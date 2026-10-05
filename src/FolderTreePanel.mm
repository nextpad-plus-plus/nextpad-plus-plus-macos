#import "FolderTreePanel.h"
#import "NppLocalizer.h"
#import "StyleConfiguratorWindowController.h"
#import <objc/runtime.h>
#import "NppThemeManager.h"

// ── Tree item model ───────────────────────────────────────────────────────────

@interface _FTItem : NSObject
@property NSURL  *url;
@property BOOL    isDirectory;
@property BOOL    isRootFolder;   // YES for user-added top-level dirs
@property (nullable) NSMutableArray<_FTItem *> *children; // nil = not yet loaded
@end

@implementation _FTItem
@end

// ── Forward declaration so _FTOutlineView can call FolderTreePanel ────────────

@interface FolderTreePanel () <NSTextFieldDelegate>
- (NSMenu *)_contextMenuForRow:(NSInteger)row;
- (nullable _FTItem *)_expandPathComponents:(NSArray<NSString *> *)components fromRoot:(_FTItem *)root;
@end

// ── Custom outline view — right-click delegates to panel ─────────────────────

@interface _FTOutlineView : NSOutlineView
@property (nonatomic, weak) FolderTreePanel *ftPanel;
@end

@implementation _FTOutlineView
- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint p   = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:p];
    return [_ftPanel _contextMenuForRow:row];
}
@end

// ── Constants ─────────────────────────────────────────────────────────────────

static NSString * const kDefaultsRootsKey   = @"FolderTreePanelRoots";
static NSString * const kTreeviewSubdir     = @"icons/standard/panels/treeview";

// Toolbar button metrics — match FunctionListPanel so the three panels
// share a consistent title-bar look.
static const CGFloat kFTToolbarBtnSize  = 16;
static const CGFloat kFTToolbarIconSize = 11;

// Pick the toolbar icon subdirectory based on the current theme. Dark
// variants are pre-rendered lighter so they stay readable on a dark bar.
static NSString *_FTToolbarIconSubdir(void) {
    return [NppThemeManager shared].isDark
        ? @"icons/dark/panels/toolbar"
        : @"icons/standard/panels/toolbar";
}

static NSImage *_FTLoadToolbarIcon(NSString *iconName, CGFloat size) {
    NSURL *url = [[NSBundle mainBundle] URLForResource:iconName withExtension:@"png"
                                          subdirectory:_FTToolbarIconSubdir()];
    NSImage *img = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
    if (img) img.size = NSMakeSize(size, size);
    return img;
}

// ── Panel button: toolbar-style hover, square (non-rounded) corners ───────────
// Mirrors _FLPHoverButton in FunctionListPanel.mm: invisible chrome at rest,
// toolbar-blue fill + border on hover/press. In dark mode the fill is
// skipped (would clash with the dark title strip) — only the border
// changes color. Image is drawn centered at its own .size so the visible
// icon size is kFTToolbarIconSize, not stretched to the button frame.
@interface _FTPanelButton : NSButton {
    BOOL _hovering;
}
@end

@implementation _FTPanelButton

- (instancetype)init {
    self = [super init];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.bordered = NO;
        [self setButtonType:NSButtonTypeMomentaryChange];
        [self.widthAnchor  constraintEqualToConstant:kFTToolbarBtnSize].active = YES;
        [self.heightAnchor constraintEqualToConstant:kFTToolbarBtnSize].active = YES;
        NSTrackingArea *ta = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:(NSTrackingMouseEnteredAndExited |
                          NSTrackingActiveInActiveApp |
                          NSTrackingInVisibleRect)
                   owner:self userInfo:nil];
        [self addTrackingArea:ta];
    }
    return self;
}

- (void)mouseEntered:(NSEvent *)event { _hovering = YES;  [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)event  { _hovering = NO;   [self setNeedsDisplay:YES]; }

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

// ── Close ✕ button: permanent 1px square grey border, toolbar-blue hover ─────
// Mirrors _FLPCloseButton in FunctionListPanel.mm / _DMPCloseButton in
// DocumentMapPanel.mm.
// Phase 2: close button is provided by PanelFrame.

// ── FolderTreePanel ───────────────────────────────────────────────────────────

@implementation FolderTreePanel {
    NSURL                     *_activeFileURL;

    // Toolbar row — search field on the left, action buttons right-aligned.
    NSTextField               *_searchField;
    NSButton                  *_refreshButton;
    NSButton                  *_unfoldAllButton;
    NSButton                  *_foldAllButton;
    NSButton                  *_locateButton;
    BOOL                       _bgIsDark;   // theme background is dark (tree icon set)

    // Filter — case-insensitive substring against lastPathComponent. nil/empty
    // means no filter. When non-nil, children are eagerly loaded so the
    // filter can match at any depth.
    NSString                  *_filterText;

    // Tree
    NSScrollView              *_scrollView;
    _FTOutlineView            *_outlineView;

    // Data — multiple user-added root folders
    NSMutableArray<_FTItem *> *_roots;

    // Zoom
    CGFloat _panelFontSize;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _roots = [NSMutableArray array];
        { CGFloat z = [[NSUserDefaults standardUserDefaults] floatForKey:@"PanelZoom_FolderTree"]; _panelFontSize = z >= 8 ? z : 11; }
        [self _buildUI];
        [self _applyTheme];
        [self _restoreRoots];
        [self retranslateUI];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_locChanged:)
                                                     name:NPPLocalizationChanged object:nil];
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
// PanelFrame owns the title; this panel retranslates only its own tool-
// bar button tooltips.
- (void)retranslateUI {
    NppLocalizer *loc = [NppLocalizer shared];
    _refreshButton.toolTip          = [loc translate:@"Refresh"];
    _unfoldAllButton.toolTip        = [loc translate:@"Expand All"];
    _foldAllButton.toolTip          = [loc translate:@"Fold All"];
    _locateButton.toolTip           = [loc translate:@"Locate Current File"];
    _searchField.placeholderString  = [loc translate:@"Filter file/folder name..."];
}

