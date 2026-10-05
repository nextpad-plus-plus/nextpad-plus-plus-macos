// SPDX-License-Identifier: MIT
//
// Headless tests for Find/Replace in Files and Find in Projects (SearchCore.mm
// + NppTextEncoding.mm) on a temporary tree. No AppKit, no app launch: the
// tree lives in a fresh directory under NSTemporaryDirectory() and is deleted
// afterwards. The app's defaults domain is never touched.
//
// Run with ctest (see CMakeLists.txt). Exits non-zero on any failure.

#import <Foundation/Foundation.h>
#include <sys/stat.h>
#import "SearchCore.h"
#import "NppTextEncoding.h"

// NppTextEncoding.mm reads the large-file preference through these keys
// (defined by PreferencesWindowController.mm in the app). Test-only names, so
// the lookup finds nothing and the default (no large-file limit) applies.
extern NSString *const kPrefLargeFileEnabled;
extern NSString *const kPrefLargeFileSizeMB;
NSString *const kPrefLargeFileEnabled = @"nppHeadlessTest.largeFileEnabled";
NSString *const kPrefLargeFileSizeMB  = @"nppHeadlessTest.largeFileSizeMB";

static int g_fail = 0;

static void check(NSString *label, BOOL cond, NSString *detail = @"") {
    printf("[%s] %s %s\n", cond ? "PASS" : "FAIL", label.UTF8String, detail.UTF8String);
    if (!cond) g_fail++;
}

static NSString *g_root;

static NSString *pathFor(NSString *rel) {
    return [g_root stringByAppendingPathComponent:rel];
}

static void writeData(NSString *rel, NSData *data) {
    NSString *full = pathFor(rel);
    [[NSFileManager defaultManager] createDirectoryAtPath:full.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:full atomically:NO];
}

static NSData *bytes(const char *s, size_t n) {
    return [NSData dataWithBytes:s length:n];
}

static NSData *withBOM(NSData *bom, NSData *body) {
    NSMutableData *d = [bom mutableCopy];
    [d appendData:body];
    return d;
}

static NSData *readFile(NSString *rel) {
    return [NSData dataWithContentsOfFile:pathFor(rel)];
}

static NPPFindOptions *options(NSString *search, NPPSearchType type) {
    NPPFindOptions *o = [[NPPFindOptions alloc] init];
    o.searchText = search;
    o.searchType = type;
    o.matchCase = YES;
    o.filters = @"*.*";
    o.isRecursive = YES;
    return o;
}

static NPPFileResults *resultsFor(NSArray<NPPFileResults *> *all, NSString *rel) {
    NSString *full = pathFor(rel);
    for (NPPFileResults *fr in all)
        if ([fr.filePath isEqualToString:full]) return fr;
    return nil;
}

static NSArray<NPPFileResults *> *findInTree(NPPFindOptions *o, NSInteger *scanned = NULL) {
    return [NPPSearchCore findInDirectory:g_root options:o progressBlock:nil
                              cancelToken:nil totalFilesScanned:scanned regexError:NULL];
}

static NSString *describe(NPPFileResults *fr) {
    if (!fr) return @"<no results>";
    NSMutableString *s = [NSMutableString string];
    for (NPPSearchResult *r in fr.results) {
        [s appendFormat:@"L%ld:", (long)r.lineNumber];
        for (NSValue *v in r.matchRanges) [s appendFormat:@"%@", NSStringFromRange(v.rangeValue)];
        [s appendString:@" "];
    }
    return s;
}

static NSData *shiftJIS(NSString *s) {
    return [s dataUsingEncoding:NSShiftJISStringEncoding];
}

static NSData *utf16(NSString *s, NSStringEncoding enc) {
    return [s dataUsingEncoding:enc];
}

