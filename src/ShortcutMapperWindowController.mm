#import "ShortcutMapperWindowController.h"
#import "NppPaths.h"
#import "AppDelegate.h"
#import "MainWindowController.h"
#import "MenuBuilder.h"          // kMenuTagPlugins
#import "NppPluginManager.h"
#import "NppLocalizer.h"

NSNotificationName const NPPShortcutsChangedNotification = @"NPPShortcutsChangedNotification";

// ═══════════════════════════════════════════════════════════════════════════════
// ShortcutEntry — one row in the table
// ═══════════════════════════════════════════════════════════════════════════════

@interface ShortcutEntry : NSObject
@property (copy)   NSString *name;
@property (copy)   NSString *shortcutDisplay;   // e.g. "Cmd+Shift+S"
@property (copy)   NSString *category;          // "File", "Edit", etc. (Main Menu only)
@property (copy)   NSString *pluginName;        // Plugin tab only
@property (assign) BOOL hasCtrl, hasAlt, hasShift, hasCmd;
@property (assign) NSUInteger keyCode;          // 0 = none
@property (assign) NSInteger  commandID;        // IDM_* or SCI_* or index
@property (copy, nullable) NSString *selectorName; // macOS selector string
@property (assign) BOOL isModified;             // user changed from default
@property (assign) BOOL isMenuShadowed;         // Scintilla cmd shadowed by a same-key NSMenu item (info-only highlight)
@end

@implementation ShortcutEntry
- (void)updateDisplay {
    if (_keyCode == 0) { _shortcutDisplay = @""; return; }
    // macOS native symbol display: ⌃⌥⇧⌘ + key
    NSMutableString *s = [NSMutableString string];
    if (_hasCtrl)  [s appendString:@"\u2303"];  // ⌃
    if (_hasAlt)   [s appendString:@"\u2325"];  // ⌥
    if (_hasShift) [s appendString:@"\u21E7"];  // ⇧
    if (_hasCmd)   [s appendString:@"\u2318"];  // ⌘
    [s appendString:[ShortcutEntry keyNameForCode:_keyCode]];
    _shortcutDisplay = [s copy];
}

+ (NSString *)keyNameForCode:(NSUInteger)code {
    if (code >= 'A' && code <= 'Z') return [NSString stringWithFormat:@"%c", (char)code];
    if (code >= '0' && code <= '9') return [NSString stringWithFormat:@"%c", (char)code];
    // Windows VK function key codes (112-123 = F1-F12)
    if (code >= 112 && code <= 123) return [NSString stringWithFormat:@"F%lu", (unsigned long)(code - 111)];
    // macOS NSFunctionKey values (0xF704-0xF70F = F1-F12)
    if (code >= 0xF704 && code <= 0xF70F) return [NSString stringWithFormat:@"F%lu", (unsigned long)(code - 0xF704 + 1)];
    // macOS NSFunctionKey values (0xF710-0xF71B = F13-F24)
    if (code >= 0xF710 && code <= 0xF71B) return [NSString stringWithFormat:@"F%lu", (unsigned long)(code - 0xF710 + 13)];
    switch (code) {
        case 8:   return @"\u232B"; // ⌫ Backspace
        case 9:   return @"\u21E5"; // ⇥ Tab
        case 13:  return @"\u21A9"; // ↩ Enter
        case 27:  return @"\u238B"; // ⎋ Escape
        case 32:  return @"\u2423"; // ␣ Space
        case 33:  return @"\u21DE"; // ⇞ Page Up
        case 34:  return @"\u21DF"; // ⇟ Page Down
        case 35:  return @"\u2198"; // ↘ End
        case 36:  return @"\u2196"; // ↖ Home
        case 37:  return @"\u2190"; // ← Left
        case 38:  return @"\u2191"; // ↑ Up
        case 39:  return @"\u2192"; // → Right
        case 40:  return @"\u2193"; // ↓ Down
        case 45:  return @"Ins";
        case 46:  return @"\u2326"; // ⌦ Delete
        case 186: return @";";
        case 187: return @"+";
        case 188: return @",";
        case 189: return @"-";
        case 190: return @".";
        case 191: return @"/";
        case 192: return @"`";
        case 219: return @"[";
        case 220: return @"\\";
        case 221: return @"]";
        case 222: return @"'";
        // macOS special key unicodes
        case 0xF728: return @"\u2326"; // ⌦ Forward Delete
        case 0xF729: return @"\u2196"; // ↖ Home
        case 0xF72B: return @"\u2198"; // ↘ End
        case 0xF72C: return @"\u21DE"; // ⇞ Page Up
        case 0xF72D: return @"\u21DF"; // ⇟ Page Down
        case 0xF702: return @"\u2190"; // ← Left
        case 0xF703: return @"\u2192"; // → Right
        case 0xF700: return @"\u2191"; // ↑ Up
        case 0xF701: return @"\u2193"; // ↓ Down
        default:  return [NSString stringWithFormat:@"0x%lX", (unsigned long)code];
    }
}

+ (NSArray<NSString *> *)allKeyNames {
    NSMutableArray *keys = [NSMutableArray arrayWithObject:@"None"];
    for (unichar c = 'A'; c <= 'Z'; c++) [keys addObject:[NSString stringWithFormat:@"%c", c]];
    for (unichar c = '0'; c <= '9'; c++) [keys addObject:[NSString stringWithFormat:@"%c", c]];
    for (int i = 1; i <= 12; i++) [keys addObject:[NSString stringWithFormat:@"F%d", i]];
    [keys addObjectsFromArray:@[@"Backspace", @"Tab", @"Enter", @"Escape", @"Space",
        @"Page Up", @"Page Down", @"End", @"Home", @"Left", @"Up", @"Right", @"Down",
        @"Insert", @"Delete", @";", @"+", @"=", @",", @"-", @".", @"/", @"`", @"[", @"\\", @"]", @"'"]];
    return keys;
}

/// Returns the English popup name for a key code (matches allKeyNames).
+ (NSString *)popupNameForCode:(NSUInteger)code {
    if (code >= 'A' && code <= 'Z') return [NSString stringWithFormat:@"%c", (char)code];
    if (code >= '0' && code <= '9') return [NSString stringWithFormat:@"%c", (char)code];
    if (code >= 112 && code <= 123) return [NSString stringWithFormat:@"F%lu", (unsigned long)(code - 111)];
    if (code >= 0xF704 && code <= 0xF70F) return [NSString stringWithFormat:@"F%lu", (unsigned long)(code - 0xF704 + 1)];
    NSDictionary *map = @{@8:@"Backspace", @9:@"Tab", @13:@"Enter", @27:@"Escape", @32:@"Space",
        @33:@"Page Up", @34:@"Page Down", @35:@"End", @36:@"Home", @37:@"Left", @38:@"Up",
        @39:@"Right", @40:@"Down", @45:@"Insert", @46:@"Delete",
        @186:@";", @187:@"+", @188:@",", @189:@"-", @190:@".", @191:@"/",
        @192:@"`", @219:@"[", @220:@"\\", @221:@"]", @222:@"'",
        @0xF728:@"Delete", @0xF729:@"Home", @0xF72B:@"End",
        @0xF72C:@"Page Up", @0xF72D:@"Page Down",
        @0xF702:@"Left", @0xF703:@"Right", @0xF700:@"Up", @0xF701:@"Down"};
    return map[@(code)] ?: @"None";
}

+ (NSUInteger)keyCodeForName:(NSString *)name {
    if ([name isEqualToString:@"None"] || name.length == 0) return 0;
    NSDictionary *map = @{@"Backspace":@8, @"Tab":@9, @"Enter":@13, @"Escape":@27, @"Space":@32,
        @"Page Up":@33, @"Page Down":@34, @"End":@35, @"Home":@36, @"Left":@37, @"Up":@38,
        @"Right":@39, @"Down":@40, @"Insert":@45, @"Delete":@46, @";":@186, @"+":@187, @"=":@187,
        @",":@188, @"-":@189, @".":@190, @"/":@191, @"`":@192, @"[":@219, @"\\":@220,
        @"]":@221, @"'":@222};
    NSNumber *mapped = map[name];
    if (mapped) return mapped.unsignedIntegerValue;
    if (name.length == 1) return [name characterAtIndex:0];
    if ([name hasPrefix:@"F"] && name.length <= 3) return 111 + [name substringFromIndex:1].intValue;
    return 0;
}

+ (NSString *)menuKeyEquivalentForCode:(NSUInteger)code {
    if (code >= 'A' && code <= 'Z')
        return [[NSString stringWithFormat:@"%c", (char)code] lowercaseString];
    if (code >= '0' && code <= '9')
        return [NSString stringWithFormat:@"%c", (char)code];
    if (code >= 112 && code <= 123) {
        unichar fk = NSF1FunctionKey + (code - 112);
        return [NSString stringWithCharacters:&fk length:1];
    }
    switch (code) {
        case 8:   return [NSString stringWithFormat:@"%C", (unichar)NSBackspaceCharacter];
        case 9:   return @"\t";
        case 13:  return @"\r";
        case 27:  return [NSString stringWithFormat:@"%C", (unichar)0x1B];
        case 46:  return [NSString stringWithFormat:@"%C", (unichar)NSDeleteCharacter];
        case 186: return @";";
        case 187: return @"=";
        case 188: return @",";
        case 189: return @"-";
        case 190: return @".";
        case 191: return @"/";
        case 192: return @"`";
        case 219: return @"[";
        case 220: return @"\\";
        case 221: return @"]";
        case 222: return @"'";
        default:  return [[NSString stringWithFormat:@"%c", (char)code] lowercaseString];
    }
}
@end

// Table row view that washes a row with a faint orange tint — used to flag the
// menu-shadowed Scintilla commands. The colour is the Tahoe tab-bar "Orange"
// (#F5B67A) at ~20% alpha so it reads as a subtle highlight in light and dark.
@interface _SCMRowView : NSTableRowView
@property (nonatomic) BOOL tinted;
@end
@implementation _SCMRowView
- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    [super drawBackgroundInRect:dirtyRect];
    if (_tinted) {
        [[NSColor colorWithRed:0xF5/255.0 green:0xB6/255.0 blue:0x7A/255.0 alpha:0.20] set];
        NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    }
}
@end

