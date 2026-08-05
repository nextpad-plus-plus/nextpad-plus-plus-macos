#import "ProjectPanel.h"
#import "NppLocalizer.h"
#import "NppThemeManager.h"
#import "StyleConfiguratorWindowController.h"

// ── Node types ───────────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, PPNodeType) {
    PPNodeWorkspace,
    PPNodeProject,
    PPNodeFolder,
    PPNodeFile,
};

// ── Tree item model ──────────────────────────────────────────────────────────

@interface _ProjectItem : NSObject
@property PPNodeType      type;
@property NSString       *name;           // display name
@property (nullable) NSString *filePath;  // absolute path (files only)
@property (nullable) NSMutableArray<_ProjectItem *> *children;
@property (nullable, weak) _ProjectItem *parent;
@end

@implementation _ProjectItem
- (instancetype)initWithType:(PPNodeType)type name:(NSString *)name {
    self = [super init];
    if (self) {
        _type     = type;
        _name     = [name copy];
        if (type != PPNodeFile)
            _children = [NSMutableArray array];
    }
    return self;
}
@end

// ── Workspace model ──────────────────────────────────────────────────────────

@interface _ProjectWorkspace : NSObject
@property NSString       *filePath;       // path to .workspace XML file, or nil
@property _ProjectItem   *rootItem;       // workspace root node
@property BOOL            isDirty;
@end

@implementation _ProjectWorkspace

- (instancetype)init {
    self = [super init];
    if (self) {
        _rootItem = [[_ProjectItem alloc] initWithType:PPNodeWorkspace name:@"Workspace"];
        _isDirty  = NO;
    }
    return self;
}

#pragma mark - XML Loading

- (BOOL)loadFromPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return NO;

    NSError *err = nil;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:&err];
    if (!doc) return NO;

    NSXMLElement *root = doc.rootElement;
    if (!root || ![root.name isEqualToString:@"NotepadPlus"]) return NO;

    _filePath = [path copy];
    _rootItem = [[_ProjectItem alloc] initWithType:PPNodeWorkspace
                                              name:path.lastPathComponent];

    NSString *wsDir = [path stringByDeletingLastPathComponent];
    for (NSXMLElement *projEl in [root elementsForName:@"Project"]) {
        NSString *projName = [[projEl attributeForName:@"name"] stringValue] ?: @"Project";
        _ProjectItem *projItem = [[_ProjectItem alloc] initWithType:PPNodeProject name:projName];
        projItem.parent = _rootItem;
        [_rootItem.children addObject:projItem];
        [self _buildTreeFrom:projEl parent:projItem wsDir:wsDir];
    }

    _isDirty = NO;
    return YES;
}

- (void)_buildTreeFrom:(NSXMLElement *)xmlNode parent:(_ProjectItem *)parentItem wsDir:(NSString *)wsDir {
    for (NSXMLNode *child in xmlNode.children) {
        if (![child isKindOfClass:[NSXMLElement class]]) continue;
        NSXMLElement *el = (NSXMLElement *)child;

        if ([el.name isEqualToString:@"Folder"]) {
            NSString *folderName = [[el attributeForName:@"name"] stringValue] ?: @"Folder";
            _ProjectItem *folderItem = [[_ProjectItem alloc] initWithType:PPNodeFolder name:folderName];
            folderItem.parent = parentItem;
            [parentItem.children addObject:folderItem];
            [self _buildTreeFrom:el parent:folderItem wsDir:wsDir];

        } else if ([el.name isEqualToString:@"File"]) {
            NSString *rawPath = [[el attributeForName:@"name"] stringValue];
            if (!rawPath.length) continue;

            // Convert Windows paths to macOS
            NSString *converted = [self _convertPath:rawPath wsDir:wsDir];
            NSString *displayName = converted.lastPathComponent;

            _ProjectItem *fileItem = [[_ProjectItem alloc] initWithType:PPNodeFile name:displayName];
            fileItem.filePath = converted;
            fileItem.parent   = parentItem;
            [parentItem.children addObject:fileItem];
        }
    }
}

/// Convert a path from workspace XML to an absolute macOS path.
/// Handles: Windows backslashes, UNC paths, relative paths, absolute macOS paths.
- (NSString *)_convertPath:(NSString *)rawPath wsDir:(NSString *)wsDir {
    // Replace backslashes
    NSString *path = [rawPath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];

    // Already absolute macOS path
    if ([path hasPrefix:@"/"]) return path;

    // Windows absolute path (C:/...) — not resolvable on macOS, keep as-is for display
    if (path.length >= 3 && [[path substringWithRange:NSMakeRange(1, 1)] isEqualToString:@":"]) {
        return path;
    }

    // UNC path (//server/...) — not resolvable on macOS, keep as-is
    if ([path hasPrefix:@"//"]) return path;

    // Relative path — resolve against workspace directory
    return [wsDir stringByAppendingPathComponent:path];
}

/// Calculate relative path from workspace file location.
- (NSString *)_relativePathFor:(NSString *)absPath {
    if (!_filePath) return absPath;
    NSString *wsDir = [_filePath stringByDeletingLastPathComponent];
    if (!wsDir.length) return absPath;

    NSString *wsDirSlash = [wsDir hasSuffix:@"/"] ? wsDir : [wsDir stringByAppendingString:@"/"];
    if ([absPath hasPrefix:wsDirSlash]) {
        return [absPath substringFromIndex:wsDirSlash.length];
    }
    return absPath;
}

#pragma mark - XML Saving

