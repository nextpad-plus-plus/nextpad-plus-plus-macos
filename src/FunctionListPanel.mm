#import "NppParserRegex.h"
#import "FunctionListPanel.h"
#import "NppPaths.h"
#import "NppLocalizer.h"
#import "StyleConfiguratorWindowController.h"
#import "PreferencesWindowController.h"
#import "Scintilla.h"
#import "ScintillaMessages.h"
#import "NppThemeManager.h"

// ── Data model: tree item (node = class/struct, leaf = function/method) ──────

@interface _FuncItem : NSObject
@property (nonatomic, copy)   NSString *name;
@property (nonatomic)         NSInteger line;      // 1-based
@property (nonatomic)         NSInteger pos;       // byte offset in document
@property (nonatomic)         BOOL isNode;         // YES = class/struct/protocol
@property (nonatomic, strong) NSMutableArray<_FuncItem *> *children;
@end

@implementation _FuncItem
- (instancetype)initWithName:(NSString *)name line:(NSInteger)line pos:(NSInteger)pos isNode:(BOOL)isNode {
    self = [super init];
    if (self) {
        _name = [name copy];
        _line = line;
        _pos  = pos;
        _isNode = isNode;
        _children = isNode ? [NSMutableArray array] : nil;
    }
    return self;
}
@end

// ── Lightweight XML node (preserves newlines in attribute values) ─────────────

@interface _FLNode : NSObject
@property (nonatomic, copy) NSString *tagName;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *attrs;
@property (nonatomic, strong) NSMutableArray<_FLNode *> *children;
@property (nonatomic, weak) _FLNode *parent;
- (NSString *)attr:(NSString *)name;
- (NSArray<_FLNode *> *)childrenWithTag:(NSString *)tag;
- (NSArray<_FLNode *> *)descendantsAtPath:(NSString *)path;
@end

@implementation _FLNode
- (instancetype)init {
    self = [super init];
    if (self) {
        _attrs = [NSMutableDictionary new];
        _children = [NSMutableArray new];
    }
    return self;
}
- (NSString *)attr:(NSString *)name { return _attrs[name]; }
- (NSArray<_FLNode *> *)childrenWithTag:(NSString *)tag {
    NSMutableArray *r = [NSMutableArray new];
    for (_FLNode *c in _children)
        if ([c.tagName isEqualToString:tag]) [r addObject:c];
    return r;
}
- (NSArray<_FLNode *> *)descendantsAtPath:(NSString *)path {
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    NSArray<_FLNode *> *current = @[self];
    for (NSString *part in parts) {
        NSMutableArray *next = [NSMutableArray new];
        for (_FLNode *n in current)
            [next addObjectsFromArray:[n childrenWithTag:part]];
        current = next;
        if (!current.count) return @[];
    }
    return current;
}
@end

// ── Title-bar close button ───────────────────────────────────────────────────
// Mirrors _DMPCloseButton in DocumentMapPanel.mm: permanent 1px light-grey
// square border at rest, toolbar-style blue on hover/press. In dark mode the
// light-blue fill is skipped (looks wrong on a dark bar); only the border
// color changes.
// Phase 2: close button provided by PanelFrame.

// ── Title-bar hover button (for sort / reload) ───────────────────────────────
// Draws its image normally at rest — invisible chrome. On hover/press it
// adds the toolbar-blue fill + border (fill skipped in dark mode so it
// doesn't clash with the dark title strip).
@interface _FLPHoverButton : NSButton { BOOL _hovering; }
@end

@implementation _FLPHoverButton

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.bordered = NO;
        self.buttonType = NSButtonTypeMomentaryChange;
        self.imageScaling = NSImageScaleProportionallyDown;
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
        // Draw the image centered at its own .size — NOT scaled to fit the
        // button bounds. This is what makes kFLToolbarIconSize actually
        // control the visible icon size; otherwise drawInRect would stretch
        // every image to fill the 16×16 button.
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

// ── Panel button helper (same pattern as FolderTreePanel / GitPanel) ─────────

// Sort / Reload button metrics.
// Button frame matches the close button (16×16) so the hover border is the
// same size across all three title-bar controls. The icon itself stays
// small (6pt — the "40% smaller" visual per user), centered with whitespace.
static const CGFloat kFLToolbarBtnSize  = 16;
static const CGFloat kFLToolbarIconSize = 11;

// Pick the toolbar icon subdirectory based on the current theme. The dark
// variants are pre-rendered lighter so they stay readable on a dark bar.
static NSString *_FLToolbarIconSubdir(void) {
    return [NppThemeManager shared].isDark
        ? @"icons/dark/panels/toolbar"
        : @"icons/standard/panels/toolbar";
}

static NSImage *_FLLoadToolbarIcon(NSString *iconName, CGFloat size) {
    NSURL *url = [[NSBundle mainBundle] URLForResource:iconName withExtension:@"png"
                                          subdirectory:_FLToolbarIconSubdir()];
    NSImage *img = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
    if (img) img.size = NSMakeSize(size, size);
    return img;
}

static NSButton *_flPanelBtn(NSString *iconName, NSString *tip,
                              CGFloat btnSize, CGFloat iconSize,
                              id target, SEL action) {
    _FLPHoverButton *btn = [[_FLPHoverButton alloc] initWithFrame:NSZeroRect];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.toolTip    = tip;
    btn.target     = target;
    btn.action     = action;
    [btn.widthAnchor  constraintEqualToConstant:btnSize].active = YES;
    [btn.heightAnchor constraintEqualToConstant:btnSize].active = YES;
    NSImage *img = _FLLoadToolbarIcon(iconName, iconSize);
    if (img) {
        btn.image = img;
    } else {
        btn.title = @"?";
    }
    return btn;
}

// ── FunctionListPanel ────────────────────────────────────────────────────────

@implementation FunctionListPanel {
    // Search-row toolbar (PanelFrame supplies title bar + close).
    NSButton     *_sortButton;
    NSButton     *_reloadButton;

    // Search field
    NSTextField  *_searchField;

    // Tree
    NSScrollView   *_scrollView;
    NSOutlineView  *_outlineView;

    // Data
    NSMutableArray<_FuncItem *> *_rootItems;     // full tree
    NSMutableArray<_FuncItem *> *_filteredItems;  // search-filtered tree
    CGFloat _panelFontSize;
    __weak EditorView *_editor;

    // State
    BOOL _sortAlpha;  // YES = alphabetical, NO = document order
    NSString *_searchText;

    // Icons
    NSImage *_leafIcon;
    NSImage *_nodeIcon;

    // Empty state
    NSTextField *_emptyLabel;

    // Background scanning
    NSUInteger _scanGeneration;         // incremented on each loadEditor, cancels stale scans

    // Line offset table (built once per scan, used for O(log n) line lookups)
    NSUInteger *_lineOffsets;           // array of byte offsets where each line starts
    NSUInteger  _lineOffsetCount;       // number of lines
}

