#import "GitPanel.h"
#import "GitHelper.h"
#import "NppLocalizer.h"
#import "StyleConfiguratorWindowController.h"
#import "NppThemeManager.h"

// ── Status item model ─────────────────────────────────────────────────────────

@interface _GitStatusItem : NSObject
@property NSString *xy;    // 2-char porcelain status (e.g. " M", "??", "A ")
@property NSString *path;  // repo-relative path
@end

@implementation _GitStatusItem
@end

// ── Title-bar metrics + theme-aware icon loader ──────────────────────────────
// Match FunctionListPanel / FolderTreePanel so the three panel title bars
// share a consistent look.
static const CGFloat kGPToolbarBtnSize  = 16;
static const CGFloat kGPToolbarIconSize = 11;

// Remap a light-theme icon subdirectory to its dark-theme counterpart.
// Handles both "icons/standard/panels/toolbar" → "icons/dark/panels/toolbar"
// and "icons/light/panels/treeview" → "icons/dark/panels/treeview".
static NSString *_GPThemedSubdir(NSString *lightSubdir) {
    if (![NppThemeManager shared].isDark) return lightSubdir;
    NSString *s = [lightSubdir stringByReplacingOccurrencesOfString:@"/standard/"
                                                          withString:@"/dark/"];
    s = [s stringByReplacingOccurrencesOfString:@"/light/" withString:@"/dark/"];
    return s;
}

static NSImage *_GPLoadIcon(NSString *iconName, NSString *lightSubdir, CGFloat size) {
    NSURL *url = [[NSBundle mainBundle] URLForResource:iconName withExtension:@"png"
                                          subdirectory:_GPThemedSubdir(lightSubdir)];
    NSImage *img = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
    if (img) img.size = NSMakeSize(size, size);
    return img;
}

// ── Panel button: toolbar-style hover, square (non-rounded) corners ─────────
// Mirrors _FLPHoverButton / _FTPanelButton. Invisible chrome at rest;
// toolbar-blue fill+border on hover/press with fill skipped in dark mode.
// Image drawn centered at .size (not stretched).
@interface _GPHoverButton : NSButton { BOOL _hovering; }
@end

@implementation _GPHoverButton

- (instancetype)init {
    self = [super init];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.bordered = NO;
        [self setButtonType:NSButtonTypeMomentaryChange];
        [self.widthAnchor  constraintEqualToConstant:kGPToolbarBtnSize].active = YES;
        [self.heightAnchor constraintEqualToConstant:kGPToolbarBtnSize].active = YES;
        NSTrackingArea *ta = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:(NSTrackingMouseEnteredAndExited |
                          NSTrackingActiveInActiveApp     |
                          NSTrackingInVisibleRect)
                   owner:self userInfo:nil];
        [self addTrackingArea:ta];
    }
    return self;
}

- (void)mouseEntered:(NSEvent *)event { _hovering = YES; [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)event  { _hovering = NO;  [self setNeedsDisplay:YES]; }

- (void)drawRect:(NSRect)dirtyRect {
    BOOL pressed = self.isHighlighted;
    BOOL active  = pressed || _hovering;
    BOOL isDark  = [NppThemeManager shared].isDark;

    if (active) {
        if (!isDark) {
            NSColor *bg = pressed
                ? [NSColor colorWithRed:0xCC/255.0 green:0xE8/255.0 blue:0xFF/255.0 alpha:1.0]
                : [NSColor colorWithRed:0xE5/255.0 green:0xF3/255.0 blue:0xFF/255.0 alpha:1.0];
            [bg setFill];
            NSRectFill(self.bounds);
        }
        NSColor *bdr = [NSColor colorWithRed:0xD0/255.0 green:0xEA/255.0 blue:0xFF/255.0 alpha:1.0];
        NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds, 0.5, 0.5)];
        border.lineWidth = 1.0;
        [bdr setStroke];
        [border stroke];
    }

    if (self.image) {
        NSSize isz = self.image.size;
        NSRect ir = NSMakeRect(NSMidX(self.bounds) - isz.width / 2.0,
                               NSMidY(self.bounds) - isz.height / 2.0,
                               isz.width, isz.height);
        [self.image drawInRect:ir
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver
                      fraction:1.0
                respectFlipped:YES
                         hints:nil];
    }
}

@end

// ── Close ✕ button: permanent 1px square grey border, toolbar-blue hover ────
// Mirrors _FLPCloseButton / _FTCloseButton / _DMPCloseButton.
// Phase 2: close button is provided by PanelFrame.