static void buildTree() {
    const uint8_t bom8[] = {0xEF, 0xBB, 0xBF};
    const uint8_t bomLE[] = {0xFF, 0xFE};
    const uint8_t bomBE[] = {0xFE, 0xFF};

    // UTF-8: two hits on line 2, a non-ASCII prefix on line 1.
    writeData(@"utf8.txt", [@"café foo\nbar foo foo\nlast line\n" dataUsingEncoding:NSUTF8StringEncoding]);
    // UTF-8 with BOM and CRLF.
    writeData(@"utf8bom.txt", withBOM(bytes((const char *)bom8, 3),
                                      [@"foo\r\nfoo bar\r\n" dataUsingEncoding:NSUTF8StringEncoding]));
    // UTF-16 LE / BE with BOM.
    writeData(@"utf16le.txt", withBOM(bytes((const char *)bomLE, 2),
                                      utf16(@"日本 foo\nfoo\n", NSUTF16LittleEndianStringEncoding)));
    writeData(@"utf16be.txt", withBOM(bytes((const char *)bomBE, 2),
                                      utf16(@"日本 foo\nfoo\n", NSUTF16BigEndianStringEncoding)));
    // Windows-1252: "café € foo".
    writeData(@"cp1252.txt", bytes("caf\xE9 \x80 foo\n", 11));
    // Shift-JIS: enough Japanese for the charset detector.
    NSString *ja = @"これは日本語のテキストです。検索と置換のテストを行います。foo\n"
                   @"日本語の文章をもう一行書きます。漢字とひらがなとカタカナ。\n";
    writeData(@"sjis.txt", shiftJIS(ja));
    // Binary: NULs and the needle. Must be skipped.
    writeData(@"binary.bin", bytes("\x00\x01\x02 foo \x00\xFF\xFE\x00", 12));
    // Nested, hidden and filtered files.
    writeData(@"sub/nested.md", [@"foo in a subfolder\n" dataUsingEncoding:NSUTF8StringEncoding]);
    writeData(@".hidden/secret.txt", [@"foo hidden\n" dataUsingEncoding:NSUTF8StringEncoding]);
    // Multi-line patterns, lookbehind, \K.
    writeData(@"code.c", [@"int main() {\n    return 0;\n}\nprice: 42 EUR\nkey=value\n"
                          dataUsingEncoding:NSUTF8StringEncoding]);
    // Classic Mac line ends.
    writeData(@"cr.txt", [@"one\rtwo foo\rthree" dataUsingEncoding:NSUTF8StringEncoding]);
}