- (BOOL)saveToPath:(NSString *)path {
    NSXMLElement *root = [[NSXMLElement alloc] initWithName:@"NotepadPlus"];
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithRootElement:root];
    doc.characterEncoding = @"UTF-8";

    NSString *savePath = path ?: _filePath;
    if (!savePath) return NO;

    for (_ProjectItem *projItem in _rootItem.children) {
        NSXMLElement *projEl = [[NSXMLElement alloc] initWithName:@"Project"];
        [projEl addAttribute:[NSXMLNode attributeWithName:@"name" stringValue:projItem.name]];
        [self _buildXMLFrom:projItem into:projEl savePath:savePath];
        [root addChild:projEl];
    }

    NSData *xmlData = [doc XMLDataWithOptions:NSXMLNodePrettyPrint];
    NSError *err = nil;
    BOOL ok = [xmlData writeToFile:savePath options:NSDataWritingAtomic error:&err];
    if (ok && (!path || [path isEqualToString:_filePath])) {
        _filePath = [savePath copy];
        _isDirty = NO;
    }
    return ok;
}

- (void)_buildXMLFrom:(_ProjectItem *)item into:(NSXMLElement *)parent savePath:(NSString *)savePath {
    for (_ProjectItem *child in item.children) {
        if (child.type == PPNodeFolder) {
            NSXMLElement *folderEl = [[NSXMLElement alloc] initWithName:@"Folder"];
            [folderEl addAttribute:[NSXMLNode attributeWithName:@"name" stringValue:child.name]];
            [self _buildXMLFrom:child into:folderEl savePath:savePath];
            [parent addChild:folderEl];

        } else if (child.type == PPNodeFile && child.filePath) {
            NSString *storePath = [self _relativePathFor:child.filePath];
            NSXMLElement *fileEl = [[NSXMLElement alloc] initWithName:@"File"];
            [fileEl addAttribute:[NSXMLNode attributeWithName:@"name" stringValue:storePath]];
            [parent addChild:fileEl];
        }
    }
}

#pragma mark - File enumeration (for Find in Projects)

- (NSArray<NSString *> *)allFilePaths {
    NSMutableArray *result = [NSMutableArray array];
    [self _collectFilesFrom:_rootItem into:result];
    return result;
}

- (void)_collectFilesFrom:(_ProjectItem *)item into:(NSMutableArray *)result {
    if (item.type == PPNodeFile && item.filePath) {
        [result addObject:item.filePath];
        return;
    }
    for (_ProjectItem *child in item.children) {
        [self _collectFilesFrom:child into:result];
    }
}

@end

// ── Custom outline view for right-click context menu ─────────────────────────

@interface ProjectPanel ()
- (NSMenu *)_contextMenuForRow:(NSInteger)row;
@end

@interface _PPOutlineView : NSOutlineView
@property (nonatomic, weak) ProjectPanel *ppPanel;
@end

@implementation _PPOutlineView
- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint p   = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:p];
    if (row >= 0) {
        [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    }
    return [_ppPanel _contextMenuForRow:row];
}
@end

// ── Panel button (same style as FolderTreePanel) ─────────────────────────────

@interface _PPPanelButton : NSButton {
    BOOL _hovering;
}
@end

@implementation _PPPanelButton

- (instancetype)init {
    self = [super init];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.bordered = NO;
        self.bezelStyle = NSBezelStyleSmallSquare;
        [self setButtonType:NSButtonTypeMomentaryChange];
        self.imageScaling = NSImageScaleProportionallyDown;
        [self.widthAnchor  constraintEqualToConstant:22].active = YES;
        [self.heightAnchor constraintEqualToConstant:22].active = YES;
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
    if (pressed || _hovering) {
        NSColor *bg  = pressed
            ? [NSColor colorWithRed:0xCC/255.0 green:0xE8/255.0 blue:0xFF/255.0 alpha:1.0]
            : [NSColor colorWithRed:0xE5/255.0 green:0xF3/255.0 blue:0xFF/255.0 alpha:1.0];
        NSColor *bdr = [NSColor colorWithRed:0xD0/255.0 green:0xEA/255.0 blue:0xFF/255.0 alpha:1.0];
        NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:2 yRadius:2];
        [bg setFill]; [fill fill];
        NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                                               xRadius:2 yRadius:2];
        border.lineWidth = 1.0; [bdr setStroke]; [border stroke];
    }
    if (self.image) {
        [self.image drawInRect:NSInsetRect(self.bounds, 3, 3)
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver
                      fraction:1.0
                respectFlipped:YES
                         hints:nil];
    }
}

@end

// ── Constants ────────────────────────────────────────────────────────────────

static NSString * const kTreeviewSubdir = @"icons/standard/panels/treeview";
static NSString * const kPrefWSPath     = @"ProjectPanelWorkspace%ld";  // format with tab index

// Walk a _ProjectItem subtree, appending every PPNodeFile's filePath to `out`.
// File-private (workspaces are virtual XML trees — the items are file-private
// to this TU). Used by "Run Macro on Files…" handlers.
//
// Dedup pass: workspaces can legally reference the same file from multiple
// virtual folders (one physical file appearing twice in the project view).
// Without dedup the batch runner would process the file twice — the first
// pass saves+closes it, the second reopens fresh and runs the macro on the
// just-modified content. Stable order (first-seen wins).
static void _PPCollectFilesInto(_ProjectItem *item, NSMutableArray<NSString *> *out, NSMutableSet<NSString *> *seen) {
    if (!item) return;
    if (item.type == PPNodeFile) {
        NSString *p = item.filePath;
        if (p.length) {
            NSString *canon = p.stringByStandardizingPath;
            if (![seen containsObject:canon]) {
                [seen addObject:canon];
                [out addObject:p];
            }
        }
        return;
    }
    for (_ProjectItem *child in item.children) _PPCollectFilesInto(child, out, seen);
}

