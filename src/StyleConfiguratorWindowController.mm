#import "StyleConfiguratorWindowController.h"
#import "NppPaths.h"
#import "PreferencesWindowController.h"
#import "NppLocalizer.h"
#import "NppLangsManager.h"

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - NPPStyleEntry
// ─────────────────────────────────────────────────────────────────────────────

@implementation NPPStyleEntry
- (instancetype)init {
    self = [super init];
    if (self) { _keywordClass = @""; _keywords = @""; }
    return self;
}
- (id)copyWithZone:(NSZone *)zone {
    NPPStyleEntry *c    = [NPPStyleEntry new];
    c.name              = [_name copy];
    c.styleID           = _styleID;
    c.fgColor           = [_fgColor copy];
    c.bgColor           = [_bgColor copy];
    c.fontName          = [_fontName copy];
    c.fontSize          = _fontSize;
    c.bold              = _bold;
    c.italic            = _italic;
    c.underline         = _underline;
    c.fontStyleExplicit = _fontStyleExplicit;
    c.keywordClass      = [_keywordClass copy];
    c.keywords          = [_keywords copy];
    return c;
}
@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - NPPLexer
// ─────────────────────────────────────────────────────────────────────────────

@implementation NPPLexer
- (instancetype)init { self = [super init]; _styles = [NSMutableArray new]; return self; }
- (nullable NPPStyleEntry *)styleForID:(int)sid {
    for (NPPStyleEntry *e in _styles) if (e.styleID == sid) return e;
    return nil;
}
- (nullable NPPStyleEntry *)styleForName:(NSString *)name {
    for (NPPStyleEntry *e in _styles) if ([e.name isEqualToString:name]) return e;
    return nil;
}
- (id)copyWithZone:(NSZone *)zone {
    NPPLexer *c     = [NPPLexer new];
    c.lexerID       = [_lexerID copy];
    c.displayName   = [_displayName copy];
    for (NPPStyleEntry *e in _styles) [c.styles addObject:[e copy]];
    return c;
}
@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Color helpers
// ─────────────────────────────────────────────────────────────────────────────

static NSColor * _Nullable colorFromRRGGBB(NSString * _Nullable hex) {
    if (!hex.length || hex.length < 6) return nil;
    unsigned int v = 0;
    [[NSScanner scannerWithString:hex] scanHexInt:&v];
    return [NSColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                           green:((v >>  8) & 0xFF) / 255.0
                            blue:( v        & 0xFF) / 255.0
                           alpha:1.0];
}

/// Collapse a keyword list (XML text or the user's typing) to single-space
/// separated words.
static NSString *normalizedKeywords(NSString * _Nullable text) {
    NSArray<NSString *> *parts = [text ?: @"" componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *words = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *w in parts) if (w.length) [words addObject:w];
    return [words componentsJoinedByString:@" "];
}

static NSString *hexFromColor(NSColor *c) {
    NSColor *r = [c colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
    unsigned int rv = (unsigned int)(r.redComponent   * 255.0 + 0.5);
    unsigned int gv = (unsigned int)(r.greenComponent * 255.0 + 0.5);
    unsigned int bv = (unsigned int)(r.blueComponent  * 255.0 + 0.5);
    return [NSString stringWithFormat:@"%02X%02X%02X", rv, gv, bv];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - NPPStyleStore
// ─────────────────────────────────────────────────────────────────────────────

static NSString *const kNSDefaultsStyleKey  = @"NPPStyleOverrides";
static NSString *const kNSDefaultsThemeKey  = @"NPPActiveTheme";
static NSString *const kDefaultThemeName    = @"Default (stylers.xml)";

/// Mapping: theme/model lexer ID aliases.
/// "c", "objc" and "typescript" are real sections with their own styles (as on
/// Windows); they are not folded into "cpp".
static NSString *modelLexerID(NSString *themeID) {
    NSDictionary<NSString *, NSString *> *aliases = @{
        @"hypertext"  : @"html",
        @"js"         : @"javascript.js",
        @"ts"         : @"typescript",
    };
    NSString *mapped = aliases[themeID.lowercaseString];
    return mapped ?: themeID.lowercaseString;
}

@implementation NPPStyleStore {
    NSMutableArray<NPPLexer *> *_lexers;
    NSDictionary<NSString *, NPPLexer *> *_lexerDict;
    NSString *_activeThemeName;
}

+ (NPPStyleStore *)sharedStore {
    static NPPStyleStore *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NPPStyleStore new]; });
    return s;
}

// ── XML parsing ──────────────────────────────────────────────────────────────

- (NPPStyleEntry *)_parseElement:(NSXMLElement *)el {
    NPPStyleEntry *s    = [NPPStyleEntry new];
    s.name              = [el attributeForName:@"name"].stringValue ?: @"";
    s.styleID           = [[el attributeForName:@"styleID"].stringValue intValue];
    s.fgColor           = colorFromRRGGBB([el attributeForName:@"fgColor"].stringValue);
    s.bgColor           = colorFromRRGGBB([el attributeForName:@"bgColor"].stringValue);
    s.fontName          = [el attributeForName:@"fontName"].stringValue ?: @"";
    NSString *fsSz      = [el attributeForName:@"fontSize"].stringValue;
    s.fontSize          = (fsSz.length > 0) ? fsSz.intValue : 0;
    NSString *fst       = [el attributeForName:@"fontStyle"].stringValue;
    s.fontStyleExplicit = (fst.length > 0);
    if (s.fontStyleExplicit) {
        int fstVal = fst.intValue;
        s.bold      = (fstVal & 1) != 0;
        s.italic    = (fstVal & 2) != 0;
        s.underline = (fstVal & 4) != 0;
    }
    s.keywordClass      = [el attributeForName:@"keywordClass"].stringValue ?: @"";
    s.keywords          = normalizedKeywords(el.stringValue);
    return s;
}

- (NSMutableArray<NPPLexer *> *)_parseXML:(NSXMLDocument *)doc {
    NSMutableArray<NPPLexer *> *result = [NSMutableArray new];

    // Global Styles first (use name matching, since WidgetStyle uses name not styleID for lookup)
    NPPLexer *globalLexer   = [NPPLexer new];
    globalLexer.lexerID     = @"global";
    globalLexer.displayName = @"Global Styles";
    NSArray *widgets = [doc nodesForXPath:@"//GlobalStyles/WidgetStyle" error:nil];
    for (NSXMLElement *el in widgets)
        [globalLexer.styles addObject:[self _parseElement:el]];
    [result addObject:globalLexer];

    // Per-language lexers
    NSArray *lexerTypes = [doc nodesForXPath:@"//LexerStyles/LexerType" error:nil];
    for (NSXMLElement *lt in lexerTypes) {
        NPPLexer *lex      = [NPPLexer new];
        lex.lexerID        = [lt attributeForName:@"name"].stringValue.lowercaseString ?: @"";
        lex.displayName    = [lt attributeForName:@"desc"].stringValue ?: lex.lexerID;
        NSArray *words     = [lt nodesForXPath:@"WordsStyle" error:nil];
        for (NSXMLElement *el in words)
            [lex.styles addObject:[self _parseElement:el]];
        if (lex.lexerID.length) [result addObject:lex];
    }
    return result;
}

- (NSMutableArray<NPPLexer *> *)_parseDefaultXML {
    // Read from ~/Library/Application Support/Nextpad++/stylers.xml first (user-editable), fall back to bundle model.
    NSString *userStylers = NppConfigSubpath(@"stylers.xml");
    NSURL *url = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:userStylers]) {
        url = [NSURL fileURLWithPath:userStylers];
    } else {
        url = [[NSBundle mainBundle] URLForResource:@"stylers.model" withExtension:@"xml"];
    }
    if (!url) { NSLog(@"[NPPStyleStore] stylers.xml not found"); return [NSMutableArray new]; }
    NSData *data = [NSData dataWithContentsOfURL:url];
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:nil];
    return doc ? [self _parseXML:doc] : [NSMutableArray new];
}

// ── Merge theme entry into target ─────────────────────────────────────────────

- (void)_mergeThemeEntry:(NPPStyleEntry *)src into:(NPPStyleEntry *)dst {
    if (src.fgColor)           dst.fgColor  = src.fgColor;
    if (src.bgColor)           dst.bgColor  = src.bgColor;
    if (src.fontName.length)   dst.fontName = src.fontName;
    if (src.fontSize > 0)      dst.fontSize = src.fontSize;
    if (src.fontStyleExplicit) {
        dst.bold      = src.bold;
        dst.italic    = src.italic;
        dst.underline = src.underline;
        dst.fontStyleExplicit = YES;
    }
    // The theme has this element, so its keyword text replaces the model's
    // verbatim, an empty list included (that is how a theme clears one).
    if (dst.keywordClass.length) dst.keywords = src.keywords ?: @"";
}

// ── Load theme from XML ───────────────────────────────────────────────────────

