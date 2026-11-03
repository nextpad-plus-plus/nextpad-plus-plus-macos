#import "SearchCore.h"
#import "Scintilla.h"
#import "NppTextEncoding.h"
#include <atomic>
#include <stdlib.h>
#include <unistd.h>
#include <sys/stat.h>
#include <string>
#include <vector>
// SCFIND_REGEXP_* empty-match / dot-matches-newline flags, consumed by the
// Boost backend (regex/BoostRegExSearch.cxx). Same bit layout as Windows
// Notepad++'s boostregex/BoostRegexSearch.h.
#include "BoostRegexSearch.h"
#include "../regex/NppBufferSearch.h"

// Per-operation regex flag bundles. Mirrors Windows FindReplaceDlg.cpp:3000-3014
// FINDNEXTTYPE_* matrix:
//   - Single Find Next  → EMPTYMATCH_ALL (allow empty matches anywhere)
//   - Find Next for Replace → also ALLOWATSTART (so user can replace the
//     selected match without it being treated as a continuation)
//   - Replace All / Find All / Mark All / Count → NOTAFTERMATCH (reject empty
//     match at continuation startPos, the fix for issue #151)
// All ops carry SKIPCRLFASONE so the advance-past-rejected-empty step treats
// CRLF as one user character.
static const int kRegexEmptyFlagsFindNext       = SCFIND_REGEXP_EMPTYMATCH_ALL | SCFIND_REGEXP_SKIPCRLFASONE;
static const int kRegexEmptyFlagsFindForReplace = SCFIND_REGEXP_EMPTYMATCH_ALL | SCFIND_REGEXP_EMPTYMATCH_ALLOWATSTART | SCFIND_REGEXP_SKIPCRLFASONE;
static const int kRegexEmptyFlagsLoopOp         = SCFIND_REGEXP_EMPTYMATCH_NOTAFTERMATCH | SCFIND_REGEXP_SKIPCRLFASONE;

// How often (in hits) a Find in Files run polls its cancel token inside one file.
static const NSInteger kCancelPollHits = 1024;

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
    c.wordChars       = _wordChars;
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

@interface NPPSearchResult ()
/// YES when the line's bytes were not valid UTF-8 and lineText was decoded as
/// Latin-1, so offsets in it are byte offsets.
@property BOOL npp_bytewiseLineText;
/// Where the last hit started, as a byte offset and in UTF-16 units, so the
/// next hit on a long line is converted from there instead of from the start.
@property NSUInteger npp_lastHitByte;
@property NSUInteger npp_lastHitUnits;
- (void)npp_addRange:(NSRange)range;
- (NSUInteger)npp_rangeCount;
@end

@implementation NPPSearchResult {
    NSMutableArray<NSValue *> *_ranges;
}
- (instancetype)init {
    self = [super init];
    if (self) _ranges = [NSMutableArray array];
    return self;
}
- (NSArray<NSValue *> *)matchRanges {
    return [_ranges copy];
}
- (void)setMatchRanges:(NSArray<NSValue *> *)matchRanges {
    _ranges = [matchRanges mutableCopy] ?: [NSMutableArray array];
}
- (void)npp_addRange:(NSRange)range {
    [_ranges addObject:[NSValue valueWithRange:range]];
}
- (NSUInteger)npp_rangeCount {
    return _ranges.count;
}
- (NSInteger)hitCount {
    return MAX((NSInteger)1, (NSInteger)_ranges.count);
}
@end

// ── NPPFileResults ───────────────────────────────────────────────────────────

@implementation NPPFileResults
- (instancetype)init {
    self = [super init];
    if (self) _results = [NSMutableArray array];
    return self;
}
- (NSInteger)hitCount {
    NSInteger n = 0;
    for (NPPSearchResult *r in _results) n += r.hitCount;
    return n;
}
@end

// ── NPPCancelToken ───────────────────────────────────────────────────────────

