#import "PreferencesWindowController.h"
#import "NppPaths.h"
#import "NppLocalizer.h"
#import "NppLangsManager.h"
#import "NppThemeManager.h"
#import "StyleConfiguratorWindowController.h"
#import "TahoeToolbarConfig.h"

// Defined in regex/RegexBackendSelect.cxx — selects the Boost.Regex backend over
// the default per-line std::regex one. Mirrored from kPrefUseBoostRegex.
extern "C" bool gNppUseBoostRegex;

// ── NSUserDefaults keys (mirrors NPP settings) ────────────────────────────────
NSString *const kPrefTabWidth           = @"tabWidth";
NSString *const kPrefUseTabs            = @"useTabs";
NSString *const kPrefAutoIndent         = @"autoIndent";  // 0=None 1=Advanced 2=Basic
NSString *const kPrefBackspaceUnindent = @"backspaceUnindent";
NSString *const kPrefTabOverrides      = @"tabOverrides"; // {langName: {tabSize:N, useTabs:BOOL}}
NSString *const kPrefShowLineNumbers    = @"showLineNumbers";
NSString *const kPrefShowIndentGuides   = @"showIndentGuides";
NSString *const kPrefWordWrap           = @"wordWrap";       // persistent across launches; default NO
NSString *const kPrefHighlightCurrentLine = @"highlightCurrentLine";
NSString *const kPrefEOLType            = @"eolType";       // 0=CRLF 1=LF 2=CR
NSString *const kPrefEncoding           = @"encoding";      // 0=UTF-8 1=Latin-1
NSString *const kPrefAutoBackup         = @"autoBackup";
NSString *const kPrefBackupInterval     = @"backupInterval"; // seconds
NSString *const kPrefRememberSession    = @"rememberSession"; // BOOL, default YES — issue #87
NSString *const kPrefZoomLevel          = @"zoomLevel";
NSString *const kPrefSpellCheck         = @"spellCheck";
NSString *const kPrefAutoCompleteEnable  = @"autoCompleteEnable";
NSString *const kPrefAutoCompleteMinChars = @"autoCompleteMinChars";
NSString *const kPrefAutoCloseBrackets   = @"autoCloseBrackets";
NSString *const kPrefShowFullPathInTitle = @"showFullPathInTitle";
NSString *const kPrefToolbarColorMode    = @"toolbarColorMode";
NSString *const kPrefToolbarColorChoice  = @"toolbarColorChoice";
NSString *const kPrefToolbarCustomColor  = @"toolbarCustomColor";
NSString *const kPrefToolbarColorPlugins = @"toolbarColorPlugins";
NSString *const kPrefCaretWidth          = @"caretWidth";
NSString *const kPrefTabMaxLabelWidth    = @"tabMaxLabelWidth";
NSString *const kPrefTabCloseButton      = @"tabCloseButton";
NSString *const kPrefDoubleClickTabClose = @"doubleClickTabClose";
NSString *const kPrefTabBarWrap          = @"tabBarWrap";
NSString *const kPrefHideTabBar          = @"hideTabBar";
NSString *const kPrefVirtualSpace        = @"virtualSpace";
NSString *const kPrefColumnSel2MultiEdit = @"columnSel2MultiEdit";
NSString *const kPrefScrollBeyondLastLine= @"scrollBeyondLastLine";
NSString *const kPrefScrollSpeedGain     = @"scrollSpeedGain";
NSString *const kPrefCaretBlinkRate      = @"caretBlinkRate";
NSString *const kPrefFontQuality         = @"fontQuality";
NSString *const kPrefLineHeightMultiplier = @"lineHeightMultiplier";
NSString *const kPrefGlobalOverrideEnableFg        = @"globalOverrideEnableFg";
NSString *const kPrefGlobalOverrideEnableBg        = @"globalOverrideEnableBg";
NSString *const kPrefGlobalOverrideEnableFont      = @"globalOverrideEnableFont";
NSString *const kPrefGlobalOverrideEnableFontSize  = @"globalOverrideEnableFontSize";
NSString *const kPrefGlobalOverrideEnableBold      = @"globalOverrideEnableBold";
NSString *const kPrefGlobalOverrideEnableItalic    = @"globalOverrideEnableItalic";
NSString *const kPrefGlobalOverrideEnableUnderline = @"globalOverrideEnableUnderline";
NSString *const kPrefCopyLineNoSelection = @"copyLineNoSelection";
NSString *const kPrefSmartHighlight      = @"smartHighlight";
NSString *const kPrefFillFindWithSelection = @"fillFindWithSelection";
NSString *const kPrefFuncParamsHint      = @"funcParamsHint";
NSString *const kPrefFindTransparencyEnabled = @"findTransparencyEnabled";
NSString *const kPrefFindTransparencyMode    = @"findTransparencyMode";   // 0=losing focus, 1=always
NSString *const kPrefFindTransparencyAlpha   = @"findTransparencyAlpha";
NSString *const kPrefClickableLinkEnable      = @"clickableLinkEnable";
NSString *const kPrefClickableLinkNoUnderline = @"clickableLinkNoUnderline";
NSString *const kPrefClickableLinkFullBox     = @"clickableLinkFullBox";
NSString *const kPrefClickableLinkSchemes     = @"clickableLinkSchemes";

// Windows NppGUI._uriSchemes default (Parameters.h) — the customized URI
// schemes that should also be treated as clickable links.
static NSString *const kDefaultClickableLinkSchemes =
    @"svn:// cvs:// git:// imap:// irc:// irc6:// ircs:// ldap:// ldaps:// news: "
    @"telnet:// gopher:// ssh:// sftp:// smb:// skype: snmp:// spotify: steam:// "
    @"sms: slack:// chrome:// bitcoin:";
extern NSString *const kPrefShowStatusBar;
extern NSString *const kPrefToolbarVisible;
extern NSString *const kPrefDockPanelsOnLeft;
NSString *const kPrefShowStatusBar       = @"showStatusBar";
NSString *const kPrefToolbarVisible      = @"toolbarVisible";
NSString *const kPrefDockPanelsOnLeft    = @"dockPanelsOnLeft";
NSString *const kPrefSidePanelWidth      = @"SidePanelWidth";
NSString *const kPrefMuteSounds          = @"muteSounds";
NSString *const kPrefSaveAllConfirm      = @"saveAllConfirm";
NSString *const kPrefPluginSplitViewRouting = @"pluginSplitViewRouting";
NSString *const kPrefRightClickKeepsSel  = @"rightClickKeepsSel";
NSString *const kPrefDisableTextDragDrop = @"disableTextDragDrop";
NSString *const kPrefMonoFontFind        = @"monoFontFind";
NSString *const kPrefConfirmReplaceAll   = @"confirmReplaceAll";
NSString *const kPrefReplaceAndStop      = @"replaceAndStop";
NSString *const kPrefUseBoostRegex       = @"useBoostRegex";
NSString *const kPrefSmartHiliteCase     = @"smartHiliteCase";
NSString *const kPrefSmartHiliteWord     = @"smartHiliteWord";
NSString *const kPrefDateTimeReverse     = @"dateTimeReverse";
NSString *const kPrefKeepAbsentSession   = @"keepAbsentSession";
NSString *const kPrefShowBookmarkMargin  = @"showBookmarkMargin";
NSString *const kPrefShowEOL             = @"showEOL";
NSString *const kPrefShowWhitespace      = @"showWhitespace";
NSString *const kPrefEdgeColumn          = @"edgeColumn";
NSString *const kPrefEdgeMode            = @"edgeMode";
NSString *const kPrefPaddingLeft         = @"paddingLeft";
NSString *const kPrefPaddingRight        = @"paddingRight";
NSString *const kPrefPanelKeepState      = @"panelKeepState";
NSString *const kPrefFoldStyle           = @"foldStyle";
NSString *const kPrefLineNumDynWidth     = @"lineNumDynWidth";
NSString *const kPrefInSelThreshold      = @"inSelThreshold";
NSString *const kPrefFuncListUseXML      = @"funcListUseXML";
NSString *const kPrefToolbarIconScale    = @"toolbarIconScale";
NSString *const kPrefFileStatusAutoDetection  = @"fileStatusAutoDetection";
NSString *const kPrefFileStatusUpdateSilently = @"fileStatusUpdateSilently";

// Delimiter pane (issue #42)
NSString *const kPrefWordCharsUseDefault = @"wordCharsUseDefault";
NSString *const kPrefWordCharsAdded      = @"wordCharsAdded";
NSString *const kPrefDelimOpen           = @"delimOpen";
NSString *const kPrefDelimClose          = @"delimClose";
NSString *const kPrefDelimEntireDoc      = @"delimEntireDoc";

// Performance / Large File Restriction (issue #75-style; mirrors Windows NPP)
NSString *const kPrefLargeFileEnabled            = @"largeFileEnabled";
NSString *const kPrefLargeFileSizeMB             = @"largeFileSizeMB";
NSString *const kPrefLargeFileNoWrap             = @"largeFileNoWrap";
NSString *const kPrefLargeFileAllowAutoComplete  = @"largeFileAllowAutoComplete";
NSString *const kPrefLargeFileAllowSmartHilite   = @"largeFileAllowSmartHilite";
NSString *const kPrefLargeFileAllowBraceMatch    = @"largeFileAllowBraceMatch";
NSString *const kPrefLargeFileAllowURLClick      = @"largeFileAllowURLClick";
NSString *const kPrefLargeFileSuppress2GBWarning = @"largeFileSuppress2GBWarning";

// Theme / Style Configurator keys
NSString *const kPrefThemePreset        = @"themePreset";
NSString *const kPrefStyleFg            = @"styleFg";
NSString *const kPrefStyleBg            = @"styleBg";
NSString *const kPrefStyleComment       = @"styleComment";
NSString *const kPrefStyleKeyword       = @"styleKeyword";
NSString *const kPrefStyleString        = @"styleString";
NSString *const kPrefStyleNumber        = @"styleNumber";
NSString *const kPrefStylePreproc       = @"stylePreproc";
NSString *const kPrefStyleFontName      = @"styleFontName";
NSString *const kPrefStyleFontSize      = @"styleFontSize";

// Flipped NSView so scroll content starts at top-left
@interface _NPPFlippedView : NSView
@end
@implementation _NPPFlippedView
- (BOOL)isFlipped { return YES; }
@end

// ── Sidebar page definitions ─────────────────────────────────────────────────
// Each entry: @{@"title": name} or @{@"separator": @YES}
// Pages are built lazily and cached.

// ── PreferencesWindowController ───────────────────────────────────────────────

@interface PreferencesWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate>
@end

@implementation PreferencesWindowController {
    NSTableView          *_sidebarTable;
    NSScrollView         *_contentScroll;
    NSView               *_contentArea;
    // Tahoe toolbar group editor (Toolbar page, gated on the Tahoe appearance).
    NSOutlineView        *_tahoeOutline;
    NSMutableArray       *_tahoeEditGroups; // [ @{label,kind,items:[ @{key,display,state} ]} ]
    NSMutableArray       *_pageNames;     // sidebar row titles (NSString or @"-" for separator)
    NSMutableDictionary  *_pageViews;     // pageTitle → NSView (lazy cache)
    NSPopUpButton        *_languagePopup; // General page — language selector
    NSArray<NSString *>  *_indentLangNames;    // Indentation page — "[Default]" + language display names
    NSDictionary<NSString *, NSString *> *_indentDisplayToInternal; // "Python" → "python"
    NSString             *_indentSelectedLang; // currently selected internal lang name (nil = [Default])
    NSTextField          *_delimWordCharsField; // Delimiter page — toggled enabled by radio
    NSTextView           *_clickableSchemesTextView; // Cloud & Link page — URI customized schemes
}

+ (void)load {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kPrefTabWidth:           @4,
        kPrefUseTabs:            @YES,
        kPrefAutoIndent:         @1,   // 0=None 1=Advanced 2=Basic
        kPrefBackspaceUnindent:  @NO,
        kPrefShowLineNumbers:    @YES,
        kPrefShowIndentGuides:   @YES,
        kPrefWordWrap:           @NO,   // persistent default (was session-only, now persistent)
        kPrefHighlightCurrentLine: @YES,
        kPrefEOLType:            @1,
        kPrefEncoding:           @0,
        kPrefAutoBackup:         @YES,
        kPrefBackupInterval:     @60,
        kPrefRememberSession:    @YES,
        kPrefZoomLevel:          @0,
        kPrefLanguage:           @"english",
        // Default (light) theme colors
        kPrefThemePreset:        @"Default",
        kPrefStyleFg:            @"#000000",
        kPrefStyleBg:            @"#FFFFFF",
        kPrefStyleComment:       @"#008000",
        kPrefStyleKeyword:       @"#0000FF",
        kPrefStyleString:        @"#A31515",
        kPrefStyleNumber:        @"#098658",
        kPrefStylePreproc:       @"#800080",
        kPrefStyleFontName:      @"Menlo",
        kPrefStyleFontSize:      @11,
        kPrefAutoCompleteEnable:   @YES,
        kPrefAutoCompleteMinChars: @1,
        kPrefAutoCloseBrackets:    @YES,
        kPrefShowFullPathInTitle:  @YES,
        kPrefToolbarColorMode:     @0,
        kPrefToolbarColorChoice:   @2,
        kPrefToolbarColorPlugins:  @NO,
        kPrefCaretWidth:           @1,
        kPrefTabMaxLabelWidth:     @190,
        kPrefTabCloseButton:       @YES,
        kPrefDoubleClickTabClose:  @NO,
        kPrefTabBarWrap:           @NO,
        kPrefHideTabBar:           @NO,
        kPrefVirtualSpace:         @NO,
        kPrefColumnSel2MultiEdit:  @YES,
        kPrefScrollBeyondLastLine: @NO,
        kPrefScrollSpeedGain:      @1.0,
        kPrefCaretBlinkRate:       @500,
        kPrefFontQuality:          @3,   // 0=default 1=none 2=antialiased 3=LCD
        kPrefLineHeightMultiplier: @1.0, // 1.0 = no extra spacing (current behavior)
        kPrefGlobalOverrideEnableFg:        @NO,
        kPrefGlobalOverrideEnableBg:        @NO,
        kPrefGlobalOverrideEnableFont:      @NO,
        kPrefGlobalOverrideEnableFontSize:  @NO,
        kPrefGlobalOverrideEnableBold:      @NO,
        kPrefGlobalOverrideEnableItalic:    @NO,
        kPrefGlobalOverrideEnableUnderline: @NO,
        kPrefCopyLineNoSelection:  @YES,
        kPrefSmartHighlight:       @YES,
        kPrefUseBoostRegex:        @NO,   // off = current per-line std::regex backend
        kPrefFillFindWithSelection:@YES,
        kPrefFuncParamsHint:       @NO,
        kPrefFindTransparencyEnabled: @YES,  // matches Windows default
        kPrefFindTransparencyMode:    @0,    // 0=on losing focus, 1=always
        kPrefFindTransparencyAlpha:   @0.5,
        kPrefClickableLinkEnable:      @YES, // matches Windows default (urlUnderLineFg)
        kPrefClickableLinkNoUnderline: @NO,
        kPrefClickableLinkFullBox:     @NO,
        kPrefClickableLinkSchemes:     kDefaultClickableLinkSchemes,
        kPrefShowStatusBar:        @YES,
        kPrefToolbarVisible:       @YES,
        kPrefDockPanelsOnLeft:     @NO,
        kPrefSidePanelWidth:       @280.0,
        kPrefMuteSounds:           @NO,
        kPrefSaveAllConfirm:       @NO,
        kPrefPluginSplitViewRouting: @YES,
        kPrefRightClickKeepsSel:   @NO,
        kPrefDisableTextDragDrop:  @NO,
        kPrefMonoFontFind:         @NO,
        kPrefConfirmReplaceAll:    @YES,
        kPrefReplaceAndStop:       @NO,
        kPrefSmartHiliteCase:      @NO,
        kPrefSmartHiliteWord:      @NO,
        kPrefDateTimeReverse:      @NO,
        kPrefKeepAbsentSession:    @NO,
        kPrefShowBookmarkMargin:   @YES,
        kPrefShowEOL:              @NO,
        kPrefShowWhitespace:       @NO,
        kPrefEdgeColumn:           @0,
        kPrefEdgeMode:             @0,    // 0=off 1=line 2=background
        kPrefPaddingLeft:          @0,
        kPrefPaddingRight:         @0,
        kPrefPanelKeepState:       @YES,
        kPrefFoldStyle:            @0,    // 0=box 1=circle 2=arrow 3=simple 4=none
        kPrefLineNumDynWidth:      @YES,
        kPrefInSelThreshold:       @1024,
        kPrefFuncListUseXML:       @YES,
        kPrefToolbarIconScale:     @1.0,  // 0.50/0.75/0.90/1.00/1.25/1.50 — restart required
        kPrefFileStatusAutoDetection:  @YES,
        kPrefFileStatusUpdateSilently: @NO,
        kPrefDarkMode:             @0,   // 0=Auto, 1=Light, 2=Dark
        // Performance / Large File Restriction
        kPrefLargeFileEnabled:            @YES,
        kPrefLargeFileSizeMB:             @200,  // 1–2046; matches Windows NPP default
        kPrefLargeFileNoWrap:             @YES,
        kPrefLargeFileAllowAutoComplete:  @NO,
        kPrefLargeFileAllowSmartHilite:   @NO,
        kPrefLargeFileAllowBraceMatch:    @NO,
        kPrefLargeFileAllowURLClick:      @NO,
        kPrefLargeFileSuppress2GBWarning: @YES,
        // Delimiter pane (issue #42)
        kPrefWordCharsUseDefault:         @YES,
        kPrefWordCharsAdded:              @"",
        kPrefDelimOpen:                   @"(",
        kPrefDelimClose:                  @")",
        kPrefDelimEntireDoc:              @NO,
    }];
    // Force-upgrade any stale @NO value stored by earlier builds.
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (![ud objectForKey:kPrefUseTabs]) {
    } else if ([ud objectForKey:@"_useTabsDefaultApplied"] == nil) {
        [ud setBool:YES forKey:kPrefUseTabs];
        [ud setBool:YES forKey:@"_useTabsDefaultApplied"];
    }
    // Sync the regex-backend selector flag from the saved/default preference at
    // startup (registerDefaults above makes boolForKey valid immediately).
    gNppUseBoostRegex = [ud boolForKey:kPrefUseBoostRegex];
}