static void _PPCollectFiles(_ProjectItem *item, NSMutableArray<NSString *> *out) {
    NSMutableSet *seen = [NSMutableSet set];
    _PPCollectFilesInto(item, out, seen);
}

// ── ProjectPanel ─────────────────────────────────────────────────────────────

@implementation ProjectPanel {
    // 3 workspaces (one per tab)
    _ProjectWorkspace  *_workspaces[3];
    NSInteger           _activeTab;
    CGFloat             _panelFontSize;

    // UI
    NSScrollView       *_scrollView;
    _PPOutlineView     *_outlineView;
    NSSegmentedControl *_tabControl;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        for (int i = 0; i < 3; i++)
            _workspaces[i] = [[_ProjectWorkspace alloc] init];
        _activeTab = 0;
        { CGFloat z = [[NSUserDefaults standardUserDefaults] floatForKey:@"PanelZoom_Project"]; _panelFontSize = z >= 8 ? z : 11; }
        [self _buildUI];
        [self _applyTheme];
        [self _restoreState];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_themeChanged:)
                                                     name:@"NPPPreferencesChanged" object:nil];
    }
    return self;
}

- (instancetype)init { return [self initWithFrame:NSZeroRect]; }

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Public API

- (void)activateTab:(NSInteger)tabIndex {
    if (tabIndex < 0 || tabIndex > 2) return;
    _activeTab = tabIndex;
    _tabControl.selectedSegment = tabIndex;
    [self _updateTitleForActiveWorkspace];
    [_outlineView reloadData];

    // Expand workspace root
    _ProjectItem *root = _workspaces[_activeTab].rootItem;
    if (root) [_outlineView expandItem:root];
}

- (NSInteger)activeTab { return _activeTab; }

- (NSArray<NSString *> *)allFilePathsFromWorkspace:(NSInteger)tabIndex {
    if (tabIndex < 0 || tabIndex > 2) return @[];
    return [_workspaces[tabIndex] allFilePaths];
}

- (BOOL)workspaceHasContent:(NSInteger)tabIndex {
    if (tabIndex < 0 || tabIndex > 2) return NO;
    return _workspaces[tabIndex].filePath.length > 0 &&
           [_workspaces[tabIndex] allFilePaths].count > 0;
}

#pragma mark - UI Construction

- (void)_buildUI {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    // ── OutlineView ──────────────────────────────────────────────────────
    _outlineView = [[_PPOutlineView alloc] init];
    _outlineView.ppPanel    = self;
    _outlineView.dataSource = self;
    _outlineView.delegate   = self;
    _outlineView.rowHeight  = 22;
    _outlineView.headerView = nil;
    _outlineView.indentationPerLevel  = 16;
    _outlineView.autoresizesOutlineColumn = NO;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_outlineView addTableColumn:col];
    _outlineView.outlineTableColumn = col;
    [_outlineView sizeLastColumnToFit];
    _outlineView.target       = self;
    _outlineView.doubleAction = @selector(_doubleClicked:);

    // Register for drag
    [_outlineView registerForDraggedTypes:@[@"dev.npp.project.item"]];
    [_outlineView setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];

    _scrollView = [[NSScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.hasVerticalScroller   = YES;
    _scrollView.hasHorizontalScroller = YES;
    _scrollView.autohidesScrollers    = YES;
    _scrollView.documentView = _outlineView;

    // Expand/collapse icon updates
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(_itemExpandedOrCollapsed:)
               name:NSOutlineViewItemDidExpandNotification  object:_outlineView];
    [nc addObserver:self selector:@selector(_itemExpandedOrCollapsed:)
               name:NSOutlineViewItemDidCollapseNotification object:_outlineView];

    // ── Bottom separator ─────────────────────────────────────────────────
    NSBox *sep2 = [[NSBox alloc] init];
    sep2.boxType = NSBoxSeparator;
    sep2.translatesAutoresizingMaskIntoConstraints = NO;

    // ── Tab control (bottom) ─────────────────────────────────────────────
    _tabControl = [NSSegmentedControl segmentedControlWithLabels:@[@"1", @"2", @"3"]
                                                   trackingMode:NSSegmentSwitchTrackingSelectOne
                                                         target:self
                                                         action:@selector(_tabChanged:)];
    _tabControl.translatesAutoresizingMaskIntoConstraints = NO;
    _tabControl.selectedSegment = 0;
    _tabControl.controlSize = NSControlSizeSmall;
    _tabControl.font = [NSFont systemFontOfSize:10];

    for (NSView *v in @[_scrollView, sep2, _tabControl])
        [self addSubview:v];

    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor     constraintEqualToAnchor:self.topAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scrollView.bottomAnchor  constraintEqualToAnchor:sep2.topAnchor],
        [sep2.leadingAnchor        constraintEqualToAnchor:self.leadingAnchor],
        [sep2.trailingAnchor       constraintEqualToAnchor:self.trailingAnchor],
        [sep2.heightAnchor         constraintEqualToConstant:1],
        [_tabControl.topAnchor     constraintEqualToAnchor:sep2.bottomAnchor constant:2],
        [_tabControl.bottomAnchor  constraintEqualToAnchor:self.bottomAnchor constant:-2],
        [_tabControl.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
    ]];
}

#pragma mark - Theme