// dealloc is below (after init) — _lineOffsets freed there

#pragma mark - Init

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _rootItems    = [NSMutableArray array];
        _filteredItems = [NSMutableArray array];
        { CGFloat z = [[NSUserDefaults standardUserDefaults] floatForKey:@"PanelZoom_FunctionList"]; _panelFontSize = z >= 8 ? z : 11; }
        _searchText   = @"";
        [self _loadIcons];
        [self _buildLayout];
        [self retranslateUI];
        [self _applyTheme];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_locChanged:)
                                                     name:NPPLocalizationChanged object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_themeChanged:)
                                                     name:@"NPPPreferencesChanged" object:nil];
        // PanelFrame owns the title-bar repaint for dark mode; we still
        // need our own icon refresh on that event.
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_refreshToolbarIcons)
                                                     name:NPPDarkModeChangedNotification object:nil];
    }
    return self;
}

- (instancetype)init { return [self initWithFrame:NSZeroRect]; }

- (void)dealloc {
    free(_lineOffsets);
    _lineOffsets = NULL;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Icons

- (void)_loadIcons {
    NSURL *leafURL = [[NSBundle mainBundle] URLForResource:@"funcList_leaf" withExtension:@"png"
                                              subdirectory:@"icons/standard/panels/treeview"];
    NSURL *nodeURL = [[NSBundle mainBundle] URLForResource:@"funcList_node" withExtension:@"png"
                                              subdirectory:@"icons/standard/panels/treeview"];
    _leafIcon = leafURL ? [[NSImage alloc] initWithContentsOfURL:leafURL] : nil;
    _nodeIcon = nodeURL ? [[NSImage alloc] initWithContentsOfURL:nodeURL] : nil;
    _leafIcon.size = NSMakeSize(14, 14);
    _nodeIcon.size = NSMakeSize(14, 14);
}

#pragma mark - Layout

- (void)_buildLayout {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    // Phase 2: title bar + close button supplied by PanelFrame. The Sort
    // and Reload buttons move out of the old title bar and into the
    // search row, right-aligned (per Windows/macOS parity spec).

    _sortButton = _flPanelBtn(@"funclstSort", @"Sort functions (A to Z)",
                               kFLToolbarBtnSize, kFLToolbarIconSize,
                               self, @selector(_toggleSort:));
    [self addSubview:_sortButton];

    _reloadButton = _flPanelBtn(@"funclstReload", @"Reload",
                                 kFLToolbarBtnSize, kFLToolbarIconSize,
                                 self, @selector(_reload:));
    [self addSubview:_reloadButton];

    // ── Search field ─────────────────────────────────────────────────────────
    _searchField = [[NSTextField alloc] init];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.placeholderString = @"Search function...";
    _searchField.font = [NSFont systemFontOfSize:11];
    _searchField.delegate = self;
    _searchField.bezelStyle = NSTextFieldRoundedBezel;
    [[_searchField cell] setScrollable:YES];
    [self addSubview:_searchField];

    // ── Outline view (tree) ──────────────────────────────────────────────────
    _outlineView = [[NSOutlineView alloc] init];
    _outlineView.headerView = nil;
    _outlineView.rowHeight = 19;
    _outlineView.indentationPerLevel = 16;
    _outlineView.intercellSpacing = NSMakeSize(0, 1);
    _outlineView.allowsMultipleSelection = NO;
    _outlineView.dataSource = self;
    _outlineView.delegate = self;
    _outlineView.autoresizesOutlineColumn = YES;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"func"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_outlineView addTableColumn:col];
    _outlineView.outlineTableColumn = col;

    _scrollView = [[NSScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.borderType = NSNoBorder;
    _scrollView.documentView = _outlineView;
    [self addSubview:_scrollView];

    // ── Empty label ──────────────────────────────────────────────────────────
    _emptyLabel = [NSTextField labelWithString:@"No functions found"];
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.textColor = [NSColor secondaryLabelColor];
    _emptyLabel.hidden = YES;
    [self addSubview:_emptyLabel];

    // ── Constraints ──────────────────────────────────────────────────────────
    // Search row: [search expandable] [sort 16×16] [reload 16×16]. Sort +
    // Reload right-aligned. 6pt leading/trailing gutters match Windows.
    [NSLayoutConstraint activateConstraints:@[
        [_searchField.topAnchor      constraintEqualToAnchor:self.topAnchor constant:4],
        [_searchField.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor constant:6],
        [_searchField.trailingAnchor constraintEqualToAnchor:_sortButton.leadingAnchor constant:-6],
        [_searchField.heightAnchor   constraintEqualToConstant:22],

        [_sortButton.trailingAnchor  constraintEqualToAnchor:_reloadButton.leadingAnchor constant:-2],
        [_sortButton.centerYAnchor   constraintEqualToAnchor:_searchField.centerYAnchor],
        [_reloadButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
        [_reloadButton.centerYAnchor  constraintEqualToAnchor:_searchField.centerYAnchor],

        [_scrollView.topAnchor      constraintEqualToAnchor:_searchField.bottomAnchor constant:4],
        [_scrollView.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scrollView.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],

        [_emptyLabel.centerXAnchor constraintEqualToAnchor:_scrollView.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:_scrollView.centerYAnchor],
    ]];
}

#pragma mark - Theme

- (void)_themeChanged:(NSNotification *)n { [self _applyTheme]; }

- (void)_refreshToolbarIcons {
    _sortButton.image   = _FLLoadToolbarIcon(@"funclstSort",   kFLToolbarIconSize);
    _reloadButton.image = _FLLoadToolbarIcon(@"funclstReload", kFLToolbarIconSize);
    [_sortButton   setNeedsDisplay:YES];
    [_reloadButton setNeedsDisplay:YES];
}

- (void)_applyTheme {
    [self _refreshToolbarIcons];
    _emptyLabel.textColor = [NSColor secondaryLabelColor];
    [_outlineView reloadData]; // colors may have changed
}

#pragma mark - Localization

- (void)_locChanged:(NSNotification *)n { [self retranslateUI]; }
// PanelFrame owns the panel title; this retranslates only the panel's
// own controls (empty placeholder + two toolbar button tooltips).
- (void)retranslateUI {
    NppLocalizer *loc = [NppLocalizer shared];
    _emptyLabel.stringValue = [loc translate:@"No functions found"];
    _sortButton.toolTip     = [loc translate:@"Sort functions (A to Z)"];
    _reloadButton.toolTip   = [loc translate:@"Reload"];
}

#pragma mark - Actions

- (void)_toggleSort:(id)sender {
    _sortAlpha = !_sortAlpha;
    [self _rebuildFilteredItems];
    [_outlineView reloadData];
    [self _expandAllNodes];
}

- (void)_reload:(id)sender {
    [self reload];
}

#pragma mark - Search field delegate

- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object != _searchField) return;
    _searchText = _searchField.stringValue ?: @"";
    [self _rebuildFilteredItems];
    [_outlineView reloadData];
    [self _expandAllNodes];
    [self _updateEmptyState];
}

#pragma mark - Public API

- (void)loadEditor:(EditorView *)editor {
    _editor = editor;
    [_rootItems removeAllObjects];
    [_filteredItems removeAllObjects];
    [_outlineView reloadData];
    [self _updateEmptyState];

    if (!editor) return;

    // Grab full text from Scintilla (must be on main thread — Scintilla is not thread-safe)
    intptr_t len = [editor.scintillaView message:SCI_GETLENGTH];
    char *buf = (char *)malloc((size_t)len + 1);
    if (!buf) return;
    [editor.scintillaView message:SCI_GETTEXT wParam:(uptr_t)(len + 1) lParam:(sptr_t)buf];
    NSString *text = [[NSString alloc] initWithBytes:buf length:(NSUInteger)len
                                            encoding:NSUTF8StringEncoding];
    if (!text) { free(buf); return; }

    // Build line offset table from raw UTF-8 (fast, single pass)
    [self _buildLineOffsetsFromUTF8:buf length:(NSUInteger)len];
    free(buf);

    NSString *lang = editor.currentLanguage;

    // Increment generation to cancel any in-flight background scan
    NSUInteger gen = ++_scanGeneration;

    // Dispatch scanning to background queue
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Check if this scan is still current
        if (gen != self->_scanGeneration) return;

        [self _scanText:text forLanguage:lang];

        if (gen != self->_scanGeneration) return;

        // Update UI on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self->_scanGeneration) return;
            [self _rebuildFilteredItems];
            [self->_outlineView reloadData];
            [self _expandAllNodes];
            [self _updateEmptyState];
        });
    });
}

