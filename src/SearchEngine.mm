#import "SearchEngine.h"
#import "Scintilla.h"
// EMPTYMATCH_* / SKIPCRLFASONE flag constants — matches Windows
// boostregex/BoostRegexSearch.h. Consumed by regex/NppRegexSearch.cxx (our
// SCI_OWNREGEX implementation).
#import "../regex/NppRegexSearch.h"

// Per-operation regex flag bundles. Mirrors Windows FindReplaceDlg.cpp:3000-3014
// FINDNEXTTYPE_* matrix:
//   - Single Find Next  → EMPTYMATCH_ALL (allow empty matches anywhere)
//   - Find Next for Replace → also ALLOWATSTART (so user can replace the
//     selected match without it being treated as a continuation)
//   - Replace All / Find All / Mark All / Count → NOTAFTERMATCH (reject empty
//     match at continuation startPos, the fix for issue #151)
// All ops carry SKIPCRLFASONE so the advance-past-rejected-empty step treats
// CRLF as one user character.
static int kRegexEmptyFlagsFindNext      = SCFIND_REGEXP_EMPTYMATCH_ALL | SCFIND_REGEXP_SKIPCRLFASONE;
static int kRegexEmptyFlagsFindForReplace = SCFIND_REGEXP_EMPTYMATCH_ALL | SCFIND_REGEXP_EMPTYMATCH_ALLOWATSTART | SCFIND_REGEXP_SKIPCRLFASONE;
static int kRegexEmptyFlagsLoopOp        = SCFIND_REGEXP_EMPTYMATCH_NOTAFTERMATCH | SCFIND_REGEXP_SKIPCRLFASONE;

/// Expand Scintilla replacement tags (\0 through \9) for one regex match.
/// All other characters, including backslashes, remain literal.
static NSString *nppRegexReplacement(NSString *replacement,
                                     NSTextCheckingResult *match,
                                     NSString *line) {
    NSMutableString *expanded = [NSMutableString string];
    for (NSUInteger i = 0; i < replacement.length; i++) {
        unichar c = [replacement characterAtIndex:i];
        if (c == '\\' && i + 1 < replacement.length) {
            unichar next = [replacement characterAtIndex:i + 1];
            if (next >= '0' && next <= '9') {
                NSUInteger group = (NSUInteger)(next - '0');
                if (group < match.numberOfRanges) {
                    NSRange range = [match rangeAtIndex:group];
                    if (range.location != NSNotFound)
                        [expanded appendString:[line substringWithRange:range]];
                }
                i++;
                continue;
            }
        }
        [expanded appendFormat:@"%C", c];
    }
    return expanded;
}

// ── NPPFindOptions ───────────────────────────────────────────────────────────

@implementation NPPFindOptions

