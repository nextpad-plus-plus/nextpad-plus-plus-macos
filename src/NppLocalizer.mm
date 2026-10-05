#import "NppLocalizer.h"
#import <objc/runtime.h>

NSNotificationName const NPPLocalizationChanged = @"NPPLocalizationChanged";
NSString * const kPrefLanguage = @"language";

// Associated-object key used to stash the original English title on each
// NSMenuItem so that language switches and English-reset both work correctly.
static const char kOriginalTitleKey = 0;

// ---------------------------------------------------------------------------
#pragma mark - String normalization helpers
// ---------------------------------------------------------------------------

/// Strip Windows accelerator-key notation from a string.
/// "Cu&t"    → "Cut"
/// "&File"   → "File"
/// "A && B"  → "A & B"  (double-& is a literal ampersand in Windows UI)
static NSString *stripAccelerators(NSString *s) {
    // Protect literal && with a private-use placeholder before removing single &.
    NSString *placeholder = @"\uE000";
    s = [s stringByReplacingOccurrencesOfString:@"&&" withString:placeholder];

    NSMutableString *result = [NSMutableString stringWithCapacity:s.length];
    NSUInteger len = s.length;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '&' && i + 1 < len) {
            // Skip the '&'; the next character will be appended on the next iteration.
            continue;
        }
        [result appendFormat:@"%C", c];
    }
    return [result stringByReplacingOccurrencesOfString:placeholder withString:@"&"];
}

/// Normalize a title for dictionary lookup:
///   • strip Windows accelerators
///   • normalize "..." → "…" (U+2026)
///   • strip trailing parenthetical suffixes like " (Ctrl+Mouse Wheel Up)"
///   • trim whitespace
///   • lowercase
static NSString *normalizeForLookup(NSString *s) {
    s = stripAccelerators(s);
    s = [s stringByReplacingOccurrencesOfString:@"..." withString:@"…"];

    // Strip trailing parenthetical, e.g. " (Ctrl+Mouse Wheel Up)"
    NSRange parenStart = [s rangeOfString:@" (" options:NSBackwardsSearch];
    if (parenStart.location != NSNotFound) {
        NSString *suffix = [s substringFromIndex:parenStart.location];
        if ([suffix hasSuffix:@")"]) {
            s = [s substringToIndex:parenStart.location];
        }
    }

    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return [s lowercaseString];
}

// ---------------------------------------------------------------------------
#pragma mark - NppLocalizer private interface
// ---------------------------------------------------------------------------

@interface NppLocalizer ()
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *translationMap; // normalized-english → display-translated
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *miscMap;        // misc-key → value
@property (nonatomic, readwrite) BOOL      isRTL;
@property (nonatomic, readwrite) NSString *currentLanguageName;
@property (nonatomic, readwrite) NSString *currentLanguageFile;
@end

// ---------------------------------------------------------------------------
#pragma mark - Implementation
// ---------------------------------------------------------------------------

@implementation NppLocalizer

+ (instancetype)shared {
    static NppLocalizer *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _translationMap     = @{};
        _miscMap            = @{};
        _currentLanguageName = @"English";
        _currentLanguageFile = @"english";
        _isRTL              = NO;
    }
    return self;
}

// ---------------------------------------------------------------------------
#pragma mark - Public API
// ---------------------------------------------------------------------------

- (void)autoLoad {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefLanguage];
    // Normalize legacy value from english_customizable to english
    if ([saved isEqualToString:@"english_customizable"]) {
        saved = @"english";
        [[NSUserDefaults standardUserDefaults] setObject:saved forKey:kPrefLanguage];
    }
    if (saved.length > 0 && ![saved isEqualToString:@"english"]) {
        [self loadLanguageNamed:saved];
    }
}