- (void)reload {
    EditorView *ed = _editor;
    if (ed) [self loadEditor:ed];
}

#pragma mark - Line offset table (O(n) build, O(log n) lookup)

/// Build a table of byte offsets for the start of each line.
- (void)_buildLineOffsetsFromUTF8:(const char *)utf8 length:(NSUInteger)len {
    free(_lineOffsets);
    // Estimate: one line per 40 bytes on average
    NSUInteger cap = MAX(len / 40, 256);
    _lineOffsets = (NSUInteger *)malloc(cap * sizeof(NSUInteger));
    _lineOffsetCount = 0;

    _lineOffsets[_lineOffsetCount++] = 0; // line 1 starts at offset 0
    for (NSUInteger i = 0; i < len; i++) {
        if (utf8[i] == '\n') {
            if (_lineOffsetCount >= cap) {
                cap *= 2;
                _lineOffsets = (NSUInteger *)realloc(_lineOffsets, cap * sizeof(NSUInteger));
            }
            _lineOffsets[_lineOffsetCount++] = i + 1;
        }
    }
}

/// Fast O(log n) line lookup using the pre-built offset table. Returns 1-based line number.
- (NSInteger)_fastLineForPos:(NSUInteger)pos {
    if (!_lineOffsets || _lineOffsetCount == 0) return 1;
    // Binary search: find the last offset <= pos
    NSUInteger lo = 0, hi = _lineOffsetCount;
    while (lo < hi) {
        NSUInteger mid = (lo + hi) / 2;
        if (_lineOffsets[mid] <= pos) lo = mid + 1;
        else hi = mid;
    }
    return (NSInteger)lo; // lo is 1-based line number
}

#pragma mark - XML/regex cache

/// Cache parsed XML parser elements + compiled regexes per language.
/// Key = language name, Value = NSDictionary with parsed data.
static NSMutableDictionary<NSString *, NSDictionary *> *_xmlParserCache = nil;

static NSDictionary *_cachedParserForLanguage(NSString *lang) {
    if (!_xmlParserCache) _xmlParserCache = [NSMutableDictionary new];
    return _xmlParserCache[lang];
}

static void _cacheParser(NSString *lang, NSDictionary *entry) {
    if (!_xmlParserCache) _xmlParserCache = [NSMutableDictionary new];
    _xmlParserCache[lang] = entry;
}

#pragma mark - XML-based function list parser engine

static NppParserRegex *_compilePattern(NSString *pattern, NSRegularExpressionOptions opts) {
    return [NppParserRegex regularExpressionWithPattern:pattern options:opts error:nil];
}