- (NSArray<NPPLexer *> *)lexersForTheme:(NSString *)themeName {
    // Start from clean defaults
    NSMutableArray<NPPLexer *> *result = [self _parseDefaultXML];

    if ([themeName isEqualToString:kDefaultThemeName] || !themeName.length) {
        return result; // "Default (stylers.xml)" = pure model defaults
    }

    // Find theme XML: check user ~/Library/Application Support/Nextpad++/themes/ first, then bundle
    NSURL *themeURL = nil;
    NSString *userPath = [_userThemesDir() stringByAppendingPathComponent:
                          [themeName stringByAppendingPathExtension:@"xml"]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:userPath]) {
        themeURL = [NSURL fileURLWithPath:userPath];
    } else {
        themeURL = [[NSBundle mainBundle] URLForResource:themeName
                                          withExtension:@"xml"
                                           subdirectory:@"themes"];
    }
    if (!themeURL) {
        NSLog(@"[NPPStyleStore] Theme not found: %@", themeName);
        return result;
    }
    NSData *data = [NSData dataWithContentsOfURL:themeURL];
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:nil];
    if (!doc) return result;

    // Build quick lookup by lexerID
    NSMutableDictionary<NSString *, NPPLexer *> *lookup = [NSMutableDictionary new];
    for (NPPLexer *lex in result) lookup[lex.lexerID] = lex;

    // Merge GlobalStyles (match by name, not styleID)
    NPPLexer *globalLex = lookup[@"global"];
    NSArray<NSXMLElement *> *widgets = [doc nodesForXPath:@"//GlobalStyles/WidgetStyle" error:nil];
    for (NSXMLElement *el in widgets) {
        NPPStyleEntry *themeEntry = [self _parseElement:el];
        NPPStyleEntry *target = [globalLex styleForName:themeEntry.name];
        if (target) [self _mergeThemeEntry:themeEntry into:target];
    }

    // Merge per-language styles
    NSArray<NSXMLElement *> *lexerTypes = [doc nodesForXPath:@"//LexerStyles/LexerType" error:nil];
    for (NSXMLElement *lt in lexerTypes) {
        NSString *rawID = [lt attributeForName:@"name"].stringValue.lowercaseString ?: @"";
        NSString *lid   = modelLexerID(rawID); // e.g. "c" → "cpp"
        NPPLexer *lex   = lookup[lid];
        // If not found by alias, try original ID too
        if (!lex) lex   = lookup[rawID];
        if (!lex) continue;
        NSArray<NSXMLElement *> *words = [lt nodesForXPath:@"WordsStyle" error:nil];
        for (NSXMLElement *el in words) {
            NPPStyleEntry *themeEntry = [self _parseElement:el];
            NPPStyleEntry *target = [lex styleForID:themeEntry.styleID];
            if (target) [self _mergeThemeEntry:themeEntry into:target];
        }
    }
    return result;
}

// ── Available themes ──────────────────────────────────────────────────────────

/// Return path to ~/Library/Application Support/Nextpad++/themes/ (user-installed themes directory).
static NSString *_userThemesDir(void) {
    return NppConfigSubpath(@"themes");
}

- (NSArray<NSString *> *)availableThemeNames {
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    [names addObject:kDefaultThemeName];

    NSMutableSet<NSString *> *seen = [NSMutableSet new]; // deduplicate by name

    // Scan user themes first (~/Library/Application Support/Nextpad++/themes/) — user themes override bundled
    NSString *userDir = _userThemesDir();
    NSArray<NSString *> *userFiles = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:userDir error:nil];
    for (NSString *f in userFiles) {
        if ([f.pathExtension.lowercaseString isEqualToString:@"xml"])
            [seen addObject:f.stringByDeletingPathExtension];
    }

    // Scan bundled themes (Resources/themes/)
    NSURL *bundleDir = [[NSBundle mainBundle] URLForResource:@"themes" withExtension:nil];
    if (bundleDir) {
        NSArray<NSURL *> *files = [[NSFileManager defaultManager]
            contentsOfDirectoryAtURL:bundleDir
            includingPropertiesForKeys:nil
            options:NSDirectoryEnumerationSkipsHiddenFiles
            error:nil];
        for (NSURL *u in files) {
            if ([u.pathExtension.lowercaseString isEqualToString:@"xml"])
                [seen addObject:u.URLByDeletingPathExtension.lastPathComponent];
        }
    }

    NSMutableArray<NSString *> *sorted = [seen.allObjects mutableCopy];
    [sorted sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [names addObjectsFromArray:sorted];
    return [names copy];
}

// ── Apply overrides from NSUserDefaults ───────────────────────────────────────

- (void)_applyUserOverrides:(NSDictionary *)overrides to:(NSMutableArray<NPPLexer *> *)lexers {
    if (!overrides.count) return;
    NSMutableDictionary<NSString *, NPPLexer *> *dict = [NSMutableDictionary new];
    for (NPPLexer *lex in lexers) dict[lex.lexerID] = lex;
    for (NSString *key in overrides) {
        NSArray<NSString *> *parts = [key componentsSeparatedByString:@"|"];
        if (parts.count != 3) continue;
        NSString *lid  = parts[0];
        NSString *sidOrName = parts[1];
        NSString *prop = parts[2];
        NPPLexer  *lex = dict[lid];
        if (!lex) continue;
        // Global styles use name as key (many share styleID=0).
        // Lexer styles use styleID (unique within each lexer).
        // Detect by checking if the middle part is numeric.
        NPPStyleEntry *entry;
        BOOL isNumeric = sidOrName.length > 0 && [sidOrName rangeOfCharacterFromSet:
            [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound;
        if ([lid isEqualToString:@"global"] && !isNumeric) {
            entry = [lex styleForName:sidOrName];
        } else {
            entry = [lex styleForID:sidOrName.intValue];
        }
        if (!entry) continue;
        id val = overrides[key];
        if ([prop isEqualToString:@"fg"])         entry.fgColor   = colorFromRRGGBB(val);
        else if ([prop isEqualToString:@"bg"])     entry.bgColor   = colorFromRRGGBB(val);
        else if ([prop isEqualToString:@"fontName"])  entry.fontName  = val;
        else if ([prop isEqualToString:@"fontSize"])  entry.fontSize  = [val intValue];
        else if ([prop isEqualToString:@"bold"])      entry.bold      = [val boolValue];
        else if ([prop isEqualToString:@"italic"])    entry.italic    = [val boolValue];
        else if ([prop isEqualToString:@"underline"]) entry.underline = [val boolValue];
        else if ([prop isEqualToString:@"keywords"])  entry.keywords  = normalizedKeywords(val);
    }
}

// ── Public API ────────────────────────────────────────────────────────────────

- (void)loadFromDefaults {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *savedTheme = [ud stringForKey:kNSDefaultsThemeKey] ?: kDefaultThemeName;
    _activeThemeName = savedTheme;

    // Load theme (model + XML merge)
    NSMutableArray<NPPLexer *> *base = [[self lexersForTheme:savedTheme] mutableCopy];

    // Apply user overrides on top
    NSDictionary *saved = [ud dictionaryForKey:kNSDefaultsStyleKey];
    if (saved) [self _applyUserOverrides:saved to:base];

    _lexers = base;
    [self _buildDict];
}

- (void)_buildDict {
    NSMutableDictionary *d = [NSMutableDictionary new];
    for (NPPLexer *lex in _lexers) d[lex.lexerID] = lex;
    _lexerDict = [d copy];
}

- (nullable NSArray<NPPStyleEntry *> *)stylesForLexer:(NSString *)lexerID {
    if (!_lexers.count) [self loadFromDefaults];
    NSString *lid = lexerID.lowercaseString;
    if ([lid isEqualToString:@"c"] || [lid isEqualToString:@"objc"])  lid = @"cpp";
    else if ([lid isEqualToString:@"js"])   lid = @"javascript";
    else if ([lid isEqualToString:@"ts"])   lid = @"typescript";
    NPPLexer *lex = _lexerDict[lid];
    return lex ? lex.styles : nil;
}

- (nullable NSArray<NPPStyleEntry *> *)stylesForExactLexer:(NSString *)lexerID {
    if (!_lexers.count) [self loadFromDefaults];
    return _lexerDict[lexerID.lowercaseString].styles;
}

- (NSArray<NPPLexer *> *)allLexers {
    if (!_lexers.count) [self loadFromDefaults];
    return _lexers;
}

- (NPPStyleEntry *)_globalDefaultEntry {
    if (!_lexers.count) [self loadFromDefaults];
    NPPLexer *g = _lexerDict[@"global"];
    NPPStyleEntry *e = [g styleForID:32];
    if (!e) e = [g styleForName:@"Default Style"];
    return e;
}
- (NSColor *)globalFg   { NPPStyleEntry *e = [self _globalDefaultEntry]; return e.fgColor ?: [NSColor blackColor]; }
- (NSColor *)globalBg   { NPPStyleEntry *e = [self _globalDefaultEntry]; return e.bgColor ?: [NSColor whiteColor]; }
- (NSString *)globalFontName { NPPStyleEntry *e = [self _globalDefaultEntry]; return (e.fontName.length) ? e.fontName : @"Menlo"; }
- (int)globalFontSize   { NPPStyleEntry *e = [self _globalDefaultEntry]; return e.fontSize > 0 ? e.fontSize : 11; }

- (nullable NPPStyleEntry *)globalStyleNamed:(NSString *)name {
    if (!_lexers.count) [self loadFromDefaults];
    NPPLexer *g = _lexerDict[@"global"];
    return g ? [g styleForName:name] : nil;
}

- (void)previewLexers:(NSArray<NPPLexer *> *)lexers {
    _lexers = [NSMutableArray new];
    for (NPPLexer *lex in lexers) [_lexers addObject:[lex copy]];
    [self _buildDict];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"NPPPreferencesChanged"
                      object:nil
                    userInfo:@{@"themeChanged": @YES}];
}

- (void)commitLexers:(NSArray<NPPLexer *> *)lexers themeName:(NSString *)themeName {
    _activeThemeName = themeName;  // Set BEFORE preview so applyThemeColors reads the correct theme name
    [self previewLexers:lexers];

    // Serialize diffs against clean theme baseline (no user overrides)
    NSArray<NPPLexer *> *baseline = [self lexersForTheme:themeName];
    NSMutableDictionary<NSString *, NPPLexer *> *baseDict = [NSMutableDictionary new];
    for (NPPLexer *lex in baseline) baseDict[lex.lexerID] = lex;

    NSMutableDictionary *overrides = [NSMutableDictionary new];
    BOOL isGlobal;
    for (NPPLexer *lex in _lexers) {
        NPPLexer *baseLex = baseDict[lex.lexerID];
        isGlobal = [lex.lexerID isEqualToString:@"global"];
        for (NPPStyleEntry *e in lex.styles) {
            // For Global Styles, use name as key (many entries share styleID=0).
            // For lexer styles, use styleID (unique within each lexer).
            NPPStyleEntry *b = isGlobal ? [baseLex styleForName:e.name]
                                        : [baseLex styleForID:e.styleID];
            NSString *base = isGlobal
                ? [NSString stringWithFormat:@"%@|%@|", lex.lexerID, e.name]
                : [NSString stringWithFormat:@"%@|%d|", lex.lexerID, e.styleID];
            NSString *bFg = b.fgColor ? hexFromColor(b.fgColor) : nil;
            NSString *eFg = e.fgColor ? hexFromColor(e.fgColor) : nil;
            if (eFg && ![eFg isEqualToString:bFg]) overrides[[base stringByAppendingString:@"fg"]] = eFg;
            NSString *bBg = b.bgColor ? hexFromColor(b.bgColor) : nil;
            NSString *eBg = e.bgColor ? hexFromColor(e.bgColor) : nil;
            if (eBg && ![eBg isEqualToString:bBg]) overrides[[base stringByAppendingString:@"bg"]] = eBg;
            if (e.fontName.length && ![e.fontName isEqualToString:b.fontName ?: @""])
                overrides[[base stringByAppendingString:@"fontName"]] = e.fontName;
            if (e.fontSize > 0 && e.fontSize != (b ? b.fontSize : 0))
                overrides[[base stringByAppendingString:@"fontSize"]] = @(e.fontSize);
            if (e.fontStyleExplicit) {
                if (e.bold != (b ? b.bold : NO))        overrides[[base stringByAppendingString:@"bold"]]    = @(e.bold);
                if (e.italic != (b ? b.italic : NO))    overrides[[base stringByAppendingString:@"italic"]]  = @(e.italic);
                if (e.underline != (b ? b.underline : NO)) overrides[[base stringByAppendingString:@"underline"]] = @(e.underline);
            }
            // User-defined keywords; an empty string records a cleared list.
            if (e.keywordClass.length && ![e.keywords ?: @"" isEqualToString:b.keywords ?: @""])
                overrides[[base stringByAppendingString:@"keywords"]] = e.keywords ?: @"";
        }
    }

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:overrides forKey:kNSDefaultsStyleKey];
    [ud setObject:themeName forKey:kNSDefaultsThemeKey];

    // Legacy keys for backward compat
    [ud setObject:[@"#" stringByAppendingString:hexFromColor(self.globalFg)] forKey:kPrefStyleFg];
    [ud setObject:[@"#" stringByAppendingString:hexFromColor(self.globalBg)] forKey:kPrefStyleBg];
    [ud setObject:self.globalFontName forKey:kPrefStyleFontName];
    [ud setInteger:self.globalFontSize forKey:kPrefStyleFontSize];

    // Write changes back to the XML file (selective update, not full rewrite).
    [self _writeOverridesToXML:overrides themeName:themeName];
}