@implementation NPPCancelToken {
    std::atomic<bool> _cancelled;
}
- (BOOL)isCancelled { return _cancelled.load(std::memory_order_relaxed) ? YES : NO; }
- (void)cancel      { _cancelled.store(true, std::memory_order_relaxed); }
@end

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Number of UTF-16 code units in `length` bytes of valid UTF-8.
static NSUInteger utf16UnitsInUTF8(const char *bytes, size_t length) {
    NSUInteger units = 0;
    for (size_t i = 0; i < length; i++) {
        const unsigned char c = (unsigned char)bytes[i];
        if ((c & 0xC0) == 0x80) continue;     // continuation byte
        units += (c >= 0xF0) ? 2 : 1;         // 4-byte sequences are surrogate pairs
    }
    return units;
}

/// The UTF-8 bytes of `text`, NULs included. Returns NO (and a lossy copy)
/// when the text has unpaired surrogates and so has no exact UTF-8 form.
static BOOL utf8BytesOf(NSString *text, std::string &out) {
    out.clear();
    if (!text.length) return YES;
    const NSUInteger maxLength = [text maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    out.resize(maxLength);
    NSUInteger used = 0;
    NSRange remaining = NSMakeRange(0, 0);
    const BOOL ok = [text getBytes:out.data() maxLength:maxLength usedLength:&used
                          encoding:NSUTF8StringEncoding options:0
                             range:NSMakeRange(0, text.length) remainingRange:&remaining];
    if (ok && remaining.length == 0) {
        out.resize(used);
        return YES;
    }
    NSData *lossy = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    out.assign((const char *)lossy.bytes, lossy.length);
    return NO;
}

/// Everything a BufferSearch needs from the options, prepared the same way the
/// editor prepares its needle and replacement.
struct NPPSearchSetup {
    std::string needle;
    std::string replacement;
    int flags = 0;
    bool regexReplace = false;
    std::string wordChars;
    bool hasWordChars = false;
};

static NPPSearchSetup setupForOptions(NPPFindOptions *opts) {
    NPPSearchSetup s;
    NSString *search = opts.searchText ?: @"";
    NSString *replacement = opts.replaceText ?: @"";
    if (opts.searchType == NPPSearchExtended) {
        search = [NPPSearchCore expandExtendedString:search];
        replacement = [NPPSearchCore expandExtendedString:replacement];
    }
    // UTF8String, as the editor passes it to SCI_SEARCHINTARGET and
    // SCI_REPLACETARGET(RE): the text ends at an embedded NUL there too.
    s.needle = search.UTF8String ?: "";
    s.replacement = replacement.UTF8String ?: "";
    s.flags = [NPPSearchCore loopFlagsForOptions:opts];
    s.regexReplace = (opts.searchType == NPPSearchRegex);
    if (opts.wordChars.length) {
        s.wordChars = opts.wordChars.UTF8String ?: "";
        s.hasWordChars = true;
    }
    return s;
}

/// The engine's message when the last search failed (bad pattern, or
/// Boost's complexity limit while matching), else nil.
static NSString *regexErrorOf(const NppSearch::BufferSearch &search) {
    if (search.LastStatus() == NppSearch::Status::Ok) return nil;
    NSString *message = [NSString stringWithUTF8String:search.ErrorMessage().c_str()];
    return message.length ? message : @"Invalid regular expression";
}

enum class CollectResult { Done, Cancelled, RegexFailed };

/// Find every match in `utf8` (already loaded into `search`) and append one
/// NPPSearchResult per line to `results`.
static CollectResult collectHits(NppSearch::BufferSearch &search, const std::string &utf8,
                                 NSString *path, NPPCancelToken *cancelToken,
                                 NSMutableArray<NPPSearchResult *> *results) {
    BOOL cancelled = NO;
    NSInteger hits = 0;
    NppSearch::ForEachMatch(search, 0, search.Length(), [&](NppSearch::Pos start, NppSearch::Pos end) {
        const NppSearch::Pos line = search.LineFromPosition(start);
        const NppSearch::Pos lineStart = search.LineStart(line);
        const NppSearch::Pos lineEnd = search.LineEnd(line);
        [NPPSearchCore appendHitToResults:results
                                 filePath:path
                               lineNumber:(NSInteger)line + 1
                                lineBytes:utf8.data() + lineStart
                               lineLength:(NSUInteger)(lineEnd - lineStart)
                                 hitStart:(NSUInteger)(start - lineStart)
                                   hitEnd:(NSUInteger)(end - lineStart)];
        if (++hits % kCancelPollHits == 0 && cancelToken.isCancelled) {
            cancelled = YES;
            return false;
        }
        return true;
    });
    // A failed search ends the loop like "no more matches"; the hits so far
    // would be a silently truncated list.
    if (search.LastStatus() != NppSearch::Status::Ok) return CollectResult::RegexFailed;
    return cancelled ? CollectResult::Cancelled : CollectResult::Done;
}

// ── NPPSearchCore ────────────────────────────────────────────────────────────

@implementation NPPSearchCore

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
    // As on Windows, whole word does not apply to regular expressions (use \b).
    if (opts.wholeWord && opts.searchType != NPPSearchRegex) flags |= SCFIND_WHOLEWORD;
    if (opts.searchType == NPPSearchRegex) {
        // SCI_OWNREGEX routes every SCFIND_REGEXP search to the Boost backend
        // (regex/BoostRegExSearch.cxx), as on Windows Notepad++: Perl syntax,
        // whole-document matching (patterns can span lines), lookbehind, \K.
        // ^ and $ match at line boundaries; '.' crosses line ends only with
        // ". matches newline".
        flags |= SCFIND_REGEXP;
        if (opts.dotMatchesNewline) flags |= SCFIND_REGEXP_DOTMATCHESNL;
    }
    return flags;
}

