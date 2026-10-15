#import "UserDefineLangManager.h"
#import "NppPaths.h"
#import "NppThemeManager.h"
#import "ScintillaView.h"
#import "Scintilla.h"
#import "ScintillaMessages.h"

namespace Scintilla { struct ILexer5; }
extern "C" Scintilla::ILexer5 *CreateLexer(const char *name);

NSNotificationName const UserDefineLangsDidChangeNotification = @"UserDefineLangsDidChangeNotification";

// ── UserDefinedLang ──────────────────────────────────────────────────────────

@implementation UserDefinedLang
@end

// ── UserDefineLangManager ────────────────────────────────────────────────────

@implementation UserDefineLangManager {
    NSMutableArray<UserDefinedLang *> *_languages;
    // O(1) lookup indices, rebuilt whenever _languages changes (issue #130).
    // _nameIndex is keyed by exact name. _extIndex is keyed by lowercased
    // extension and maps to ALL UDLs claiming that extension (issue #130
    // follow-up): the markdown UDL ships as a light + dark pair, so a single
    // ext can have multiple variants. languageForExtension: picks the
    // theme-matching one (Windows: Parameters.cpp:1921 behavior).
    NSMutableDictionary<NSString *, UserDefinedLang *> *_nameIndex;
    NSMutableDictionary<NSString *, NSMutableArray<UserDefinedLang *> *> *_extIndex;
}

+ (instancetype)shared {
    static UserDefineLangManager *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _languages = [NSMutableArray array];
        _nameIndex = [NSMutableDictionary dictionary];
        _extIndex  = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSArray<UserDefinedLang *> *)allLanguages {
    return [_languages copy];
}

#pragma mark - Directory paths

+ (NSString *)userUDLDirectory {
    NSString *dir = NppConfigSubpath(@"userDefineLangs");
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

+ (NSString *)bundledUDLDirectory {
    return [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"userDefineLangs"];
}

#pragma mark - Loading

- (void)loadAll {
    [_languages removeAllObjects];

    // Load from bundled directory first (pre-installed UDLs)
    [self _loadFromDirectory:[UserDefineLangManager bundledUDLDirectory]];

    // Load from user directory (user-created/imported UDLs, can override bundled)
    [self _loadFromDirectory:[UserDefineLangManager userUDLDirectory]];

    // Also check for the legacy single-file container (userDefineLang.xml)
    NSString *legacyPath = NppConfigSubpath(@"userDefineLang.xml");
    if ([[NSFileManager defaultManager] fileExistsAtPath:legacyPath]) {
        [self _loadFromContainerFile:legacyPath];
    }

    // Sort by name
    [_languages sortUsingComparator:^NSComparisonResult(UserDefinedLang *a, UserDefinedLang *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];

    [self _rebuildIndexes];
}

/// Rebuild the name/extension lookup indices from _languages.
/// _nameIndex is unique-by-name (first entry wins). _extIndex aggregates ALL
/// UDLs that claim a given extension into an array, so languageForExtension:
/// can pick the theme-matching variant (e.g. the markdown light/dark pair).
- (void)_rebuildIndexes {
    [_nameIndex removeAllObjects];
    [_extIndex removeAllObjects];
    for (UserDefinedLang *udl in _languages) {
        if (udl.name.length && !_nameIndex[udl.name])
            _nameIndex[udl.name] = udl;
        for (NSString *e in [udl.extensions componentsSeparatedByString:@" "]) {
            NSString *ext = e.lowercaseString;
            if (!ext.length) continue;
            NSMutableArray<UserDefinedLang *> *bucket = _extIndex[ext];
            if (!bucket) {
                bucket = [NSMutableArray array];
                _extIndex[ext] = bucket;
            }
            [bucket addObject:udl];
        }
    }
}

- (void)_loadFromDirectory:(NSString *)dir {
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *file in files) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"xml"]) continue;
        NSString *fullPath = [dir stringByAppendingPathComponent:file];
        [self _loadFromFile:fullPath];
    }
}