+ (instancetype)sharedController {
    static PreferencesWindowController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (void)showWindow:(id)sender {
    // Sync toolbar visibility with the main window before showing the page.
    [self _syncToolbarVisibilityFromMainWindow];

    [_pageViews removeAllObjects];
    [super showWindow:sender];
    NSInteger selectedRow = [_sidebarTable selectedRow];
    if (selectedRow >= 0) {
        [self _showPageAtIndex:selectedRow];
    }

    // Watch for toolbar toggles while the preferences window is open.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_mainWindowDidUpdate:)
                                                 name:NSWindowDidUpdateNotification
                                               object:nil];
}

- (void)windowWillClose:(NSNotification *)notification {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowDidUpdateNotification
                                                  object:nil];
}

- (void)_mainWindowDidUpdate:(NSNotification *)note {
    // Avoid feedback loops if preferences window is currently active.
    if (self.window.isKeyWindow) return;

    // Ignore updates from the preferences window itself.
    NSWindow *updatedWin = note.object;
    if (updatedWin == self.window || !updatedWin.toolbar) return;

    [self _syncToolbarVisibilityFromMainWindow];
}

- (void)_syncToolbarVisibilityFromMainWindow {
    // Find the main window toolbar and sync its state to defaults and the checkbox.
    for (NSWindow *win in [NSApp windows]) {
        if (win == self.window) continue;
        if (win.toolbar) {
            BOOL actuallyVisible = win.toolbar.visible;
            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
            if ([ud boolForKey:kPrefToolbarVisible] != actuallyVisible) {
                [ud setBool:actuallyVisible forKey:kPrefToolbarVisible];
                // Update the checkbox state.
                BOOL isHidden = !actuallyVisible;
                for (NSView *pageView in _pageViews.allValues) {
                    NSButton *hideBtn = [pageView viewWithTag:903];
                    if (hideBtn) {
                        hideBtn.state = isHidden ? NSControlStateValueOn : NSControlStateValueOff;
                        [self _updateToolbarPageControlsEnabledState:pageView hidden:isHidden];
                    }
                }
            }
            break;
        }
    }
}

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 700, 480)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    win.title = @"Preferences";
    [win center];
    self = [super initWithWindow:win];
    if (self) {
        [self registerDefaults];
        [self _buildSidebarLayout];
        [self retranslateUI];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_locChanged:)
                                                     name:NPPLocalizationChanged object:nil];
        // Observe application-wide preference alterations to ensure synchronization of UI states.
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_prefsChanged:)
                                                     name:@"NPPPreferencesChanged" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_prefsChanged:)
                                                     name:@"NPPToolbarVisibilityChanged" object:nil];
    }
    return self;
}

- (void)_locChanged:(NSNotification *)n {
    [self retranslateUI];
    [self _rebuildLanguagePopup];
}

- (void)_prefsChanged:(NSNotification *)note {
    // Update the "Hide" checkbox and color settings when the toolbar visibility changes.
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL isHidden = ![ud boolForKey:kPrefToolbarVisible];
    for (NSView *pageView in _pageViews.allValues) {
        NSButton *hideBtn = [pageView viewWithTag:903];
        if (hideBtn) {
            hideBtn.state = isHidden ? NSControlStateValueOn : NSControlStateValueOff;
            [self _updateToolbarPageControlsEnabledState:pageView hidden:isHidden];
        }
    }
}

- (void)_updateToolbarPageControlsEnabledState:(NSView *)pageView hidden:(BOOL)isHidden {
    // Enable or disable all color and styling settings on the page, except for the "Hide" checkbox.
    for (NSView *sub in pageView.subviews) {
        if ([sub respondsToSelector:@selector(setEnabled:)]) {
            if (sub.tag != 903) {
                [((id)sub) setEnabled:!isHidden];
                // Dim the controls to 50% opacity to visually signify they are inactive
                sub.alphaValue = isHidden ? 0.5 : 1.0;
            }
        }
    }
}

- (void)retranslateUI {
    NppLocalizer *loc = [NppLocalizer shared];
    self.window.title = [loc translate:@"Preferences"];

    // Rebuild sidebar page names with new translations
    _pageNames = [NSMutableArray arrayWithArray:@[
        [loc translate:@"General"],
        [loc translate:@"Toolbar"],
        [loc translate:@"Editor"],
        [loc translate:@"Indentation"],
        [loc translate:@"Tab Bar"],
        [loc translate:@"Dark Mode"],
        [loc translate:@"Margins"],
        [loc translate:@"New Document"],
        [loc translate:@"Backup"],
        [loc translate:@"Auto-Completion"],
        [loc translate:@"Searching"],
        [loc translate:@"Delimiter"],
        [loc translate:@"Cloud and Link"],
        [loc translate:@"Performance"],
        [loc translate:@"MISC."],
    ]];
    // Tahoe group: only under the Liquid Glass appearance (Classic Prefs unchanged).
    if ([NppThemeManager shared].usesGlassMaterials) {
        NSString *tahoe = [loc translate:@"Tahoe"];
        NSUInteger dm = [_pageNames indexOfObject:[loc translate:@"Dark Mode"]];
        if (dm != NSNotFound) [_pageNames insertObject:tahoe atIndex:dm + 1];
        else [_pageNames addObject:tahoe];
    }
    // Invalidate cached page views so they rebuild with new translations
    [_pageViews removeAllObjects];
    [_sidebarTable reloadData];

    // Re-show current page
    NSInteger row = _sidebarTable.selectedRow;
    if (row >= 0) [self _showPageAtIndex:row];
}

- (void)registerDefaults {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kPrefTabWidth:           @4,
        kPrefUseTabs:            @YES,
        kPrefAutoIndent:         @1,   // 0=None 1=Advanced 2=Basic
        kPrefBackspaceUnindent:  @NO,
        kPrefShowLineNumbers:    @YES,
        kPrefShowIndentGuides:   @YES,
        kPrefWordWrap:           @NO,   // persistent default (was session-only, now persistent)
        kPrefHighlightCurrentLine: @YES,
        kPrefEOLType:            @1,
        kPrefEncoding:           @0,
        kPrefAutoBackup:         @YES,
        kPrefBackupInterval:     @60,
        kPrefRememberSession:    @YES,
    }];
}

// ═══════════════════════════════════════════════════════════════════════════════
// Sidebar Layout
// ═══════════════════════════════════════════════════════════════════════════════

- (void)_buildSidebarLayout {
    NSView *root = self.window.contentView;

    // ── Page names (sidebar rows) ────────────────────────────────────────────
    _pageNames = [NSMutableArray arrayWithArray:@[
        [[NppLocalizer shared] translate:@"General"],
        [[NppLocalizer shared] translate:@"Toolbar"],
        [[NppLocalizer shared] translate:@"Editor"],
        [[NppLocalizer shared] translate:@"Indentation"],
        [[NppLocalizer shared] translate:@"Tab Bar"],
        [[NppLocalizer shared] translate:@"Dark Mode"],
        [[NppLocalizer shared] translate:@"Margins"],
        [[NppLocalizer shared] translate:@"New Document"],
        [[NppLocalizer shared] translate:@"Backup"],
        [[NppLocalizer shared] translate:@"Auto-Completion"],
        [[NppLocalizer shared] translate:@"Searching"],
        [[NppLocalizer shared] translate:@"Delimiter"],
        [[NppLocalizer shared] translate:@"Cloud and Link"],
        [[NppLocalizer shared] translate:@"Performance"],
        [[NppLocalizer shared] translate:@"MISC."],
    ]];
    // Tahoe group: only under the Liquid Glass appearance (Classic Prefs unchanged).
    if ([NppThemeManager shared].usesGlassMaterials) {
        NSString *tahoe = [[NppLocalizer shared] translate:@"Tahoe"];
        NSUInteger dm = [_pageNames indexOfObject:[[NppLocalizer shared] translate:@"Dark Mode"]];
        if (dm != NSNotFound) [_pageNames insertObject:tahoe atIndex:dm + 1];
        else [_pageNames addObject:tahoe];
    }
    _pageViews = [NSMutableDictionary dictionary];

    // ── Sidebar (source list table view) ─────────────────────────────────────
    NSScrollView *sidebarScroll = [[NSScrollView alloc] init];
    sidebarScroll.translatesAutoresizingMaskIntoConstraints = NO;
    sidebarScroll.hasVerticalScroller   = NO;
    sidebarScroll.hasHorizontalScroller = NO;
    sidebarScroll.drawsBackground = NO;

    _sidebarTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _sidebarTable.headerView = nil;
    _sidebarTable.rowHeight = 24;
    _sidebarTable.intercellSpacing = NSMakeSize(0, 2);
    _sidebarTable.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    _sidebarTable.backgroundColor = [NSColor clearColor];
    _sidebarTable.dataSource = self;
    _sidebarTable.delegate   = self;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    col.editable = NO;
    [_sidebarTable addTableColumn:col];
    sidebarScroll.documentView = _sidebarTable;

    // ── Content area (wrapped in scroll view for long pages) ────────────────
    _contentArea = [[NSView alloc] init];
    _contentArea.translatesAutoresizingMaskIntoConstraints = NO;

    _contentScroll = [[NSScrollView alloc] init];
    _contentScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _contentScroll.hasVerticalScroller   = YES;
    _contentScroll.hasHorizontalScroller = NO;
    _contentScroll.drawsBackground       = NO;
    _contentScroll.automaticallyAdjustsContentInsets = NO;
    _contentScroll.scrollerStyle = NSScrollerStyleOverlay; // macOS overlay scrollbar

    // Document view for scroll content (regular coordinate system — page views use frame positioning)
    _contentArea = [[NSView alloc] init];
    _contentScroll.documentView = _contentArea;

    // ── Close button ─────────────────────────────────────────────────────────
    NSButton *closeBtn = [NSButton buttonWithTitle:[[NppLocalizer shared] translate:@"Close"]
                                            target:self action:@selector(closePrefs:)];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    closeBtn.keyEquivalent = @"\033";

    // ── Separator between sidebar and content ────────────────────────────────
    NSBox *sep = [[NSBox alloc] init];
    sep.boxType = NSBoxSeparator;
    sep.translatesAutoresizingMaskIntoConstraints = NO;

    [root addSubview:sidebarScroll];
    [root addSubview:sep];
    [root addSubview:_contentScroll];
    [root addSubview:closeBtn];

    [NSLayoutConstraint activateConstraints:@[
        // Sidebar
        [sidebarScroll.topAnchor      constraintEqualToAnchor:root.topAnchor constant:12],
        [sidebarScroll.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:12],
        [sidebarScroll.widthAnchor    constraintEqualToConstant:170],
        [sidebarScroll.bottomAnchor   constraintEqualToAnchor:closeBtn.topAnchor constant:-12],

        // Separator
        [sep.topAnchor      constraintEqualToAnchor:root.topAnchor constant:8],
        [sep.leadingAnchor  constraintEqualToAnchor:sidebarScroll.trailingAnchor constant:8],
        [sep.widthAnchor    constraintEqualToConstant:1],
        [sep.bottomAnchor   constraintEqualToAnchor:closeBtn.topAnchor constant:-8],

        // Content scroll view
        [_contentScroll.topAnchor      constraintEqualToAnchor:root.topAnchor constant:12],
        [_contentScroll.leadingAnchor  constraintEqualToAnchor:sep.trailingAnchor constant:12],
        [_contentScroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-12],
        [_contentScroll.bottomAnchor   constraintEqualToAnchor:closeBtn.topAnchor constant:-12],

        // Close button
        [closeBtn.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],
        [closeBtn.bottomAnchor   constraintEqualToAnchor:root.bottomAnchor constant:-12],
        [closeBtn.widthAnchor    constraintEqualToConstant:80],
    ]];

    // Select first real page — defer until after layout so contentSize is valid
    [_sidebarTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _showPageAtIndex:0];
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// Sidebar Data Source & Delegate
// ═══════════════════════════════════════════════════════════════════════════════

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    if (tv.tag == 1400) return (NSInteger)_indentLangNames.count;
    return (NSInteger)_pageNames.count;
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    // Indentation language list
    if (tv.tag == 1400) {
        NSTextField *tf = [tv makeViewWithIdentifier:@"langCell" owner:nil];
        if (!tf) {
            tf = [NSTextField labelWithString:@""];
            tf.identifier = @"langCell";
            tf.font = [NSFont systemFontOfSize:12];
            tf.bordered = NO;
            tf.editable = NO;
            tf.drawsBackground = NO;
        }
        tf.stringValue = _indentLangNames[row];
        if (row == 0) tf.font = [NSFont boldSystemFontOfSize:12]; // [Default] bold
        else tf.font = [NSFont systemFontOfSize:12];
        return tf;
    }

    // Sidebar
    NSString *name = _pageNames[row];

    if ([name isEqualToString:@"-"]) {
        // Separator row
        NSBox *sep = [[NSBox alloc] init];
        sep.boxType = NSBoxSeparator;
        sep.frame = NSMakeRect(8, 10, 150, 1);
        NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 170, 20)];
        [container addSubview:sep];
        return container;
    }

    NSTextField *tf = [tv makeViewWithIdentifier:@"cell" owner:nil];
    if (!tf) {
        tf = [NSTextField labelWithString:@""];
        tf.identifier = @"cell";
        tf.font = [NSFont systemFontOfSize:13];
    }
    tf.stringValue = name;
    return tf;
}