- (instancetype)init {
    self = [super init];
    if (self) {
        _searchText  = @"";
        _replaceText = @"";
        _wrapAround  = YES;
        _direction   = NPPSearchDown;
        _searchType  = NPPSearchNormal;
        _isRecursive = YES;
        _filters     = @"*.*";
        _markStyle   = 1;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    NPPFindOptions *c = [[NPPFindOptions alloc] init];
    c.searchText      = _searchText;
    c.replaceText     = _replaceText;
    c.matchCase       = _matchCase;
    c.wholeWord       = _wholeWord;
    c.wrapAround      = _wrapAround;
    c.inSelection     = _inSelection;
    c.direction       = _direction;
    c.searchType      = _searchType;
    c.dotMatchesNewline = _dotMatchesNewline;
    c.filters         = _filters;
    c.directory       = _directory;
    c.isRecursive     = _isRecursive;
    c.isInHiddenDirs  = _isInHiddenDirs;
    c.doPurge         = _doPurge;
    c.doBookmarkLine  = _doBookmarkLine;
    c.markStyle       = _markStyle;
    c.projectPanel1   = _projectPanel1;
    c.projectPanel2   = _projectPanel2;
    c.projectPanel3   = _projectPanel3;
    return c;
}

@end

// ── NPPSearchResult ──────────────────────────────────────────────────────────

@implementation NPPSearchResult
@end

// ── NPPFileResults ───────────────────────────────────────────────────────────

@implementation NPPFileResults
- (instancetype)init {
    self = [super init];
    if (self) _results = [NSMutableArray array];
    return self;
}
@end

// ── SearchEngine ─────────────────────────────────────────────────────────────

@implementation SearchEngine

#pragma mark - Extended string expansion

+ (NSString *)expandExtendedString:(NSString *)input {
    if (!input.length) return input;

    NSMutableData *data = [NSMutableData dataWithCapacity:input.length];
    const char *s = input.UTF8String;
    size_t len = strlen(s);

    for (size_t i = 0; i < len; i++) {
        if (s[i] == '\\' && i + 1 < len) {
            char next = s[i + 1];
            switch (next) {
                case 'n':  { char c = '\n'; [data appendBytes:&c length:1]; i++; continue; }
                case 'r':  { char c = '\r'; [data appendBytes:&c length:1]; i++; continue; }
                case 't':  { char c = '\t'; [data appendBytes:&c length:1]; i++; continue; }
                case '0':  { char c = '\0'; [data appendBytes:&c length:1]; i++; continue; }
                case '\\': { char c = '\\'; [data appendBytes:&c length:1]; i++; continue; }
                case 'x': case 'X': {
                    if (i + 3 < len) {
                        char hex[3] = { s[i+2], s[i+3], 0 };
                        char *end = NULL;
                        long val = strtol(hex, &end, 16);
                        if (end == hex + 2) {
                            char c = (char)val;
                            [data appendBytes:&c length:1];
                            i += 3;
                            continue;
                        }
                    }
                    break;
                }
                default: break;
            }
        }
        [data appendBytes:&s[i] length:1];
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: input;
}

#pragma mark - Scintilla flags

+ (int)scintillaFlagsForOptions:(NPPFindOptions *)opts {
    int flags = 0;
    if (opts.matchCase) flags |= SCFIND_MATCHCASE;
    if (opts.wholeWord && opts.searchType != NPPSearchRegex) flags |= SCFIND_WHOLEWORD;
    if (opts.searchType == NPPSearchRegex) {
        // Issue #108 — SCFIND_POSIX selects Scintilla's RESearch engine which
        // lacks `|` alternation, lookaheads, non-capturing groups, and `\b`
        // word boundaries (RESearch uses `\<` and `\>` instead). SCFIND_CXX11REGEX
        // routes to std::regex (ECMAScript flavor), giving feature parity with
        // Windows NPP Boost.Regex for in-line patterns. Multi-line patterns
        // crossing `\n` still don't work because our build doesn't define
        // REGEX_MULTILINE — the line-by-line scan in MatchOnLines remains.
        flags |= SCFIND_REGEXP | SCFIND_CXX11REGEX;
        if (opts.dotMatchesNewline) flags |= SCFIND_REGEXP_DOTMATCHESNL;
    }
    return flags;
}

/// Prepare the search needle, applying Extended expansion if needed. Returns UTF8 C string.
+ (const char *)preparedNeedle:(NPPFindOptions *)opts {
    NSString *text = opts.searchText;
    if (opts.searchType == NPPSearchExtended)
        text = [self expandExtendedString:text];
    return text.UTF8String;
}

#pragma mark - Find

+ (BOOL)findInView:(ScintillaView *)sci options:(NPPFindOptions *)opts forward:(BOOL)forward {
    if (!opts.searchText.length) return NO;

    const char *needle = [self preparedNeedle:opts];
    size_t needleLen = strlen(needle);
    int flags = [self scintillaFlagsForOptions:opts];
    if (opts.searchType == NPPSearchRegex) flags |= kRegexEmptyFlagsFindNext;

    sptr_t docLen = [sci message:SCI_GETLENGTH];
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];

    [sci message:SCI_SETSEARCHFLAGS wParam:(uptr_t)flags];

    sptr_t searchStart, searchEnd;
    if (forward) {
        searchStart = selEnd;
        searchEnd   = docLen;
    } else {
        searchStart = selStart;
        searchEnd   = 0;
    }

    [sci message:SCI_SETTARGETRANGE wParam:(uptr_t)searchStart lParam:searchEnd];
    sptr_t found = [sci message:SCI_SEARCHINTARGET wParam:needleLen lParam:(sptr_t)needle];

    // Wrap around if not found and option is on
    if (found < 0 && opts.wrapAround) {
        if (forward) {
            [sci message:SCI_SETTARGETRANGE wParam:0 lParam:searchStart];
        } else {
            [sci message:SCI_SETTARGETRANGE wParam:docLen lParam:searchEnd];
        }
        found = [sci message:SCI_SEARCHINTARGET wParam:needleLen lParam:(sptr_t)needle];
    }

    if (found >= 0) {
        sptr_t end = [sci message:SCI_GETTARGETEND];
        [sci message:SCI_SETSEL wParam:(uptr_t)found lParam:end];
        [sci message:SCI_SCROLLCARET];
        return YES;
    }
    return NO;
}

#pragma mark - Replace

+ (BOOL)replaceInView:(ScintillaView *)sci options:(NPPFindOptions *)opts {
    if (!opts.searchText.length) return NO;

    const char *needle = [self preparedNeedle:opts];
    int flags = [self scintillaFlagsForOptions:opts];
    // Selection-match probe: the selection IS what the user picked to replace
    // — allow empty match exactly at its start so e.g. `$` matches a previously
    // found end-of-line selection. The follow-up Find Next then uses the
    // FindNext flag set (no ALLOWATSTART, so the freshly-replaced position
    // doesn't trigger another zero-width match at the same byte).
    if (opts.searchType == NPPSearchRegex) flags |= kRegexEmptyFlagsFindForReplace;

    // Check if current selection matches
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];

    if (selStart != selEnd) {
        [sci message:SCI_SETSEARCHFLAGS wParam:(uptr_t)flags];
        [sci message:SCI_SETTARGETRANGE wParam:(uptr_t)selStart lParam:selEnd];
        sptr_t found = [sci message:SCI_SEARCHINTARGET wParam:strlen(needle) lParam:(sptr_t)needle];

        if (found >= 0 && [sci message:SCI_GETTARGETSTART] == selStart &&
            [sci message:SCI_GETTARGETEND] == selEnd) {
            // Current selection matches — replace it
            NSString *replaceText = opts.replaceText ?: @"";
            if (opts.searchType == NPPSearchExtended)
                replaceText = [self expandExtendedString:replaceText];
            const char *replacement = replaceText.UTF8String;

            if (opts.searchType == NPPSearchRegex)
                [sci message:SCI_REPLACETARGETRE wParam:(uptr_t)-1 lParam:(sptr_t)replacement];
            else
                [sci message:SCI_REPLACETARGET wParam:(uptr_t)-1 lParam:(sptr_t)replacement];
        }
    }

    // Find next
    return [self findInView:sci options:opts forward:(opts.direction == NPPSearchDown)];
}