// ═══════════════════════════════════════════════════════════════════════════════
// ShortcutMapperWindowController
// ═══════════════════════════════════════════════════════════════════════════════

@interface ShortcutMapperWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSControlTextEditingDelegate, NSWindowDelegate>
@end

@implementation ShortcutMapperWindowController {
    NSSegmentedControl *_segControl;
    NSTableView     *_tableView;
    NSScrollView    *_scrollView;
    NSTextField     *_filterField;
    NSTextField     *_conflictInfo;
    NSButton        *_modifyBtn, *_clearBtn, *_deleteBtn, *_closeBtn;

    // Data for each tab
    NSMutableArray<ShortcutEntry *> *_mainMenuEntries;
    NSMutableArray<ShortcutEntry *> *_macroEntries;
    NSMutableArray<ShortcutEntry *> *_runCmdEntries;
    NSMutableArray<ShortcutEntry *> *_pluginEntries;
    NSMutableArray<ShortcutEntry *> *_scintillaEntries;

    // Filtered view
    NSMutableArray<ShortcutEntry *> *_filteredEntries;
    ShortcutMapperTab _currentTab;
    BOOL _saved;
    BOOL _hasChanges;  // only save if user actually modified something
}

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 820, 560)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    win.title = [[NppLocalizer shared] translate:@"Shortcut Mapper"];
    win.minSize = NSMakeSize(600, 400);
    [win center];

    self = [super initWithWindow:win];
    if (self) {
        win.delegate = self;
        [self _buildUI];
        [self _loadAllData];
        [self _switchToTab:ShortcutMapperTabMainMenu];
    }
    return self;
}

- (void)showWithTab:(ShortcutMapperTab)tab {
    [self _switchToTab:tab];
    [self showWindow:nil];
}

// ═══════════════════════════════════════════════════════════════════════════════
// UI Construction
// ═══════════════════════════════════════════════════════════════════════════════

- (void)_buildUI {
    NSView *cv = self.window.contentView;

    // Segmented control for tabs (matching Windows tab bar appearance)
    NppLocalizer *loc = [NppLocalizer shared];
    NSSegmentedControl *seg = [NSSegmentedControl segmentedControlWithLabels:
        @[[loc translate:@"Main menu"], [loc translate:@"Macros"], [loc translate:@"Run commands"], [loc translate:@"Plugin commands"], [loc translate:@"Scintilla commands"]]
        trackingMode:NSSegmentSwitchTrackingSelectOne
        target:self action:@selector(_tabSegmentChanged:)];
    seg.translatesAutoresizingMaskIntoConstraints = NO;
    seg.selectedSegment = 0;
    seg.segmentStyle = NSSegmentStyleTexturedSquare;
    [cv addSubview:seg];
    _segControl = seg;

    // Table view inside scroll view
    _tableView = [[NSTableView alloc] init];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 20;
    _tableView.allowsMultipleSelection = NO;
    _tableView.usesAlternatingRowBackgroundColors = YES;
    _tableView.target = self;
    _tableView.doubleAction = @selector(_modifyShortcut:);
    _tableView.gridStyleMask = NSTableViewSolidHorizontalGridLineMask | NSTableViewSolidVerticalGridLineMask;

    // Row number column
    NSTableColumn *numCol = [[NSTableColumn alloc] initWithIdentifier:@"num"];
    numCol.title = @"";
    numCol.width = 30;
    numCol.minWidth = 30;
    numCol.maxWidth = 40;
    [_tableView addTableColumn:numCol];

    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameCol.title = [loc translate:@"Name"];
    nameCol.width = 350;
    nameCol.resizingMask = NSTableColumnAutoresizingMask;
    [nameCol.headerCell setFont:[NSFont boldSystemFontOfSize:13]];
    [_tableView addTableColumn:nameCol];

    NSTableColumn *shortcutCol = [[NSTableColumn alloc] initWithIdentifier:@"shortcut"];
    shortcutCol.title = [loc translate:@"Shortcut"];
    shortcutCol.width = 180;
    [shortcutCol.headerCell setFont:[NSFont boldSystemFontOfSize:13]];
    [_tableView addTableColumn:shortcutCol];

    NSTableColumn *catCol = [[NSTableColumn alloc] initWithIdentifier:@"category"];
    catCol.title = [loc translate:@"Category"];
    catCol.width = 150;
    [catCol.headerCell setFont:[NSFont boldSystemFontOfSize:13]];
    [_tableView addTableColumn:catCol];

    _scrollView = [[NSScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.borderType = NSBezelBorder;
    _scrollView.documentView = _tableView;
    [cv addSubview:_scrollView];

    // Conflict info
    _conflictInfo = [[NSTextField alloc] init];
    _conflictInfo.translatesAutoresizingMaskIntoConstraints = NO;
    _conflictInfo.editable = NO;
    _conflictInfo.bordered = YES;
    _conflictInfo.bezeled = YES;
    _conflictInfo.bezelStyle = NSTextFieldSquareBezel;
    _conflictInfo.font = [NSFont systemFontOfSize:11];
    _conflictInfo.stringValue = [loc translate:[[NppLocalizer shared] translate:@"No shortcut conflicts for this item."]];
    [cv addSubview:_conflictInfo];

    // Filter
    NSTextField *filterLabel = [NSTextField labelWithString:[loc translate:@"Filter:"]];
    filterLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:filterLabel];

    _filterField = [[NSTextField alloc] init];
    _filterField.translatesAutoresizingMaskIntoConstraints = NO;
    _filterField.placeholderString = [loc translate:@"Type to filter..."];
    _filterField.delegate = (id<NSTextFieldDelegate>)self;
    [cv addSubview:_filterField];

    // Buttons
    _modifyBtn = [NSButton buttonWithTitle:[loc translate:@"Modify"] target:self action:@selector(_modifyShortcut:)];
    _clearBtn  = [NSButton buttonWithTitle:[loc translate:@"Clear"]  target:self action:@selector(_clearShortcut:)];
    _deleteBtn = [NSButton buttonWithTitle:[loc translate:@"Delete"] target:self action:@selector(_deleteShortcut:)];
    _closeBtn  = [NSButton buttonWithTitle:[loc translate:@"Close"]  target:self action:@selector(_close:)];
    _closeBtn.keyEquivalent = @"\r";
    for (NSButton *b in @[_modifyBtn, _clearBtn, _deleteBtn, _closeBtn]) {
        b.translatesAutoresizingMaskIntoConstraints = NO;
        b.bezelStyle = NSBezelStyleRounded;
        [cv addSubview:b];
    }

    // Layout
    [NSLayoutConstraint activateConstraints:@[
        [seg.topAnchor constraintEqualToAnchor:cv.topAnchor constant:10],
        [seg.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:10],

        [_scrollView.topAnchor constraintEqualToAnchor:seg.bottomAnchor constant:6],
        [_scrollView.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:10],
        [_scrollView.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-10],
        [_scrollView.bottomAnchor constraintEqualToAnchor:_conflictInfo.topAnchor constant:-8],

        [_conflictInfo.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:10],
        [_conflictInfo.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-10],
        [_conflictInfo.heightAnchor constraintEqualToConstant:40],
        [_conflictInfo.bottomAnchor constraintEqualToAnchor:filterLabel.topAnchor constant:-6],

        [filterLabel.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:10],
        [filterLabel.centerYAnchor constraintEqualToAnchor:_filterField.centerYAnchor],
        [_filterField.leadingAnchor constraintEqualToAnchor:filterLabel.trailingAnchor constant:4],
        [_filterField.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-10],
        [_filterField.bottomAnchor constraintEqualToAnchor:_modifyBtn.topAnchor constant:-10],
        [_filterField.heightAnchor constraintEqualToConstant:22],

        [_closeBtn.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-10],
        [_closeBtn.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor constant:-10],
        [_closeBtn.widthAnchor constraintEqualToConstant:80],
        [_deleteBtn.trailingAnchor constraintEqualToAnchor:_closeBtn.leadingAnchor constant:-8],
        [_deleteBtn.bottomAnchor constraintEqualToAnchor:_closeBtn.bottomAnchor],
        [_deleteBtn.widthAnchor constraintEqualToConstant:80],
        [_clearBtn.trailingAnchor constraintEqualToAnchor:_deleteBtn.leadingAnchor constant:-8],
        [_clearBtn.bottomAnchor constraintEqualToAnchor:_closeBtn.bottomAnchor],
        [_clearBtn.widthAnchor constraintEqualToConstant:80],
        [_modifyBtn.trailingAnchor constraintEqualToAnchor:_clearBtn.leadingAnchor constant:-8],
        [_modifyBtn.bottomAnchor constraintEqualToAnchor:_closeBtn.bottomAnchor],
        [_modifyBtn.widthAnchor constraintEqualToConstant:80],
    ]];
}

- (void)_tabSegmentChanged:(NSSegmentedControl *)seg {
    [self _switchToTab:(ShortcutMapperTab)seg.selectedSegment];
}

// ═══════════════════════════════════════════════════════════════════════════════
// Data Loading
// ═══════════════════════════════════════════════════════════════════════════════

- (void)_loadAllData {
    [self _loadMainMenuEntries];
    [self _loadMacroEntries];
    [self _loadRunCommandEntries];
    [self _loadPluginEntries];
    [self _loadScintillaEntries];
}

/// Walk the live application menu recursively to build the Main Menu tab data.
- (void)_loadMainMenuEntries {
    _mainMenuEntries = [NSMutableArray array];
    NSMenu *mainMenu = [NSApp mainMenu];
    NSLog(@"[ShortcutMapper] Main menu top-level items: %ld", (long)mainMenu.numberOfItems);

    for (NSUInteger i = 0; i < mainMenu.itemArray.count; i++) {
        NSMenuItem *topItem = mainMenu.itemArray[i];
        if (!topItem.submenu) continue;

        // The menu name is the submenu's title (topItem.title may return class name).
        // The App menu (index 0) has an empty submenu.title — fall through to the
        // "Application" label so its entries (Hide / Quit / Preferences / etc.) appear
        // in a recognisable category. We deliberately INCLUDE the App menu now so the
        // conflict checker can spot collisions with ⌘H / ⌘Q / ⌘, / ⌘M instead of
        // silently letting users rebind something to one of those system shortcuts.
        NSString *category = topItem.submenu.title;
        if (i == 0 && (!category.length || [category isEqualToString:@"NSMenuItem"]))
            category = @"Application";
        if (!category.length) category = topItem.title;
        if (!category.length || [category isEqualToString:@"NSMenuItem"]) category = @"Other";

        @try {
            // Force the submenu to populate
            [topItem.submenu update];
            NSUInteger before = _mainMenuEntries.count;
            [self _walkMenu:topItem.submenu category:category];
            NSLog(@"[ShortcutMapper]   %@ (%lu → %lu items, submenu has %ld items)",
                  category, (unsigned long)before, (unsigned long)_mainMenuEntries.count,
                  (long)topItem.submenu.numberOfItems);
        } @catch (NSException *ex) {
            NSLog(@"[ShortcutMapper] EXCEPTION walking %@: %@", category, ex);
        }
    }
    // Mark entries that have overrides in shortcuts.xml and restore their shortcuts
    // from the XML (macOS may silently clear duplicate keyEquivalents on live menu items)
    NSString *scPath = NppConfigSubpath(@"shortcuts.xml");
    NSData *scData = [NSData dataWithContentsOfFile:scPath];
    if (scData) {
        NSXMLDocument *scDoc = [[NSXMLDocument alloc] initWithData:scData options:0 error:nil];
        if (scDoc) {
            NSArray *overrides = [scDoc nodesForXPath:@"//InternalCommands/Shortcut" error:nil];
            NSMutableDictionary *overrideMap = [NSMutableDictionary dictionary]; // sel → NSXMLElement
            for (NSXMLElement *sc in overrides) {
                NSString *selId = [[sc attributeForName:@"id"] stringValue];
                if (selId.length) overrideMap[selId] = sc;
            }
            for (ShortcutEntry *e in _mainMenuEntries) {
                NSXMLElement *sc = overrideMap[e.selectorName];
                if (!sc) continue;
                e.isModified = YES;
                // Read shortcut from XML (not live menu — macOS may have cleared it)
                e.hasCtrl  = [[[sc attributeForName:@"Ctrl"]  stringValue] isEqualToString:@"yes"];
                e.hasAlt   = [[[sc attributeForName:@"Alt"]   stringValue] isEqualToString:@"yes"];
                e.hasShift = [[[sc attributeForName:@"Shift"] stringValue] isEqualToString:@"yes"];
                e.hasCmd   = [[[sc attributeForName:@"Cmd"]   stringValue] isEqualToString:@"yes"];
                e.keyCode  = [[[sc attributeForName:@"Key"]   stringValue] integerValue];
                // Backward compat: if no Cmd attribute, treat Ctrl as Cmd (Windows convention)
                if (!e.hasCmd && e.hasCtrl && ![sc attributeForName:@"Cmd"]) {
                    e.hasCmd = YES; e.hasCtrl = NO;
                }
                [e updateDisplay];
            }
            NSLog(@"[ShortcutMapper] Marked %lu entries as having overrides (from shortcuts.xml)",
                  (unsigned long)overrideMap.count);
        }
    }

    NSLog(@"[ShortcutMapper] Main menu total: %lu entries", (unsigned long)_mainMenuEntries.count);
}

- (void)_walkMenu:(NSMenu *)menu category:(NSString *)category {
    // Selectors to skip (dynamic / repeated items where adding entries would
    // pollute the table or fire phantom conflicts):
    //   • openRecentFile:  — recent-files items vary per session
    //   • runSavedMacro:   — already covered by the Macros tab
    //   • pluginMenuAction: / pluginToolbarAction: — already covered by Plugins tab
    //   • submenuAction:   — internal Cocoa wrapper for parent submenu items
    //   • _showAllCharsDropdown: — dynamic toolbar dropdown anchor
    //
    // System selectors (hide:, terminate:, performMiniaturize:, etc.) are
    // INTENTIONALLY left in the table so the conflict checker can detect
    // collisions with ⌘H, ⌘Q, ⌘M, ⌃⌘F, etc. They appear in the "Application"
    // / "Window" categories and are reassignable like any other shortcut.
    static NSSet *skipSelectors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        skipSelectors = [NSSet setWithObjects:
            @"openRecentFile:", @"runSavedMacro:", @"pluginMenuAction:",
            @"pluginToolbarAction:", @"submenuAction:", @"_showAllCharsDropdown:",
            nil];
    });

    for (NSMenuItem *mi in menu.itemArray) {
        if (mi.isSeparatorItem) continue;
        if (mi.submenu) {
            [mi.submenu update]; // force populate lazy submenus
            [self _walkMenu:mi.submenu category:category];
            continue;
        }
        if (!mi.action) continue;

        // Skip dynamic/system items
        NSString *selName = NSStringFromSelector(mi.action);
        if ([skipSelectors containsObject:selName]) continue;
        // Skip empty-titled items
        if (mi.title.length == 0) continue;

        ShortcutEntry *e = [[ShortcutEntry alloc] init];
        e.name = mi.title;
        e.category = category;
        e.selectorName = NSStringFromSelector(mi.action);
        e.commandID = mi.tag;

        // Extract current key equivalent
        NSString *key = mi.keyEquivalent;
        NSEventModifierFlags mods = mi.keyEquivalentModifierMask;
        if (key.length > 0 && [key characterAtIndex:0] > 32) {
            e.hasCmd   = (mods & NSEventModifierFlagCommand) != 0;
            e.hasCtrl  = (mods & NSEventModifierFlagControl) != 0;
            e.hasAlt   = (mods & NSEventModifierFlagOption)  != 0;
            e.hasShift = (mods & NSEventModifierFlagShift)   != 0;
            unichar c = [key.uppercaseString characterAtIndex:0];
            e.keyCode = c;
        } else if (key.length > 0) {
            // Function keys and special keys
            unichar c = [key characterAtIndex:0];
            e.hasCmd   = (mods & NSEventModifierFlagCommand) != 0;
            e.hasCtrl  = (mods & NSEventModifierFlagControl) != 0;
            e.hasAlt   = (mods & NSEventModifierFlagOption)  != 0;
            e.hasShift = (mods & NSEventModifierFlagShift)   != 0;
            // Map NSFunctionKey characters to Windows VK codes
            if (c >= NSF1FunctionKey && c <= NSF12FunctionKey)
                e.keyCode = 112 + (c - NSF1FunctionKey);
            else
                e.keyCode = c;
        }
        [e updateDisplay];
        // Debug: log entries with overrides
        if (e.keyCode > 0 || [e.selectorName isEqualToString:@"toggleIndentGuides:"])
            NSLog(@"[ShortcutMapper] Entry: '%@' sel=%@ key='%@' keyCode=%lu mods=cmd:%d alt:%d shift:%d display='%@'",
                  e.name, e.selectorName, mi.keyEquivalent, (unsigned long)e.keyCode,
                  e.hasCmd, e.hasAlt, e.hasShift, e.shortcutDisplay);
        [_mainMenuEntries addObject:e];
    }
}

