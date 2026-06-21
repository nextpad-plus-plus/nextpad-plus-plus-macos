#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// NSUserDefaults keys (exported so EditorView can read them)
extern NSString *const kPrefTabWidth;
extern NSString *const kPrefUseTabs;
extern NSString *const kPrefAutoIndent;          // NSInteger 0=None 1=Advanced 2=Basic
extern NSString *const kPrefBackspaceUnindent;   // BOOL, default NO
extern NSString *const kPrefTabOverrides;        // NSDictionary<langName, @{@"tabSize":@N, @"useTabs":@BOOL}>
extern NSString *const kPrefShowLineNumbers;
extern NSString *const kPrefShowIndentGuides;    // BOOL, default YES
/// Word wrap. Persistent across launches (default NO).
/// Three UI surfaces all read/write this key: the Preferences > Editor
/// "Word wrap" checkbox, the View > Word Wrap menu item, and the toolbar
/// Word Wrap button. Each writes the new state to kPrefWordWrap; toolbar/
/// menu also propagates to every open editor across all open windows via
/// NPPWordWrapSessionChanged broadcast (so a click universalizes the
/// state mid-session). New tabs inherit the saved state via
/// EditorView.applyPreferencesFromDefaults reading this key on init.
/// RTL editors are skipped from the OFF path (they require wrap on for
/// layout — see EditorView.setTextDirectionRTL: + _savedWrapBeforeRTL).
extern NSString *const kPrefWordWrap;
extern NSString *const kPrefHighlightCurrentLine;
extern NSString *const kPrefEOLType;
extern NSString *const kPrefEncoding;
extern NSString *const kPrefAutoBackup;
extern NSString *const kPrefBackupInterval;
extern NSString *const kPrefRememberSession;     // BOOL, default YES — when off, app starts with a clean editor on each launch (issue #87)
extern NSString *const kPrefZoomLevel;
extern NSString *const kPrefSpellCheck;          // BOOL, default NO
extern NSString *const kPrefAutoCompleteEnable;  // BOOL, default YES
extern NSString *const kPrefAutoCompleteMinChars;// NSInteger 1-9, default 1
extern NSString *const kPrefAutoCloseBrackets;   // BOOL, default YES
extern NSString *const kPrefShowFullPathInTitle; // BOOL, default YES
// Toolbar icon colorization (issue: Windows "Toolbar" prefs parity)
extern NSString *const kPrefToolbarColorMode;    // 0=Off, 1=Partial(hue rotate), 2=Complete(mono fill). default 0
extern NSString *const kPrefToolbarColorChoice;  // 0=Red 1=Green 2=Blue 3=Purple 4=Cyan 5=Olive 6=Yellow 7=Accent 8=Custom. default 2
extern NSString *const kPrefToolbarCustomColor;  // NSData (archived NSColor), used when choice==8
extern NSString *const kPrefToolbarColorPlugins; // BOOL — also colorize plugin toolbar icons. default NO
extern NSString *const kPrefCaretWidth;          // NSInteger 1-3, default 1
extern NSString *const kPrefTabMaxLabelWidth;    // NSInteger pixels, default 190
extern NSString *const kPrefTabCloseButton;      // BOOL, default YES
extern NSString *const kPrefDoubleClickTabClose; // BOOL, default NO
extern NSString *const kPrefTabBarWrap;          // BOOL, default NO
extern NSString *const kPrefHideTabBar;          // BOOL, default NO — hide the tab bar entirely
extern NSString *const kPrefVirtualSpace;        // BOOL, default NO
extern NSString *const kPrefColumnSel2MultiEdit; // BOOL, default YES — column selection becomes multi-edit on Backspace/arrows
extern NSString *const kPrefScrollBeyondLastLine;// BOOL, default NO
extern NSString *const kPrefScrollSpeedGain;     // double, default 1.0 (1.0 = no mouse-wheel acceleration)
extern NSString *const kPrefCaretBlinkRate;      // NSInteger ms, default 500
extern NSString *const kPrefFontQuality;         // NSInteger 0-3, default 3 (LCD)
extern NSString *const kPrefLineHeightMultiplier;// double, default 1.0; presets 1.0/1.2/1.3/1.4/1.5 (issue #149)
// Global override — force attributes from Default Style across every style ID
// (Windows: <GUIConfig name="globalOverride" .../>; see Parameters.cpp:6156).
extern NSString *const kPrefGlobalOverrideEnableFg;       // BOOL, default NO
extern NSString *const kPrefGlobalOverrideEnableBg;       // BOOL, default NO
extern NSString *const kPrefGlobalOverrideEnableFont;     // BOOL, default NO
extern NSString *const kPrefGlobalOverrideEnableFontSize; // BOOL, default NO
extern NSString *const kPrefGlobalOverrideEnableBold;     // BOOL, default NO
extern NSString *const kPrefGlobalOverrideEnableItalic;   // BOOL, default NO
extern NSString *const kPrefGlobalOverrideEnableUnderline;// BOOL, default NO
extern NSString *const kPrefCopyLineNoSelection; // BOOL, default YES
extern NSString *const kPrefSmartHighlight;      // BOOL, default YES
extern NSString *const kPrefFillFindWithSelection;// BOOL, default YES
extern NSString *const kPrefFuncParamsHint;      // BOOL, default NO
// Find window transparency (issue #143 — Windows "Transparency" parity).
// The control lives in the Find/Replace tabs of FindWindow, not this prefs pane.
extern NSString *const kPrefFindTransparencyEnabled; // BOOL, default YES
extern NSString *const kPrefFindTransparencyMode;    // NSInteger 0=on losing focus, 1=always
extern NSString *const kPrefFindTransparencyAlpha;   // double 0.2–0.9, default 0.5
// Clickable links (issue #133 — Windows "Cloud & Link" parity). These persist
// the setting; the link detection/highlight/open behavior is wired separately.
extern NSString *const kPrefClickableLinkEnable;     // BOOL, default YES
extern NSString *const kPrefClickableLinkNoUnderline;// BOOL, default NO
extern NSString *const kPrefClickableLinkFullBox;    // BOOL, default NO — box hover style vs underline
extern NSString *const kPrefClickableLinkSchemes;    // NSString — space-separated URI schemes
// Tier 1 booleans
extern NSString *const kPrefShowStatusBar;       // BOOL, default YES
extern NSString *const kPrefToolbarVisible;      // BOOL, default YES
extern NSString *const kPrefDockPanelsOnLeft;    // BOOL, default NO
extern NSString *const kPrefSidePanelWidth;      // double, default 280
extern NSString *const kPrefMuteSounds;          // BOOL, default NO
extern NSString *const kPrefSaveAllConfirm;      // BOOL, default NO
extern NSString *const kPrefPluginSplitViewRouting; // BOOL, default YES — route plugin SCI messages to split view
extern NSString *const kPrefRightClickKeepsSel;  // BOOL, default NO
extern NSString *const kPrefDisableTextDragDrop; // BOOL, default NO
extern NSString *const kPrefMonoFontFind;        // BOOL, default NO
extern NSString *const kPrefConfirmReplaceAll;   // BOOL, default YES
extern NSString *const kPrefReplaceAndStop;      // BOOL, default NO
extern NSString *const kPrefUseBoostRegex;       // BOOL, default NO (opt-in Boost.Regex backend)
extern NSString *const kPrefSmartHiliteCase;     // BOOL, default NO
extern NSString *const kPrefSmartHiliteWord;     // BOOL, default NO
extern NSString *const kPrefDateTimeReverse;     // BOOL, default NO
extern NSString *const kPrefKeepAbsentSession;   // BOOL, default NO
extern NSString *const kPrefShowBookmarkMargin;  // BOOL, default YES
extern NSString *const kPrefShowEOL;             // BOOL, default NO
extern NSString *const kPrefShowWhitespace;      // BOOL, default NO
// Tier 2
extern NSString *const kPrefEdgeColumn;          // NSInteger, default 0 (0=off)
extern NSString *const kPrefEdgeMode;            // NSInteger, 0=off 1=line 2=background
extern NSString *const kPrefPaddingLeft;         // NSInteger, 0-30, default 0
extern NSString *const kPrefPaddingRight;        // NSInteger, 0-30, default 0
extern NSString *const kPrefPanelKeepState;      // BOOL, default YES
extern NSString *const kPrefFoldStyle;           // NSInteger, 0=box 1=circle 2=arrow 3=simple 4=none
extern NSString *const kPrefLineNumDynWidth;     // BOOL, default YES
extern NSString *const kPrefInSelThreshold;      // NSInteger, default 1024
extern NSString *const kPrefFuncListUseXML;      // BOOL, default YES — use XML parsers vs hardcoded regex
extern NSString *const kPrefToolbarIconScale;    // double, 0.50/0.75/0.90/1.00/1.25/1.50, default 1.0 — restart required
// File status auto-detection (PR #116 — Windows MISC parity)
extern NSString *const kPrefFileStatusAutoDetection;  // BOOL, default YES — detect external on-disk changes
extern NSString *const kPrefFileStatusUpdateSilently; // BOOL, default NO — auto-reload clean buffers (dirty still prompt)