#pragma mark - Replace All

+ (NSInteger)replaceAllInView:(ScintillaView *)sci options:(NPPFindOptions *)opts {
    if (!opts.searchText.length) return 0;

    const char *needle = [self preparedNeedle:opts];
    size_t needleLen = strlen(needle);
    int flags = [self scintillaFlagsForOptions:opts];
    // Loop semantics — see Windows FindReplaceDlg.cpp:3461. NOTAFTERMATCH
    // rejects zero-width matches at the continuation position, the fix for
    // issue #151 ($ → X freezing on docs ending with \n).
    if (opts.searchType == NPPSearchRegex) flags |= kRegexEmptyFlagsLoopOp;

    NSString *replaceText = opts.replaceText ?: @"";
    if (opts.searchType == NPPSearchExtended)
        replaceText = [self expandExtendedString:replaceText];
    const char *replacement = replaceText.UTF8String;

    [sci message:SCI_SETSEARCHFLAGS wParam:(uptr_t)flags];
    [sci message:SCI_BEGINUNDOACTION];

    sptr_t rangeStart, rangeEnd;
    if (opts.inSelection) {
        rangeStart = [sci message:SCI_GETSELECTIONSTART];
        rangeEnd   = [sci message:SCI_GETSELECTIONEND];
    } else if (opts.wrapAround) {
        rangeStart = 0;
        rangeEnd   = [sci message:SCI_GETLENGTH];
    } else if (opts.direction == NPPSearchUp) {
        rangeStart = 0;
        rangeEnd   = [sci message:SCI_GETCURRENTPOS];
    } else {
        rangeStart = [sci message:SCI_GETCURRENTPOS];
        rangeEnd   = [sci message:SCI_GETLENGTH];
    }

    NSInteger count = 0;
    sptr_t pos = rangeStart;

    while (pos < rangeEnd) {
        [sci message:SCI_SETTARGETRANGE wParam:(uptr_t)pos lParam:rangeEnd];
        sptr_t found = [sci message:SCI_SEARCHINTARGET wParam:needleLen lParam:(sptr_t)needle];
        if (found < 0) break;

        sptr_t targetEnd = [sci message:SCI_GETTARGETEND];
        sptr_t replLen;
        if (opts.searchType == NPPSearchRegex)
            replLen = [sci message:SCI_REPLACETARGETRE wParam:(uptr_t)-1 lParam:(sptr_t)replacement];
        else
            replLen = [sci message:SCI_REPLACETARGET wParam:(uptr_t)-1 lParam:(sptr_t)replacement];

        sptr_t delta = replLen - (targetEnd - found);
        rangeEnd += delta;
        pos = found + replLen;
        if (pos <= found) pos = found + 1; // prevent infinite loop on zero-length match
        count++;
    }

    [sci message:SCI_ENDUNDOACTION];
    return count;
}