/// Append a WordsStyle row (name, styleID, keywordClass from the in-memory
/// entry) under LexerType `lexerID`, creating the LexerType if needed.
/// Returns the new element, or nil when there is no such entry.
- (nullable NSArray<NSXMLElement *> *)_addWordsStyleForLexer:(NSString *)lexerID
                                                      styleID:(NSString *)sid
                                                   toDocument:(NSXMLDocument *)doc {
    NPPStyleEntry *entry = [_lexerDict[lexerID] styleForID:sid.intValue];
    if (!entry.keywordClass.length) return nil;
    NSString *ltPath = [NSString stringWithFormat:@"//LexerStyles/LexerType[@name='%@']", lexerID];
    NSXMLElement *lt = [doc nodesForXPath:ltPath error:nil].firstObject;
    if (!lt) {
        NSXMLElement *styles = [doc nodesForXPath:@"//LexerStyles" error:nil].firstObject;
        if (!styles) return nil;
        lt = [NSXMLElement elementWithName:@"LexerType"];
        [lt addAttribute:[NSXMLNode attributeWithName:@"name" stringValue:lexerID]];
        [lt addAttribute:[NSXMLNode attributeWithName:@"desc"
                                          stringValue:_lexerDict[lexerID].displayName ?: lexerID]];
        [lt addAttribute:[NSXMLNode attributeWithName:@"ext" stringValue:@""]];
        [styles addChild:lt];
    }
    NSXMLElement *ws = [NSXMLElement elementWithName:@"WordsStyle"];
    [ws addAttribute:[NSXMLNode attributeWithName:@"name" stringValue:entry.name ?: @""]];
    [ws addAttribute:[NSXMLNode attributeWithName:@"styleID" stringValue:sid]];
    [ws addAttribute:[NSXMLNode attributeWithName:@"keywordClass" stringValue:entry.keywordClass]];
    [lt addChild:ws];
    return @[ ws ];
}

