#import "NppKeywordSlots.h"

// Keyword group → Lexilla word list slot mapping, copied from Windows Notepad++
// (PowerEditor/src/ScintillaComponent/ScintillaEditView.cpp/.h,
//  PowerEditor/src/MISC/Common/NppConstants.h).
//
// Windows numbers langs.xml groups with LANG_INDEX_*:
//   instre1=0 instre2=1 type1=2 type2=3 type3=4 type4=5 type5=6 type6=7 type7=8
// Simple lexers go through setLexer(lang, LIST_n mask), which feeds group n to
// slot n for every bit set in the mask. Lexers whose slot layout differs have
// bespoke setters; those are spelled out as explicit slot lists below.
//
// Substyle keyword groups (substyle1..8, LANG_INDEX_SUBSTYLE1..8) are not fed
// here. When they are, add a substyle descriptor to NppKeywordLangSpec (base
// style ID, count, first substyle group), matching Windows'
// populateSubStyleKeywords() calls in the same setters.

// Group names in LANG_INDEX order (index == natural slot).
static const char *const kGroupByIndex[] = {
    "instre1", "instre2", "type1", "type2", "type3", "type4", "type5", "type6", "type7",
};
enum { kNaturalGroupCount = sizeof(kGroupByIndex) / sizeof(kGroupByIndex[0]) };

// ScintillaEditView.h LIST_n masks.
enum : uint16_t {
    LIST_NONE = 0,
    LIST_0 = 1 << 0, LIST_1 = 1 << 1, LIST_2 = 1 << 2, LIST_3 = 1 << 3,
    LIST_4 = 1 << 4, LIST_5 = 1 << 5, LIST_6 = 1 << 6, LIST_7 = 1 << 7,
    LIST_8 = 1 << 8,
    LIST_ALL = 0x1FF,
};
#define LIST_0_TO(n) ((uint16_t)((1u << ((n) + 1)) - 1))

// ── Bespoke setters ─────────────────────────────────────────────────────────

// setCppLexer(): C, C++, Java, C#, ActionScript, Swift, Go. Doxygen tags are
// always C++'s type2 list, in slot 2. Global classes (instre2) go to slot 3.
static const NppKeywordSlot kCppSlots[] = {
    { NULL,  "instre1", 0 },
    { NULL,  "type1",   1 },
    { "cpp", "type2",   2 },
    { NULL,  "instre2", 3 },
};
// setCppLexer() for L_RC skips the doxygen list.
static const NppKeywordSlot kRcSlots[] = {
    { NULL, "instre1", 0 },
    { NULL, "type1",   1 },
    { NULL, "instre2", 3 },
};
// setJsLexer(): L_JAVASCRIPT and L_JS_EMBEDDED both read javascript.js lists
// when the javascript.js styler exists (it does in stylers.model.xml).
static const NppKeywordSlot kJsSlots[] = {
    { "javascript.js", "instre1", 0 },
    { "javascript.js", "type1",   1 },
    { "cpp",           "type2",   2 },
    { "javascript.js", "instre2", 3 },
};
// setTypeScriptLexer()
static const NppKeywordSlot kTypeScriptSlots[] = {
    { NULL,  "instre1", 0 },
    { NULL,  "type1",   1 },
    { "cpp", "type2",   2 },
};
// setObjCLexer(): LexObjC reads instrs, types, doxygen, directives, qualifiers.
static const NppKeywordSlot kObjCSlots[] = {
    { NULL,  "instre1", 0 },
    { NULL,  "type1",   1 },
    { "cpp", "type2",   2 },
    { NULL,  "instre2", 3 },
    { NULL,  "type2",   4 },
};
// setTclLexer(): TCL keywords, iTCL (type1), TK (instre2), TK commands, expand, user1-4.
static const NppKeywordSlot kTclSlots[] = {
    { NULL, "instre1", 0 },
    { NULL, "type1",   1 },
    { NULL, "instre2", 2 },
    { NULL, "type2",   3 },
    { NULL, "type3",   4 },
    { NULL, "type4",   5 },
    { NULL, "type5",   6 },
    { NULL, "type6",   7 },
    { NULL, "type7",   8 },
};
// setJsonLexer(): JSON5 reuses the JSON lists.
static const NppKeywordSlot kJsonSlots[] = {
    { "json", "instre1", 0 },
    { "json", "instre2", 1 },
};
// setXmlLexer(L_XML): DOCTYPE keywords go to LexHTML's SGML slot.
static const NppKeywordSlot kXmlSlots[] = {
    { NULL, "instre1", 5 },
};
// setXmlLexer() for HTML, PHP, ASP, JSP: setHTMLLexer() + setEmbeddedJSLexer()
// + setEmbeddedPhpLexer() + setEmbeddedAspLexer(), each into LexHTML's slot for
// that sublanguage. The ASP setter reads the VB list, not asp's own.
static const NppKeywordSlot kHtmlFamilySlots[] = {
    { "html",       "instre1", 0 },  // HTML elements and attributes
    { "javascript", "instre1", 1 },  // JavaScript keywords
    { "vb",         "instre1", 2 },  // VBScript keywords
    { "php",        "instre1", 4 },  // PHP keywords
    { "html",       "instre2", 5 },  // SGML and DTD keywords
};

