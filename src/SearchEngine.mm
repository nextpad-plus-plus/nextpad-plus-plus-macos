#import "SearchEngine.h"
#import "Scintilla.h"
#include <string>
#include <vector>
#include "../regex/NppSearchLoops.h"

namespace {

/// The shared search loops (regex/NppSearchLoops.h) driving a ScintillaView
/// through its target: SCI_SEARCHINTARGET and SCI_REPLACETARGET(RE). Find in
/// Files runs the same loops over a headless Document (NppBufferSearch).
class ViewTarget final : public NppSearch::Target {
public:
    ViewTarget(ScintillaView *sci, const char *needle, const char *replacement, bool regexReplace)
        : _sci(sci), _needle(needle), _needleLength(strlen(needle)),
          _replacement(replacement ?: ""), _regexReplace(regexReplace) {}

    NppSearch::Pos Find(NppSearch::Pos start, NppSearch::Pos end, NppSearch::Pos *matchEnd) override {
        [_sci message:SCI_SETTARGETRANGE wParam:(uptr_t)start lParam:end];
        const sptr_t found = [_sci message:SCI_SEARCHINTARGET wParam:_needleLength lParam:(sptr_t)_needle];
        if (found < 0) {
            // The Boost backend returns -2 for a regex_error (bad pattern, or
            // its complexity limit while matching) and -3 for other failures.
            if (found <= -2) failed = true;
            return -1;
        }
        *matchEnd = [_sci message:SCI_GETTARGETEND];
        return found;
    }

    NppSearch::Pos Replace(NppSearch::Pos start, NppSearch::Pos end) override {
        [_sci message:SCI_SETTARGETRANGE wParam:(uptr_t)start lParam:end];
        return [_sci message:(_regexReplace ? SCI_REPLACETARGETRE : SCI_REPLACETARGET)
                      wParam:(uptr_t)-1 lParam:(sptr_t)_replacement];
    }

    /// The regex failed (rather than simply not matching) at some Find.
    bool failed = false;

private:
    __unsafe_unretained ScintillaView *_sci;
    const char *_needle;
    size_t _needleLength;
    const char *_replacement;
    bool _regexReplace;
};

} // namespace

@implementation SearchEngine

// The variants without regexFailed: (macro playback, menu Find Next) treat a
// failed regex like "not found".
+ (BOOL)findInView:(ScintillaView *)sci options:(NPPFindOptions *)opts forward:(BOOL)forward {
    return [self findInView:sci options:opts forward:forward regexFailed:NULL];
}
+ (BOOL)replaceInView:(ScintillaView *)sci options:(NPPFindOptions *)opts {
    return [self replaceInView:sci options:opts regexFailed:NULL];
}
+ (NSInteger)replaceAllInView:(ScintillaView *)sci options:(NPPFindOptions *)opts {
    return [self replaceAllInView:sci options:opts regexFailed:NULL];
}
+ (NSInteger)countInView:(ScintillaView *)sci options:(NPPFindOptions *)opts {
    return [self countInView:sci options:opts regexFailed:NULL];
}
+ (NSArray<NPPSearchResult *> *)findAllInView:(ScintillaView *)sci
                                     filePath:(NSString *)path
                                      options:(NPPFindOptions *)opts {
    return [self findAllInView:sci filePath:path options:opts regexFailed:NULL];
}
+ (NSInteger)markAllInView:(ScintillaView *)sci options:(NPPFindOptions *)opts {
    return [self markAllInView:sci options:opts regexFailed:NULL];
}

/// Prepare the search needle, applying Extended expansion if needed. Returns UTF8 C string.
+ (const char *)preparedNeedle:(NPPFindOptions *)opts {
    NSString *text = opts.searchText;
    if (opts.searchType == NPPSearchExtended)
        text = [self expandExtendedString:text];
    return text.UTF8String;
}

/// The Replace with text as passed to SCI_REPLACETARGET(RE).
+ (const char *)preparedReplacement:(NPPFindOptions *)opts {
    NSString *replaceText = opts.replaceText ?: @"";
    if (opts.searchType == NPPSearchExtended)
        replaceText = [self expandExtendedString:replaceText];
    return replaceText.UTF8String;
}