- (void)_loadFromFile:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) { NSLog(@"UDL: cannot read %@", path.lastPathComponent); return; }

    NSError *error;
    // Preserve original structure (comments, entities, whitespace), but not
    // character references: with NSXMLNodePreserveCharacterReferences,
    // stringValue drops the whitespace between adjacent references
    // ("&#x4E2D; &#x6587;" reads back as two joined words) and leaves
    // non-BMP ones (&#x1F600;) undecoded. The UDL dialog writes such
    // references for characters a file's declared encoding cannot hold.
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data
                                                     options:NSXMLNodePreserveAll & ~NSXMLNodePreserveCharacterReferences
                                                       error:&error];
    if (!doc) {
        // Fall back to tidy XML for files with encoding issues
        doc = [[NSXMLDocument alloc] initWithData:data
                                          options:NSXMLDocumentTidyXML
                                            error:&error];
    }
    if (!doc) {
        NSLog(@"UDL: XML parse error in %@: %@", path.lastPathComponent, error.localizedDescription);
        return;
    }

    // Find all <UserLang> elements — try direct children first, then XPath fallback
    NSArray *userLangs = [doc.rootElement elementsForName:@"UserLang"];
    if (!userLangs.count) {
        userLangs = [doc.rootElement nodesForXPath:@"//UserLang" error:nil];
    }
    for (NSXMLElement *elem in userLangs) {
        UserDefinedLang *udl = [self _parseUserLangElement:elem path:path];
        if (udl) {
            // Replace existing with same name (user overrides bundled)
            for (NSUInteger i = 0; i < _languages.count; i++) {
                if ([_languages[i].name isEqualToString:udl.name]) {
                    _languages[i] = udl;
                    udl = nil;
                    break;
                }
            }
            if (udl) [_languages addObject:udl];
        }
    }
}

- (void)_loadFromContainerFile:(NSString *)path {
    [self _loadFromFile:path];
}

- (nullable UserDefinedLang *)_parseUserLangElement:(NSXMLElement *)elem path:(NSString *)path {
    NSString *name = [[elem attributeForName:@"name"] stringValue];
    if (!name.length) return nil;

    UserDefinedLang *udl = [[UserDefinedLang alloc] init];
    udl.name       = name;
    udl.extensions = [[elem attributeForName:@"ext"] stringValue] ?: @"";
    udl.xmlPath    = path;
    udl.isDarkModeTheme = [[[elem attributeForName:@"darkModeTheme"] stringValue] isEqualToString:@"yes"];

    // Settings
    NSXMLElement *settings = [[elem elementsForName:@"Settings"] firstObject];
    if (settings) {
        NSXMLElement *global = [[settings elementsForName:@"Global"] firstObject];
        if (global) {
            udl.caseIgnored = [[[global attributeForName:@"caseIgnored"] stringValue] isEqualToString:@"yes"];
            udl.allowFoldOfComments = [[[global attributeForName:@"allowFoldOfComments"] stringValue] isEqualToString:@"yes"];
            udl.foldCompact = [[[global attributeForName:@"foldCompact"] stringValue] isEqualToString:@"yes"];
            udl.forcePureLC = [[[global attributeForName:@"forcePureLC"] stringValue] intValue];
            udl.decimalSeparator = [[[global attributeForName:@"decimalSeparator"] stringValue] intValue];
        }

        NSXMLElement *prefix = [[settings elementsForName:@"Prefix"] firstObject];
        if (prefix) {
            NSMutableArray *pArr = [NSMutableArray arrayWithCapacity:8];
            for (int i = 1; i <= 8; i++) {
                NSString *attr = [NSString stringWithFormat:@"Keywords%d", i];
                BOOL val = [[[prefix attributeForName:attr] stringValue] isEqualToString:@"yes"];
                [pArr addObject:@(val)];
            }
            udl.isPrefix = pArr;
        }
    }

    // KeywordLists
    NSXMLElement *kwLists = [[elem elementsForName:@"KeywordLists"] firstObject];
    if (kwLists) {
        NSMutableDictionary *kwMap = [NSMutableDictionary dictionary];
        for (NSXMLElement *kw in [kwLists elementsForName:@"Keywords"]) {
            NSString *kwName = [[kw attributeForName:@"name"] stringValue];
            NSString *kwText = kw.stringValue ?: @"";
            if (kwName.length) kwMap[kwName] = kwText;
        }
        udl.keywordLists = kwMap;
    }

    // Styles
    NSXMLElement *stylesElem = [[elem elementsForName:@"Styles"] firstObject];
    if (stylesElem) {
        NSMutableArray *styles = [NSMutableArray array];
        for (NSXMLElement *ws in [stylesElem elementsForName:@"WordsStyle"]) {
            NSMutableDictionary *sd = [NSMutableDictionary dictionary];
            for (NSXMLNode *attr in ws.attributes) {
                sd[attr.name] = attr.stringValue;
            }
            [styles addObject:sd];
        }
        udl.styles = styles;
    }

    return udl;
}

#pragma mark - Lookup

