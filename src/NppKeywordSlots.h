#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One langs.xml keyword group fed to one Lexilla word list slot. Entries
/// that share a slot are merged into one list.
typedef struct {
    const char * _Nullable sourceLang; // langs.xml <Language name>; NULL = the language being applied
    const char *group;                 // langs.xml <Keywords name>, e.g. "instre1", "type2"
    int         slot;                  // SCI_SETKEYWORDS index (lexer word list number)
    // Styler whose user-defined keywords (WordsStyle text with keywordClass ==
    // group) are prepended, like Windows' makeStyle() + concatToBuildKeywordList().
    // NULL = sourceLang (or the language being applied); "" = none.
    const char * _Nullable stylerLang;
} NppKeywordSlot;

/// Upper bound on the number of assignments any language produces.
enum { kNppKeywordSlotsMax = 16 };

/// Fill `out` with the keyword group to lexer slot assignments Windows
/// Notepad++ makes for `lang` (a langs.xml language name, case-insensitive).
/// Mirrors ScintillaEditView: the generic setLexer() LIST_n masks for simple
/// lexers and the bespoke setters (setCppLexer, setJsLexer, setObjCLexer,
/// setTclLexer, setJsonLexer, setXmlLexer, setHTMLLexer and the embedded
/// JS/PHP/ASP setters) for the rest. Returns the number of entries written.
NSUInteger NppKeywordSlotsForLanguage(NSString *lang, NppKeywordSlot out[_Nonnull], NSUInteger capacity);

/// One SCI_ALLOCATESUBSTYLES call: `count` substyles of `baseStyle`, fed from
/// the langs.xml groups substyle<firstGroup> .. substyle<firstGroup+count-1>.
typedef struct {
    const char * _Nullable sourceLang; // langs.xml language and styler; NULL = the language being applied
    int         baseStyle;             // lexer style that gets the substyles (e.g. SCE_C_IDENTIFIER)
    int         count;                 // number of substyles to allocate
    int         firstGroup;            // 1-based substyle group number of the first substyle
} NppSubstyleBase;

/// Upper bound on the number of substyle allocations any language makes.
enum { kNppSubstyleBasesMax = 8 };

/// Fill `out` with the substyle allocations Windows Notepad++ makes for
/// `lang`, in the order it makes them (populateSubStyleKeywords() calls in
/// setCppLexer, setJsLexer, setTypeScriptLexer, setBashLexer, setXmlLexer,
/// setHTMLLexer, the embedded JS/PHP/ASP setters and the setLexer() baseStyleID
/// argument). Allocation order fixes the style IDs: Lexilla hands out substyles
/// sequentially from the lexer's first substyle ID, and stylers.xml numbers its
/// substyle rows to match. Returns the number of entries written.
NSUInteger NppSubstyleBasesForLanguage(NSString *lang, NppSubstyleBase out[_Nonnull], NSUInteger capacity);

NS_ASSUME_NONNULL_END