+ (NSString *)wordCharsOfView:(ScintillaView *)sci {
    const sptr_t length = [sci message:SCI_GETWORDCHARS wParam:0 lParam:0];
    if (length <= 0) return @"";
    std::string chars((size_t)length + 1, '\0');
    [sci message:SCI_GETWORDCHARS wParam:0 lParam:(sptr_t)chars.data()];
    chars.resize((size_t)length);
    // Bytes, not text: Latin-1 keeps each one as one character.
    return [[NSString alloc] initWithBytes:chars.data() length:chars.size()
                                  encoding:NSISOLatin1StringEncoding] ?: @"";
}

#pragma mark - Find

+ (BOOL)findInView:(ScintillaView *)sci options:(NPPFindOptions *)opts forward:(BOOL)forward
       regexFailed:(nullable BOOL *)regexFailed {
    if (regexFailed) *regexFailed = NO;
    if (!opts.searchText.length) return NO;

    const char *needle = [self preparedNeedle:opts];
    size_t needleLen = strlen(needle);
    int flags = [self findNextFlagsForOptions:opts];

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
    if (found <= -2) {
        if (regexFailed) *regexFailed = YES;
        return NO;
    }

    // Wrap around if not found and option is on
    if (found < 0 && opts.wrapAround) {
        if (forward) {
            [sci message:SCI_SETTARGETRANGE wParam:0 lParam:searchStart];
        } else {
            [sci message:SCI_SETTARGETRANGE wParam:docLen lParam:searchEnd];
        }
        found = [sci message:SCI_SEARCHINTARGET wParam:needleLen lParam:(sptr_t)needle];
        if (found <= -2) {
            if (regexFailed) *regexFailed = YES;
            return NO;
        }
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

+ (BOOL)replaceInView:(ScintillaView *)sci options:(NPPFindOptions *)opts
          regexFailed:(nullable BOOL *)regexFailed {
    if (regexFailed) *regexFailed = NO;
    if (!opts.searchText.length) return NO;

    const char *needle = [self preparedNeedle:opts];
    // Selection-match probe: the selection IS what the user picked to replace
    // — allow empty match exactly at its start so e.g. `$` matches a previously
    // found end-of-line selection. The follow-up Find Next then uses the
    // FindNext flag set (no ALLOWATSTART, so the freshly-replaced position
    // doesn't trigger another zero-width match at the same byte).
    int flags = [self findForReplaceFlagsForOptions:opts];

    // Check if current selection matches
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];

    if (selStart != selEnd) {
        [sci message:SCI_SETSEARCHFLAGS wParam:(uptr_t)flags];
        [sci message:SCI_SETTARGETRANGE wParam:(uptr_t)selStart lParam:selEnd];
        sptr_t found = [sci message:SCI_SEARCHINTARGET wParam:strlen(needle) lParam:(sptr_t)needle];
        if (found <= -2) {
            if (regexFailed) *regexFailed = YES;
            return NO;
        }

        if (found >= 0 && [sci message:SCI_GETTARGETSTART] == selStart &&
            [sci message:SCI_GETTARGETEND] == selEnd) {
            // Current selection matches — replace it
            const char *replacement = [self preparedReplacement:opts];

            if (opts.searchType == NPPSearchRegex)
                [sci message:SCI_REPLACETARGETRE wParam:(uptr_t)-1 lParam:(sptr_t)replacement];
            else
                [sci message:SCI_REPLACETARGET wParam:(uptr_t)-1 lParam:(sptr_t)replacement];
        }
    }

    // Find next
    return [self findInView:sci options:opts forward:(opts.direction == NPPSearchDown)
                regexFailed:regexFailed];
}

#pragma mark - Replace All

+ (NSInteger)replaceAllInView:(ScintillaView *)sci options:(NPPFindOptions *)opts
                 regexFailed:(nullable BOOL *)regexFailed {
    if (regexFailed) *regexFailed = NO;
    if (!opts.searchText.length) return 0;

    const char *needle = [self preparedNeedle:opts];
    // Loop semantics — see Windows FindReplaceDlg.cpp:3461. NOTAFTERMATCH
    // rejects zero-width matches at the continuation position, the fix for
    // issue #151 ($ → X freezing on docs ending with \n).
    int flags = [self loopFlagsForOptions:opts];
    const char *replacement = [self preparedReplacement:opts];

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

    ViewTarget target(sci, needle, replacement, opts.searchType == NPPSearchRegex);
    NSInteger count = (NSInteger)NppSearch::ReplaceAll(target, rangeStart, rangeEnd);

    [sci message:SCI_ENDUNDOACTION];
    // As on Windows, replacements made before the failure stay (one undo step).
    if (regexFailed) *regexFailed = target.failed;
    return count;
}

#pragma mark - Count

+ (NSInteger)countInView:(ScintillaView *)sci options:(NPPFindOptions *)opts
            regexFailed:(nullable BOOL *)regexFailed {
    if (regexFailed) *regexFailed = NO;
    if (!opts.searchText.length) return 0;

    const char *needle = [self preparedNeedle:opts];
    [sci message:SCI_SETSEARCHFLAGS wParam:(uptr_t)[self loopFlagsForOptions:opts]];

    ViewTarget target(sci, needle, nullptr, false);
    NSInteger count = (NSInteger)NppSearch::ForEachMatch(target, 0, [sci message:SCI_GETLENGTH],
        [](NppSearch::Pos, NppSearch::Pos) { return true; });
    if (regexFailed) *regexFailed = target.failed;
    return count;
}

#pragma mark - Find All

+ (NSArray<NPPSearchResult *> *)findAllInView:(ScintillaView *)sci
                                     filePath:(NSString *)path
                                      options:(NPPFindOptions *)opts
                                  regexFailed:(nullable BOOL *)regexFailed {
    if (regexFailed) *regexFailed = NO;
    if (!opts.searchText.length) return @[];

    const char *needle = [self preparedNeedle:opts];
    [sci message:SCI_SETSEARCHFLAGS wParam:(uptr_t)[self loopFlagsForOptions:opts]];

    NSMutableArray<NPPSearchResult *> *results = [NSMutableArray array];
    ViewTarget target(sci, needle, nullptr, false);
    std::vector<char> lineBuf;
    sptr_t cachedLine = -1;
    sptr_t lineStart = 0, lineEnd = 0;
    NppSearch::ForEachMatch(target, 0, [sci message:SCI_GETLENGTH],
        [&](NppSearch::Pos found, NppSearch::Pos end) {
            sptr_t line = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)found];
            if (line != cachedLine) {
                cachedLine = line;
                lineStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)line];
                lineEnd   = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)line];
                lineBuf.assign((size_t)(lineEnd - lineStart) + 1, '\0');
                struct Sci_TextRangeFull tr;
                tr.chrg.cpMin = lineStart;
                tr.chrg.cpMax = lineEnd;
                tr.lpstrText  = lineBuf.data();
                [sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&tr];
            }
            [self appendHitToResults:results
                            filePath:path
                          lineNumber:line + 1   // 1-based
                           lineBytes:lineBuf.data()
                          lineLength:(NSUInteger)(lineEnd - lineStart)
                            hitStart:(NSUInteger)(found - lineStart)
                              hitEnd:(NSUInteger)(end - lineStart)];
            return true;
        });
    if (target.failed) {
        // No silently truncated list.
        if (regexFailed) *regexFailed = YES;
        return @[];
    }
    return results;
}

#pragma mark - Mark All

+ (NSInteger)markAllInView:(ScintillaView *)sci options:(NPPFindOptions *)opts
             regexFailed:(nullable BOOL *)regexFailed {
    if (regexFailed) *regexFailed = NO;
    if (!opts.searchText.length) return 0;

    const char *needle = [self preparedNeedle:opts];
    int flags = [self loopFlagsForOptions:opts];

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

    const BOOL bookmark = opts.doBookmarkLine;
    ViewTarget target(sci, needle, nullptr, false);
    NSInteger count = (NSInteger)NppSearch::ForEachMatch(target, 0, [sci message:SCI_GETLENGTH],
        [&](NppSearch::Pos found, NppSearch::Pos end) {
            [sci message:SCI_INDICATORFILLRANGE wParam:(uptr_t)found lParam:end - found];
            if (bookmark) {
                sptr_t line = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)found];
                [sci message:SCI_MARKERADD wParam:(uptr_t)line lParam:20]; // bookmark marker
            }
            return true;
        });
    if (regexFailed) *regexFailed = target.failed;
    return count;
}

@end