+ (int)loopFlagsForOptions:(NPPFindOptions *)opts {
    int flags = [self scintillaFlagsForOptions:opts];
    if (opts.searchType == NPPSearchRegex) flags |= kRegexEmptyFlagsLoopOp;
    return flags;
}

+ (int)findNextFlagsForOptions:(NPPFindOptions *)opts {
    int flags = [self scintillaFlagsForOptions:opts];
    if (opts.searchType == NPPSearchRegex) flags |= kRegexEmptyFlagsFindNext;
    return flags;
}

+ (int)findForReplaceFlagsForOptions:(NPPFindOptions *)opts {
    int flags = [self scintillaFlagsForOptions:opts];
    if (opts.searchType == NPPSearchRegex) flags |= kRegexEmptyFlagsFindForReplace;
    return flags;
}

+ (nullable NSString *)patternErrorForOptions:(NPPFindOptions *)opts {
    if (opts.searchType != NPPSearchRegex || !opts.searchText.length) return nil;
    // Compiling happens on the first Find, even over an empty buffer.
    NppSearch::BufferSearch search;
    NPPSearchSetup s = setupForOptions(opts);
    search.SetSearch(s.needle, s.flags, s.replacement, s.regexReplace);
    NppSearch::Pos end = 0;
    search.Find(0, 0, &end);
    return regexErrorOf(search);
}

+ (void)prepareForBackgroundSearch {
    NppSearch::PrepareForBackgroundUse();
}

#pragma mark - Results

