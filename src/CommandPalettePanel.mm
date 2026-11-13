#import "CommandPalettePanel.h"
#import "NppLocalizer.h"

// ── Private row view (green selection highlight) ───────────────────────────

@interface _CPRowView : NSTableRowView @end
@implementation _CPRowView
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    if (!self.isSelected) return;
    NSColor *c = [NSColor colorWithRed:0.18 green:0.80 blue:0.44 alpha:0.18];
    [c setFill];
    NSRect r = NSInsetRect(self.bounds, 4, 2);
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:6 yRadius:6] fill];
}
@end

// ── CommandPalettePanel ────────────────────────────────────────────────────

static const CGFloat kPanelW  = 620;
static const CGFloat kPanelH  = 420;
static const CGFloat kSearchH = 56;
static const CGFloat kRowH    = 50;

@implementation CommandPalettePanel {
    NSTextField  *_searchField;
    NSTableView  *_tableView;
    NSTextField  *_emptyLabel;

    NSArray<NSDictionary *> *_allCommands;
    NSArray<NSDictionary *> *_filtered;

    id _escMonitor;   // local event monitor for Escape
}

// Borderless windows can't become key by default — override so the
// search field actually receives keyboard input.
- (BOOL)canBecomeKeyWindow  { return YES; }
- (BOOL)canBecomeMainWindow { return NO;  }

- (void)dealloc {
    if (_escMonitor) [NSEvent removeMonitor:_escMonitor];
}

- (instancetype)init {
    self = [super initWithContentRect:NSMakeRect(0, 0, kPanelW, kPanelH)
                            styleMask:NSWindowStyleMaskBorderless
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (!self) return nil;

    self.opaque            = NO;
    self.backgroundColor   = NSColor.clearColor;
    self.hasShadow         = YES;
    self.level             = NSFloatingWindowLevel;
    self.delegate          = self;
    self.releasedWhenClosed = NO;

    [self _buildUI];
    return self;
}

// ── UI construction ────────────────────────────────────────────────────────

- (void)_buildUI {
    // Container with rounded corners
    NSView *box = [[NSView alloc] initWithFrame:self.contentView.bounds];
    box.wantsLayer = YES;
    box.layer.cornerRadius   = 14;
    box.layer.masksToBounds  = YES;
    box.layer.backgroundColor =
        [NSColor colorWithRed:0.11 green:0.13 blue:0.18 alpha:0.97].CGColor;
    box.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.10].CGColor;
    box.layer.borderWidth = 1;
    box.autoresizingMask  = NSViewWidthSizable | NSViewHeightSizable;
    [self.contentView addSubview:box];

    // Magnifier icon
    if (@available(macOS 11.0, *)) {
        NSImageView *icon = [NSImageView imageViewWithImage:
            [NSImage imageWithSystemSymbolName:@"magnifyingglass"
                     accessibilityDescription:nil]];
        icon.frame = NSMakeRect(16, kPanelH - kSearchH + 12, 22, 22);
        icon.contentTintColor = [NSColor colorWithWhite:0.55 alpha:1.0];
        icon.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
        [box addSubview:icon];
    }

    // Search field
    _searchField = [[NSTextField alloc] initWithFrame:
        NSMakeRect(46, kPanelH - kSearchH + 10, kPanelW - 62, 28)];
    _searchField.placeholderString = [[NppLocalizer shared] translate:@"Search commands…"];
    _searchField.bordered           = NO;
    _searchField.backgroundColor    = NSColor.clearColor;
    _searchField.textColor          = NSColor.whiteColor;
    _searchField.font   = [NSFont systemFontOfSize:16 weight:NSFontWeightRegular];
    _searchField.delegate           = self;
    _searchField.focusRingType      = NSFocusRingTypeNone;
    _searchField.autoresizingMask   = NSViewWidthSizable | NSViewMinYMargin;
    [box addSubview:_searchField];

    // Separator
    NSBox *sep = [[NSBox alloc] initWithFrame:
        NSMakeRect(0, kPanelH - kSearchH, kPanelW, 1)];
    sep.boxType  = NSBoxCustom;
    sep.fillColor = [NSColor colorWithWhite:1.0 alpha:0.08];
    sep.borderWidth = 0;
    sep.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [box addSubview:sep];

    // Scroll + table
    CGFloat tableH = kPanelH - kSearchH - 1;
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:
        NSMakeRect(0, 0, kPanelW, tableH)];
    sv.hasVerticalScroller   = YES;
    sv.drawsBackground       = NO;
    sv.autohidesScrollers    = YES;
    sv.autoresizingMask      = NSViewWidthSizable | NSViewHeightSizable;

    _tableView = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, kPanelW, tableH)];
    _tableView.dataSource  = self;
    _tableView.delegate    = self;
    _tableView.backgroundColor  = NSColor.clearColor;
    _tableView.headerView        = nil;
    _tableView.intercellSpacing  = NSMakeSize(0, 0);
    _tableView.rowHeight         = kRowH;
    _tableView.target            = self;
    _tableView.action            = @selector(_rowClicked:);
    _tableView.focusRingType     = NSFocusRingTypeNone;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"cmd"];
    col.width = kPanelW;
    [_tableView addTableColumn:col];
    sv.documentView = _tableView;
    [box addSubview:sv];

    // "No results" label
    _emptyLabel = [NSTextField labelWithString:[[NppLocalizer shared] translate:@"No commands found"]];
    _emptyLabel.frame = NSMakeRect(0, tableH / 2 - 12, kPanelW, 24);
    _emptyLabel.alignment   = NSTextAlignmentCenter;
    _emptyLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightRegular];
    _emptyLabel.textColor   = [NSColor colorWithWhite:0.45 alpha:1.0];
    _emptyLabel.hidden      = YES;
    _emptyLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [box addSubview:_emptyLabel];
}