- (CGFloat)tableView:(NSTableView *)tv heightOfRow:(NSInteger)row {
    if (tv.tag == 1400) return 18;
    NSString *name = _pageNames[row];
    return [name isEqualToString:@"-"] ? 12 : 26;
}

- (BOOL)tableView:(NSTableView *)tv shouldSelectRow:(NSInteger)row {
    if (tv.tag == 1400) return YES;
    return ![_pageNames[row] isEqualToString:@"-"]; // separators not selectable
}

- (void)tableViewSelectionDidChange:(NSNotification *)n {
    NSTableView *tv = n.object;
    if (tv.tag == 1400) {
        [self _indentLangSelectionChanged:tv];
        return;
    }
    NSInteger row = _sidebarTable.selectedRow;
    if (row >= 0) [self _showPageAtIndex:row];
}

// ═══════════════════════════════════════════════════════════════════════════════
// Page Switching
// ═══════════════════════════════════════════════════════════════════════════════

- (void)_showPageAtIndex:(NSInteger)index {
    NSString *name = _pageNames[index];
    if ([name isEqualToString:@"-"]) return;

    // Remove current content
    for (NSView *sub in [_contentArea.subviews copy])
        [sub removeFromSuperview];

    // Build or retrieve cached page view
    NSView *pageView = _pageViews[name];
    if (!pageView) {
        pageView = [self _buildPageForName:name];
        if (pageView) _pageViews[name] = pageView;
    }
    if (!pageView) return;

    // Page views use frame-based positioning: y starts high (e.g. 380) and decreases.
    // Find the bounding box of all subviews to determine actual content extent.
    CGFloat contentW = _contentScroll.contentSize.width;
    CGFloat visibleH = _contentScroll.contentSize.height;

    CGFloat maxY = 0, minY = CGFLOAT_MAX;
    for (NSView *sub in pageView.subviews) {
        CGFloat top = NSMaxY(sub.frame);
        CGFloat bot = NSMinY(sub.frame);
        if (top > maxY) maxY = top;
        if (bot < minY) minY = bot;
    }
    if (minY == CGFLOAT_MAX) { minY = 0; maxY = visibleH; }

    // Content height = span of controls + padding at top and bottom
    CGFloat controlsHeight = (maxY - minY) + 20; // 20px padding
    CGFloat pageHeight = MAX(visibleH, controlsHeight);

    // Shift controls so the topmost control sits 10px from the top of the page view
    CGFloat shiftY = pageHeight - maxY - 10;
    if (fabs(shiftY) > 1) {
        for (NSView *sub in pageView.subviews) {
            NSRect f = sub.frame;
            f.origin.y += shiftY;
            sub.frame = f;
        }
    }

    pageView.frame = NSMakeRect(0, 0, contentW, pageHeight);
    pageView.autoresizingMask = NSViewWidthSizable;
    [_contentArea addSubview:pageView];

    _contentArea.frame = NSMakeRect(0, 0, contentW, pageHeight);

    // Scroll to top (in non-flipped view, top = highest Y)
    [_contentArea scrollPoint:NSMakePoint(0, pageHeight)];
}

- (NSView *)_buildPageForName:(NSString *)name {
    NppLocalizer *loc = [NppLocalizer shared];
    if ([name isEqualToString:[loc translate:@"General"]])         return [self _buildGeneralPage];
    if ([name isEqualToString:[loc translate:@"Toolbar"]])         return [self _buildToolbarPage];
    if ([name isEqualToString:[loc translate:@"Editor"]])          return [self _buildEditorPage];
    if ([name isEqualToString:[loc translate:@"Indentation"]])    return [self _buildIndentationPage];
    if ([name isEqualToString:[loc translate:@"Tab Bar"]])         return [self _buildTabBarPage];
    if ([name isEqualToString:[loc translate:@"Dark Mode"]])       return [self _buildDarkModePage];
    if ([name isEqualToString:[loc translate:@"Tahoe"]])           return [self _buildTahoePage];
    if ([name isEqualToString:[loc translate:@"Margins"]])          return [self _buildMarginsPage];
    if ([name isEqualToString:[loc translate:@"New Document"]])     return [self _buildNewDocPage];
    if ([name isEqualToString:[loc translate:@"Backup"]])           return [self _buildBackupPage];
    if ([name isEqualToString:[loc translate:@"Auto-Completion"]])  return [self _buildAutoCompletionPage];
    if ([name isEqualToString:[loc translate:@"Searching"]])        return [self _buildSearchingPage];
    if ([name isEqualToString:[loc translate:@"Delimiter"]])        return [self _buildDelimiterPage];
    if ([name isEqualToString:[loc translate:@"Cloud and Link"]])     return [self _buildCloudLinkPage];
    if ([name isEqualToString:[loc translate:@"Performance"]])      return [self _buildPerformancePage];
    if ([name isEqualToString:[loc translate:@"MISC."]])            return [self _buildMiscPage];
    return nil;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Page Builders — Each returns an NSView with all controls
// ═══════════════════════════════════════════════════════════════════════════════

#pragma mark - General Page

- (NSView *)_buildGeneralPage {
    NSView *v = [[NSView alloc] init];
    CGFloat y = 380;

    // ── Localization ──
    NSTextField *sectionLabel = [NSTextField labelWithString:[[NppLocalizer shared] translate:@"Localization"]];
    sectionLabel.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    sectionLabel.frame = NSMakeRect(20, y, 300, 20);
    [v addSubview:sectionLabel];
    y -= 30;

    NSTextField *langLabel = [NSTextField labelWithString:[[NppLocalizer shared] translate:@"Language:"]];
    langLabel.frame = NSMakeRect(20, y, 90, 20);
    [v addSubview:langLabel];

    _languagePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(120, y - 2, 250, 26) pullsDown:NO];
    _languagePopup.tag = 400;
    _languagePopup.target = self;
    _languagePopup.action = @selector(prefChanged:);
    [self _rebuildLanguagePopup];
    [v addSubview:_languagePopup];
    y -= 36;

    NSTextField *hint = [NSTextField wrappingLabelWithString:
        [NSString stringWithFormat:@"%@\n%@",
         [[NppLocalizer shared] translate:@"Additional language files (.xml) can be placed in:"],
         @"~/Library/Application Support/Nextpad++/localization/"]];
    hint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.frame = NSMakeRect(20, y - 16, 400, 44);
    [v addSubview:hint];
    y -= 70;

    // ── Title Bar ──
    NSTextField *tbSection = [NSTextField labelWithString:[[NppLocalizer shared] translate:@"Title Bar"]];
    tbSection.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    tbSection.frame = NSMakeRect(20, y, 300, 20);
    [v addSubview:tbSection];
    y -= 28;

    NSButton *fullPath = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"Show full file path in title bar"]
                                              target:self action:@selector(prefChanged:)];
    fullPath.frame = NSMakeRect(20, y, 350, 20);
    fullPath.state = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefShowFullPathInTitle]
                     ? NSControlStateValueOn : NSControlStateValueOff;
    fullPath.tag = 900;
    [v addSubview:fullPath];
    y -= 32;

    // ── Status Bar ──
    NSTextField *sbSection = [NSTextField labelWithString:[[NppLocalizer shared] translate:@"Status Bar"]];
    sbSection.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    sbSection.frame = NSMakeRect(20, y, 300, 20);
    [v addSubview:sbSection];
    y -= 28;

    NSButton *showSB = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"Show status bar"]
                                            target:self action:@selector(prefChanged:)];
    showSB.frame = NSMakeRect(20, y, 350, 20);
    showSB.state = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefShowStatusBar]
                   ? NSControlStateValueOn : NSControlStateValueOff;
    showSB.tag = 901;
    [v addSubview:showSB];
    y -= 32;

    // ── Panel Placement ──
    NSTextField *panelSection = [NSTextField labelWithString:[[NppLocalizer shared] translate:@"Panel Placement"]];
    panelSection.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    panelSection.frame = NSMakeRect(20, y, 300, 20);
    [v addSubview:panelSection];
    y -= 28;

    NSButton *dockLeft = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"Dock side panels on the left"]
                                              target:self action:@selector(prefChanged:)];
    dockLeft.frame = NSMakeRect(20, y, 350, 20);
    dockLeft.state = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefDockPanelsOnLeft]
                     ? NSControlStateValueOn : NSControlStateValueOff;
    dockLeft.tag = 902;
    [v addSubview:dockLeft];

    return v;
}

#pragma mark - Toolbar Page

- (NSView *)_buildToolbarPage {
    NSView *v = [[NSView alloc] init];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NppLocalizer *loc = [NppLocalizer shared];
    CGFloat y = 380;

    NSInteger mode   = [ud integerForKey:kPrefToolbarColorMode];
    NSInteger choice = [ud integerForKey:kPrefToolbarColorChoice];

    // ── Colorization (radio: Off / Partial / Complete) ──
    NSTextField *s1 = [NSTextField labelWithString:[loc translate:@"Colorization"]];
    s1.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    s1.frame = NSMakeRect(20, y, 320, 20); [v addSubview:s1];
    y -= 28;

    NSArray *modes = @[ @[[loc translate:@"Off"], @0],
                        @[[loc translate:@"Partial (recolor accents only)"], @1],
                        @[[loc translate:@"Complete (recolor entire icon)"], @2] ];
    for (NSArray *m in modes) {
        NSButton *r = [NSButton radioButtonWithTitle:m[0] target:self
                                              action:@selector(_toolbarColorModeChanged:)];
        r.tag = [m[1] integerValue];
        r.frame = NSMakeRect(30, y, 360, 20);
        r.state = (mode == r.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        [v addSubview:r];
        y -= 24;
    }
    y -= 14;

    // ── Color choice (two columns of radios + custom well) ──
    NSTextField *s2 = [NSTextField labelWithString:[loc translate:@"Color"]];
    s2.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    s2.frame = NSMakeRect(20, y, 320, 20); [v addSubview:s2];
    y -= 26;

    NSArray *colors = @[ [loc translate:@"Red"], [loc translate:@"Green"], [loc translate:@"Blue"],
                         [loc translate:@"Purple"], [loc translate:@"Cyan"], [loc translate:@"Olive"],
                         [loc translate:@"Yellow"], [loc translate:@"System Accent"], [loc translate:@"Custom"] ];
    CGFloat colY = y;
    for (NSInteger i = 0; i < (NSInteger)colors.count; i++) {
        NSButton *r = [NSButton radioButtonWithTitle:colors[i] target:self
                                              action:@selector(_toolbarColorChoiceChanged:)];
        r.tag = i;
        BOOL left = (i < 5);
        CGFloat x  = left ? 30 : 210;
        CGFloat ry = left ? (colY - i * 24) : (colY - (i - 5) * 24);
        r.frame = NSMakeRect(x, ry, 170, 20);
        r.state = (choice == i) ? NSControlStateValueOn : NSControlStateValueOff;
        [v addSubview:r];
    }

    // Custom color well — aligned with the "Custom" radio (right column, row 3).
    NSColorWell *well = [[NSColorWell alloc] initWithFrame:NSMakeRect(380, colY - 3 * 24 - 1, 44, 22)];
    NSData *cd = [ud dataForKey:kPrefToolbarCustomColor];
    NSColor *cc = cd ? [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class] fromData:cd error:nil] : nil;
    well.color  = cc ?: [NSColor systemBlueColor];
    well.target = self;
    well.action = @selector(_toolbarCustomColorChanged:);
    [v addSubview:well];

    y = colY - 5 * 24 - 18;

    // ── Plugins ──
    NSButton *plug = [NSButton checkboxWithTitle:[loc translate:@"Apply to plugin toolbar icons"]
                                          target:self action:@selector(_toolbarColorPluginsChanged:)];
    plug.frame = NSMakeRect(20, y, 400, 20);
    plug.state = [ud boolForKey:kPrefToolbarColorPlugins] ? NSControlStateValueOn : NSControlStateValueOff;
    [v addSubview:plug];
    y -= 24;

    NSTextField *note = [NSTextField wrappingLabelWithString:
        [loc translate:@"In Complete mode plugin icons become a single solid color."]];
    note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    note.textColor = NSColor.secondaryLabelColor;
    note.frame = NSMakeRect(38, y - 18, 400, 34);
    [v addSubview:note];

    // Decrement layout origin coordinate to space the checkbox appropriately.
    y -= 52;

    // Instantiate and configure the "Hide" checkbox.
    NSButton *hideBtn = [NSButton checkboxWithTitle:[loc translate:@"Hide"]
                                             target:self action:@selector(prefChanged:)];
    hideBtn.tag = 903;
    hideBtn.frame = NSMakeRect(20, y, 400, 20);
    // Check the box if the toolbar is hidden.
    hideBtn.state = ![ud boolForKey:kPrefToolbarVisible] ? NSControlStateValueOn : NSControlStateValueOff;
    [v addSubview:hideBtn];

    // Disable all options above if the toolbar is currently hidden.
    [self _updateToolbarPageControlsEnabledState:v hidden:![ud boolForKey:kPrefToolbarVisible]];

    return v;
}

#pragma mark - Tahoe Page (gated — Liquid Glass appearance only)

// A dedicated "Tahoe" Preferences group. The sidebar row is added only under the
// Tahoe appearance (see _pageNames build sites), so Classic Preferences is
// unchanged. Currently hosts the toolbar group editor; future Tahoe-only settings
// land here too.
- (NSView *)_buildTahoePage {
    NSView *v = [[NSView alloc] init];
    NppLocalizer *loc = [NppLocalizer shared];
    CGFloat y = 380;

    NSTextField *th = [NSTextField labelWithString:[loc translate:@"Toolbar Groups"]];
    th.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    th.frame = NSMakeRect(20, y, 360, 20); [v addSubview:th];
    y -= 26;

    NSTextField *help = [NSTextField wrappingLabelWithString:[loc translate:
        @"Choose where each button appears in the Liquid Glass toolbar: on the "
        @"group capsule (Toolbar), in the group's ▾ overflow menu, or Hidden."]];
    help.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    help.textColor = NSColor.secondaryLabelColor;
    help.frame = NSMakeRect(20, y - 34, 440, 34); [v addSubview:help];
    y -= 34 + 14;

    [self _buildTahoeEditGroups];

    const CGFloat outlineH = 340;
    NSScrollView *sc = [[NSScrollView alloc] initWithFrame:
        NSMakeRect(20, y - outlineH, 460, outlineH)];
    sc.hasVerticalScroller = YES;
    sc.borderType = NSBezelBorder;
    sc.autohidesScrollers = YES;

    NSOutlineView *ov = [[NSOutlineView alloc] initWithFrame:sc.bounds];
    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameCol.title = [loc translate:@"Button"]; nameCol.width = 280; nameCol.minWidth = 160;
    NSTableColumn *placeCol = [[NSTableColumn alloc] initWithIdentifier:@"placement"];
    placeCol.title = [loc translate:@"Placement"]; placeCol.width = 150; placeCol.minWidth = 120;
    [ov addTableColumn:nameCol];
    [ov addTableColumn:placeCol];
    ov.outlineTableColumn = nameCol;
    ov.dataSource = self;
    ov.delegate = self;
    ov.indentationPerLevel = 14;
    ov.allowsColumnResizing = YES;
    ov.usesAlternatingRowBackgroundColors = YES;
    sc.documentView = ov;
    [v addSubview:sc];
    _tahoeOutline = ov;
    [ov reloadData];
    [ov expandItem:nil expandChildren:YES];
    y -= outlineH + 12;

    NSButton *reset = [NSButton buttonWithTitle:[loc translate:@"Reset to Defaults"]
                                         target:self action:@selector(_tahoeResetGroups:)];
    reset.bezelStyle = NSBezelStyleRounded;
    reset.frame = NSMakeRect(20, y - 6, 170, 26); [v addSubview:reset];

    return v;
}

- (void)_toolbarColorModeChanged:(NSButton *)sender {
    [[NSUserDefaults standardUserDefaults] setInteger:sender.tag forKey:kPrefToolbarColorMode];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NPPToolbarColorChanged" object:nil];
}