/// Parse raw XML bytes preserving newlines in attribute values.
/// Returns the root _FLNode tree, or nil on failure.
/// This is intentionally minimal — handles only the subset needed for functionList XML.
static _FLNode *_parseRawXML(NSData *data) {
    NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!raw) return nil;

    _FLNode *root = [[_FLNode alloc] init];
    root.tagName = @"__root__";
    NSMutableArray<_FLNode *> *stack = [NSMutableArray arrayWithObject:root];

    NSUInteger len = raw.length;
    NSUInteger i = 0;

    while (i < len) {
        // Skip to next '<'
        NSUInteger tagStart = [raw rangeOfString:@"<" options:0 range:NSMakeRange(i, len - i)].location;
        if (tagStart == NSNotFound) break;
        i = tagStart + 1;
        if (i >= len) break;

        // Skip comments <!-- ... -->
        if (i + 2 < len && [raw characterAtIndex:i] == '!' &&
            [raw characterAtIndex:i+1] == '-' && [raw characterAtIndex:i+2] == '-') {
            NSRange endComment = [raw rangeOfString:@"-->" options:0 range:NSMakeRange(i, len - i)];
            if (endComment.location != NSNotFound) i = NSMaxRange(endComment);
            continue;
        }
        // Skip processing instructions <? ... ?>
        if ([raw characterAtIndex:i] == '?') {
            NSRange endPI = [raw rangeOfString:@"?>" options:0 range:NSMakeRange(i, len - i)];
            if (endPI.location != NSNotFound) i = NSMaxRange(endPI);
            continue;
        }
        // Closing tag </name>
        if ([raw characterAtIndex:i] == '/') {
            NSRange endTag = [raw rangeOfString:@">" options:0 range:NSMakeRange(i, len - i)];
            if (endTag.location != NSNotFound) i = NSMaxRange(endTag);
            if (stack.count > 1) [stack removeLastObject];
            continue;
        }

        // Opening tag: extract tag name
        NSMutableString *tagName = [NSMutableString new];
        while (i < len) {
            unichar c = [raw characterAtIndex:i];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '/' || c == '>') break;
            [tagName appendFormat:@"%C", c];
            i++;
        }
        if (!tagName.length) continue;

        _FLNode *node = [[_FLNode alloc] init];
        node.tagName = tagName;
        node.parent = stack.lastObject;
        [stack.lastObject.children addObject:node];

        // Parse attributes (preserving newlines in values!)
        BOOL selfClosing = NO;
        while (i < len) {
            // Skip whitespace
            while (i < len) {
                unichar c = [raw characterAtIndex:i];
                if (c != ' ' && c != '\t' && c != '\n' && c != '\r') break;
                i++;
            }
            if (i >= len) break;
            unichar c = [raw characterAtIndex:i];
            if (c == '>') { i++; break; }
            if (c == '/') {
                selfClosing = YES;
                i++;
                // Skip to '>'
                while (i < len && [raw characterAtIndex:i] != '>') i++;
                if (i < len) i++; // skip '>'
                break;
            }

            // Attribute name
            NSMutableString *attrName = [NSMutableString new];
            while (i < len) {
                unichar ac = [raw characterAtIndex:i];
                if (ac == '=' || ac == ' ' || ac == '\t' || ac == '\n' || ac == '\r' ||
                    ac == '>' || ac == '/') break;
                [attrName appendFormat:@"%C", ac];
                i++;
            }
            // Skip to '='
            while (i < len && [raw characterAtIndex:i] != '=' &&
                   [raw characterAtIndex:i] != '>' && [raw characterAtIndex:i] != '/') i++;
            if (i >= len || [raw characterAtIndex:i] != '=') continue;
            i++; // skip '='

            // Skip whitespace before quote
            while (i < len) {
                unichar wc = [raw characterAtIndex:i];
                if (wc != ' ' && wc != '\t' && wc != '\n' && wc != '\r') break;
                i++;
            }
            if (i >= len) break;

            unichar quote = [raw characterAtIndex:i];
            if (quote != '"' && quote != '\'') continue;
            i++; // skip opening quote

            // Read attribute value — preserving newlines!
            NSMutableString *attrVal = [NSMutableString new];
            while (i < len) {
                unichar vc = [raw characterAtIndex:i];
                if (vc == quote) { i++; break; }
                [attrVal appendFormat:@"%C", vc];
                i++;
            }

            if (attrName.length) node.attrs[attrName] = attrVal;
        }

        if (!selfClosing) [stack addObject:node];
    }

    return root;
}

/// Find the <parser> element inside a functionList XML tree.
static _FLNode *_findParserNode(_FLNode *root) {
    for (_FLNode *c1 in root.children) {
        if ([c1.tagName isEqualToString:@"parser"]) return c1;
        if ([c1.tagName isEqualToString:@"NotepadPlus"] || [c1.tagName isEqualToString:@"functionList"]) {
            _FLNode *found = _findParserNode(c1);
            if (found) return found;
        }
    }
    return nil;
}

/// Load a function list XML file. Returns the <parser> _FLNode or nil.
static _FLNode *_loadParserXML(NSString *lang) {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. Check user override: ~/Library/Application Support/Nextpad++/functionList/<lang>.xml
    NSString *userPath = NppConfigSubpath(
                          [NSString stringWithFormat:@"functionList/%@.xml", lang]);
    NSData *data = [fm fileExistsAtPath:userPath] ? [NSData dataWithContentsOfFile:userPath] : nil;

    // 2. Fall back to bundled: Resources/functionList/<lang>.xml
    if (!data) {
        NSString *bundlePath = [[NSBundle mainBundle] pathForResource:lang ofType:@"xml"
                                                         inDirectory:@"functionList"];
        if (bundlePath) data = [NSData dataWithContentsOfFile:bundlePath];
    }
    if (!data) return nil;

    _FLNode *root = _parseRawXML(data);
    if (!root) return nil;
    return _findParserNode(root);
}

/// Extract name from text using a chain of nameExpr _FLNode elements (last one refines).
static NSString *_extractName(NSString *matchedText, NSArray<_FLNode *> *nameExprs) {
    NSString *result = matchedText;
    for (_FLNode *ne in nameExprs) {
        NSString *pattern = [ne attr:@"expr"];
        if (!pattern.length) continue;
        NppParserRegex *re = _compilePattern(pattern, 0);
        if (!re) continue;
        NSTextCheckingResult *m = [re firstMatchInString:result options:0
                                                   range:NSMakeRange(0, result.length)];
        if (m && m.range.length > 0) {
            result = [result substringWithRange:m.range];
        } else if (m && m.range.length == 0 && result.length > 1) {
            // Zero-length match at start — happens when \K was stripped from mainExpr.
            // The nameExpr expects text AFTER the \K point. Try from position 1 onwards.
            m = [re firstMatchInString:result options:0
                                 range:NSMakeRange(1, result.length - 1)];
            if (m && m.range.length > 0) result = [result substringWithRange:m.range];
        }
    }
    return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/// Build an NSIndexSet of comment ranges (excluded from function matching).
/// No string mutation — just tracks which byte ranges are comments.
static NSIndexSet *_commentRanges(NSString *text, NSString *commentExpr) {
    if (!commentExpr.length) return nil;
    NppParserRegex *re = _compilePattern(commentExpr,
        NSRegularExpressionAnchorsMatchLines | NSRegularExpressionDotMatchesLineSeparators);
    if (!re) return nil;

    NSMutableIndexSet *ranges = [NSMutableIndexSet new];
    [re enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                      usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
        [ranges addIndexesInRange:m.range];
    }];
    return ranges.count ? ranges : nil;
}

/// Check if a match range overlaps with comment ranges.
static BOOL _isInComment(NSRange range, NSIndexSet *commentRanges) {
    if (!commentRanges) return NO;
    return [commentRanges intersectsIndexesInRange:range];
}