int main() {
    @autoreleasepool {
        NSString *tmpl = [NSTemporaryDirectory() stringByAppendingPathComponent:@"npp-search-test-XXXXXX"];
        char buf[PATH_MAX];
        strlcpy(buf, tmpl.fileSystemRepresentation, sizeof buf);
        if (!mkdtemp(buf)) { perror("mkdtemp"); return 2; }
        g_root = [NSString stringWithUTF8String:buf];
        buildTree();

        // ---- Find in Files: encodings, multi-hit lines, binary skip ---------
        {
            NSInteger scanned = 0;
            NSArray<NPPFileResults *> *all = findInTree(options(@"foo", NPPSearchNormal), &scanned);

            NPPFileResults *fr = resultsFor(all, @"utf8.txt");
            check(@"utf8: 3 hits on 2 lines", fr.hitCount == 3 && fr.results.count == 2, describe(fr));
            NPPSearchResult *l1 = fr.results.firstObject;
            check(@"utf8: line 1 offset in UTF-16 units after 'café '",
                  l1.lineNumber == 1 && l1.matchStart == 5 && l1.matchLength == 3
                  && [l1.lineText isEqualToString:@"café foo"], describe(fr));
            NPPSearchResult *l2 = fr.results.count > 1 ? fr.results[1] : nil;
            check(@"utf8: line 2 listed once with both hits",
                  l2.lineNumber == 2 && l2.matchRanges.count == 2
                  && NSEqualRanges(l2.matchRanges[1].rangeValue, NSMakeRange(8, 3)), describe(fr));

            fr = resultsFor(all, @"utf8bom.txt");
            check(@"utf8 BOM + CRLF: 2 hits, line text has no CR",
                  fr.hitCount == 2 && [fr.results.firstObject.lineText isEqualToString:@"foo"], describe(fr));
            fr = resultsFor(all, @"utf16le.txt");
            check(@"utf16le: 2 hits, CJK line decoded",
                  fr.hitCount == 2 && [fr.results.firstObject.lineText isEqualToString:@"日本 foo"]
                  && fr.results.firstObject.matchStart == 3, describe(fr));
            fr = resultsFor(all, @"utf16be.txt");
            check(@"utf16be: 2 hits", fr.hitCount == 2, describe(fr));
            fr = resultsFor(all, @"cp1252.txt");
            check(@"windows-1252: hit, é and € decoded",
                  fr.hitCount == 1 && [fr.results.firstObject.lineText hasPrefix:@"café €"], describe(fr));
            fr = resultsFor(all, @"sjis.txt");
            check(@"shift-jis: hit, Japanese decoded",
                  fr.hitCount == 1 && [fr.results.firstObject.lineText hasPrefix:@"これは日本語"], describe(fr));
            check(@"binary file skipped", resultsFor(all, @"binary.bin") == nil);
            check(@"subfolder searched", resultsFor(all, @"sub/nested.md").hitCount == 1);
            check(@"hidden folder skipped", resultsFor(all, @".hidden/secret.txt") == nil);
            fr = resultsFor(all, @"cr.txt");
            check(@"CR-only line ends: hit on line 2", fr.results.firstObject.lineNumber == 2, describe(fr));
            check(@"files scanned excludes hidden", scanned == 10,
                  [NSString stringWithFormat:@"scanned=%ld", (long)scanned]);

            NPPFindOptions *o = options(@"foo", NPPSearchNormal);
            o.isInHiddenDirs = YES;
            check(@"hidden folder searched when asked", resultsFor(findInTree(o), @".hidden/secret.txt") != nil);
            o = options(@"foo", NPPSearchNormal);
            o.isRecursive = NO;
            check(@"not recursive: subfolder skipped", resultsFor(findInTree(o), @"sub/nested.md") == nil);
            o = options(@"foo", NPPSearchNormal);
            o.filters = @"*.md *.c";
            all = findInTree(o);
            check(@"filters: only *.md", all.count == 1 && resultsFor(all, @"sub/nested.md") != nil);
        }

        // ---- Match case, whole word, extended -----------------------------------
        {
            NPPFindOptions *o = options(@"FOO", NPPSearchNormal);
            check(@"match case: FOO finds nothing", findInTree(o).count == 0);
            o.matchCase = NO;
            check(@"case-insensitive: FOO finds utf8.txt", resultsFor(findInTree(o), @"utf8.txt").hitCount == 3);

            o = options(@"main", NPPSearchNormal);
            o.wholeWord = YES;
            check(@"whole word", resultsFor(findInTree(o), @"code.c").hitCount == 1);
            o = options(@"mai", NPPSearchNormal);
            o.wholeWord = YES;
            check(@"whole word rejects a word prefix", resultsFor(findInTree(o), @"code.c") == nil);

            o = options(@"foo\\nbar", NPPSearchExtended);
            NPPFileResults *fr = resultsFor(findInTree(o), @"utf8.txt");
            check(@"extended \\n spans lines", fr.hitCount == 1 && fr.results.firstObject.lineNumber == 1
                  && fr.results.firstObject.matchLength == 3, describe(fr));
        }

        // ---- Regex: multi-line, lookbehind, \K, every hit -----------------------
        {
            NPPFindOptions *o = options(@"\\{\\n\\s+return", NPPSearchRegex);
            NPPFileResults *fr = resultsFor(findInTree(o), @"code.c");
            check(@"regex spans lines; hit cut at end of first line",
                  fr.hitCount == 1 && fr.results.firstObject.lineNumber == 1
                  && fr.results.firstObject.matchStart == 11 && fr.results.firstObject.matchLength == 1,
                  describe(fr));

            o = options(@"\\{.*\\}", NPPSearchRegex);
            check(@"'.' stops at line ends", resultsFor(findInTree(o), @"code.c") == nil);
            o.dotMatchesNewline = YES;
            check(@"'. matches newline' spans lines", resultsFor(findInTree(o), @"code.c").hitCount == 1);

            o = options(@"(?<=price: )\\d+", NPPSearchRegex);
            fr = resultsFor(findInTree(o), @"code.c");
            check(@"lookbehind", fr.hitCount == 1 && fr.results.firstObject.matchStart == 7
                  && fr.results.firstObject.matchLength == 2, describe(fr));
            o = options(@"key=\\K\\w+", NPPSearchRegex);
            fr = resultsFor(findInTree(o), @"code.c");
            check(@"\\K", fr.hitCount == 1 && fr.results.firstObject.matchStart == 4, describe(fr));

            o = options(@"o", NPPSearchRegex);
            fr = resultsFor(findInTree(o), @"utf8.txt");
            check(@"regex: every hit on a line, not just the first",
                  fr.hitCount == 6 && fr.results.count == 2, describe(fr));

            o = options(@"^", NPPSearchRegex);
            fr = resultsFor(findInTree(o), @"utf8bom.txt");
            check(@"empty matches: ^ once per line on CRLF", fr.hitCount == 3, describe(fr));

            o = options(@"(unclosed", NPPSearchRegex);
            check(@"invalid regex: error reported", [NPPSearchCore patternErrorForOptions:o] != nil);
            NSInteger scanned = -1;
            check(@"invalid regex: no results, no files walked", findInTree(o, &scanned).count == 0 && scanned == 0);
            check(@"valid regex: no error", [NPPSearchCore patternErrorForOptions:options(@"a+", NPPSearchRegex)] == nil);
        }

        // ---- Find in Projects (explicit paths) -----------------------------------
        {
            NSArray *paths = @[pathFor(@"utf8.txt"), pathFor(@"missing.txt"), pathFor(@"binary.bin"),
                               pathFor(@".hidden/secret.txt")];
            NSInteger scanned = 0;
            NSArray<NPPFileResults *> *all = [NPPSearchCore findInFilePaths:paths options:options(@"foo", NPPSearchNormal)
                                                             progressBlock:nil cancelToken:nil
                                                         totalFilesScanned:&scanned regexError:NULL];
            check(@"find in projects: listed files only, missing skipped",
                  all.count == 2 && scanned == 3, [NSString stringWithFormat:@"files=%lu scanned=%ld",
                                                    (unsigned long)all.count, (long)scanned]);
        }

        // ---- Cancel ---------------------------------------------------------------
        {
            NPPCancelToken *token = [[NPPCancelToken alloc] init];
            [token cancel];
            NSInteger scanned = -1;
            NSArray *all = [NPPSearchCore findInDirectory:g_root options:options(@"foo", NPPSearchNormal)
                                            progressBlock:nil cancelToken:token totalFilesScanned:&scanned regexError:NULL];
            check(@"cancelled before start: nothing scanned", all.count == 0 && scanned == 0);

            NSMutableString *big = [NSMutableString string];
            for (int i = 0; i < 5000; i++) [big appendString:@"hit\n"];
            NSArray *partial = [NPPSearchCore findAllInString:big filePath:@"big" options:options(@"hit", NPPSearchNormal)
                                                  cancelToken:token regexError:NULL];
            NSArray *full = [NPPSearchCore findAllInString:big filePath:@"big" options:options(@"hit", NPPSearchNormal)
                                               cancelToken:nil regexError:NULL];
            check(@"cancel is polled inside a large file", full.count == 5000 && partial.count < full.count,
                  [NSString stringWithFormat:@"partial=%lu full=%lu", (unsigned long)partial.count,
                                              (unsigned long)full.count]);
        }

        // ---- Replace in Files ------------------------------------------------------
        {
            NSInteger count = 0;
            NSStringEncoding enc = 0;
            NPPFindOptions *o = options(@"(\\w+)=(\\w+)", NPPSearchRegex);
            o.replaceText = @"${2}=$1 \\1";
            NPPReplaceFileStatus st = [NPPSearchCore replaceAllInFile:pathFor(@"code.c") options:o
                                                     replacementCount:&count encoding:&enc isOpenAndModified:nil error:nil];
            NSString *code = [[NSString alloc] initWithData:readFile(@"code.c") encoding:NSUTF8StringEncoding];
            check(@"regex replace: ${2}, $1 and \\1", st == NPPReplaceFileReplaced && count == 1
                  && [code hasSuffix:@"value=key key\n"], code);

            o = options(@"\\n", NPPSearchRegex);
            o.replaceText = @"|";
            st = [NPPSearchCore replaceAllInFile:pathFor(@"utf8.txt") options:o replacementCount:&count
                                        encoding:&enc isOpenAndModified:nil error:nil];
            code = [[NSString alloc] initWithData:readFile(@"utf8.txt") encoding:NSUTF8StringEncoding];
            check(@"regex replace of \\n joins lines (#360)", st == NPPReplaceFileReplaced && count == 3
                  && [code isEqualToString:@"café foo|bar foo foo|last line|"], code);

            // UTF-8 BOM + CRLF kept.
            o = options(@"foo$", NPPSearchRegex);
            o.replaceText = @"baz";
            [NPPSearchCore replaceAllInFile:pathFor(@"utf8bom.txt") options:o replacementCount:&count
                                   encoding:&enc isOpenAndModified:nil error:nil];
            check(@"utf8 BOM and CRLF preserved",
                  [readFile(@"utf8bom.txt") isEqualToData:withBOM(bytes("\xEF\xBB\xBF", 3),
                      [@"baz\r\nfoo bar\r\n" dataUsingEncoding:NSUTF8StringEncoding])]);

            // UTF-16 LE/BE written back in their encoding with BOM.
            o = options(@"foo", NPPSearchNormal);
            o.replaceText = @"ばー";
            [NPPSearchCore replaceAllInFile:pathFor(@"utf16le.txt") options:o replacementCount:&count
                                   encoding:&enc isOpenAndModified:nil error:nil];
            check(@"utf16le round trip", count == 2 && [readFile(@"utf16le.txt") isEqualToData:
                withBOM(bytes("\xFF\xFE", 2), utf16(@"日本 ばー\nばー\n", NSUTF16LittleEndianStringEncoding))]);
            [NPPSearchCore replaceAllInFile:pathFor(@"utf16be.txt") options:o replacementCount:&count
                                   encoding:&enc isOpenAndModified:nil error:nil];
            check(@"utf16be round trip", count == 2 && [readFile(@"utf16be.txt") isEqualToData:
                withBOM(bytes("\xFE\xFF", 2), utf16(@"日本 ばー\nばー\n", NSUTF16BigEndianStringEncoding))]);

            // Shift-JIS stays Shift-JIS.
            [NPPSearchCore replaceAllInFile:pathFor(@"sjis.txt") options:o replacementCount:&count
                                   encoding:&enc isOpenAndModified:nil error:nil];
            NSString *ja = [[NSString alloc] initWithData:readFile(@"sjis.txt") encoding:NSShiftJISStringEncoding];
            check(@"shift-jis round trip", count == 1 && [ja containsString:@"行います。ばー\n"], ja ?: @"<undecodable>");

            // Windows-1252: a representable replacement is written, an
            // unrepresentable one leaves the file untouched.
            NSData *before = readFile(@"cp1252.txt");
            st = [NPPSearchCore replaceAllInFile:pathFor(@"cp1252.txt") options:o replacementCount:&count
                                        encoding:&enc isOpenAndModified:nil error:nil];
            check(@"windows-1252: unrepresentable replacement refused, file untouched",
                  st == NPPReplaceFileUnrepresentable && [readFile(@"cp1252.txt") isEqualToData:before]);
            o.replaceText = @"bär";
            st = [NPPSearchCore replaceAllInFile:pathFor(@"cp1252.txt") options:o replacementCount:&count
                                        encoding:&enc isOpenAndModified:nil error:nil];
            check(@"windows-1252 round trip", st == NPPReplaceFileReplaced
                  && [readFile(@"cp1252.txt") isEqualToData:bytes("caf\xE9 \x80 b\xE4r\n", 11)]);

            // A no-op replacement does not rewrite the file.
            o = options(@"(sub)", NPPSearchRegex);
            o.replaceText = @"\\1";
            NSDate *mtime = [[NSFileManager defaultManager] attributesOfItemAtPath:pathFor(@"sub/nested.md")
                                                                             error:nil].fileModificationDate;
            st = [NPPSearchCore replaceAllInFile:pathFor(@"sub/nested.md") options:o replacementCount:&count
                                        encoding:&enc isOpenAndModified:nil error:nil];
            NSDate *after = [[NSFileManager defaultManager] attributesOfItemAtPath:pathFor(@"sub/nested.md")
                                                                             error:nil].fileModificationDate;
            check(@"no-op replacement leaves the file alone", st == NPPReplaceFileUnchanged
                  && [mtime isEqualToDate:after]);

            // Binary files are never written.
            NSData *bin = readFile(@"binary.bin");
            o = options(@"foo", NPPSearchNormal);
            o.replaceText = @"bar";
            st = [NPPSearchCore replaceAllInFile:pathFor(@"binary.bin") options:o replacementCount:&count
                                        encoding:&enc isOpenAndModified:nil error:nil];
            check(@"binary file not rewritten", st == NPPReplaceFileUnreadable && [readFile(@"binary.bin") isEqualToData:bin]);

            // A decode that does not reproduce the original bytes (doubled BOM)
            // is not rewritten.
            writeData(@"doublebom.txt", bytes("\xEF\xBB\xBF\xEF\xBB\xBF" "foo\n", 10));
            NSData *dbl = readFile(@"doublebom.txt");
            st = [NPPSearchCore replaceAllInFile:pathFor(@"doublebom.txt") options:o replacementCount:&count
                                        encoding:&enc isOpenAndModified:nil error:nil];
            check(@"file that does not round-trip is left untouched",
                  st != NPPReplaceFileReplaced && [readFile(@"doublebom.txt") isEqualToData:dbl],
                  [NSString stringWithFormat:@"status=%ld", (long)st]);

            // $ -> ; terminates and matches the editor (#151).
            o = options(@"$", NPPSearchRegex);
            o.replaceText = @";";
            NSString *r = [NPPSearchCore stringByReplacingAllInString:@"a\r\nb\r\n" options:o replacementCount:&count regexError:NULL];
            check(@"$ replace on CRLF text", [r isEqualToString:@"a;\r\nb;\r\n;"] && count == 3, r);

            // Extended mode replacement escapes.
            o = options(@",", NPPSearchExtended);
            o.replaceText = @"\\t";
            r = [NPPSearchCore stringByReplacingAllInString:@"a,b" options:o replacementCount:&count regexError:NULL];
            check(@"extended replacement \\t", [r isEqualToString:@"a\tb"], r);

            // Normal mode: replacement is literal.
            o = options(@"a.b", NPPSearchNormal);
            o.replaceText = @"$1\\n";
            r = [NPPSearchCore stringByReplacingAllInString:@"a.b axb" options:o replacementCount:&count regexError:NULL];
            check(@"normal replacement is literal", [r isEqualToString:@"$1\\n axb"] && count == 1, r);

            // Whole word with the editor's word characters.
            o = options(@"foo", NPPSearchNormal);
            o.wholeWord = YES;
            o.replaceText = @"X";
            r = [NPPSearchCore stringByReplacingAllInString:@"foo-bar foo" options:o replacementCount:&count regexError:NULL];
            check(@"whole word, default word chars", [r isEqualToString:@"X-bar X"], r);
            o.wordChars = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-";
            r = [NPPSearchCore stringByReplacingAllInString:@"foo-bar foo" options:o replacementCount:&count regexError:NULL];
            check(@"whole word, '-' as a word char", [r isEqualToString:@"foo-bar X"], r);
        }

        // ---- Replace in Files: staged write, checked commit ------------------------
        {
            NSFileManager *fm = [NSFileManager defaultManager];
            NPPFindOptions *o = options(@"old", NPPSearchNormal);
            o.replaceText = @"new";
            NSInteger count = 0;
            NSStringEncoding enc = 0;
            NSData *oldText = [@"old text\n" dataUsingEncoding:NSUTF8StringEncoding];
            NSData *newText = [@"new text\n" dataUsingEncoding:NSUTF8StringEncoding];

            // Saved elsewhere (new inode) between staging and commit.
            writeData(@"commit/swap.txt", oldText);
            NSData *saved = [@"saved in a tab\n" dataUsingEncoding:NSUTF8StringEncoding];
            NPPReplaceFileStatus st = [NPPSearchCore replaceAllInFile:pathFor(@"commit/swap.txt") options:o
                replacementCount:&count encoding:&enc
                isOpenAndModified:^BOOL(NSString *path) {
                    [saved writeToFile:path atomically:YES];   // atomic save: new inode
                    return NO;
                } error:nil];
            check(@"commit refused after an atomic save (inode changed)",
                  st == NPPReplaceFileChangedOnDisk && [readFile(@"commit/swap.txt") isEqualToData:saved],
                  [NSString stringWithFormat:@"status=%ld", (long)st]);

            // Only the mtime moved.
            writeData(@"commit/touch.txt", oldText);
            st = [NPPSearchCore replaceAllInFile:pathFor(@"commit/touch.txt") options:o
                replacementCount:&count encoding:&enc
                isOpenAndModified:^BOOL(NSString *path) {
                    [fm setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-3600]}
                         ofItemAtPath:path error:nil];
                    return NO;
                } error:nil];
            check(@"commit refused after an mtime change",
                  st == NPPReplaceFileChangedOnDisk && [readFile(@"commit/touch.txt") isEqualToData:oldText],
                  [NSString stringWithFormat:@"status=%ld", (long)st]);

            // Open in a tab with unsaved changes.
            writeData(@"commit/open.txt", oldText);
            __block NSString *askedFor = nil;
            st = [NPPSearchCore replaceAllInFile:pathFor(@"commit/open.txt") options:o
                replacementCount:&count encoding:&enc
                isOpenAndModified:^BOOL(NSString *path) { askedFor = path; return YES; } error:nil];
            check(@"open file with unsaved changes skipped",
                  st == NPPReplaceFileOpenModified && count == 0
                  && [askedFor isEqualToString:pathFor(@"commit/open.txt")]
                  && [readFile(@"commit/open.txt") isEqualToData:oldText]);

            // Permissions kept.
            writeData(@"commit/perm.txt", oldText);
            chmod(pathFor(@"commit/perm.txt").fileSystemRepresentation, 0640);
            st = [NPPSearchCore replaceAllInFile:pathFor(@"commit/perm.txt") options:o
                replacementCount:&count encoding:&enc isOpenAndModified:nil error:nil];
            NSUInteger perms = [fm attributesOfItemAtPath:pathFor(@"commit/perm.txt") error:nil].filePosixPermissions;
            check(@"permissions preserved", st == NPPReplaceFileReplaced && perms == 0640
                  && [readFile(@"commit/perm.txt") isEqualToData:newText],
                  [NSString stringWithFormat:@"perms=%lo", (unsigned long)perms]);

            // Symlink kept; the target is rewritten.
            writeData(@"commit/real.txt", oldText);
            [fm createSymbolicLinkAtPath:pathFor(@"commit/link.txt") withDestinationPath:@"real.txt" error:nil];
            st = [NPPSearchCore replaceAllInFile:pathFor(@"commit/link.txt") options:o
                replacementCount:&count encoding:&enc isOpenAndModified:nil error:nil];
            NSString *linkType = [fm attributesOfItemAtPath:pathFor(@"commit/link.txt") error:nil].fileType;
            check(@"symlink preserved, target rewritten",
                  st == NPPReplaceFileReplaced && [linkType isEqualToString:NSFileTypeSymbolicLink]
                  && [readFile(@"commit/real.txt") isEqualToData:newText]);

            // No staged temp file left behind by any of the above.
            BOOL leftover = NO;
            for (NSString *rel in [fm enumeratorAtPath:g_root])
                if ([rel.lastPathComponent containsString:@".npp-replace-"]) leftover = YES;
            check(@"no staged temp file left behind", !leftover);
        }

        // ---- Regex failing while matching; empty files ---------------------------
        {
            NSFileManager *fm = [NSFileManager defaultManager];
            // Boost gives up on (?:a+)+$ over 200 a's followed by "!" (complexity
            // limit) after "ok" has already matched once. Nothing may be
            // written, and Find in Files must not return a truncated list.
            NSString *text = [NSString stringWithFormat:@" ok  %@!",
                              [@"" stringByPaddingToLength:200 withString:@"a" startingAtIndex:0]];
            NPPFindOptions *o = options(@"ok|(?:a+)+$", NPPSearchRegex);
            o.replaceText = @"DONE";
            NSInteger count = -1;
            NSString *err = nil;
            NSString *r = [NPPSearchCore stringByReplacingAllInString:text options:o replacementCount:&count
                                                           regexError:&err];
            check(@"replace: regex failing mid-text returns the text unchanged with an error",
                  [r isEqualToString:text] && count == 0 && err.length > 0, err ?: @"<no error>");

            writeData(@"edge/fail.txt", [text dataUsingEncoding:NSUTF8StringEncoding]);
            NSData *before = readFile(@"edge/fail.txt");
            NSStringEncoding enc = 0;
            NPPReplaceFileStatus st = [NPPSearchCore replaceAllInFile:pathFor(@"edge/fail.txt") options:o
                replacementCount:&count encoding:&enc isOpenAndModified:nil error:nil];
            check(@"replace in files: regex failure leaves the file untouched",
                  st == NPPReplaceFileRegexFailed && [readFile(@"edge/fail.txt") isEqualToData:before],
                  [NSString stringWithFormat:@"status=%ld", (long)st]);

            err = nil;
            NSArray *found = [NPPSearchCore findInDirectory:pathFor(@"edge") options:o progressBlock:nil
                                                cancelToken:nil totalFilesScanned:NULL regexError:&err];
            check(@"find in files: regex failure stops the run with an error, no partial hits",
                  found.count == 0 && err.length > 0, err ?: @"<no error>");
            err = nil;
            NSArray *hits = [NPPSearchCore findAllInString:text filePath:@"t" options:o cancelToken:nil
                                                regexError:&err];
            check(@"find all: regex failure returns no partial hits", hits.count == 0 && err.length > 0);
            [fm removeItemAtPath:pathFor(@"edge/fail.txt") error:nil];

            // A zero-byte file is text, not a read failure: ^$ matches it once.
            writeData(@"edge/empty.txt", [NSData data]);
            NSInteger scanned = 0;
            err = nil;
            found = [NPPSearchCore findInDirectory:pathFor(@"edge") options:options(@"^$", NPPSearchRegex)
                                     progressBlock:nil cancelToken:nil totalFilesScanned:&scanned regexError:&err];
            NPPFileResults *fr = found.firstObject;
            check(@"empty file: ^$ finds one hit on line 1",
                  found.count == 1 && fr.hitCount == 1 && fr.results.firstObject.lineNumber == 1
                  && scanned == 1 && !err, describe(fr));
            found = [NPPSearchCore findInDirectory:pathFor(@"edge") options:options(@"x", NPPSearchNormal)
                                     progressBlock:nil cancelToken:nil totalFilesScanned:NULL regexError:NULL];
            check(@"empty file: normal search finds nothing", found.count == 0);
            o = options(@"^$", NPPSearchRegex);
            o.replaceText = @"filled";
            st = [NPPSearchCore replaceAllInFile:pathFor(@"edge/empty.txt") options:o replacementCount:&count
                                        encoding:&enc isOpenAndModified:nil error:nil];
            check(@"empty file: ^$ replace fills it",
                  st == NPPReplaceFileReplaced && count == 1
                  && [readFile(@"edge/empty.txt") isEqualToData:[@"filled" dataUsingEncoding:NSUTF8StringEncoding]],
                  [NSString stringWithFormat:@"status=%ld", (long)st]);
        }

        // ---- Results model --------------------------------------------------------
        {
            NSMutableArray<NPPSearchResult *> *results = [NSMutableArray array];
            const char *line = "\xC3\xA9t\xC3\xA9 \xF0\x9F\x98\x80 x";   // "été 😀 x"
            const size_t len = strlen(line);
            [NPPSearchCore appendHitToResults:results filePath:@"f" lineNumber:1 lineBytes:line lineLength:len
                                     hitStart:6 hitEnd:10];
            [NPPSearchCore appendHitToResults:results filePath:@"f" lineNumber:1 lineBytes:line lineLength:len
                                     hitStart:11 hitEnd:99];
            NPPSearchResult *r = results.firstObject;
            check(@"hits on one line merge; UTF-16 offsets; end clamped",
                  results.count == 1 && r.hitCount == 2
                  && NSEqualRanges(r.matchRanges[0].rangeValue, NSMakeRange(4, 2))
                  && NSEqualRanges(r.matchRanges[1].rangeValue, NSMakeRange(7, 1)),
                  [NSString stringWithFormat:@"%@", r.matchRanges]);
            [NPPSearchCore appendHitToResults:results filePath:@"f" lineNumber:2 lineBytes:"\xFF\xFE" lineLength:2
                                     hitStart:1 hitEnd:2];
            check(@"invalid UTF-8 line shown byte for byte", results.count == 2
                  && results[1].lineText.length == 2 && results[1].matchStart == 1);
        }

        [[NSFileManager defaultManager] removeItemAtPath:g_root error:nil];
    }
    printf("\n%s (%d failure%s)\n", g_fail ? "FAILURES" : "ALL PASS", g_fail, g_fail == 1 ? "" : "s");
    return g_fail ? 1 : 0;
}