/// Selectively update changed style attributes in the theme/stylers XML file.
/// Only modifies attribute values for entries that have overrides — preserves
/// file structure, comments, and unchanged entries.
- (void)_writeOverridesToXML:(NSDictionary *)overrides themeName:(NSString *)themeName {
    if (!overrides.count) return;

    // Determine target XML file
    NSString *xmlPath;
    if ([themeName isEqualToString:kDefaultThemeName] || !themeName.length) {
        xmlPath = NppConfigSubpath(@"stylers.xml");
    } else {
        // User themes dir first; if not there, copy from bundle
        NSString *userPath = [_userThemesDir() stringByAppendingPathComponent:
                              [themeName stringByAppendingPathExtension:@"xml"]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:userPath]) {
            xmlPath = userPath;
        } else {
            // Bundled theme — copy to user themes dir before modifying
            NSURL *bundleURL = [[NSBundle mainBundle] URLForResource:themeName
                                                      withExtension:@"xml"
                                                       subdirectory:@"themes"];
            if (!bundleURL) return;
            [[NSFileManager defaultManager] copyItemAtPath:bundleURL.path
                                                    toPath:userPath error:nil];
            xmlPath = userPath;
        }
    }

    NSData *data = [NSData dataWithContentsOfFile:xmlPath];
    if (!data) return;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data
                                                     options:NSXMLNodePreserveWhitespace
                                                       error:nil];
    if (!doc) return;

    BOOL changed = NO;
    for (NSString *key in overrides) {
        NSArray<NSString *> *parts = [key componentsSeparatedByString:@"|"];
        if (parts.count != 3) continue;
        NSString *lexerID = parts[0];
        NSString *sidOrName = parts[1];
        NSString *prop = parts[2];
        id val = overrides[key];

        // Find the XML element to update
        NSArray<NSXMLElement *> *elements = nil;
        if ([lexerID isEqualToString:@"global"]) {
            // Global style: match by name attribute
            NSString *xpath = [NSString stringWithFormat:
                @"//GlobalStyles/WidgetStyle[@name='%@']", sidOrName];
            elements = [doc nodesForXPath:xpath error:nil];
        } else {
            // Lexer style: match by LexerType name + WordsStyle styleID
            BOOL isNumeric = sidOrName.length > 0 && [sidOrName rangeOfCharacterFromSet:
                [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound;
            if (isNumeric) {
                NSString *xpath = [NSString stringWithFormat:
                    @"//LexerStyles/LexerType[@name='%@']/WordsStyle[@styleID='%@']",
                    lexerID, sidOrName];
                elements = [doc nodesForXPath:xpath error:nil];
            }
        }
        // A theme file without this row would otherwise lose a keyword edit
        // (an explicit empty list included) once another theme is saved and
        // the NSUserDefaults override is replaced: add the row so the file
        // itself carries the list.
        if (!elements.count && [prop isEqualToString:@"keywords"]) {
            elements = [self _addWordsStyleForLexer:lexerID styleID:sidOrName toDocument:doc];
            if (elements.count) changed = YES;
        }
        if (!elements.count) continue;

        NSXMLElement *el = elements[0];
        // User-defined keywords are the element text, not an attribute.
        if ([prop isEqualToString:@"keywords"]) {
            if (![el.stringValue isEqualToString:val]) {
                el.stringValue = val;
                changed = YES;
            }
            continue;
        }
        // Map property name to XML attribute name
        NSString *attrName = nil;
        NSString *attrVal = nil;
        if ([prop isEqualToString:@"fg"])          { attrName = @"fgColor";   attrVal = val; }
        else if ([prop isEqualToString:@"bg"])      { attrName = @"bgColor";   attrVal = val; }
        else if ([prop isEqualToString:@"fontName"]) { attrName = @"fontName";  attrVal = val; }
        else if ([prop isEqualToString:@"fontSize"]) { attrName = @"fontSize";  attrVal = [val stringValue]; }
        else if ([prop isEqualToString:@"bold"] || [prop isEqualToString:@"italic"]
                 || [prop isEqualToString:@"underline"]) {
            // Recalculate fontStyle bitmask from current overrides
            NSXMLNode *fstNode = [el attributeForName:@"fontStyle"];
            int fst = fstNode ? fstNode.stringValue.intValue : 0;
            int bit = [prop isEqualToString:@"bold"] ? 1
                    : [prop isEqualToString:@"italic"] ? 2 : 4;
            if ([val boolValue]) fst |= bit; else fst &= ~bit;
            attrName = @"fontStyle"; attrVal = [@(fst) stringValue];
        }

        if (attrName && attrVal) {
            NSXMLNode *attr = [el attributeForName:attrName];
            if (attr) {
                attr.stringValue = attrVal;
            } else {
                [el addAttribute:[NSXMLNode attributeWithName:attrName stringValue:attrVal]];
            }
            changed = YES;
        }
    }

    if (changed) {
        NSData *output = [doc XMLDataWithOptions:NSXMLNodePrettyPrint | NSXMLNodeCompactEmptyElement];
        [output writeToFile:xmlPath atomically:YES];
    }
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - _SCColorSwatch
// ─────────────────────────────────────────────────────────────────────────────

@interface _SCColorSwatch : NSButton
@property (nonatomic, strong) NSColor *swatchColor;
@property (nonatomic, weak)   id       colorTarget;
@property (nonatomic)         SEL      colorAction;
@end

@implementation _SCColorSwatch
- (instancetype)initWithFrame:(NSRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.bordered = NO;
        [self setButtonType:NSButtonTypeMomentaryPushIn];
        _swatchColor = [NSColor blackColor];
        [self setTarget:self];
        [self setAction:@selector(_clicked:)];
    }
    return self;
}
- (void)drawRect:(NSRect)dr {
    NSRect r = NSInsetRect(self.bounds, 0.5, 0.5);
    [_swatchColor setFill];
    NSRectFill(r);
    [[NSColor colorWithWhite:0.3 alpha:1] setStroke];
    [[NSBezierPath bezierPathWithRect:r] stroke];
}
- (void)_clicked:(id)s {
    NSColorPanel *cp = [NSColorPanel sharedColorPanel];
    [cp setTarget:self];
    [cp setAction:@selector(_colorPanelChanged:)];
    [cp setColor:_swatchColor];
    [cp orderFront:self];
}
- (void)_colorPanelChanged:(NSColorPanel *)cp {
    _swatchColor = cp.color;
    [self setNeedsDisplay:YES];
    if (_colorTarget && _colorAction)
        [NSApp sendAction:_colorAction to:_colorTarget from:self];
}
@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - StyleConfiguratorWindowController
// ─────────────────────────────────────────────────────────────────────────────

@interface StyleConfiguratorWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate>
@end

@implementation StyleConfiguratorWindowController {
    NSPopUpButton        *_themePopup;
    NSPopUpButton        *_langPopup;
    NSTableView          *_styleTable;
    NSTextField          *_headerLabel;
    _SCColorSwatch       *_fgSwatch, *_bgSwatch;
    NSTextField          *_fgLabel, *_bgLabel;
    NSPopUpButton        *_fontNamePopup, *_fontSizePopup;
    NSButton             *_boldCheck, *_italicCheck, *_underlineCheck;
    // Global override "Force … for all styles" checkboxes (Windows parity).
    // Hidden by default; shown only when the selected Style row is
    // "Global override". The 7 boolean prefs (kPrefGlobalOverrideEnable*)
    // back these — toggling re-skins all open editors via NPPPreferencesChanged.
    NSButton             *_forceFgCheck, *_forceBgCheck;
    NSButton             *_forceFontCheck, *_forceFontSizeCheck;
    NSButton             *_forceBoldCheck, *_forceItalicCheck, *_forceUnderlineCheck;
    // Snapshots for cancel-restore.
    BOOL                  _backupOverrideFg, _backupOverrideBg;
    BOOL                  _backupOverrideFont, _backupOverrideFontSize;
    BOOL                  _backupOverrideBold, _backupOverrideItalic, _backupOverrideUnderline;
    // Keyword lists for rows with a keywordClass (Windows "Default keywords"
    // + "User-defined keywords"). Hidden for every other row.
    NSTextField          *_defKeywordsLabel, *_userKeywordsLabel;
    NSScrollView         *_defKeywordsScroll, *_userKeywordsScroll;
    NSTextView           *_defKeywordsView, *_userKeywordsView;
    BOOL                  _userKeywordsDirty;   // typed since the last preview
    // The user keywords view's own undo stack, emptied whenever the view is
    // filled for another row, so Undo never replays edits onto other text.
    NSUndoManager        *_userKeywordsUndo;

    // Working copy — edited by user; cancelled on Cancel; committed on Save
    NSMutableArray<NPPLexer *>  *_workingLexers;
    // Snapshot taken when window opens — restored on Cancel
    NSArray<NPPLexer *>         *_cancelBackup;
    NSString                    *_cancelTheme;
    // Currently displayed styles
    NSArray<NPPStyleEntry *>    *_currentStyles;
    int                          _selectedStyleID;
    NSString                    *_selectedStyleName;  // name of selected style (needed for global styleID=0 collision)
    // Active theme name in working copy
    NSString                    *_workingTheme;
    // Suppress feedback loops when populating UI
    BOOL                         _suppressActions;
}

+ (instancetype)sharedController {
    static StyleConfiguratorWindowController *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 780, 510)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    win.title = [[NppLocalizer shared] translate:@"Style Configurator"];
    win.releasedWhenClosed = NO;
    self = [super initWithWindow:win];
    if (self) {
        [self _buildUI];
        _selectedStyleID = -1;
    }
    return self;
}

// ── UI construction ───────────────────────────────────────────────────────────