- (void)_loadMacroEntries {
    _macroEntries = [NSMutableArray array];
    NSString *path = NppConfigSubpath(@"shortcuts.xml");
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:nil];
    if (!doc) return;
    for (NSXMLElement *el in [doc nodesForXPath:@"//Macros/Macro" error:nil]) {
        ShortcutEntry *e = [[ShortcutEntry alloc] init];
        e.name = [[el attributeForName:@"name"] stringValue] ?: @"";
        e.hasCtrl  = [[[el attributeForName:@"Ctrl"]  stringValue] isEqualToString:@"yes"];
        e.hasAlt   = [[[el attributeForName:@"Alt"]   stringValue] isEqualToString:@"yes"];
        e.hasShift = [[[el attributeForName:@"Shift"] stringValue] isEqualToString:@"yes"];
        e.hasCmd   = [[[el attributeForName:@"Cmd"]   stringValue] isEqualToString:@"yes"];
        e.keyCode  = [[[el attributeForName:@"Key"]   stringValue] integerValue];
        // Backward compat: if no Cmd attribute exists, treat Ctrl as Cmd (Windows convention)
        if (!e.hasCmd && e.hasCtrl && ![el attributeForName:@"Cmd"]) {
            e.hasCmd = YES; e.hasCtrl = NO;
        }
        [e updateDisplay];
        [_macroEntries addObject:e];
    }
    NSLog(@"[ShortcutMapper] Macros: %lu entries", (unsigned long)_macroEntries.count);
}

- (void)_loadRunCommandEntries {
    _runCmdEntries = [NSMutableArray array];

    // Load from shortcuts.xml <UserDefinedCommands> only (matches Windows behavior)
    NSString *path = NppConfigSubpath(@"shortcuts.xml");
    NSData *data = [NSData dataWithContentsOfFile:path];

    // If no UserDefinedCommands exist in shortcuts.xml, create defaults
    BOOL hasUserCmds = NO;
    if (data) {
        NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:nil];
        if (doc) {
            NSArray *cmds = [doc nodesForXPath:@"//UserDefinedCommands/Command" error:nil];
            hasUserCmds = (cmds.count > 0);
            for (NSXMLElement *el in cmds) {
                ShortcutEntry *e = [[ShortcutEntry alloc] init];
                e.name = [[el attributeForName:@"name"] stringValue] ?: @"";
                e.hasCtrl  = [[[el attributeForName:@"Ctrl"]  stringValue] isEqualToString:@"yes"];
                e.hasAlt   = [[[el attributeForName:@"Alt"]   stringValue] isEqualToString:@"yes"];
                e.hasShift = [[[el attributeForName:@"Shift"] stringValue] isEqualToString:@"yes"];
                e.hasCmd   = [[[el attributeForName:@"Cmd"]   stringValue] isEqualToString:@"yes"];
                e.keyCode  = [[[el attributeForName:@"Key"]   stringValue] integerValue];
                if (!e.hasCmd && e.hasCtrl && ![el attributeForName:@"Cmd"]) {
                    e.hasCmd = YES; e.hasCtrl = NO;
                }
                [e updateDisplay];
                [_runCmdEntries addObject:e];
            }
        }
    }

    // Default entries come from the bundled shortcuts.xml (copied to ~/Library/Application Support/Nextpad++/ on first run)
    NSLog(@"[ShortcutMapper] Run commands: %lu entries", (unsigned long)_runCmdEntries.count);
}

