#import <Cocoa/Cocoa.h>
#import "TabManager.h"

NS_ASSUME_NONNULL_BEGIN

@class DocumentListPanel;
@class EditorView;

@protocol DocumentListPanelDelegate <NSObject>
- (void)documentListPanelDidRequestClose:(DocumentListPanel *)panel;
@optional
/// All open editors across every view (primary + both split panes). When
/// implemented, the panel lists these instead of just the primary tab manager's
/// editors — so tabs moved to a split view still appear. Falls back to the
/// primary tab manager when not implemented.
- (NSArray<EditorView *> *)documentListPanelEditors:(DocumentListPanel *)panel;
/// Activate an editor that may live in any view (primary or a split pane).
/// Return YES if handled; the panel falls back to the primary tab manager on NO.
- (BOOL)documentListPanel:(DocumentListPanel *)panel activateEditor:(EditorView *)editor;
/// Close an editor that may live in any view (primary or a split pane).
/// Return YES if handled; the panel falls back to the primary tab manager on NO.
- (BOOL)documentListPanel:(DocumentListPanel *)panel closeEditor:(EditorView *)editor;
/// The currently-active editor across all views, for the selected-row highlight.
- (nullable EditorView *)documentListPanelCurrentEditor:(DocumentListPanel *)panel;
/// The tab color assigned to this document (nil if none) — used to tint the row,
/// matching the colored tab.
- (nullable NSColor *)documentListPanel:(DocumentListPanel *)panel
              backgroundColorForEditor:(EditorView *)editor;
@end

/// Side panel that lists all open editor tabs and lets the user switch between
/// them by clicking a row.
@interface DocumentListPanel : NSView <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, weak, nullable) id<DocumentListPanelDelegate> delegate;

- (instancetype)initWithTabManager:(TabManager *)tabManager;

/// Reload the list from the tab manager (call after tab open/close/select).
- (void)reloadData;

/// Lightweight refresh of the per-row saved/unsaved floppy indicators
/// without disturbing selection or scroll position. Call when an editor's
/// modified state may have changed (e.g. on edit or save).
- (void)refreshModifiedStates;

@end

NS_ASSUME_NONNULL_END