/// XML-based scan: parse a function list XML and populate _rootItems.
/// Returns YES if successful, NO if XML not found or unconvertible (fall back to hardcoded).
- (BOOL)_scanTextWithXML:(NSString *)text forLanguage:(NSString *)lang {
    // ── Load parser (cached) ──────────────────────────────────────────
    NSDictionary *cached = _cachedParserForLanguage(lang);
    _FLNode *parser = nil;
    NppParserRegex *commentRE = nil;

    if (cached) {
        parser = cached[@"parser"];
        commentRE = cached[@"commentRE"]; // may be [NSNull null]
    } else {
        parser = _loadParserXML(lang);
        if (!parser) return NO;

        NSString *commentExpr = [parser attr:@"commentExpr"];
        commentRE = commentExpr.length ? _compilePattern(commentExpr,
            NSRegularExpressionAnchorsMatchLines | NSRegularExpressionDotMatchesLineSeparators) : nil;

        _cacheParser(lang, @{
            @"parser": parser,
            @"commentRE": commentRE ?: [NSNull null]
        });
    }
    if (!parser) return NO;
    if ([commentRE isEqual:[NSNull null]]) commentRE = nil;

    // ── Build comment exclusion ranges ────────────────────────────────
    NSIndexSet *commentRanges = nil;
    if (commentRE) {
        NSMutableIndexSet *cRanges = [NSMutableIndexSet new];
        [commentRE enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                                 usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
            [cRanges addIndexesInRange:m.range];
        }];
        if (cRanges.count) commentRanges = cRanges;
    }

    // ── Collect parser elements ───────────────────────────────────────
    NSArray<_FLNode *> *classRangeEls = [parser childrenWithTag:@"classRange"];
    NSArray<_FLNode *> *allFuncEls = [parser childrenWithTag:@"function"];
    NSMutableArray<_FLNode *> *topLevelFuncs = [allFuncEls mutableCopy];

    BOOL didParse = NO;

    // ── Process classRange elements ───────────────────────────────────
    for (_FLNode *crEl in classRangeEls) {
        NSString *crMainExpr = [crEl attr:@"mainExpr"];
        NppParserRegex *crRE = _compilePattern(crMainExpr,
            NSRegularExpressionAnchorsMatchLines | NSRegularExpressionDotMatchesLineSeparators);
        if (!crRE) continue;
        didParse = YES;

        NSArray<_FLNode *> *classNameExprs = [crEl descendantsAtPath:@"className/nameExpr"];
        NSArray<_FLNode *> *nestedFuncEls = [crEl childrenWithTag:@"function"];

        [crRE enumerateMatchesInString:text options:0
                                 range:NSMakeRange(0, text.length)
                            usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
            if (_isInComment(m.range, commentRanges)) return;

            NSString *matchedText = [text substringWithRange:m.range];
            NSString *className = classNameExprs.count
                ? _extractName(matchedText, classNameExprs)
                : [matchedText componentsSeparatedByCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]][0];
            if (!className.length) return;

            NSInteger classLine = [self _fastLineForPos:m.range.location];
            _FuncItem *classNode = [[_FuncItem alloc] initWithName:className line:classLine
                                                               pos:(NSInteger)m.range.location isNode:YES];

            for (_FLNode *funcEl in nestedFuncEls) {
                NSString *funcMainExpr = [funcEl attr:@"mainExpr"];
                NppParserRegex *funcRE = _compilePattern(funcMainExpr,
                    NSRegularExpressionAnchorsMatchLines);
                if (!funcRE) continue;

                NSArray<_FLNode *> *funcNameExprs = [funcEl descendantsAtPath:@"functionName/funcNameExpr"];
                if (!funcNameExprs.count)
                    funcNameExprs = [funcEl descendantsAtPath:@"functionName/nameExpr"];

                [funcRE enumerateMatchesInString:matchedText options:0
                                           range:NSMakeRange(0, matchedText.length)
                                      usingBlock:^(NSTextCheckingResult *fm2, NSMatchingFlags f2, BOOL *stop2) {
                    NSString *funcMatch = [matchedText substringWithRange:fm2.range];
                    NSString *funcName = funcNameExprs.count
                        ? _extractName(funcMatch, funcNameExprs) : funcMatch;
                    if (!funcName.length) return;

                    NSUInteger absPos = m.range.location + fm2.range.location;
                    NSInteger funcLine = [self _fastLineForPos:absPos];
                    _FuncItem *leaf = [[_FuncItem alloc] initWithName:funcName line:funcLine
                                                                 pos:(NSInteger)absPos isNode:NO];
                    [classNode.children addObject:leaf];
                }];
            }

            [self->_rootItems addObject:classNode];
        }];
    }

    // ── Process top-level function elements ───────────────────────────
    for (_FLNode *funcEl in topLevelFuncs) {
        NSString *funcMainExpr = [funcEl attr:@"mainExpr"];
        NppParserRegex *funcRE = _compilePattern(funcMainExpr,
            NSRegularExpressionAnchorsMatchLines);
        if (!funcRE) continue;
        didParse = YES;

        NSArray<_FLNode *> *funcNameExprs = [funcEl descendantsAtPath:@"functionName/funcNameExpr"];
        if (!funcNameExprs.count)
            funcNameExprs = [funcEl descendantsAtPath:@"functionName/nameExpr"];
        NSArray<_FLNode *> *topClassExprs = [funcEl descendantsAtPath:@"className/nameExpr"];

        [funcRE enumerateMatchesInString:text options:0
                                   range:NSMakeRange(0, text.length)
                              usingBlock:^(NSTextCheckingResult *fm3, NSMatchingFlags f3, BOOL *stop3) {
            if (_isInComment(fm3.range, commentRanges)) return;

            NSString *funcMatch = [text substringWithRange:fm3.range];
            NSString *funcName = funcNameExprs.count
                ? _extractName(funcMatch, funcNameExprs) : funcMatch;
            if (!funcName.length) return;

            NSInteger funcLine = [self _fastLineForPos:fm3.range.location];
            _FuncItem *leaf = [[_FuncItem alloc] initWithName:funcName line:funcLine
                                                         pos:(NSInteger)fm3.range.location isNode:NO];

            if (topClassExprs.count) {
                NSString *clsName = _extractName(funcMatch, topClassExprs);
                if (clsName.length) {
                    _FuncItem *parent = nil;
                    for (_FuncItem *existing in self->_rootItems) {
                        if (existing.isNode && [existing.name isEqualToString:clsName]) {
                            parent = existing;
                            break;
                        }
                    }
                    if (!parent) {
                        parent = [[_FuncItem alloc] initWithName:clsName line:funcLine
                                                             pos:(NSInteger)fm3.range.location isNode:YES];
                        [self->_rootItems addObject:parent];
                    }
                    [parent.children addObject:leaf];
                    return;
                }
            }

            [self->_rootItems addObject:leaf];
        }];
    }

    return didParse;
}

#pragma mark - Scanning (hierarchical: classes → methods)

