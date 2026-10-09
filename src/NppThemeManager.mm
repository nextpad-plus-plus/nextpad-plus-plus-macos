#import "NppThemeManager.h"

NSNotificationName const NPPDarkModeChangedNotification = @"NPPDarkModeChangedNotification";
NSString *const kPrefDarkMode = @"NPPDarkMode";
NSString *const kPrefAppearanceStyle = @"NPPAppearanceStyle";

// ── Toolbar icon name mapping: standard name → Fluent name ──────────────────
// To remap an icon: change the right-hand value only.
// Light icons live in icons/light/toolbar/regular/{fluentName}.png
// Dark icons live in icons/dark/toolbar/regular/{fluentName}.png
static NSDictionary<NSString *, NSString *> *toolbarIconMapping(void) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"newFile":       @"new_off",
            @"openFile":      @"open_off",
            @"saveFile":      @"save_off",
            @"saveAll":       @"saveall_off",
            @"closeFile":     @"close_off",
            @"closeAll":      @"closeall_off",
            @"print":         @"print_off",
            @"cut":           @"cut_off",
            @"copy":          @"copy_off",
            @"paste":         @"paste_off",
            @"undo":          @"undo_off",
            @"redo":          @"redo_off",
            @"find":          @"find_off",
            @"findReplace":   @"findrep_off",
            @"zoomIn":        @"zoomIn_off",
            @"zoomOut":       @"zoomOut_off",
            @"syncV":         @"syncV_off",
            @"syncH":         @"syncH_off",
            @"wrap":          @"wrap_off",
            @"allChars":      @"allChars_off",
            @"indentGuide":   @"indentGuide_off",
            @"udl":           @"udl_off",
            @"docMap":        @"docMap_off",
            @"docList":       @"docList_off",
            @"funcList":      @"funcList_off",
            @"fileBrowser":   @"fileBrowser_off",
            @"monitoring":    @"monitoring_off",
            @"startRecord":   @"startrecord_off",
            @"stopRecord":    @"stoprecord_off",
            @"playRecord":    @"playrecord_off",
            @"playRecord_m":  @"playrecord_m_off",
            @"saveRecord":    @"saverecord_off",
            // Red save icon (unsaved tab indicator) — paired Fluent variant
            // shipped at icons/{light,dark}/toolbar/regular/save_off_red.png.
            @"saveFileRed":   @"save_off_red",
        };
    });
    return map;
}

@implementation NppThemeManager {
    BOOL _cachedIsDark;
    NSImage *_unsavedIconLight;   // -unsavedDocumentIconForDarkBackground: cache
    NSImage *_unsavedIconDark;
}

@synthesize appearanceStyle = _appearanceStyle;

+ (instancetype)shared {
    static NppThemeManager *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[NppThemeManager alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Load saved preference (default = Auto)
        NSInteger saved = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefDarkMode];
        _mode = (NppDarkModeOption)saved;
        [self _recalcIsDark];
        [self _applyAppearance];

        // Appearance profile (Auto/Classic/Tahoe). Absent integer key → 0 → Auto.
        _appearanceStyle = (NppAppearanceStyle)[[NSUserDefaults standardUserDefaults]
            integerForKey:kPrefAppearanceStyle];

        // Observe system appearance changes for Auto mode via distributed notification
        [[NSDistributedNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_systemAppearanceDidChange:)
                   name:@"AppleInterfaceThemeChangedNotification" object:nil];
    }
    return self;
}

- (void)_systemAppearanceDidChange:(NSNotification *)n {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _systemAppearanceChanged];
    });
}

- (void)_systemAppearanceChanged {
    if (_mode == NppDarkModeAuto) {
        BOOL wasDark = _cachedIsDark;
        [self _recalcIsDark];
        if (_cachedIsDark != wasDark) {
            [self _applyAppearance];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:NPPDarkModeChangedNotification object:nil];
        }
    }
}