// ── Toolbar icon button helper (header row, not title bar) ───────────────────

static NSButton *_gitPanelBtn(NSString *iconName, NSString *subdir, NSString *tip,
                               id target, SEL action)
{
    _GPHoverButton *btn = [[_GPHoverButton alloc] init];
    btn.toolTip = tip;
    btn.target  = target;
    btn.action  = action;
    NSImage *img = _GPLoadIcon(iconName, subdir, kGPToolbarIconSize);
    if (img) {
        btn.image = img;
    } else {
        btn.title = @"?";
    }
    return btn;
}

// ── GitPanel implementation ───────────────────────────────────────────────────

@implementation GitPanel {
    NSString             *_repoRoot;
    NSArray<_GitStatusItem *> *_items;

    // Header (branch info + toolbar buttons). PanelFrame supplies the
    // title bar + close button above this row.
    NSTextField          *_branchLabel;
    NSButton             *_browseRepoButton;
    NSButton             *_refreshButton;

    // Table
    NSScrollView         *_scrollView;
    NSTableView          *_tableView;
    CGFloat               _panelFontSize;

    // Buttons
    NSButton             *_stageAllButton;
    NSButton             *_unstageAllButton;

    // Commit
    NSTextField          *_commitField;
    NSButton             *_commitButton;

    // No-repo state
    NSTextField          *_noRepoLabel;

    // Cached bullet image
    NSImage              *_bulletImage;
}

static NSString * const kLastRepoRootKey = @"GitPanelLastRepoRoot";

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _items = @[];
        { CGFloat z = [[NSUserDefaults standardUserDefaults] floatForKey:@"PanelZoom_Git"]; _panelFontSize = z >= 8 ? z : 11; }
        [self _loadBulletImage];
        [self _buildUI];
        [self _setNoRepo:YES];
        [self _applyTheme];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_themeChanged:)
                   name:@"NPPPreferencesChanged" object:nil];
        // PanelFrame owns the title bar's dark-mode repaint. We still
        // need dark-mode changes for our own icon refresh (panel body).
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_refreshToolbarIcons)
                   name:NPPDarkModeChangedNotification object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_locChanged:)
                   name:NPPLocalizationChanged object:nil];
        [self retranslateUI];
        // Restore last repo
        NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kLastRepoRootKey];
        if (saved) {
            BOOL isDir = NO;
            if ([[NSFileManager defaultManager] fileExistsAtPath:saved isDirectory:&isDir] && isDir) {
                [self setRepoRoot:saved];
                [self refresh];
            }
        }
    }
    return self;
}

- (instancetype)init {
    return [self initWithFrame:NSZeroRect];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_locChanged:(NSNotification *)n { [self retranslateUI]; }
// PanelFrame owns the title; this retranslates only the panel's
// internal controls.
- (void)retranslateUI {
    NppLocalizer *loc = [NppLocalizer shared];
    _refreshButton.toolTip        = [loc translate:@"Refresh"];
    _browseRepoButton.toolTip     = [loc translate:@"Browse for repository…"];
    _stageAllButton.title          = [loc translate:@"Stage All"];
    _unstageAllButton.title        = [loc translate:@"Unstage All"];
    _commitButton.title            = [loc translate:@"Commit"];
    _commitField.placeholderString = [loc translate:@"Commit message\u2026"];
    _noRepoLabel.stringValue       = [loc translate:@"No git repository\nUse Browse to open a repo."];
}

- (void)_loadBulletImage {
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"bullet_red"
                                        withExtension:@"png"
                                         subdirectory:@"icons/standard/toolbar"];
    _bulletImage = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
    if (_bulletImage) _bulletImage.size = NSMakeSize(12, 12);
}

// ── Theme ─────────────────────────────────────────────────────────────────────

- (void)_applyTheme {
    NSColor *bg = [[NPPStyleStore sharedStore] globalBg];
    NSColor *fg = [[NPPStyleStore sharedStore] globalFg];
    _scrollView.backgroundColor = bg;
    _tableView.backgroundColor  = bg;
    _branchLabel.textColor      = fg;
    _noRepoLabel.textColor      = [NSColor secondaryLabelColor];
    [self _refreshToolbarIcons];
    [_tableView reloadData];
}