- (void)_toolbarColorChoiceChanged:(NSButton *)sender {
    [[NSUserDefaults standardUserDefaults] setInteger:sender.tag forKey:kPrefToolbarColorChoice];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NPPToolbarColorChanged" object:nil];
}

- (void)_toolbarCustomColorChanged:(NSColorWell *)sender {
    NSData *d = [NSKeyedArchiver archivedDataWithRootObject:sender.color
                                     requiringSecureCoding:YES error:nil];
    if (d) [[NSUserDefaults standardUserDefaults] setObject:d forKey:kPrefToolbarCustomColor];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NPPToolbarColorChanged" object:nil];
}

- (void)_toolbarColorPluginsChanged:(NSButton *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn)
                                            forKey:kPrefToolbarColorPlugins];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NPPToolbarColorChanged" object:nil];
}

#pragma mark - Tahoe Toolbar Group Editor (gated)

// State codes used in the edit model and the placement popup: 0=Toolbar (primary),
// 1=Overflow menu, 2=Hidden.

// Build the editable tree from the on-disk Tahoe config (or defaults). Built-in
// groups draw their button universe from the defaults catalog (so Hidden buttons
// can be re-surfaced); the Plugins group's universe comes from the file (the host
// materializes all live plugins into it).
- (void)_buildTahoeEditGroups {
    NSArray<NSDictionary *> *loaded   = [TahoeToolbarConfig load];
    NSArray<NSDictionary *> *defaults = [TahoeToolbarConfig defaultBuiltinGroups];

    NSMutableDictionary<NSString *, NSDictionary *> *loadedByLabel = [NSMutableDictionary dictionary];
    for (NSDictionary *g in loaded) if (g[@"label"]) loadedByLabel[g[@"label"]] = g;

    NSMutableArray *groups = [NSMutableArray array];

    for (NSDictionary *def in defaults) {
        NSString *label   = def[@"label"];
        NSDictionary *lf  = loadedByLabel[label];
        NSArray *primary  = lf ? (lf[@"primary"]  ?: @[]) : (def[@"primary"]  ?: @[]);
        NSArray *overflow = lf ? (lf[@"overflow"] ?: @[]) : (def[@"overflow"] ?: @[]);
        NSSet *primSet = [NSSet setWithArray:primary];
        NSSet *overSet = [NSSet setWithArray:overflow];

        // Display order: file primary, then file overflow, then any remaining
        // default-universe buttons (currently hidden), in default order.
        NSMutableArray<NSString *> *order = [NSMutableArray array];
        for (NSString *k in primary)  if (![order containsObject:k]) [order addObject:k];
        for (NSString *k in overflow) if (![order containsObject:k]) [order addObject:k];
        NSMutableArray<NSString *> *universe = [NSMutableArray array];
        [universe addObjectsFromArray:(def[@"primary"]  ?: @[])];
        [universe addObjectsFromArray:(def[@"overflow"] ?: @[])];
        for (NSString *k in universe) if (![order containsObject:k]) [order addObject:k];

        NSMutableArray *items = [NSMutableArray array];
        for (NSString *k in order) {
            NSInteger state = [primSet containsObject:k] ? 0 : ([overSet containsObject:k] ? 1 : 2);
            [items addObject:[@{ @"key": k,
                                 @"display": [TahoeToolbarConfig displayNameForId:k],
                                 @"state": @(state) } mutableCopy]];
        }
        [groups addObject:[@{ @"label": label, @"kind": @"builtin",
                              @"items": items } mutableCopy]];
    }

    // Plugins group (universe from the file; display name = the command name).
    NSDictionary *plug = nil;
    for (NSDictionary *g in loaded)
        if ([g[@"kind"] isEqualToString:@"plugins"]) { plug = g; break; }
    if (plug) {
        NSMutableArray *items = [NSMutableArray array];
        NSArray *sections = @[ @[@"primary", @0], @[@"overflow", @1], @[@"hidden", @2] ];
        for (NSArray *sec in sections)
            for (NSString *k in (NSArray *)(plug[sec[0]] ?: @[]))
                [items addObject:[@{ @"key": k, @"display": k, @"state": sec[1] } mutableCopy]];
        if (items.count)
            [groups addObject:[@{ @"label": @"Plugins", @"kind": @"plugins",
                                  @"customized": @([plug[@"customized"] boolValue]),
                                  @"items": items } mutableCopy]];
    }

    _tahoeEditGroups = groups;
}

// Serialize the edit tree back to the file and tell the live window to rebuild.
- (void)_tahoeSaveEditGroups {
    NSMutableArray *model = [NSMutableArray array];
    for (NSDictionary *g in _tahoeEditGroups) {
        NSMutableArray *primary = [NSMutableArray array];
        NSMutableArray *overflow = [NSMutableArray array];
        NSMutableArray *hidden = [NSMutableArray array];
        for (NSDictionary *it in g[@"items"]) {
            NSString *k = it[@"key"];
            switch ([it[@"state"] integerValue]) {
                case 0:  [primary addObject:k];  break;
                case 1:  [overflow addObject:k]; break;
                default: [hidden addObject:k];   break;
            }
        }
        NSMutableDictionary *gm = [@{ @"label": g[@"label"], @"kind": g[@"kind"],
                                      @"primary": primary, @"overflow": overflow,
                                      @"hidden": hidden } mutableCopy];
        if ([g[@"customized"] boolValue]) gm[@"customized"] = @YES;
        [model addObject:gm];
    }
    [TahoeToolbarConfig saveModel:model];
    [[NSNotificationCenter defaultCenter] postNotificationName:NPPTahoeToolbarConfigChanged object:nil];
}

- (void)_tahoePlacementChanged:(NSPopUpButton *)sender {
    NSInteger row = [_tahoeOutline rowForView:sender];
    if (row < 0) return;
    id item = [_tahoeOutline itemAtRow:row];
    if (![item isKindOfClass:[NSMutableDictionary class]] || !item[@"state"]) return;
    item[@"state"] = @(sender.indexOfSelectedItem);
    // Editing a plugin row means the user has taken over the Plugins group, so the
    // host stops re-applying its smart default and preserves this arrangement.
    id parent = [_tahoeOutline parentForItem:item];
    if ([parent isKindOfClass:[NSMutableDictionary class]] &&
        [parent[@"kind"] isEqualToString:@"plugins"])
        ((NSMutableDictionary *)parent)[@"customized"] = @YES;
    [self _tahoeSaveEditGroups];
}

- (void)_tahoeResetGroups:(id)sender {
    // Delete the file, let the host regenerate it (defaults + live plugins)
    // synchronously, then reload the editor from the fresh file.
    [TahoeToolbarConfig removeFile];
    [[NSNotificationCenter defaultCenter] postNotificationName:NPPTahoeToolbarConfigChanged object:nil];
    [self _buildTahoeEditGroups];
    [_tahoeOutline reloadData];
    [_tahoeOutline expandItem:nil expandChildren:YES];
}

#pragma mark NSOutlineView data source / delegate (Tahoe editor)

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    if (item == nil) return (NSInteger)_tahoeEditGroups.count;
    if ([item isKindOfClass:[NSDictionary class]] && item[@"items"])
        return (NSInteger)((NSArray *)item[@"items"]).count;
    return 0;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item {
    if (item == nil) return _tahoeEditGroups[index];
    return ((NSArray *)item[@"items"])[index];
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
    return [item isKindOfClass:[NSDictionary class]] && item[@"items"] != nil;
}

- (BOOL)outlineView:(NSOutlineView *)ov shouldSelectItem:(id)item {
    return NO;
}

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    NppLocalizer *loc = [NppLocalizer shared];
    BOOL isGroup = ([item isKindOfClass:[NSDictionary class]] && item[@"items"] != nil);

    if ([col.identifier isEqualToString:@"name"]) {
        NSTextField *tf = [ov makeViewWithIdentifier:@"tahoeName" owner:self];
        if (!tf) {
            tf = [NSTextField labelWithString:@""];
            tf.identifier = @"tahoeName";
            tf.bordered = NO; tf.drawsBackground = NO; tf.editable = NO;
        }
        if (isGroup) {
            tf.stringValue = [loc translate:item[@"label"]];
            tf.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
        } else {
            tf.stringValue = item[@"display"] ?: (item[@"key"] ?: @"");
            tf.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
        }
        return tf;
    }

    if ([col.identifier isEqualToString:@"placement"]) {
        if (isGroup) return nil;
        NSPopUpButton *pop = [ov makeViewWithIdentifier:@"tahoePlace" owner:self];
        if (!pop) {
            pop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 140, 22) pullsDown:NO];
            pop.identifier = @"tahoePlace";
            pop.controlSize = NSControlSizeSmall;
            pop.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
            [pop addItemsWithTitles:@[ [loc translate:@"Toolbar"],
                                       [loc translate:@"Overflow menu"],
                                       [loc translate:@"Hidden"] ]];
            pop.target = self;
            pop.action = @selector(_tahoePlacementChanged:);
        }
        [pop selectItemAtIndex:[item[@"state"] integerValue]];
        return pop;
    }
    return nil;
}

#pragma mark - Editor Page

- (NSView *)_buildEditorPage {
    NSView *v = [[NSView alloc] init];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    CGFloat y = 380;

    NppLocalizer *loc = [NppLocalizer shared];
    NSArray *checks = @[
        @[[loc translate:@"Show line numbers"],               @103, kPrefShowLineNumbers],
        @[[loc translate:@"Word wrap"],                       @104, kPrefWordWrap],
        @[[loc translate:@"Highlight current line"],          @105, kPrefHighlightCurrentLine],
        @[[loc translate:@"Auto-close brackets ( ) [ ] { }"], @700, kPrefAutoCloseBrackets],
        @[[loc translate:@"Enable virtual space"],            @702, kPrefVirtualSpace],
        @[[loc translate:@"Column selection switches to multi-editing"], @713, kPrefColumnSel2MultiEdit],
        @[[loc translate:@"Scroll beyond last line"],         @703, kPrefScrollBeyondLastLine],
        @[[loc translate:@"Copy/cut line without selection"],  @706, kPrefCopyLineNoSelection],
        @[[loc translate:@"Right-click keeps selection"],      @707, kPrefRightClickKeepsSel],
        @[[loc translate:@"Disable selected text drag-drop"],  @708, kPrefDisableTextDragDrop],
        @[[loc translate:@"Show bookmark margin"],             @709, kPrefShowBookmarkMargin],
        @[[loc translate:@"Show EOL markers"],                 @710, kPrefShowEOL],
        @[[loc translate:@"Show whitespace"],                  @711, kPrefShowWhitespace],
    ];
    for (NSArray *def in checks) {
        NSButton *chk = [NSButton checkboxWithTitle:def[0] target:self action:@selector(prefChanged:)];
        chk.frame = NSMakeRect(20, y, 350, 20);
        chk.state = [ud boolForKey:def[2]] ? NSControlStateValueOn : NSControlStateValueOff;
        chk.tag = [def[1] integerValue];
        [v addSubview:chk];
        y -= 28;
    }

    y -= 8;
    // Caret width
    NSTextField *cwLabel = [NSTextField labelWithString:[loc translate:@"Caret width:"]];
    cwLabel.frame = NSMakeRect(20, y, 100, 20);
    [v addSubview:cwLabel];
    NSPopUpButton *cwPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(130, y-2, 120, 26) pullsDown:NO];
    [cwPopup addItemsWithTitles:@[[loc translate:@"Thin (1px)"], [loc translate:@"Medium (2px)"], [loc translate:@"Thick (3px)"]]];
    [cwPopup selectItemAtIndex:[ud integerForKey:kPrefCaretWidth] - 1];
    cwPopup.tag = 701; cwPopup.target = self; cwPopup.action = @selector(prefChanged:);
    [v addSubview:cwPopup];
    y -= 32;

    // Caret blink rate
    NSTextField *brLabel = [NSTextField labelWithString:[loc translate:@"Caret blink rate (ms):"]];
    brLabel.frame = NSMakeRect(20, y, 160, 20);
    [v addSubview:brLabel];
    NSTextField *brField = [[NSTextField alloc] initWithFrame:NSMakeRect(190, y-2, 60, 22)];
    brField.integerValue = [ud integerForKey:kPrefCaretBlinkRate];
    brField.tag = 704; brField.target = self; brField.action = @selector(prefChanged:);
    [v addSubview:brField];
    y -= 32;

    // Font quality
    NSTextField *fqLabel = [NSTextField labelWithString:[loc translate:@"Font rendering:"]];
    fqLabel.frame = NSMakeRect(20, y, 120, 20);
    [v addSubview:fqLabel];
    NSPopUpButton *fqPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(150, y-2, 180, 26) pullsDown:NO];
    [fqPopup addItemsWithTitles:@[[loc translate:@"Default"], [loc translate:@"None"], [loc translate:@"Antialiased"], [loc translate:@"LCD Optimized"]]];
    [fqPopup selectItemAtIndex:[ud integerForKey:kPrefFontQuality]];
    fqPopup.tag = 705; fqPopup.target = self; fqPopup.action = @selector(prefChanged:);
    [v addSubview:fqPopup];

    // Line spacing (issue #149) — multiplier presets applied as extra ascent
    // + descent in pixels (Scintilla SCI_SETEXTRAASCENT/DESCENT). 1.0 = current.
    y -= 32;
    NSTextField *lsLabel = [NSTextField labelWithString:[loc translate:@"Line spacing:"]];
    lsLabel.frame = NSMakeRect(20, y, 120, 20);
    [v addSubview:lsLabel];
    NSPopUpButton *lsPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(150, y-2, 180, 26) pullsDown:NO];
    [lsPopup addItemsWithTitles:@[
        [loc translate:@"1.0 (Default)"], @"1.2", @"1.3", @"1.4", @"1.5"]];
    static const double kLineHeightPresets[5] = {1.0, 1.2, 1.3, 1.4, 1.5};
    double curMult = [ud doubleForKey:kPrefLineHeightMultiplier];
    NSInteger lsIdx = 0;
    for (NSInteger i = 0; i < 5; i++) {
        if (fabs(curMult - kLineHeightPresets[i]) < 1e-6) { lsIdx = i; break; }
    }
    [lsPopup selectItemAtIndex:lsIdx];
    lsPopup.tag = 712; lsPopup.target = self; lsPopup.action = @selector(prefChanged:);
    [v addSubview:lsPopup];

    return v;
}

#pragma mark - Indentation Page

// Internal language name → display name for Indentation page
static NSDictionary<NSString *, NSString *> *_langDisplayNames() {
    static NSDictionary *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{
            @"ada":@"Ada", @"asm":@"Assembly", @"asp":@"ASP",
            @"bash":@"Bash", @"batch":@"Batch",
            @"c":@"C", @"cs":@"C#", @"cpp":@"C++", @"cmake":@"CMake",
            @"cobol":@"COBOL", @"css":@"CSS",
            @"d":@"D", @"diff":@"Diff",
            @"erlang":@"Erlang",
            @"fortran":@"Fortran",
            @"go":@"Go", @"groovy":@"Groovy",
            @"haskell":@"Haskell", @"html":@"HTML",
            @"ini":@"INI", @"inno":@"Inno Setup",
            @"java":@"Java", @"javascript":@"JavaScript", @"json":@"JSON", @"json5":@"JSON5", @"jsp":@"JSP",
            @"latex":@"LaTeX", @"lisp":@"Lisp", @"lua":@"Lua",
            @"makefile":@"Makefile", @"matlab":@"MATLAB", @"mssql":@"MS SQL",
            @"nim":@"Nim", @"nsis":@"NSIS",
            @"objc":@"Objective-C",
            @"pascal":@"Pascal", @"perl":@"Perl", @"php":@"PHP",
            @"powershell":@"PowerShell", @"props":@"Properties", @"python":@"Python",
            @"r":@"R", @"rc":@"Resource", @"ruby":@"Ruby", @"rust":@"Rust",
            @"scheme":@"Scheme", @"smalltalk":@"Smalltalk", @"sql":@"SQL",
            @"swift":@"Swift",
            @"tcl":@"Tcl", @"tex":@"TeX", @"toml":@"TOML", @"typescript":@"TypeScript",
            @"vb":@"Visual Basic", @"vhdl":@"VHDL",
            @"xml":@"XML",
            @"yaml":@"YAML",
        };
    });
    return m;
}

