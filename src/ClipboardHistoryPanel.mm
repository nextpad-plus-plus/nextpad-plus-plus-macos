#import "ClipboardHistoryPanel.h"
#import "StyleConfiguratorWindowController.h"
#import "NppThemeManager.h"

// Phase 2: title bar + close button + separator now supplied by PanelFrame.

static const NSUInteger kMaxHistory = 30;

@implementation ClipboardHistoryPanel {
    NSScrollView       *_scrollView;
    NSTableView        *_tableView;
    NSMutableArray<NSString *> *_history;
    NSTimer            *_timer;
    NSInteger           _lastChangeCount;
    CGFloat             _panelFontSize;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _history = [NSMutableArray array];
        { CGFloat z = [[NSUserDefaults standardUserDefaults] floatForKey:@"PanelZoom_ClipboardHistory"]; _panelFontSize = z >= 8 ? z : 11; }
        _lastChangeCount = [NSPasteboard generalPasteboard].changeCount;
        [self _buildLayout];
        [self _applyTheme];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_themeChanged:)
                                                     name:@"NPPPreferencesChanged" object:nil];
    }
    return self;
}

- (instancetype)init {
    return [self initWithFrame:NSZeroRect];
}

- (void)dealloc {
    // Pair the addObserver: in initWithFrame: so a torn-down panel can
    // never leave a dangling pointer in CoreFoundation's observer list —
    // the signature of the long-session crash in incident
    // 647E563D / 18618486.
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_buildLayout {
    _scrollView = [[NSScrollView alloc] init];
    NSScrollView *scroll = _scrollView;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;

    _tableView = [[NSTableView alloc] init];
    _tableView.headerView = nil;
    _tableView.rowHeight = 18;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.allowsEmptySelection = YES;
    _tableView.allowsMultipleSelection = NO;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"clip"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:col];
    [_tableView sizeLastColumnToFit];

    scroll.documentView = _tableView;
    [self addSubview:scroll];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor      constraintEqualToAnchor:self.topAnchor],
        [scroll.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [scroll.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
    ]];
}

- (void)_applyTheme {
    NPPStyleStore *store = [NPPStyleStore sharedStore];
    NSColor *bg = [store globalBg];
    _scrollView.backgroundColor = bg;
    _tableView.backgroundColor  = bg;
    // Pin the table (and scroller) appearance to the theme background, not the
    // chrome: otherwise dark chrome over a light theme draws the unfocused
    // selection in dark-mode grey under theme-black text.
    _scrollView.appearance = [NppThemeManager appearanceForBackground:bg];
    [_tableView reloadData];
}

- (void)_themeChanged:(NSNotification *)note {
    [self _applyTheme];
}

// ── Public API ────────────────────────────────────────────────────────────────

- (void)startMonitoring {
    if (_timer) return;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.75
                                              target:self
                                            selector:@selector(_pollPasteboard:)
                                            userInfo:nil
                                             repeats:YES];
}

- (void)stopMonitoring {
    [_timer invalidate];
    _timer = nil;
}

// ── Private ───────────────────────────────────────────────────────────────────

- (void)_pollPasteboard:(NSTimer *)t {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSInteger current = pb.changeCount;
    if (current == _lastChangeCount) return;
    _lastChangeCount = current;

    NSString *str = [pb stringForType:NSPasteboardTypeString];
    if (!str.length) return;

    // Skip duplicate of most recent entry
    if (_history.count && [_history.firstObject isEqualToString:str]) return;

    [_history insertObject:str atIndex:0];
    if (_history.count > kMaxHistory) [_history removeLastObject];

    [_tableView reloadData];
}

// ── Copy support ──────────────────────────────────────────────────────────────

/// NSTableView calls this for each selected row when the user presses Cmd+C.
/// Returning a writer here lets NSTableView handle copy: internally, preventing
/// the action from propagating up the responder chain and crashing.
- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView
              pasteboardWriterForRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_history.count) return nil;
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setString:_history[row] forType:NSPasteboardTypeString];
    return item;
}

/// Fallback: if copy: bubbles up from the table without being handled, copy the
/// full (non-truncated) text of the selected entry to the general pasteboard.
- (void)copy:(id)sender {
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_history.count) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:_history[row] forType:NSPasteboardTypeString];
}

// ── NSTableViewDataSource ─────────────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_history.count;
}

// ── NSTableViewDelegate ───────────────────────────────────────────────────────

- (nullable NSView *)tableView:(NSTableView *)tableView
            viewForTableColumn:(nullable NSTableColumn *)tableColumn
                           row:(NSInteger)row {
    NSString *entry = _history[row];
    // Truncate long entries for display
    NSString *display = entry.length > 80
        ? [[entry substringToIndex:80] stringByAppendingString:@"…"]
        : entry;
    // Collapse newlines for single-line display
    display = [display stringByReplacingOccurrencesOfString:@"\n" withString:@"↵"];
    display = [display stringByReplacingOccurrencesOfString:@"\r" withString:@"↵"];

    NSTextField *cell = [tableView makeViewWithIdentifier:@"ClipCell" owner:nil];
    if (!cell) {
        cell = [[NppThemedLabel alloc] init];
        cell.identifier = @"ClipCell";
        cell.editable = NO;
        cell.bordered = NO;
        cell.drawsBackground = NO;
    }
    NPPStyleStore *store = [NPPStyleStore sharedStore];
    NSString *fontName = [store globalFontName];
    int fontSize = [store globalFontSize];
    cell.font = [NSFont fontWithName:fontName size:fontSize ?: 12];
    cell.font = [NSFont systemFontOfSize:_panelFontSize];
    if ([cell isKindOfClass:[NppThemedLabel class]])
        ((NppThemedLabel *)cell).themeTextColor = [store globalFg];
    else
        cell.textColor = [store globalFg];
    cell.stringValue = display;
    return cell;
}


#pragma mark - Panel Zoom

- (void)_saveZoom { [[NSUserDefaults standardUserDefaults] setFloat:_panelFontSize forKey:@"PanelZoom_ClipboardHistory"]; }
- (void)panelZoomIn    { _panelFontSize = MIN(_panelFontSize + 1, 28); _tableView.rowHeight = _panelFontSize + 8; [_tableView reloadData]; [self _saveZoom]; }
- (void)panelZoomOut   { _panelFontSize = MAX(_panelFontSize - 1, 8);  _tableView.rowHeight = _panelFontSize + 8; [_tableView reloadData]; [self _saveZoom]; }
- (void)panelZoomReset { _panelFontSize = 11; _tableView.rowHeight = 19; [_tableView reloadData]; [self _saveZoom]; }
@end
