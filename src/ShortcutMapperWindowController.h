#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted when the user saves shortcut changes. MainWindowController should
/// refresh menu accelerators and Scintilla key bindings.
extern NSNotificationName const NPPShortcutsChangedNotification;

/// Install a shortcuts.xml key assignment on a menu item.
///
/// Shortcuts are stored Windows-style — a virtual-key code plus four modifier
/// flags — and have to be translated into the (keyEquivalent, modifierMask)
/// pair AppKit wants. Four places need that translation: the Shortcut Mapper,
/// which updates the live menus the moment the user saves; AppDelegate, which
/// replays the whole file at launch; and MainWindowController's macro and
/// Run-command menu rebuilds. They must agree, or a shortcut behaves
/// differently before and after a restart (issue #265) — so the mapping lives
/// here once rather than in four copies that drift apart.
///
/// Callers are responsible for the legacy `Ctrl=yes` with no `Cmd` attribute
/// fixup before calling; that concerns reading the file, not the key mapping.
///
/// A `keyCode` of 0 clears the item's shortcut.
void NppApplyShortcutToMenuItem(NSMenuItem *mi, NSUInteger keyCode,
                                BOOL hasCmd, BOOL hasCtrl, BOOL hasAlt, BOOL hasShift);

/// The 5 tabs of the Shortcut Mapper, matching Windows NPP.
typedef NS_ENUM(NSInteger, ShortcutMapperTab) {
    ShortcutMapperTabMainMenu = 0,
    ShortcutMapperTabMacros,
    ShortcutMapperTabRunCommands,
    ShortcutMapperTabPluginCommands,
    ShortcutMapperTabScintillaCommands,
};

/// Shortcut Mapper window — allows viewing and editing keyboard shortcuts
/// for all commands across 5 categories.
@interface ShortcutMapperWindowController : NSWindowController

/// Show the mapper, optionally opening a specific tab.
- (void)showWithTab:(ShortcutMapperTab)tab;

@end

NS_ASSUME_NONNULL_END
