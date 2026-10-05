#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted after the UDL dialog saves, renames, creates or removes a UDL (the
/// manager has already reloaded). userInfo: @"name" (the affected UDL) and,
/// for a rename, @"oldName". Editors using the UDL re-apply it.
extern NSNotificationName const UserDefineLangsDidChangeNotification;

/// Represents one User Defined Language loaded from XML.
@interface UserDefinedLang : NSObject
@property (nonatomic, copy)   NSString *name;          // display name
@property (nonatomic, copy)   NSString *extensions;    // space-separated file extensions (no dot)
@property (nonatomic)         BOOL caseIgnored;
@property (nonatomic)         BOOL allowFoldOfComments;
@property (nonatomic)         BOOL foldCompact;
@property (nonatomic)         int  forcePureLC;        // 0/1/2
@property (nonatomic)         int  decimalSeparator;   // 0=dot, 1=comma, 2=both
@property (nonatomic, copy)   NSArray<NSNumber *> *isPrefix; // BOOL[8] for keywords 1-8
@property (nonatomic, copy)   NSDictionary<NSString *, NSString *> *keywordLists; // name → keywords
@property (nonatomic, copy)   NSArray<NSDictionary *> *styles; // [{name, fgColor, bgColor, fontStyle, ...}]
@property (nonatomic, copy)   NSString *xmlPath;       // source file path
@property (nonatomic)         BOOL isDarkModeTheme;
@end

/// Manages loading and access to User Defined Languages.
/// Scans bundled + user directories for UDL XML files.
@interface UserDefineLangManager : NSObject

+ (instancetype)shared;

/// Load/reload all UDL files from bundled and user directories.
- (void)loadAll;

/// All loaded UDLs, sorted by name.
@property (nonatomic, readonly) NSArray<UserDefinedLang *> *allLanguages;

/// Find a UDL by name.
- (nullable UserDefinedLang *)languageNamed:(NSString *)name;

/// Find a UDL by file extension (without dot).
- (nullable UserDefinedLang *)languageForExtension:(NSString *)ext;

/// Find a UDL for a file name (no directory). Mirrors Windows
/// getUserDefinedLangNameFromExt: an ext= entry matches the file's extension,
/// or the whole name when the name contains a dot (e.g. "foo.conf"). Where
/// several UDLs match, the light/dark variant matching the editor theme wins.
- (nullable UserDefinedLang *)languageForFileName:(NSString *)fileName;

/// `udl`, or the theme-matching variant of it when `udl` claims `fileName`
/// (by extension or whole name) and another UDL claiming it is the better
/// light/dark match. A UDL picked for a file it does not claim is kept.
- (UserDefinedLang *)variantOf:(UserDefinedLang *)udl forFileName:(nullable NSString *)fileName;

/// Import a UDL from a file (copies to user directory).
- (nullable UserDefinedLang *)importFromPath:(NSString *)path;

/// Export a UDL to a file.
- (BOOL)exportLanguage:(UserDefinedLang *)lang toPath:(NSString *)path;

/// Delete a UDL (removes from user directory).
- (BOOL)deleteLanguage:(UserDefinedLang *)lang;

/// Path to the user UDL directory (~/Library/Application Support/Nextpad++/userDefineLangs/).
+ (NSString *)userUDLDirectory;

/// Path to the bundled UDL directory (inside app bundle).
+ (NSString *)bundledUDLDirectory;

/// Apply a UDL's keyword lists to a Scintilla view for syntax highlighting.
/// This configures the "user" lexer (LexUser) with the UDL's definitions.
- (void)applyLanguage:(UserDefinedLang *)lang toScintillaView:(id)sciView;

@end

NS_ASSUME_NONNULL_END