- (void)_buildUI {
    NSView *cv = self.window.contentView;
    const CGFloat W = 780, H = 510;
    const CGFloat pad = 16;

    // Theme row
    CGFloat y = H - 30;
    NSTextField *themeLbl = [self _label:[[NppLocalizer shared] translate:@"Select theme:"]];
    themeLbl.frame = NSMakeRect(W - pad - 250 - 110, y - 3, 110, 20);
    [cv addSubview:themeLbl];

    _themePopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(W - pad - 250, y - 3, 250, 25) pullsDown:NO];
    _themePopup.target = self;
    _themePopup.action = @selector(_themeChanged:);
    [cv addSubview:_themePopup];

    // Left panel – Language / Style
    NSBox *leftBox = [[NSBox alloc] initWithFrame:NSMakeRect(pad, 50, 245, 425)];
    leftBox.title = @"";
    leftBox.titlePosition = NSNoTitle;
    [cv addSubview:leftBox];
    NSView *lc = leftBox.contentView;
    CGFloat lcH = lc.bounds.size.height;
    CGFloat lcW = lc.bounds.size.width;

    NSTextField *langLbl = [self _label:[[NppLocalizer shared] translate:@"Language:"]];
    langLbl.frame = NSMakeRect(6, lcH - 24, lcW - 12, 18);
    [lc addSubview:langLbl];

    _langPopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(6, lcH - 52, lcW - 12, 24) pullsDown:NO];
    _langPopup.target = self;
    _langPopup.action = @selector(_langChanged:);
    [lc addSubview:_langPopup];

    NSTextField *styleLbl = [self _label:[[NppLocalizer shared] translate:@"Style:"]];
    styleLbl.frame = NSMakeRect(6, lcH - 76, lcW - 12, 18);
    [lc addSubview:styleLbl];

    // Style list – allow horizontal scroll so no names are clipped
    NSScrollView *sv = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(6, 6, lcW - 12, lcH - 84)];
    sv.hasVerticalScroller   = YES;
    sv.hasHorizontalScroller = YES;
    sv.autohidesScrollers    = YES;
    sv.borderType            = NSBezelBorder;
    _styleTable = [[NSTableView alloc] initWithFrame:sv.bounds];
    _styleTable.headerView = nil;
    _styleTable.rowHeight  = 18;
    _styleTable.font       = [NSFont systemFontOfSize:12];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"style"];
    col.width = 3000;  // wide enough that names are never truncated
    col.resizingMask = NSTableColumnNoResizing;
    col.editable = NO;  // style names are not user-editable
    [_styleTable addTableColumn:col];
    _styleTable.dataSource = self;
    _styleTable.delegate   = self;
    sv.documentView = _styleTable;
    [lc addSubview:sv];

    // Right panel
    CGFloat rx = pad + 245 + 12;
    CGFloat rw = W - rx - pad;
    CGFloat ry = 50;
    CGFloat rh = 425;

    _headerLabel = [NSTextField labelWithString:@""];
    _headerLabel.frame = NSMakeRect(rx, ry + rh - 26, rw, 22);
    _headerLabel.textColor = [NSColor systemBlueColor];
    _headerLabel.font = [NSFont boldSystemFontOfSize:13];
    [cv addSubview:_headerLabel];

    // Boxes occupy the upper portion of the right pane; checkboxes for the
    // Global override row live in the space below (issue #149 follow-up:
    // mirrors Windows Style Configurator layout exactly).
    CGFloat boxH = 200;
    CGFloat boxY = ry + rh - 30 - boxH; // top edge sits ~30pt below header
    CGFloat csW  = rw * 0.45;
    CGFloat fsX  = rx + csW + 10;
    CGFloat fsW  = rw - csW - 10;

    NSBox *colourBox = [[NSBox alloc] initWithFrame:NSMakeRect(rx, boxY, csW, boxH)];
    colourBox.title = [[NppLocalizer shared] translate:@"Colour Style"];
    [cv addSubview:colourBox];
    [self _buildColourBox:colourBox];

    NSBox *fontBox = [[NSBox alloc] initWithFrame:NSMakeRect(fsX, boxY, fsW, boxH)];
    fontBox.title = [[NppLocalizer shared] translate:@"Font Style"];
    [cv addSubview:fontBox];
    [self _buildFontBox:fontBox];

    // ── Global override "Force …" checkboxes (Windows parity) ──────────────
    // Persistent controls; hidden by default and shown only when the selected
    // Style row is "Global override". Placed below the colour/font boxes.
    NppLocalizer *loc = [NppLocalizer shared];
    CGFloat coY    = boxY - 28;                 // first row of colour-side checks
    CGFloat coX    = rx + 6;                    // left aligned to colourBox
    CGFloat coW    = csW - 12;                  // span colourBox column
    CGFloat foX    = fsX + 6;                   // left aligned to fontBox
    CGFloat foW    = fsW - 12;

    _forceFgCheck = [NSButton checkboxWithTitle:
        [loc translate:@"Force foreground color for all styles"]
        target:self action:@selector(_forceFgChanged:)];
    _forceFgCheck.frame = NSMakeRect(coX, coY, coW, 18);
    [cv addSubview:_forceFgCheck];

    _forceBgCheck = [NSButton checkboxWithTitle:
        [loc translate:@"Force background color for all styles"]
        target:self action:@selector(_forceBgChanged:)];
    _forceBgCheck.frame = NSMakeRect(coX, coY - 22, coW, 18);
    [cv addSubview:_forceBgCheck];

    CGFloat foY = coY;
    _forceFontCheck = [NSButton checkboxWithTitle:
        [loc translate:@"Force font choice for all styles"]
        target:self action:@selector(_forceFontChanged:)];
    _forceFontCheck.frame = NSMakeRect(foX, foY, foW, 18);
    [cv addSubview:_forceFontCheck];

    _forceFontSizeCheck = [NSButton checkboxWithTitle:
        [loc translate:@"Force font size choice for all styles"]
        target:self action:@selector(_forceFontSizeChanged:)];
    _forceFontSizeCheck.frame = NSMakeRect(foX, foY - 22, foW, 18);
    [cv addSubview:_forceFontSizeCheck];

    _forceBoldCheck = [NSButton checkboxWithTitle:
        [loc translate:@"Force bold choice for all styles"]
        target:self action:@selector(_forceBoldChanged:)];
    _forceBoldCheck.frame = NSMakeRect(foX, foY - 44, foW, 18);
    [cv addSubview:_forceBoldCheck];

    _forceItalicCheck = [NSButton checkboxWithTitle:
        [loc translate:@"Force italic choice for all styles"]
        target:self action:@selector(_forceItalicChanged:)];
    _forceItalicCheck.frame = NSMakeRect(foX, foY - 66, foW, 18);
    [cv addSubview:_forceItalicCheck];

    _forceUnderlineCheck = [NSButton checkboxWithTitle:
        [loc translate:@"Force underline choice for all styles"]
        target:self action:@selector(_forceUnderlineChanged:)];
    _forceUnderlineCheck.frame = NSMakeRect(foX, foY - 88, foW, 18);
    [cv addSubview:_forceUnderlineCheck];

    // Start hidden — visibility flipped in -_updateRightPanelForStyle:.
    for (NSButton *b in @[ _forceFgCheck, _forceBgCheck,
                           _forceFontCheck, _forceFontSizeCheck,
                           _forceBoldCheck, _forceItalicCheck, _forceUnderlineCheck ])
        b.hidden = YES;

    // ── Keyword lists (Windows parity) ─────────────────────────────────────
    // Same space as the Global override checkboxes, which never show at the
    // same time: that row has no keywordClass. Left: the langs.xml group
    // (read-only). Right: user-defined keywords, saved as the WordsStyle text
    // and added to that group (for USER KEYWORDS rows, the substyle's words).
    CGFloat kwLabelY = boxY - 24;
    CGFloat kwBottom = ry + 8;
    CGFloat kwH      = kwLabelY - 4 - kwBottom;
    _defKeywordsLabel = [self _label:[loc translate:@"Default keywords"]];
    _defKeywordsLabel.frame = NSMakeRect(rx, kwLabelY, csW, 18);
    [cv addSubview:_defKeywordsLabel];
    _userKeywordsLabel = [self _label:[loc translate:@"User-defined keywords"]];
    _userKeywordsLabel.frame = NSMakeRect(fsX, kwLabelY, fsW, 18);
    [cv addSubview:_userKeywordsLabel];

    _defKeywordsScroll  = [self _keywordScrollWithFrame:NSMakeRect(rx, kwBottom, csW, kwH)
                                                editable:NO textView:&_defKeywordsView];
    [cv addSubview:_defKeywordsScroll];
    _userKeywordsScroll = [self _keywordScrollWithFrame:NSMakeRect(fsX, kwBottom, fsW, kwH)
                                               editable:YES textView:&_userKeywordsView];
    _userKeywordsView.delegate = self;
    _userKeywordsUndo = [NSUndoManager new];
    _defKeywordsView.accessibilityLabel  = _defKeywordsLabel.stringValue;
    _userKeywordsView.accessibilityLabel = _userKeywordsLabel.stringValue;
    [cv addSubview:_userKeywordsScroll];
    [self _setKeywordControlsHidden:YES];

    // Buttons
    NSButton *cancelBtn = [NSButton buttonWithTitle:[[NppLocalizer shared] translate:@"Cancel"]
                                             target:self action:@selector(_cancel:)];
    cancelBtn.frame = NSMakeRect(W - pad - 90, 14, 90, 28);
    cancelBtn.keyEquivalent = @"\033";
    [cv addSubview:cancelBtn];

    NSButton *saveBtn = [NSButton buttonWithTitle:[[NppLocalizer shared] translate:@"Save && Close"]
                                           target:self action:@selector(_saveAndClose:)];
    saveBtn.frame = NSMakeRect(W - pad - 90 - 120 - 8, 14, 120, 28);
    saveBtn.keyEquivalent = @"\r";
    saveBtn.bezelStyle = NSBezelStyleRounded;
    [cv addSubview:saveBtn];
}

- (void)_buildColourBox:(NSBox *)box {
    NSView *cv  = box.contentView;
    CGFloat cW  = cv.bounds.size.width;
    CGFloat cH  = cv.bounds.size.height;
    CGFloat midY = cH / 2.0;

    _fgLabel = [self _label:[[NppLocalizer shared] translate:@"Foreground colour"]];
    _fgLabel.frame = NSMakeRect(10, midY + 8, cW - 65, 18);
    [cv addSubview:_fgLabel];
    _fgSwatch = [[_SCColorSwatch alloc] initWithFrame:NSMakeRect(cW - 54, midY + 5, 42, 24)];
    _fgSwatch.colorTarget = self;
    _fgSwatch.colorAction = @selector(_fgColorChanged:);
    [cv addSubview:_fgSwatch];

    _bgLabel = [self _label:[[NppLocalizer shared] translate:@"Background colour"]];
    _bgLabel.frame = NSMakeRect(10, midY - 28, cW - 65, 18);
    [cv addSubview:_bgLabel];
    _bgSwatch = [[_SCColorSwatch alloc] initWithFrame:NSMakeRect(cW - 54, midY - 31, 42, 24)];
    _bgSwatch.colorTarget = self;
    _bgSwatch.colorAction = @selector(_bgColorChanged:);
    [cv addSubview:_bgSwatch];
}