+ (NSString *)stringByReplacingAllInString:(NSString *)content
                                   options:(NPPFindOptions *)opts
                          replacementCount:(NSInteger *)replacementCount {
    if (replacementCount) *replacementCount = 0;
    if (!opts.searchText.length || !content.length) return content;

    NSString *search = opts.searchText;
    NSString *replacement = opts.replaceText ?: @"";
    if (opts.searchType == NPPSearchExtended) {
        search = [self expandExtendedString:search];
        replacement = [self expandExtendedString:replacement];
    }
    if (!search.length) return content;

    if (opts.searchType == NPPSearchRegex) {
        NSRegularExpressionOptions reOptions = 0;
        if (!opts.matchCase) reOptions |= NSRegularExpressionCaseInsensitive;
        if (opts.dotMatchesNewline) reOptions |= NSRegularExpressionDotMatchesLineSeparators;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:search
                                                                                options:reOptions
                                                                                  error:nil];
        if (!regex) return content;
        // Find in Files evaluates each line independently. Replace the same way
        // so anchors and Dot Matches Newline cannot affect text the search did
        // not preview. Splitting and rejoining on LF also preserves CRLF bytes:
        // each line retains its trailing CR.
        NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
        NSMutableArray<NSString *> *replacedLines = [NSMutableArray arrayWithCapacity:lines.count];
        NSInteger count = 0;
        for (NSString *line in lines) {
            NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:line
                                                                      options:0
                                                                        range:NSMakeRange(0, line.length)];
            if (!matches.count) {
                [replacedLines addObject:line];
                continue;
            }
            NSMutableString *replacedLine = [line mutableCopy];
            for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
                NSString *expanded = nppRegexReplacement(replacement, match, line);
                [replacedLine replaceCharactersInRange:match.range withString:expanded];
            }
            count += (NSInteger)matches.count;
            [replacedLines addObject:replacedLine];
        }
        if (replacementCount) *replacementCount = count;
        return [replacedLines componentsJoinedByString:@"\n"];
    }

    NSStringCompareOptions compareOptions = opts.matchCase ? 0 : NSCaseInsensitiveSearch;
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    NSMutableCharacterSet *wordCharacters = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [wordCharacters addCharactersInString:@"_"];
    NSRange remaining = NSMakeRange(0, content.length);
    while (remaining.length > 0) {
        NSRange match = [content rangeOfString:search options:compareOptions range:remaining];
        if (match.location == NSNotFound) break;

        BOOL isWholeWord = YES;
        if (opts.wholeWord) {
            if (match.location > 0)
                isWholeWord = ![wordCharacters characterIsMember:[content characterAtIndex:match.location - 1]];
            NSUInteger matchEnd = NSMaxRange(match);
            if (isWholeWord && matchEnd < content.length)
                isWholeWord = ![wordCharacters characterIsMember:[content characterAtIndex:matchEnd]];
        }
        if (isWholeWord) [ranges addObject:[NSValue valueWithRange:match]];

        NSUInteger next = NSMaxRange(match);
        if (next <= match.location) next = match.location + 1;
        remaining = NSMakeRange(next, content.length - next);
    }

    if (replacementCount) *replacementCount = (NSInteger)ranges.count;
    if (!ranges.count) return content;
    NSMutableString *result = [content mutableCopy];
    for (NSValue *value in ranges.reverseObjectEnumerator)
        [result replaceCharactersInRange:value.rangeValue withString:replacement];
    return result;
}