+ (void)appendHitToResults:(NSMutableArray<NPPSearchResult *> *)results
                  filePath:(NSString *)path
                lineNumber:(NSInteger)lineNumber
                 lineBytes:(const char *)lineBytes
                lineLength:(NSUInteger)lineLength
                  hitStart:(NSUInteger)hitStart
                    hitEnd:(NSUInteger)hitEnd {
    if (hitStart > lineLength) hitStart = lineLength;
    if (hitEnd > lineLength) hitEnd = lineLength;   // multi-line match: cut at the EOL
    if (hitEnd < hitStart) hitEnd = hitStart;
    path = path ?: @"";

    NPPSearchResult *r = results.lastObject;
    if (!r || r.lineNumber != lineNumber || ![r.filePath isEqualToString:path]) {
        r = [[NPPSearchResult alloc] init];
        r.filePath = path;
        r.lineNumber = lineNumber;
        NSString *text = [[NSString alloc] initWithBytes:lineBytes length:lineLength
                                                encoding:NSUTF8StringEncoding];
        if (!text) {
            // Not valid UTF-8 (can happen in an editor buffer): show it as
            // Latin-1, where one byte is one character, so offsets stay right.
            text = [[NSString alloc] initWithBytes:lineBytes length:lineLength
                                          encoding:NSISOLatin1StringEncoding];
            r.npp_bytewiseLineText = YES;
        }
        r.lineText = text ?: @"";
        [results addObject:r];
    }

    NSRange range;
    if (r.npp_bytewiseLineText) {
        range = NSMakeRange(hitStart, hitEnd - hitStart);
    } else {
        // Hits arrive left to right; count on from the previous one.
        NSUInteger fromByte = 0, fromUnits = 0;
        if (hitStart >= r.npp_lastHitByte) {
            fromByte = r.npp_lastHitByte;
            fromUnits = r.npp_lastHitUnits;
        }
        const NSUInteger start = fromUnits + utf16UnitsInUTF8(lineBytes + fromByte, hitStart - fromByte);
        const NSUInteger length = utf16UnitsInUTF8(lineBytes + hitStart, hitEnd - hitStart);
        r.npp_lastHitByte = hitStart;
        r.npp_lastHitUnits = start;
        range = NSMakeRange(start, length);
    }
    if ([r npp_rangeCount] == 0) {
        r.matchStart = (NSInteger)range.location;
        r.matchLength = (NSInteger)range.length;
    }
    [r npp_addRange:range];
}

#pragma mark - Strings

+ (NSArray<NPPSearchResult *> *)findAllInString:(NSString *)content
                                       filePath:(NSString *)path
                                        options:(NPPFindOptions *)opts
                                    cancelToken:(nullable NPPCancelToken *)cancelToken
                                     regexError:(NSString * _Nullable * _Nullable)regexError {
    if (regexError) *regexError = nil;
    NSMutableArray<NPPSearchResult *> *results = [NSMutableArray array];
    if (!opts.searchText.length) return results;
    NPPSearchSetup s = setupForOptions(opts);
    if (s.needle.empty()) return results;
    NppSearch::BufferSearch search(s.hasWordChars ? s.wordChars.c_str() : nullptr);
    search.SetSearch(s.needle, s.flags, s.replacement, s.regexReplace);
    std::string utf8;
    utf8BytesOf(content, utf8);
    search.SetText(utf8.data(), utf8.size());
    if (collectHits(search, utf8, path, cancelToken, results) == CollectResult::RegexFailed) {
        if (regexError) *regexError = regexErrorOf(search);
        return @[];
    }
    return results;
}

+ (NSString *)stringByReplacingAllInString:(NSString *)content
                                   options:(NPPFindOptions *)opts
                          replacementCount:(NSInteger *)replacementCount
                                regexError:(NSString * _Nullable * _Nullable)regexError {
    if (replacementCount) *replacementCount = 0;
    if (regexError) *regexError = nil;
    if (!opts.searchText.length) return content;

    NPPSearchSetup s = setupForOptions(opts);
    if (s.needle.empty()) return content;
    std::string utf8;
    // Text with no exact UTF-8 form can't be rewritten without changing it.
    if (!utf8BytesOf(content, utf8)) return content;

    // The editor's Replace All loop over a Document holding the text, so
    // anchors, lookbehind and multi-line matches see the replaced text exactly
    // as they would in a tab.
    NppSearch::BufferSearch search(s.hasWordChars ? s.wordChars.c_str() : nullptr);
    search.SetSearch(s.needle, s.flags, s.replacement, s.regexReplace);
    search.SetText(utf8.data(), utf8.size());
    const NppSearch::Pos count = NppSearch::ReplaceAll(search, 0, search.Length());
    // A search that fails part way (Boost's complexity limit) ends the loop
    // like "no more matches". Return nothing rather than a partly replaced
    // text, as Windows stops a Replace All on the error.
    if (search.LastStatus() != NppSearch::Status::Ok) {
        if (regexError) *regexError = regexErrorOf(search);
        return content;
    }
    if (count <= 0) return content;

    const std::string out = search.Text();
    NSString *replaced = [[NSString alloc] initWithBytes:out.data() length:out.size()
                                                encoding:NSUTF8StringEncoding];
    if (!replaced) return content;
    if (replacementCount) *replacementCount = (NSInteger)count;
    return replaced;
}