// ── UI Construction ───────────────────────────────────────────────────────────

static _FTPanelButton *_panelBtn(NSString *iconName, NSString *tip, id target, SEL action) {
    _FTPanelButton *btn = [[_FTPanelButton alloc] init];
    btn.toolTip = tip;
    btn.target  = target;
    btn.action  = action;
    NSImage *img = _FTLoadToolbarIcon(iconName, kFTToolbarIconSize);
    if (img) {
        btn.image = img;
    } else {
        btn.title = @"?";
    }
    return btn;
}

- (void)_buildUI {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    // Phase 2: title bar + close button now live in PanelFrame. The
    // refresh / expand-all / fold-all / locate buttons plus a file/folder
    // name filter sit in a single row below the PanelFrame chrome —
    // search field on the left, action buttons right-aligned, matching
    // FunctionListPanel's layout exactly so the two panels share a look.
    _searchField = [[NSTextField alloc] init];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.placeholderString = @"Filter file/folder name...";
    _searchField.font = [NSFont systemFontOfSize:11];
    _searchField.delegate = self;
    _searchField.bezelStyle = NSTextFieldRoundedBezel;
    [[_searchField cell] setScrollable:YES];
    [self addSubview:_searchField];

    _refreshButton   = _panelBtn(@"funclstReload",          @"Refresh",             self, @selector(_refreshAll:));
    _unfoldAllButton = _panelBtn(@"fb_expand_all",          @"Expand All",          self, @selector(_unfoldAll:));
    _foldAllButton   = _panelBtn(@"fb_fold_all",            @"Fold All",            self, @selector(_foldAll:));
    _locateButton    = _panelBtn(@"fb_select_current_file", @"Locate Current File", self, @selector(_locateCurrent:));

    for (NSView *v in @[_refreshButton, _unfoldAllButton, _foldAllButton, _locateButton])
        [self addSubview:v];

    // ── OutlineView ───────────────────────────────────────────────────────
    _outlineView = [[_FTOutlineView alloc] init];
    _outlineView.ftPanel    = self;
    _outlineView.dataSource = self;
    _outlineView.delegate   = self;
    _outlineView.rowHeight  = 22;
    _outlineView.headerView = nil;
    _outlineView.indentationPerLevel  = 14;
    _outlineView.autoresizesOutlineColumn = NO;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_outlineView addTableColumn:col];
    _outlineView.outlineTableColumn = col;
    [_outlineView sizeLastColumnToFit];
    _outlineView.target       = self;
    _outlineView.doubleAction = @selector(_doubleClicked:);

    _scrollView = [[NSScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.hasVerticalScroller   = YES;
    _scrollView.hasHorizontalScroller = YES;
    _scrollView.autohidesScrollers    = YES;
    _scrollView.documentView = _outlineView;

    // Icon updates when folders expand/collapse + theme changes
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(_itemExpandedOrCollapsed:)
               name:NSOutlineViewItemDidExpandNotification  object:_outlineView];
    [nc addObserver:self selector:@selector(_itemExpandedOrCollapsed:)
               name:NSOutlineViewItemDidCollapseNotification object:_outlineView];
    [nc addObserver:self selector:@selector(_themeChanged:)
               name:@"NPPPreferencesChanged" object:nil];
    // Dark-mode toggle doesn't route through NPPPreferencesChanged, so
    // we still need a separate observer to repaint our icons (panel body
    // stuff only — PanelFrame handles its own title-bar color change).
    [nc addObserver:self selector:@selector(_refreshToolbarIcons)
               name:NPPDarkModeChangedNotification object:nil];

    [self addSubview:_scrollView];

    // Search row: [search expandable] [refresh] [unfold] [fold] [locate].
    // 6pt leading/trailing gutters + 2pt inter-button gap match FunctionList.
    [NSLayoutConstraint activateConstraints:@[
        [_searchField.topAnchor      constraintEqualToAnchor:self.topAnchor constant:4],
        [_searchField.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor constant:6],
        [_searchField.trailingAnchor constraintEqualToAnchor:_refreshButton.leadingAnchor constant:-6],
        [_searchField.heightAnchor   constraintEqualToConstant:22],

        [_locateButton.trailingAnchor    constraintEqualToAnchor:self.trailingAnchor constant:-6],
        [_foldAllButton.trailingAnchor   constraintEqualToAnchor:_locateButton.leadingAnchor  constant:-2],
        [_unfoldAllButton.trailingAnchor constraintEqualToAnchor:_foldAllButton.leadingAnchor constant:-2],
        [_refreshButton.trailingAnchor   constraintEqualToAnchor:_unfoldAllButton.leadingAnchor constant:-2],

        [_refreshButton.centerYAnchor   constraintEqualToAnchor:_searchField.centerYAnchor],
        [_unfoldAllButton.centerYAnchor constraintEqualToAnchor:_searchField.centerYAnchor],
        [_foldAllButton.centerYAnchor   constraintEqualToAnchor:_searchField.centerYAnchor],
        [_locateButton.centerYAnchor    constraintEqualToAnchor:_searchField.centerYAnchor],

        [_scrollView.topAnchor      constraintEqualToAnchor:_searchField.bottomAnchor constant:4],
        [_scrollView.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scrollView.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
    ]];
}

// ── Theme ─────────────────────────────────────────────────────────────────────

- (void)_applyTheme {
    NSColor *bg = [[NPPStyleStore sharedStore] globalBg];
    _bgIsDark = [NppThemeManager isDarkColor:bg];

    // Theme only the tree/scroll area. The panel background itself (and
    // therefore the toolbar row) is left at system default so it matches
    // FunctionListPanel's look — subtle grey in light mode, default dark
    // chrome in dark mode.
    _outlineView.backgroundColor = bg;
    _scrollView.backgroundColor = bg;

    [self _refreshToolbarIcons];

    // Match disclosure-triangle (arrow) color, selection fill and scrollers to
    // the theme background: dark bg → DarkAqua so arrows are drawn white;
    // light bg → Aqua so arrows are drawn dark. Set on the scroll view so both
    // scrollers follow too (they otherwise inherit the chrome appearance).
    _scrollView.appearance = [NppThemeManager appearanceForBackground:bg];

    // Reload so every visible cell picks up the new text color immediately.
    [_outlineView reloadData];
}

- (void)_themeChanged:(NSNotification *)note {
    [self _applyTheme];
}

// ── Public API ────────────────────────────────────────────────────────────────

- (void)setActiveFileURL:(NSURL *)fileURL {
    _activeFileURL = fileURL;
}

- (void)chooseRootFolder {
    [self _addFolder:nil];
}

// ── Persistence ───────────────────────────────────────────────────────────────

- (void)_saveRoots {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (_FTItem *root in _roots)
        [paths addObject:root.url.path];
    [[NSUserDefaults standardUserDefaults] setObject:paths forKey:kDefaultsRootsKey];
}

- (void)_restoreRoots {
    NSArray<NSString *> *paths = [[NSUserDefaults standardUserDefaults]
                                  arrayForKey:kDefaultsRootsKey];
    for (NSString *path in paths) {
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] || !isDir)
            continue;
        _FTItem *root = [[_FTItem alloc] init];
        root.url          = [NSURL fileURLWithPath:path];
        root.isDirectory  = YES;
        root.isRootFolder = YES;
        [_roots addObject:root];
    }
    [_outlineView reloadData];
}