- (void)_recalcIsDark {
    _unsavedIconLight = nil;
    _unsavedIconDark  = nil;
    switch (_mode) {
        case NppDarkModeLight: _cachedIsDark = NO; break;
        case NppDarkModeDark:  _cachedIsDark = YES; break;
        case NppDarkModeAuto:
        default: {
            // Read the system's AppleInterfaceStyle global preference directly
            // via CFPreferences instead of NSApp.effectiveAppearance.
            //
            // NSApp.effectiveAppearance is unreliable at first call from
            // applicationDidFinishLaunching: — it returns Aqua (Light) until
            // the first runloop tick has propagated the system appearance,
            // even when the user has macOS in Dark mode. That made the very
            // first read of statusBarBackground.CGColor bake the light value
            // into the status bar / FindReplace / IncrementalSearch layers,
            // and the bar stayed light for the whole session (the
            // NPPDarkModeChangedNotification path that re-applies the CGColor
            // only fires on explicit pref change). Toggling Prefs Light↔Dark
            // and back masked the bug because by then NSApp was caught up.
            //
            // Reading the global "Apple Global Domain" pref directly is the
            // canonical source of truth and is correct immediately at launch.
            // Value is "Dark" when dark mode is enabled; missing / absent
            // means Light.
            CFPropertyListRef style = CFPreferencesCopyAppValue(
                CFSTR("AppleInterfaceStyle"), kCFPreferencesAnyApplication);
            NSString *styleStr = style ? (__bridge_transfer NSString *)style : nil;
            _cachedIsDark = [styleStr isEqualToString:@"Dark"];
            break;
        }
    }
}

- (void)setMode:(NppDarkModeOption)mode {
    _mode = mode;
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:kPrefDarkMode];
    [self _recalcIsDark];
    [self _applyAppearance];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:NPPDarkModeChangedNotification object:nil];
}