- (BOOL)loadLanguageNamed:(nullable NSString *)languageName {
    // Normalise: nil/empty/"english" all mean "reset to English".
    NSString *stem = [languageName lowercaseString];
    BOOL resetToEnglish = (stem.length == 0 || [stem isEqualToString:@"english"]);

    if (resetToEnglish) {
        self.translationMap      = @{};
        self.miscMap             = @{};
        self.currentLanguageName = @"English";
        self.currentLanguageFile = @"english";
        self.isRTL               = NO;
        [[NSUserDefaults standardUserDefaults] setObject:@"english" forKey:kPrefLanguage];
        [self applyToMainMenu];
        [[NSNotificationCenter defaultCenter] postNotificationName:NPPLocalizationChanged object:self];
        return YES;
    }

    // Locate the target language XML.
    NSString *targetPath = [self _xmlPathForStem:stem];
    if (!targetPath) {
        NSLog(@"NppLocalizer: language file '%@' not found.", stem);
        return NO;
    }

    // Locate english.xml (needed to build the English→ID reverse map).
    NSString *englishPath = [self _xmlPathForStem:@"english"];
    if (!englishPath) {
        NSLog(@"NppLocalizer: english.xml not found; cannot build translation map.");
        return NO;
    }

    // Parse both XML files.
    NSDictionary *englishRaw = [self _parseXMLAtPath:englishPath];
    NSDictionary *targetRaw  = [self _parseXMLAtPath:targetPath];
    if (englishRaw.count == 0 || targetRaw.count == 0) {
        NSLog(@"NppLocalizer: failed to parse XML for '%@'.", stem);
        return NO;
    }

    // Extract RTL flag and language display name from target XML.
    NSString *displayName = targetRaw[@"__name__"] ?: [self _displayNameFromStem:stem];
    BOOL rtl = [targetRaw[@"__rtl__"] isEqualToString:@"yes"];

    // Build the normalized-English → translated-display-title map.
    NSMutableDictionary *tmap = [NSMutableDictionary dictionaryWithCapacity:englishRaw.count];
    NSMutableDictionary *mmap = [NSMutableDictionary dictionary];

    for (NSString *key in englishRaw) {
        if ([key hasPrefix:@"__"]) continue; // skip metadata keys

        NSString *englishVal  = englishRaw[key];
        NSString *translatedVal = targetRaw[key];

        if (!translatedVal) continue; // target doesn't have this entry

        // Skip empty translations.
        NSString *displayTranslated = stripAccelerators(translatedVal);
        displayTranslated = [displayTranslated stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        if (displayTranslated.length == 0) continue;

        // Misc strings go into their own map.
        if ([key hasPrefix:@"misc:"]) {
            NSString *miscKey = [key substringFromIndex:5];
            mmap[miscKey] = displayTranslated;
            continue;
        }

        // Build lookup entries with the normalized English title.
        NSString *normalized = normalizeForLookup(englishVal);
        if (normalized.length == 0) continue;

        tmap[normalized] = displayTranslated;

        // Also add a paren-stripped version as a secondary key, so that
        // "Zoom In (Ctrl+Mouse Wheel Up)" in the XML matches "Zoom In" in the menu.
        // (normalizeForLookup already strips trailing parens, so both map to the same key.)
    }

    // Also index every dialog item name (stripped of accelerators) directly,
    // so panel code can call translate:@"Match case" and get the right result.
    // We do this as a second pass using just the english name as key.
    for (NSString *key in englishRaw) {
        if (![key hasPrefix:@"dlg:"] && ![key hasPrefix:@"dlgattr:"] &&
            ![key hasPrefix:@"tabbar:"]) continue;
        NSString *englishVal    = englishRaw[key];
        NSString *translatedVal = targetRaw[key];
        if (!translatedVal) continue;
        NSString *displayTranslated = stripAccelerators(translatedVal);
        displayTranslated = [displayTranslated
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (displayTranslated.length == 0) continue;
        // Index by the english title (normalized) as an additional lookup key.
        NSString *normalized = normalizeForLookup(englishVal);
        if (normalized.length > 0 && !tmap[normalized]) {
            tmap[normalized] = displayTranslated;
        }
    }

    // Platform-specific aliases: macOS uses slightly different wording for a
    // handful of items.  Add these so the translation still applies.
    [self _addPlatformAliasesTo:tmap englishRaw:englishRaw targetRaw:targetRaw];

    self.translationMap      = [tmap copy];
    self.miscMap             = [mmap copy];
    self.currentLanguageName = displayName;
    self.currentLanguageFile = stem;
    self.isRTL               = rtl;

    [[NSUserDefaults standardUserDefaults] setObject:stem forKey:kPrefLanguage];

    [self applyToMainMenu];
    [[NSNotificationCenter defaultCenter] postNotificationName:NPPLocalizationChanged object:self];
    return YES;
}

- (void)applyToMainMenu {
    NSMenu *mainMenu = [NSApplication sharedApplication].mainMenu;
    if (!mainMenu) return;

    for (NSMenuItem *topItem in mainMenu.itemArray) {
        // Skip the Application menu (index 0, title == app name).
        if (topItem == mainMenu.itemArray.firstObject) continue;

        // On macOS the menu bar text comes from submenu.title, not item.title.
        // Translate both to cover all cases.
        [self _translateMenuItem:topItem];
        if (topItem.hasSubmenu) {
            [self _translateSubmenuTitle:topItem.submenu];
            [self _translateMenu:topItem.submenu];
        }
    }
}

- (NSString *)translate:(NSString *)english {
    if (english.length == 0) return english;
    NSString *key = normalizeForLookup(english);
    NSString *translated = self.translationMap[key];
    // Uncomment for debug: if (!translated) NSLog(@"[NppLocalizer] MISS: \"%@\"", english);
    // Fallback (no translation found) goes through stripAccelerators so
    // Win32-style "&&" → "&" cleanup applies for English-only display too.
    // Translated values are already pre-stripped during map building.
    // Implicit contract for callers: use Win32-style "&&" for a literal
    // ampersand; a lone "&" is treated as a Win32 mnemonic and dropped
    // (matches how the translationMap lookup keys are normalized).
    return translated ?: stripAccelerators(english);
}

- (NSString *)miscString:(NSString *)key {
    NSString *val = self.miscMap[key];
    return val ?: key;
}

// ---------------------------------------------------------------------------
#pragma mark - Available languages
// ---------------------------------------------------------------------------

+ (NSArray<NSString *> *)availableLanguageNames {
    return [[[self availableLanguagesMap] allKeys]
            sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

+ (NSDictionary<NSString *, NSString *> *)availableLanguagesMap {
    // language display name → filename stem
    NSMutableDictionary *map = [NSMutableDictionary dictionary];

    // Always include English.
    map[@"English"] = @"english";

    NSArray<NSString *> *dirs = @[
        [self bundledLanguageDirectory],
        [self userLanguageDirectory],
    ];

    for (NSString *dir in dirs) {
        NSArray<NSString *> *files = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *file in files) {
            if (![file.pathExtension.lowercaseString isEqualToString:@"xml"]) continue;
            NSString *stem = [file.stringByDeletingPathExtension lowercaseString];
            if ([stem isEqualToString:@"english"] ||
                [stem isEqualToString:@"english_customizable"]) continue;
            NSString *fullPath = [dir stringByAppendingPathComponent:file];
            NSString *displayName = [self _displayNameFromXMLAtPath:fullPath] ?:
                                    [self _displayNameFromStem:stem];
            if (displayName) {
                map[displayName] = stem;
            }
        }
    }
    return [map copy];
}

+ (NSString *)userLanguageDirectory {
    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [appSupport stringByAppendingPathComponent:
                     @"Nextpad++/localization"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return dir;
}

+ (NSString *)bundledLanguageDirectory {
    return [NSBundle.mainBundle.resourcePath
            stringByAppendingPathComponent:@"localization"];
}

// ---------------------------------------------------------------------------
#pragma mark - Private: XML parsing
// ---------------------------------------------------------------------------

/// Recursively parse a <Dialog> element and its named sub-sections.
/// `parentName` is non-nil for nested elements (e.g. "Preference" when parsing <Global>).
- (void)_parseDialogElement:(NSXMLElement *)dlg
                 parentName:(nullable NSString *)parentName
                       into:(NSMutableDictionary *)result {
    NSString *dlgName = parentName
        ? [NSString stringWithFormat:@"%@_%@", parentName, dlg.name]
        : dlg.name;

    // Attributes: title, titleFind, titleReplace, …
    for (NSXMLNode *attr in dlg.attributes) {
        NSString *val = attr.stringValue;
        if (val.length == 0) continue;
        result[[NSString stringWithFormat:@"dlgattr:%@:%@", dlgName, attr.name]] = val;
    }

    for (NSXMLNode *childNode in dlg.children) {
        if (![childNode isKindOfClass:[NSXMLElement class]]) continue;
        NSXMLElement *child = (NSXMLElement *)childNode;

        if ([child.name isEqualToString:@"Item"]) {
            // <Item id="..." name="..."/>
            NSString *idStr = [[child attributeForName:@"id"]   stringValue];
            NSString *name  = [[child attributeForName:@"name"] stringValue];
            if (idStr.length && name.length)
                result[[NSString stringWithFormat:@"dlg:%@:%@", dlgName, idStr]] = name;

        } else if ([child.name isEqualToString:@"SubDialog"]) {
            // <SubDialog> (StyleConfig) — items inside
            for (NSXMLElement *sub in [child elementsForName:@"Item"]) {
                NSString *idStr = [[sub attributeForName:@"id"]   stringValue];
                NSString *name  = [[sub attributeForName:@"name"] stringValue];
                if (idStr.length && name.length)
                    result[[NSString stringWithFormat:@"dlg:%@_sub:%@", dlgName, idStr]] = name;
            }

        } else if ([child.name isEqualToString:@"Menu"]) {
            // Inline <Menu> (Find dialog context buttons)
            for (NSXMLElement *mi in [child elementsForName:@"Item"]) {
                NSString *idStr = [[mi attributeForName:@"id"]   stringValue];
                NSString *name  = [[mi attributeForName:@"name"] stringValue];
                if (idStr.length && name.length)
                    result[[NSString stringWithFormat:@"dlg:%@_menu:%@", dlgName, idStr]] = name;
            }

        } else {
            // Named sub-section, e.g. <Global title="General"> inside <Preference>.
            // Check if it looks like a sub-section (has a title attribute or Item children).
            NSString *subTitle = [[child attributeForName:@"title"] stringValue];
            NSArray  *subItems = [child elementsForName:@"Item"];
            if (subTitle.length || subItems.count > 0) {
                [self _parseDialogElement:child parentName:dlgName into:result];
            }
        }
    }
}

/// Returns a flat dictionary keyed by namespaced IDs:
///   "cmd:<id>"           — Menu/Main/Commands items
///   "menu:<menuId>"      — Menu/Main/Entries items
///   "submenu:<subMenuId>"— Menu/Main/SubEntries items
///   "tabbar:<CMDID>"     — Menu/TabBar items
///   "dlg:<dialog>:<id>"  — Dialog section items
///   "dlgattr:<dialog>:<attr>" — Dialog element attributes (title, titleFind, …)
///   "misc:<key>"         — MiscStrings elements
///   "__name__"           — Native-Langue name attribute (metadata)
///   "__rtl__"            — Native-Langue RTL attribute (metadata)
- (NSDictionary<NSString *, NSString *> *)_parseXMLAtPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return @{};

    NSError *error = nil;
    NSXMLDocument *doc = [[NSXMLDocument alloc]
        initWithData:data
             options:NSXMLNodeOptionsNone
               error:&error];
    if (!doc) {
        NSLog(@"NppLocalizer: XML parse FAILED for %@: %@", path.lastPathComponent, error);
        return @{};
    }
    if (error) {
        NSLog(@"NppLocalizer: XML parse WARNING for %@ (continuing): %@", path.lastPathComponent, error);
        // Continue — NSXMLDocument may return a valid doc with non-fatal warnings
    }

    NSXMLElement *root = doc.rootElement; // <NotepadPlus>
    NSXMLElement *nativeLang = [[root elementsForName:@"Native-Langue"] firstObject];
    if (!nativeLang) return @{};

    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    // Metadata.
    NSString *langName = [[nativeLang attributeForName:@"name"] stringValue];
    NSString *rtl      = [[nativeLang attributeForName:@"RTL"] stringValue];
    if (langName) result[@"__name__"] = langName;
    if (rtl)      result[@"__rtl__"]  = [rtl lowercaseString];

    // Menu/Main/Entries — top-level menu titles.
    NSArray *entries = [nativeLang nodesForXPath:@"Menu/Main/Entries/Item" error:nil];
    for (NSXMLElement *item in entries) {
        NSString *menuId = [[item attributeForName:@"menuId"] stringValue];
        NSString *name   = [[item attributeForName:@"name"]   stringValue];
        if (menuId.length && name.length)
            result[[@"menu:" stringByAppendingString:menuId]] = name;
    }

    // Menu/Main/SubEntries — submenu titles.
    NSArray *subEntries = [nativeLang nodesForXPath:@"Menu/Main/SubEntries/Item" error:nil];
    for (NSXMLElement *item in subEntries) {
        NSString *subMenuId = [[item attributeForName:@"subMenuId"] stringValue];
        NSString *name      = [[item attributeForName:@"name"]      stringValue];
        if (subMenuId.length && name.length)
            result[[@"submenu:" stringByAppendingString:subMenuId]] = name;
    }

    // Menu/Main/Commands — individual menu items.
    NSArray *commands = [nativeLang nodesForXPath:@"Menu/Main/Commands/Item" error:nil];
    for (NSXMLElement *item in commands) {
        NSString *idStr = [[item attributeForName:@"id"]   stringValue];
        NSString *name  = [[item attributeForName:@"name"] stringValue];
        if (idStr.length && name.length)
            result[[@"cmd:" stringByAppendingString:idStr]] = name;
    }

    // Menu/TabBar — tab context-menu items.
    NSArray *tabBarItems = [nativeLang nodesForXPath:@"Menu/TabBar/Item" error:nil];
    for (NSXMLElement *item in tabBarItems) {
        NSString *cmdId = [[item attributeForName:@"CMDID"] stringValue];
        NSString *name  = [[item attributeForName:@"name"]  stringValue];
        if (cmdId.length && name.length)
            result[[@"tabbar:" stringByAppendingString:cmdId]] = name;
        // Also add the alternativeName if present (e.g. "Unpin Tab").
        NSString *altName = [[item attributeForName:@"alternativeName"] stringValue];
        if (cmdId.length && altName.length)
            result[[NSString stringWithFormat:@"tabbar_alt:%@", cmdId]] = altName;
    }

    // Dialog — all <Item> name attributes and element title attributes.
    // We parse the top-level dialog children, plus one level of nesting for
    // compound dialogs like <Preference> which contains <Global>, <NewDoc>, etc.
    NSArray *dialogs = [nativeLang nodesForXPath:@"Dialog/*" error:nil];
    for (NSXMLElement *dlg in dialogs) {
        [self _parseDialogElement:dlg parentName:nil into:result];
    }

    // MiscStrings — <element-name value="..."/>
    NSArray *miscItems = [nativeLang nodesForXPath:@"MiscStrings/*" error:nil];
    for (NSXMLElement *item in miscItems) {
        NSString *key = item.name;
        NSString *val = [[item attributeForName:@"value"] stringValue];
        if (key.length && val.length)
            result[[NSString stringWithFormat:@"misc:%@", key]] = val;
    }

    return [result copy];
}

// ---------------------------------------------------------------------------
#pragma mark - Private: translation map building
// ---------------------------------------------------------------------------

/// Add platform-specific alias entries so macOS-specific wording maps to the
/// correct Windows XML string and thereby receives the correct translation.
- (void)_addPlatformAliasesTo:(NSMutableDictionary *)tmap
                   englishRaw:(NSDictionary *)englishRaw
                    targetRaw:(NSDictionary *)targetRaw {
    // Each entry: macOS normalized title → Windows XML entry key.
    // The Windows XML entry key resolves via englishRaw/targetRaw to a translation.
    NSDictionary<NSString *, NSString *> *aliases = @{
        // File menu
        @"close all but current":          @"cmd:41005",
        @"close all but pinned":           @"cmd:41026",
        @"move to trash":                  @"cmd:41016",  // Windows says "Move to Recycle Bin"
        @"open containing folder":         @"submenu:file-openFolder",
        @"close multiple documents":       @"submenu:file-closeMore",

        // Edit menu
        @"indent":                         @"submenu:edit-indent",
        @"comment/uncomment":              @"submenu:edit-comment",
        @"auto-completion":                @"submenu:edit-autoCompletion",
        @"eol conversion":                 @"submenu:edit-eolConversion",
        @"blank operations":               @"submenu:edit-blankOperations",
        @"paste special":                  @"submenu:edit-pasteSpecial",
        @"on selection":                   @"submenu:edit-onSelection",
        @"convert case to":                @"submenu:edit-convertCaseTo",
        @"line operations":                @"submenu:edit-lineOperations",
        @"read-only in notepad++":         @"submenu:edit-readonlyInNextpad++",
        @"insert":                         @"submenu:edit-insert",
        @"copy to clipboard":              @"submenu:edit-copyToClipboard",
        @"multi-select all":               @"submenu:edit-multiSelectALL",
        @"multi-select next":              @"submenu:edit-multiSelectNext",
        @"duplicate line":                 @"cmd:42010",  // macOS title "Duplicate Line" vs "Duplicate Current Line"
        @"delete line":                    @"cmd:42015",  // vs "Move Down Current Line" collision; use closest
        @"move line up":                   @"cmd:42014",
        @"move line down":                 @"cmd:42015",
        @"single line comment":            @"cmd:42035",
        @"single line uncomment":          @"cmd:42036",
        @"toggle single line comment":     @"cmd:42022",
        @"block comment":                  @"cmd:42023",
        @"block uncomment":                @"cmd:42047",

        // Search menu
        @"change history":                 @"submenu:search-changeHistory",
        @"style all occurrences of token": @"submenu:search-markAll",
        @"style one token":                @"submenu:search-markOne",
        @"clear style":                    @"submenu:search-unmarkAll",
        @"jump up":                        @"submenu:search-jumpUp",
        @"jump down":                      @"submenu:search-jumpDown",
        @"copy styled text":               @"submenu:search-copyStyledText",
        @"bookmark":                       @"submenu:search-bookmark",
        @"clear all changes":              @"cmd:43069",

        // View menu
        @"view current file in":           @"submenu:view-currentFileIn",
        @"show symbol":                    @"submenu:view-showSymbol",
        @"zoom":                           @"submenu:view-zoom",
        @"move/clone current document":    @"submenu:view-moveCloneDocument",
        @"move to new window":             @"cmd:10003",  // Windows says "Move to New Instance"
        @"tab":                            @"submenu:view-tab",
        @"fold level":                     @"submenu:view-collapseLevel",
        @"unfold level":                   @"submenu:view-uncollapseLevel",
        @"project":                        @"submenu:view-project",
        @"zoom in":                        @"cmd:44023",
        @"zoom out":                       @"cmd:44024",
        @"restore default zoom":           @"cmd:44033",
        @"select next tab":                @"cmd:44095",
        @"select previous tab":            @"cmd:44096",
        @"synchronize vertical scrolling": @"cmd:44035",
        @"synchronize horizontal scrolling": @"cmd:44036",

        // Encoding menu
        @"character set":                  @"submenu:encoding-characterSets",
        @"western european":               @"submenu:encoding-westernEuropean",
        @"central european":               @"submenu:encoding-centralEuropean",
        @"cyrillic":                       @"submenu:encoding-cyrillic",
        @"greek":                          @"submenu:encoding-greek",
        @"baltic":                         @"submenu:encoding-baltic",
        @"turkish":                        @"submenu:encoding-turkish",
        @"chinese":                        @"submenu:encoding-chinese",
        @"japanese":                       @"submenu:encoding-japanese",
        @"korean":                         @"submenu:encoding-korean",
        @"old mac (cr)":                   @"cmd:45003",  // macOS calls it "Old Mac (CR)", XML "Macintosh (CR)"

        // Language menu
        @"user defined language":          @"submenu:language-userDefinedLanguage",

        // Settings menu
        @"import":                         @"submenu:settings-import",

        // Tools menu
        @"md5":                            @"submenu:tools-md5",
        @"sha-1":                          @"submenu:tools-sha1",
        @"sha-256":                        @"submenu:tools-sha256",
        @"sha-512":                        @"submenu:tools-sha512",
        @"generate":                       @"cmd:48501",
        @"generate from files…":           @"cmd:48502",
        @"generate from selection into clipboard": @"cmd:48503",

        // FindReplacePanel / IncrementalSearchBar — macOS labels vs Windows XML wording
        @"whole word":                     @"dlg:Find:1603",   // "Match whole word only"
        @"wrap":                           @"dlg:Find:1606",   // "Wrap around"
        @"replace:":                       @"dlg:Find:1611",   // "Replace with:"
        @"find previous":                  @"cmd:43010",
        @"find next":                      @"cmd:43002",
        @"replace all":                    @"dlg:Find:1609",
        @"replace":                        @"dlg:Find:1608",
        @"match case":                     @"dlg:IncrementalFind:1685",

        // Find in Files / Find in Projects
        @"find in files":                  @"cmd:43013",
        @"directory:":                     @"dlg:Find:1655",   // "Directory:"
        @"filter:":                        @"dlg:Find:1654",   // "Filters:"
        @"match case":                     @"dlg:IncrementalFind:1685",

        // ColumnEditor
        @"column / multi-selection editor": @"dlgattr:ColumnEditor:title",
        @"initial number:":                @"dlg:ColumnEditor:2024",
        @"increase by:":                   @"dlg:ColumnEditor:2025",
        @"repeat:":                        @"dlg:ColumnEditor:2026",
        @"leading:":                       @"dlg:ColumnEditor:2027",
        @"text to insert":                 @"dlg:ColumnEditor:2023",
        @"number to insert":               @"dlg:ColumnEditor:2030",

        // StyleConfigurator
        @"style configurator":             @"dlgattr:StyleConfig:title",
        @"select theme:":                  @"dlg:StyleConfig:2306",
        @"cancel":                         @"dlg:StyleConfig:2",
        @"save && close":                  @"dlg:StyleConfig:2301",
        @"bold":                           @"dlg:StyleConfig_sub:2204",
        @"italic":                         @"dlg:StyleConfig_sub:2205",
        @"underline":                      @"dlg:StyleConfig_sub:2218",
        @"font name:":                     @"dlg:StyleConfig_sub:2208",
        @"font size:":                     @"dlg:StyleConfig_sub:2209",
        @"foreground colour":              @"dlg:StyleConfig_sub:2206",
        @"background colour":              @"dlg:StyleConfig_sub:2207",

        // GoToLine dialog
        @"go to…":                         @"dlgattr:GoToLine:title",
        @"line":                           @"dlg:GoToLine:2007",
        @"offset":                         @"dlg:GoToLine:2008",
        @"go":                             @"dlg:GoToLine:1",

        // Preferences window & tabs
        @"preferences":                    @"dlgattr:Preference:title",
        @"general":                        @"dlgattr:Preference_Global:title",
        @"new document":                   @"dlgattr:Preference_NewDoc:title",
        @"backup":                         @"dlgattr:Preference_Backup:title",
        // macOS displays "Cloud and Link"; the Windows XML title is "Cloud & Link"
        // (a single & is dropped as a mnemonic by normalizeForLookup, so the
        // plain-English name never matches the harvested key — alias it here).
        @"cloud and link":                 @"dlgattr:Preference_Cloud:title",

        // Window menu
        @"sort by":                        @"submenu:window-sortby",
        @"file name a to z":               @"cmd:11002",
        @"file name z to a":               @"cmd:11003",
        @"file type a to z":               @"cmd:11006",
        @"file type z to a":               @"cmd:11007",
        @"full path a to z":               @"cmd:11004",
        @"full path z to a":               @"cmd:11005",
        @"windows…":                       @"cmd:11001",
    };

    for (NSString *macosKey in aliases) {
        if (tmap[macosKey]) continue; // already translated via normal matching
        NSString *xmlKey = aliases[macosKey];
        NSString *translated = targetRaw[xmlKey];
        if (!translated) continue;
        // An entry still holding the Windows English text is an untranslated
        // placeholder (e.g. "Move to New Instance" for "Move to New Window"):
        // keep the macOS English title rather than show the Windows wording.
        if ([translated isEqualToString:englishRaw[xmlKey]]) continue;
        NSString *display = stripAccelerators(translated);
        display = [display stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceCharacterSet]];
        if (display.length > 0) {
            tmap[macosKey] = display;
        }
    }
}

// ---------------------------------------------------------------------------
#pragma mark - Private: menu walking
// ---------------------------------------------------------------------------

- (void)_translateMenu:(NSMenu *)menu {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isSeparatorItem) continue;
        [self _translateMenuItem:item];
        if (item.hasSubmenu) {
            [self _translateSubmenuTitle:item.submenu];
            [self _translateMenu:item.submenu];
        }
    }
}