// ── Internal helpers ──────────────────────────────────────────────────────────

- (void)_addRootURL:(NSURL *)url {
    for (_FTItem *r in _roots)
        if ([r.url isEqual:url]) return;   // already present
    _FTItem *root = [[_FTItem alloc] init];
    root.url          = url;
    root.isDirectory  = YES;
    root.isRootFolder = YES;
    [_roots addObject:root];
    [_outlineView reloadData];
}

- (NSArray<_FTItem *> *)_loadChildrenOfURL:(NSURL *)url {
    NSArray<NSURL *> *contents =
        [[NSFileManager defaultManager]
            contentsOfDirectoryAtURL:url
            includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLNameKey]
            options:NSDirectoryEnumerationSkipsHiddenFiles
            error:nil] ?: @[];
    NSMutableArray<_FTItem *> *dirs  = [NSMutableArray array];
    NSMutableArray<_FTItem *> *files = [NSMutableArray array];
    for (NSURL *u in contents) {
        NSNumber *isDir = nil;
        [u getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        _FTItem *it = [[_FTItem alloc] init];
        it.url = u; it.isDirectory = isDir.boolValue; it.children = nil;
        if (it.isDirectory) [dirs  addObject:it];
        else                [files addObject:it];
    }
    NSSortDescriptor *sd = [NSSortDescriptor
        sortDescriptorWithKey:@"url.lastPathComponent" ascending:YES
                     selector:@selector(localizedCaseInsensitiveCompare:)];
    [dirs  sortUsingDescriptors:@[sd]];
    [files sortUsingDescriptors:@[sd]];
    NSMutableArray *result = [NSMutableArray arrayWithArray:dirs];
    [result addObjectsFromArray:files];
    return result;
}

