#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Single authoritative entry per built-in language, derived from Windows
/// Notepad++ sources (the Notepad_plus.rc Language menu captions joined with
/// ScintillaEditView.cpp's _langNameInfoArray). See issue #144 follow-up.
typedef struct {
    const char *internalName; // matches <Language name="..."> in langs.model.xml
    const char *caption;      // exact Windows menu caption (display string)
    const char *lexerID;      // Lexilla lexer ID (passed to CreateLexer)
} NppBuiltinLang;

/// All built-in language entries, sorted alphabetically by `caption`.
/// "None (Normal Text)" is the first entry — callers that letter-group should
/// pin it at the top of the Language menu rather than under "N".
const NppBuiltinLang *NppBuiltinLanguagesAll(NSUInteger *outCount);

/// Look up the display caption for an internal name (e.g. "mssql" →
/// "Microsoft Transact-SQL"). Returns nil for unknown names.
NSString * _Nullable NppBuiltinLanguageCaptionForInternal(NSString *internalName);

/// Look up the Lexilla lexer ID for an internal name (e.g. "fortran77" → "f77").
/// Returns nil for unknown names.
NSString * _Nullable NppBuiltinLanguageLexerIDForInternal(NSString *internalName);

/// Windows LangType value (enum LangType, Notepad_plus_msgs.h) for an internal
/// name (e.g. "json" → 57 = L_JSON). "" and "normal" → 0 (L_TEXT). Returns -1
/// for names that are not built-in languages (User Defined Languages included).
int NppBuiltinLanguageLangTypeForInternal(NSString *internalName);

/// Internal name for a Windows LangType value (e.g. 57 → "json"), as passed to
/// EditorView's setLanguage:. 0 (L_TEXT) → "" (plain text). Returns nil for
/// values the host has no built-in language for (L_USER, L_EXTERNAL, …).
NSString * _Nullable NppBuiltinLanguageInternalForLangType(NSInteger langType);

NS_ASSUME_NONNULL_END