- (void)_loadPluginEntries {
    _pluginEntries = [NSMutableArray array];
    // Walk the Plugins menu to extract plugin commands. Use the tag-based
    // lookup so this works regardless of UI language — a literal-title
    // scan would fall through and the Shortcut Mapper's Plugins tab would
    // be empty in any non-English locale.
    NSMenu *pluginsMenu = [[[NSApp mainMenu] itemWithTag:kMenuTagPlugins] submenu];
    if (!pluginsMenu) {
        NSLog(@"[ShortcutMapper] Plugins menu not found (tag missing)");
        return;
    }
    [pluginsMenu update];
    for (NSMenuItem *pluginItem in pluginsMenu.itemArray) {
        if (pluginItem.isSeparatorItem) continue;
        if (!pluginItem.submenu) continue;
        NSString *plugName = pluginItem.title;
        if (!plugName.length) continue;
        [pluginItem.submenu update];
        for (NSMenuItem *cmdItem in pluginItem.submenu.itemArray) {
            if (cmdItem.isSeparatorItem || !cmdItem.action) continue;
            if (!cmdItem.title.length) continue;
            // Skip separator-like items (plugins use "-" as title for separators)
            NSString *trimmed = [cmdItem.title stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"- "]];
            if (trimmed.length == 0) continue;
            ShortcutEntry *e = [[ShortcutEntry alloc] init];
            e.name = cmdItem.title;
            e.pluginName = plugName;
            e.commandID = cmdItem.tag;
            e.selectorName = NSStringFromSelector(cmdItem.action);
            // Extract key
            NSString *key = cmdItem.keyEquivalent;
            NSEventModifierFlags mods = cmdItem.keyEquivalentModifierMask;
            if (key.length > 0 && [key characterAtIndex:0] > 32) {
                e.hasCmd   = (mods & NSEventModifierFlagCommand) != 0;
                e.hasCtrl  = (mods & NSEventModifierFlagControl) != 0;
                e.hasAlt   = (mods & NSEventModifierFlagOption)  != 0;
                e.hasShift = (mods & NSEventModifierFlagShift)   != 0;
                e.keyCode  = [key.uppercaseString characterAtIndex:0];
            }
            [e updateDisplay];
            [_pluginEntries addObject:e];
        }
    }
    NSLog(@"[ShortcutMapper] Plugin commands: %lu entries", (unsigned long)_pluginEntries.count);
}