- (void)_applyTheme {
    NSColor *bg = [[NPPStyleStore sharedStore] globalBg];
    CGFloat brightness = bg.brightnessComponent;

    self.wantsLayer = YES;
    self.layer.backgroundColor = bg.CGColor;
    _outlineView.backgroundColor = bg;
    _scrollView.backgroundColor  = bg;

    _outlineView.appearance = [NSAppearance appearanceNamed:
        brightness < 0.5 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];

    [_outlineView reloadData];
}

- (void)_themeChanged:(NSNotification *)n { [self _applyTheme]; }

#pragma mark - State Persistence

- (void)_restoreState {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    for (int i = 0; i < 3; i++) {
        NSString *key = [NSString stringWithFormat:kPrefWSPath, (long)i];
        NSString *path = [ud stringForKey:key];
        if (path.length && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [_workspaces[i] loadFromPath:path];
        }
    }
    [self _updateTitleForActiveWorkspace];
    [_outlineView reloadData];
    _ProjectItem *root = _workspaces[_activeTab].rootItem;
    if (root) [_outlineView expandItem:root];
}

- (void)_saveState {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    for (int i = 0; i < 3; i++) {
        NSString *key = [NSString stringWithFormat:kPrefWSPath, (long)i];
        NSString *path = _workspaces[i].filePath;
        if (path.length)
            [ud setObject:path forKey:key];
        else
            [ud removeObjectForKey:key];
    }
}

#pragma mark - Actions

// Called by MainWindowController via its SidePanelHostDelegate hook before
// the panel is removed from the SidePanelHost (either X button or tab
// toggle-off). Flushes any dirty workspaces and persists the active-path
// state keys so reopening restores correctly.
- (void)panelWillClose {
    for (int i = 0; i < 3; i++) {
        if (_workspaces[i].isDirty && _workspaces[i].filePath)
            [_workspaces[i] saveToPath:nil];
    }
    [self _saveState];
}

- (void)_tabChanged:(id)sender {
    [self activateTab:_tabControl.selectedSegment];
}

- (void)_doubleClicked:(id)sender {
    _ProjectItem *item = [_outlineView itemAtRow:_outlineView.clickedRow];
    if (!item) return;

    if (item.type == PPNodeFile && item.filePath) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:item.filePath]) {
            [_delegate projectPanel:self openFileAtPath:item.filePath];
        } else {
            NSBeep();
        }
    } else {
        // Toggle expand/collapse for containers
        if ([_outlineView isItemExpanded:item])
            [_outlineView collapseItem:item];
        else
            [_outlineView expandItem:item];
    }
}

- (void)_itemExpandedOrCollapsed:(NSNotification *)n {
    _ProjectItem *item = n.userInfo[@"NSObject"];
    if (item) {
        NSInteger row = [_outlineView rowForItem:item];
        if (row >= 0) [_outlineView reloadItem:item];
    }
}

- (void)_updateTitleForActiveWorkspace {
    // Workspace identity is carried by the outline root node's label + icon
    // (project_work_space vs project_work_space_dirty). The PanelFrame chrome
    // title stays generic ("Project Panel") — the segment control at the
    // bottom already indicates which of the three workspace slots is active.
}

#pragma mark - Helper: icon loading

- (NSImage *)_treeviewIcon:(NSString *)name {
    NSString *subdir = kTreeviewSubdir;
    // Use dark icons if dark mode
    if ([NppThemeManager shared].isDark) {
        subdir = @"icons/dark/panels/treeview";
    }
    NSURL *url = [[NSBundle mainBundle] URLForResource:name withExtension:@"png"
                                          subdirectory:subdir];
    NSImage *img = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
    if (img) img.size = NSMakeSize(16, 16);
    return img;
}

#pragma mark - Context Menus

- (NSMenu *)_contextMenuForRow:(NSInteger)row {
    _ProjectItem *item = row >= 0 ? [_outlineView itemAtRow:row] : nil;
    if (!item) return nil;

    switch (item.type) {
        case PPNodeWorkspace: return [self _workspaceMenu];
        case PPNodeProject:   return [self _projectMenu];
        case PPNodeFolder:    return [self _folderMenu];
        case PPNodeFile:      return [self _fileMenu];
    }
    return nil;
}

- (NSMenu *)_workspaceMenu {
    NppLocalizer *loc = [NppLocalizer shared];
    NSMenu *m = [[NSMenu alloc] init];
    [m addItemWithTitle:[loc translate:@"New Workspace"]     action:@selector(_newWorkspace:)     keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Open Workspace"]    action:@selector(_openWorkspace:)    keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Reload Workspace"]  action:@selector(_reloadWorkspace:)  keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:[loc translate:@"Save"]              action:@selector(_saveWorkspace:)    keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Save As..."]        action:@selector(_saveWorkspaceAs:)  keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Save a Copy As..."] action:@selector(_saveCopyAs:)       keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:[loc translate:@"Add New Project"]   action:@selector(_addProject:)       keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:[loc translate:@"Find in Projects..."] action:@selector(_findInProjects:) keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Run Macro on Files..."] action:@selector(_runMacroOnWorkspace:) keyEquivalent:@""];
    for (NSMenuItem *mi in m.itemArray) mi.target = self;
    return m;
}