#pragma mark - File decoding

/// Read and decode a file for Find/Replace in Files. Used to be a UTF-8-only
/// read, which silently skipped every Windows-1252 / Latin-1 / UTF-16 / CJK
/// file. Now uses the editor's detection rules (NppTextEncoding) so anything
/// that opens as text in a tab is searchable. Binary files (non-Unicode bytes
/// with a NUL) are still skipped. Returns nil when the file can't be read.
+ (nullable NSString *)_decodedContentsOfFile:(NSString *)path
                                     encoding:(nullable NSStringEncoding *)encoding
                                       hasBOM:(nullable BOOL *)hasBOM
                                      rawData:(NSData * _Nullable * _Nullable)rawData {
    // Plain read, not mapped: Find in Files walks arbitrary trees, and a file
    // truncated by another process (log rotation) under a mapping is a SIGBUS.
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if (!data) return nil;
    if (rawData) *rawData = data;
    return NppDecodeTextData(data, YES, encoding, hasBOM);
}

#pragma mark - Replace in File

+ (NPPReplaceFileStatus)replaceAllInFile:(NSString *)path
                                 options:(NPPFindOptions *)opts
                        replacementCount:(NSInteger *)replacementCount
                                encoding:(nullable NSStringEncoding *)encodingOut
                       isOpenAndModified:(nullable BOOL (^)(NSString *path))isOpenAndModified
                                   error:(NSError **)error {
    if (replacementCount) *replacementCount = 0;
    // Remember size, mtime and inode from before the read; checked again at
    // commit time (see below). Work on the symlink target so the check and
    // the final rename apply to the real file, not the link.
    NSString *target = [path stringByResolvingSymlinksInPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrsBefore = [fm attributesOfItemAtPath:target error:nil];
    NSStringEncoding enc = NSUTF8StringEncoding;
    BOOL hasBOM = NO;
    NSData *original = nil;
    NSString *content = [self _decodedContentsOfFile:path encoding:&enc hasBOM:&hasBOM rawData:&original];
    if (encodingOut) *encodingOut = enc;
    if (!content) return NPPReplaceFileUnreadable;

    NSInteger count = 0;
    NSString *regexError = nil;
    NSString *replaced = [self stringByReplacingAllInString:content
                                                    options:opts
                                           replacementCount:&count
                                                 regexError:&regexError];
    if (regexError) return NPPReplaceFileRegexFailed;
    // A replacement can be a no-op ("foo" -> "foo", regex (foo) -> \1).
    // Comparing the text as well as the count keeps those files from being
    // rewritten, which would bump their mtime for no reason.
    if (count <= 0 || [replaced isEqualToString:content]) return NPPReplaceFileUnchanged;

    // Write back in the file's own encoding + BOM, never lossily. Two guards:
    //  1. The untouched text must re-encode to the exact original bytes. If it
    //     doesn't, the decode itself was not clean (odd-length UTF-16, a
    //     doubled BOM, a detector guess that doesn't round-trip) and a rewrite
    //     would change bytes outside the matches.
    //  2. The replaced text must be fully representable (e.g. typing a CJK
    //     character into a Windows-1252 file). NppEncodeTextData refuses to
    //     substitute, so nil means "would lose data".
    NSData *roundTrip = NppEncodeTextData(content, enc, hasBOM);
    if (!roundTrip || ![roundTrip isEqualToData:original])
        return NPPReplaceFileDecodeNotClean;
    NSData *out = NppEncodeTextData(replaced, enc, hasBOM);
    if (!out) return NPPReplaceFileUnrepresentable;

    if (!attrsBefore) return NPPReplaceFileChangedOnDisk;

    // Replace runs off the main thread, so the user may save this file from
    // an editor tab while we work. A check-then-write is not enough: an
    // atomic write creates its temp file and renames *after* the check, and
    // a save landing in between is overwritten. So stage the new bytes in a
    // temp file next to the original first, then validate and rename as one
    // step on the main thread. Editor saves run on the main thread too, so
    // none can interleave with the commit.
    NSString *staged = [self _stageReplacement:out forFile:target
                                    permissions:(mode_t)attrsBefore.filePosixPermissions
                                          error:error];
    if (!staged) return NPPReplaceFileWriteFailed;

    __block NPPReplaceFileStatus status = NPPReplaceFileReplaced;
    __block NSError *commitError = nil;
    void (^commit)(void) = ^{
        if (isOpenAndModified && isOpenAndModified(path)) {
            status = NPPReplaceFileOpenModified;
            return;
        }
        // Size + mtime + inode: an editor's atomic save swaps the inode even
        // when size and mtime happen to match.
        NSDictionary *attrsNow = [fm attributesOfItemAtPath:target error:nil];
        if (!attrsNow
            || ![attrsBefore.fileModificationDate isEqualToDate:attrsNow.fileModificationDate]
            || attrsBefore.fileSize != attrsNow.fileSize
            || attrsBefore.fileSystemFileNumber != attrsNow.fileSystemFileNumber) {
            status = NPPReplaceFileChangedOnDisk;
            return;
        }
        if (rename(staged.fileSystemRepresentation, target.fileSystemRepresentation) != 0) {
            commitError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            status = NPPReplaceFileWriteFailed;
        }
    };
    if ([NSThread isMainThread]) commit();
    else dispatch_sync(dispatch_get_main_queue(), commit);

    if (status != NPPReplaceFileReplaced) {
        unlink(staged.fileSystemRepresentation);
        if (error && commitError) *error = commitError;
        return status;
    }
    if (replacementCount) *replacementCount = count;
    return NPPReplaceFileReplaced;
}

/// Write `data` to a new temp file in the same directory as `file` (same
/// volume, so the later rename is atomic), with the original file's
/// permission bits. Returns the temp path, or nil with *error set.
+ (nullable NSString *)_stageReplacement:(NSData *)data
                                 forFile:(NSString *)file
                             permissions:(mode_t)permissions
                                   error:(NSError **)error {
    NSString *templ = [[file stringByDeletingLastPathComponent] stringByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.npp-replace-XXXXXX", file.lastPathComponent]];
    char *buf = strdup(templ.fileSystemRepresentation);
    int fd = mkstemp(buf);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        free(buf);
        return nil;
    }
    NSString *staged = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:buf
                                                                                  length:strlen(buf)];
    free(buf);
    BOOL ok = YES;
    const uint8_t *p = (const uint8_t *)data.bytes;
    NSUInteger left = data.length;
    while (ok && left > 0) {
        ssize_t n = write(fd, p, left);
        if (n < 0) { if (errno == EINTR) continue; ok = NO; break; }
        p += n;
        left -= (NSUInteger)n;
    }
    if (ok && fchmod(fd, permissions & 07777) != 0) ok = NO;
    if (ok && fsync(fd) != 0) ok = NO;
    int savedErrno = errno;
    if (close(fd) != 0 && ok) { ok = NO; savedErrno = errno; }
    if (!ok) {
        unlink(staged.fileSystemRepresentation);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:savedErrno userInfo:nil];
        return nil;
    }
    return staged;
}