#pragma mark - Count

+ (NSInteger)countInView:(ScintillaView *)sci options:(NPPFindOptions *)opts {
    if (!opts.searchText.length) return 0;

    const char *needle = [self preparedNeedle:opts];
    size_t needleLen = strlen(needle);
    int flags = [self scintillaFlagsForOptions:opts];
    if (opts.searchType == NPPSearchRegex) flags |= kRegexEmptyFlagsLoopOp;

    [sci message:SCI_SETSEARCHFLAGS wParam:(uptr_t)flags];

    sptr_t docLen = [sci message:SCI_GETLENGTH];
    NSInteger count = 0;
    sptr_t pos = 0;

    while (pos < docLen) {
        [sci message:SCI_SETTARGETRANGE wParam:(uptr_t)pos lParam:docLen];
        sptr_t found = [sci message:SCI_SEARCHINTARGET wParam:needleLen lParam:(sptr_t)needle];
        if (found < 0) break;
        sptr_t end = [sci message:SCI_GETTARGETEND];
        pos = end > found ? end : found + 1;
        count++;
    }
    return count;
}

#pragma mark - Find All

+ (NSArray<NPPSearchResult *> *)findAllInView:(ScintillaView *)sci
                                     filePath:(NSString *)path
                                      options:(NPPFindOptions *)opts {
    if (!opts.searchText.length) return @[];

    const char *needle = [self preparedNeedle:opts];
    size_t needleLen = strlen(needle);
    int flags = [self scintillaFlagsForOptions:opts];
    if (opts.searchType == NPPSearchRegex) flags |= kRegexEmptyFlagsLoopOp;

    [sci message:SCI_SETSEARCHFLAGS wParam:(uptr_t)flags];

    sptr_t docLen = [sci message:SCI_GETLENGTH];
    NSMutableArray *results = [NSMutableArray array];
    sptr_t pos = 0;

    while (pos < docLen) {
        [sci message:SCI_SETTARGETRANGE wParam:(uptr_t)pos lParam:docLen];
        sptr_t found = [sci message:SCI_SEARCHINTARGET wParam:needleLen lParam:(sptr_t)needle];
        if (found < 0) break;
        sptr_t end = [sci message:SCI_GETTARGETEND];

        // Get line number and line text
        sptr_t line = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)found];
        sptr_t lineStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)line];
        sptr_t lineEnd   = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)line];
        sptr_t lineLen   = lineEnd - lineStart;

        // Get line text
        char *buf = (char *)calloc(lineLen + 1, 1);
        struct Sci_TextRangeFull tr;
        tr.chrg.cpMin = lineStart;
        tr.chrg.cpMax = lineEnd;
        tr.lpstrText  = buf;
        [sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&tr];

        NPPSearchResult *r = [[NPPSearchResult alloc] init];
        r.filePath    = path ?: @"";
        r.lineNumber  = line + 1; // 1-based
        r.lineText    = [NSString stringWithUTF8String:buf] ?: @"";
        r.matchStart  = found - lineStart;
        r.matchLength = end - found;
        [results addObject:r];

        free(buf);
        pos = end > found ? end : found + 1;
    }
    return results;
}

