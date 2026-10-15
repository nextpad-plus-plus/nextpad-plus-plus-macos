#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted when dark mode state changes. All UI components should re-query colors.
extern NSNotificationName const NPPDarkModeChangedNotification;

/// Preference key for dark mode setting (Auto/Light/Dark).
extern NSString *const kPrefDarkMode;

/// Preference key for the UI appearance style (Auto/Classic/Tahoe). Default Auto.
extern NSString *const kPrefAppearanceStyle;

typedef NS_ENUM(NSInteger, NppDarkModeOption) {
    NppDarkModeAuto  = 0,  // Follow macOS system appearance
    NppDarkModeLight = 1,  // Always light
    NppDarkModeDark  = 2,  // Always dark
};

/// UI appearance profile — the "structure stays, chrome swaps" axis (orthogonal
/// to light/dark). Classic = today's dense pro toolbar/chrome; Tahoe = native
/// macOS "Liquid Glass" profile (in development). Auto follows the OS.
typedef NS_ENUM(NSInteger, NppAppearanceStyle) {
    NppAppearanceAuto    = 0,  // Follow OS (resolves to Classic for now; Tahoe-on-macOS-26 lands later)
    NppAppearanceClassic = 1,  // Always the classic profile
    NppAppearanceTahoe   = 2,  // Native Liquid Glass profile
};

/// Chrome regions that adopt translucent materials in the Tahoe profile. Used by
/// -materialForRole: (Step 3b/3c). Inert under Classic (usesGlassMaterials == NO).
typedef NS_ENUM(NSInteger, NppMaterialRole) {
    NppMaterialRoleToolbar     = 0,  // unified toolbar / title-bar region
    NppMaterialRoleSidebar     = 1,  // side-panel host
    NppMaterialRolePanelHeader = 2,  // PanelFrame header
    NppMaterialRoleStatusBar   = 3,  // bottom status bar
};

/// Per-profile toolbar metrics, in points. Classic mirrors today's compact values
/// (nppIconSize/nppBtnSize/nppSpacing/nppSepGap/nppToolbarCornerR); Tahoe returns
/// relaxed values. Consumed by the Tahoe toolbar builder (Step 3c).
typedef struct {
    CGFloat iconSize;
    CGFloat buttonSize;
    CGFloat buttonSpacing;
    CGFloat groupGap;
    CGFloat cornerRadius;
} NppToolbarMetrics;

/// Centralized theme manager. All UI components query this for colors and icon paths.
/// Never hardcode colors — always go through NppThemeManager.
@interface NppThemeManager : NSObject

+ (instancetype)shared;

/// Current mode (Auto/Light/Dark). Setting this posts NPPDarkModeChangedNotification.
@property (nonatomic) NppDarkModeOption mode;

/// YES if the effective appearance is currently dark.
@property (nonatomic, readonly) BOOL isDark;

/// Raw user preference for the appearance profile (Auto/Classic/Tahoe). Setting
/// this persists it. (Live switching / toolbar rebuild is wired in a later step;
/// for now the value is read when the toolbar is built.)
@property (nonatomic) NppAppearanceStyle appearanceStyle;

/// The appearance profile the UI should actually render. Resolves Auto. Currently
/// always Classic unless the user explicitly forces Tahoe; the Auto→Tahoe-on-
/// macOS-26 resolution is enabled once the Tahoe profile is built.
@property (nonatomic, readonly) NppAppearanceStyle effectiveAppearanceStyle;

// ── Tahoe presentation scaffolding (inert under Classic) ──────────────────────

/// YES when chrome should use translucent NSVisualEffectView materials (Tahoe).
/// NO for Classic — chrome stays opaque exactly as today.
@property (nonatomic, readonly) BOOL usesGlassMaterials;

/// The NSVisualEffectView material for a chrome role. Only meaningful when
/// usesGlassMaterials is YES; callers gate on that before applying it.
- (NSVisualEffectMaterial)materialForRole:(NppMaterialRole)role;

/// Toolbar metrics for the effective profile (see NppToolbarMetrics).
@property (nonatomic, readonly) NppToolbarMetrics toolbarMetrics;

// ── UI Colors ────────────────────────────────────────────────────────────────

// Tab bar
@property (nonatomic, readonly) NSColor *tabBarBackground;
@property (nonatomic, readonly) NSColor *activeTabFill;
@property (nonatomic, readonly) NSColor *inactiveTabFill;
@property (nonatomic, readonly) NSColor *hoverTabFill;
@property (nonatomic, readonly) NSColor *inactiveTabGradientTop;
@property (nonatomic, readonly) NSColor *inactiveTabGradientBottom;
@property (nonatomic, readonly) NSColor *hoverTabGradientTop;
@property (nonatomic, readonly) NSColor *hoverTabGradientBottom;
@property (nonatomic, readonly) NSColor *accentStripe;
@property (nonatomic, readonly) NSColor *tabBorder;
@property (nonatomic, readonly) NSColor *tabText;
@property (nonatomic, readonly) NSColor *tabTextInactive;
/// Red used for the unsaved-document floppy (tab bar, Document List).
@property (nonatomic, readonly) NSColor *unsavedIconTint;
/// Red outline floppy marking a document with unsaved changes (the saved
/// outline save glyph, whole outline tinted for the given background).
/// Cached; falls back to save_off_red.
- (nullable NSImage *)unsavedDocumentIconForDarkBackground:(BOOL)dark;
/// -unsavedDocumentIconForDarkBackground: with the chrome's isDark.
- (nullable NSImage *)unsavedDocumentIcon;
@property (nonatomic, readonly) NSColor *dividerDark;
@property (nonatomic, readonly) NSColor *dividerLight;

// Tab scroll arrows
@property (nonatomic, readonly) NSColor *arrowHoverBg;
@property (nonatomic, readonly) NSColor *arrowPressBg;
@property (nonatomic, readonly) NSColor *arrowBorder;
@property (nonatomic, readonly) NSColor *arrowFill;

// Panels / status bar
@property (nonatomic, readonly) NSColor *panelBackground;
@property (nonatomic, readonly) NSColor *statusBarBackground;

// ── Icon Paths ───────────────────────────────────────────────────────────────

/// Returns the toolbar icon directory: "icons/standard/toolbar" or "icons/dark/toolbar/regular"
@property (nonatomic, readonly) NSString *toolbarIconDir;

/// Returns the tabbar icon directory: "icons/standard/tabbar" or "icons/dark/tabbar"
@property (nonatomic, readonly) NSString *tabbarIconDir;

/// Returns the panels icon base directory: "icons/standard/panels" or "icons/dark/panels"
@property (nonatomic, readonly) NSString *panelsIconDir;

/// Load a toolbar icon by standard name (e.g. "saveFile"). Automatically maps to
/// dark icon name if in dark mode. Returns nil if not found.
- (nullable NSImage *)toolbarIconNamed:(NSString *)standardName;

/// Load a tabbar icon by name (e.g. "closeTabButton"). Uses current theme directory.
- (nullable NSImage *)tabbarIconNamed:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