#pragma mark - Find in Files

/// File-name filter predicates for opts.filters ("*.c *.h", "*.txt, *.md").
+ (NSArray<NSPredicate *> *)_filterPredicatesForOptions:(NPPFindOptions *)opts {
    NSArray<NSString *> *globs = [opts.filters componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@", "]];
    NSMutableArray<NSPredicate *> *preds = [NSMutableArray array];
    for (NSString *g in globs) {
        NSString *t = [g stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [preds addObject:[NSPredicate predicateWithFormat:@"SELF LIKE[c] %@", t]];
    }
    return preds;
}

+ (BOOL)_name:(NSString *)name passesFilters:(NSArray<NSPredicate *> *)preds {
    if (preds.count == 0) return YES;
    for (NSPredicate *p in preds)
        if ([p evaluateWithObject:name]) return YES;
    return NO;
}

/// Search one file. Returns its results, or nil when it has no hits or can't
/// be read (binary, undecodable). Sets *regexError if the regex failed.
+ (nullable NPPFileResults *)_searchFile:(NSString *)full
                                 search:(NppSearch::BufferSearch &)search
                            cancelToken:(nullable NPPCancelToken *)cancelToken
                             regexError:(NSString * _Nullable * _Nonnull)regexError {
    // Read file with the editor's encoding detection (skips binaries). An
    // empty file decodes to "" and is searched: ^$ matches it once.
    NSString *content = [self _decodedContentsOfFile:full encoding:NULL hasBOM:NULL rawData:NULL];
    if (!content) return nil;

    std::string utf8;
    utf8BytesOf(content, utf8);
    content = nil;
    search.SetText(utf8.data(), utf8.size());

    NSMutableArray<NPPSearchResult *> *lines = [NSMutableArray array];
    const CollectResult collected = collectHits(search, utf8, full, cancelToken, lines);
    if (collected == CollectResult::RegexFailed)
        *regexError = regexErrorOf(search);
    // Free the file's text now rather than when the next file replaces it.
    search.SetText("", 0);
    if (collected == CollectResult::RegexFailed || !lines.count) return nil;

    NPPFileResults *fileRes = [[NPPFileResults alloc] init];
    fileRes.filePath = full;
    [fileRes.results addObjectsFromArray:lines];
    return fileRes;
}

