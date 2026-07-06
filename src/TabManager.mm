#import "TabManager.h"
#import "EditorView.h"

// ── NppDropView ──────────────────────────────────────────────────────────────
@implementation NppDropView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Register both modern (file URL) and legacy (filenames) pasteboard types
        // so drops from Finder work on all macOS 11+ versions.
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSFilenamesPboardType]];
    }
    return self;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSDictionary *opts = @{NSPasteboardURLReadingFileURLsOnlyKey: @YES};
    if ([sender.draggingPasteboard canReadObjectForClasses:@[[NSURL class]] options:opts])
        return NSDragOperationCopy;
    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    return [self draggingEntered:sender];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];

    // Modern path: NSPasteboardTypeFileURL (macOS 10.13+)
    NSDictionary *opts = @{NSPasteboardURLReadingFileURLsOnlyKey: @YES};
    NSArray<NSURL *> *urls = [sender.draggingPasteboard
        readObjectsForClasses:@[[NSURL class]] options:opts];
    for (NSURL *url in urls) if (url.isFileURL) [paths addObject:url.path];

    // Legacy fallback: NSFilenamesPboardType (array of path strings)
    if (!paths.count) {
        NSArray *names = [sender.draggingPasteboard propertyListForType:NSFilenamesPboardType];
        if ([names isKindOfClass:[NSArray class]])
            [paths addObjectsFromArray:names];
    }

    if (paths.count && _dropHandler) { _dropHandler(paths); return YES; }
    return NO;
}

@end

// ── TabManager ───────────────────────────────────────────────────────────────
@implementation TabManager {
    NppTabBar                  *_tabBar;
    NSView                     *_contentView;
    NSMutableArray<EditorView *> *_editors;
    NSInteger                   _selectedIndex;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _editors = [NSMutableArray array];
        _selectedIndex = -1;

        _tabBar = [[NppTabBar alloc] initWithFrame:NSZeroRect];
        _tabBar.delegate = self;

        _contentView = [[NppDropView alloc] initWithFrame:NSZeroRect];
        _contentView.wantsLayer = YES;
    }
    return self;
}

#pragma mark - Public API

- (EditorView *)addNewTab {
    EditorView *editor = [[EditorView alloc] initWithFrame:_contentView.bounds];
    editor.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    [self insertEditor:editor title:editor.displayName modified:NO];
    return editor;
}

- (nullable EditorView *)openFileAtPath:(NSString *)path {
    // Focus existing tab if already open
    for (NSInteger i = 0; i < (NSInteger)_editors.count; i++) {
        if ([_editors[i].filePath isEqualToString:path]) {
            [self activateTabAtIndex:i];
            return _editors[i];
        }
    }

    EditorView *editor = [[EditorView alloc] initWithFrame:_contentView.bounds];
    editor.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSError *error;
    if (![editor loadFileAtPath:path error:&error]) {
        [[NSAlert alertWithError:error] runModal];
        return nil;
    }

    [self insertEditor:editor title:editor.displayName modified:NO];
    return editor;
}

- (void)closeCurrentTab {
    if (_selectedIndex >= 0) {
        [self closeEditor:_editors[_selectedIndex]];
    }
}

- (void)closeEditor:(EditorView *)editor {
    // Only prompt for unsaved changes when no clone sibling holds the shared document.
    if (editor.isModified && !editor.cloneSibling) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithFormat:@"Save changes to \"%@\"?", editor.displayName];
        alert.informativeText = @"Your changes will be lost if you don't save them.";
        [alert addButtonWithTitle:@"Save"];
        [alert addButtonWithTitle:@"Don't Save"];
        [alert addButtonWithTitle:@"Cancel"];
        NSModalResponse resp = [alert runModal];

        if (resp == NSAlertFirstButtonReturn) {
            if (!editor.filePath) {
                [self runSavePanelForEditor:editor completion:^(BOOL saved) {
                    if (saved) [self removeEditor:editor];
                }];
                return;
            }
            NSError *err;
            if (![editor saveError:&err]) {
                // Save failed (read-only path, full disk, encoding-inapplicable, …).
                // Surface the error and KEEP the tab — falling through to
                // removeEditor: would silently destroy the user's unsaved changes
                // even though they explicitly chose "Save".
                [[NSAlert alertWithError:err] runModal];
                return;
            }
        } else if (resp == NSAlertThirdButtonReturn) {
            return;
        }
    }
    [self removeEditor:editor];
}