- (void)_refreshToolbarIcons {
    _refreshButton.image    = _GPLoadIcon(@"funclstReload",       @"icons/standard/panels/toolbar",
                                          kGPToolbarIconSize);
    _browseRepoButton.image = _GPLoadIcon(@"project_folder_open", @"icons/light/panels/treeview",
                                          kGPToolbarIconSize);
    [_refreshButton    setNeedsDisplay:YES];
    [_browseRepoButton setNeedsDisplay:YES];
}

- (void)_themeChanged:(NSNotification *)note {
    [self _applyTheme];
}

// ── UI Construction ───────────────────────────────────────────────────────────

- (void)_buildUI {
    NppLocalizer *loc = [NppLocalizer shared];
    NSFont *smallFont = [NSFont systemFontOfSize:11];
    NSFont *monoFont  = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];

    // Phase 2: title bar + close button supplied by PanelFrame. The
    // refresh / browse-for-repo buttons move from the old title bar into
    // the branch-header row (which is the first thing inside the panel's
    // content area), right-aligned.
    _refreshButton    = _gitPanelBtn(@"funclstReload",       @"icons/standard/panels/toolbar",
                                      [loc translate:@"Refresh"],                self, @selector(_refresh:));
    _browseRepoButton = _gitPanelBtn(@"project_folder_open", @"icons/light/panels/treeview",
                                      [loc translate:@"Browse for repository…"], self, @selector(_browseForRepo:));

    // ── Branch header (with right-aligned toolbar buttons) ────────────────────
    NSView *header = [[NSView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;

    _branchLabel = [NSTextField labelWithString:@""];
    _branchLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _branchLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    _branchLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    [header addSubview:_branchLabel];
    [header addSubview:_browseRepoButton];
    [header addSubview:_refreshButton];
    [NSLayoutConstraint activateConstraints:@[
        [header.heightAnchor constraintEqualToConstant:28],
        [_branchLabel.leadingAnchor  constraintEqualToAnchor:header.leadingAnchor constant:6],
        [_branchLabel.centerYAnchor  constraintEqualToAnchor:header.centerYAnchor],
        [_branchLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_browseRepoButton.leadingAnchor constant:-4],

        [_refreshButton.trailingAnchor   constraintEqualToAnchor:header.trailingAnchor   constant:-4],
        [_browseRepoButton.trailingAnchor constraintEqualToAnchor:_refreshButton.leadingAnchor constant:-2],
        [_refreshButton.centerYAnchor    constraintEqualToAnchor:header.centerYAnchor],
        [_browseRepoButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    ]];

    // ── Separator ─────────────────────────────────────────────────────────────
    NSBox *sep1 = [[NSBox alloc] init];
    sep1.boxType = NSBoxSeparator;
    sep1.translatesAutoresizingMaskIntoConstraints = NO;

    // ── Table ─────────────────────────────────────────────────────────────────
    _tableView = [[NSTableView alloc] init];
    _tableView.dataSource = self;
    _tableView.delegate   = self;
    _tableView.rowHeight  = 22;
    _tableView.headerView = nil;
    _tableView.usesAlternatingRowBackgroundColors = NO;
    _tableView.allowsMultipleSelection = YES;
    _tableView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;

    NSTableColumn *badgeCol = [[NSTableColumn alloc] initWithIdentifier:@"badge"];
    badgeCol.width = 20;
    badgeCol.minWidth = 20;
    badgeCol.maxWidth = 20;
    [_tableView addTableColumn:badgeCol];

    NSTableColumn *pathCol = [[NSTableColumn alloc] initWithIdentifier:@"path"];
    pathCol.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:pathCol];
    [_tableView sizeLastColumnToFit];

    _tableView.target = self;
    _tableView.action = @selector(_rowSingleClicked:);

    // Context menu
    NSMenu *ctxMenu = [[NSMenu alloc] init];
    [ctxMenu addItemWithTitle:[loc translate:@"Stage"]     action:@selector(_stageSelected:)   keyEquivalent:@""];
    [ctxMenu addItemWithTitle:[loc translate:@"Unstage"]   action:@selector(_unstageSelected:) keyEquivalent:@""];
    [ctxMenu addItem:[NSMenuItem separatorItem]];
    [ctxMenu addItemWithTitle:[loc translate:@"Open File"] action:@selector(_openSelected:)    keyEquivalent:@""];
    _tableView.menu = ctxMenu;
    ctxMenu.itemArray[0].target = self;
    ctxMenu.itemArray[1].target = self;
    ctxMenu.itemArray[3].target = self;

    _scrollView = [[NSScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.hasVerticalScroller   = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.autohidesScrollers    = YES;
    _scrollView.documentView = _tableView;

    // ── Stage / Unstage All ───────────────────────────────────────────────────
    _stageAllButton = [NSButton buttonWithTitle:[loc translate:@"Stage All"] target:self
                                         action:@selector(_stageAll:)];
    _stageAllButton.translatesAutoresizingMaskIntoConstraints = NO;
    _stageAllButton.bezelStyle = NSBezelStyleRounded;
    _stageAllButton.font = smallFont;

    _unstageAllButton = [NSButton buttonWithTitle:[loc translate:@"Unstage All"] target:self
                                           action:@selector(_unstageAll:)];
    _unstageAllButton.translatesAutoresizingMaskIntoConstraints = NO;
    _unstageAllButton.bezelStyle = NSBezelStyleRounded;
    _unstageAllButton.font = smallFont;

    NSView *buttonRow = [[NSView alloc] init];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    [buttonRow addSubview:_stageAllButton];
    [buttonRow addSubview:_unstageAllButton];
    [NSLayoutConstraint activateConstraints:@[
        [buttonRow.heightAnchor constraintEqualToConstant:28],
        [_stageAllButton.leadingAnchor  constraintEqualToAnchor:buttonRow.leadingAnchor constant:4],
        [_stageAllButton.centerYAnchor  constraintEqualToAnchor:buttonRow.centerYAnchor],
        [_unstageAllButton.leadingAnchor constraintEqualToAnchor:_stageAllButton.trailingAnchor constant:4],
        [_unstageAllButton.centerYAnchor constraintEqualToAnchor:buttonRow.centerYAnchor],
    ]];

    // ── Separator ─────────────────────────────────────────────────────────────
    NSBox *sep2 = [[NSBox alloc] init];
    sep2.boxType = NSBoxSeparator;
    sep2.translatesAutoresizingMaskIntoConstraints = NO;

    // ── Commit message ────────────────────────────────────────────────────────
    _commitField = [[NSTextField alloc] init];
    _commitField.translatesAutoresizingMaskIntoConstraints = NO;
    _commitField.placeholderString = [loc translate:@"Commit message\u2026"];
    _commitField.font = monoFont;
    _commitField.cell.wraps = YES;
    _commitField.cell.scrollable = NO;
    _commitField.delegate = (id<NSTextFieldDelegate>)self;

    // ── Commit button ─────────────────────────────────────────────────────────
    _commitButton = [NSButton buttonWithTitle:[loc translate:@"Commit"] target:self
                                       action:@selector(_commit:)];
    _commitButton.translatesAutoresizingMaskIntoConstraints = NO;
    _commitButton.bezelStyle = NSBezelStyleRounded;
    _commitButton.font = smallFont;
    _commitButton.enabled = NO;
    _commitButton.keyEquivalent = @"\r";

    // ── No-repo label ─────────────────────────────────────────────────────────
    _noRepoLabel = [NSTextField labelWithString:[loc translate:@"No git repository\nUse Browse to open a repo."]];
    _noRepoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _noRepoLabel.font = [NSFont systemFontOfSize:13];
    _noRepoLabel.textColor = [NSColor secondaryLabelColor];
    _noRepoLabel.alignment = NSTextAlignmentCenter;
    _noRepoLabel.maximumNumberOfLines = 2;

    // ── Assemble layout ───────────────────────────────────────────────────────
    for (NSView *v in @[header, sep1, _scrollView, buttonRow, sep2,
                        _commitField, _commitButton, _noRepoLabel])
        [self addSubview:v];

    [NSLayoutConstraint activateConstraints:@[
        // Branch header (formerly under the panel's own title bar; now
        // directly under PanelFrame's title bar)
        [header.topAnchor      constraintEqualToAnchor:self.topAnchor],
        [header.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        // Sep1
        [sep1.topAnchor      constraintEqualToAnchor:header.bottomAnchor],
        [sep1.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [sep1.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [sep1.heightAnchor   constraintEqualToConstant:1],
        // Table fills middle
        [_scrollView.topAnchor      constraintEqualToAnchor:sep1.bottomAnchor],
        [_scrollView.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scrollView.bottomAnchor   constraintEqualToAnchor:buttonRow.topAnchor],
        // Button row
        [buttonRow.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [buttonRow.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [buttonRow.bottomAnchor   constraintEqualToAnchor:sep2.topAnchor],
        // Sep2
        [sep2.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [sep2.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [sep2.heightAnchor   constraintEqualToConstant:1],
        [sep2.bottomAnchor   constraintEqualToAnchor:_commitField.topAnchor],
        // Commit field — full width
        [_commitField.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor constant:4],
        [_commitField.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
        [_commitField.heightAnchor   constraintEqualToConstant:54],
        // Commit button — right-aligned
        [_commitButton.topAnchor     constraintEqualToAnchor:_commitField.bottomAnchor constant:4],
        [_commitButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
        [_commitButton.bottomAnchor  constraintEqualToAnchor:self.bottomAnchor constant:-4],
        // No-repo state (centered)
        [_noRepoLabel.centerXAnchor  constraintEqualToAnchor:self.centerXAnchor],
        [_noRepoLabel.centerYAnchor  constraintEqualToAnchor:self.centerYAnchor],
        [_noRepoLabel.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_noRepoLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
    ]];
}

- (void)_setNoRepo:(BOOL)noRepo {
    _noRepoLabel.hidden      = !noRepo;
    _scrollView.hidden       = noRepo;
    _stageAllButton.hidden   = noRepo;
    _unstageAllButton.hidden = noRepo;
    _commitField.hidden      = noRepo;
    _commitButton.hidden     = noRepo;
    if (noRepo) _branchLabel.stringValue = [[NppLocalizer shared] translate:@"(no repository)"];
}

// ── Public API ────────────────────────────────────────────────────────────────

- (void)setRepoRoot:(nullable NSString *)root {
    _repoRoot = [root copy];
    if (!root) {
        _items = @[];
        [_tableView reloadData];
        [self _setNoRepo:YES];
    } else {
        [[NSUserDefaults standardUserDefaults] setObject:root forKey:kLastRepoRootKey];
        [self _setNoRepo:NO];
    }
}

- (void)refresh {
    if (!_repoRoot) { [self _setNoRepo:YES]; return; }
    NSString *root = _repoRoot;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *branch = [GitHelper currentBranchAtRoot:root];
        NSArray<NSDictionary *> *status = [GitHelper statusAtRoot:root];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self->_branchLabel.stringValue =
                branch ? [NSString stringWithFormat:@"\u2387 %@", branch] : [[NppLocalizer shared] translate:@"(detached)"];
            NSMutableArray *items = [NSMutableArray array];
            for (NSDictionary *d in status) {
                _GitStatusItem *it = [[_GitStatusItem alloc] init];
                it.xy   = d[@"xy"];
                it.path = d[@"path"];
                [items addObject:it];
            }
            self->_items = items;
            [self->_tableView reloadData];
            [self _setNoRepo:NO];
        });
    });
}

// ── NSTableViewDataSource ─────────────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return (NSInteger)_items.count;
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    _GitStatusItem *item = _items[row];
    NSColor *fg = [[NPPStyleStore sharedStore] globalFg];

    if ([col.identifier isEqualToString:@"badge"]) {
        NSImageView *iv = [tv makeViewWithIdentifier:@"badge" owner:nil];
        if (!iv) {
            iv = [[NSImageView alloc] init];
            iv.identifier = @"badge";
            iv.imageFrameStyle = NSImageFrameNone;
            iv.imageScaling = NSImageScaleProportionallyDown;
        }
        // Use bullet_red.png for all changed/untracked files; nil for others
        NSString *xy = item.xy;
        unichar x = xy.length > 0 ? [xy characterAtIndex:0] : ' ';
        unichar y = xy.length > 1 ? [xy characterAtIndex:1] : ' ';
        BOOL hasChange = !(x == ' ' && y == ' ');
        iv.image = hasChange ? _bulletImage : nil;
        return iv;
    } else {
        NSTextField *label = [tv makeViewWithIdentifier:@"path" owner:nil];
        if (!label) {
            label = [NSTextField labelWithString:@""];
            label.identifier = @"path";
            label.lineBreakMode = NSLineBreakByTruncatingMiddle;
            label.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        }
        label.stringValue = item.path;
        label.textColor = fg;
        label.font = [NSFont monospacedSystemFontOfSize:_panelFontSize weight:NSFontWeightRegular];
        return label;
    }
}

// ── Row click ─────────────────────────────────────────────────────────────────

- (void)_rowSingleClicked:(id)sender {
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_items.count) return;
    _GitStatusItem *item = _items[row];
    if (!_repoRoot) return;
    NSString *fullPath = [_repoRoot stringByAppendingPathComponent:item.path];
    if (_delegate) [_delegate gitPanel:self diffFileAtPath:fullPath];
}

// ── Context menu / button actions ─────────────────────────────────────────────

- (nullable _GitStatusItem *)_itemAtClickedRow {
    NSInteger row = _tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)_items.count) return nil;
    return _items[row];
}

- (void)_stageSelected:(id)sender {
    _GitStatusItem *it = [self _itemAtClickedRow];
    if (!it || !_repoRoot) return;
    NSString *root = _repoRoot, *path = it.path;
    [GitHelper stageFile:path root:root completion:^(BOOL ok) { [self refresh]; }];
}

- (void)_unstageSelected:(id)sender {
    _GitStatusItem *it = [self _itemAtClickedRow];
    if (!it || !_repoRoot) return;
    NSString *root = _repoRoot, *path = it.path;
    [GitHelper unstageFile:path root:root completion:^(BOOL ok) { [self refresh]; }];
}

- (void)_openSelected:(id)sender {
    _GitStatusItem *it = [self _itemAtClickedRow];
    if (!it || !_repoRoot) return;
    NSString *fullPath = [_repoRoot stringByAppendingPathComponent:it.path];
    if (_delegate) [_delegate gitPanel:self openFileAtPath:fullPath];
}

- (void)_stageAll:(id)sender {
    if (!_repoRoot) return;
    NSString *root = _repoRoot;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/usr/bin/git";
        task.arguments = @[@"add", @"-A"];
        task.currentDirectoryPath = root;
        // Output is intentionally unused. Send both streams to /dev/null rather
        // than unread pipes, whose bounded buffers can deadlock a verbose git
        // invocation before waitUntilExit returns.
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        task.standardError  = [NSFileHandle fileHandleWithNullDevice];
        @try { [task launch]; [task waitUntilExit]; } @catch (NSException *) {}
        dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
    });
}

- (void)_unstageAll:(id)sender {
    if (!_repoRoot) return;
    NSString *root = _repoRoot;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/usr/bin/git";
        task.arguments = @[@"restore", @"--staged", @"."];
        task.currentDirectoryPath = root;
        // See _stageAll: — unread NSPipes can fill and block the child forever.
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        task.standardError  = [NSFileHandle fileHandleWithNullDevice];
        @try { [task launch]; [task waitUntilExit]; } @catch (NSException *) {}
        dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
    });
}

- (void)_browseForRepo:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.message = [[NppLocalizer shared] translate:@"Choose a git repository folder"];
    if ([panel runModal] == NSModalResponseOK) {
        NSURL *url = panel.URLs.firstObject;
        NSString *root = [GitHelper gitRootForPath:url.path];
        if (!root) root = url.path;
        [self setRepoRoot:root];
        [self refresh];
    }
}