- (void)_loadScintillaEntries {
    _scintillaEntries = [NSMutableArray array];
    // Hardcoded Scintilla command definitions matching Windows scintKeyDefs[]
    struct SciKeyDef { const char *name; int sciID; BOOL ctrl; BOOL alt; BOOL shift; int key; };
    static const struct SciKeyDef defs[] = {
        {"SCI_SELECTALL",            2013, YES, NO,  NO,  'A'},
        {"SCI_CLEAR",                2180, NO,  NO,  NO,  46},  // Delete
        {"SCI_CLEARALL",             2004, NO,  NO,  NO,  0},
        {"SCI_UNDO",                 2176, YES, NO,  NO,  'Z'},
        {"SCI_REDO",                 2011, YES, NO,  YES, 'Z'},
        {"SCI_NEWLINE",              2329, NO,  NO,  NO,  13},  // Enter
        {"SCI_TAB",                  2327, NO,  NO,  NO,  9},
        {"SCI_BACKTAB",              2328, NO,  NO,  YES, 9},
        {"SCI_FORMFEED",             2330, NO,  NO,  NO,  0},
        {"SCI_ZOOMIN",               2333, YES, NO,  NO,  187}, // =
        {"SCI_ZOOMOUT",              2334, YES, NO,  NO,  189}, // -
        {"SCI_SETZOOM",              2373, YES, NO,  NO,  191}, // /
        {"SCI_SELECTIONDUPLICATE",   2469, YES, NO,  NO,  'D'},
        {"SCI_LINESJOIN",            2288, NO,  NO,  NO,  0},
        {"SCI_SCROLLCARET",          2169, NO,  NO,  NO,  0},
        {"SCI_EDITTOGGLEOVERTYPE",   2324, NO,  NO,  NO,  45},  // Insert
        {"SCI_MOVECARETINSIDEVIEW",  2401, NO,  NO,  NO,  0},
        {"SCI_LINEDOWN",             2300, NO,  NO,  NO,  40},  // Down
        {"SCI_LINEDOWNEXTEND",       2301, NO,  NO,  YES, 40},
        {"SCI_LINEDOWNRECTEXTEND",   2426, NO,  YES, YES, 40},  // Opt+Shift+Down
        {"SCI_LINESCROLLDOWN",       2342, YES, NO,  NO,  40},
        {"SCI_LINEUP",               2302, NO,  NO,  NO,  38},  // Up
        {"SCI_LINEUPEXTEND",         2303, NO,  NO,  YES, 38},
        {"SCI_LINEUPRECTEXTEND",     2427, NO,  YES, YES, 38},  // Opt+Shift+Up
        {"SCI_LINESCROLLUP",         2343, YES, NO,  NO,  38},
        {"SCI_PARADOWN",             2413, YES, NO,  NO,  221}, // ]
        {"SCI_PARADOWNEXTEND",       2414, YES, NO,  YES, 221},
        {"SCI_PARAUP",               2415, YES, NO,  NO,  219}, // [
        {"SCI_PARAUPEXTEND",         2416, YES, NO,  YES, 219},
        {"SCI_CHARLEFT",             2304, NO,  NO,  NO,  37},  // Left
        {"SCI_CHARLEFTEXTEND",       2305, NO,  NO,  YES, 37},
        {"SCI_CHARLEFTRECTEXTEND",   2428, NO,  YES, YES, 37},  // Opt+Shift+Left
        {"SCI_CHARRIGHT",            2306, NO,  NO,  NO,  39},  // Right
        {"SCI_CHARRIGHTEXTEND",      2307, NO,  NO,  YES, 39},
        {"SCI_CHARRIGHTRECTEXTEND",  2429, NO,  YES, YES, 39},  // Opt+Shift+Right
        {"SCI_WORDLEFT",             2308, YES, NO,  NO,  37},
        {"SCI_WORDLEFTEXTEND",       2309, YES, NO,  YES, 37},
        {"SCI_WORDLEFTEND",          2439, NO,  NO,  NO,  0},
        {"SCI_WORDLEFTENDEXTEND",    2440, NO,  NO,  NO,  0},
        {"SCI_WORDRIGHT",            2310, YES, NO,  NO,  39},
        {"SCI_WORDRIGHTEXTEND",      2311, YES, NO,  YES, 39},
        {"SCI_WORDRIGHTEND",         2441, NO,  NO,  NO,  0},
        {"SCI_WORDRIGHTENDEXTEND",   2442, NO,  NO,  NO,  0},
        {"SCI_WORDPARTLEFT",         2390, YES, NO,  NO,  191},
        {"SCI_WORDPARTLEFTEXTEND",   2391, YES, NO,  YES, 191},
        {"SCI_WORDPARTRIGHT",        2392, YES, NO,  NO,  220},
        {"SCI_WORDPARTRIGHTEXTEND",  2393, YES, NO,  YES, 220},
        {"SCI_HOME",                 2312, NO,  NO,  NO,  36},
        {"SCI_HOMEEXTEND",           2313, NO,  NO,  YES, 36},
        {"SCI_HOMERECTEXTEND",       2430, NO,  NO,  NO,  0},
        {"SCI_HOMEDISPLAY",          2345, NO,  YES, NO,  36},  // Opt+Home
        {"SCI_HOMEDISPLAYEXTEND",    2346, NO,  NO,  NO,  0},
        {"SCI_HOMEWRAP",             2349, NO,  NO,  NO,  0},
        {"SCI_HOMEWRAPEXTEND",       2450, NO,  NO,  NO,  0},
        {"SCI_VCHOME",               2331, NO,  NO,  NO,  0},
        {"SCI_VCHOMEEXTEND",         2332, NO,  NO,  NO,  0},
        {"SCI_VCHOMERECTEXTEND",     2431, NO,  YES, YES, 36},  // Opt+Shift+Home
        {"SCI_VCHOMEDISPLAY",        2652, NO,  NO,  NO,  0},
        {"SCI_VCHOMEDISPLAYEXTEND",  2653, NO,  NO,  NO,  0},
        {"SCI_VCHOMEWRAP",           2453, NO,  NO,  NO,  0},
        {"SCI_VCHOMEWRAPEXTEND",     2454, NO,  NO,  NO,  0},
        {"SCI_LINEEND",              2314, NO,  NO,  NO,  35},
        {"SCI_LINEENDEXTEND",        2315, NO,  NO,  YES, 35},
        {"SCI_LINEENDRECTEXTEND",    2432, NO,  YES, YES, 35},  // Opt+Shift+End
        {"SCI_LINEENDDISPLAY",       2347, NO,  YES, NO,  35},  // Opt+End
        {"SCI_LINEENDDISPLAYEXTEND", 2348, NO,  NO,  NO,  0},
        {"SCI_LINEENDWRAP",          2451, NO,  NO,  NO,  0},
        {"SCI_LINEENDWRAPEXTEND",    2452, NO,  NO,  NO,  0},
        {"SCI_DOCUMENTSTART",        2316, YES, NO,  NO,  36},
        {"SCI_DOCUMENTSTARTEXTEND",  2317, YES, NO,  YES, 36},
        {"SCI_DOCUMENTEND",          2318, YES, NO,  NO,  35},
        {"SCI_DOCUMENTENDEXTEND",    2319, YES, NO,  YES, 35},
        {"SCI_PAGEUP",               2320, NO,  NO,  NO,  33},
        {"SCI_PAGEUPEXTEND",         2321, NO,  NO,  YES, 33},
        {"SCI_PAGEUPRECTEXTEND",     2433, NO,  YES, YES, 33},  // Opt+Shift+PageUp
        {"SCI_PAGEDOWN",             2322, NO,  NO,  NO,  34},
        {"SCI_PAGEDOWNEXTEND",       2323, NO,  NO,  YES, 34},
        {"SCI_PAGEDOWNRECTEXTEND",   2434, NO,  YES, YES, 34},  // Opt+Shift+PageDown
        {"SCI_DELETEBACK",           2326, NO,  NO,  NO,  8},
        {"SCI_DELETEBACKNOTLINE",    2344, NO,  NO,  NO,  0},
        {"SCI_DELWORDLEFT",          2335, YES, NO,  NO,  8},
        {"SCI_DELWORDRIGHT",         2336, YES, NO,  NO,  46},
        {"SCI_DELLINELEFT",          2395, YES, NO,  YES, 8},
        {"SCI_DELLINERIGHT",         2396, YES, NO,  YES, 46},
        {"SCI_LINEDELETE",           2338, YES, NO,  YES, 'L'},
        {"SCI_LINECUT",              2337, YES, NO,  NO,  'L'},
        {"SCI_LINECOPY",             2455, YES, NO,  YES, 'X'},
        {"SCI_LINETRANSPOSE",        2339, YES, NO,  NO,  'T'},
        {"SCI_LINEDUPLICATE",        2404, NO,  NO,  NO,  0},
        {"SCI_CUT",                  2177, YES, NO,  NO,  'X'},
        {"SCI_COPY",                 2178, YES, NO,  NO,  'C'},
        {"SCI_PASTE",                2179, YES, NO,  NO,  'V'},
        {"SCI_CANCEL",               2325, NO,  NO,  NO,  27},
        {"SCI_STUTTEREDPAGEUP",      2435, NO,  NO,  NO,  0},
        {"SCI_STUTTEREDPAGEUPEXTEND",2436, NO,  NO,  NO,  0},
        {"SCI_STUTTEREDPAGEDOWN",    2437, NO,  NO,  NO,  0},
        {"SCI_STUTTEREDPAGEDOWNEXTEND",2438,NO, NO,  NO,  0},
        {"SCI_SWAPMAINANCHORCARET",  2607, NO,  NO,  NO,  0},
        {"SCI_ROTATESELECTION",      2606, NO,  NO,  NO,  0},
    };
    // Read existing overrides from shortcuts.xml
    NSString *path = NppConfigSubpath(@"shortcuts.xml");
    NSData *xmlData = [NSData dataWithContentsOfFile:path];
    NSXMLDocument *xmlDoc = xmlData ? [[NSXMLDocument alloc] initWithData:xmlData options:0 error:nil] : nil;
    NSArray *xmlScintKeys = xmlDoc ? [xmlDoc nodesForXPath:@"//ScintillaKeys/ScintKey" error:nil] : @[];
    // Build a lookup: sciID → NSXMLElement
    NSMutableDictionary<NSNumber *, NSXMLElement *> *overrides = [NSMutableDictionary dictionary];
    for (NSXMLElement *sk in xmlScintKeys) {
        int sciID = [[[sk attributeForName:@"ScintID"] stringValue] intValue];
        overrides[@(sciID)] = sk;
    }

    for (size_t i = 0; i < sizeof(defs)/sizeof(defs[0]); i++) {
        ShortcutEntry *e = [[ShortcutEntry alloc] init];
        e.name = [NSString stringWithUTF8String:defs[i].name];
        e.commandID = defs[i].sciID;

        // Check if there's an override in shortcuts.xml
        NSXMLElement *ovr = overrides[@(defs[i].sciID)];
        if (ovr) {
            BOOL hasCtrl  = [[[ovr attributeForName:@"Ctrl"]  stringValue] isEqualToString:@"yes"];
            BOOL hasAlt   = [[[ovr attributeForName:@"Alt"]   stringValue] isEqualToString:@"yes"];
            BOOL hasShift = [[[ovr attributeForName:@"Shift"] stringValue] isEqualToString:@"yes"];
            BOOL hasCmd   = [[[ovr attributeForName:@"Cmd"]   stringValue] isEqualToString:@"yes"];
            NSUInteger keyCode = [[[ovr attributeForName:@"Key"] stringValue] integerValue];
            // Backward compat: old files without Cmd attribute treat Ctrl as Command
            if (!hasCmd && hasCtrl && ![ovr attributeForName:@"Cmd"]) {
                hasCmd = YES; hasCtrl = NO;
            }
            e.hasCmd   = hasCmd;
            e.hasCtrl  = hasCtrl;
            e.hasAlt   = hasAlt;
            e.hasShift = hasShift;
            e.keyCode  = keyCode;
            e.isModified = YES; // mark so it gets re-saved
        } else {
            // Map Windows Ctrl to macOS Cmd (defaults)
            e.hasCmd   = defs[i].ctrl;
            e.hasAlt   = defs[i].alt;
            e.hasShift = defs[i].shift;
            e.keyCode  = defs[i].key;
        }
        // The 6 standard-edit commands whose Scintilla-tab shortcut sits on the EXACT
        // same key as a Cocoa Edit-menu item (Select All ⌘A, Undo ⌘Z, Redo ⌘⇧Z, Cut ⌘X,
        // Copy ⌘C, Paste ⌘V). AppKit fires the menu first, so changing them here is a
        // no-op — they're highlighted to signal that. They stay editable (info-only).
        // (Zoom/SelectionDuplicate are NOT included: their Scintilla keys differ from the
        // menu's ⌘+/⌘-/⌘0/⌘D, so those overrides actually take effect.)
        switch (defs[i].sciID) {
            case 2013: // SCI_SELECTALL
            case 2176: // SCI_UNDO
            case 2011: // SCI_REDO
            case 2177: // SCI_CUT
            case 2178: // SCI_COPY
            case 2179: // SCI_PASTE
                e.isMenuShadowed = YES; break;
            default: break;
        }
        [e updateDisplay];
        [_scintillaEntries addObject:e];
    }
    NSLog(@"[ShortcutMapper] Scintilla commands: %lu entries (%lu overrides from XML)",
          (unsigned long)_scintillaEntries.count, (unsigned long)overrides.count);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tab Switching
// ═══════════════════════════════════════════════════════════════════════════════

- (void)_switchToTab:(ShortcutMapperTab)tab {
    _currentTab = tab;
    _segControl.selectedSegment = tab;

    // Show/hide Category column based on tab
    NSTableColumn *catCol = [_tableView tableColumnWithIdentifier:@"category"];
    catCol.hidden = (tab != ShortcutMapperTabMainMenu);
    catCol.title = (tab == ShortcutMapperTabPluginCommands) ? [[NppLocalizer shared] translate:@"Plugin"] : [[NppLocalizer shared] translate:@"Category"];
    if (tab == ShortcutMapperTabPluginCommands) catCol.hidden = NO;

    // Enable/disable Delete button
    _deleteBtn.enabled = (tab == ShortcutMapperTabMacros || tab == ShortcutMapperTabRunCommands);

    [self _applyFilter];
}

// Tab switching handled by _tabSegmentChanged:

// ═══════════════════════════════════════════════════════════════════════════════
// Filtering
// ═══════════════════════════════════════════════════════════════════════════════

- (NSMutableArray<ShortcutEntry *> *)_entriesForCurrentTab {
    switch (_currentTab) {
        case ShortcutMapperTabMainMenu:        return _mainMenuEntries;
        case ShortcutMapperTabMacros:          return _macroEntries;
        case ShortcutMapperTabRunCommands:     return _runCmdEntries;
        case ShortcutMapperTabPluginCommands:  return _pluginEntries;
        case ShortcutMapperTabScintillaCommands: return _scintillaEntries;
    }
    return _mainMenuEntries;
}

- (void)_applyFilter {
    NSString *filter = _filterField.stringValue;
    NSMutableArray *source = [self _entriesForCurrentTab];

    if (filter.length == 0) {
        _filteredEntries = source;
    } else {
        _filteredEntries = [NSMutableArray array];
        for (ShortcutEntry *e in source) {
            if ([e.name rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [e.shortcutDisplay rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound ||
                (e.category && [e.category rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound)) {
                [_filteredEntries addObject:e];
            }
        }
    }
    [_tableView reloadData];
    _conflictInfo.stringValue = [[NppLocalizer shared] translate:@"No shortcut conflicts for this item."];
}

- (void)_filterChanged:(id)sender {
    [self _applyFilter];
}

// Live filtering as user types (no need to hit Enter)
- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == _filterField) {
        [self _applyFilter];
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// NSTableViewDataSource / Delegate
// ═══════════════════════════════════════════════════════════════════════════════

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_filteredEntries.count;
}

// Returns a row view that paints a subtle orange wash behind menu-shadowed Scintilla
// commands (see _loadScintillaEntries) so users can tell those rows are menu-driven.
- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    _SCMRowView *rv = [tableView makeViewWithIdentifier:@"SCMRow" owner:nil];
    if (!rv) { rv = [[_SCMRowView alloc] init]; rv.identifier = @"SCMRow"; }
    rv.tinted = (row >= 0 && row < (NSInteger)_filteredEntries.count) && _filteredEntries[row].isMenuShadowed;
    return rv;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_filteredEntries.count) return nil;
    ShortcutEntry *e = _filteredEntries[row];
    NSString *colID = tableColumn.identifier;

    // Determine text for this cell
    NSString *text = @"";
    if ([colID isEqualToString:@"num"])
        text = [NSString stringWithFormat:@"%ld", (long)(row + 1)];
    else if ([colID isEqualToString:@"name"])
        text = e.name ?: @"";
    else if ([colID isEqualToString:@"shortcut"])
        text = e.shortcutDisplay ?: @"";
    else if ([colID isEqualToString:@"category"])
        text = (_currentTab == ShortcutMapperTabPluginCommands)
            ? (e.pluginName ?: @"") : (e.category ?: @"");

    // Use a single identifier for all cells (same as DocumentListPanel pattern)
    NSTextField *cell = [tableView makeViewWithIdentifier:@"SCell" owner:nil];
    if (!cell) {
        cell = [[NSTextField alloc] init];
        cell.identifier = @"SCell";
        cell.editable = NO;
        cell.bordered = NO;
        cell.drawsBackground = NO;
    }
    cell.stringValue = text;
    cell.font = [NSFont systemFontOfSize:12];
    cell.textColor = [NSColor labelColor];
    cell.alignment = [colID isEqualToString:@"num"] ? NSTextAlignmentRight : NSTextAlignmentLeft;
    if ([colID isEqualToString:@"num"]) {
        cell.textColor = [NSColor secondaryLabelColor];
        cell.font = [NSFont systemFontOfSize:11];
    }
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_filteredEntries.count) {
        _conflictInfo.stringValue = [[NppLocalizer shared] translate:@"No shortcut conflicts for this item."];
        return;
    }
    ShortcutEntry *e = _filteredEntries[row];
    if (e.keyCode == 0) {
        _conflictInfo.stringValue = [[NppLocalizer shared] translate:@"No shortcut conflicts for this item."];
        return;
    }
    // Check for conflicts
    NSString *conflicts = [self _findConflictsFor:e excluding:nil];
    _conflictInfo.stringValue = conflicts.length ? conflicts : [[NppLocalizer shared] translate:@"No shortcut conflicts for this item."];
}