/// Shared driver for Find in Files and Find in Projects. nextPath returns the
/// next file to search (already filtered), or nil when done.
+ (NSArray<NPPFileResults *> *)_findInFiles:(NSString * _Nullable (^)(void))nextPath
                                    options:(NPPFindOptions *)opts
                              progressBlock:(nullable void(^)(NSString *currentFile, NSInteger hits))progressBlock
                                cancelToken:(nullable NPPCancelToken *)cancelToken
                          totalFilesScanned:(nullable NSInteger *)totalFilesScanned
                                 regexError:(NSString * _Nullable * _Nullable)regexErrorOut {
    NSMutableArray<NPPFileResults *> *allResults = [NSMutableArray array];
    if (totalFilesScanned) *totalFilesScanned = 0;
    if (regexErrorOut) *regexErrorOut = nil;
    NPPSearchSetup s = setupForOptions(opts);
    if (s.needle.empty()) return allResults;
    // An invalid regex matches nothing anywhere; don't walk the tree for it.
    NSString *patternError = [self patternErrorForOptions:opts];
    if (patternError) {
        if (regexErrorOut) *regexErrorOut = patternError;
        return allResults;
    }

    // One Document for the whole run, so the regex is compiled once.
    NppSearch::BufferSearch search(s.hasWordChars ? s.wordChars.c_str() : nullptr);
    search.SetSearch(s.needle, s.flags, s.replacement, s.regexReplace);

    NSInteger totalHits = 0;
    NSInteger filesScanned = 0;
    NSString *regexError = nil;
    while (!cancelToken.isCancelled && !regexError) {
        // Per-file pool: decoding a non-UTF-8 file (charset detector, NSString
        // conversions) leaves autoreleased temporaries several times the file
        // size. Without a pool they pile up for the whole run.
        @autoreleasepool {
            NSString *full = nextPath();
            if (!full) break;
            filesScanned++;
            NPPFileResults *fileRes = [self _searchFile:full search:search cancelToken:cancelToken
                                             regexError:&regexError];
            if (!fileRes) continue;
            totalHits += fileRes.hitCount;
            [allResults addObject:fileRes];
            if (progressBlock) {
                NSInteger h = totalHits;
                dispatch_async(dispatch_get_main_queue(), ^{
                    progressBlock(full, h);
                });
            }
        }
    }
    if (totalFilesScanned) *totalFilesScanned = filesScanned;
    if (regexError) {
        // As on Windows: the run stops on the error, with no partial results.
        if (regexErrorOut) *regexErrorOut = regexError;
        return @[];
    }
    return allResults;
}

