#import <Cocoa/Cocoa.h>
#import "NppTabBar.h"

@class EditorView;
@class TabManager;

NS_ASSUME_NONNULL_BEGIN

/// NSView subclass used as the editor container; accepts file drag-and-drop.
@interface NppDropView : NSView
/// Called on the main thread with an array of dropped file paths.
@property (nonatomic, copy, nullable) void (^dropHandler)(NSArray<NSString *> *paths);
@end

@protocol TabManagerDelegate <NSObject>
- (void)tabManager:(id)tabManager didSelectEditor:(EditorView *)editor;
- (void)tabManager:(id)tabManager didCloseEditor:(EditorView *)editor;
@optional
/// Whether releasing `editor`'s dragged tab at `screenPoint`, away from every
/// tab bar, would do anything (only used to dim the dragged tab).
- (BOOL)tabManager:(TabManager *)tabManager canReleaseEditor:(EditorView *)editor
     atScreenPoint:(NSPoint)screenPoint copy:(BOOL)copy;
/// `editor`'s tab was dragged out and released away from every tab bar.
/// `copy` is YES when Option was held. Returns NO when nothing happened.
- (BOOL)tabManager:(TabManager *)tabManager releaseEditor:(EditorView *)editor
     atScreenPoint:(NSPoint)screenPoint copy:(BOOL)copy;
/// Whether this pane may be left with no tabs when its last one closes (the
/// owner then hides it). When NO or not implemented, a fresh untitled tab
/// replaces the closed one.
- (BOOL)tabManagerMayBecomeEmpty:(TabManager *)tabManager;
/// The pane's last tab was closed and the pane was left empty (see above).
/// Only a close sends this; -evictEditor: never does.
- (void)tabManagerDidBecomeEmpty:(TabManager *)tabManager;
/// `editor`'s tab was dropped on `target`'s tab bar (another split pane or
/// another window) at insertion slot `index`; cloned there when `copy`.
- (void)tabManager:(TabManager *)tabManager moveEditor:(EditorView *)editor
      toTabManager:(TabManager *)target atIndex:(NSInteger)index copy:(BOOL)copy;
@end

/// Manages the custom tab bar and the set of open editor views.
@interface TabManager : NSObject <NppTabBarDelegate>

@property (nonatomic, weak, nullable) id<TabManagerDelegate> delegate;
@property (nonatomic, readonly) NppTabBar *tabBar;      // the tab bar view
@property (nonatomic, readonly) NSView   *contentView;  // container for editor views
@property (nonatomic, readonly, nullable) EditorView *currentEditor;
@property (nonatomic, readonly) NSArray<EditorView *> *allEditors;

- (instancetype)init;

/// Add a new untitled tab and return its EditorView.
- (EditorView *)addNewTab;

/// Open a file in a new tab (or focus existing tab if already open).
- (nullable EditorView *)openFileAtPath:(NSString *)path;

/// Close the currently active tab.
- (void)closeCurrentTab;

/// Close a specific editor tab.
- (void)closeEditor:(EditorView *)editor;

/// Close a specific editor tab WITHOUT any save prompt. The caller is
/// responsible for having already handled unsaved changes. Keeps at least one
/// tab open (opens a fresh untitled tab if this was the last one).
- (void)removeEditor:(EditorView *)editor;

/// Remove an editor from this manager without any save prompt or deallocation.
/// The EditorView stays alive; caller is responsible for adopting it elsewhere.
/// Selection stays on the current tab unless it was the one removed. Unlike
/// -removeEditor:, this may leave the manager with no tabs.
- (void)evictEditor:(EditorView *)editor;

/// Insert an existing, already-initialized EditorView into this manager as a new tab.
- (void)adoptEditor:(EditorView *)editor;

/// As -adoptEditor:, inserting the tab at `index` (clamped to 0…count) and
/// selecting it.
- (void)adoptEditor:(EditorView *)editor atIndex:(NSInteger)index;

/// Notify tab bar that the current editor's modified state changed.
- (void)refreshCurrentTabTitle;

/// Refresh all tab titles and modified icons (e.g. after Save All).
- (void)refreshAllTabTitles;

/// Refresh the tab showing `editor`, wherever it sits in this manager. Does
/// nothing if this manager does not own it, so a caller can offer the same
/// editor to every manager and let the owner respond.
- (void)refreshTitleForEditor:(EditorView *)editor;

/// Select tab by index programmatically (fires delegate).
- (void)selectTabAtIndex:(NSInteger)index;

/// Swap two tabs by index. The selection follows the tab that was selected.
- (void)swapEditorAtIndex:(NSInteger)a withIndex:(NSInteger)b;

/// Reorder tabs to match the given sorted array (must contain same editors, same count).
/// The previously active editor remains selected.
- (void)reorderEditors:(NSArray<EditorView *> *)orderedEditors;

/// Show Save As panel for an untitled editor.
- (void)runSavePanelForEditor:(EditorView *)editor completion:(nullable void(^)(BOOL saved))completion;

@end

NS_ASSUME_NONNULL_END