- (NSView *)_buildIndentationPage {
    NSView *v = [[NSView alloc] init];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NppLocalizer *loc = [NppLocalizer shared];
    CGFloat y = 380;

    // ── Build language list: [Default] + sorted display names ──
    NSDictionary *displayMap = _langDisplayNames();
    NSArray<NSString *> *rawNames = [[NppLangsManager shared] allLanguageNames];
    NSMutableArray<NSString *> *displayNames = [NSMutableArray arrayWithObject:@"[Default]"];
    [displayNames addObject:@"Normal text"];
    NSMutableDictionary *reverseMap = [NSMutableDictionary dictionary];
    NSMutableArray *sorted = [NSMutableArray array];
    for (NSString *raw in rawNames) {
        NSString *display = displayMap[raw] ?: raw;
        [sorted addObject:display];
        reverseMap[display] = raw;
    }
    [sorted sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [displayNames addObjectsFromArray:sorted];
    _indentLangNames = [displayNames copy];
    _indentDisplayToInternal = [reverseMap copy];
    _indentSelectedLang = nil; // [Default] selected initially

    // ── Indent Settings group ──
    NSBox *indentBox = [[NSBox alloc] initWithFrame:NSMakeRect(16, y - 180, 175, 190)];
    indentBox.title = [loc translate:@"Indent Settings"];
    indentBox.titlePosition = NSAtTop;

    NSScrollView *langScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(-1, -1, 159, 165)];
    langScroll.hasVerticalScroller = YES;
    langScroll.borderType = NSBezelBorder;
    NSTableView *langTable = [[NSTableView alloc] initWithFrame:langScroll.bounds];
    NSTableColumn *langCol = [[NSTableColumn alloc] initWithIdentifier:@"lang"];
    langCol.title = @"";
    langCol.width = 139;
    [langTable addTableColumn:langCol];
    langTable.headerView = nil;
    langTable.rowHeight = 18;
    langTable.tag = 1400;
    langTable.dataSource = self;
    langTable.delegate = self;
    langScroll.documentView = langTable;
    [indentBox addSubview:langScroll];
    // Select [Default] row
    [langTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [v addSubview:indentBox];

    // ── Indent options box (below Indent Settings) ──
    CGFloat optBoxTop = y - 190;  // just below indentBox
    NSBox *optBox = [[NSBox alloc] initWithFrame:NSMakeRect(19, optBoxTop - 193, 430, 193)];
    optBox.titlePosition = NSNoTitle;

    // "Use default value" checkbox at top
    NSButton *defaultChk = [NSButton checkboxWithTitle:[loc translate:@"Use default value"]
                                                target:self action:@selector(_useDefaultValueChanged:)];
    defaultChk.frame = NSMakeRect(15, 153, 200, 20);
    defaultChk.state = NSControlStateValueOn; // default is checked (use global settings)
    defaultChk.tag = 1320;
    [optBox addSubview:defaultChk];

    CGFloat oy = 118;

    NSFont *smallFont = [NSFont systemFontOfSize:[NSFont systemFontSize] - 1];

    NSTextField *sizeLabel = [NSTextField labelWithString:[loc translate:@"Indent size:"]];
    sizeLabel.frame = NSMakeRect(15, oy, 90, 20);
    sizeLabel.font = smallFont;
    sizeLabel.tag = 1330;
    [optBox addSubview:sizeLabel];

    NSTextField *sizeField = [[NSTextField alloc] initWithFrame:NSMakeRect(115, oy - 2, 50, 22)];
    sizeField.integerValue = [ud integerForKey:kPrefTabWidth];
    sizeField.tag = 100;
    sizeField.target = self;
    sizeField.action = @selector(prefChanged:);
    sizeField.enabled = NO;
    [optBox addSubview:sizeField];
    oy -= 30;

    NSTextField *usingLabel = [NSTextField labelWithString:[loc translate:@"Indent using:"]];
    usingLabel.frame = NSMakeRect(15, oy, 100, 20);
    usingLabel.font = smallFont;
    usingLabel.tag = 1331;
    [optBox addSubview:usingLabel];
    oy -= 24;

    BOOL useTabs = [ud boolForKey:kPrefUseTabs];
    NSButton *tabRadio = [NSButton radioButtonWithTitle:[loc translate:@"Tab character"]
                                                 target:self action:@selector(_indentUsingChanged:)];
    tabRadio.frame = NSMakeRect(25, oy, 150, 20);
    tabRadio.font = smallFont;
    tabRadio.tag = 1301;
    tabRadio.state = useTabs ? NSControlStateValueOn : NSControlStateValueOff;
    tabRadio.enabled = NO;
    [optBox addSubview:tabRadio];
    oy -= 24;

    NSButton *spaceRadio = [NSButton radioButtonWithTitle:[loc translate:@"Space character(s)"]
                                                   target:self action:@selector(_indentUsingChanged:)];
    spaceRadio.frame = NSMakeRect(25, oy, 150, 20);
    spaceRadio.font = smallFont;
    spaceRadio.tag = 1302;
    spaceRadio.state = useTabs ? NSControlStateValueOff : NSControlStateValueOn;
    spaceRadio.enabled = NO;
    [optBox addSubview:spaceRadio];
    oy -= 30;

    NSButton *bsChk = [NSButton checkboxWithTitle:[loc translate:@"Backspace key unindents instead of removing single space"]
                                           target:self action:@selector(prefChanged:)];
    bsChk.frame = NSMakeRect(15, oy, 400, 20);
    bsChk.font = smallFont;
    bsChk.state = [ud boolForKey:kPrefBackspaceUnindent] ? NSControlStateValueOn : NSControlStateValueOff;
    bsChk.tag = 1303;
    bsChk.enabled = NO;
    [optBox addSubview:bsChk];

    [v addSubview:optBox];

    // [Default] is selected initially — hide "Use default value" checkbox and
    // enable controls. The table selection delegate may not fire during page
    // construction because the view isn't yet in a window.
    defaultChk.hidden = YES;
    sizeField.enabled = YES;
    tabRadio.enabled = YES;
    spaceRadio.enabled = YES;
    bsChk.enabled = YES;

    // ── Auto-indent radio group (right of Indent Settings) ──
    NSBox *autoBox = [[NSBox alloc] initWithFrame:NSMakeRect(215, y - 90, 160, 100)];
    autoBox.title = [loc translate:@"Auto-indent"];
    autoBox.titlePosition = NSAtTop;

    NSInteger mode = [ud integerForKey:kPrefAutoIndent];
    // Migrate legacy BOOL: YES(1) → Advanced(1), NO(0) → None(0) — already compatible

    NSButton *noneRadio = [NSButton radioButtonWithTitle:[loc translate:@"None"]
                                                  target:self action:@selector(_autoIndentChanged:)];
    noneRadio.frame = NSMakeRect(15, 50, 120, 20);
    noneRadio.tag = 1310;
    noneRadio.state = (mode == 0) ? NSControlStateValueOn : NSControlStateValueOff;
    [autoBox addSubview:noneRadio];

    NSButton *basicRadio = [NSButton radioButtonWithTitle:[loc translate:@"Basic"]
                                                   target:self action:@selector(_autoIndentChanged:)];
    basicRadio.frame = NSMakeRect(15, 30, 120, 20);
    basicRadio.tag = 1311;
    basicRadio.state = (mode == 2) ? NSControlStateValueOn : NSControlStateValueOff;
    [autoBox addSubview:basicRadio];

    NSButton *advRadio = [NSButton radioButtonWithTitle:[loc translate:@"Advanced"]
                                                 target:self action:@selector(_autoIndentChanged:)];
    advRadio.frame = NSMakeRect(15, 10, 120, 20);
    advRadio.tag = 1312;
    advRadio.state = (mode == 1) ? NSControlStateValueOn : NSControlStateValueOff;
    [autoBox addSubview:advRadio];

    [v addSubview:autoBox];

    return v;
}

// Resolve indent settings for the selected language.
// Returns {tabSize, useTabs} from: user override → langs.xml tabSettings → global default.
- (void)_getIndentForLang:(NSString *)lang tabSize:(NSInteger *)outSize useTabs:(BOOL *)outUseTabs hasOverride:(BOOL *)outHasOverride {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSInteger globalSize = [ud integerForKey:kPrefTabWidth];
    if (globalSize < 1) globalSize = 4;
    BOOL globalUseTabs = [ud boolForKey:kPrefUseTabs];

    if (!lang.length) {
        // [Default] or Normal text — show global settings
        *outSize = globalSize;
        *outUseTabs = globalUseTabs;
        *outHasOverride = NO;
        return;
    }

    // Check user override first
    NSDictionary *overrides = [ud dictionaryForKey:kPrefTabOverrides];
    NSDictionary *langOverride = overrides[lang];
    if (langOverride) {
        *outSize = [langOverride[@"tabSize"] integerValue];
        if (*outSize < 1) *outSize = 4;
        *outUseTabs = [langOverride[@"useTabs"] boolValue];
        *outHasOverride = YES;
        return;
    }

    // Check langs.xml built-in tabSettings
    NppLangDef *def = [[NppLangsManager shared] langDefForName:lang];
    if (def && def.tabSettings >= 0) {
        NSInteger ts = def.tabSettings;
        NSInteger xmlSize = ts & 0x7F;
        BOOL xmlUseSpaces = (ts & 0x80) != 0;
        if (xmlSize > 0) {
            *outSize = xmlSize;
            *outUseTabs = !xmlUseSpaces;
            *outHasOverride = NO; // built-in, not user override
            return;
        }
    }

    // Fall back to global
    *outSize = globalSize;
    *outUseTabs = globalUseTabs;
    *outHasOverride = NO;
}

- (void)_indentLangSelectionChanged:(NSTableView *)tv {
    NSInteger row = tv.selectedRow;
    if (row < 0) return;

    NSString *displayName = _indentLangNames[row];
    // Map display name to internal name
    if (row == 0) { // [Default]
        _indentSelectedLang = nil;
    } else if (row == 1) { // Normal text
        _indentSelectedLang = @"";
    } else {
        _indentSelectedLang = _indentDisplayToInternal[displayName] ?: displayName.lowercaseString;
    }

    // Load settings for this language into the controls
    NSInteger tabSize = 4;
    BOOL useTabs = YES;
    BOOL hasOverride = NO;
    [self _getIndentForLang:_indentSelectedLang tabSize:&tabSize useTabs:&useTabs hasOverride:&hasOverride];

    // Find controls in the optBox (tag-based lookup)
    NSView *optBox = [tv.window.contentView viewWithTag:1320].superview;
    if (!optBox) return;

    for (NSView *sub in optBox.subviews) {
        if (sub.tag == 100 && [sub isKindOfClass:[NSTextField class]])
            [(NSTextField *)sub setIntegerValue:tabSize];
        else if (sub.tag == 1301 && [sub isKindOfClass:[NSButton class]])
            [(NSButton *)sub setState:useTabs ? NSControlStateValueOn : NSControlStateValueOff];
        else if (sub.tag == 1302 && [sub isKindOfClass:[NSButton class]])
            [(NSButton *)sub setState:useTabs ? NSControlStateValueOff : NSControlStateValueOn];
        else if (sub.tag == 1320 && [sub isKindOfClass:[NSButton class]]) {
            BOOL isDefault = (_indentSelectedLang == nil); // [Default] row
            if (isDefault) {
                // [Default] row: checkbox hidden, controls always enabled
                [(NSButton *)sub setHidden:YES];
            } else {
                [(NSButton *)sub setHidden:NO];
                [(NSButton *)sub setState:hasOverride ? NSControlStateValueOff : NSControlStateValueOn];
            }
        }
    }

    // Enable/disable controls based on state
    BOOL isDefault = (_indentSelectedLang == nil);
    BOOL controlsEnabled = isDefault || hasOverride;
    for (NSView *sub in optBox.subviews) {
        if (sub.tag == 1320) continue; // skip the checkbox itself
        if ([sub isKindOfClass:[NSButton class]])
            [(NSButton *)sub setEnabled:controlsEnabled];
        else if ([sub isKindOfClass:[NSTextField class]] && [(NSTextField *)sub isEditable])
            [(NSTextField *)sub setEnabled:controlsEnabled];
    }
}

- (void)_useDefaultValueChanged:(NSButton *)sender {
    BOOL useDefault = (sender.state == NSControlStateValueOn);

    if (_indentSelectedLang != nil) {
        if (!useDefault) {
            // Create override immediately with current control values
            [self _saveIndentOverrideFromBox:sender.superview];
        } else if (useDefault) {
            // Remove per-language override
            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
            NSMutableDictionary *overrides = [[ud dictionaryForKey:kPrefTabOverrides] mutableCopy] ?: [NSMutableDictionary dictionary];
            [overrides removeObjectForKey:_indentSelectedLang];
            [ud setObject:overrides forKey:kPrefTabOverrides];

            // Reload to show the effective settings (from langs.xml or global)
            NSInteger tabSize = 4; BOOL useTabs = YES; BOOL hasOvr = NO;
            [self _getIndentForLang:_indentSelectedLang tabSize:&tabSize useTabs:&useTabs hasOverride:&hasOvr];
            NSView *box = sender.superview;
            for (NSView *sub in box.subviews) {
                if (sub.tag == 100 && [sub isKindOfClass:[NSTextField class]])
                    [(NSTextField *)sub setIntegerValue:tabSize];
                else if (sub.tag == 1301 && [sub isKindOfClass:[NSButton class]])
                    [(NSButton *)sub setState:useTabs ? NSControlStateValueOn : NSControlStateValueOff];
                else if (sub.tag == 1302 && [sub isKindOfClass:[NSButton class]])
                    [(NSButton *)sub setState:useTabs ? NSControlStateValueOff : NSControlStateValueOn];
            }
        }
    }

    // Enable/disable controls
    NSView *box = sender.superview;
    for (NSView *sub in box.subviews) {
        if (sub == sender) continue;
        if ([sub isKindOfClass:[NSButton class]])
            [(NSButton *)sub setEnabled:!useDefault];
        else if ([sub isKindOfClass:[NSTextField class]] && [(NSTextField *)sub isEditable])
            [(NSTextField *)sub setEnabled:!useDefault];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:@"NPPPreferencesChanged" object:nil];
}

- (void)_saveIndentOverrideFromBox:(NSView *)box {
    // Read current values from the controls in the box
    NSInteger tabSize = 4;
    BOOL useTabs = YES;
    for (NSView *sub in box.subviews) {
        if (sub.tag == 100 && [sub isKindOfClass:[NSTextField class]])
            tabSize = [(NSTextField *)sub integerValue];
        else if (sub.tag == 1301 && [sub isKindOfClass:[NSButton class]])
            useTabs = ([(NSButton *)sub state] == NSControlStateValueOn);
    }
    if (tabSize < 1) tabSize = 4;

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (_indentSelectedLang != nil && _indentSelectedLang.length > 0) {
        // Per-language override
        NSMutableDictionary *overrides = [[ud dictionaryForKey:kPrefTabOverrides] mutableCopy] ?: [NSMutableDictionary dictionary];
        overrides[_indentSelectedLang] = @{@"tabSize": @(tabSize), @"useTabs": @(useTabs)};
        [ud setObject:overrides forKey:kPrefTabOverrides];
    } else {
        // [Default] or Normal text → save to global
        [ud setInteger:tabSize forKey:kPrefTabWidth];
        [ud setBool:useTabs forKey:kPrefUseTabs];
    }
}

- (void)_indentUsingChanged:(NSButton *)sender {
    BOOL useTabs = (sender.tag == 1301);

    // Update sibling radio in the same NSBox
    NSView *box = sender.superview;
    for (NSView *sub in box.subviews) {
        if ([sub isKindOfClass:[NSButton class]] && sub != sender) {
            NSButton *btn = (NSButton *)sub;
            if (btn.tag == 1301 || btn.tag == 1302)
                btn.state = (btn == sender) ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }

    // Save to appropriate target (global or per-language)
    if (_indentSelectedLang == nil) {
        // [Default] selected → save to global
        [[NSUserDefaults standardUserDefaults] setBool:useTabs forKey:kPrefUseTabs];
    } else {
        [self _saveIndentOverrideFromBox:box];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:@"NPPPreferencesChanged" object:nil];
}

- (void)_autoIndentChanged:(NSButton *)sender {
    // 1310=None(0), 1311=Basic(2), 1312=Advanced(1)
    NSInteger mode = 0;
    if (sender.tag == 1311) mode = 2;
    else if (sender.tag == 1312) mode = 1;

    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:kPrefAutoIndent];

    // Update sibling radios in the NSBox
    NSView *box = sender.superview;
    for (NSView *sub in box.subviews) {
        if ([sub isKindOfClass:[NSButton class]] && sub != sender) {
            [(NSButton *)sub setState:NSControlStateValueOff];
        }
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NPPPreferencesChanged" object:nil];
}

#pragma mark - Tab Bar Page

- (NSView *)_buildTabBarPage {
    NSView *v = [[NSView alloc] init];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    CGFloat y = 380;
    NppLocalizer *loc = [NppLocalizer shared];

    NSArray *checks = @[
        @[[loc translate:@"Show close button on tabs"],        @800, kPrefTabCloseButton],
        @[[loc translate:@"Double-click to close tab"],        @801, kPrefDoubleClickTabClose],
        @[[loc translate:@"Wrap tabs to multiple lines"],      @803, kPrefTabBarWrap],
        @[[loc translate:@"Hide tab bar"],                     @804, kPrefHideTabBar],
    ];
    for (NSArray *def in checks) {
        NSButton *chk = [NSButton checkboxWithTitle:def[0] target:self action:@selector(prefChanged:)];
        chk.frame = NSMakeRect(20, y, 350, 20);
        chk.state = [ud boolForKey:def[2]] ? NSControlStateValueOn : NSControlStateValueOff;
        chk.tag = [def[1] integerValue];
        [v addSubview:chk];
        y -= 28;
    }

    y -= 8;
    NSTextField *mwLabel = [NSTextField labelWithString:[loc translate:@"Max tab width (pixels):"]];
    mwLabel.frame = NSMakeRect(20, y, 170, 20);
    [v addSubview:mwLabel];
    NSTextField *mwField = [[NSTextField alloc] initWithFrame:NSMakeRect(200, y-2, 60, 22)];
    mwField.integerValue = [ud integerForKey:kPrefTabMaxLabelWidth];
    mwField.tag = 802; mwField.target = self; mwField.action = @selector(prefChanged:);
    [v addSubview:mwField];

    return v;
}

#pragma mark - Margins Page

- (NSView *)_buildMarginsPage {
    NSView *v = [[NSView alloc] init];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    CGFloat y = 380;
    NppLocalizer *loc = [NppLocalizer shared];

    // ── Edge Column ──
    NSTextField *edgeSection = [NSTextField labelWithString:[loc translate:@"Vertical Edge"]];
    edgeSection.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    edgeSection.frame = NSMakeRect(20, y, 300, 20);
    [v addSubview:edgeSection];
    y -= 28;

    NSTextField *emLabel = [NSTextField labelWithString:[loc translate:@"Edge mode:"]];
    emLabel.frame = NSMakeRect(20, y, 90, 20);
    [v addSubview:emLabel];
    NSPopUpButton *emPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(120, y-2, 160, 26) pullsDown:NO];
    [emPopup addItemsWithTitles:@[[loc translate:@"Off"], [loc translate:@"Line"], [loc translate:@"Background"]]];
    [emPopup selectItemAtIndex:[ud integerForKey:kPrefEdgeMode]];
    emPopup.tag = 1101; emPopup.target = self; emPopup.action = @selector(prefChanged:);
    [v addSubview:emPopup];
    y -= 30;

    NSTextField *ecLabel = [NSTextField labelWithString:[loc translate:@"Edge column:"]];
    ecLabel.frame = NSMakeRect(20, y, 100, 20);
    [v addSubview:ecLabel];
    NSTextField *ecField = [[NSTextField alloc] initWithFrame:NSMakeRect(130, y-2, 50, 22)];
    ecField.integerValue = [ud integerForKey:kPrefEdgeColumn];
    ecField.tag = 1100; ecField.target = self; ecField.action = @selector(prefChanged:);
    [v addSubview:ecField];
    y -= 36;

    // ── Fold Margin Style ──
    NSTextField *foldSection = [NSTextField labelWithString:[loc translate:@"Fold Margin Style"]];
    foldSection.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    foldSection.frame = NSMakeRect(20, y, 300, 20);
    [v addSubview:foldSection];
    y -= 28;

    NSPopUpButton *foldPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, y-2, 180, 26) pullsDown:NO];
    [foldPopup addItemsWithTitles:@[[loc translate:@"Box tree"], [loc translate:@"Circle tree"], [loc translate:@"Arrow"], [loc translate:@"Simple +/-"], [loc translate:@"None"]]];
    [foldPopup selectItemAtIndex:[ud integerForKey:kPrefFoldStyle]];
    foldPopup.tag = 1104; foldPopup.target = self; foldPopup.action = @selector(prefChanged:);
    [v addSubview:foldPopup];
    y -= 36;

    // ── Line Numbers ──
    NSButton *dynWidth = [NSButton checkboxWithTitle:[loc translate:@"Dynamic line number width"]
                                              target:self action:@selector(prefChanged:)];
    dynWidth.frame = NSMakeRect(20, y, 350, 20);
    dynWidth.state = [ud boolForKey:kPrefLineNumDynWidth] ? NSControlStateValueOn : NSControlStateValueOff;
    dynWidth.tag = 1105;
    [v addSubview:dynWidth];
    y -= 36;

    // ── Padding ──
    NSTextField *padSection = [NSTextField labelWithString:[loc translate:@"Padding"]];
    padSection.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    padSection.frame = NSMakeRect(20, y, 300, 20);
    [v addSubview:padSection];
    y -= 28;

    NSTextField *plLabel = [NSTextField labelWithString:[loc translate:@"Left:"]];
    plLabel.frame = NSMakeRect(20, y, 40, 20);
    [v addSubview:plLabel];
    NSTextField *plField = [[NSTextField alloc] initWithFrame:NSMakeRect(65, y-2, 50, 22)];
    plField.integerValue = [ud integerForKey:kPrefPaddingLeft];
    plField.tag = 1102; plField.target = self; plField.action = @selector(prefChanged:);
    [v addSubview:plField];

    NSTextField *prLabel = [NSTextField labelWithString:[loc translate:@"Right:"]];
    prLabel.frame = NSMakeRect(140, y, 50, 20);
    [v addSubview:prLabel];
    NSTextField *prField = [[NSTextField alloc] initWithFrame:NSMakeRect(195, y-2, 50, 22)];
    prField.integerValue = [ud integerForKey:kPrefPaddingRight];
    prField.tag = 1103; prField.target = self; prField.action = @selector(prefChanged:);
    [v addSubview:prField];

    return v;
}