/// Recursively find the _FTItem for url, expanding parents as needed.
- (nullable _FTItem *)_findItemForURL:(NSURL *)url inItems:(NSArray<_FTItem *> *)items {
    for (_FTItem *it in items) {
        if ([it.url isEqual:url]) return it;
        if (it.isDirectory && [url.path hasPrefix:[it.url.path stringByAppendingString:@"/"]]) {
            if (!it.children) it.children = [[self _loadChildrenOfURL:it.url] mutableCopy];
            [_outlineView expandItem:it];
            _FTItem *found = [self _findItemForURL:url inItems:it.children];
            if (found) return found;
        }
    }
    return nil;
}

- (NSImage *)_treeviewIcon:(NSString *)name {
    // Folder icons sit on the theme background, so pick the icon set from it
    // (not the chrome): the standard set is drawn for a light background.
    NSString *subdir = _bgIsDark ? @"icons/dark/panels/treeview" : kTreeviewSubdir;
    NSURL *url = [[NSBundle mainBundle] URLForResource:name withExtension:@"png"
                                          subdirectory:subdir];
    NSImage *img = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
    if (img) img.size = NSMakeSize(16, 16);
    return img;
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)_refreshAll:(id)sender {
    // Clear cached children for all roots so they reload from disk
    for (_FTItem *root in _roots)
        root.children = [[self _loadChildrenOfURL:root.url] mutableCopy];
    [_outlineView reloadData];
}

- (void)_unfoldAll:(id)sender {
    [_outlineView expandItem:nil expandChildren:YES];
}

- (void)_foldAll:(id)sender {
    [_outlineView collapseItem:nil collapseChildren:YES];
}

- (void)_locateCurrent:(id)sender {
    if (!_activeFileURL) return;
    NSString *targetPath = _activeFileURL.path.stringByStandardizingPath;
    if (!targetPath.length) return;

    // Only locate real files on disk, not directories or untitled buffers
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:targetPath isDirectory:&isDir] || isDir)
        return;

    for (_FTItem *root in _roots) {
        NSString *rootPath = root.url.path.stringByStandardizingPath;
        if (![targetPath hasPrefix:[rootPath stringByAppendingString:@"/"]])
            continue;

        // Path components between root and file, e.g. ["src", "main.mm"]
        NSString *relative = [targetPath substringFromIndex:rootPath.length + 1];
        NSArray<NSString *> *components = [relative pathComponents];
        if (!components.count) continue;

        _FTItem *fileItem = [self _expandPathComponents:components fromRoot:root];
        if (!fileItem) return;

        NSInteger row = [_outlineView rowForItem:fileItem];
        if (row >= 0) {
            [_outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                      byExtendingSelection:NO];
            [_outlineView scrollRowToVisible:row];
        }
        return;
    }
}

/// Load and expand every folder along the path, return the final file item.
- (nullable _FTItem *)_expandPathComponents:(NSArray<NSString *> *)components
                                   fromRoot:(_FTItem *)root {
    if (!root.children)
        root.children = [[self _loadChildrenOfURL:root.url] mutableCopy];
    [_outlineView expandItem:root];

    _FTItem *current = root;
    for (NSUInteger i = 0; i < components.count - 1; i++) {
        if (!current.children)
            current.children = [[self _loadChildrenOfURL:current.url] mutableCopy];
        _FTItem *next = nil;
        for (_FTItem *child in current.children)
            if ([child.url.lastPathComponent isEqualToString:components[i]]) { next = child; break; }
        if (!next) return nil;
        if (!next.children)
            next.children = [[self _loadChildrenOfURL:next.url] mutableCopy];
        [_outlineView expandItem:next];
        current = next;
    }

    // Expand the parent and find the file
    if (!current.children)
        current.children = [[self _loadChildrenOfURL:current.url] mutableCopy];
    [_outlineView expandItem:current];
    for (_FTItem *child in current.children)
        if ([child.url.lastPathComponent isEqualToString:components.lastObject]) return child;
    return nil;
}

- (void)_doubleClicked:(id)sender {
    id item = [_outlineView itemAtRow:_outlineView.clickedRow];
    if (!item) return;
    _FTItem *ft = (_FTItem *)item;
    if (!ft.isDirectory && _delegate)
        [_delegate folderTreePanel:self openFileAtURL:ft.url];
}

- (void)_itemExpandedOrCollapsed:(NSNotification *)note {
    _FTItem *item = note.userInfo[@"NSObject"];
    if (item) [_outlineView reloadItem:item];
}

// ── "Add Folder…" / "Remove All" actions ─────────────────────────────────────

- (void)_addFolder:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles        = NO;
    panel.canChooseDirectories  = YES;
    panel.allowsMultipleSelection = YES;
    panel.message = @"Choose a folder to add to the workspace";
    if ([panel runModal] == NSModalResponseOK) {
        for (NSURL *url in panel.URLs)
            [self _addRootURL:url];
        [self _saveRoots];
    }
}