- (NSMenu *)_projectMenu {
    NppLocalizer *loc = [NppLocalizer shared];
    NSMenu *m = [[NSMenu alloc] init];
    [m addItemWithTitle:[loc translate:@"Move Up"]       action:@selector(_moveUp:)         keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Move Down"]     action:@selector(_moveDown:)       keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:[loc translate:@"Rename"]        action:@selector(_rename:)         keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Add Folder"]    action:@selector(_addFolder:)      keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Add Files..."]  action:@selector(_addFiles:)       keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Add Files from Directory..."] action:@selector(_addFilesFromDir:) keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:[loc translate:@"Run Macro on Files..."] action:@selector(_runMacroOnSubtree:) keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:[loc translate:@"Remove"]        action:@selector(_removeItem:)     keyEquivalent:@""];
    for (NSMenuItem *mi in m.itemArray) mi.target = self;
    return m;
}

- (NSMenu *)_folderMenu {
    // Same as project menu — _runMacroOnSubtree: handles both by collecting
    // files under whichever node is currently selected.
    return [self _projectMenu];
}

- (NSMenu *)_fileMenu {
    NppLocalizer *loc = [NppLocalizer shared];
    NSMenu *m = [[NSMenu alloc] init];
    [m addItemWithTitle:[loc translate:@"Move Up"]          action:@selector(_moveUp:)         keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Move Down"]        action:@selector(_moveDown:)       keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:[loc translate:@"Rename"]           action:@selector(_rename:)         keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Remove"]           action:@selector(_removeItem:)     keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Modify File Path"] action:@selector(_modifyFilePath:) keyEquivalent:@""];
    for (NSMenuItem *mi in m.itemArray) mi.target = self;
    return m;
}

#pragma mark - Workspace Operations

- (void)_newWorkspace:(id)sender {
    _ProjectWorkspace *ws = _workspaces[_activeTab];
    if (ws.isDirty) {
        if (![self _promptSaveDirtyWorkspace:ws]) return;
    }
    _workspaces[_activeTab] = [[_ProjectWorkspace alloc] init];
    [self _updateTitleForActiveWorkspace];
    [_outlineView reloadData];
    [_outlineView expandItem:_workspaces[_activeTab].rootItem];
    [self _saveState];
}

- (void)_openWorkspace:(id)sender {
    _ProjectWorkspace *ws = _workspaces[_activeTab];
    if (ws.isDirty) {
        if (![self _promptSaveDirtyWorkspace:ws]) return;
    }

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = @[@"workspace", @"Workspace"];
    panel.allowsMultipleSelection = NO;
    if ([panel runModal] != NSModalResponseOK) return;

    NSString *path = panel.URL.path;
    _ProjectWorkspace *newWS = [[_ProjectWorkspace alloc] init];
    if ([newWS loadFromPath:path]) {
        _workspaces[_activeTab] = newWS;
        [self _updateTitleForActiveWorkspace];
        [_outlineView reloadData];
        [_outlineView expandItem:newWS.rootItem];
        [self _saveState];
    }
}

- (void)_reloadWorkspace:(id)sender {
    _ProjectWorkspace *ws = _workspaces[_activeTab];
    if (!ws.filePath) return;
    _ProjectWorkspace *reloaded = [[_ProjectWorkspace alloc] init];
    if ([reloaded loadFromPath:ws.filePath]) {
        _workspaces[_activeTab] = reloaded;
        [self _updateTitleForActiveWorkspace];
        [_outlineView reloadData];
        [_outlineView expandItem:reloaded.rootItem];
    }
}

- (void)_saveWorkspace:(id)sender {
    _ProjectWorkspace *ws = _workspaces[_activeTab];
    if (!ws.filePath) {
        [self _saveWorkspaceAs:sender];
        return;
    }
    [ws saveToPath:nil];
    [self _updateTitleForActiveWorkspace];
    [_outlineView reloadItem:ws.rootItem];
}

- (void)_saveWorkspaceAs:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[@"workspace"];
    panel.nameFieldStringValue = _workspaces[_activeTab].rootItem.name ?: @"project";
    if ([panel runModal] != NSModalResponseOK) return;

    _ProjectWorkspace *ws = _workspaces[_activeTab];
    [ws saveToPath:panel.URL.path];
    ws.filePath = panel.URL.path;
    ws.rootItem.name = panel.URL.lastPathComponent;
    ws.isDirty = NO;
    [self _updateTitleForActiveWorkspace];
    [_outlineView reloadItem:ws.rootItem];
    [self _saveState];
}

- (void)_saveCopyAs:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[@"workspace"];
    panel.nameFieldStringValue = _workspaces[_activeTab].rootItem.name ?: @"project";
    if ([panel runModal] != NSModalResponseOK) return;

    _ProjectWorkspace *ws = _workspaces[_activeTab];
    [ws saveToPath:panel.URL.path];
    // Don't update filePath — this is a copy, not a rename
}

- (BOOL)_promptSaveDirtyWorkspace:(_ProjectWorkspace *)ws {
    NppLocalizer *loc = [NppLocalizer shared];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [loc translate:@"The workspace was modified."];
    alert.informativeText = [loc translate:@"Do you want to save changes?"];
    [alert addButtonWithTitle:[loc translate:@"Save"]];
    [alert addButtonWithTitle:[loc translate:@"Don't Save"]];
    [alert addButtonWithTitle:[loc translate:@"Cancel"]];
    NSModalResponse resp = [alert runModal];
    if (resp == NSAlertFirstButtonReturn) {
        if (ws.filePath)
            [ws saveToPath:nil];
        else
            return NO; // Would need save-as, treat as cancel for simplicity
        return YES;
    } else if (resp == NSAlertSecondButtonReturn) {
        return YES; // Discard
    }
    return NO; // Cancel
}

#pragma mark - Edit Operations