// ═══════════════════════════════════════════════════════════════════════════════
// Conflict Detection
// ═══════════════════════════════════════════════════════════════════════════════

- (NSString *)_findConflictsFor:(ShortcutEntry *)entry excluding:(ShortcutEntry * _Nullable)exclude {
    if (entry.keyCode == 0) return @"";
    NSMutableArray<NSString *> *conflicts = [NSMutableArray array];

    NSArray *allTabs = @[
        @[@"Main menu", _mainMenuEntries ?: @[]],
        @[@"Macros", _macroEntries ?: @[]],
        @[@"Run commands", _runCmdEntries ?: @[]],
        @[@"Plugin commands", _pluginEntries ?: @[]],
        @[@"Scintilla commands", _scintillaEntries ?: @[]],
    ];

    for (NSArray *tabInfo in allTabs) {
        NSString *tabName = tabInfo[0];
        NSArray<ShortcutEntry *> *entries = tabInfo[1];
        for (NSUInteger i = 0; i < entries.count; i++) {
            ShortcutEntry *other = entries[i];
            if (other == entry || other == exclude) continue;
            if (other.keyCode == 0) continue;
            if (other.keyCode == entry.keyCode &&
                other.hasCmd == entry.hasCmd &&
                other.hasCtrl == entry.hasCtrl &&
                other.hasAlt == entry.hasAlt &&
                other.hasShift == entry.hasShift) {
                [conflicts addObject:[NSString stringWithFormat:@"%@ | %lu  %@  ( %@ )",
                    tabName, (unsigned long)(i+1), other.name, other.shortcutDisplay]];
            }
        }
    }
    return conflicts.count ? [conflicts componentsJoinedByString:@"\n"] : @"";
}

// ═══════════════════════════════════════════════════════════════════════════════
// Actions: Modify / Clear / Delete / Close
// ═══════════════════════════════════════════════════════════════════════════════

- (void)_modifyShortcut:(id)sender {
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_filteredEntries.count) return;
    ShortcutEntry *e = _filteredEntries[row];

    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 400, 240)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered defer:NO];
    panel.title = [[NppLocalizer shared] translate:@"Shortcut"];
    [panel center];
    NSView *cv = panel.contentView;

    // Name
    NSTextField *nameLbl = [NSTextField labelWithString:[[NppLocalizer shared] translate:@"Name:"]];
    nameLbl.frame = NSMakeRect(20, 205, 50, 16);
    [cv addSubview:nameLbl];
    NSTextField *nameVal = [NSTextField labelWithString:e.name];
    nameVal.frame = NSMakeRect(75, 205, 305, 16);
    nameVal.font = [NSFont boldSystemFontOfSize:13];
    nameVal.lineBreakMode = NSLineBreakByTruncatingTail;
    [cv addSubview:nameVal];

    // Modifiers
    NSButton *chkCmd = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"\u2318 Command"] target:nil action:nil];
    chkCmd.frame = NSMakeRect(20, 170, 140, 20);
    chkCmd.state = e.hasCmd ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:chkCmd];

    NSButton *chkCtrl = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"\u2303 Control"] target:nil action:nil];
    chkCtrl.frame = NSMakeRect(170, 170, 140, 20);
    chkCtrl.state = e.hasCtrl ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:chkCtrl];

    NSButton *chkOpt = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"\u2325 Option"] target:nil action:nil];
    chkOpt.frame = NSMakeRect(20, 143, 140, 20);
    chkOpt.state = e.hasAlt ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:chkOpt];

    NSButton *chkShift = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"\u21E7 Shift"] target:nil action:nil];
    chkShift.frame = NSMakeRect(170, 143, 100, 20);
    chkShift.state = e.hasShift ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:chkShift];

    NSTextField *plusKey = [NSTextField labelWithString:@"+"];
    plusKey.frame = NSMakeRect(270, 145, 15, 16);
    [cv addSubview:plusKey];

    // Key dropdown — wide enough for longest key name
    NSPopUpButton *keyPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(288, 141, 95, 25) pullsDown:NO];
    [keyPopup addItemsWithTitles:[ShortcutEntry allKeyNames]];
    if (e.keyCode > 0) {
        NSString *current = [ShortcutEntry popupNameForCode:e.keyCode];
        [keyPopup selectItemWithTitle:current];
    }
    [cv addSubview:keyPopup];

    // Conflict warning label (red text, updates live)
    NSTextField *conflictLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 100, 360, 32)];
    conflictLabel.editable = NO;
    conflictLabel.bordered = NO;
    conflictLabel.drawsBackground = NO;
    conflictLabel.font = [NSFont systemFontOfSize:11];
    conflictLabel.textColor = [NSColor systemRedColor];
    conflictLabel.stringValue = @"";
    conflictLabel.lineBreakMode = NSLineBreakByWordWrapping;
    conflictLabel.maximumNumberOfLines = 2;
    [cv addSubview:conflictLabel];

    // OK button is created up here (instead of below the checkConflict
    // block) so the conflict-check block can hold a strong reference and
    // toggle its enabled state live. Disabling OK when a conflict is
    // detected is the user-facing half of the "no silent collisions" rule:
    // the warning label tells the user what's wrong, and the disabled OK
    // forces them to pick something non-conflicting (or "None") before
    // saving. The block-operation wiring further down then fires
    // checkConflict on every modifier or key change, keeping enabled in
    // sync with whatever the user is currently picking.
    NSButton *btnOK = [[NSButton alloc] initWithFrame:NSMakeRect(195, 12, 90, 28)];
    btnOK.title = [[NppLocalizer shared] translate:@"OK"]; btnOK.bezelStyle = NSBezelStyleRounded;
    btnOK.keyEquivalent = @"\r"; btnOK.target = NSApp; btnOK.action = @selector(stopModal);
    [cv addSubview:btnOK];

    NSButton *btnCancel = [[NSButton alloc] initWithFrame:NSMakeRect(293, 12, 90, 28)];
    btnCancel.title = [[NppLocalizer shared] translate:@"Cancel"]; btnCancel.bezelStyle = NSBezelStyleRounded;
    btnCancel.keyEquivalent = @"\033"; btnCancel.target = NSApp; btnCancel.action = @selector(abortModal);
    [cv addSubview:btnCancel];

    // Live conflict check block
    __weak ShortcutMapperWindowController *weakSelf = self;
    void (^checkConflict)(void) = ^{
        NSUInteger keyCode = [ShortcutEntry keyCodeForName:keyPopup.titleOfSelectedItem];
        if (keyCode == 0) {
            // No key picked → no shortcut → "no conflict" is the correct
            // resting state, and OK must be enabled so the user can save
            // a cleared / never-set entry.
            conflictLabel.stringValue = @"";
            btnOK.enabled = YES;
            return;
        }

        // Build a temporary entry to check against
        ShortcutEntry *test = [[ShortcutEntry alloc] init];
        test.hasCmd   = (chkCmd.state == NSControlStateValueOn);
        test.hasCtrl  = (chkCtrl.state == NSControlStateValueOn);
        test.hasAlt   = (chkOpt.state == NSControlStateValueOn);
        test.hasShift = (chkShift.state == NSControlStateValueOn);
        test.keyCode  = keyCode;

        NSString *conflicts = [weakSelf _findConflictsFor:test excluding:e];
        if (conflicts.length) {
            conflictLabel.textColor = [NSColor systemRedColor];
            conflictLabel.stringValue = [NSString stringWithFormat:[[NppLocalizer shared] translate:@"CONFLICT: %@"], conflicts];
            btnOK.enabled = NO;
        } else {
            conflictLabel.textColor = [NSColor secondaryLabelColor];
            conflictLabel.stringValue = [[NppLocalizer shared] translate:@"No shortcut conflicts."];
            btnOK.enabled = YES;
        }
    };

    // Wire live checking to all controls.
    // Each NSBlockOperation must be held in a strong local so it survives
    // the modal run loop. NSControl.target is a zeroing-weak property under
    // ARC — without a strong owner the block operation is released
    // immediately and the weak target zeroes to nil, which causes
    // NSPopUpButton's menu auto-validation to disable (dim) its items and
    // checkbox actions to silently no-op. This manifests only in Release
    // builds (-O3) where ARC aggressively releases temporaries.
    NSMutableArray *targetOps = [NSMutableArray array];
    for (NSButton *chk in @[chkCmd, chkCtrl, chkOpt, chkShift]) {
        NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:checkConflict];
        chk.target = op;
        chk.action = @selector(main);
        [targetOps addObject:op];
    }
    NSBlockOperation *keyOp = [NSBlockOperation blockOperationWithBlock:checkConflict];
    keyPopup.target = keyOp;
    keyPopup.action = @selector(main);
    [targetOps addObject:keyOp];

    // Initial check (also sets btnOK.enabled to its starting state)
    checkConflict();

    // handle the window close button (red x) — without this the modal session
    // outlives the panel and the app becomes unclickable (#283)
    id closeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowWillCloseNotification
                    object:panel
                     queue:nil
                usingBlock:^(NSNotification *note) { [NSApp abortModal]; }];

    NSModalResponse resp = [NSApp runModalForWindow:panel];
    [[NSNotificationCenter defaultCenter] removeObserver:closeObserver];
    [panel orderOut:nil];
    if (resp != NSModalResponseStop) return;

    // Apply changes
    e.hasCmd   = (chkCmd.state == NSControlStateValueOn);
    e.hasCtrl  = (chkCtrl.state == NSControlStateValueOn);
    e.hasAlt   = (chkOpt.state == NSControlStateValueOn);
    e.hasShift = (chkShift.state == NSControlStateValueOn);
    e.keyCode  = [ShortcutEntry keyCodeForName:keyPopup.titleOfSelectedItem];
    e.isModified = YES;
    _hasChanges = YES;
    [e updateDisplay];
    [_tableView reloadData];

    // Update conflict info
    NSString *conflicts = [self _findConflictsFor:e excluding:nil];
    _conflictInfo.stringValue = conflicts.length ? conflicts : [[NppLocalizer shared] translate:@"No shortcut conflicts for this item."];
}