- (void)_removeAllFolders:(id)sender {
    [_roots removeAllObjects];
    [_outlineView reloadData];
    [self _saveRoots];
}

// ── Context menus ─────────────────────────────────────────────────────────────

- (NSMenu *)_contextMenuForRow:(NSInteger)row {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];

    if (row < 0) {
        // Blank space
        NSMenuItem *add = [[NSMenuItem alloc] initWithTitle:@"Add Folder…"
                                                     action:@selector(_addFolder:) keyEquivalent:@""];
        add.target = self;
        [menu addItem:add];
        NSMenuItem *removeAll = [[NSMenuItem alloc] initWithTitle:@"Remove All"
                                                           action:@selector(_removeAllFolders:) keyEquivalent:@""];
        removeAll.target = self;
        [menu addItem:removeAll];
        return menu;
    }

    _FTItem *ft = (_FTItem *)[_outlineView itemAtRow:row];
    if (!ft) return menu;

    if (ft.isDirectory) {
        // Root folder: show Remove at top
        if (ft.isRootFolder) {
            NSMenuItem *remove = [[NSMenuItem alloc] initWithTitle:@"Remove"
                                                            action:@selector(_menuRemoveFolder:) keyEquivalent:@""];
            remove.target            = self;
            remove.representedObject = ft;
            [menu addItem:remove];
            [menu addItem:[NSMenuItem separatorItem]];
        }
        NSMenuItem *copyPath = [[NSMenuItem alloc] initWithTitle:@"Copy Path"
                                                          action:@selector(_menuCopyPath:) keyEquivalent:@""];
        copyPath.target            = self;
        copyPath.representedObject = ft;
        [menu addItem:copyPath];

        NSMenuItem *fif = [[NSMenuItem alloc] initWithTitle:@"Find in Files"
                                                     action:@selector(_menuFindInFiles:) keyEquivalent:@""];
        fif.target            = self;
        fif.representedObject = ft;
        [menu addItem:fif];

        // Run Macro on Files (issue: BBEdit-style batch processing).
        // representedObject carries the folder path; the menu action is on
        // MainWindowController, reached via responder chain (nil target).
        NSMenuItem *runMacro = [[NSMenuItem alloc] initWithTitle:@"Run Macro on Files…"
                                                          action:@selector(showBatchRunDialogForFolder:)
                                                   keyEquivalent:@""];
        runMacro.representedObject = ft.url.path;
        [menu addItem:runMacro];

        // Rename (non-root directories only)
        if (!ft.isRootFolder) {
            [menu addItem:[NSMenuItem separatorItem]];
            NSMenuItem *rename = [[NSMenuItem alloc] initWithTitle:@"Rename"
                                                            action:@selector(_menuRename:) keyEquivalent:@""];
            rename.target            = self;
            rename.representedObject = ft;
            [menu addItem:rename];
        }

        [menu addItem:[NSMenuItem separatorItem]];

        NSMenuItem *finder = [[NSMenuItem alloc] initWithTitle:@"Finder Here"
                                                        action:@selector(_menuFinderHere:) keyEquivalent:@""];
        finder.target            = self;
        finder.representedObject = ft;
        [menu addItem:finder];

        NSMenuItem *term = [[NSMenuItem alloc] initWithTitle:@"Terminal Here"
                                                      action:@selector(_menuTerminalHere:) keyEquivalent:@""];
        term.target            = self;
        term.representedObject = ft;
        [menu addItem:term];

    } else {
        // File
        NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"Open"
                                                      action:@selector(_menuOpenFile:) keyEquivalent:@""];
        open.target            = self;
        open.representedObject = ft;
        [menu addItem:open];
        [menu addItem:[NSMenuItem separatorItem]];

        NSMenuItem *copyPath = [[NSMenuItem alloc] initWithTitle:@"Copy Path"
                                                          action:@selector(_menuCopyPath:) keyEquivalent:@""];
        copyPath.target            = self;
        copyPath.representedObject = ft;
        [menu addItem:copyPath];

        NSMenuItem *copyName = [[NSMenuItem alloc] initWithTitle:@"Copy File Name"
                                                          action:@selector(_menuCopyFileName:) keyEquivalent:@""];
        copyName.target            = self;
        copyName.representedObject = ft;
        [menu addItem:copyName];

        [menu addItem:[NSMenuItem separatorItem]];

        NSMenuItem *rename = [[NSMenuItem alloc] initWithTitle:@"Rename"
                                                        action:@selector(_menuRename:) keyEquivalent:@""];
        rename.target            = self;
        rename.representedObject = ft;
        [menu addItem:rename];

        [menu addItem:[NSMenuItem separatorItem]];

        NSMenuItem *run = [[NSMenuItem alloc] initWithTitle:@"Run by System"
                                                     action:@selector(_menuRunBySystem:) keyEquivalent:@""];
        run.target            = self;
        run.representedObject = ft;
        [menu addItem:run];

        NSMenuItem *finder = [[NSMenuItem alloc] initWithTitle:@"Finder Here"
                                                        action:@selector(_menuFinderHere:) keyEquivalent:@""];
        finder.target            = self;
        finder.representedObject = ft;
        [menu addItem:finder];

        NSMenuItem *term = [[NSMenuItem alloc] initWithTitle:@"Terminal Here"
                                                      action:@selector(_menuTerminalHere:) keyEquivalent:@""];
        term.target            = self;
        term.representedObject = ft;
        [menu addItem:term];
    }
    return menu;
}

