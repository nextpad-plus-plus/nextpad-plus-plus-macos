#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class EditorView;
@class TabManager;

@interface MainWindowController : NSWindowController

/// Open a file (called by AppDelegate when the OS hands us a file to open).
- (void)openFileAtPath:(NSString *)path;

/// Bring the receiver's window to the user's attention: activate the app,
/// deminiaturize the window if it's currently in the Dock, and order it
/// front. Idempotent — safe to call when the window is already key/visible.
/// Used by AppDelegate's open-file delegate hooks so opening a file from
/// Finder while the window is minimized actually surfaces the window
/// instead of silently adding the file to a hidden tab (issue #63).
- (void)bringWindowForward;

/// The active editor in the currently focused pane (for plugin access).
- (nullable EditorView *)currentEditor;

/// Editor for a specific view: 0 = primary tab manager, 1 = secondary (vertical split).
/// Returns nil if the secondary view has no tabs.
- (nullable EditorView *)editorForPluginView:(int)viewId;

/// Load a session file (plist format with tabs array).
- (void)loadSessionFromPath:(NSString *)path;

/// Restore the last session from ~/Library/Application Support/Nextpad++/session.plist.
- (BOOL)restoreLastSession;

/// The receiver's tab managers: primary view plus the horizontal/vertical split
/// views, with nils omitted. Session saving walks every window's managers so a
/// tab living in a secondary window is neither dropped from session.plist nor
/// stripped of its backup file by the stale-backup prune.
- (NSArray<TabManager *> *)sessionTabManagers;

/// YES once the receiver's window has closed. A closed window's tabs are gone —
/// the user closed them — so they no longer contribute to the session. Tracked
/// explicitly rather than inferred from -[NSWindow isVisible], which is also NO
/// for a merely miniaturized window.
@property (nonatomic, readonly) BOOL windowHasClosed;

/// Write session.plist covering the tabs of EVERY open window, and prune backup
/// files no longer referenced by any of them.
///
/// This is app-scoped on purpose. session.plist and the backup directory are
/// single, shared resources, so a per-window save would write only the closing
/// window's tabs and then delete every other window's backups — losing the
/// unsaved contents of all other windows. Call this once per quit, before any
/// window is torn down.
- (void)saveSessionForAllWindows;

/// YES when the session should be persisted at all: the "Remember current
/// session for next launch" pref is on and -nosession was not passed (#87).
- (BOOL)sessionPersistenceEnabled;

/// Add a plugin-provided toolbar icon.  Called by NppPluginManager when a
/// plugin sends NPPM_ADDTOOLBARICON_FORDARKMODE.
///
/// The icon is resolved from disk at the current appearance and re-resolved
/// automatically on theme change. Each candidate filename is probed first
/// in `<pluginDir>/` and then in `<pluginDir>/resources/` — plugin root
/// takes precedence so existing layouts keep working untouched. Lookup
/// order (first hit wins):
///   1. Dark mode + iconHint   →  <base>_dark.<ext>
///   2.                        →  <iconHint>
///   3. Dark mode (no hint)    →  toolbar_dark.png
///   4.                        →  toolbar.png
///
/// `pluginDir` must be the absolute path of the plugin's installed directory.
/// `iconHint` may be nil/empty — in that case only steps 3+4 apply (the
/// "convention" path). `tooltip` becomes both the toolTip string and the
/// overflow-menu label.
- (void)addPluginToolbarIconForPluginDir:(NSString *)pluginDir
                                iconHint:(nullable NSString *)iconHint
                                 tooltip:(NSString *)tooltip
                                   cmdID:(int)cmdID;

/// Rebuild the Macro menu from shortcuts.xml (called after macro save/delete).
- (void)rebuildMacroMenu;

/// Build and apply the editor right-click context menu to all editors.
- (void)applyEditorContextMenuToAll;

/// Plugin panel docking — add `panel` to the side-panel host so it sits
/// alongside built-in panels (Document List, Function List, etc.).  Thin
/// forwarder to the private `_setPanelVisible:title:show:` — plugins call
/// this via the NPPM_DMM_SHOWPANEL message rather than directly.
- (void)showPluginPanel:(NSView *)panel withTitle:(NSString *)title;

/// Plugin panel docking — remove `panel` from the side-panel host.  Does
/// not release any strong reference the host holds on the view; the
/// NppPluginManager registry keeps the view alive until the plugin
/// unregisters it.
- (void)hidePluginPanel:(NSView *)panel;

/// Query whether a plugin panel is currently attached to the side-panel
/// host.  Returns NO for nil.
- (BOOL)isPluginPanelShown:(nullable NSView *)panel;

/// Re-open the built-in side panels that were open at last quit (issue
/// #132). Gated on the "Remember panel visibility" preference. Call once,
/// on the primary window only, after it has been shown.
- (void)restoreSidePanels;

@end

/// Write current NSUserDefaults preferences to ~/Library/Application Support/Nextpad++/config.xml.
void writeConfigXML(void);

/// Read ~/Library/Application Support/Nextpad++/config.xml and apply settings to NSUserDefaults.
void readConfigXML(void);

/// Regenerate toolbarButtonsConf_example.xml with current plugin entries.
void regenerateToolbarExample(void);

NS_ASSUME_NONNULL_END