+ (NSArray<NPPFileResults *> *)findInDirectory:(NSString *)directory
                                       options:(NPPFindOptions *)opts
                                 progressBlock:(nullable void(^)(NSString *currentFile, NSInteger hits))progressBlock
                                   cancelToken:(nullable NPPCancelToken *)cancelToken
                            totalFilesScanned:(nullable NSInteger *)totalFilesScanned
                                   regexError:(NSString * _Nullable * _Nullable)regexError {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:directory];
    NSArray<NSPredicate *> *preds = [self _filterPredicatesForOptions:opts];
    const BOOL skipHidden = !opts.isInHiddenDirs;

    NSString * _Nullable (^nextPath)(void) = ^NSString * _Nullable {
        NSString *rel;
        while ((rel = [en nextObject])) {
            if (cancelToken.isCancelled) return nil;
            NSString *name = rel.lastPathComponent;
            NSString *full = [directory stringByAppendingPathComponent:rel];
            BOOL isDir = NO;
            [fm fileExistsAtPath:full isDirectory:&isDir];
            if (isDir) {
                // Skip hidden directories, and every subdirectory unless
                // "In all sub-folders" is on (#317).
                if (!opts.isRecursive || (skipHidden && [name hasPrefix:@"."])) [en skipDescendants];
                continue;
            }
            // Skip hidden files
            if (skipHidden && [name hasPrefix:@"."]) continue;
            if (![self _name:name passesFilters:preds]) continue;
            return full;
        }
        return nil;
    };
    return [self _findInFiles:nextPath options:opts progressBlock:progressBlock
                  cancelToken:cancelToken totalFilesScanned:totalFilesScanned
                   regexError:regexError];
}

+ (NSArray<NPPFileResults *> *)findInFilePaths:(NSArray<NSString *> *)filePaths
                                       options:(NPPFindOptions *)opts
                                 progressBlock:(nullable void(^)(NSString *currentFile, NSInteger hits))progressBlock
                                   cancelToken:(nullable NPPCancelToken *)cancelToken
                            totalFilesScanned:(nullable NSInteger *)totalFilesScanned
                                   regexError:(NSString * _Nullable * _Nullable)regexError {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSPredicate *> *preds = [self _filterPredicatesForOptions:opts];
    __block NSUInteger index = 0;

    NSString * _Nullable (^nextPath)(void) = ^NSString * _Nullable {
        while (index < filePaths.count) {
            NSString *full = filePaths[index++];
            if (![fm fileExistsAtPath:full]) continue;
            if (![self _name:full.lastPathComponent passesFilters:preds]) continue;
            return full;
        }
        return nil;
    };
    return [self _findInFiles:nextPath options:opts progressBlock:progressBlock
                  cancelToken:cancelToken totalFilesScanned:totalFilesScanned
                   regexError:regexError];
}

@end