#pragma mark - Dark Mode Page

- (NSView *)_buildDarkModePage {
    NSView *v = [[NSView alloc] init];
    CGFloat y = 380;

    NppLocalizer *loc = [NppLocalizer shared];
    NSTextField *dmLabel = [NSTextField labelWithString:[loc translate:@"Appearance"]];
    dmLabel.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    dmLabel.frame = NSMakeRect(20, y, 300, 20);
    [v addSubview:dmLabel];
    y -= 32;

    NSArray *titles = @[[loc translate:@"Auto (Follow System)"], [loc translate:@"Light"], [loc translate:@"Dark"]];
    for (NSInteger i = 0; i < 3; i++) {
        NSButton *radio = [NSButton radioButtonWithTitle:titles[i] target:self action:@selector(_darkModeRadioChanged:)];
        radio.frame = NSMakeRect(20, y, 300, 20);
        radio.tag = 500 + i;
        radio.state = ([NppThemeManager shared].mode == i) ? NSControlStateValueOn : NSControlStateValueOff;
        [v addSubview:radio];
        y -= 24;
    }

    return v;
}

- (void)_darkModeRadioChanged:(id)sender {
    NSInteger mode = [(NSButton *)sender tag] - 500;
    // Deselect other radios
    NSView *page = [(NSButton *)sender superview];
    for (NSView *sub in page.subviews) {
        if ([sub isKindOfClass:[NSButton class]] && [(NSButton *)sub tag] >= 500 && [(NSButton *)sub tag] <= 502) {
            [(NSButton *)sub setState:((NSButton *)sub).tag == [(NSButton *)sender tag]
                ? NSControlStateValueOn : NSControlStateValueOff];
        }
    }
    [NppThemeManager shared].mode = (NppDarkModeOption)mode;

    // Switch theme to match dark/light mode
    NPPStyleStore *store = [NPPStyleStore sharedStore];
    BOOL effectiveDark = (mode == NppDarkModeDark) ||
        (mode == NppDarkModeAuto && [NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:
            @[NSAppearanceNameDarkAqua]] != nil);
    NSString *targetTheme = effectiveDark ? @"DarkModeDefault" : @"Default (stylers.xml)";
    if (![store.activeThemeName isEqualToString:targetTheme]) {
        NSArray *lexers = [store lexersForTheme:targetTheme];
        [store commitLexers:lexers themeName:targetTheme];
    }
}

#pragma mark - New Document Page

- (NSView *)_buildNewDocPage {
    NSView *v = [[NSView alloc] init];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    CGFloat y = 380;

    NppLocalizer *loc = [NppLocalizer shared];
    NSTextField *eolLabel = [NSTextField labelWithString:[loc translate:@"Default line ending:"]];
    eolLabel.frame = NSMakeRect(20, y, 150, 20);
    [v addSubview:eolLabel];

    NSPopUpButton *eolPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(180, y-2, 180, 26) pullsDown:NO];
    [eolPopup addItemsWithTitles:@[[loc translate:@"Windows (CRLF)"], [loc translate:@"Unix (LF)"], [loc translate:@"Mac (CR)"]]];
    [eolPopup selectItemAtIndex:[ud integerForKey:kPrefEOLType]];
    eolPopup.tag = 200;
    eolPopup.target = self;
    eolPopup.action = @selector(prefChanged:);
    [v addSubview:eolPopup];
    y -= 36;

    NSTextField *encLabel = [NSTextField labelWithString:[loc translate:@"Default encoding:"]];
    encLabel.frame = NSMakeRect(20, y, 150, 20);
    [v addSubview:encLabel];

    NSPopUpButton *encPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(180, y-2, 180, 26) pullsDown:NO];
    [encPopup addItemsWithTitles:@[@"UTF-8", @"Latin-1 (ISO-8859-1)"]];
    [encPopup selectItemAtIndex:[ud integerForKey:kPrefEncoding]];
    encPopup.tag = 201;
    encPopup.target = self;
    encPopup.action = @selector(prefChanged:);
    [v addSubview:encPopup];

    return v;
}

#pragma mark - Backup Page

- (NSView *)_buildBackupPage {
    NSView *v = [[NSView alloc] init];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    CGFloat y = 380;

    NSButton *autoBackup = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"Enable auto-backup"]
                                                target:self action:@selector(prefChanged:)];
    autoBackup.frame = NSMakeRect(20, y, 350, 20);
    autoBackup.state = [ud boolForKey:kPrefAutoBackup] ? NSControlStateValueOn : NSControlStateValueOff;
    autoBackup.tag = 300;
    [v addSubview:autoBackup];
    y -= 30;

    // Issue #87 — when off, app starts with a clean editor on each launch.
    // Independent from auto-backup above (auto-backup keeps protecting unsaved
    // work in case of crash; remember-session is purely about reopening tabs).
    NSButton *rememberSession = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"Remember current session for next launch"]
                                                     target:self action:@selector(prefChanged:)];
    rememberSession.frame = NSMakeRect(20, y, 400, 20);
    rememberSession.state = [ud boolForKey:kPrefRememberSession] ? NSControlStateValueOn : NSControlStateValueOff;
    rememberSession.tag = 302;
    [v addSubview:rememberSession];
    y -= 30;

    NSTextField *intLabel = [NSTextField labelWithString:[[NppLocalizer shared] translate:@"Backup interval (seconds):"]];
    intLabel.frame = NSMakeRect(20, y, 200, 20);
    [v addSubview:intLabel];

    NSTextField *intField = [[NSTextField alloc] initWithFrame:NSMakeRect(230, y-2, 60, 22)];
    intField.integerValue = [ud integerForKey:kPrefBackupInterval];
    intField.tag = 301;
    intField.target = self;
    intField.action = @selector(prefChanged:);
    [v addSubview:intField];
    y -= 36;

    NSTextField *backupDirLabel = [NSTextField labelWithString:[[NppLocalizer shared] translate:@"Backup location:"]];
    backupDirLabel.frame = NSMakeRect(20, y, 140, 20);
    [v addSubview:backupDirLabel];
    y -= 20;

    NSTextField *backupPath = [NSTextField labelWithString:
        NppConfigSubpath(@"backup")];
    backupPath.frame = NSMakeRect(20, y, 400, 20);
    backupPath.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    [v addSubview:backupPath];

    return v;
}

#pragma mark - Auto-Completion Page

- (NSView *)_buildAutoCompletionPage {
    NSView *v = [[NSView alloc] init];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    CGFloat y = 380;
    NppLocalizer *loc = [NppLocalizer shared];

    NSArray *checks = @[
        @[[loc translate:@"Enable auto-completion on each input"],     @600, kPrefAutoCompleteEnable],
        @[[loc translate:@"Function parameters hint on input"],        @602, kPrefFuncParamsHint],
    ];
    for (NSArray *def in checks) {
        NSButton *chk = [NSButton checkboxWithTitle:def[0] target:self action:@selector(prefChanged:)];
        chk.frame = NSMakeRect(20, y, 400, 20);
        chk.state = [ud boolForKey:def[2]] ? NSControlStateValueOn : NSControlStateValueOff;
        chk.tag = [def[1] integerValue];
        [v addSubview:chk];
        y -= 28;
    }

    y -= 4;
    NSTextField *minLabel = [NSTextField labelWithString:[loc translate:@"From Nth character:"]];
    minLabel.frame = NSMakeRect(20, y, 160, 20);
    [v addSubview:minLabel];

    NSTextField *minField = [[NSTextField alloc] initWithFrame:NSMakeRect(190, y-2, 50, 22)];
    minField.integerValue = [ud integerForKey:kPrefAutoCompleteMinChars];
    minField.tag = 601;
    minField.target = self;
    minField.action = @selector(prefChanged:);
    [v addSubview:minField];

    return v;
}

#pragma mark - Searching Page