- (nullable UserDefinedLang *)languageNamed:(NSString *)name {
    return name.length ? _nameIndex[name] : nil;
}

- (nullable UserDefinedLang *)languageForExtension:(NSString *)ext {
    if (!ext.length) return nil;
    NSArray<UserDefinedLang *> *bucket = _extIndex[ext.lowercaseString];
    if (!bucket.count) return nil;
    if (bucket.count == 1) return bucket[0];

    // Multiple UDLs claim this extension — prefer the one whose
    // darkModeTheme flag matches the current dark-mode state. Mirrors
    // Windows NPP behaviour (NppParameters::getUserDefinedLangNameFromExt,
    // Parameters.cpp:1921): the markdown UDL ships as a light + dark pair,
    // and Windows auto-picks the right one based on dark-mode state.
    // Falls back to the first match if no theme-specific variant exists.
    BOOL wantDark = [NppThemeManager shared].isDark;
    for (UserDefinedLang *udl in bucket) {
        if (udl.isDarkModeTheme == wantDark) return udl;
    }
    return bucket[0];
}

#pragma mark - Import / Export / Delete

- (nullable UserDefinedLang *)importFromPath:(NSString *)path {
    NSString *destDir = [UserDefineLangManager userUDLDirectory];
    NSString *filename = path.lastPathComponent;
    NSString *destPath = [destDir stringByAppendingPathComponent:filename];

    NSError *error;
    [[NSFileManager defaultManager] copyItemAtPath:path toPath:destPath error:&error];
    if (error) {
        NSLog(@"UDL import failed: %@", error);
        return nil;
    }

    // Load the imported file
    NSUInteger countBefore = _languages.count;
    [self _loadFromFile:destPath];
    if (_languages.count > countBefore) {
        [self _rebuildIndexes];
        return _languages.lastObject;
    }
    return nil;
}

- (BOOL)exportLanguage:(UserDefinedLang *)lang toPath:(NSString *)path {
    if (!lang.xmlPath) return NO;
    NSError *error;
    return [[NSFileManager defaultManager] copyItemAtPath:lang.xmlPath toPath:path error:&error];
}

- (BOOL)deleteLanguage:(UserDefinedLang *)lang {
    if (!lang.xmlPath) return NO;
    // Only allow deleting from user directory
    NSString *userDir = [UserDefineLangManager userUDLDirectory];
    if (![lang.xmlPath hasPrefix:userDir]) return NO;

    NSError *error;
    BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:lang.xmlPath error:&error];
    if (ok) {
        [_languages removeObject:lang];
        [self _rebuildIndexes];
    }
    return ok;
}

#pragma mark - Apply UDL to Scintilla

/// Preprocess a keyword string for SCI_SETKEYWORDS: strip quotes, convert
/// spaces inside quotes to \v (double-quoted) or \b (single-quoted) per
/// the Windows ScintillaEditView::setUserLexer() logic.
static NSData *preprocessKeywords(NSString *raw) {
    const char *src = raw.UTF8String ?: "";
    size_t srcLen = strlen(src);
    char *buf = (char *)malloc(srcLen + 1);
    if (!buf) return [NSData data];

    BOOL inDouble = NO, inSingle = NO;
    size_t out = 0;

    for (size_t j = 0; j < srcLen; j++) {
        char c = src[j];

        // Toggle quote state
        if (c == '"' && !inSingle)  { inDouble = !inDouble; continue; }
        if (c == '\'' && !inDouble) { inSingle = !inSingle; continue; }

        // Handle escape sequences inside quotes
        if (c == '\\' && j + 1 < srcLen &&
            (src[j+1] == '"' || src[j+1] == '\'' || src[j+1] == '\\')) {
            j++;
            buf[out++] = src[j];
            continue;
        }

        if (inDouble || inSingle) {
            if (c > ' ') {
                buf[out++] = c;
            } else if (out > 0 && buf[out-1] > ' ' && j + 1 < srcLen && src[j+1] > ' ') {
                // Space inside quotes: \v for double-quoted (multi-line), \b for single-quoted
                buf[out++] = inDouble ? '\v' : '\b';
            }
        } else {
            buf[out++] = c;
        }
    }
    buf[out] = '\0';
    NSData *result = [NSData dataWithBytes:buf length:out + 1];
    free(buf);
    return result;
}