// ── Index building ─────────────────────────────────────────────────────────

- (void)buildIndex {
    NSMutableArray *result = [NSMutableArray array];
    for (NSMenuItem *top in NSApp.mainMenu.itemArray) {
        if (top.hasSubmenu)
            [self _walk:top.submenu path:top.submenu.title into:result];
    }
    _allCommands = [result copy];
}

- (void)_walk:(NSMenu *)menu path:(NSString *)path into:(NSMutableArray *)out {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isSeparatorItem || item.title.length == 0) continue;

        NSString *fullPath = [NSString stringWithFormat:@"%@ › %@", path, item.title];

        if (item.hasSubmenu) {
            [self _walk:item.submenu path:fullPath into:out];
        } else if (item.action && item.action != @selector(notYetImplemented:)) {
            NSMutableDictionary *cmd = [NSMutableDictionary dictionary];
            cmd[@"title"]    = item.title;
            cmd[@"path"]     = path;
            cmd[@"selector"] = NSStringFromSelector(item.action);
            cmd[@"item"]     = item;
            NSString *key = [self _keyStringForItem:item];
            if (key.length) cmd[@"key"] = key;
            [out addObject:cmd];
        }
    }
}

- (NSString *)_keyStringForItem:(NSMenuItem *)item {
    if (!item.keyEquivalent.length) return @"";
    NSMutableString *s = [NSMutableString string];
    NSEventModifierFlags m = item.keyEquivalentModifierMask;
    if (m & NSEventModifierFlagControl) [s appendString:@"⌃"];
    if (m & NSEventModifierFlagOption)  [s appendString:@"⌥"];
    if (m & NSEventModifierFlagShift)   [s appendString:@"⇧"];
    if (m & NSEventModifierFlagCommand) [s appendString:@"⌘"];
    [s appendString:item.keyEquivalent.uppercaseString];
    return s;
}

// ── Show / hide ────────────────────────────────────────────────────────────

- (void)showOverWindow:(NSWindow *)window {
    [self buildIndex];
    [_searchField setStringValue:@""];
    [self _filterWith:@""];

    NSRect wf = window.frame;
    CGFloat x = NSMidX(wf) - kPanelW / 2.0;
    CGFloat y = NSMaxY(wf) - 90 - kPanelH;
    [self setFrameOrigin:NSMakePoint(x, MAX(y, NSMinY(wf) + 20))];

    [window addChildWindow:self ordered:NSWindowAbove];
    [self makeKeyAndOrderFront:nil];
    [self makeFirstResponder:_searchField];

    // Local monitor: catch Escape even if the text field swallows it
    if (!_escMonitor) {
        __weak typeof(self) wSelf = self;
        _escMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                            handler:^NSEvent *(NSEvent *e) {
            if (e.keyCode == 53 && wSelf.isVisible) {   // 53 = Escape
                [wSelf _dismiss];
                return nil;  // consume the event
            }
            return e;
        }];
    }
}

- (void)_dismiss {
    if (_escMonitor) {
        [NSEvent removeMonitor:_escMonitor];
        _escMonitor = nil;
    }
    if (self.parentWindow)
        [self.parentWindow removeChildWindow:self];
    [self orderOut:nil];
}

// ── Filtering ──────────────────────────────────────────────────────────────