// Delimiter pane (issue #42) — two independent features sharing one prefs page,
// mirroring Windows NPP. (1) "Word character list" extends Scintilla's word
// set so double-click selects e.g. an IP address as a whole. (2) "Delimiter
// selection settings" lets ⌘+double-click select text between configured
// open/close characters (single line, or entire document if AllowSeveralLines).
extern NSString *const kPrefWordCharsUseDefault; // BOOL, default YES
extern NSString *const kPrefWordCharsAdded;      // NSString, default @"" — ASCII chars added to word set
extern NSString *const kPrefDelimOpen;           // NSString, single char, default @"("
extern NSString *const kPrefDelimClose;          // NSString, single char, default @")"
extern NSString *const kPrefDelimEntireDoc;      // BOOL, default NO — Allow on several lines

// Performance / Large File Restriction (Phase 1 of huge-file support).
// Mirrors the Windows NPP "Performance" preferences pane. When a file size
// crosses kPrefLargeFileSizeMB AND kPrefLargeFileEnabled is YES, the editor
// enters "large file mode": syntax highlighting + undo are off (existing
// behavior) and the per-feature Allow* toggles below decide whether
// auto-complete, smart-highlight, brace-match, and URL-clickable still run.
extern NSString *const kPrefLargeFileEnabled;            // BOOL, default YES
extern NSString *const kPrefLargeFileSizeMB;             // NSInteger MB, 1–2046, default 200
extern NSString *const kPrefLargeFileNoWrap;             // BOOL, default YES — turn off word-wrap when large
extern NSString *const kPrefLargeFileAllowAutoComplete;  // BOOL, default NO  — keep autocomplete when large
extern NSString *const kPrefLargeFileAllowSmartHilite;   // BOOL, default NO  — keep smart highlight when large
extern NSString *const kPrefLargeFileAllowBraceMatch;    // BOOL, default NO  — keep brace match when large
extern NSString *const kPrefLargeFileAllowURLClick;      // BOOL, default NO  — keep URL hyperlinks when large
extern NSString *const kPrefLargeFileSuppress2GBWarning; // BOOL, default YES — skip warning above 2 GB

// Theme / Style Configurator keys (hex color strings "#RRGGBB")
extern NSString *const kPrefThemePreset;    // preset name or "Custom"
extern NSString *const kPrefStyleFg;        // default foreground
extern NSString *const kPrefStyleBg;        // default background
extern NSString *const kPrefStyleComment;
extern NSString *const kPrefStyleKeyword;
extern NSString *const kPrefStyleString;
extern NSString *const kPrefStyleNumber;
extern NSString *const kPrefStylePreproc;
extern NSString *const kPrefStyleFontName;  // e.g. "Menlo"
extern NSString *const kPrefStyleFontSize;  // integer stored as NSNumber

/// Modeless preferences window. Call +sharedController to get the singleton.
@interface PreferencesWindowController : NSWindowController

+ (instancetype)sharedController;

@end

NS_ASSUME_NONNULL_END