- (void)_clearShortcut:(id)sender {
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_filteredEntries.count) return;
    ShortcutEntry *e = _filteredEntries[row];
    e.hasCmd = e.hasCtrl = e.hasAlt = e.hasShift = NO;
    e.keyCode = 0;
    e.isModified = YES;
    _hasChanges = YES;
    [e updateDisplay];
    [_tableView reloadData];
    _conflictInfo.stringValue = [[NppLocalizer shared] translate:@"No shortcut conflicts for this item."];
}

- (void)_deleteShortcut:(id)sender {
    if (_currentTab != ShortcutMapperTabMacros && _currentTab != ShortcutMapperTabRunCommands) return;
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_filteredEntries.count) return;

    ShortcutEntry *e = _filteredEntries[row];
    NSAlert *confirm = [[NSAlert alloc] init];
    confirm.messageText = [[NppLocalizer shared] translate:@"Delete Shortcut"];
    confirm.informativeText = [NSString stringWithFormat:[[NppLocalizer shared] translate:@"Delete \"%@\"?"], e.name];
    [confirm addButtonWithTitle:[[NppLocalizer shared] translate:@"Delete"]];
    [confirm addButtonWithTitle:[[NppLocalizer shared] translate:@"Cancel"]];
    if ([confirm runModal] != NSAlertFirstButtonReturn) return;

    NSMutableArray *source = [self _entriesForCurrentTab];
    [source removeObject:e];
    _hasChanges = YES;
    [self _applyFilter];
}

- (void)_close:(id)sender {
    [self _saveIfNeeded];
    [self.window close];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self _saveIfNeeded];
}

- (void)_saveIfNeeded {
    if (_saved) { NSLog(@"[ShortcutMapper] _saveIfNeeded: already saved, skipping"); return; }
    _saved = YES;
    if (!_hasChanges) {
        NSLog(@"[ShortcutMapper] _saveIfNeeded: no changes, skipping save");
        return;
    }
    NSLog(@"[ShortcutMapper] _saveIfNeeded: saving now...");
    [self _saveChanges];
}

// ═══════════════════════════════════════════════════════════════════════════════
// Save Changes to shortcuts.xml and live menus
// ═══════════════════════════════════════════════════════════════════════════════

- (void)_saveChanges {
    NSInteger modCount = 0;

    // Apply shortcut changes to live menu items (all tabs)
    NSArray *allEntries = [@[_mainMenuEntries ?: @[], _pluginEntries ?: @[], _runCmdEntries ?: @[]]
                           valueForKeyPath:@"@unionOfArrays.self"];
    for (ShortcutEntry *e in allEntries) {
        if (!e.isModified) continue;
        if (!e.selectorName) continue;
        // Plugin commands all share the same selector (pluginMenuAction:), so a
        // selector-only lookup returns the *first* plugin menu item in the
        // walk and applies every plugin shortcut to it (issue #86). Resolve
        // plugin entries via (pluginName, commandID) instead — mirroring the
        // logic AppDelegate._loadShortcutOverrides already uses to apply
        // shortcuts.xml at launch.
        NSMenuItem *mi = nil;
        if ([e.selectorName isEqualToString:@"pluginMenuAction:"] && e.pluginName.length) {
            mi = [self _findPluginMenuItemWithName:e.pluginName internalID:e.commandID];
        } else {
            SEL sel = NSSelectorFromString(e.selectorName);
            mi = [self _findMenuItemWithAction:sel inMenu:[NSApp mainMenu]];
        }
        if (!mi) continue;
        [self _applyShortcutEntry:e toMenuItem:mi];
        modCount++;
    }

    // Save ALL changes to shortcuts.xml
    [self _saveToShortcutsXML];

    // Rebuild the Macro menu to reflect deletions/changes
    AppDelegate *appDel = (AppDelegate *)[NSApp delegate];
    for (MainWindowController *wc in appDel.windowControllers)
        [wc rebuildMacroMenu];

    NSLog(@"[ShortcutMapper] Saved %ld modified shortcuts", (long)modCount);

    // Post notification for other parts of the app
    [[NSNotificationCenter defaultCenter] postNotificationName:NPPShortcutsChangedNotification object:nil];
}

- (void)_applyShortcutEntry:(ShortcutEntry *)e toMenuItem:(NSMenuItem *)mi {
    if (e.keyCode == 0) {
        mi.keyEquivalent = @"";
        mi.keyEquivalentModifierMask = 0;
        return;
    }
    NSEventModifierFlags mods = 0;
    if (e.hasCmd)   mods |= NSEventModifierFlagCommand;
    if (e.hasCtrl)  mods |= NSEventModifierFlagControl;
    if (e.hasAlt)   mods |= NSEventModifierFlagOption;
    if (e.hasShift) mods |= NSEventModifierFlagShift;

    NSString *key = [ShortcutEntry menuKeyEquivalentForCode:e.keyCode];
    if (e.keyCode >= 112 && e.keyCode <= 123) {
        mods &= ~NSEventModifierFlagCommand; // function keys don't need Cmd implicit
    }
    mi.keyEquivalent = key;
    mi.keyEquivalentModifierMask = mods;
}

// Resolve a plugin menu item by (pluginName, commandID) instead of by
// selector. The selector pluginMenuAction: is shared across every plugin
// command; only (parent-submenu-title, NSMenuItem.tag) identifies a command
// uniquely. Mirrors AppDelegate._loadShortcutOverrides:485-505 — keep both
// codepaths in sync if the matching policy ever changes.
//
// The tag-OR-cmdIdx fallback is intentional: most plugins assign tags 0..N
// sequentially so cmdIdx == tag in practice, but if a plugin uses sparse
// or unset tags, the cmdIdx leg still finds the Nth runnable command.
- (nullable NSMenuItem *)_findPluginMenuItemWithName:(NSString *)pluginName
                                          internalID:(NSInteger)internalID {
    if (!pluginName.length) return nil;
    NSMenu *pluginsMenu = [[[NSApp mainMenu] itemWithTag:kMenuTagPlugins] submenu];
    if (!pluginsMenu) return nil;
    for (NSMenuItem *pluginItem in pluginsMenu.itemArray) {
        if (![pluginItem.title isEqualToString:pluginName]) continue;
        if (!pluginItem.submenu) continue;
        NSInteger cmdIdx = 0;
        for (NSMenuItem *cmdItem in pluginItem.submenu.itemArray) {
            if (cmdItem.isSeparatorItem || !cmdItem.action) continue;
            if (cmdItem.tag == internalID || cmdIdx == internalID)
                return cmdItem;
            cmdIdx++;
        }
    }
    return nil;
}

- (nullable NSMenuItem *)_findMenuItemWithAction:(SEL)action inMenu:(NSMenu *)menu {
    for (NSMenuItem *mi in menu.itemArray) {
        if (mi.action == action) return mi;
        if (mi.submenu) {
            NSMenuItem *found = [self _findMenuItemWithAction:action inMenu:mi.submenu];
            if (found) return found;
        }
    }
    return nil;
}