- (void)_filterWith:(NSString *)text {
    if (text.length == 0) {
        _filtered = _allCommands;
    } else {
        NSString *lower = text.lowercaseString;
        NSPredicate *pred = [NSPredicate predicateWithBlock:
            ^BOOL(NSDictionary *cmd, id _) {
                return [[cmd[@"title"] lowercaseString] containsString:lower]
                    || [[cmd[@"path"]  lowercaseString] containsString:lower];
            }];
        _filtered = [_allCommands filteredArrayUsingPredicate:pred];
    }

    [_tableView reloadData];
    _emptyLabel.hidden = (_filtered.count > 0 || _allCommands.count == 0);

    if (_filtered.count > 0) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                byExtendingSelection:NO];
        [_tableView scrollRowToVisible:0];
    }
}

// ── Execute ────────────────────────────────────────────────────────────────

- (void)_executeSelected {
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_filtered.count) return;
    NSMenuItem *item = _filtered[row][@"item"];
    [self _dismiss];
    // Small delay so the panel is gone before the action fires
    dispatch_async(dispatch_get_main_queue(), ^{
        if (item.action)
            [NSApp sendAction:item.action to:item.target from:item];
    });
}

// ── NSTextFieldDelegate ────────────────────────────────────────────────────

- (void)controlTextDidChange:(NSNotification *)note {
    [self _filterWith:_searchField.stringValue];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)tv
        doCommandBySelector:(SEL)sel {
    if (sel == @selector(moveDown:)) {
        NSInteger next = MIN(_tableView.selectedRow + 1,
                             (NSInteger)_filtered.count - 1);
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:next]
                byExtendingSelection:NO];
        [_tableView scrollRowToVisible:next];
        return YES;
    }
    if (sel == @selector(moveUp:)) {
        NSInteger prev = MAX(_tableView.selectedRow - 1, 0);
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:prev]
                byExtendingSelection:NO];
        [_tableView scrollRowToVisible:prev];
        return YES;
    }
    if (sel == @selector(insertNewline:)) {
        [self _executeSelected];
        return YES;
    }
    if (sel == @selector(cancelOperation:)) {
        [self _dismiss];
        return YES;
    }
    return NO;
}

// ── NSWindowDelegate ───────────────────────────────────────────────────────

- (void)windowDidResignKey:(NSNotification *)note {
    [self _dismiss];
}

// ── NSTableViewDataSource ──────────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return (NSInteger)_filtered.count;
}

// ── NSTableViewDelegate ────────────────────────────────────────────────────

- (NSTableRowView *)tableView:(NSTableView *)tv
                rowViewForRow:(NSInteger)row {
    return [[_CPRowView alloc] init];
}

- (NSView *)tableView:(NSTableView *)tv
   viewForTableColumn:(NSTableColumn *)col
                  row:(NSInteger)row {
    NSDictionary *cmd = _filtered[row];

    NSView *cell = [tv makeViewWithIdentifier:@"CP" owner:self];
    if (!cell) {
        cell = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kPanelW, kRowH)];
        cell.identifier = @"CP";

        // Title
        NSTextField *title = [NSTextField labelWithString:@""];
        title.tag   = 1;
        title.frame = NSMakeRect(18, 26, kPanelW - 130, 18);
        title.font  = [NSFont systemFontOfSize:13.5
                                        weight:NSFontWeightMedium];
        title.textColor = NSColor.whiteColor;
        title.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:title];

        // Path (breadcrumb)
        NSTextField *path = [NSTextField labelWithString:@""];
        path.tag   = 2;
        path.frame = NSMakeRect(18, 9, kPanelW - 130, 14);
        path.font  = [NSFont systemFontOfSize:11
                                       weight:NSFontWeightRegular];
        path.textColor = [NSColor colorWithWhite:0.52 alpha:1.0];
        path.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [cell addSubview:path];

        // Key shortcut (right side)
        NSTextField *key = [NSTextField labelWithString:@""];
        key.tag       = 3;
        key.frame     = NSMakeRect(kPanelW - 108, 16, 96, 18);
        key.font      = [NSFont monospacedSystemFontOfSize:11
                                                    weight:NSFontWeightRegular];
        key.textColor = [NSColor colorWithWhite:0.42 alpha:1.0];
        key.alignment = NSTextAlignmentRight;
        [cell addSubview:key];
    }

    ((NSTextField *)[cell viewWithTag:1]).stringValue = cmd[@"title"] ?: @"";
    ((NSTextField *)[cell viewWithTag:2]).stringValue = cmd[@"path"]  ?: @"";
    ((NSTextField *)[cell viewWithTag:3]).stringValue = cmd[@"key"]   ?: @"";

    return cell;
}

- (CGFloat)tableView:(NSTableView *)tv heightOfRow:(NSInteger)row {
    return kRowH;
}

- (void)_rowClicked:(id)sender {
    if (_tableView.clickedRow >= 0) {
        [_tableView selectRowIndexes:
            [NSIndexSet indexSetWithIndex:_tableView.clickedRow]
                byExtendingSelection:NO];
        [self _executeSelected];
    }
}

@end