- (void)_refresh:(id)sender {
    [self refresh];
}

- (void)_commit:(id)sender {
    NSString *msg = _commitField.stringValue;
    if (!msg.length || !_repoRoot) return;
    NSString *root = _repoRoot;
    _commitButton.enabled = NO;
    [GitHelper commitMessage:msg root:root completion:^(BOOL ok, NSString *errMsg) {
        if (ok) {
            self->_commitField.stringValue = @"";
            [self refresh];
        } else {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = [[NppLocalizer shared] translate:@"Commit Failed"];
            alert.informativeText = errMsg ?: [[NppLocalizer shared] translate:@"Unknown error"];
            [alert runModal];
        }
        self->_commitButton.enabled = self->_commitField.stringValue.length > 0;
    }];
}

// ── NSTextFieldDelegate (commit field) ────────────────────────────────────────

- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object == _commitField) {
        _commitButton.enabled = _commitField.stringValue.length > 0;
    }
}


#pragma mark - Panel Zoom

- (void)_saveZoom { [[NSUserDefaults standardUserDefaults] setFloat:_panelFontSize forKey:@"PanelZoom_Git"]; }
- (void)panelZoomIn    { _panelFontSize = MIN(_panelFontSize + 1, 28); _tableView.rowHeight = _panelFontSize + 8; [_tableView reloadData]; [self _saveZoom]; }
- (void)panelZoomOut   { _panelFontSize = MAX(_panelFontSize - 1, 8);  _tableView.rowHeight = _panelFontSize + 8; [_tableView reloadData]; [self _saveZoom]; }
- (void)panelZoomReset { _panelFontSize = 11; _tableView.rowHeight = 19; [_tableView reloadData]; [self _saveZoom]; }
@end