/// Translate an NSMenu's title (the text shown in the menu bar and submenu headers).
/// Uses the same original-title caching as _translateMenuItem: but via a separate
/// associated-object key so item.title and submenu.title don't interfere.
static const char kOriginalSubmenuTitleKey = 0;

- (void)_translateSubmenuTitle:(NSMenu *)menu {
    if (menu.title.length == 0) return;

    NSString *stored = objc_getAssociatedObject(menu, &kOriginalSubmenuTitleKey);
    NSString *englishTitle = stored ?: menu.title;

    NSString *key = normalizeForLookup(englishTitle);
    NSString *translated = self.translationMap[key];

    if (translated.length > 0) {
        if (!stored) {
            objc_setAssociatedObject(menu, &kOriginalSubmenuTitleKey,
                                     menu.title,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        menu.title = translated;
    } else if (stored) {
        menu.title = stored;
    }
}

- (void)_translateMenuItem:(NSMenuItem *)item {
    if (item.title.length == 0) return;

    // Retrieve the stored original English title (set on first translation).
    NSString *stored = objc_getAssociatedObject(item, &kOriginalTitleKey);
    NSString *englishTitle = stored ?: item.title;

    NSString *key = normalizeForLookup(englishTitle);
    NSString *translated = self.translationMap[key];

    if (translated.length > 0) {
        // Save the original English title so future language switches can
        // re-translate from English rather than from a previously-translated string.
        if (!stored) {
            objc_setAssociatedObject(item, &kOriginalTitleKey,
                                     item.title,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        item.title = translated;
    } else if (stored) {
        // We have a stored English title but no translation in the new language.
        // Restore the English original (handles English reset and untranslated items).
        item.title = stored;
    }
    // If no stored title and no translation: leave the title as-is (already English).
}

+ (NSString *)englishTitleOfMenuItem:(NSMenuItem *)item {
    if (!item) return @"";
    NSString *stored = objc_getAssociatedObject(item, &kOriginalTitleKey);
    return stored ?: (item.title ?: @"");
}

+ (NSString *)englishTitleOfMenu:(NSMenu *)menu {
    if (!menu) return @"";
    NSString *stored = objc_getAssociatedObject(menu, &kOriginalSubmenuTitleKey);
    return stored ?: (menu.title ?: @"");
}

+ (NSString *)normalizedTitleKey:(NSString *)title {
    return title.length ? normalizeForLookup(title) : @"";
}

// ---------------------------------------------------------------------------
#pragma mark - Private: file lookup helpers
// ---------------------------------------------------------------------------

- (nullable NSString *)_xmlPathForStem:(NSString *)stem {
    // Check user directory first (allows overriding bundled files).
    NSString *userDir   = [NppLocalizer userLanguageDirectory];
    NSString *bundleDir = [NppLocalizer bundledLanguageDirectory];
    NSFileManager *fm   = [NSFileManager defaultManager];

    NSString *targetName = [stem stringByAppendingPathExtension:@"xml"];

    for (NSString *dir in @[userDir, bundleDir]) {
        // Fast path: direct match. Works on case-insensitive volumes
        // (the macOS default) regardless of how the file is actually cased.
        NSString *path = [[dir stringByAppendingPathComponent:stem]
                          stringByAppendingPathExtension:@"xml"];
        if ([fm fileExistsAtPath:path]) return path;

        // Fallback: case-insensitive directory scan so that files with
        // mixed-case names (e.g. chineseSimplified.xml) still load when
        // the volume is case-sensitive APFS — see issue #23.
        NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dir error:NULL];
        for (NSString *entry in entries) {
            if ([entry caseInsensitiveCompare:targetName] == NSOrderedSame) {
                return [dir stringByAppendingPathComponent:entry];
            }
        }
    }
    return nil;
}

+ (nullable NSString *)_displayNameFromXMLAtPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSError *error = nil;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data
                                                     options:NSXMLNodeOptionsNone
                                                       error:&error];
    if (!doc) return nil;
    NSXMLElement *nativeLang = [[doc.rootElement elementsForName:@"Native-Langue"] firstObject];
    return [[nativeLang attributeForName:@"name"] stringValue];
}

+ (NSString *)_displayNameFromStem:(NSString *)stem {
    // Convert camelCase stem to display name: "chineseSimplified" → "Chinese Simplified".
    NSMutableString *result = [NSMutableString string];
    NSCharacterSet *upper = [NSCharacterSet uppercaseLetterCharacterSet];
    for (NSUInteger i = 0; i < stem.length; i++) {
        unichar c = [stem characterAtIndex:i];
        if (i > 0 && [upper characterIsMember:c]) {
            [result appendString:@" "];
        }
        if (i == 0) {
            [result appendFormat:@"%C", (unichar)toupper(c)];
        } else {
            [result appendFormat:@"%C", c];
        }
    }
    return [result copy];
}

// ---------------------------------------------------------------------------
// Forward the private class-method helpers via instance methods for
// internal use (to avoid static vs. dynamic dispatch issues).
// ---------------------------------------------------------------------------

- (NSString *)_displayNameFromStem:(NSString *)stem {
    return [NppLocalizer _displayNameFromStem:stem];
}

@end