// ── Context menu action handlers ──────────────────────────────────────────────

- (void)_menuRemoveFolder:(NSMenuItem *)sender {
    _FTItem *ft = sender.representedObject;
    [_roots removeObject:ft];
    [_outlineView reloadData];
    [self _saveRoots];
}

- (void)_menuCopyPath:(NSMenuItem *)sender {
    _FTItem *ft = sender.representedObject;
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:ft.url.path forType:NSPasteboardTypeString];
}

- (void)_menuCopyFileName:(NSMenuItem *)sender {
    _FTItem *ft = sender.representedObject;
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:ft.url.lastPathComponent forType:NSPasteboardTypeString];
}

- (void)_menuFindInFiles:(NSMenuItem *)sender {
    _FTItem *ft = sender.representedObject;
    NSString *path = ft.isDirectory ? ft.url.path
                                    : ft.url.URLByDeletingLastPathComponent.path;
    [_delegate folderTreePanel:self findInFilesAtPath:path];
}

- (void)_menuFinderHere:(NSMenuItem *)sender {
    _FTItem *ft = sender.representedObject;
    if (ft.isDirectory) {
        [[NSWorkspace sharedWorkspace] openURL:ft.url];
    } else {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ft.url]];
    }
}

- (void)_menuTerminalHere:(NSMenuItem *)sender {
    _FTItem *ft = sender.representedObject;
    NSString *dir = ft.isDirectory ? ft.url.path
                                   : ft.url.URLByDeletingLastPathComponent.path;
    // open -a Terminal <dir> always opens a NEW Terminal window at that path
    [NSTask launchedTaskWithLaunchPath:@"/usr/bin/open"
                             arguments:@[@"-a", @"Terminal", dir]];
}

- (void)_menuOpenFile:(NSMenuItem *)sender {
    _FTItem *ft = sender.representedObject;
    [_delegate folderTreePanel:self openFileAtURL:ft.url];
}