#define SLOTS(a) a, (sizeof(a) / sizeof(a[0]))

typedef struct {
    const char           *lang;      // langs.xml language name
    uint16_t              listMask;  // setLexer() LIST_n mask (used when slots == NULL)
    const NppKeywordSlot *slots;     // bespoke setter assignments
    NSUInteger            slotCount;
} NppKeywordLangSpec;

static const NppKeywordLangSpec kSpecs[] = {
    // Bespoke setters
    { "c",             0, SLOTS(kCppSlots) },
    { "cpp",           0, SLOTS(kCppSlots) },
    { "java",          0, SLOTS(kCppSlots) },
    { "cs",            0, SLOTS(kCppSlots) },
    { "actionscript",  0, SLOTS(kCppSlots) },
    { "swift",         0, SLOTS(kCppSlots) },
    { "go",            0, SLOTS(kCppSlots) },
    { "rc",            0, SLOTS(kRcSlots) },
    { "javascript.js", 0, SLOTS(kJsSlots) },
    { "javascript",    0, SLOTS(kJsSlots) },
    { "typescript",    0, SLOTS(kTypeScriptSlots) },
    { "objc",          0, SLOTS(kObjCSlots) },
    { "tcl",           0, SLOTS(kTclSlots) },
    { "json",          0, SLOTS(kJsonSlots) },
    { "json5",         0, SLOTS(kJsonSlots) },
    { "xml",           0, SLOTS(kXmlSlots) },
    { "html",          0, SLOTS(kHtmlFamilySlots) },
    { "php",           0, SLOTS(kHtmlFamilySlots) },
    { "asp",           0, SLOTS(kHtmlFamilySlots) },
    { "jsp",           0, SLOTS(kHtmlFamilySlots) },

    // setLexer() masks from ScintillaEditView.h
    { "ada",          LIST_0 },
    { "asm",          LIST_0_TO(7) },
    { "asn1",         LIST_0_TO(3) },
    { "autoit",       LIST_0_TO(6) },
    { "avs",          LIST_0_TO(5) },
    { "baanc",        LIST_0_TO(8) },
    { "bash",         LIST_0 },
    { "batch",        LIST_0 },
    { "blitzbasic",   LIST_0_TO(3) },
    { "caml",         LIST_0_TO(2) },
    { "cmake",        LIST_0_TO(2) },
    { "cobol",        LIST_0_TO(2) },
    { "coffeescript", LIST_0_TO(3) },
    { "csound",       LIST_0_TO(2) },
    { "css",          LIST_0 | LIST_1 | LIST_4 | LIST_6 },
    { "d",            LIST_0_TO(6) },
    { "diff",         LIST_NONE },
    { "erlang",       LIST_0_TO(5) },
    { "errorlist",    LIST_NONE },
    { "escript",      LIST_0_TO(2) },
    { "escseq",       LIST_NONE },
    { "fcST",         LIST_0_TO(5) },
    { "forth",        LIST_0_TO(5) },
    { "fortran",      LIST_0_TO(2) },
    { "fortran77",    LIST_0_TO(2) },
    { "freebasic",    LIST_0_TO(3) },
    { "gdscript",     LIST_0 | LIST_1 },
    { "gui4cli",      LIST_0_TO(4) },
    { "haskell",      LIST_0 },
    { "hollywood",    LIST_0_TO(3) },
    { "ihex",         LIST_NONE },
    { "ini",          LIST_NONE },
    { "inno",         LIST_0_TO(5) },
    { "kix",          LIST_0_TO(2) },
    { "latex",        LIST_NONE },
    { "lisp",         LIST_0 | LIST_1 },
    { "lua",          LIST_0_TO(7) },
    { "makefile",     LIST_NONE },
    { "matlab",       LIST_0 },
    { "mmixal",       LIST_0_TO(2) },
    { "mssql",        LIST_0_TO(5) },
    { "nfo",          LIST_NONE },
    { "nim",          LIST_0 },
    { "nncrontab",    LIST_0_TO(2) },
    { "normal",       LIST_NONE },
    { "nsis",         LIST_0_TO(3) },
    { "oscript",      LIST_0_TO(5) },
    { "pascal",       LIST_0 },
    { "perl",         LIST_0 },
    { "postscript",   LIST_0_TO(3) },
    { "powershell",   LIST_0_TO(5) },
    { "props",        LIST_NONE },
    { "purebasic",    LIST_0_TO(3) },
    { "python",       LIST_0 | LIST_1 },
    { "r",            LIST_0_TO(2) },
    { "raku",         LIST_0_TO(6) },
    { "rebol",        LIST_0_TO(6) },
    { "registry",     LIST_NONE },
    { "ruby",         LIST_0 },
    { "rust",         LIST_0_TO(6) },
    { "sas",          LIST_0_TO(3) },
    { "scheme",       LIST_0 | LIST_1 },
    { "smalltalk",    LIST_0 },
    { "spice",        LIST_0_TO(2) },
    { "sql",          LIST_0 | LIST_1 | LIST_4 },
    { "srec",         LIST_NONE },
    { "tehex",        LIST_NONE },
    { "tex",          LIST_NONE },
    { "toml",         LIST_0 },
    { "txt2tags",     LIST_NONE },
    { "vb",           LIST_0 },
    { "verilog",      LIST_0 | LIST_1 },
    { "vhdl",         LIST_0_TO(6) },
    { "visualprolog", LIST_0_TO(3) },
    { "yaml",         LIST_0 },
};