- (void)evictEditor:(EditorView *)editor {
    NSInteger idx = [_editors indexOfObject:editor];
    if (idx == NSNotFound) return;
    [editor removeFromSuperview];
    [_editors removeObjectAtIndex:idx];
    [_tabBar removeTabAtIndex:idx];
    if (_editors.count > 0) {
        NSInteger nextIdx = MIN(idx, (NSInteger)_editors.count - 1);
        [self activateTabAtIndex:nextIdx];
    }
    [_delegate tabManager:self didCloseEditor:editor];
}

- (void)adoptEditor:(EditorView *)editor {
    [self insertEditor:editor title:editor.displayName modified:editor.isModified];
}

- (void)refreshCurrentTabTitle {
    if (_selectedIndex < 0) return;
    EditorView *editor = _editors[_selectedIndex];
    [_tabBar setTitle:editor.displayName modified:editor.isModified atIndex:_selectedIndex];
}

- (void)refreshAllTabTitles {
    for (NSInteger i = 0; i < (NSInteger)_editors.count; i++)
        [_tabBar setTitle:_editors[i].displayName modified:_editors[i].isModified atIndex:i];
}

- (void)selectTabAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_editors.count) return;
    [self activateTabAtIndex:index];
}

#pragma mark - NppTabBarDelegate

- (void)tabBar:(NppTabBar *)bar didSelectTabAtIndex:(NSInteger)index {
    [self activateTabAtIndex:index];
}

- (void)tabBar:(NppTabBar *)bar didCloseTabAtIndex:(NSInteger)index {
    // NPP behavior: can't close the last tab when it's already clean and untitled
    if (_editors.count == 1 && !_editors[0].isModified && !_editors[0].filePath) return;
    [self closeEditor:_editors[index]];
}

- (void)tabBarDidRequestNewTab:(NppTabBar *)bar {
    // User double-clicked the empty area to the right of the last tab. Open
    // a new untitled tab in THIS tab manager — the routing is implicit
    // because each NppTabBar's delegate is the TabManager that owns it, so
    // we can never receive this for a bar that belongs to a different pane.
    [self addNewTab];
}

- (void)tabBar:(NppTabBar *)bar didMoveTabFromIndex:(NSInteger)fromIndex toIndex:(NSInteger)toIndex {
    NSInteger count = (NSInteger)_editors.count;
    if (fromIndex < 0 || fromIndex >= count ||
        toIndex < 0 || toIndex >= count ||
        fromIndex == toIndex) return;

    EditorView *movingEditor = _editors[fromIndex];
    [_editors removeObjectAtIndex:(NSUInteger)fromIndex];
    [_editors insertObject:movingEditor atIndex:(NSUInteger)toIndex];

    if (_selectedIndex == fromIndex) {
        _selectedIndex = toIndex;
    } else if (fromIndex < _selectedIndex && _selectedIndex <= toIndex) {
        _selectedIndex--;
    } else if (toIndex <= _selectedIndex && _selectedIndex < fromIndex) {
        _selectedIndex++;
    }
}

#pragma mark - Accessors

- (NppTabBar *)tabBar    { return _tabBar; }
- (NSView *)contentView  { return _contentView; }

- (EditorView *)currentEditor {
    if (_selectedIndex < 0 || _selectedIndex >= (NSInteger)_editors.count) return nil;
    return _editors[_selectedIndex];
}

- (NSArray<EditorView *> *)allEditors { return [_editors copy]; }

#pragma mark - Private

- (void)insertEditor:(EditorView *)editor title:(NSString *)title modified:(BOOL)modified {
    [_editors addObject:editor];
    [_contentView addSubview:editor];
    [_tabBar addTabWithTitle:title modified:modified];
    [self activateTabAtIndex:(NSInteger)_editors.count - 1];
}