- (void)_saveToShortcutsXML {
    NSString *path = NppConfigSubpath(@"shortcuts.xml");

    // Read existing shortcuts.xml — modify in-place to preserve comments and structure
    NSData *existingData = [NSData dataWithContentsOfFile:path];
    if (!existingData) {
        NSLog(@"[ShortcutMapper] ERROR: shortcuts.xml not found at %@", path);
        return;
    }
    NSError *parseErr = nil;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:existingData
                                                     options:NSXMLNodePreserveAll
                                                       error:&parseErr];
    if (!doc) {
        NSLog(@"[ShortcutMapper] ERROR parsing shortcuts.xml: %@", parseErr);
        return;
    }

    NSXMLElement *root = doc.rootElement;

    // ── Update InternalCommands in-place ──
    // Remove existing InternalCommands element and replace with new one
    NSArray *intCmdNodes = [root elementsForName:@"InternalCommands"];
    for (NSXMLElement *old in intCmdNodes) {
        [old detach];
    }
    NSXMLElement *intCmdsEl = [NSXMLElement elementWithName:@"InternalCommands"];
    NSInteger intCmdCount = 0;
    for (ShortcutEntry *e in _mainMenuEntries) {
        if (!e.isModified) continue;
        intCmdCount++;
        NSLog(@"[ShortcutMapper] Saving InternalCommand: %@ sel=%@ key=%lu", e.name, e.selectorName, (unsigned long)e.keyCode);
        NSXMLElement *sc = [NSXMLElement elementWithName:@"Shortcut"];
        [sc addAttribute:[NSXMLNode attributeWithName:@"id" stringValue:e.selectorName ?: @""]];
        [sc addAttribute:[NSXMLNode attributeWithName:@"Ctrl" stringValue:e.hasCtrl ? @"yes" : @"no"]];
        [sc addAttribute:[NSXMLNode attributeWithName:@"Alt" stringValue:e.hasAlt ? @"yes" : @"no"]];
        [sc addAttribute:[NSXMLNode attributeWithName:@"Shift" stringValue:e.hasShift ? @"yes" : @"no"]];
        [sc addAttribute:[NSXMLNode attributeWithName:@"Cmd" stringValue:e.hasCmd ? @"yes" : @"no"]];
        [sc addAttribute:[NSXMLNode attributeWithName:@"Key"
                                          stringValue:[NSString stringWithFormat:@"%lu", (unsigned long)e.keyCode]]];
        [intCmdsEl addChild:sc];
    }
    // Insert InternalCommands as first child of root
    if (root.childCount > 0)
        [root insertChild:intCmdsEl atIndex:0];
    else
        [root addChild:intCmdsEl];
    NSLog(@"[ShortcutMapper] InternalCommands: %ld entries saved", (long)intCmdCount);

    // ── Update Macros in-place (only shortcut attributes, preserve Action children) ──
    // Build set of macro names that still exist in the in-memory list
    NSMutableSet *liveMacroNames = [NSMutableSet set];
    for (ShortcutEntry *e in _macroEntries)
        [liveMacroNames addObject:e.name];

    NSArray *macroNodes = [doc nodesForXPath:@"//Macros/Macro" error:nil];
    for (NSXMLElement *macroEl in macroNodes) {
        NSString *macroName = [[macroEl attributeForName:@"name"] stringValue];
        // Remove macros that were deleted from the in-memory list
        if (![liveMacroNames containsObject:macroName]) {
            NSLog(@"[ShortcutMapper] Deleting macro from XML: %@", macroName);
            [macroEl detach];
            continue;
        }
        for (ShortcutEntry *e in _macroEntries) {
            if ([e.name isEqualToString:macroName] && e.isModified) {
                [macroEl removeAttributeForName:@"Ctrl"];
                [macroEl removeAttributeForName:@"Alt"];
                [macroEl removeAttributeForName:@"Shift"];
                [macroEl removeAttributeForName:@"Key"];
                [macroEl addAttribute:[NSXMLNode attributeWithName:@"Ctrl" stringValue:e.hasCtrl ? @"yes" : @"no"]];
                [macroEl addAttribute:[NSXMLNode attributeWithName:@"Alt" stringValue:e.hasAlt ? @"yes" : @"no"]];
                [macroEl addAttribute:[NSXMLNode attributeWithName:@"Shift" stringValue:e.hasShift ? @"yes" : @"no"]];
                [macroEl addAttribute:[NSXMLNode attributeWithName:@"Cmd" stringValue:e.hasCmd ? @"yes" : @"no"]];
                [macroEl addAttribute:[NSXMLNode attributeWithName:@"Key"
                                                       stringValue:[NSString stringWithFormat:@"%lu", (unsigned long)e.keyCode]]];
                break;
            }
        }
    }

    // ── Update PluginCommands in-place ──
    {
        NSArray *pcNodes = [root elementsForName:@"PluginCommands"];
        NSXMLElement *pcEl = pcNodes.firstObject;
        if (!pcEl) {
            pcEl = [NSXMLElement elementWithName:@"PluginCommands"];
            [root addChild:pcEl];
        }
        for (ShortcutEntry *e in _pluginEntries) {
            if (!e.isModified) continue;
            NSLog(@"[ShortcutMapper] Saving PluginCommand: %@ plugin=%@ key=%lu",
                  e.name, e.pluginName, (unsigned long)e.keyCode);
            // Remove existing entry for this plugin command if present
            for (NSXMLElement *existing in [pcEl elementsForName:@"PluginCommand"]) {
                NSString *mod = [[existing attributeForName:@"moduleName"] stringValue];
                NSString *iid = [[existing attributeForName:@"internalID"] stringValue];
                if ([mod isEqualToString:e.pluginName] &&
                    [iid isEqualToString:[NSString stringWithFormat:@"%ld", (long)e.commandID]]) {
                    [existing detach];
                    break;
                }
            }
            NSXMLElement *pc = [NSXMLElement elementWithName:@"PluginCommand"];
            [pc addAttribute:[NSXMLNode attributeWithName:@"moduleName" stringValue:e.pluginName ?: @""]];
            [pc addAttribute:[NSXMLNode attributeWithName:@"internalID"
                                              stringValue:[NSString stringWithFormat:@"%ld", (long)e.commandID]]];
            [pc addAttribute:[NSXMLNode attributeWithName:@"Ctrl" stringValue:e.hasCtrl ? @"yes" : @"no"]];
            [pc addAttribute:[NSXMLNode attributeWithName:@"Alt" stringValue:e.hasAlt ? @"yes" : @"no"]];
            [pc addAttribute:[NSXMLNode attributeWithName:@"Shift" stringValue:e.hasShift ? @"yes" : @"no"]];
            [pc addAttribute:[NSXMLNode attributeWithName:@"Cmd" stringValue:e.hasCmd ? @"yes" : @"no"]];
            [pc addAttribute:[NSXMLNode attributeWithName:@"Key"
                                              stringValue:[NSString stringWithFormat:@"%lu", (unsigned long)e.keyCode]]];
            [pcEl addChild:pc];
        }
    }

    // ── Update UserDefinedCommands shortcuts in-place + handle deletions ──
    {
        // Build set of run command names that still exist in the in-memory list
        NSMutableSet *liveRunNames = [NSMutableSet set];
        for (ShortcutEntry *e in _runCmdEntries)
            [liveRunNames addObject:e.name];

        NSArray *cmdNodes = [doc nodesForXPath:@"//UserDefinedCommands/Command" error:nil];
        for (NSXMLElement *cmdEl in cmdNodes) {
            NSString *cmdName = [[cmdEl attributeForName:@"name"] stringValue];
            // Remove commands that were deleted from the in-memory list
            if (![liveRunNames containsObject:cmdName]) {
                NSLog(@"[ShortcutMapper] Deleting RunCommand: %@", cmdName);
                [cmdEl detach];
                continue;
            }
            // Update shortcut attributes for modified commands
            for (ShortcutEntry *e in _runCmdEntries) {
                if ([e.name isEqualToString:cmdName] && e.isModified) {
                    NSLog(@"[ShortcutMapper] Saving RunCommand shortcut: %@ key=%lu",
                          e.name, (unsigned long)e.keyCode);
                    [cmdEl removeAttributeForName:@"Ctrl"];
                    [cmdEl removeAttributeForName:@"Alt"];
                    [cmdEl removeAttributeForName:@"Shift"];
                    [cmdEl removeAttributeForName:@"Cmd"];
                    [cmdEl removeAttributeForName:@"Key"];
                    [cmdEl addAttribute:[NSXMLNode attributeWithName:@"Ctrl" stringValue:e.hasCtrl ? @"yes" : @"no"]];
                    [cmdEl addAttribute:[NSXMLNode attributeWithName:@"Alt" stringValue:e.hasAlt ? @"yes" : @"no"]];
                    [cmdEl addAttribute:[NSXMLNode attributeWithName:@"Shift" stringValue:e.hasShift ? @"yes" : @"no"]];
                    [cmdEl addAttribute:[NSXMLNode attributeWithName:@"Cmd" stringValue:e.hasCmd ? @"yes" : @"no"]];
                    [cmdEl addAttribute:[NSXMLNode attributeWithName:@"Key"
                                                         stringValue:[NSString stringWithFormat:@"%lu", (unsigned long)e.keyCode]]];
                    break;
                }
            }
        }
    }

    // ── Update ScintillaKeys in-place ──
    {
        NSArray *skNodes = [root elementsForName:@"ScintillaKeys"];
        NSXMLElement *skEl = skNodes.firstObject;
        if (!skEl) {
            skEl = [NSXMLElement elementWithName:@"ScintillaKeys"];
            [root addChild:skEl];
        }
        for (ShortcutEntry *e in _scintillaEntries) {
            if (!e.isModified) continue;
            NSLog(@"[ShortcutMapper] Saving ScintillaKey: %@ sciID=%ld key=%lu",
                  e.name, (long)e.commandID, (unsigned long)e.keyCode);
            // Remove existing entry
            for (NSXMLElement *existing in [skEl elementsForName:@"ScintKey"]) {
                if ([[[existing attributeForName:@"ScintID"] stringValue] intValue] == (int)e.commandID) {
                    [existing detach];
                    break;
                }
            }
            NSXMLElement *sk = [NSXMLElement elementWithName:@"ScintKey"];
            [sk addAttribute:[NSXMLNode attributeWithName:@"ScintID"
                                              stringValue:[NSString stringWithFormat:@"%ld", (long)e.commandID]]];
            [sk addAttribute:[NSXMLNode attributeWithName:@"menuCmdID" stringValue:@"0"]];
            [sk addAttribute:[NSXMLNode attributeWithName:@"Ctrl" stringValue:e.hasCtrl ? @"yes" : @"no"]];
            [sk addAttribute:[NSXMLNode attributeWithName:@"Alt" stringValue:e.hasAlt ? @"yes" : @"no"]];
            [sk addAttribute:[NSXMLNode attributeWithName:@"Shift" stringValue:e.hasShift ? @"yes" : @"no"]];
            [sk addAttribute:[NSXMLNode attributeWithName:@"Cmd" stringValue:e.hasCmd ? @"yes" : @"no"]];
            [sk addAttribute:[NSXMLNode attributeWithName:@"Key"
                                              stringValue:[NSString stringWithFormat:@"%lu", (unsigned long)e.keyCode]]];
            [skEl addChild:sk];
        }
    }

    // Write back — preserves comments and structure
    NSData *xmlData = [doc XMLDataWithOptions:NSXMLNodePrettyPrint | NSXMLNodePreserveAll];
    if (!xmlData) {
        NSLog(@"[ShortcutMapper] ERROR: failed to generate XML data");
        return;
    }
    NSError *writeErr = nil;
    BOOL ok = [xmlData writeToFile:path options:NSDataWritingAtomic error:&writeErr];
    if (ok) {
        NSLog(@"[ShortcutMapper] Saved shortcuts.xml (%lu bytes) to %@", (unsigned long)xmlData.length, path);
    } else {
        NSLog(@"[ShortcutMapper] ERROR writing shortcuts.xml: %@", writeErr);
    }
}

@end