#pragma mark - Mark All

+ (NSInteger)markAllInView:(ScintillaView *)sci options:(NPPFindOptions *)opts {
    if (!opts.searchText.length) return 0;

    const char *needle = [self preparedNeedle:opts];
    size_t needleLen = strlen(needle);
    int flags = [self scintillaFlagsForOptions:opts];
    if (opts.searchType == NPPSearchRegex) flags |= kRegexEmptyFlagsLoopOp;

    // Mark indicator slot: use indicator 31 for "Find Mark Style"
    static const int kFindMarkIndicator = 31;

    if (opts.doPurge) {
        [sci message:SCI_SETINDICATORCURRENT wParam:kFindMarkIndicator];
        [sci message:SCI_INDICATORCLEARRANGE wParam:0 lParam:[sci message:SCI_GETLENGTH]];
        if (opts.doBookmarkLine) {
            [sci message:SCI_MARKERDELETEALL wParam:20]; // bookmark marker 20
        }
    }

    [sci message:SCI_SETINDICATORCURRENT wParam:kFindMarkIndicator];
    [sci message:SCI_INDICSETSTYLE  wParam:kFindMarkIndicator lParam:INDIC_ROUNDBOX];
    [sci message:SCI_INDICSETFORE   wParam:kFindMarkIndicator lParam:0xFF8000]; // orange
    [sci message:SCI_INDICSETALPHA  wParam:kFindMarkIndicator lParam:100];

    [sci message:SCI_SETSEARCHFLAGS wParam:(uptr_t)flags];

    sptr_t docLen = [sci message:SCI_GETLENGTH];
    NSInteger count = 0;
    sptr_t pos = 0;

    while (pos < docLen) {
        [sci message:SCI_SETTARGETRANGE wParam:(uptr_t)pos lParam:docLen];
        sptr_t found = [sci message:SCI_SEARCHINTARGET wParam:needleLen lParam:(sptr_t)needle];
        if (found < 0) break;
        sptr_t end = [sci message:SCI_GETTARGETEND];

        [sci message:SCI_INDICATORFILLRANGE wParam:(uptr_t)found lParam:end - found];

        if (opts.doBookmarkLine) {
            sptr_t line = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)found];
            [sci message:SCI_MARKERADD wParam:(uptr_t)line lParam:20]; // bookmark marker
        }

        pos = end > found ? end : found + 1;
        count++;
    }
    return count;
}

#pragma mark - Find in Directory

