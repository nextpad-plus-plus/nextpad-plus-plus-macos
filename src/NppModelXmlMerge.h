//  NppModelXmlMerge.h
//  Brings user copies of langs.xml, stylers.xml and theme files up to date with
//  the bundled langs.model.xml / stylers.model.xml.
//
//  The user files are copied from the models on first run and then shadow them
//  completely, so without this step existing users never see new languages,
//  keywords or styles. This is a port of NppParameters::updateFromModelXml
//  (PowerEditor/src/Parameters.cpp in Notepad++):
//
//    - It runs only when the model's <NotepadPlus modelDate="..."> is newer than
//      the one stored in the user file, and writes the model's date back.
//    - langs: adds missing <Language> elements, missing <Keywords> groups, words
//      missing from existing groups (the group is then re-sorted, as upstream
//      does), missing <Language> attributes, and extensions missing from "ext".
//    - stylers and themes: adds missing WidgetStyle, LexerType and WordsStyle
//      elements and attributes missing from existing ones. In a theme file the
//      fgColor/bgColor of anything added are taken from the theme's own
//      "Default Style" instead of the light model colours.
//    - It never changes or removes a value the user file already has, so changes
//      to existing model values (a new default colour or font) are not migrated.
//
//  The merge edits the file text in place, so formatting, comments, attribute
//  order, line endings and a UTF-8 BOM are kept. Before writing, the old file
//  is saved as "<name>.bak-<yyyyMMdd>" next to it (one backup per file is kept)
//  and the result is written atomically with the file's permissions. A file
//  that does not parse, or is read-only, is left untouched and not retried
//  for the rest of the run.
//
//  Future model changes reach existing users only if the PR that makes them
//  also bumps modelDate in the model file it touches.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NppModelXmlKind) {
    NppModelXmlKindLangs,   // langs.xml against langs.model.xml
    NppModelXmlKindStylers, // stylers.xml or a theme against stylers.model.xml
};

typedef NS_ENUM(NSInteger, NppModelXmlMergeStatus) {
    NppModelXmlMergeUpToDate, // user modelDate >= model modelDate: nothing done
    NppModelXmlMergeMerged,   // file rewritten (or only its modelDate bumped)
    NppModelXmlMergeFailed,   // read/parse/write failure: file left untouched
};

/// Pure text merge. Returns the merged document text, or nil when the user text
/// is already current (*status = UpToDate) or cannot be merged (*status = Failed,
/// *error set). `isTheme` selects the theme colour handling described above.
FOUNDATION_EXPORT NSString *_Nullable NppMergeModelXmlText(NSString *userText,
                                                           NSString *modelText,
                                                           NppModelXmlKind kind,
                                                           BOOL isTheme,
                                                           NppModelXmlMergeStatus *_Nullable status,
                                                           NSError *_Nullable *_Nullable error);

/// Merge the model at `modelPath` into the user file at `userPath`, with the
/// backup and atomic write described above.
FOUNDATION_EXPORT NppModelXmlMergeStatus NppMergeModelXmlFile(NSString *userPath,
                                                              NSString *modelPath,
                                                              NppModelXmlKind kind,
                                                              BOOL isTheme);

/// Copy langs.model.xml / stylers.model.xml from the bundle as langs.xml /
/// stylers.xml when they are missing, and (once per launch) merge newer model
/// entries into existing copies. Call before anything reads langs or stylers.
FOUNDATION_EXPORT void NppInstallUserLangsAndStylers(void);

/// Merge newer stylers.model.xml entries into a theme file in the user themes
/// directory. Call it for the active theme only (at launch, and when a theme
/// is committed as the active one), never for previews, as Notepad++ does.
/// Each path is checked once per run. A copy identical to the bundled theme of
/// the same name is skipped, as is a merge that would only store the date.
/// Returns YES when the file was rewritten, so callers can reload it.
FOUNDATION_EXPORT BOOL NppUpdateUserThemeFromModel(NSString *themePath);

NS_ASSUME_NONNULL_END