- (void)_buildFontBox:(NSBox *)box {
    NSView *cv = box.contentView;
    CGFloat cW = cv.bounds.size.width;
    CGFloat cH = cv.bounds.size.height;

    NppLocalizer *loc = [NppLocalizer shared];
    NSTextField *fnLbl = [self _label:[loc translate:@"Font name:"]];
    fnLbl.frame = NSMakeRect(8, cH - 32, 72, 18);
    [cv addSubview:fnLbl];
    _fontNamePopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(82, cH - 35, cW - 90, 22) pullsDown:NO];
    [_fontNamePopup addItemWithTitle:[loc translate:@"(inherit)"]];
    NSArray<NSString *> *families = [[[NSFontManager sharedFontManager]
        availableFontFamilies] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *f in families) [_fontNamePopup addItemWithTitle:f];
    _fontNamePopup.target = self;
    _fontNamePopup.action = @selector(_fontNameChanged:);
    [cv addSubview:_fontNamePopup];

    CGFloat checkX = 8, checkY = cH - 68;
    _boldCheck = [NSButton checkboxWithTitle:[loc translate:@"Bold"]      target:self action:@selector(_boldChanged:)];
    _boldCheck.frame = NSMakeRect(checkX, checkY, 80, 18);
    [cv addSubview:_boldCheck];
    checkY -= 22;
    _italicCheck = [NSButton checkboxWithTitle:[loc translate:@"Italic"]  target:self action:@selector(_italicChanged:)];
    _italicCheck.frame = NSMakeRect(checkX, checkY, 80, 18);
    [cv addSubview:_italicCheck];
    checkY -= 22;
    _underlineCheck = [NSButton checkboxWithTitle:[loc translate:@"Underline"] target:self action:@selector(_underlineChanged:)];
    _underlineCheck.frame = NSMakeRect(checkX, checkY, 90, 18);
    [cv addSubview:_underlineCheck];

    NSTextField *szLbl = [self _label:[loc translate:@"Font size:"]];
    szLbl.frame = NSMakeRect(cW - 130, cH - 68, 70, 18);
    [cv addSubview:szLbl];
    _fontSizePopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(cW - 58, cH - 71, 50, 22) pullsDown:NO];
    [_fontSizePopup addItemWithTitle:[loc translate:@"(inherit)"]];
    for (NSNumber *sz in @[@6,@7,@8,@9,@10,@11,@12,@14,@16,@18,@20,@22,@24,@28,@36,@48,@72])
        [_fontSizePopup addItemWithTitle:[sz stringValue]];
    _fontSizePopup.target = self;
    _fontSizePopup.action = @selector(_fontSizeChanged:);
    [cv addSubview:_fontSizePopup];
}

- (NSTextField *)_label:(NSString *)text {
    NSTextField *f = [NSTextField labelWithString:text];
    f.font = [NSFont systemFontOfSize:12];
    return f;
}

/// A bordered, wrapping, vertically scrolling text view for a keyword list.
- (NSScrollView *)_keywordScrollWithFrame:(NSRect)frame editable:(BOOL)editable
                                 textView:(NSTextView * __strong *)outView {
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:frame];
    sv.hasVerticalScroller = YES;
    sv.autohidesScrollers  = YES;
    sv.borderType          = NSBezelBorder;
    NSSize content = sv.contentSize;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, content.width, content.height)];
    tv.minSize = NSMakeSize(0, content.height);
    tv.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    tv.verticallyResizable   = YES;
    tv.horizontallyResizable = NO;
    tv.autoresizingMask      = NSViewWidthSizable;
    tv.textContainer.containerSize = NSMakeSize(content.width, FLT_MAX);
    tv.textContainer.widthTracksTextView = YES;
    tv.font                  = [NSFont systemFontOfSize:11];
    tv.editable              = editable;
    tv.selectable            = YES;
    tv.richText              = NO;
    tv.allowsUndo            = editable;
    tv.automaticQuoteSubstitutionEnabled = NO;
    tv.automaticDashSubstitutionEnabled  = NO;
    tv.automaticTextReplacementEnabled   = NO;
    tv.automaticSpellingCorrectionEnabled = NO;
    tv.continuousSpellCheckingEnabled     = NO;
    if (!editable) tv.backgroundColor = [NSColor controlBackgroundColor];
    sv.documentView = tv;
    *outView = tv;
    return sv;
}

- (void)_setKeywordControlsHidden:(BOOL)hidden {
    for (NSView *v in @[ _defKeywordsLabel, _userKeywordsLabel,
                         _defKeywordsScroll, _userKeywordsScroll ])
        v.hidden = hidden;
}

/// Push typed user-defined keywords to open editors (they refeed their lists
/// when the keywords differ from what they last applied).
- (void)_previewUserKeywordsIfDirty {
    if (!_userKeywordsDirty) return;
    _userKeywordsDirty = NO;
    [[NPPStyleStore sharedStore] previewLexers:_workingLexers];
}

/// Fill both keyword views for a row (programmatic, so no textDidChange:) and
/// drop the user view's undo history, which belonged to the previous text.
- (void)_fillKeywordViewsDefault:(NSString *)def user:(NSString *)user {
    _defKeywordsView.string  = def ?: @"";
    _userKeywordsView.string = user ?: @"";
    [_userKeywordsUndo removeAllActions];
}

- (NSUndoManager *)undoManagerForTextView:(NSTextView *)view {
    return (view == _userKeywordsView) ? _userKeywordsUndo : self.window.undoManager;
}

// NSTextViewDelegate: typing only updates the working entry; the preview runs
// when editing ends, the row changes, or on Save, so a large list (PHP) is not
// refed into every open editor on each keystroke.
- (void)textDidChange:(NSNotification *)note {
    if (_suppressActions || note.object != _userKeywordsView) return;
    NPPStyleEntry *e = [self _currentEntry];
    if (!e.keywordClass.length) return;
    e.keywords = normalizedKeywords(_userKeywordsView.string);
    _userKeywordsDirty = YES;
}

- (void)textDidEndEditing:(NSNotification *)note {
    if (note.object != _userKeywordsView) return;
    [self _previewUserKeywordsIfDirty];
}

// ── Populate theme popup from bundle ─────────────────────────────────────────

- (void)_populateThemePopup {
    [_themePopup removeAllItems];
    NSArray<NSString *> *themes = [[NPPStyleStore sharedStore] availableThemeNames];
    for (NSString *t in themes) [_themePopup addItemWithTitle:t];
}

// ── Working copy management ───────────────────────────────────────────────────

- (void)_resetWorkingCopyForTheme:(NSString *)themeName {
    NSArray<NPPLexer *> *base = [[NPPStyleStore sharedStore] lexersForTheme:themeName];
    _workingLexers = [NSMutableArray new];
    for (NPPLexer *lex in base) [_workingLexers addObject:[lex copy]];
    _workingTheme = themeName;
}

- (NPPLexer *)_workingLexerForID:(NSString *)lid {
    for (NPPLexer *lex in _workingLexers) if ([lex.lexerID isEqualToString:lid]) return lex;
    return nil;
}

- (void)_populateLangPopup {
    [_langPopup removeAllItems];
    for (NPPLexer *lex in _workingLexers)
        [_langPopup addItemWithTitle:lex.displayName];
}

- (void)_selectLangAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)_workingLexers.count) return;
    _currentStyles = _workingLexers[idx].styles;
    [_styleTable reloadData];
    if (_currentStyles.count > 0) {
        // Auto-select the first row so the font / size / colour controls
        // have a target to write into. Without this the user can adjust
        // controls and click Save & Close with no row selected; every
        // callback short-circuits at `if (!e) return;` and nothing
        // persists — the silent no-op trap behind issue #52.
        // tableViewSelectionDidChange: then drives _updateRightPanelForStyle:
        // which populates the right panel from the freshly-selected entry.
        [_styleTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                 byExtendingSelection:NO];
        // If row 0 was already selected (language or theme switch), no
        // selection change is posted and the panel would keep showing, and
        // editing, the previous lexer's row. Refresh it explicitly.
        [self tableViewSelectionDidChange:
            [NSNotification notificationWithName:NSTableViewSelectionDidChangeNotification
                                          object:_styleTable]];
    } else {
        [_styleTable deselectAll:nil];
        _selectedStyleID = -1;
        [self _clearRightPanel];
    }
}

- (void)_clearRightPanel {
    _headerLabel.stringValue = @"";
    _fgSwatch.swatchColor = [NSColor colorWithWhite:0.85 alpha:1];
    _bgSwatch.swatchColor = [NSColor colorWithWhite:0.85 alpha:1];
    [_fgSwatch setNeedsDisplay:YES];
    [_bgSwatch setNeedsDisplay:YES];
    _suppressActions = YES;
    [_fontNamePopup selectItemAtIndex:0];
    [_fontSizePopup selectItemAtIndex:0];
    _boldCheck.state      = NSControlStateValueOff;
    _italicCheck.state    = NSControlStateValueOff;
    _underlineCheck.state = NSControlStateValueOff;
    _suppressActions = NO;
    _fgLabel.textColor = [NSColor secondaryLabelColor];
    _bgLabel.textColor = [NSColor secondaryLabelColor];
    [self _setKeywordControlsHidden:YES];
    [self _fillKeywordViewsDefault:nil user:nil];
}