- (void)_scanText:(NSString *)text forLanguage:(NSString *)lang {
    [_rootItems removeAllObjects];
    lang = lang.lowercaseString;

    // If XML-based parsing is enabled, try the multi-stage XML parser first.
    // Falls back to hardcoded regex if XML not found or patterns are unconvertible.
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kPrefFuncListUseXML]) {
        if ([self _scanTextWithXML:text forLanguage:lang])
            return; // XML parser succeeded
    }

    // ═══════════════════════════════════════════════════════════════════
    // Hardcoded regex fallback (original approach)
    // ═══════════════════════════════════════════════════════════════════

    // === Phase 1: Detect classes/structs/protocols ===
    NSMutableArray<_FuncItem *> *classNodes = [NSMutableArray array];

    // Check user override for class pattern
    NSString *userClassPattern = nil;
    _userFuncPatternForLanguage(lang, &userClassPattern);

    NSString *classPattern = userClassPattern; // nil if no user override
    if (!classPattern) {
        if ([@[@"c", @"cpp", @"objc", @"swift", @"java", @"cs", @"typescript", @"javascript",
               @"javascript.js", @"go", @"d", @"rust", @"kotlin"] containsObject:lang]) {
            classPattern = @"(?m)^[ \\t]*(?:public\\s+|private\\s+|protected\\s+|internal\\s+|abstract\\s+|final\\s+|static\\s+)*"
                           @"(?:class|struct|protocol|interface|enum)\\s+(\\w+)";
        } else if ([lang isEqualToString:@"python"]) {
            classPattern = @"(?m)^class\\s+(\\w+)";
        } else if ([lang isEqualToString:@"ruby"]) {
            classPattern = @"(?m)^[ \\t]*(?:class|module)\\s+(\\w+)";
        } else if ([lang isEqualToString:@"php"]) {
            classPattern = @"(?m)^[ \\t]*(?:abstract\\s+|final\\s+)?class\\s+(\\w+)";
        }
    }

    // Build a list of class ranges: {name, startLine, startPos, endPos}
    NSMutableArray *classRanges = [NSMutableArray array]; // @[@{name, start, end, node}]

    if (classPattern) {
        NSRegularExpression *classRE = [NSRegularExpression
            regularExpressionWithPattern:classPattern
                                 options:NSRegularExpressionAnchorsMatchLines error:nil];
        if (classRE) {
            [classRE enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                                  usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
                NSRange nameR = [m rangeAtIndex:1];
                if (nameR.location == NSNotFound) return;
                NSString *name = [text substringWithRange:nameR];
                NSUInteger startPos = m.range.location;
                NSInteger line = [self _fastLineForPos:startPos];

                _FuncItem *node = [[_FuncItem alloc] initWithName:name line:line pos:(NSInteger)startPos isNode:YES];
                [classNodes addObject:node];

                // Find the class body end (brace counting)
                NSUInteger bodyStart = [self _findBraceOpen:text from:NSMaxRange(m.range)];
                NSUInteger bodyEnd   = [self _findBraceClose:text from:bodyStart];

                [classRanges addObject:@{@"name": name, @"start": @(bodyStart),
                                         @"end": @(bodyEnd), @"node": node}];
            }];
        }
    }

    // === Phase 2: Detect functions/methods ===
    NSString *funcPattern = [self _funcPatternForLanguage:lang];
    if (!funcPattern) return;

    NSRegularExpression *funcRE = [NSRegularExpression
        regularExpressionWithPattern:funcPattern
                             options:NSRegularExpressionAnchorsMatchLines error:nil];
    if (!funcRE) return;

    NSMutableSet *addedNames = [NSMutableSet set]; // dedup

    [funcRE enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                          usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
        // Try capture group 1, fall back to group 2 (for patterns with alternation)
        NSRange nameR = [m rangeAtIndex:1];
        if (nameR.location == NSNotFound && m.numberOfRanges > 2)
            nameR = [m rangeAtIndex:2];
        if (nameR.location == NSNotFound) return;
        NSString *name = [text substringWithRange:nameR];

        // Truncate long names (e.g. full XML tags) and collapse whitespace
        if (name.length > 50) name = [[name substringToIndex:50] stringByAppendingString:@"…"];
        name = [[name componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
                componentsJoinedByString:@" "];

        // Dedup by name + position
        NSString *key = [NSString stringWithFormat:@"%@_%lu", name, (unsigned long)m.range.location];
        if ([addedNames containsObject:key]) return;
        [addedNames addObject:key];

        // Use the position of the captured NAME (not the full match start)
        // to get the exact line the function name appears on
        NSUInteger pos = nameR.location;
        NSInteger line = [self _fastLineForPos:pos];

        _FuncItem *leaf = [[_FuncItem alloc] initWithName:name line:line pos:(NSInteger)pos isNode:NO];

        // Check if this function is inside a class range
        BOOL nested = NO;
        for (NSDictionary *cr in classRanges) {
            NSUInteger cStart = [cr[@"start"] unsignedIntegerValue];
            NSUInteger cEnd   = [cr[@"end"] unsignedIntegerValue];
            if (pos > cStart && pos < cEnd) {
                _FuncItem *parentNode = cr[@"node"];
                [parentNode.children addObject:leaf];
                nested = YES;
                break;
            }
        }
        if (!nested) {
            [self->_rootItems addObject:leaf];
        }
    }];

    // Add class nodes (that have children) to root
    for (_FuncItem *node in classNodes) {
        if (node.children.count > 0) {
            // Sort children by line
            [node.children sortUsingComparator:^NSComparisonResult(_FuncItem *a, _FuncItem *b) {
                return a.line < b.line ? NSOrderedAscending : (a.line > b.line ? NSOrderedDescending : NSOrderedSame);
            }];
            [_rootItems addObject:node];
        }
    }

    // Sort root by line number (document order)
    [_rootItems sortUsingComparator:^NSComparisonResult(_FuncItem *a, _FuncItem *b) {
        return a.line < b.line ? NSOrderedAscending : (a.line > b.line ? NSOrderedDescending : NSOrderedSame);
    }];
}

/// Check ~/Library/Application Support/Nextpad++/functionList/<lang>.xml for a user-defined pattern override.
/// Expected format:
///   <NotepadPlus><functionList><parser>
///     <function mainExpr="regex-with-capture-group-1-for-name" />
///     <classRange mainExpr="regex-with-capture-group-1-for-name" />  (optional)
///   </parser></functionList></NotepadPlus>
/// Returns nil if no user override exists or the file can't be parsed.
static NSString *_userFuncPatternForLanguage(NSString *lang, NSString * __autoreleasing *outClassPattern) {
    NSString *path = NppConfigSubpath(
                      [NSString stringWithFormat:@"functionList/%@.xml", lang.lowercaseString]);
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;

    _FLNode *root = _parseRawXML(data);
    if (!root) return nil;
    _FLNode *parser = _findParserNode(root);
    if (!parser) return nil;

    // Extract function mainExpr
    NSArray<_FLNode *> *funcNodes = [parser childrenWithTag:@"function"];
    NSString *funcExpr = funcNodes.count ? [funcNodes[0] attr:@"mainExpr"] : nil;

    // Extract optional classRange mainExpr
    if (outClassPattern) {
        NSArray<_FLNode *> *classNodes = [parser childrenWithTag:@"classRange"];
        if (classNodes.count)
            *outClassPattern = [classNodes[0] attr:@"mainExpr"];
    }

    return funcExpr;
}