/// Mirrors Windows ScintillaEditView::setUserLexer() exactly.
/// Iterates all 28 keyword list indices in order. Indices that are in the
/// setLexerMapper go via SCI_SETPROPERTY; all others go via SCI_SETKEYWORDS
/// with an incrementing counter (matching the Windows keyword index order
/// that LexUser.cxx expects).
- (void)applyLanguage:(UserDefinedLang *)lang toScintillaView:(id)sciView {
    ScintillaView *sv = (ScintillaView *)sciView;

    // Set the "user" lexer
    Scintilla::ILexer5 *lexer = CreateLexer("user");
    if (!lexer) return;
    [sv message:SCI_SETILEXER wParam:0 lParam:(sptr_t)lexer];

    NSDictionary<NSString *, NSString *> *kw = lang.keywordLists;

    // ── The 28 keyword list names in index order (matching Windows) ──────
    static NSArray<NSString *> *kwListNames = nil;
    if (!kwListNames) {
        kwListNames = @[
            @"Comments",                     //  0
            @"Numbers, prefix1",             //  1
            @"Numbers, prefix2",             //  2
            @"Numbers, extras1",             //  3
            @"Numbers, extras2",             //  4
            @"Numbers, suffix1",             //  5
            @"Numbers, suffix2",             //  6
            @"Numbers, range",               //  7
            @"Operators1",                   //  8
            @"Operators2",                   //  9
            @"Folders in code1, open",       // 10
            @"Folders in code1, middle",     // 11
            @"Folders in code1, close",      // 12
            @"Folders in code2, open",       // 13
            @"Folders in code2, middle",     // 14
            @"Folders in code2, close",      // 15
            @"Folders in comment, open",     // 16
            @"Folders in comment, middle",   // 17
            @"Folders in comment, close",    // 18
            @"Keywords1",                    // 19
            @"Keywords2",                    // 20
            @"Keywords3",                    // 21
            @"Keywords4",                    // 22
            @"Keywords5",                    // 23
            @"Keywords6",                    // 24
            @"Keywords7",                    // 25
            @"Keywords8",                    // 26
            @"Delimiters",                   // 27
        ];
    }

    // ── setLexerMapper: indices sent as SCI_SETPROPERTY ──────────────────
    // Mirrors Windows globalMappper().setLexerMapper from UserDefineDialog.h
    static NSDictionary<NSNumber *, NSString *> *propMap = nil;
    if (!propMap) {
        propMap = @{
            @0:  @"userDefine.comments",
            @1:  @"userDefine.numberPrefix1",
            @2:  @"userDefine.numberPrefix2",
            @3:  @"userDefine.numberExtras1",
            @4:  @"userDefine.numberExtras2",
            @5:  @"userDefine.numberSuffix1",
            @6:  @"userDefine.numberSuffix2",
            @7:  @"userDefine.numberRange",
            @8:  @"userDefine.operators1",
            @10: @"userDefine.foldersInCode1Open",
            @11: @"userDefine.foldersInCode1Middle",
            @12: @"userDefine.foldersInCode1Close",
            @27: @"userDefine.delimiters",
        };
    }

    // ── Iterate all 28 indices, matching Windows setUserLexer() loop ─────
    int setKeywordsCounter = 0;

    for (int i = 0; i < 28; i++) {
        NSString *kwName = kwListNames[i];
        NSString *raw = kw[kwName] ?: @"";
        const char *rawUTF8 = raw.UTF8String ?: "";

        NSString *propName = propMap[@(i)];
        if (propName) {
            // This index is in the setLexerMapper → send as SCI_SETPROPERTY
            [sv message:SCI_SETPROPERTY
                 wParam:(uptr_t)propName.UTF8String
                 lParam:(sptr_t)rawUTF8];
        } else {
            // NOT in mapper → preprocess and send via SCI_SETKEYWORDS
            NSData *processed = preprocessKeywords(raw);
            [sv message:SCI_SETKEYWORDS
                 wParam:(uptr_t)setKeywordsCounter
                 lParam:(sptr_t)processed.bytes];
            setKeywordsCounter++;
        }
    }

    // ── Lexer behavior properties ────────────────────────────────────────
    [sv message:SCI_SETPROPERTY wParam:(uptr_t)"userDefine.isCaseIgnored"
         lParam:(sptr_t)(lang.caseIgnored ? "1" : "0")];
    [sv message:SCI_SETPROPERTY wParam:(uptr_t)"userDefine.allowFoldOfComments"
         lParam:(sptr_t)(lang.allowFoldOfComments ? "1" : "0")];
    [sv message:SCI_SETPROPERTY wParam:(uptr_t)"userDefine.foldCompact"
         lParam:(sptr_t)(lang.foldCompact ? "1" : "0")];
    [sv message:SCI_SETPROPERTY wParam:(uptr_t)"userDefine.forcePureLC"
         lParam:(sptr_t)[[NSString stringWithFormat:@"%d", lang.forcePureLC] UTF8String]];
    [sv message:SCI_SETPROPERTY wParam:(uptr_t)"userDefine.decimalSeparator"
         lParam:(sptr_t)[[NSString stringWithFormat:@"%d", lang.decimalSeparator] UTF8String]];

    // Prefix flags for keyword groups 1-8
    NSArray<NSNumber *> *prefixes = lang.isPrefix ?: @[];
    for (int i = 0; i < 8; i++) {
        char propNameBuf[64];
        snprintf(propNameBuf, sizeof(propNameBuf), "userDefine.prefixKeywords%d", i + 1);
        BOOL isPrefix = (i < (int)prefixes.count) ? prefixes[i].boolValue : NO;
        [sv message:SCI_SETPROPERTY wParam:(uptr_t)propNameBuf lParam:(sptr_t)(isPrefix ? "1" : "0")];
    }

    // UDL name (pointer value as identifier for lexer cache)
    char udlNameBuf[32];
    snprintf(udlNameBuf, sizeof(udlNameBuf), "%lu", (unsigned long)(uintptr_t)lang);
    [sv message:SCI_SETPROPERTY wParam:(uptr_t)"userDefine.udlName" lParam:(sptr_t)udlNameBuf];

    // Buffer ID (use ScintillaView pointer as unique ID)
    char bufIdBuf[32];
    snprintf(bufIdBuf, sizeof(bufIdBuf), "%lu", (unsigned long)(uintptr_t)sv);
    [sv message:SCI_SETPROPERTY wParam:(uptr_t)"userDefine.currentBufferID" lParam:(sptr_t)bufIdBuf];

    // ── Apply styles ─────────────────────────────────────────────────────
    for (NSDictionary *style in lang.styles) {
        NSString *styleName = style[@"name"];
        NSString *fgStr = style[@"fgColor"];
        NSString *bgStr = style[@"bgColor"];
        NSString *fontStyleStr = style[@"fontStyle"];

        int styleID = [self _styleIDForName:styleName];
        if (styleID < 0) continue;

        if (fgStr.length == 6) {
            unsigned int rgb = 0;
            [[NSScanner scannerWithString:fgStr] scanHexInt:&rgb];
            // NPP stores RRGGBB, Scintilla expects BBGGRR
            int bgr = (int)(((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF));
            [sv message:SCI_STYLESETFORE wParam:styleID lParam:bgr];
        }
        if (bgStr.length == 6) {
            unsigned int rgb = 0;
            [[NSScanner scannerWithString:bgStr] scanHexInt:&rgb];
            int bgr = (int)(((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF));
            [sv message:SCI_STYLESETBACK wParam:styleID lParam:bgr];
        }
        if (fontStyleStr) {
            int fs = fontStyleStr.intValue;
            if (fs & 1) [sv message:SCI_STYLESETBOLD      wParam:styleID lParam:1];
            if (fs & 2) [sv message:SCI_STYLESETITALIC     wParam:styleID lParam:1];
            if (fs & 4) [sv message:SCI_STYLESETUNDERLINE  wParam:styleID lParam:1];
        }
    }

    // Force re-lex the entire document
    [sv message:SCI_COLOURISE wParam:0 lParam:-1];
}

- (int)_styleIDForName:(NSString *)name {
    static NSDictionary *map = nil;
    if (!map) {
        map = @{
            @"DEFAULT":           @0,
            @"COMMENTS":          @1,
            @"LINE COMMENTS":     @2,
            @"NUMBERS":           @3,
            @"KEYWORDS1":         @4, @"KEYWORDS2": @5, @"KEYWORDS3": @6, @"KEYWORDS4": @7,
            @"KEYWORDS5":         @8, @"KEYWORDS6": @9, @"KEYWORDS7": @10, @"KEYWORDS8": @11,
            @"OPERATORS":         @12,
            @"FOLDER IN CODE1":   @13,
            @"FOLDER IN CODE2":   @14,
            @"FOLDER IN COMMENT": @15,
            @"DELIMITERS1":       @16, @"DELIMITERS2": @17, @"DELIMITERS3": @18, @"DELIMITERS4": @19,
            @"DELIMITERS5":       @20, @"DELIMITERS6": @21, @"DELIMITERS7": @22, @"DELIMITERS8": @23,
        };
    }
    NSNumber *n = map[name.uppercaseString];
    return n ? n.intValue : -1;
}

@end