- (void)activateTabAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_editors.count) return;

    // Hide previously active editor
    if (_selectedIndex >= 0 && _selectedIndex < (NSInteger)_editors.count) {
        _editors[_selectedIndex].hidden = YES;
    }

    _selectedIndex = index;
    EditorView *editor = _editors[index];
    editor.hidden = NO;
    editor.frame = _contentView.bounds;
    [_tabBar selectTabAtIndex:index];
    [_contentView setNeedsLayout:YES];

    [_delegate tabManager:self didSelectEditor:editor];
}

- (void)removeEditor:(EditorView *)editor {
    NSInteger idx = [_editors indexOfObject:editor];
    if (idx == NSNotFound) return;

    // Unregister file presenter so the EditorView can be deallocated.
    // (NSFileCoordinator holds a strong ref to registered presenters.)
    [editor prepareForClose];
    [editor removeFromSuperview];
    [_editors removeObjectAtIndex:idx];
    [_tabBar removeTabAtIndex:idx];

    // Always keep at least one tab
    if (_editors.count == 0) {
        [self addNewTab];
        return;
    }

    NSInteger nextIdx = MIN(idx, (NSInteger)_editors.count - 1);
    [self activateTabAtIndex:nextIdx];
    [_delegate tabManager:self didCloseEditor:editor];
}

- (void)swapEditorAtIndex:(NSInteger)a withIndex:(NSInteger)b {
    NSInteger count = (NSInteger)_editors.count;
    if (a < 0 || a >= count || b < 0 || b >= count || a == b) return;

    // Swap in the editors array
    [_editors exchangeObjectAtIndex:(NSUInteger)a withObjectAtIndex:(NSUInteger)b];

    // Swap in the tab bar
    [_tabBar swapTabAtIndex:a withIndex:b];

    // Selection follows the originally selected tab
    if (_selectedIndex == a) {
        _selectedIndex = b;
        [_tabBar selectTabAtIndex:b];
    } else if (_selectedIndex == b) {
        _selectedIndex = a;
        [_tabBar selectTabAtIndex:a];
    }
}

- (void)reorderEditors:(NSArray<EditorView *> *)orderedEditors {
    if (orderedEditors.count != _editors.count) return;

    EditorView *current = self.currentEditor;

    // Save pinned state keyed by editor identity before rebuilding.
    NSMutableDictionary<NSValue *, NSNumber *> *pinnedMap = [NSMutableDictionary dictionary];
    for (NSInteger i = 0; i < (NSInteger)_editors.count; i++) {
        NSValue *key = [NSValue valueWithNonretainedObject:_editors[i]];
        pinnedMap[key] = @([_tabBar isTabPinnedAtIndex:i]);
    }

    // Replace _editors with the sorted order.
    [_editors removeAllObjects];
    [_editors addObjectsFromArray:orderedEditors];

    // Rebuild the tab bar: remove all items then re-add in new order.
    while (_tabBar.tabCount > 0) [_tabBar removeTabAtIndex:0];
    for (NSInteger i = 0; i < (NSInteger)_editors.count; i++) {
        EditorView *ed = _editors[i];
        [_tabBar addTabWithTitle:ed.displayName modified:ed.isModified];
        NSValue *key = [NSValue valueWithNonretainedObject:ed];
        if ([pinnedMap[key] boolValue])
            [_tabBar pinTabAtIndex:i toggle:YES];
    }

    // Restore the previously active editor.
    NSInteger newSel = [_editors indexOfObject:current];
    if (newSel == NSNotFound) newSel = 0;
    _selectedIndex = -1;
    [self activateTabAtIndex:newSel];
}

- (void)runSavePanelForEditor:(EditorView *)editor completion:(void(^)(BOOL))completion {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = editor.displayName;
    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSError *err;
            // Report the ACTUAL write result, not just that the panel was
            // confirmed. completion(YES) tells the close path it may discard the
            // buffer, so reporting success on a failed write loses the content.
            BOOL saved = [editor saveToPath:panel.URL.path error:&err];
            if (!saved) [[NSAlert alertWithError:err] runModal];
            [self refreshAllTabTitles];
            if (completion) completion(saved);
        } else {
            if (completion) completion(NO);
        }
    }];
}

@end