- (NSString *)_funcPatternForLanguage:(NSString *)lang {
    // Check user override first
    NSString *userPattern = _userFuncPatternForLanguage(lang, nil);
    if (userPattern.length) return userPattern;

    if ([lang isEqualToString:@"python"])
        return @"(?m)^[ \\t]*(?:async\\s+)?def\\s+(\\w+)\\s*\\(";
    if ([lang isEqualToString:@"ruby"])
        return @"(?m)^[ \\t]*def\\s+(\\w+)";
    if ([lang isEqualToString:@"bash"])
        return @"(?m)^[ \\t]*(\\w+)\\s*\\(\\s*\\)";
    if ([@[@"javascript", @"javascript.js", @"typescript"] containsObject:lang]) {
        return @"(?m)(?:function\\s+(\\w+)\\s*\\(|(?:async\\s+)?(\\w+)\\s*\\([^)]*\\)\\s*[:{])";
    }
    // Swift: func keyword required
    if ([lang isEqualToString:@"swift"]) {
        return @"(?m)^[ \\t]*(?:@\\w+\\s+)*(?:(?:public|private|internal|fileprivate|open|static|class|override|mutating|final)\\s+)*func\\s+(\\w+)";
    }
    // C/C++/ObjC/Java/C#: return-type + name + params + opening brace
    if ([@[@"c", @"cpp", @"objc", @"java", @"cs", @"go", @"d", @"actionscript", @"rc"] containsObject:lang]) {
        // [^)]* matches until closing paren (NOT [^;]* which crosses function boundaries)
        return @"(?m)^[\\t ]*(?:[\\w\\*<>\\[\\],&:\\s]+\\s+)(\\w+)\\s*\\([^)]*\\)\\s*(?:const\\s*)?(?:override\\s*)?(?:noexcept\\s*)?\\{";
    }
    if ([lang isEqualToString:@"php"])
        return @"(?m)^[ \\t]*(?:public\\s+|private\\s+|protected\\s+|static\\s+)*function\\s+(\\w+)\\s*\\(";
    if ([lang isEqualToString:@"go"])
        return @"(?m)^func\\s+(?:\\([^)]+\\)\\s+)?(\\w+)\\s*\\(";
    if ([lang isEqualToString:@"rust"])
        return @"(?m)^\\s*(?:pub(?:\\([^)]*\\))?\\s+)?(?:async\\s+)?fn\\s+(\\w+)";
    if ([lang isEqualToString:@"lua"])
        return @"(?m)(?:function\\s+(\\w[\\w.:]*)\\s*\\(|local\\s+function\\s+(\\w+)\\s*\\()";
    if ([lang isEqualToString:@"perl"])
        return @"(?m)^\\s*sub\\s+(\\w+)";
    if ([lang isEqualToString:@"haskell"])
        return @"(?m)^(\\w+)\\s+::";
    if ([lang isEqualToString:@"r"])
        return @"(?m)(\\w+)\\s*<-\\s*function\\s*\\(";
    if ([lang isEqualToString:@"powershell"])
        return @"(?m)^\\s*function\\s+(\\w[\\w-]*)";
    if ([lang isEqualToString:@"pascal"])
        return @"(?m)^\\s*(?:procedure|function)\\s+(\\w+)";
    if ([@[@"fortran", @"fortran77"] containsObject:lang])
        return @"(?mi)^\\s*(?:(?:integer|real|double\\s+precision|complex|logical|character|subroutine|function|program)\\s+)(\\w+)";
    if ([lang isEqualToString:@"ada"])
        return @"(?m)^\\s*(?:procedure|function)\\s+(\\w+)";
    if ([lang isEqualToString:@"vb"])
        return @"(?mi)^\\s*(?:public\\s+|private\\s+|friend\\s+)?(?:sub|function|property)\\s+(\\w+)";
    if ([lang isEqualToString:@"sql"] || [lang isEqualToString:@"mssql"])
        return @"(?mi)^\\s*create\\s+(?:or\\s+replace\\s+)?(?:function|procedure|trigger)\\s+(\\w+)";
    if ([lang isEqualToString:@"latex"])
        return @"(?m)\\\\(?:section|subsection|subsubsection|chapter|part)\\{([^}]+)\\}";
    if ([lang isEqualToString:@"makefile"])
        return @"(?m)^([\\w][\\w.-]*)\\s*:";
    if ([lang isEqualToString:@"cmake"])
        return @"(?mi)^\\s*(?:function|macro)\\s*\\(\\s*(\\w+)";
    if ([lang isEqualToString:@"nim"])
        return @"(?m)^\\s*(?:proc|func|method|iterator|template|macro)\\s+(\\w+)";
    if ([lang isEqualToString:@"erlang"])
        return @"(?m)^(\\w+)\\s*\\(";
    if ([lang isEqualToString:@"asm"])
        return @"(?m)^(\\w+):";
    if ([lang isEqualToString:@"vhdl"])
        return @"(?mi)^\\s*(?:procedure|function)\\s+(\\w+)";
    if ([lang isEqualToString:@"verilog"])
        return @"(?m)^\\s*(?:module|task|function)\\s+(\\w+)";
    if ([lang isEqualToString:@"css"])
        return @"(?m)^([.#]?[\\w][\\w.#>~+\\-\\s,:]*)\\s*\\{";
    if ([lang isEqualToString:@"ini"] || [lang isEqualToString:@"props"])
        return @"(?m)^\\[([^\\]]+)\\]";
    if ([lang isEqualToString:@"yaml"])
        return @"(?m)^(\\w[\\w-]*)\\s*:";
    if ([lang isEqualToString:@"toml"])
        return @"(?m)^\\[([^\\]]+)\\]";
    if ([lang isEqualToString:@"batch"])
        return @"(?mi)^\\s*:(\\w+)";
    if ([lang isEqualToString:@"coffeescript"])
        return @"(?m)^\\s*(\\w+)\\s*[=:]\\s*(?:\\([^)]*\\))?\\s*[-=]>";
    // XML/HTML: capture full opening tag (truncated to 50 chars in display)
    if ([lang isEqualToString:@"xml"] || [lang isEqualToString:@"html"] || [lang isEqualToString:@"asp"])
        return @"(?m)(<\\w+(?:\\s+[\\w:-]+\\s*=\\s*\"[^\"]*\")*\\s*/?>)";
    // JSON: top-level keys
    if ([lang isEqualToString:@"json"])
        return @"(?m)^\\s*\"(\\w[\\w\\s]*)\"\\s*:";
    // Generic fallback: C-style function definitions
    return @"(?m)^[\\t ]*[\\w\\*]+(?:[\\s\\*]+)(\\w+)\\s*\\([^)]*\\)\\s*\\{";
}