static const NppKeywordLangSpec *specForLanguage(NSString *lang) {
    static NSDictionary<NSString *, NSValue *> *index;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const NSUInteger n = sizeof(kSpecs) / sizeof(kSpecs[0]);
        NSMutableDictionary *m = [NSMutableDictionary dictionaryWithCapacity:n];
        for (NSUInteger i = 0; i < n; i++)
            m[@(kSpecs[i].lang).lowercaseString] = [NSValue valueWithPointer:&kSpecs[i]];
        index = [m copy];
    });
    return (const NppKeywordLangSpec *)[index[lang.lowercaseString] pointerValue];
}

NSUInteger NppKeywordSlotsForLanguage(NSString *lang, NppKeywordSlot out[], NSUInteger capacity) {
    const NppKeywordLangSpec *spec = specForLanguage(lang);
    NSUInteger n = 0;

    if (spec && spec->slots) {
        for (NSUInteger i = 0; i < spec->slotCount && n < capacity; i++)
            out[n++] = spec->slots[i];
        return n;
    }

    // Generic setLexer() path. Languages without a Windows setter (none of the
    // built-ins today) get every list in natural order.
    const uint16_t mask = spec ? spec->listMask : LIST_ALL;
    for (int i = 0; i < kNaturalGroupCount && n < capacity; i++) {
        if (mask & (1u << i))
            out[n++] = (NppKeywordSlot){ NULL, kGroupByIndex[i], i };
    }
    return n;
}