- (void)_addProject:(id)sender {
    _ProjectWorkspace *ws = _workspaces[_activeTab];
    _ProjectItem *proj = [[_ProjectItem alloc] initWithType:PPNodeProject name:@"New Project"];
    proj.parent = ws.rootItem;
    [ws.rootItem.children addObject:proj];
    [self _markDirty];
    [_outlineView reloadData];
    [_outlineView expandItem:ws.rootItem];

    // Begin inline edit
    NSInteger row = [_outlineView rowForItem:proj];
    if (row >= 0) {
        [_outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_outlineView editColumn:0 row:row withEvent:nil select:YES];
        });
    }
}

- (void)_addFolder:(id)sender {
    _ProjectItem *parent = [self _selectedItem];
    if (!parent || (parent.type != PPNodeProject && parent.type != PPNodeFolder)) return;

    _ProjectItem *folder = [[_ProjectItem alloc] initWithType:PPNodeFolder name:@"New Folder"];
    folder.parent = parent;
    [parent.children addObject:folder];
    [self _markDirty];
    [_outlineView reloadItem:parent reloadChildren:YES];
    [_outlineView expandItem:parent];

    NSInteger row = [_outlineView rowForItem:folder];
    if (row >= 0) {
        [_outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_outlineView editColumn:0 row:row withEvent:nil select:YES];
        });
    }
}

- (void)_addFiles:(id)sender {
    _ProjectItem *parent = [self _selectedItem];
    if (!parent || (parent.type != PPNodeProject && parent.type != PPNodeFolder)) return;

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    if ([panel runModal] != NSModalResponseOK) return;

    for (NSURL *url in panel.URLs) {
        NSString *path = url.path;
        _ProjectItem *fileItem = [[_ProjectItem alloc] initWithType:PPNodeFile
                                                               name:path.lastPathComponent];
        fileItem.filePath = path;
        fileItem.parent   = parent;
        [parent.children addObject:fileItem];
    }
    [self _markDirty];
    [_outlineView reloadItem:parent reloadChildren:YES];
    [_outlineView expandItem:parent];
}

- (void)_addFilesFromDir:(id)sender {
    _ProjectItem *parent = [self _selectedItem];
    if (!parent || (parent.type != PPNodeProject && parent.type != PPNodeFolder)) return;

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    if ([panel runModal] != NSModalResponseOK) return;

    NSString *dirPath = panel.URL.path;
    [self _recursiveAddFrom:dirPath into:parent];
    [self _markDirty];
    [_outlineView reloadItem:parent reloadChildren:YES];
    [_outlineView expandItem:parent];
}