#pragma mark - Helpers

// _lineForPos:inText: removed — replaced by _fastLineForPos: (O(log n) binary search)

- (NSUInteger)_findBraceOpen:(NSString *)text from:(NSUInteger)start {
    NSUInteger len = text.length;
    for (NSUInteger i = start; i < len; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '{') return i;
        if (c == ';') return len; // declaration only, no body
    }
    return len;
}

- (NSUInteger)_findBraceClose:(NSString *)text from:(NSUInteger)start {
    NSUInteger len = text.length;
    NSInteger depth = 0;
    for (NSUInteger i = start; i < len; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '{') depth++;
        else if (c == '}') { depth--; if (depth <= 0) return i; }
    }
    return len;
}

#pragma mark - Filtering & sorting

- (void)_rebuildFilteredItems {
    [_filteredItems removeAllObjects];

    BOOL hasSearch = (_searchText.length > 0);
    NSString *lowerSearch = _searchText.lowercaseString;

    for (_FuncItem *item in _rootItems) {
        if (item.isNode) {
            // Filter children, keep node if any child matches
            _FuncItem *filteredNode = nil;
            for (_FuncItem *child in item.children) {
                if (!hasSearch || [child.name.lowercaseString containsString:lowerSearch]) {
                    if (!filteredNode) {
                        filteredNode = [[_FuncItem alloc] initWithName:item.name
                                                                  line:item.line pos:item.pos isNode:YES];
                    }
                    [filteredNode.children addObject:child];
                }
            }
            // Also match the node name itself
            if (!filteredNode && hasSearch && [item.name.lowercaseString containsString:lowerSearch]) {
                filteredNode = item; // include all children
            }
            if (filteredNode) [_filteredItems addObject:filteredNode];
            else if (!hasSearch) [_filteredItems addObject:item];
        } else {
            // Leaf at root level
            if (!hasSearch || [item.name.lowercaseString containsString:lowerSearch]) {
                [_filteredItems addObject:item];
            }
        }
    }

    // Sort
    if (_sortAlpha) {
        [self _sortAlphabetically:_filteredItems];
    }
}

- (void)_sortAlphabetically:(NSMutableArray<_FuncItem *> *)items {
    [items sortUsingComparator:^NSComparisonResult(_FuncItem *a, _FuncItem *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    for (_FuncItem *item in items) {
        if (item.isNode && item.children.count > 0) {
            [self _sortAlphabetically:item.children];
        }
    }
}

- (void)_expandAllNodes {
    for (_FuncItem *item in _filteredItems) {
        if (item.isNode) [_outlineView expandItem:item];
    }
}

- (void)_updateEmptyState {
    _emptyLabel.hidden = (_filteredItems.count > 0);
}

#pragma mark - NSOutlineViewDataSource

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(nullable id)item {
    if (!item) return (NSInteger)_filteredItems.count;
    _FuncItem *fi = (_FuncItem *)item;
    return fi.isNode ? (NSInteger)fi.children.count : 0;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(nullable id)item {
    if (!item) return _filteredItems[index];
    return ((_FuncItem *)item).children[index];
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
    return ((_FuncItem *)item).isNode;
}

#pragma mark - NSOutlineViewDelegate

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    _FuncItem *fi = (_FuncItem *)item;

    NSTableCellView *cell = [ov makeViewWithIdentifier:@"FLCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        cell.identifier = @"FLCell";

        NSImageView *iv = [[NSImageView alloc] init];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        iv.imageScaling = NSImageScaleProportionallyDown;
        [cell addSubview:iv];
        cell.imageView = iv;

        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.font = [NSFont systemFontOfSize:12];
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:tf];
        cell.textField = tf;

        [NSLayoutConstraint activateConstraints:@[
            [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [iv.widthAnchor constraintEqualToConstant:14],
            [iv.heightAnchor constraintEqualToConstant:14],
            [tf.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:4],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    cell.imageView.image = fi.isNode ? _nodeIcon : _leafIcon;
    cell.textField.stringValue = fi.name;
    cell.textField.font = [NSFont systemFontOfSize:_panelFontSize];
    // Update icon size constraints
    for (NSLayoutConstraint *c in cell.imageView.constraints) {
        if (c.firstAttribute == NSLayoutAttributeWidth || c.firstAttribute == NSLayoutAttributeHeight)
            c.constant = _panelFontSize + 2;
    }
    return cell;
}

#pragma mark - Click handler

- (void)outlineViewSelectionDidChange:(NSNotification *)n {
    NSInteger row = _outlineView.selectedRow;
    if (row < 0) return;
    _FuncItem *fi = [_outlineView itemAtRow:row];
    if (!fi) return;
    EditorView *ed = _editor;
    if (!ed) return;

    NSInteger line = fi.line;
    // Give focus to Scintilla's inner content view (SCIContentView), then navigate.
    // Must target the content view — not ScintillaView itself — for selection to render.
    NSView *contentView = [ed.scintillaView content];
    [ed.window makeFirstResponder:contentView];

    // Use performSelector with delay so the focus change fully settles
    // before we set the selection (otherwise the focus-in event clears it).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [ed goToLineNumber:line];
    });
}


#pragma mark - Panel Zoom

- (void)_saveZoom { [[NSUserDefaults standardUserDefaults] setFloat:_panelFontSize forKey:@"PanelZoom_FunctionList"]; }
- (void)panelZoomIn    { _panelFontSize = MIN(_panelFontSize + 1, 28); _outlineView.rowHeight = _panelFontSize + 8; [_outlineView reloadData]; [self _saveZoom]; }
- (void)panelZoomOut   { _panelFontSize = MAX(_panelFontSize - 1, 8);  _outlineView.rowHeight = _panelFontSize + 8; [_outlineView reloadData]; [self _saveZoom]; }
- (void)panelZoomReset { _panelFontSize = 11; _outlineView.rowHeight = 19; [_outlineView reloadData]; [self _saveZoom]; }
@end