+ (NSArray<NPPFileResults *> *)findInDirectory:(NSString *)directory
                                       options:(NPPFindOptions *)opts
                                 progressBlock:(nullable void(^)(NSString *currentFile, NSInteger hits))progressBlock
                                    cancelFlag:(BOOL *)cancelFlag
                            totalFilesScanned:(nullable NSInteger *)totalFilesScanned {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:directory];
    if (!opts.isRecursive) [en skipDescendants];

    NSString *searchText = opts.searchText;
    if (opts.searchType == NPPSearchExtended)
        searchText = [self expandExtendedString:searchText];

    // Build file filter predicates
    NSArray<NSString *> *globs = [opts.filters componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@", "]];
    NSMutableArray<NSPredicate *> *preds = [NSMutableArray array];
    for (NSString *g in globs) {
        NSString *t = [g stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [preds addObject:[NSPredicate predicateWithFormat:@"SELF LIKE[c] %@", t]];
    }

    NSStringCompareOptions cmpOpts = opts.matchCase ? 0 : NSCaseInsensitiveSearch;
    NSMutableArray<NPPFileResults *> *allResults = [NSMutableArray array];
    __block NSInteger totalHits = 0;
    NSInteger filesScanned = 0;
    NSString *rel;

    // Compile the regex once for the whole call — pattern, case-sensitivity,
    // and dot-matches-newline are invariant across every file and line. The
    // sister function findInFilePaths: does the same.
    NSRegularExpression *re = nil;
    if (opts.searchType == NPPSearchRegex) {
        NSRegularExpressionOptions reOpts = 0;
        if (!opts.matchCase) reOpts |= NSRegularExpressionCaseInsensitive;
        if (opts.dotMatchesNewline) reOpts |= NSRegularExpressionDotMatchesLineSeparators;
        re = [NSRegularExpression regularExpressionWithPattern:searchText
                                                       options:reOpts error:nil];
        if (!re) {
            if (totalFilesScanned) *totalFilesScanned = 0;
            return allResults;
        }
    }

    while ((rel = [en nextObject])) {
        if (cancelFlag && *cancelFlag) break;

        NSString *full = [directory stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        [fm fileExistsAtPath:full isDirectory:&isDir];
        if (isDir) {
            // Skip hidden directories
            if (!opts.isInHiddenDirs && [rel.lastPathComponent hasPrefix:@"."]) {
                [en skipDescendants];
            }
            continue;
        }

        // Skip hidden files
        if (!opts.isInHiddenDirs && [rel.lastPathComponent hasPrefix:@"."]) continue;

        // Apply file filter
        NSString *name = rel.lastPathComponent;
        BOOL pass = (preds.count == 0);
        for (NSPredicate *p in preds) {
            if ([p evaluateWithObject:name]) { pass = YES; break; }
        }
        if (!pass) continue;

        filesScanned++;

        // Read file
        NSString *content = [NSString stringWithContentsOfFile:full
                                                     encoding:NSUTF8StringEncoding error:nil];
        if (!content) continue;

        NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
        NPPFileResults *fileRes = nil;

        for (NSInteger ln = 0; ln < (NSInteger)lines.count; ln++) {
            if (cancelFlag && *cancelFlag) break;

            NSString *line = lines[ln];
            NSRange range;

            if (opts.searchType == NPPSearchRegex) {
                NSTextCheckingResult *m = [re firstMatchInString:line options:0
                                                          range:NSMakeRange(0, line.length)];
                if (!m) continue;
                range = m.range;
            } else {
                range = [line rangeOfString:searchText options:cmpOpts];
                if (range.location == NSNotFound) continue;
            }

            // Whole word check for non-regex
            if (opts.wholeWord && opts.searchType != NPPSearchRegex) {
                if (range.location > 0) {
                    unichar c = [line characterAtIndex:range.location - 1];
                    if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:c] || c == '_')
                        continue;
                }
                NSUInteger endPos = range.location + range.length;
                if (endPos < line.length) {
                    unichar c = [line characterAtIndex:endPos];
                    if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:c] || c == '_')
                        continue;
                }
            }

            if (!fileRes) {
                fileRes = [[NPPFileResults alloc] init];
                fileRes.filePath = full;
            }

            NPPSearchResult *r = [[NPPSearchResult alloc] init];
            r.filePath    = full;
            r.lineNumber  = ln + 1;
            r.lineText    = line;
            r.matchStart  = (NSInteger)range.location;
            r.matchLength = (NSInteger)range.length;
            [fileRes.results addObject:r];
        }

        if (fileRes) {
            totalHits += (NSInteger)fileRes.results.count;
            [allResults addObject:fileRes];
            if (progressBlock) {
                NSInteger h = totalHits;
                NSString *f = full;
                dispatch_async(dispatch_get_main_queue(), ^{
                    progressBlock(f, h);
                });
            }
        }
    }
    if (totalFilesScanned) *totalFilesScanned = filesScanned;
    return allResults;
}