- (void)_recursiveAddFrom:(NSString *)dirPath into:(_ProjectItem *)parent {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:dirPath error:nil];
    if (!contents) return;

    // Sort: directories first, then files, alphabetically within each group
    NSMutableArray *dirs  = [NSMutableArray array];
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *name in contents) {
        if ([name hasPrefix:@"."]) continue; // skip hidden files
        NSString *fullPath = [dirPath stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        [fm fileExistsAtPath:fullPath isDirectory:&isDir];
        if (isDir)
            [dirs addObject:name];
        else
            [files addObject:name];
    }
    [dirs sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [files sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    for (NSString *dirName in dirs) {
        NSString *subPath = [dirPath stringByAppendingPathComponent:dirName];
        _ProjectItem *folder = [[_ProjectItem alloc] initWithType:PPNodeFolder name:dirName];
        folder.parent = parent;
        [parent.children addObject:folder];
        [self _recursiveAddFrom:subPath into:folder];
    }

    for (NSString *fileName in files) {
        NSString *filePath = [dirPath stringByAppendingPathComponent:fileName];
        _ProjectItem *fileItem = [[_ProjectItem alloc] initWithType:PPNodeFile name:fileName];
        fileItem.filePath = filePath;
        fileItem.parent   = parent;
        [parent.children addObject:fileItem];
    }
}

- (void)_removeItem:(id)sender {
    _ProjectItem *item = [self _selectedItem];
    if (!item || item.type == PPNodeWorkspace) return;

    _ProjectItem *parent = item.parent;
    if (!parent) return;

    // Confirm if has children
    if (item.children.count > 0) {
        NppLocalizer *loc = [NppLocalizer shared];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithFormat:@"Remove \"%@\"?", item.name];
        alert.informativeText = [loc translate:@"This will remove it and all its contents from the project. No files on disk will be affected."];
        [alert addButtonWithTitle:[loc translate:@"Remove"]];
        [alert addButtonWithTitle:[loc translate:@"Cancel"]].keyEquivalent = @"\033";
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }

    [parent.children removeObject:item];
    [self _markDirty];
    [_outlineView reloadItem:parent reloadChildren:YES];
}

- (void)_moveUp:(id)sender {
    _ProjectItem *item = [self _selectedItem];
    if (!item || !item.parent) return;
    NSMutableArray *siblings = item.parent.children;
    NSUInteger idx = [siblings indexOfObject:item];
    if (idx == 0 || idx == NSNotFound) return;
    [siblings exchangeObjectAtIndex:idx withObjectAtIndex:idx - 1];
    [self _markDirty];
    [_outlineView reloadItem:item.parent reloadChildren:YES];
    NSInteger row = [_outlineView rowForItem:item];
    if (row >= 0) [_outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
}

- (void)_moveDown:(id)sender {
    _ProjectItem *item = [self _selectedItem];
    if (!item || !item.parent) return;
    NSMutableArray *siblings = item.parent.children;
    NSUInteger idx = [siblings indexOfObject:item];
    if (idx >= siblings.count - 1 || idx == NSNotFound) return;
    [siblings exchangeObjectAtIndex:idx withObjectAtIndex:idx + 1];
    [self _markDirty];
    [_outlineView reloadItem:item.parent reloadChildren:YES];
    NSInteger row = [_outlineView rowForItem:item];
    if (row >= 0) [_outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
}

- (void)_rename:(id)sender {
    NSInteger row = _outlineView.selectedRow;
    if (row < 0) return;
    [_outlineView editColumn:0 row:row withEvent:nil select:YES];
}

- (void)_modifyFilePath:(id)sender {
    _ProjectItem *item = [self _selectedItem];
    if (!item || item.type != PPNodeFile) return;

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    if (item.filePath) {
        panel.directoryURL = [NSURL fileURLWithPath:item.filePath.stringByDeletingLastPathComponent];
    }
    if ([panel runModal] != NSModalResponseOK) return;

    item.filePath = panel.URL.path;
    item.name     = panel.URL.lastPathComponent;
    [self _markDirty];
    [_outlineView reloadItem:item];
}

- (void)_findInProjects:(id)sender {
    _ProjectWorkspace *ws = _workspaces[_activeTab];
    // Use the workspace file's directory, or home if none
    NSString *dir = ws.filePath.stringByDeletingLastPathComponent ?: NSHomeDirectory();
    [_delegate projectPanel:self findInFilesAtPath:dir];
}

// ── Run Macro on Files (Project Panel) ───────────────────────────────────
// Workspaces are *virtual* XML trees — files inside one project can live in
// completely different directories on disk, so we can't hand the dialog a
// folder path. Instead we walk the selected subtree, flatten it to a list
// of absolute paths, and present the dialog in fixed-file-list mode. The
// dialog's extension filter still narrows the list (handy when a project
// contains both .cpp and .png and you only want the .cpp files).

- (void)_runMacroOnWorkspace:(id)sender {
    if (![_delegate respondsToSelector:@selector(projectPanel:runMacroOnFiles:sourceDescription:)]) return;
    _ProjectWorkspace *ws = _workspaces[_activeTab];
    NSMutableArray *files = [NSMutableArray array];
    _PPCollectFiles(ws.rootItem, files);
    NSString *desc = [NSString stringWithFormat:@"%@: %@",
                       [[NppLocalizer shared] translate:@"Workspace"],
                       ws.rootItem.name ?: @""];
    [_delegate projectPanel:self runMacroOnFiles:files sourceDescription:desc];
}

- (void)_runMacroOnSubtree:(id)sender {
    if (![_delegate respondsToSelector:@selector(projectPanel:runMacroOnFiles:sourceDescription:)]) return;
    _ProjectItem *item = [self _selectedItem];
    if (!item) return;
    NSMutableArray *files = [NSMutableArray array];
    _PPCollectFiles(item, files);

    NppLocalizer *loc = [NppLocalizer shared];
    NSString *kind = (item.type == PPNodeProject) ? [loc translate:@"Project"]
                                                   : [loc translate:@"Folder"];
    NSString *desc = [NSString stringWithFormat:@"%@: %@", kind, item.name ?: @""];
    [_delegate projectPanel:self runMacroOnFiles:files sourceDescription:desc];
}

#pragma mark - Helpers

- (_ProjectItem *)_selectedItem {
    NSInteger row = _outlineView.selectedRow;
    if (row < 0) return nil;
    return [_outlineView itemAtRow:row];
}

- (void)_markDirty {
    _workspaces[_activeTab].isDirty = YES;
    [self _updateTitleForActiveWorkspace];
    // Update root icon
    [_outlineView reloadItem:_workspaces[_activeTab].rootItem];
}

#pragma mark - NSOutlineViewDataSource

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    if (!item) return 1; // root workspace item
    _ProjectItem *pi = (_ProjectItem *)item;
    return (NSInteger)pi.children.count;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item {
    if (!item) return _workspaces[_activeTab].rootItem;
    _ProjectItem *pi = (_ProjectItem *)item;
    return pi.children[index];
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
    _ProjectItem *pi = (_ProjectItem *)item;
    return pi.type != PPNodeFile;
}

#pragma mark - Drag & Drop

- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *)ov
                pasteboardWriterForItem:(id)item {
    _ProjectItem *pi = (_ProjectItem *)item;
    // Don't allow dragging workspace root or projects
    if (pi.type == PPNodeWorkspace || pi.type == PPNodeProject) return nil;

    NSPasteboardItem *pb = [[NSPasteboardItem alloc] init];
    // Use the pointer as a unique ID within this process
    [pb setString:[NSString stringWithFormat:@"%p", item] forType:@"dev.npp.project.item"];
    return pb;
}

- (NSDragOperation)outlineView:(NSOutlineView *)ov
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)proposedParent
            proposedChildIndex:(NSInteger)index {
    _ProjectItem *target = (_ProjectItem *)proposedParent;
    if (!target) return NSDragOperationNone;
    // Can only drop into projects or folders
    if (target.type == PPNodeFile) return NSDragOperationNone;
    return NSDragOperationMove;
}

- (BOOL)outlineView:(NSOutlineView *)ov
         acceptDrop:(id<NSDraggingInfo>)info
               item:(id)targetItem
         childIndex:(NSInteger)index {
    NSPasteboard *pb = info.draggingPasteboard;
    NSString *ptrStr = [pb stringForType:@"dev.npp.project.item"];
    if (!ptrStr) return NO;

    // Find the dragged item by pointer string
    _ProjectItem *draggedItem = nil;
    void *ptr = NULL;
    sscanf(ptrStr.UTF8String, "%p", &ptr);
    draggedItem = (__bridge _ProjectItem *)ptr;
    if (!draggedItem || !draggedItem.parent) return NO;

    _ProjectItem *target = (_ProjectItem *)targetItem;
    if (!target || target.type == PPNodeFile) return NO;

    // Don't drop onto self or descendant
    _ProjectItem *check = target;
    while (check) {
        if (check == draggedItem) return NO;
        check = check.parent;
    }

    // Remove from old parent
    [draggedItem.parent.children removeObject:draggedItem];

    // Insert at target
    if (index >= 0 && index <= (NSInteger)target.children.count)
        [target.children insertObject:draggedItem atIndex:index];
    else
        [target.children addObject:draggedItem];
    draggedItem.parent = target;

    [self _markDirty];
    [_outlineView reloadData];
    [_outlineView expandItem:target];

    NSInteger row = [_outlineView rowForItem:draggedItem];
    if (row >= 0) [_outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    return YES;
}

#pragma mark - NSOutlineViewDelegate

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    _ProjectItem *pi = (_ProjectItem *)item;

    NSTableCellView *cell = [ov makeViewWithIdentifier:@"PPCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        cell.identifier = @"PPCell";

        NSImageView *iv = [[NSImageView alloc] init];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        [iv.widthAnchor  constraintEqualToConstant:16].active = YES;
        [iv.heightAnchor constraintEqualToConstant:16].active = YES;
        cell.imageView = iv;

        NSTextField *tf = [NSTextField textFieldWithString:@""];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.bordered    = NO;
        tf.editable    = YES;
        tf.drawsBackground = NO;
        tf.font        = [NSFont systemFontOfSize:12];
        tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
        tf.delegate    = (id<NSTextFieldDelegate>)self;
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

    cell.textField.stringValue = pi.name;
    cell.textField.textColor   = [[NPPStyleStore sharedStore] globalFg];

    // Workspace root: not user-editable name (use context menu rename)
    cell.textField.editable = (pi.type != PPNodeWorkspace);

    // Icon
    NSImage *icon = nil;
    BOOL expanded = [ov isItemExpanded:pi];

    switch (pi.type) {
        case PPNodeWorkspace:
            icon = [self _treeviewIcon:_workspaces[_activeTab].isDirty
                        ? @"project_work_space_dirty" : @"project_work_space"];
            break;
        case PPNodeProject:
            icon = [self _treeviewIcon:@"project_root"];
            break;
        case PPNodeFolder:
            icon = [self _treeviewIcon:expanded ? @"project_folder_open" : @"project_folder_close"];
            break;
        case PPNodeFile: {
            BOOL exists = pi.filePath && [[NSFileManager defaultManager] fileExistsAtPath:pi.filePath];
            icon = [self _treeviewIcon:exists ? @"project_file" : @"project_file_invalid"];
            break;
        }
    }
    cell.imageView.image = icon;
    cell.textField.font = [NSFont systemFontOfSize:_panelFontSize];
    for (NSLayoutConstraint *c in cell.imageView.constraints) {
        if (c.firstAttribute == NSLayoutAttributeWidth || c.firstAttribute == NSLayoutAttributeHeight)
            c.constant = _panelFontSize + 4;
    }
    return cell;
}

- (CGFloat)outlineView:(NSOutlineView *)ov heightOfRowByItem:(id)item {
    return _panelFontSize + 10;
}

#pragma mark - NSTextFieldDelegate (inline rename)

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    NSTextField *tf = obj.object;
    NSInteger row = [_outlineView rowForView:tf];
    if (row < 0) return;

    _ProjectItem *item = [_outlineView itemAtRow:row];
    if (!item) return;

    NSString *newName = tf.stringValue;
    if (!newName.length) {
        tf.stringValue = item.name; // revert
        return;
    }

    if (![newName isEqualToString:item.name]) {
        item.name = newName;
        // For files, update the filePath to reflect the new filename
        if (item.type == PPNodeFile && item.filePath) {
            NSString *dir = item.filePath.stringByDeletingLastPathComponent;
            item.filePath = [dir stringByAppendingPathComponent:newName];
        }
        [self _markDirty];
        [_outlineView reloadItem:item];
    }
}

#pragma mark - Keyboard

- (void)keyDown:(NSEvent *)event {
    // Handle Delete key for remove, and arrow keys with modifiers for move
    unichar ch = event.characters.length > 0 ? [event.characters characterAtIndex:0] : 0;

    if (ch == NSDeleteCharacter || ch == NSBackspaceCharacter) {
        [self _removeItem:nil];
        return;
    }

    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (mods & NSEventModifierFlagCommand) {
        if (ch == NSUpArrowFunctionKey) { [self _moveUp:nil]; return; }
        if (ch == NSDownArrowFunctionKey) { [self _moveDown:nil]; return; }
    }

    [super keyDown:event];
}

#pragma mark - Panel Zoom

- (void)_saveZoom { [[NSUserDefaults standardUserDefaults] setFloat:_panelFontSize forKey:@"PanelZoom_Project"]; }
- (void)panelZoomIn    { _panelFontSize = MIN(_panelFontSize + 1, 28); [_outlineView reloadData]; [_outlineView noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [_outlineView numberOfRows])]]; [self _saveZoom]; }
- (void)panelZoomOut   { _panelFontSize = MAX(_panelFontSize - 1, 8);  [_outlineView reloadData]; [_outlineView noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [_outlineView numberOfRows])]]; [self _saveZoom]; }
- (void)panelZoomReset { _panelFontSize = 11; [_outlineView reloadData]; [_outlineView noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [_outlineView numberOfRows])]]; [self _saveZoom]; }

@end
