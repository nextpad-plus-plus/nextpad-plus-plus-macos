// SPDX-License-Identifier: MIT
//
// Headless tests for the Windows LangType table in NppBuiltinLanguages.mm, the
// integers plugins pass in NPPM_GET/SETCURRENTLANGTYPE and
// NPPM_GET/SETBUFFERLANGTYPE. No AppKit, no app launch.
//
// Run with ctest (see CMakeLists.txt). Exits non-zero on any failure.

#import <Foundation/Foundation.h>
#import "NppBuiltinLanguages.h"

static int g_fail = 0;

static void check(NSString *label, BOOL cond, NSString *detail = @"") {
    printf("[%s] %s %s\n", cond ? "PASS" : "FAIL", label.UTF8String, detail.UTF8String);
    if (!cond) g_fail++;
}

static void checkType(NSString *name, int expected) {
    int got = NppBuiltinLanguageLangTypeForInternal(name);
    check([NSString stringWithFormat:@"type of \"%@\"", name], got == expected,
          [NSString stringWithFormat:@"(got %d, expected %d)", got, expected]);
}

static void checkName(NSInteger langType, NSString *expected) {
    NSString *got = NppBuiltinLanguageInternalForLangType(langType);
    BOOL ok = expected ? [got isEqualToString:expected] : got == nil;
    check([NSString stringWithFormat:@"name of %ld", (long)langType], ok,
          [NSString stringWithFormat:@"(got %@, expected %@)",
           got ? [NSString stringWithFormat:@"\"%@\"", got] : @"nil",
           expected ? [NSString stringWithFormat:@"\"%@\"", expected] : @"nil"]);
}

int main() {
    @autoreleasepool {
        // Values from enum LangType in Windows Notepad_plus_msgs.h.
        checkType(@"json", 57);           // L_JSON (JSON Viewer's NPPM_SETCURRENTLANGTYPE)
        checkType(@"javascript.js", 58);  // L_JAVASCRIPT
        checkType(@"javascript", 58);     // alias kept from the old lookup
        checkType(@"php", 1);             // L_PHP
        checkType(@"cpp", 3);             // L_CPP
        checkType(@"json5", 86);          // L_JSON5
        checkType(@"jsp", 55);            // L_JSP
        checkType(@"errorlist", 94);      // L_ERRORLIST
        checkType(@"JSON", 57);           // case-insensitive, as before
        checkType(@"", 0);                // plain text
        checkType(@"normal", 0);
        checkType(@"udf", -1);            // L_USER is not a built-in language
        checkType(@"My UDL", -1);

        checkName(0, @"");                // L_TEXT → setLanguage:@""
        checkName(57, @"json");
        checkName(58, @"javascript.js");
        checkName(1, @"php");
        checkName(86, @"json5");
        checkName(15, nil);               // L_USER
        checkName(19, nil);               // L_JS_EMBEDDED
        checkName(47, nil);               // L_SEARCHRESULT
        checkName(97, nil);               // L_EXTERNAL
        checkName(98, nil);
        checkName(-1, nil);
        checkName(0x100000039, nil);      // must not truncate to 57

        // Every built-in language has a LangType and round-trips, so a
        // regenerated language table cannot silently drop one.
        NSUInteger count = 0;
        const NppBuiltinLang *langs = NppBuiltinLanguagesAll(&count);
        int missing = 0;
        for (NSUInteger i = 0; i < count; i++) {
            NSString *name = @(langs[i].internalName);
            int t = NppBuiltinLanguageLangTypeForInternal(name);
            NSString *back = NppBuiltinLanguageInternalForLangType(t);
            NSString *expected = [name isEqualToString:@"normal"] ? @"" : name;
            if (t < 0 || ![back isEqualToString:expected]) {
                check([NSString stringWithFormat:@"round-trip \"%@\"", name], NO,
                      [NSString stringWithFormat:@"(type %d → %@)", t, back ?: @"nil"]);
                missing++;
            }
        }
        check([NSString stringWithFormat:@"all %lu built-in languages round-trip",
               (unsigned long)count], missing == 0);
    }
    printf("\n%s (%d failure%s)\n", g_fail ? "FAILURES" : "ALL PASS", g_fail, g_fail == 1 ? "" : "s");
    return g_fail ? 1 : 0;
}