/// Set NSApp.appearance to force all native controls (toolbar, title bar,
/// scrollbars, dialogs, buttons) to render in the correct mode.
- (void)_applyAppearance {
    if (_mode == NppDarkModeAuto) {
        // nil = follow system (default macOS behavior)
        NSApp.appearance = nil;
    } else {
        NSApp.appearance = [NSAppearance appearanceNamed:
            _cachedIsDark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    }
}

- (BOOL)isDark { return _cachedIsDark; }

// ── Appearance Profile (Classic / Tahoe) ──────────────────────────────────────

- (void)setAppearanceStyle:(NppAppearanceStyle)style {
    _appearanceStyle = style;
    [[NSUserDefaults standardUserDefaults] setInteger:style forKey:kPrefAppearanceStyle];
    // No notification posted yet: switching the profile requires rebuilding the
    // toolbar (not just re-skinning colors), and that live-rebuild path is wired
    // in a later step. For now the profile is read when the toolbar is built, so
    // a change takes effect on the next launch.
}

- (NppAppearanceStyle)effectiveAppearanceStyle {
    switch (_appearanceStyle) {
        case NppAppearanceTahoe:   return NppAppearanceTahoe;
        case NppAppearanceClassic: return NppAppearanceClassic;
        case NppAppearanceAuto:
        default:
            // Auto resolves to Classic until the Tahoe profile exists. When it
            // does, this becomes: `if (@available(macOS 26.0, *)) return Tahoe;`
            return NppAppearanceClassic;
    }
}

// ── Tahoe presentation scaffolding (inert under Classic) ──────────────────────

- (BOOL)usesGlassMaterials {
    return self.effectiveAppearanceStyle == NppAppearanceTahoe;
}

- (NSVisualEffectMaterial)materialForRole:(NppMaterialRole)role {
    // Tahoe materials. Only consulted when usesGlassMaterials == YES; the values
    // may be refined in Step 3b/3c once seen against real glass.
    switch (role) {
        case NppMaterialRoleToolbar:     return NSVisualEffectMaterialHeaderView;
        case NppMaterialRoleSidebar:     return NSVisualEffectMaterialSidebar;
        case NppMaterialRolePanelHeader: return NSVisualEffectMaterialTitlebar;  // lighter/sleeker than HeaderView
        case NppMaterialRoleStatusBar:   return NSVisualEffectMaterialUnderWindowBackground;
    }
    return NSVisualEffectMaterialWindowBackground;
}

- (NppToolbarMetrics)toolbarMetrics {
    if (self.effectiveAppearanceStyle == NppAppearanceTahoe) {
        // Relaxed placeholder — tuned in Step 3c against real glass.
        return (NppToolbarMetrics){ .iconSize = 18, .buttonSize = 34,
                                    .buttonSpacing = 6, .groupGap = 12, .cornerRadius = 7 };
    }
    // Classic — mirrors nppIconSize/nppBtnSize/nppSpacing/nppSepGap/nppToolbarCornerR.
    return (NppToolbarMetrics){ .iconSize = 16, .buttonSize = 28,
                                .buttonSpacing = 4, .groupGap = 9, .cornerRadius = 4.5 };
}

// ── Tab Bar Colors ───────────────────────────────────────────────────────────

- (NSColor *)tabBarBackground {
    return _cachedIsDark ? [NSColor colorWithWhite:0.18 alpha:1]
                         : [NSColor colorWithRed:0xF0/255.0 green:0xF0/255.0 blue:0xF0/255.0 alpha:1];
}

- (NSColor *)activeTabFill {
    return _cachedIsDark ? [NSColor colorWithWhite:0.25 alpha:1]
                         : [NSColor colorWithWhite:1.0 alpha:1];
}

- (NSColor *)inactiveTabFill {
    return _cachedIsDark ? [NSColor colorWithWhite:0.20 alpha:1]
                         : [NSColor colorWithWhite:0.80 alpha:1];
}

- (NSColor *)hoverTabFill {
    return _cachedIsDark ? [NSColor colorWithWhite:0.28 alpha:1]
                         : [NSColor colorWithWhite:0.87 alpha:1];
}

- (NSColor *)inactiveTabGradientTop {
    return _cachedIsDark ? [NSColor colorWithWhite:0.22 alpha:1]
                         : [NSColor colorWithWhite:0.86 alpha:1];
}

- (NSColor *)inactiveTabGradientBottom {
    return _cachedIsDark ? [NSColor colorWithWhite:0.20 alpha:1]
                         : [NSColor colorWithWhite:0.80 alpha:1];
}

- (NSColor *)hoverTabGradientTop {
    return _cachedIsDark ? [NSColor colorWithWhite:0.30 alpha:1]
                         : [NSColor colorWithWhite:0.90 alpha:1];
}

- (NSColor *)hoverTabGradientBottom {
    return _cachedIsDark ? [NSColor colorWithWhite:0.28 alpha:1]
                         : [NSColor colorWithWhite:0.87 alpha:1];
}

- (NSColor *)accentStripe {
    // Same orange accent in both modes
    return [NSColor colorWithRed:253/255.0 green:166/255.0 blue:64/255.0 alpha:1];
}

- (NSColor *)tabBorder {
    return _cachedIsDark ? [NSColor colorWithWhite:0.35 alpha:1]
                         : [NSColor colorWithWhite:0.58 alpha:1];
}

- (NSColor *)tabText {
    return _cachedIsDark ? [NSColor colorWithWhite:0.90 alpha:1]
                         : [NSColor labelColor];
}

- (NSColor *)tabTextInactive {
    return _cachedIsDark ? [NSColor colorWithWhite:0.65 alpha:1]
                         : [NSColor colorWithWhite:0.15 alpha:1];
}

// Unsaved-document marker. As saturated as each background allows while
// keeping >= 4.5:1 on the Classic selected tab (white / 0x313131) and >= 3:1
// on the orange-tinted Tahoe selected tab. A purer red (e.g. 0xFF3B30) is
// too dark for 4.5:1 on the dark tab, so dark mode stays slightly warm.
static NSColor *unsavedTintForDark(BOOL dark) {
    return dark ? [NSColor colorWithRed:0xFF/255.0 green:0x68/255.0 blue:0x5E/255.0 alpha:1]
                : [NSColor colorWithRed:0xD7/255.0 green:0x00/255.0 blue:0x15/255.0 alpha:1];
}

- (NSColor *)unsavedIconTint {
    return unsavedTintForDark(_cachedIsDark);
}

- (nullable NSImage *)unsavedDocumentIconForDarkBackground:(BOOL)dark {
    // The same outline save glyph saved documents use (regular/save_off),
    // with the whole outline painted in the unsaved tint and the stroke
    // thickened to about 1.6x (the glyph is stamped around a small ring
    // before tinting) so it still reads at tab size in dark mode. Same shape
    // and size as the saved icon. save_off_red colours just its thin label
    // slot, which shrinks below a pixel at tab / list size and reads as the
    // same grey floppy as a saved document.
    // Cached per background (tabs redraw often); cleared in -_recalcIsDark.
    NSImage *cached = dark ? _unsavedIconDark : _unsavedIconLight;
    if (cached) return cached;
    NSString *base = dark ? @"icons/dark/toolbar" : @"icons/light/toolbar";
    NSString *path = [[NSBundle mainBundle] pathForResource:@"save_off" ofType:@"png"
                                               inDirectory:[base stringByAppendingPathComponent:@"regular"]];
    NSImage *glyph = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    NSImage *icon;
    if (glyph) {
        NSColor *tint = unsavedTintForDark(dark);
        icon = [NSImage imageWithSize:glyph.size flipped:NO drawingHandler:^BOOL(NSRect r) {
            // The Fluent stroke is 1/24 of the glyph; growing it ~0.3/24 on
            // each side gives ~1.6x the saved icon's weight.
            CGFloat d = r.size.width * 0.013;
            for (int dx = -1; dx <= 1; dx++) {
                for (int dy = -1; dy <= 1; dy++) {
                    [glyph drawInRect:NSOffsetRect(r, dx * d, dy * d) fromRect:NSZeroRect
                            operation:NSCompositingOperationSourceOver fraction:1.0];
                }
            }
            [tint setFill];
            NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop);
            return YES;
        }];
    } else {
        NSString *red = [[NSBundle mainBundle] pathForResource:@"save_off_red" ofType:@"png"
                                                  inDirectory:[base stringByAppendingPathComponent:@"regular"]];
        icon = red ? [[NSImage alloc] initWithContentsOfFile:red] : nil;
    }
    if (dark) _unsavedIconDark = icon; else _unsavedIconLight = icon;
    return icon;
}

