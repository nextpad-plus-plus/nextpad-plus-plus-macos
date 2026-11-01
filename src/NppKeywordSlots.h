#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One langs.xml keyword group fed to one Lexilla word list slot. Entries
/// that share a slot are merged into one list.
typedef struct {
    const char * _Nullable sourceLang; // langs.xml <Language name>; NULL = the language being applied
    const char *group;                 // langs.xml <Keywords name>, e.g. "instre1", "type2"
    int         slot;                  // SCI_SETKEYWORDS index (lexer word list number)
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

NS_ASSUME_NONNULL_END