- (void)_updateRightPanelForStyle:(NPPStyleEntry *)entry lang:(NPPLexer *)lex {
    _selectedStyleID = entry.styleID;
    _selectedStyleName = entry.name;
    _headerLabel.stringValue = [NSString stringWithFormat:@"%@: %@",
                                  lex.displayName, entry.name];
    BOOL hasFg = (entry.fgColor != nil);
    BOOL hasBg = (entry.bgColor != nil);
    _fgLabel.textColor = hasFg ? [NSColor labelColor] : [NSColor secondaryLabelColor];
    _bgLabel.textColor = hasBg ? [NSColor labelColor] : [NSColor secondaryLabelColor];
    _fgSwatch.swatchColor = hasFg ? entry.fgColor : [NSColor colorWithWhite:0.85 alpha:1];
    _bgSwatch.swatchColor = hasBg ? entry.bgColor : [NSColor colorWithWhite:0.85 alpha:1];
    [_fgSwatch setNeedsDisplay:YES];
    [_bgSwatch setNeedsDisplay:YES];

    _suppressActions = YES;
    if (entry.fontName.length > 0) [_fontNamePopup selectItemWithTitle:entry.fontName];
    else                            [_fontNamePopup selectItemAtIndex:0];
    if (entry.fontSize > 0) [_fontSizePopup selectItemWithTitle:[@(entry.fontSize) stringValue]];
    else                    [_fontSizePopup selectItemAtIndex:0];
    _boldCheck.state      = entry.bold      ? NSControlStateValueOn : NSControlStateValueOff;
    _italicCheck.state    = entry.italic    ? NSControlStateValueOn : NSControlStateValueOff;
    _underlineCheck.state = entry.underline ? NSControlStateValueOn : NSControlStateValueOff;

    // Global override row: reveal the 7 "Force …" checkboxes and seed their
    // states from the persisted prefs (issue #149 — Windows parity).
    BOOL isGlobalOverride = [entry.name isEqualToString:@"Global override"];
    NSArray<NSButton *> *overrideChecks = @[
        _forceFgCheck, _forceBgCheck,
        _forceFontCheck, _forceFontSizeCheck,
        _forceBoldCheck, _forceItalicCheck, _forceUnderlineCheck ];
    for (NSButton *b in overrideChecks) b.hidden = !isGlobalOverride;
    if (isGlobalOverride) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        _forceFgCheck.state        = [d boolForKey:kPrefGlobalOverrideEnableFg]
                                     ? NSControlStateValueOn : NSControlStateValueOff;
        _forceBgCheck.state        = [d boolForKey:kPrefGlobalOverrideEnableBg]
                                     ? NSControlStateValueOn : NSControlStateValueOff;
        _forceFontCheck.state      = [d boolForKey:kPrefGlobalOverrideEnableFont]
                                     ? NSControlStateValueOn : NSControlStateValueOff;
        _forceFontSizeCheck.state  = [d boolForKey:kPrefGlobalOverrideEnableFontSize]
                                     ? NSControlStateValueOn : NSControlStateValueOff;
        _forceBoldCheck.state      = [d boolForKey:kPrefGlobalOverrideEnableBold]
                                     ? NSControlStateValueOn : NSControlStateValueOff;
        _forceItalicCheck.state    = [d boolForKey:kPrefGlobalOverrideEnableItalic]
                                     ? NSControlStateValueOn : NSControlStateValueOff;
        _forceUnderlineCheck.state = [d boolForKey:kPrefGlobalOverrideEnableUnderline]
                                     ? NSControlStateValueOn : NSControlStateValueOff;
    }

    // Keyword lists: only rows tied to a langs.xml group (WordStyleDlg shows
    // them when _keywordClass != STYLE_NOT_USED).
    BOOL hasKeywords = entry.keywordClass.length > 0 && ![lex.lexerID isEqualToString:@"global"];
    [self _setKeywordControlsHidden:!hasKeywords];
    if (hasKeywords) {
        NSString *def = [[NppLangsManager shared] keywordsForLanguage:lex.lexerID
                                                          keywordClass:entry.keywordClass];
        [self _fillKeywordViewsDefault:def user:entry.keywords];
    } else {
        [self _fillKeywordViewsDefault:nil user:nil];
    }
    _suppressActions = NO;
}

// Persist new checkbox state, then re-skin every open editor by re-pushing
// the current working lexer set through previewLexers (same notification
// path that fg/bg/font edits already use).
- (void)_writeOverridePref:(NSString *)key fromCheckbox:(NSButton *)cb {
    if (_suppressActions) return;
    [[NSUserDefaults standardUserDefaults]
        setBool:(cb.state == NSControlStateValueOn) forKey:key];
    [[NPPStyleStore sharedStore] previewLexers:_workingLexers];
}

- (void)_forceFgChanged:(id)sender {
    [self _writeOverridePref:kPrefGlobalOverrideEnableFg fromCheckbox:_forceFgCheck];
}
- (void)_forceBgChanged:(id)sender {
    [self _writeOverridePref:kPrefGlobalOverrideEnableBg fromCheckbox:_forceBgCheck];
}
- (void)_forceFontChanged:(id)sender {
    [self _writeOverridePref:kPrefGlobalOverrideEnableFont fromCheckbox:_forceFontCheck];
}
- (void)_forceFontSizeChanged:(id)sender {
    [self _writeOverridePref:kPrefGlobalOverrideEnableFontSize fromCheckbox:_forceFontSizeCheck];
}
- (void)_forceBoldChanged:(id)sender {
    [self _writeOverridePref:kPrefGlobalOverrideEnableBold fromCheckbox:_forceBoldCheck];
}
- (void)_forceItalicChanged:(id)sender {
    [self _writeOverridePref:kPrefGlobalOverrideEnableItalic fromCheckbox:_forceItalicCheck];
}
- (void)_forceUnderlineChanged:(id)sender {
    [self _writeOverridePref:kPrefGlobalOverrideEnableUnderline fromCheckbox:_forceUnderlineCheck];
}

// ── NSTableViewDataSource ─────────────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return (NSInteger)_currentStyles.count;
}
- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_currentStyles.count) return @"";
    return _currentStyles[row].name;
}
- (void)tableViewSelectionDidChange:(NSNotification *)n {
    [self _previewUserKeywordsIfDirty];
    NSInteger row = _styleTable.selectedRow;
    if (row < 0 || row >= (NSInteger)_currentStyles.count) { [self _clearRightPanel]; return; }
    NSInteger langIdx = _langPopup.indexOfSelectedItem;
    if (langIdx < 0 || langIdx >= (NSInteger)_workingLexers.count) return;
    [self _updateRightPanelForStyle:_currentStyles[row] lang:_workingLexers[langIdx]];
}

// ── Current working entry ─────────────────────────────────────────────────────

- (nullable NPPStyleEntry *)_currentEntry {
    if (_selectedStyleID < 0 && !_selectedStyleName.length) return nil;
    NSInteger langIdx = _langPopup.indexOfSelectedItem;
    if (langIdx < 0 || langIdx >= (NSInteger)_workingLexers.count) return nil;
    NPPLexer *lex = _workingLexers[langIdx];
    // Global Styles: use name lookup (many entries share styleID=0).
    if ([lex.lexerID isEqualToString:@"global"] && _selectedStyleName.length)
        return [lex styleForName:_selectedStyleName];
    return [lex styleForID:_selectedStyleID];
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)_themeChanged:(id)sender {
    if (_suppressActions) return;
    NSString *name = [_themePopup titleOfSelectedItem];
    [self _resetWorkingCopyForTheme:name];
    // Refresh lang popup (keep same language selected if possible)
    NSInteger prevLangIdx = _langPopup.indexOfSelectedItem;
    [self _populateLangPopup];
    NSInteger newIdx = (prevLangIdx >= 0 && prevLangIdx < (NSInteger)_workingLexers.count)
                       ? prevLangIdx : 0;
    [_langPopup selectItemAtIndex:newIdx];
    [self _selectLangAtIndex:newIdx];
    // Live preview — immediately apply to all editors
    [NPPStyleStore sharedStore].activeThemeName = _workingTheme ?: kDefaultThemeName;
    [[NPPStyleStore sharedStore] previewLexers:_workingLexers];
}

- (void)_langChanged:(id)sender {
    if (_suppressActions) return;
    [self _selectLangAtIndex:_langPopup.indexOfSelectedItem];
}

- (void)_fgColorChanged:(_SCColorSwatch *)swatch {
    if (_suppressActions) return;
    NPPStyleEntry *e = [self _currentEntry];
    if (!e) return;
    e.fgColor = swatch.swatchColor;
    [[NPPStyleStore sharedStore] previewLexers:_workingLexers];
}
- (void)_bgColorChanged:(_SCColorSwatch *)swatch {
    if (_suppressActions) return;
    NPPStyleEntry *e = [self _currentEntry];
    if (!e) return;
    e.bgColor = swatch.swatchColor;
    [[NPPStyleStore sharedStore] previewLexers:_workingLexers];
}
// Font-related callbacks parallel the color callbacks above: write the new
// value into the working entry, then push the lexer set through previewLexers
// so the live editor reflects the change immediately. Without the preview
// call, font/style toggles only became visible after Save && Close.
- (void)_fontNameChanged:(id)sender {
    if (_suppressActions) return;
    NPPStyleEntry *e = [self _currentEntry];
    if (!e) return;
    NSInteger idx = _fontNamePopup.indexOfSelectedItem;
    e.fontName = (idx == 0) ? @"" : [_fontNamePopup titleOfSelectedItem];
    [[NPPStyleStore sharedStore] previewLexers:_workingLexers];
}
- (void)_fontSizeChanged:(id)sender {
    if (_suppressActions) return;
    NPPStyleEntry *e = [self _currentEntry];
    if (!e) return;
    NSInteger szIdx = _fontSizePopup.indexOfSelectedItem;
    e.fontSize = (szIdx == 0) ? 0 : [_fontSizePopup titleOfSelectedItem].intValue;
    [[NPPStyleStore sharedStore] previewLexers:_workingLexers];
}
- (void)_boldChanged:(id)sender {
    if (_suppressActions) return;
    NPPStyleEntry *e = [self _currentEntry];
    if (!e) return;
    e.bold = (_boldCheck.state == NSControlStateValueOn);
    e.fontStyleExplicit = YES;
    [[NPPStyleStore sharedStore] previewLexers:_workingLexers];
}
- (void)_italicChanged:(id)sender {
    if (_suppressActions) return;
    NPPStyleEntry *e = [self _currentEntry];
    if (!e) return;
    e.italic = (_italicCheck.state == NSControlStateValueOn);
    e.fontStyleExplicit = YES;
    [[NPPStyleStore sharedStore] previewLexers:_workingLexers];
}
- (void)_underlineChanged:(id)sender {
    if (_suppressActions) return;
    NPPStyleEntry *e = [self _currentEntry];
    if (!e) return;
    e.underline = (_underlineCheck.state == NSControlStateValueOn);
    e.fontStyleExplicit = YES;
    [[NPPStyleStore sharedStore] previewLexers:_workingLexers];
}