- (NSView *)_buildSearchingPage {
    NSView *v = [[NSView alloc] init];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    CGFloat y = 380;
    NppLocalizer *loc = [NppLocalizer shared];

    NSArray *checks = @[
        @[[loc translate:@"Enable smart highlighting"],              @1000, kPrefSmartHighlight],
        @[[loc translate:@"Smart highlighting: match case"],          @1002, kPrefSmartHiliteCase],
        @[[loc translate:@"Smart highlighting: whole word only"],     @1003, kPrefSmartHiliteWord],
        @[[loc translate:@"Fill find field with selected text"],      @1001, kPrefFillFindWithSelection],
        @[[loc translate:@"Use monospaced font in Find dialog"],      @1004, kPrefMonoFontFind],
        @[[loc translate:@"Confirm Replace All in open documents"],   @1005, kPrefConfirmReplaceAll],
        @[[loc translate:@"Replace: don't move to next occurrence"],  @1006, kPrefReplaceAndStop],
        @[[loc translate:@"Use Boost Regex mode (multi-line; restart to apply)"], @1008, kPrefUseBoostRegex],
    ];
    for (NSArray *def in checks) {
        NSButton *chk = [NSButton checkboxWithTitle:def[0] target:self action:@selector(prefChanged:)];
        chk.frame = NSMakeRect(20, y, 400, 20);
        chk.state = [ud boolForKey:def[2]] ? NSControlStateValueOn : NSControlStateValueOff;
        chk.tag = [def[1] integerValue];
        [v addSubview:chk];
        y -= 28;
    }

    y -= 8;
    NSTextField *threshLabel = [NSTextField labelWithString:[loc translate:@"In-selection auto-check threshold (bytes):"]];
    threshLabel.frame = NSMakeRect(20, y, 300, 20);
    [v addSubview:threshLabel];
    NSTextField *threshField = [[NSTextField alloc] initWithFrame:NSMakeRect(330, y-2, 60, 22)];
    threshField.integerValue = [ud integerForKey:kPrefInSelThreshold];
    threshField.tag = 1007; threshField.target = self; threshField.action = @selector(prefChanged:);
    [v addSubview:threshField];

    return v;
}

// Search Engine page removed — merged into Searching

#pragma mark - Cloud & Link Page

// Mirrors the "Clickable Link Settings" group from Windows NPP's "Cloud & Link"
// preferences page (issue #133). The three checkboxes encode the same state
// Windows packs into its urlMode enum; we persist them as independent booleans
// (the link feature derives its style from them). The URI customized schemes
// text box lists extra schemes that should also be treated as links.
// This wires the settings only — link detection/highlight/open is separate.
- (NSView *)_buildCloudLinkPage {
    NSView *v = [[NSView alloc] init];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NppLocalizer *loc = [NppLocalizer shared];
    CGFloat y = 380;

    NSTextField *header = [NSTextField labelWithString:[loc translate:@"Clickable Link Settings"]];
    header.frame = NSMakeRect(20, y, 400, 20);
    header.font = [NSFont boldSystemFontOfSize:13];
    [v addSubview:header];
    y -= 32;

    BOOL enabled = [ud boolForKey:kPrefClickableLinkEnable];

    NSButton *enable = [NSButton checkboxWithTitle:[loc translate:@"Enable"]
                                            target:self action:@selector(prefChanged:)];
    enable.frame = NSMakeRect(40, y, 180, 20);
    enable.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    enable.tag = 1600;
    [v addSubview:enable];

    NSButton *noUnderline = [NSButton checkboxWithTitle:[loc translate:@"No underline"]
                                                 target:self action:@selector(prefChanged:)];
    noUnderline.frame = NSMakeRect(230, y, 240, 20);
    noUnderline.state = [ud boolForKey:kPrefClickableLinkNoUnderline] ? NSControlStateValueOn : NSControlStateValueOff;
    noUnderline.tag = 1601;
    noUnderline.enabled = enabled;
    [v addSubview:noUnderline];
    y -= 26;

    NSButton *fullbox = [NSButton checkboxWithTitle:[loc translate:@"Enable fullbox mode"]
                                             target:self action:@selector(prefChanged:)];
    fullbox.frame = NSMakeRect(230, y, 240, 20);
    fullbox.state = [ud boolForKey:kPrefClickableLinkFullBox] ? NSControlStateValueOn : NSControlStateValueOff;
    fullbox.tag = 1602;
    fullbox.enabled = enabled;
    [v addSubview:fullbox];
    y -= 42;

    NSTextField *schemesLabel = [NSTextField labelWithString:[loc translate:@"URI customized schemes:"]];
    schemesLabel.frame = NSMakeRect(20, y, 400, 20);
    [v addSubview:schemesLabel];
    y -= 84;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, y, 480, 78)];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers   = YES;
    scroll.borderType           = NSBezelBorder;

    NSTextView *tv = [[NSTextView alloc] initWithFrame:scroll.contentView.bounds];
    tv.minSize = NSMakeSize(0, 78);
    tv.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    tv.verticallyResizable   = YES;
    tv.horizontallyResizable = NO;
    tv.autoresizingMask      = NSViewWidthSizable;
    tv.textContainer.widthTracksTextView = YES;
    tv.richText  = NO;
    tv.editable  = YES;
    tv.font      = [NSFont systemFontOfSize:12];
    tv.string    = [ud stringForKey:kPrefClickableLinkSchemes] ?: @"";
    tv.delegate  = self;
    scroll.documentView = tv;
    [v addSubview:scroll];
    _clickableSchemesTextView = tv;

    return v;
}

#pragma mark - Performance Page

// Phase 1 of huge-file support — mirrors the Windows NPP "Performance" pane.
// All controls are gated by the master "Enable Large File Restriction" toggle:
// when off, the threshold and feature toggles below are inactive and files of
// any size open with full features. When on, files larger than the threshold
// enter "large file mode": syntax + undo are off (existing behavior in
// EditorView.loadFileAtPath:) and the Allow* toggles decide which other
// features remain active.
- (NSView *)_buildPerformancePage {
    NSView *v = [[NSView alloc] init];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NppLocalizer *loc = [NppLocalizer shared];
    CGFloat y = 380;

    NSTextField *header = [NSTextField labelWithString:[loc translate:@"Large File Restriction"]];
    header.frame = NSMakeRect(20, y, 400, 20);
    header.font = [NSFont boldSystemFontOfSize:13];
    [v addSubview:header];
    y -= 30;

    NSButton *enable = [NSButton checkboxWithTitle:[loc translate:@"Enable Large File Restriction (no syntax highlighting)"]
                                            target:self action:@selector(prefChanged:)];
    enable.frame = NSMakeRect(20, y, 480, 20);
    enable.state = [ud boolForKey:kPrefLargeFileEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    enable.tag = 1400;
    [v addSubview:enable];
    y -= 30;

    NSTextField *sizeLabel = [NSTextField labelWithString:[loc translate:@"Define Large File Size:"]];
    sizeLabel.frame = NSMakeRect(40, y, 180, 20);
    [v addSubview:sizeLabel];

    NSTextField *sizeField = [[NSTextField alloc] initWithFrame:NSMakeRect(225, y-2, 70, 22)];
    sizeField.integerValue = [ud integerForKey:kPrefLargeFileSizeMB];
    sizeField.tag = 1401; sizeField.target = self; sizeField.action = @selector(prefChanged:);
    [v addSubview:sizeField];

    NSTextField *sizeUnit = [NSTextField labelWithString:@"MB    (1 - 2046)"];
    sizeUnit.frame = NSMakeRect(305, y, 200, 20);
    [v addSubview:sizeUnit];
    y -= 36;

    NSArray *checks = @[
        @[[loc translate:@"Deactivate Word Wrap globally"],   @1402, kPrefLargeFileNoWrap],
        @[[loc translate:@"Allow Auto-Completion"],           @1403, kPrefLargeFileAllowAutoComplete],
        @[[loc translate:@"Allow Smart Highlighting"],        @1404, kPrefLargeFileAllowSmartHilite],
        @[[loc translate:@"Allow Brace Match"],               @1405, kPrefLargeFileAllowBraceMatch],
        @[[loc translate:@"Allow URL Clickable Link"],        @1406, kPrefLargeFileAllowURLClick],
    ];
    for (NSArray *def in checks) {
        NSButton *chk = [NSButton checkboxWithTitle:def[0] target:self action:@selector(prefChanged:)];
        chk.frame = NSMakeRect(40, y, 460, 20);
        chk.state = [ud boolForKey:def[2]] ? NSControlStateValueOn : NSControlStateValueOff;
        chk.tag = [def[1] integerValue];
        [v addSubview:chk];
        y -= 28;
    }
    y -= 12;

    NSButton *suppress = [NSButton checkboxWithTitle:[loc translate:@"Suppress warning when opening ≥2GB files"]
                                              target:self action:@selector(prefChanged:)];
    suppress.frame = NSMakeRect(20, y, 460, 20);
    suppress.state = [ud boolForKey:kPrefLargeFileSuppress2GBWarning] ? NSControlStateValueOn : NSControlStateValueOff;
    suppress.tag = 1407;
    [v addSubview:suppress];

    return v;
}

#pragma mark - Delimiter Page

// Mirrors Windows NPP "Delimiter" pane (issue #42). Two independent features
// share this page in the Windows UI; we preserve that grouping.
//   • Word character list — extends Scintilla's word set so double-click
//     selects e.g. "192.168.1.1" as a whole (when "." is in the added chars).
//   • Delimiter selection settings — ⌘+double-click selects everything
//     between configured Open / Close characters. Single line by default;
//     "Allow on several lines" expands to entire-document scan.
//
// macOS modifier note: ScintillaCocoa's TranslateModifierFlags swaps Cmd↔Ctrl
// so the Windows code path (modifiers == SCMOD_CTRL) actually triggers on
// ⌘ on this platform. The Preferences label reflects that.
- (NSView *)_buildDelimiterPage {
    NSView *v = [[NSView alloc] init];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NppLocalizer *loc = [NppLocalizer shared];
    CGFloat y = 380;

    // ── Word character list ───────────────────────────────────────────────────
    NSTextField *wclHeader = [NSTextField labelWithString:[loc translate:@"Word character list"]];
    wclHeader.frame = NSMakeRect(20, y, 400, 20);
    wclHeader.font = [NSFont boldSystemFontOfSize:13];
    [v addSubview:wclHeader];
    y -= 30;

    BOOL useDefault = [ud boolForKey:kPrefWordCharsUseDefault];

    NSButton *radioDefault = [NSButton radioButtonWithTitle:
        [loc translate:@"Use default Word character list as it is"]
                                                    target:self action:@selector(prefChanged:)];
    radioDefault.frame = NSMakeRect(40, y, 460, 20);
    radioDefault.state = useDefault ? NSControlStateValueOn : NSControlStateValueOff;
    radioDefault.tag = 1500;
    [v addSubview:radioDefault];
    y -= 26;

    NSButton *radioCustom = [NSButton radioButtonWithTitle:
        [loc translate:@"Add your character as part of word"]
                                                   target:self action:@selector(prefChanged:)];
    radioCustom.frame = NSMakeRect(40, y, 460, 20);
    radioCustom.state = useDefault ? NSControlStateValueOff : NSControlStateValueOn;
    radioCustom.tag = 1501;
    [v addSubview:radioCustom];
    y -= 22;

    NSTextField *radioHint = [NSTextField labelWithString:
        [loc translate:@"(don't choose it unless you know what you're doing)"]];
    radioHint.frame = NSMakeRect(58, y, 460, 16);
    radioHint.font = [NSFont systemFontOfSize:10];
    radioHint.textColor = [NSColor secondaryLabelColor];
    [v addSubview:radioHint];
    y -= 24;

    NSTextField *charsField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(58, y - 2, 420, 22)];
    charsField.stringValue = [ud stringForKey:kPrefWordCharsAdded] ?: @"";
    charsField.placeholderString = @"e.g. .$%-";
    charsField.tag = 1502;
    charsField.target = self;
    charsField.action = @selector(prefChanged:);
    charsField.enabled = !useDefault;
    [v addSubview:charsField];
    _delimWordCharsField = charsField;  // cached for the radio toggle to re-enable
    y -= 42;

    // ── Delimiter selection settings ──────────────────────────────────────────
    NSTextField *delHeader = [NSTextField labelWithString:
        [loc translate:@"Delimiter selection settings (⌘ + Mouse double click)"]];
    delHeader.frame = NSMakeRect(20, y, 460, 20);
    delHeader.font = [NSFont boldSystemFontOfSize:13];
    [v addSubview:delHeader];
    y -= 32;

    // Inline row: "Open"  [(]  bla bla bla bla bla  [)]  "Close"
    NSTextField *openLabel = [NSTextField labelWithString:[loc translate:@"Open"]];
    openLabel.frame = NSMakeRect(40, y, 50, 20);
    [v addSubview:openLabel];

    NSTextField *openerField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(85, y - 2, 32, 22)];
    openerField.stringValue = [ud stringForKey:kPrefDelimOpen] ?: @"(";
    openerField.alignment = NSTextAlignmentCenter;
    openerField.tag = 1503;
    openerField.target = self;
    openerField.action = @selector(prefChanged:);
    [v addSubview:openerField];

    NSTextField *previewLabel = [NSTextField labelWithString:@"bla bla bla bla bla"];
    previewLabel.frame = NSMakeRect(125, y, 130, 20);
    previewLabel.textColor = [NSColor secondaryLabelColor];
    [v addSubview:previewLabel];

    NSTextField *closerField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(260, y - 2, 32, 22)];
    closerField.stringValue = [ud stringForKey:kPrefDelimClose] ?: @")";
    closerField.alignment = NSTextAlignmentCenter;
    closerField.tag = 1504;
    closerField.target = self;
    closerField.action = @selector(prefChanged:);
    [v addSubview:closerField];

    NSTextField *closeLabel = [NSTextField labelWithString:[loc translate:@"Close"]];
    closeLabel.frame = NSMakeRect(300, y, 50, 20);
    [v addSubview:closeLabel];
    y -= 36;

    NSButton *allowMulti = [NSButton checkboxWithTitle:
        [loc translate:@"Allow on several lines"]
                                                target:self action:@selector(prefChanged:)];
    allowMulti.frame = NSMakeRect(40, y, 300, 20);
    allowMulti.state = [ud boolForKey:kPrefDelimEntireDoc] ? NSControlStateValueOn : NSControlStateValueOff;
    allowMulti.tag = 1505;
    [v addSubview:allowMulti];

    return v;
}

#pragma mark - MISC. Page