+ (NSArray<NPPFileResults *> *)findInFilePaths:(NSArray<NSString *> *)filePaths
                                       options:(NPPFindOptions *)opts
                                 progressBlock:(nullable void(^)(NSString *currentFile, NSInteger hits))progressBlock
                                    cancelFlag:(BOOL *)cancelFlag
                            totalFilesScanned:(nullable NSInteger *)totalFilesScanned {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *searchText = opts.searchText;
    if (opts.searchType == NPPSearchExtended)
        searchText = [self expandExtendedString:searchText];

    // Build file filter predicates
    NSArray<NSString *> *globs = [opts.filters componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@", "]];
    NSMutableArray<NSPredicate *> *preds = [NSMutableArray array];
    for (NSString *g in globs) {
        NSString *t = [g stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [preds addObject:[NSPredicate predicateWithFormat:@"SELF LIKE[c] %@", t]];
    }

    NSStringCompareOptions cmpOpts = opts.matchCase ? 0 : NSCaseInsensitiveSearch;
    NSMutableArray<NPPFileResults *> *allResults = [NSMutableArray array];
    __block NSInteger totalHits = 0;
    NSInteger filesScanned = 0;

    // Compile the regex once for the whole call — pattern, case-sensitivity,
    // and dot-matches-newline are invariant across every file and line.
    // (PR #57 hoisted this out of the per-line loop; we hoist further out
    // of the per-file loop too.) NSRegularExpression is documented thread-
    // safe for read-only use, but we don't share across threads here anyway.
    NSRegularExpression *re = nil;
    if (opts.searchType == NPPSearchRegex) {
        NSRegularExpressionOptions reOpts = 0;
        if (!opts.matchCase) reOpts |= NSRegularExpressionCaseInsensitive;
        if (opts.dotMatchesNewline) reOpts |= NSRegularExpressionDotMatchesLineSeparators;
        re = [NSRegularExpression regularExpressionWithPattern:searchText
                                                       options:reOpts error:nil];
        if (!re) {
            if (totalFilesScanned) *totalFilesScanned = 0;
            return allResults;
        }
    }

    for (NSString *full in filePaths) {
        if (cancelFlag && *cancelFlag) break;

        // Check file exists
        if (![fm fileExistsAtPath:full]) continue;

        // Apply file filter
        NSString *name = full.lastPathComponent;
        BOOL pass = (preds.count == 0);
        for (NSPredicate *p in preds) {
            if ([p evaluateWithObject:name]) { pass = YES; break; }
        }
        if (!pass) continue;

        filesScanned++;

        // Read file
        NSString *content = [NSString stringWithContentsOfFile:full
                                                     encoding:NSUTF8StringEncoding error:nil];
        if (!content) continue;

        NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
        NPPFileResults *fileRes = nil;

        for (NSInteger ln = 0; ln < (NSInteger)lines.count; ln++) {
            if (cancelFlag && *cancelFlag) break;

            NSString *line = lines[ln];
            NSRange range;

            if (opts.searchType == NPPSearchRegex) {
                NSTextCheckingResult *m = [re firstMatchInString:line options:0
                                                          range:NSMakeRange(0, line.length)];
                if (!m) continue;
                range = m.range;
            } else {
                range = [line rangeOfString:searchText options:cmpOpts];
                if (range.location == NSNotFound) continue;
            }

            // Whole word check for non-regex
            if (opts.wholeWord && opts.searchType != NPPSearchRegex) {
                if (range.location > 0) {
                    unichar c = [line characterAtIndex:range.location - 1];
                    if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:c] || c == '_')
                        continue;
                }
                NSUInteger endPos = range.location + range.length;
                if (endPos < line.length) {
                    unichar c = [line characterAtIndex:endPos];
                    if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:c] || c == '_')
                        continue;
                }
            }

            if (!fileRes) {
                fileRes = [[NPPFileResults alloc] init];
                fileRes.filePath = full;
            }

            NPPSearchResult *r = [[NPPSearchResult alloc] init];
            r.filePath    = full;
            r.lineNumber  = ln + 1;
            r.lineText    = line;
            r.matchStart  = (NSInteger)range.location;
            r.matchLength = (NSInteger)range.length;
            [fileRes.results addObject:r];
        }

        if (fileRes) {
            totalHits += (NSInteger)fileRes.results.count;
            [allResults addObject:fileRes];
            if (progressBlock) {
                NSInteger h = totalHits;
                NSString *f = full;
                dispatch_async(dispatch_get_main_queue(), ^{
                    progressBlock(f, h);
                });
            }
        }
    }
    if (totalFilesScanned) *totalFilesScanned = filesScanned;
    return allResults;
}


@end