- (void)_saveAndClose:(id)sender {
    _userKeywordsDirty = NO;  // commitLexers: previews everything
    [[NPPStyleStore sharedStore] commitLexers:_workingLexers themeName:_workingTheme ?: kDefaultThemeName];
    [self.window close];
}

- (void)_cancel:(id)sender {
    _userKeywordsDirty = NO;
    // Restore state that was active when window was opened
    if (_cancelBackup) {
        [NPPStyleStore sharedStore].activeThemeName = _cancelTheme ?: kDefaultThemeName;
        // Roll the Global override flags back to their snapshot before
        // re-pushing the lexer set, so the resulting re-skin matches the
        // state the user saw on open.
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setBool:_backupOverrideFg        forKey:kPrefGlobalOverrideEnableFg];
        [d setBool:_backupOverrideBg        forKey:kPrefGlobalOverrideEnableBg];
        [d setBool:_backupOverrideFont      forKey:kPrefGlobalOverrideEnableFont];
        [d setBool:_backupOverrideFontSize  forKey:kPrefGlobalOverrideEnableFontSize];
        [d setBool:_backupOverrideBold      forKey:kPrefGlobalOverrideEnableBold];
        [d setBool:_backupOverrideItalic    forKey:kPrefGlobalOverrideEnableItalic];
        [d setBool:_backupOverrideUnderline forKey:kPrefGlobalOverrideEnableUnderline];
        [[NPPStyleStore sharedStore] previewLexers:_cancelBackup];
    }
    [self.window close];
}

// ── Import NPP theme XML ──────────────────────────────────────────────────────

- (void)importTheme:(id)sender {
    if (!self.window.isVisible) [self showWindow:nil];
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = [[NppLocalizer shared] translate:@"Import Style Theme"];
    panel.allowedFileTypes = @[@"xml"];
    panel.message = [[NppLocalizer shared] translate:@"Select a Nextpad++ theme XML file to apply"];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        [self _loadNppThemeXML:panel.URL];
    }];
}

- (void)_loadNppThemeXML:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:nil];
    if (!doc) return;

    // Apply GlobalStyles Default Style fg/bg/font
    NSArray<NSXMLElement *> *widgets = [doc nodesForXPath:@"//GlobalStyles/WidgetStyle" error:nil];
    NPPLexer *global = [self _workingLexerForID:@"global"];
    for (NSXMLElement *el in widgets) {
        NSString *name = [el attributeForName:@"name"].stringValue;
        NPPStyleEntry *target = [global styleForName:name];
        if (target) {
            NPPStyleStore *s = [NPPStyleStore sharedStore];
            NPPStyleEntry *te = [s _parseElement:el];
            [s _mergeThemeEntry:te into:target];
        }
    }

    // Apply per-language styles
    NSArray<NSXMLElement *> *lexerTypes = [doc nodesForXPath:@"//LexerStyles/LexerType" error:nil];
    for (NSXMLElement *lt in lexerTypes) {
        NSString *rawID = [lt attributeForName:@"name"].stringValue.lowercaseString ?: @"";
        NSString *lid = modelLexerID(rawID);
        NPPLexer *lex = [self _workingLexerForID:lid] ?: [self _workingLexerForID:rawID];
        if (!lex) continue;
        NSArray<NSXMLElement *> *words = [lt nodesForXPath:@"WordsStyle" error:nil];
        NPPStyleStore *s = [NPPStyleStore sharedStore];
        for (NSXMLElement *el in words) {
            NPPStyleEntry *te = [s _parseElement:el];
            NPPStyleEntry *target = [lex styleForID:te.styleID];
            if (target) [s _mergeThemeEntry:te into:target];
        }
    }

    [_themePopup selectItemWithTitle:@"Custom"];
    [_styleTable reloadData];
    NSInteger row = _styleTable.selectedRow;
    NSInteger langIdx = _langPopup.indexOfSelectedItem;
    if (row >= 0 && langIdx >= 0 && langIdx < (NSInteger)_workingLexers.count) {
        _currentStyles = _workingLexers[langIdx].styles;
        if (row < (NSInteger)_currentStyles.count)
            [self _updateRightPanelForStyle:_currentStyles[row] lang:_workingLexers[langIdx]];
    }
    // Live preview
    [[NPPStyleStore sharedStore] previewLexers:_workingLexers];
}

// ── Show window ───────────────────────────────────────────────────────────────

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    NPPStyleStore *store = [NPPStyleStore sharedStore];
    if (!store.allLexers.count) [store loadFromDefaults];

    // Save cancel backup — snapshot of current live store state
    NSMutableArray *backup = [NSMutableArray new];
    for (NPPLexer *lex in store.allLexers) [backup addObject:[lex copy]];
    _cancelBackup = [backup copy];
    _cancelTheme  = store.activeThemeName ?: kDefaultThemeName;

    // Snapshot Global override checkbox prefs — restored on Cancel.
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    _backupOverrideFg        = [d boolForKey:kPrefGlobalOverrideEnableFg];
    _backupOverrideBg        = [d boolForKey:kPrefGlobalOverrideEnableBg];
    _backupOverrideFont      = [d boolForKey:kPrefGlobalOverrideEnableFont];
    _backupOverrideFontSize  = [d boolForKey:kPrefGlobalOverrideEnableFontSize];
    _backupOverrideBold      = [d boolForKey:kPrefGlobalOverrideEnableBold];
    _backupOverrideItalic    = [d boolForKey:kPrefGlobalOverrideEnableItalic];
    _backupOverrideUnderline = [d boolForKey:kPrefGlobalOverrideEnableUnderline];

    // Populate theme popup
    [self _populateThemePopup];

    // Figure out active theme
    NSString *activeName = [[NSUserDefaults standardUserDefaults] stringForKey:kNSDefaultsThemeKey]
                            ?: kDefaultThemeName;
    // Load fresh working copy for active theme
    [self _resetWorkingCopyForTheme:activeName];

    // Apply any user overrides on top
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kNSDefaultsStyleKey];
    if (saved.count) {
        // Build lookup for overrides application
        NSMutableDictionary<NSString *, NPPLexer *> *lookup = [NSMutableDictionary new];
        for (NPPLexer *lex in _workingLexers) lookup[lex.lexerID] = lex;
        for (NSString *key in saved) {
            NSArray<NSString *> *parts = [key componentsSeparatedByString:@"|"];
            if (parts.count != 3) continue;
            NPPLexer *lex = lookup[parts[0]];
            if (!lex) continue;
            // Global styles: name-based key (many share styleID=0).
            // Lexer styles: numeric styleID key.
            NSString *sidOrName = parts[1];
            BOOL isNumeric = sidOrName.length > 0 && [sidOrName rangeOfCharacterFromSet:
                [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound;
            NPPStyleEntry *e;
            if ([parts[0] isEqualToString:@"global"] && !isNumeric)
                e = [lex styleForName:sidOrName];
            else
                e = [lex styleForID:sidOrName.intValue];
            if (!e) continue;
            id val = saved[key];
            NSString *prop = parts[2];
            if ([prop isEqualToString:@"fg"]) e.fgColor = colorFromRRGGBB(val);
            else if ([prop isEqualToString:@"bg"]) e.bgColor = colorFromRRGGBB(val);
            else if ([prop isEqualToString:@"fontName"]) e.fontName = val;
            else if ([prop isEqualToString:@"fontSize"]) e.fontSize = [val intValue];
            else if ([prop isEqualToString:@"bold"]) e.bold = [val boolValue];
            else if ([prop isEqualToString:@"italic"]) e.italic = [val boolValue];
            else if ([prop isEqualToString:@"underline"]) e.underline = [val boolValue];
            else if ([prop isEqualToString:@"keywords"]) e.keywords = normalizedKeywords(val);
        }
    }

    // Select theme in popup
    [_themePopup selectItemWithTitle:activeName];

    // Populate lang popup and select first item
    [self _populateLangPopup];
    if (_workingLexers.count) {
        [_langPopup selectItemAtIndex:0];
        [self _selectLangAtIndex:0];
    }

    [self.window center];
}

@end