- (NSView *)_buildMiscPage {
    NSView *v = [[NSView alloc] init];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    CGFloat y = 380;
    NppLocalizer *loc = [NppLocalizer shared];

    NSArray *checks = @[
        @[[loc translate:@"Mute all sounds"],                          @1200, kPrefMuteSounds],
        @[[loc translate:@"Confirm before Save All"],                  @1201, kPrefSaveAllConfirm],
        @[[loc translate:@"Reverse default date/time order"],          @1202, kPrefDateTimeReverse],
        @[[loc translate:@"Keep absent file entries in session"],      @1203, kPrefKeepAbsentSession],
        @[[loc translate:@"Remember panel visibility across sessions"], @1204, kPrefPanelKeepState],
        @[[loc translate:@"Use XML-based function list parsers"],      @1205, kPrefFuncListUseXML],
        @[@"Route plugin messages to split view editors",            @1206, kPrefPluginSplitViewRouting],
        @[[loc translate:@"File Status Auto-Detection"],              @1208, kPrefFileStatusAutoDetection],
        @[[loc translate:@"Update silently"],                         @1209, kPrefFileStatusUpdateSilently],
    ];
    for (NSArray *def in checks) {
        NSButton *chk = [NSButton checkboxWithTitle:def[0] target:self action:@selector(prefChanged:)];
        chk.frame = NSMakeRect(20, y, 400, 20);
        chk.state = [ud boolForKey:def[2]] ? NSControlStateValueOn : NSControlStateValueOff;
        chk.tag = [def[1] integerValue];
        [v addSubview:chk];
        y -= 28;
    }

    // "Update silently" only applies while auto-detection is on — grey it out
    // when the parent is off (matches Windows' sub-option behavior).
    [(NSButton *)[v viewWithTag:1209]
        setEnabled:[ud boolForKey:kPrefFileStatusAutoDetection]];

    // ── Toolbar icon size dropdown ─────────────────────────────────────────────
    // Restart-required (per design — toolbar metrics are cached on first use
    // via dispatch_once in MainWindowController). On change, we persist the
    // value and surface a one-time "takes effect after restart" alert so the
    // user isn't left wondering why the toolbar didn't change immediately.
    y -= 8;  // small extra gap before non-checkbox control
    NSTextField *scaleLabel = [NSTextField labelWithString:[loc translate:@"Toolbar icon size"]];
    scaleLabel.frame = NSMakeRect(20, y, 200, 20);
    [v addSubview:scaleLabel];

    NSPopUpButton *scalePopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(220, y - 3, 130, 26) pullsDown:NO];
    [scalePopup addItemsWithTitles:@[@"50%", @"75%", @"90%",
                                     [loc translate:@"100% (Default)"],
                                     @"125%", @"150%"]];
    scalePopup.target = self;
    scalePopup.action = @selector(prefChanged:);
    scalePopup.tag    = 1207;
    // Map the persisted scale → selected index. Round-tripping `pickScales`
    // here (instead of reading a separate stored index) keeps the dropdown
    // state authoritatively derived from the same scale value the toolbar
    // builder reads at startup.
    static const double pickScales[] = {0.50, 0.75, 0.90, 1.00, 1.25, 1.50};
    double currentScale = [ud doubleForKey:kPrefToolbarIconScale];
    NSInteger pickIdx = 3;  // default: 100 %
    for (NSInteger i = 0; i < 6; i++) {
        if (fabs(currentScale - pickScales[i]) < 1e-6) { pickIdx = i; break; }
    }
    [scalePopup selectItemAtIndex:pickIdx];
    [v addSubview:scalePopup];
    y -= 28;

    // ── Mouse wheel scroll speed ───────────────────────────────────────────────
    // Non-linear acceleration for discrete (clicky) mouse wheels: spinning faster
    // scrolls proportionally more, up to this multiplier at full speed. 1× (off)
    // is the default and leaves scrolling exactly as it was. Read live by
    // ScintillaView on each wheel event — no restart needed.
    y -= 8;
    NSTextField *wheelLabel = [NSTextField labelWithString:[loc translate:@"Mouse wheel scroll speed"]];
    wheelLabel.frame = NSMakeRect(20, y, 200, 20);
    [v addSubview:wheelLabel];

    NSPopUpButton *wheelPopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(220, y - 3, 130, 26) pullsDown:NO];
    [wheelPopup addItemsWithTitles:@[[loc translate:@"1× (off)"], @"2×", @"3×", @"5×", @"8×", @"10×"]];
    wheelPopup.target = self;
    wheelPopup.action = @selector(prefChanged:);
    wheelPopup.tag    = 1210;
    static const double wheelGains[] = {1.0, 2.0, 3.0, 5.0, 8.0, 10.0};
    double curGain = [ud doubleForKey:kPrefScrollSpeedGain];
    NSInteger gainIdx = 0;
    for (NSInteger i = 0; i < 6; i++) {
        if (fabs(curGain - wheelGains[i]) < 1e-6) { gainIdx = i; break; }
    }
    [wheelPopup selectItemAtIndex:gainIdx];
    [v addSubview:wheelPopup];
    y -= 28;

    return v;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Language Popup Helper
// ═══════════════════════════════════════════════════════════════════════════════

- (void)_rebuildLanguagePopup {
    if (!_languagePopup) return;

    NSDictionary<NSString *, NSString *> *langMap = [NppLocalizer availableLanguagesMap];
    NSArray<NSString *> *names = [[langMap allKeys]
        sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    [_languagePopup removeAllItems];
    [_languagePopup addItemsWithTitles:names];

    NSString *currentFile = [NppLocalizer shared].currentLanguageFile;
    for (NSString *name in names) {
        if ([langMap[name].lowercaseString isEqualToString:currentFile.lowercaseString]) {
            [_languagePopup selectItemWithTitle:name];
            break;
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Actions
// ═══════════════════════════════════════════════════════════════════════════════

- (void)prefChanged:(id)sender {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSInteger tag = [(NSControl *)sender tag];

    switch (tag) {
        case 100: {
            if (_indentSelectedLang == nil) {
                [ud setInteger:[(NSTextField *)sender integerValue] forKey:kPrefTabWidth];
            } else {
                [self _saveIndentOverrideFromBox:[(NSTextField *)sender superview]];
            }
            break;
        }
        case 103: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefShowLineNumbers]; break;
        case 104: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefWordWrap]; break;
        case 105: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefHighlightCurrentLine]; break;
        case 200: [ud setInteger:[(NSPopUpButton *)sender indexOfSelectedItem] forKey:kPrefEOLType]; break;
        case 201: [ud setInteger:[(NSPopUpButton *)sender indexOfSelectedItem] forKey:kPrefEncoding]; break;
        case 300: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefAutoBackup]; break;
        case 301: [ud setInteger:[(NSTextField *)sender integerValue] forKey:kPrefBackupInterval]; break;
        case 302: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefRememberSession]; break;
        case 400: {
            NSPopUpButton *popup = (NSPopUpButton *)sender;
            NSString *selectedName = popup.selectedItem.title;
            if (selectedName.length > 0) {
                NSDictionary *langMap = [NppLocalizer availableLanguagesMap];
                NSString *stem = langMap[selectedName];
                if (stem) {
                    [[NppLocalizer shared] loadLanguageNamed:stem];
                }
            }
            return;
        }
        case 600: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefAutoCompleteEnable]; break;
        case 601: [ud setInteger:[(NSTextField *)sender integerValue] forKey:kPrefAutoCompleteMinChars]; break;
        case 602: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefFuncParamsHint]; break;
        // Editor settings
        case 700: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefAutoCloseBrackets]; break;
        case 701: [ud setInteger:[(NSPopUpButton *)sender indexOfSelectedItem] + 1 forKey:kPrefCaretWidth]; break;
        case 702: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefVirtualSpace]; break;
        case 703: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefScrollBeyondLastLine]; break;
        case 704: [ud setInteger:[(NSTextField *)sender integerValue] forKey:kPrefCaretBlinkRate]; break;
        case 705: [ud setInteger:[(NSPopUpButton *)sender indexOfSelectedItem] forKey:kPrefFontQuality]; break;
        case 706: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefCopyLineNoSelection]; break;
        // Tab Bar settings
        case 800: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefTabCloseButton]; break;
        case 801: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefDoubleClickTabClose]; break;
        case 802: [ud setInteger:[(NSTextField *)sender integerValue] forKey:kPrefTabMaxLabelWidth]; break;
        case 803: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefTabBarWrap]; break;
        case 804: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefHideTabBar]; break;
        // General
        case 900: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefShowFullPathInTitle]; break;
        // Searching
        case 1000: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefSmartHighlight]; break;
        case 1001: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefFillFindWithSelection]; break;
        case 1002: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefSmartHiliteCase]; break;
        case 1003: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefSmartHiliteWord]; break;
        case 1004: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefMonoFontFind]; break;
        case 1005: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefConfirmReplaceAll]; break;
        case 1006: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefReplaceAndStop]; break;
        case 1007: [ud setInteger:[(NSTextField *)sender integerValue] forKey:kPrefInSelThreshold]; break;
        case 1008: {
            BOOL on = [(NSButton *)sender state] == NSControlStateValueOn;
            [ud setBool:on forKey:kPrefUseBoostRegex];
            // New Documents (and any not-yet-searched ones) pick up the new engine
            // immediately; already-searched Documents keep their cached backend
            // until reopened — hence "restart to apply" in the label.
            gNppUseBoostRegex = on;
            break;
        }
        // General
        case 901: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefShowStatusBar]; break;
        case 902: {
            [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefDockPanelsOnLeft];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"NPPDockPanelsLeftChanged" object:nil];
            break;
        }
        case 903: {
            // Save the toolbar visibility state to preferences.
            BOOL hide = [(NSButton *)sender state] == NSControlStateValueOn;
            [ud setBool:!hide forKey:kPrefToolbarVisible];
            
            // Disable or enable the color options above the checkbox.
            [self _updateToolbarPageControlsEnabledState:[(NSButton *)sender superview] hidden:hide];
            
            // Tell the main window to update the toolbar visibility.
            [[NSNotificationCenter defaultCenter] postNotificationName:@"NPPToolbarVisibilityChanged" object:nil];
            break;
        }
        // Editor
        case 707: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefRightClickKeepsSel]; break;
        case 708: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefDisableTextDragDrop]; break;
        case 709: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefShowBookmarkMargin]; break;
        case 710: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefShowEOL]; break;
        case 711: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefShowWhitespace]; break;
        case 713: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefColumnSel2MultiEdit]; break;
        case 712: {  // Line spacing multiplier (issue #149)
            static const double kPresets[5] = {1.0, 1.2, 1.3, 1.4, 1.5};
            NSInteger idx = [(NSPopUpButton *)sender indexOfSelectedItem];
            if (idx < 0 || idx >= 5) idx = 0;
            [ud setDouble:kPresets[idx] forKey:kPrefLineHeightMultiplier];
            break;
        }
        // Margins
        case 1100: [ud setInteger:[(NSTextField *)sender integerValue] forKey:kPrefEdgeColumn]; break;
        case 1101: [ud setInteger:[(NSPopUpButton *)sender indexOfSelectedItem] forKey:kPrefEdgeMode]; break;
        case 1102: [ud setInteger:[(NSTextField *)sender integerValue] forKey:kPrefPaddingLeft]; break;
        case 1103: [ud setInteger:[(NSTextField *)sender integerValue] forKey:kPrefPaddingRight]; break;
        case 1104: [ud setInteger:[(NSPopUpButton *)sender indexOfSelectedItem] forKey:kPrefFoldStyle]; break;
        case 1105: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefLineNumDynWidth]; break;
        // MISC
        case 1200: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefMuteSounds]; break;
        case 1201: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefSaveAllConfirm]; break;
        case 1202: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefDateTimeReverse]; break;
        case 1203: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefKeepAbsentSession]; break;
        case 1204: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefPanelKeepState]; break;
        case 1205: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefFuncListUseXML]; break;
        case 1206: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefPluginSplitViewRouting]; break;
        case 1208: {  // File Status Auto-Detection
            BOOL on = [(NSButton *)sender state] == NSControlStateValueOn;
            [ud setBool:on forKey:kPrefFileStatusAutoDetection];
            // Enable/disable the dependent "Update silently" checkbox.
            [(NSButton *)[[(NSButton *)sender superview] viewWithTag:1209] setEnabled:on];
            break;
        }
        case 1209: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefFileStatusUpdateSilently]; break;
        case 1210: {
            // Mouse wheel scroll speed (gain). Read live by ScintillaView on each
            // wheel event, so no notification or restart is needed.
            static const double gains[6] = {1.0, 2.0, 3.0, 5.0, 8.0, 10.0};
            NSInteger idx = [(NSPopUpButton *)sender indexOfSelectedItem];
            if (idx < 0 || idx >= 6) break;
            [ud setDouble:gains[idx] forKey:kPrefScrollSpeedGain];
            break;
        }
        // Performance / Large File Restriction (1400-1407 — 1300s collide with Indentation)
        case 1400: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefLargeFileEnabled]; break;
        case 1401: {
            // Clamp threshold to the valid 1–2046 MB range so users can't store
            // a nonsensical value via the text field.
            NSInteger mb = [(NSTextField *)sender integerValue];
            if (mb < 1)    mb = 1;
            if (mb > 2046) mb = 2046;
            [ud setInteger:mb forKey:kPrefLargeFileSizeMB];
            [(NSTextField *)sender setIntegerValue:mb];  // reflect clamp in UI
            break;
        }
        case 1402: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefLargeFileNoWrap]; break;
        case 1403: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefLargeFileAllowAutoComplete]; break;
        case 1404: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefLargeFileAllowSmartHilite]; break;
        case 1405: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefLargeFileAllowBraceMatch]; break;
        case 1406: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefLargeFileAllowURLClick]; break;
        case 1407: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefLargeFileSuppress2GBWarning]; break;
        case 1207: {
            // Toolbar icon scale — restart required.
            static const double scales[6] = {0.50, 0.75, 0.90, 1.00, 1.25, 1.50};
            NSInteger idx = [(NSPopUpButton *)sender indexOfSelectedItem];
            if (idx < 0 || idx >= 6) break;
            double newScale = scales[idx];
            double oldScale = [ud doubleForKey:kPrefToolbarIconScale];
            // Only persist + alert if the value actually changed; selecting
            // the already-active item should be silent.
            if (fabs(newScale - oldScale) < 1e-6) break;
            [ud setDouble:newScale forKey:kPrefToolbarIconScale];
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = [[NppLocalizer shared] translate:@"Toolbar icon size changed"];
            alert.informativeText = [[NppLocalizer shared] translate:
                @"The new toolbar icon size will take effect the next time Nextpad++ launches."];
            [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"OK"]];
            [alert runModal];
            break;
        }
        // Indentation
        case 1303: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefBackspaceUnindent]; break;
        // Delimiter pane (issue #42) — 1500-1505
        case 1500: {  // "Use default" radio
            [ud setBool:YES forKey:kPrefWordCharsUseDefault];
            // Pair: deselect the other radio + disable the custom-chars field
            NSView *page = [(NSButton *)sender superview];
            NSButton *other = [page viewWithTag:1501];
            other.state = NSControlStateValueOff;
            _delimWordCharsField.enabled = NO;
            break;
        }
        case 1501: {  // "Add your character" radio
            [ud setBool:NO forKey:kPrefWordCharsUseDefault];
            NSView *page = [(NSButton *)sender superview];
            NSButton *other = [page viewWithTag:1500];
            other.state = NSControlStateValueOff;
            _delimWordCharsField.enabled = YES;
            break;
        }
        case 1502:    // Custom word chars text field
            [ud setObject:[(NSTextField *)sender stringValue] forKey:kPrefWordCharsAdded];
            break;
        case 1503: {  // Open delimiter — clamp to 1 char
            NSString *s = [(NSTextField *)sender stringValue];
            NSString *one = s.length > 0 ? [s substringToIndex:1] : @"(";
            [ud setObject:one forKey:kPrefDelimOpen];
            [(NSTextField *)sender setStringValue:one]; // reflect clamp in UI
            break;
        }
        case 1504: {  // Close delimiter — clamp to 1 char
            NSString *s = [(NSTextField *)sender stringValue];
            NSString *one = s.length > 0 ? [s substringToIndex:1] : @")";
            [ud setObject:one forKey:kPrefDelimClose];
            [(NSTextField *)sender setStringValue:one];
            break;
        }
        case 1505:    // Allow on several lines
            [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefDelimEntireDoc];
            break;
        // Cloud & Link — Clickable Link Settings (1600-1602; schemes text view
        // persists via textDidChange:)
        case 1600: {  // Enable
            BOOL on = [(NSButton *)sender state] == NSControlStateValueOn;
            [ud setBool:on forKey:kPrefClickableLinkEnable];
            // Mirror Windows: the style sub-options are only meaningful when enabled.
            NSView *page = [(NSButton *)sender superview];
            [(NSButton *)[page viewWithTag:1601] setEnabled:on];
            [(NSButton *)[page viewWithTag:1602] setEnabled:on];
            break;
        }
        case 1601: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefClickableLinkNoUnderline]; break;
        case 1602: [ud setBool:[(NSButton *)sender state] == NSControlStateValueOn forKey:kPrefClickableLinkFullBox]; break;
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:@"NPPPreferencesChanged" object:nil];
}

- (void)closePrefs:(id)sender {
    [self _saveClickableSchemes];
    [self.window makeFirstResponder:nil]; // commit any in-progress text field edits
    [self.window orderOut:nil];
}

#pragma mark - NSTextViewDelegate

- (void)textDidChange:(NSNotification *)notification {
    if (notification.object == _clickableSchemesTextView)
        [self _saveClickableSchemes];
}

- (void)_saveClickableSchemes {
    if (!_clickableSchemesTextView) return;
    [[NSUserDefaults standardUserDefaults] setObject:(_clickableSchemesTextView.string ?: @"")
                                              forKey:kPrefClickableLinkSchemes];
}

@end