- (nullable NSImage *)unsavedDocumentIcon {
    return [self unsavedDocumentIconForDarkBackground:_cachedIsDark];
}

- (NSColor *)dividerDark {
    return _cachedIsDark ? [NSColor colorWithWhite:0.30 alpha:1]
                         : [NSColor colorWithWhite:0.55 alpha:1];
}

- (NSColor *)dividerLight {
    return _cachedIsDark ? [NSColor colorWithWhite:0.22 alpha:1]
                         : [NSColor colorWithWhite:0.96 alpha:1];
}

// ── Scroll Arrow Colors ──────────────────────────────────────────────────────

- (NSColor *)arrowHoverBg {
    return _cachedIsDark ? [NSColor colorWithWhite:0.30 alpha:1]
                         : [NSColor colorWithWhite:0.91 alpha:1];
}

- (NSColor *)arrowPressBg {
    return _cachedIsDark ? [NSColor colorWithWhite:0.35 alpha:1]
                         : [NSColor colorWithWhite:0.83 alpha:1];
}

- (NSColor *)arrowBorder {
    return _cachedIsDark ? [NSColor colorWithWhite:0.35 alpha:1]
                         : [NSColor colorWithWhite:0.50 alpha:1];
}

- (NSColor *)arrowFill {
    return _cachedIsDark ? [NSColor colorWithWhite:0.75 alpha:1]
                         : [NSColor colorWithWhite:0.18 alpha:1];
}

// ── Panel / Status Bar ───────────────────────────────────────────────────────

- (NSColor *)panelBackground {
    return _cachedIsDark ? [NSColor colorWithWhite:0.18 alpha:1]
                         : [NSColor controlBackgroundColor];
}

- (NSColor *)statusBarBackground {
    // Static RGB literals in both branches. The light branch previously
    // returned [NSColor windowBackgroundColor] — a semantic dynamic color —
    // and the callsites cache its .CGColor on a CALayer (status bar +
    // FindReplacePanel + IncrementalSearchBar). CGColor resolution happens
    // against the current drawing appearance, NOT against NSApp.appearance,
    // so when macOS is in Dark mode but the user has chosen Light mode in
    // Nextpad++, the dark variant of windowBackgroundColor was baked into
    // the layer at view-creation time. Static RGB makes the resolution
    // deterministic and matches the existing pattern in tabBarBackground.
    // 0xECECEC ≈ stock macOS Aqua window chrome shade.
    return _cachedIsDark ? [NSColor colorWithWhite:0.18 alpha:1]
                         : [NSColor colorWithRed:0xEC/255.0 green:0xEC/255.0 blue:0xEC/255.0 alpha:1];
}

// ── Icon Paths ───────────────────────────────────────────────────────────────

- (NSString *)toolbarIconDir {
    return _cachedIsDark ? @"icons/dark/toolbar/regular" : @"icons/light/toolbar/regular";
}

- (NSString *)tabbarIconDir {
    return _cachedIsDark ? @"icons/dark/tabbar" : @"icons/standard/tabbar";
}

- (NSString *)panelsIconDir {
    return _cachedIsDark ? @"icons/dark/panels" : @"icons/standard/panels";
}

- (nullable NSImage *)toolbarIconNamed:(NSString *)standardName {
    NSString *dir = self.toolbarIconDir;

    // Both light and dark dirs use Fluent naming — always map.
    NSString *fileName = toolbarIconMapping()[standardName];
    if (!fileName) fileName = standardName;

    NSString *path = [[NSBundle mainBundle] pathForResource:fileName ofType:@"png"
                                               inDirectory:dir];
    return path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
}

- (nullable NSImage *)tabbarIconNamed:(NSString *)name {
    NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"png"
                                               inDirectory:self.tabbarIconDir];
    return path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
}

@end