- (void)_menuRename:(NSMenuItem *)sender {
    _FTItem *ft = sender.representedObject;
    if (!ft) return;

    NSInteger row = [_outlineView rowForItem:ft];
    if (row < 0) return;

    // Get the row rect in the outline view
    NSRect rowRect = [_outlineView rectOfRow:row];
    // Inset to roughly cover the text area (skip indent + icon)
    CGFloat indent = [_outlineView levelForRow:row] * _outlineView.indentationPerLevel + 36;
    NSRect editRect = NSMakeRect(rowRect.origin.x + indent, rowRect.origin.y + 1,
                                  rowRect.size.width - indent - 4, rowRect.size.height - 2);

    NSTextField *field = [[NSTextField alloc] initWithFrame:editRect];
    field.stringValue = ft.url.lastPathComponent;
    field.font = [NSFont systemFontOfSize:12];
    field.bordered = YES;
    field.bezeled = YES;
    field.bezelStyle = NSTextFieldSquareBezel;
    field.editable = YES;
    field.focusRingType = NSFocusRingTypeExterior;
    field.tag = row;

    // Use a completion handler block stored via associated object
    __weak FolderTreePanel *weakSelf = self;
    __weak NSTextField *weakField = field;
    field.target = self;
    field.action = @selector(_renameFieldCommitted:);

    // Store the item being renamed
    objc_setAssociatedObject(field, "ftItem", ft, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [_outlineView addSubview:field];
    [field selectText:nil];
    // Select just the name part (not extension) for files
    if (!ft.isDirectory) {
        NSString *name = ft.url.lastPathComponent;
        NSString *ext = ft.url.pathExtension;
        if (ext.length > 0) {
            NSText *editor = [field.window fieldEditor:YES forObject:field];
            NSRange nameRange = NSMakeRange(0, name.length - ext.length - 1);
            [editor setSelectedRange:nameRange];
        }
    }
}

- (void)_renameFieldCommitted:(NSTextField *)field {
    _FTItem *ft = objc_getAssociatedObject(field, "ftItem");
    NSString *newName = field.stringValue;
    [field removeFromSuperview];

    if (!ft || newName.length == 0) return;

    NSString *oldName = ft.url.lastPathComponent;
    if ([newName isEqualToString:oldName]) return;

    NSURL *parentURL = ft.url.URLByDeletingLastPathComponent;
    NSURL *newURL = [parentURL URLByAppendingPathComponent:newName];

    NSError *error = nil;
    if (![[NSFileManager defaultManager] moveItemAtURL:ft.url toURL:newURL error:&error]) {
        @autoreleasepool {
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = @"Rename Failed";
            a.informativeText = error.localizedDescription;
            a.alertStyle = NSAlertStyleWarning;
            [a runModal];
        }
        return;
    }

    // Update the item's URL and refresh the tree
    ft.url = newURL;
    // Reload parent's children to reflect the new name and sort order
    _FTItem *parent = [_outlineView parentForItem:ft];
    if (parent) {
        parent.children = [[self _loadChildrenOfURL:parent.url] mutableCopy];
    } else if (ft.isRootFolder) {
        // Root folder renamed — update and save
        [self _saveRoots];
    }
    [_outlineView reloadData];
}

- (void)_menuRunBySystem:(NSMenuItem *)sender {
    _FTItem *ft = sender.representedObject;
    NSString *escaped = [ft.url.path stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *script  = [NSString stringWithFormat:
        @"tell application \"Terminal\"\n"
         "  activate\n"
         "  do script \"'%@'\"\n"
         "end tell", escaped];
    NSAppleScript *as = [[NSAppleScript alloc] initWithSource:script];
    [as executeAndReturnError:nil];
}

// ── Filter ────────────────────────────────────────────────────────────────────

- (void)controlTextDidChange:(NSNotification *)note {
    if (note.object != _searchField) return;
    NSString *t = [_searchField.stringValue stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceCharacterSet]];
    BOOL wasActive = (_filterText != nil);
    _filterText = t.length ? t : nil;

    if (_filterText) {
        // Eagerly load every subtree so the filter can match at any depth.
        // This happens once on first activation; subsequent keystrokes just
        // re-filter the already-loaded tree.
        for (_FTItem *root in _roots)
            [self _ensureChildrenLoadedDeep:root];
    }

    [_outlineView reloadData];

    if (_filterText) {
        // Expand everything so matches surface without manual unfolding.
        [_outlineView expandItem:nil expandChildren:YES];
    } else if (wasActive) {
        // Filter was just cleared — collapse back to roots so the tree
        // doesn't stay fully expanded from the last filter pass.
        for (_FTItem *root in _roots)
            [_outlineView collapseItem:root collapseChildren:YES];
    }
}

- (void)_ensureChildrenLoadedDeep:(_FTItem *)item {
    if (!item.isDirectory) return;
    if (!item.children)
        item.children = [[self _loadChildrenOfURL:item.url] mutableCopy];
    for (_FTItem *c in item.children)
        if (c.isDirectory) [self _ensureChildrenLoadedDeep:c];
}

// Name of the item matches the current filter string (case-insensitive
// substring). Used directly for files, and as the base case for folders.
- (BOOL)_itemNameMatchesFilter:(_FTItem *)item {
    if (!_filterText) return YES;
    NSString *name = item.url.lastPathComponent ?: @"";
    return [name rangeOfString:_filterText options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// Item is visible under the filter if its own name matches OR (for folders)
// at least one descendant's name matches.
- (BOOL)_itemVisibleUnderFilter:(_FTItem *)item {
    if (!_filterText) return YES;
    if ([self _itemNameMatchesFilter:item]) return YES;
    if (item.isDirectory && item.children) {
        for (_FTItem *c in item.children)
            if ([self _itemVisibleUnderFilter:c]) return YES;
    }
    return NO;
}

// Children of `item` under the current filter. When filter is empty this
// lazy-loads and returns the full list; otherwise it returns only children
// that themselves pass -_itemVisibleUnderFilter:.
- (NSArray<_FTItem *> *)_filteredChildrenOf:(_FTItem *)item {
    if (!item.children)
        item.children = [[self _loadChildrenOfURL:item.url] mutableCopy];
    if (!_filterText) return item.children;
    NSMutableArray *out = [NSMutableArray array];
    for (_FTItem *c in item.children)
        if ([self _itemVisibleUnderFilter:c]) [out addObject:c];
    return out;
}

// Top-level roots that are visible under the current filter. Roots whose
// entire subtree fails the filter are hidden — matches Windows Folder-as-
// Workspace behavior.
- (NSArray<_FTItem *> *)_filteredRoots {
    if (!_filterText) return _roots;
    NSMutableArray *out = [NSMutableArray array];
    for (_FTItem *r in _roots)
        if ([self _itemVisibleUnderFilter:r]) [out addObject:r];
    return out;
}

// ── NSOutlineViewDataSource ───────────────────────────────────────────────────

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(nullable id)item {
    if (!item) return (NSInteger)[self _filteredRoots].count;
    _FTItem *ft = (_FTItem *)item;
    if (!ft.isDirectory) return 0;
    return (NSInteger)[self _filteredChildrenOf:ft].count;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(nullable id)item {
    if (!item) return [self _filteredRoots][(NSUInteger)index];
    return [self _filteredChildrenOf:(_FTItem *)item][(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
    _FTItem *ft = (_FTItem *)item;
    if (!ft.isDirectory) return NO;
    if (!_filterText) return YES;
    return [self _filteredChildrenOf:ft].count > 0;
}

// ── NSOutlineViewDelegate ─────────────────────────────────────────────────────

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    _FTItem *ft = (_FTItem *)item;
    NSTableCellView *cell = [ov makeViewWithIdentifier:@"cell" owner:nil];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        cell.identifier = @"cell";
        NSImageView *iv = [[NSImageView alloc] init];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        iv.imageFrameStyle = NSImageFrameNone;
        iv.imageScaling = NSImageScaleProportionallyUpOrDown;
        cell.imageView = iv;
        NSTextField *tf = [NppThemedLabel labelWithString:@""];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
        tf.font = [NSFont systemFontOfSize:_panelFontSize];
        cell.textField = tf;
        [cell addSubview:iv];
        [cell addSubview:tf];
        [NSLayoutConstraint activateConstraints:@[
            [iv.leadingAnchor   constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [iv.centerYAnchor   constraintEqualToAnchor:cell.centerYAnchor],
            [tf.leadingAnchor   constraintEqualToAnchor:iv.trailingAnchor  constant:4],
            [tf.centerYAnchor   constraintEqualToAnchor:cell.centerYAnchor],
            [tf.trailingAnchor  constraintEqualToAnchor:cell.trailingAnchor constant:-2],
        ]];
    }

    cell.textField.stringValue = ft.url.lastPathComponent ?: @"";
    if ([cell.textField isKindOfClass:[NppThemedLabel class]])
        ((NppThemedLabel *)cell.textField).themeTextColor = [[NPPStyleStore sharedStore] globalFg];
    else
        cell.textField.textColor = [[NPPStyleStore sharedStore] globalFg];
    cell.textField.font = [NSFont systemFontOfSize:_panelFontSize];

    NSImage *icon = nil;
    if (ft.isDirectory) {
        BOOL expanded = [ov isItemExpanded:ft];
        NSString *iconName;
        if (ft.isRootFolder)
            iconName = expanded ? @"fb_root_open"          : @"fb_root_close";
        else
            iconName = expanded ? @"project_folder_open"   : @"project_folder_close";
        icon = [self _treeviewIcon:iconName];
        if (!icon) {
            icon = [[NSWorkspace sharedWorkspace] iconForFileType:NSFileTypeForHFSTypeCode(kGenericFolderIcon)];
            icon.size = NSMakeSize(_panelFontSize + 4, _panelFontSize + 4);
        }
    } else {
        NSString *ext = ft.url.pathExtension;
        icon = ext.length ? [[NSWorkspace sharedWorkspace] iconForFileType:ext]
                          : [[NSWorkspace sharedWorkspace] iconForFileType:@""];
        icon.size = NSMakeSize(_panelFontSize + 4, _panelFontSize + 4);
    }
    cell.imageView.image = icon;
    // Update image view size constraints for zoom
    for (NSLayoutConstraint *c in cell.imageView.constraints) {
        if (c.firstAttribute == NSLayoutAttributeWidth || c.firstAttribute == NSLayoutAttributeHeight)
            c.constant = _panelFontSize + 4;
    }
    // If no size constraints exist yet (first time after removing hardcoded ones), add them
    if (cell.imageView.constraints.count == 0) {
        [cell.imageView.widthAnchor constraintEqualToConstant:_panelFontSize + 4].active = YES;
        [cell.imageView.heightAnchor constraintEqualToConstant:_panelFontSize + 4].active = YES;
    }
    return cell;
}

- (CGFloat)outlineView:(NSOutlineView *)ov heightOfRowByItem:(id)item {
    return _panelFontSize + 10;
}


- (void)_refreshToolbarIcons {
    _refreshButton.image   = _FTLoadToolbarIcon(@"funclstReload",          kFTToolbarIconSize);
    _unfoldAllButton.image = _FTLoadToolbarIcon(@"fb_expand_all",          kFTToolbarIconSize);
    _foldAllButton.image   = _FTLoadToolbarIcon(@"fb_fold_all",            kFTToolbarIconSize);
    _locateButton.image    = _FTLoadToolbarIcon(@"fb_select_current_file", kFTToolbarIconSize);
    [_refreshButton   setNeedsDisplay:YES];
    [_unfoldAllButton setNeedsDisplay:YES];
    [_foldAllButton   setNeedsDisplay:YES];
    [_locateButton    setNeedsDisplay:YES];
}


#pragma mark - Panel Zoom

- (void)_saveZoom { [[NSUserDefaults standardUserDefaults] setFloat:_panelFontSize forKey:@"PanelZoom_FolderTree"]; }
- (void)panelZoomIn    { _panelFontSize = MIN(_panelFontSize + 1, 28); [_outlineView reloadData]; [self _saveZoom]; }
- (void)panelZoomOut   { _panelFontSize = MAX(_panelFontSize - 1, 8);  [_outlineView reloadData]; [self _saveZoom]; }
- (void)panelZoomReset { _panelFontSize = 11; [_outlineView reloadData]; [self _saveZoom]; }
@end
