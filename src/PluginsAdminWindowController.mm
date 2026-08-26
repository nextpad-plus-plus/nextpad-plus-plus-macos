#import "PluginsAdminWindowController.h"
#import "NppPaths.h"
#import "NppPluginManager.h"
#import "NppLocalizer.h"
#import <CommonCrypto/CommonDigest.h>

// ═══════════════════════════════════════════════════════════════════════════
// Plugin catalog entry — parsed from the nppPluginList JSON
// ═══════════════════════════════════════════════════════════════════════════

@interface NppPluginEntry : NSObject
@property (nonatomic, copy) NSString *folderName;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *version;           // Windows version
@property (nonatomic, copy) NSString *pluginDescription;
@property (nonatomic, copy) NSString *author;
@property (nonatomic, copy) NSString *homepage;
@property (nonatomic, copy) NSString *repository;        // Windows download URL
@property (nonatomic, copy) NSString *pluginID;           // Windows SHA-256
@property (nonatomic) BOOL isInstalled;

// macOS-specific (populated from macOS plugin list)
@property (nonatomic) BOOL isMacAvailable;               // has macOS build
@property (nonatomic, copy) NSString *macVersion;         // macOS version
@property (nonatomic, copy) NSString *macRepository;      // macOS download URL
@property (nonatomic, copy) NSString *macPluginID;        // macOS SHA-256 of zip

// Updates-tab fields (optional — nil/empty when the catalog entry
// doesn't carry them yet). See pl.macos-arm64.json for semantics.
@property (nonatomic, copy) NSString *macDylibID;         // sha256 of the .dylib itself
@property (nonatomic, copy) NSString *macDylibBuilt;      // YYYY-MM-DD (release date)
@property (nonatomic, copy) NSString *macNppMinVersion;   // minimum host version

// Runtime-only state populated by the Updates-tab scanner.
@property (nonatomic, copy) NSString *installedDylibSHA;  // sha256(~/Library/Application Support/Nextpad++/plugins/<folder>/<folder>.dylib)
@property (nonatomic, copy) NSString *installedDylibDate; // YYYY-MM-DD of that file's mtime
@end

@implementation NppPluginEntry
@end

// ═══════════════════════════════════════════════════════════════════════════
// Tab identifiers
// ═══════════════════════════════════════════════════════════════════════════

typedef NS_ENUM(NSInteger, PluginAdminTab) {
    PluginAdminTabAvailable = 0,
    PluginAdminTabUpdates,
    PluginAdminTabInstalled,
    PluginAdminTabIncompatible
};

// Windows x64 plugin list (full catalog — shows all plugins)
static NSString *const kWinPluginListURL =
    @"https://raw.githubusercontent.com/notepad-plus-plus/nppPluginList/master/src/pl.x64.json";
// macOS arm64 plugin list (our ported plugins — determines what's installable)
static NSString *const kMacPluginListURL =
    @"https://raw.githubusercontent.com/nextpad-plus-plus/nppPluginList/main/pl.macos-arm64.json";
static NSString *const kPluginListRepoURL =
    @"https://github.com/nextpad-plus-plus/nppPluginList";
static NSString *const kPluginListVersion = @"0.2.0";

// ═══════════════════════════════════════════════════════════════════════════
// Private interface
// ═══════════════════════════════════════════════════════════════════════════

@interface PluginsAdminWindowController () <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) NSTabView *tabView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSTextView *descriptionView;
@property (nonatomic, strong) NSTextField *searchField;
@property (nonatomic, strong) NSButton *actionButton;
@property (nonatomic, strong) NSButton *closeButton;
@property (nonatomic, strong) NSTextField *versionLabel;
@property (nonatomic, strong) NSTextField *statsLabel;   // "Plugins: N total · M macOS-available"
@property (nonatomic, strong) NSButton *repoLink;
@property (nonatomic, strong) NSProgressIndicator *spinner;

@property (nonatomic, strong) NSMutableArray<NppPluginEntry *> *allAvailable;
@property (nonatomic, strong) NSMutableArray<NppPluginEntry *> *installed;
@property (nonatomic, strong) NSMutableArray<NppPluginEntry *> *filteredList; // current display
@property (nonatomic, strong) NSMutableSet<NSString *> *checkedPlugins;      // folderNames

@property (nonatomic) PluginAdminTab currentTab;
@property (nonatomic, copy) NSString *searchText;

@end

@implementation PluginsAdminWindowController

// ── Singleton ───────────────────────────────────────────────────────────

+ (instancetype)sharedController {
    static PluginsAdminWindowController *inst;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[PluginsAdminWindowController alloc] init];
    });
    return inst;
}

// ── Init ────────────────────────────────────────────────────────────────

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 780, 560)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:YES];
    win.title = [[NppLocalizer shared] translate:@"Plugins Admin"];
    win.minSize = NSMakeSize(600, 450);
    [win center];

    self = [super initWithWindow:win];
    if (self) {
        _allAvailable   = [NSMutableArray array];
        _installed      = [NSMutableArray array];
        _filteredList   = [NSMutableArray array];
        _checkedPlugins = [NSMutableSet set];
        _currentTab     = PluginAdminTabAvailable;
        _searchText     = @"";
        [self buildUI];
        [self scanInstalledPlugins];
        [self fetchPluginList];
    }
    return self;
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    [self.window center];
    [self.checkedPlugins removeAllObjects];
    [self refreshForCurrentTab];
}

// ── UI Construction ─────────────────────────────────────────────────────

- (void)buildUI {
    NSView *cv = self.window.contentView;
    cv.wantsLayer = YES;

    // ── Tab buttons (segmented-style at top) ────────────────────────
    _tabView = [[NSTabView alloc] initWithFrame:NSZeroRect];
    _tabView.translatesAutoresizingMaskIntoConstraints = NO;
    _tabView.tabViewType = NSTopTabsBezelBorder;
    _tabView.delegate = (id<NSTabViewDelegate>)self;

    NppLocalizer *loc = [NppLocalizer shared];

    NSTabViewItem *t0 = [[NSTabViewItem alloc] initWithIdentifier:@"available"];
    t0.label = [loc translate:@"Available"];
    t0.view = [[NSView alloc] init];
    [_tabView addTabViewItem:t0];

    NSTabViewItem *t1 = [[NSTabViewItem alloc] initWithIdentifier:@"updates"];
    t1.label = [loc translate:@"Updates"];
    t1.view = [[NSView alloc] init];
    [_tabView addTabViewItem:t1];

    NSTabViewItem *t2 = [[NSTabViewItem alloc] initWithIdentifier:@"installed"];
    t2.label = [loc translate:@"Installed"];
    t2.view = [[NSView alloc] init];
    [_tabView addTabViewItem:t2];

    NSTabViewItem *t3 = [[NSTabViewItem alloc] initWithIdentifier:@"incompatible"];
    t3.label = [loc translate:@"Incompatible"];
    t3.view = [[NSView alloc] init];
    [_tabView addTabViewItem:t3];

    [cv addSubview:_tabView];

    // ── Search row ──────────────────────────────────────────────────
    NSTextField *searchLabel = [NSTextField labelWithString:[loc translate:@"Search:"]];
    searchLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:searchLabel];

    _searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.placeholderString = [loc translate:@"Filter plugins…"];
    _searchField.target = self;
    _searchField.action = @selector(searchChanged:);
    // Also fire on every keystroke via delegate
    _searchField.delegate = (id<NSTextFieldDelegate>)self;
    [cv addSubview:_searchField];

    _actionButton = [NSButton buttonWithTitle:[loc translate:@"Install"] target:self action:@selector(actionPressed:)];
    _actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    _actionButton.bezelStyle = NSBezelStyleRounded;
    [cv addSubview:_actionButton];

    // ── Spinner (while fetching) ────────────────────────────────────
    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.displayedWhenStopped = NO;
    [cv addSubview:_spinner];

    // ── Table view (Plugin + Version columns, with checkboxes) ──────
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSBezelBorder;

    _tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.usesAlternatingRowBackgroundColors = NO;
    _tableView.rowHeight = 20;
    _tableView.allowsMultipleSelection = NO;
    _tableView.headerView = [[NSTableHeaderView alloc] init];

    NSTableColumn *checkCol = [[NSTableColumn alloc] initWithIdentifier:@"check"];
    checkCol.width = 24;
    checkCol.minWidth = 24;
    checkCol.maxWidth = 24;
    checkCol.title = @"";
    [_tableView addTableColumn:checkCol];

    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"plugin"];
    nameCol.title = [loc translate:@"Plugin"];
    nameCol.width = 280;
    nameCol.minWidth = 150;
    [_tableView addTableColumn:nameCol];

    NSTableColumn *verCol = [[NSTableColumn alloc] initWithIdentifier:@"version"];
    verCol.title = [loc translate:@"Version"];
    verCol.width = 100;
    verCol.minWidth = 60;
    [_tableView addTableColumn:verCol];

    // Built date — populated from `dylib-built` in pl.macos-arm64.json
    // for mac-available plugins. Empty for Windows-only entries because
    // Don HO's pl.x64.json has no equivalent field.
    NSTableColumn *builtCol = [[NSTableColumn alloc] initWithIdentifier:@"built"];
    builtCol.title = [loc translate:@"Built Date"];
    builtCol.width = 100;
    builtCol.minWidth = 90;
    [_tableView addTableColumn:builtCol];

    // Operating System — string derived from isMacAvailable so we don't
    // need a dedicated field in either catalog. Fixed values: "macOS 11+"
    // for our ported plugins (matching CMakeLists deployment target) and
    // "Windows only" for upstream entries that haven't been ported.
    NSTableColumn *osCol = [[NSTableColumn alloc] initWithIdentifier:@"os"];
    osCol.title = [loc translate:@"Operating System"];
    osCol.width = 130;
    osCol.minWidth = 110;
    [_tableView addTableColumn:osCol];

    scrollView.documentView = _tableView;
    [cv addSubview:scrollView];

    // ── Description area ────────────────────────────────────────────
    NSScrollView *descScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    descScroll.translatesAutoresizingMaskIntoConstraints = NO;
    descScroll.hasVerticalScroller = YES;
    descScroll.borderType = NSBezelBorder;

    _descriptionView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 700, 100)];
    _descriptionView.editable = NO;
    _descriptionView.selectable = YES;
    _descriptionView.font = [NSFont systemFontOfSize:12];
    _descriptionView.textContainerInset = NSMakeSize(6, 6);
    descScroll.documentView = _descriptionView;
    [cv addSubview:descScroll];

    // ── Footer row: version label + stats line + repo link ──────────
    _versionLabel = [NSTextField labelWithString:
        [NSString stringWithFormat:@"Plugin list version:  %@", kPluginListVersion]];
    _versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _versionLabel.font = [NSFont systemFontOfSize:11];
    _versionLabel.textColor = NSColor.secondaryLabelColor;
    [cv addSubview:_versionLabel];

    // Stats line directly below version. Populated by updateStatsLabel
    // after mergePluginListsWin:mac: finishes. Same font/colour as the
    // version label so they read as a single footer block.
    _statsLabel = [NSTextField labelWithString:@""];
    _statsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statsLabel.font = [NSFont systemFontOfSize:11];
    _statsLabel.textColor = NSColor.secondaryLabelColor;
    [cv addSubview:_statsLabel];

    _repoLink = [NSButton buttonWithTitle:[loc translate:@"Plugin list repository"]
                                   target:self action:@selector(openRepoLink:)];
    _repoLink.translatesAutoresizingMaskIntoConstraints = NO;
    _repoLink.bordered = NO;
    NSMutableAttributedString *linkStr = [[NSMutableAttributedString alloc]
        initWithString:[loc translate:@"Plugin list repository"]
            attributes:@{
                NSForegroundColorAttributeName: NSColor.linkColor,
                NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
                NSFontAttributeName: [NSFont systemFontOfSize:11]
            }];
    _repoLink.attributedTitle = linkStr;
    [cv addSubview:_repoLink];

    // ── Close button ────────────────────────────────────────────────
    _closeButton = [NSButton buttonWithTitle:[loc translate:@"Close"] target:self action:@selector(closePressed:)];
    _closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_closeButton setKeyEquivalent:@"\033"];
    [cv addSubview:_closeButton];

    // ── Layout (all anchor-based for clarity) ───────────────────────
    [NSLayoutConstraint activateConstraints:@[
        // Tab view across top
        [_tabView.topAnchor constraintEqualToAnchor:cv.topAnchor constant:8],
        [_tabView.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:12],
        [_tabView.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-12],
        [_tabView.heightAnchor constraintEqualToConstant:36],

        // Search row
        [searchLabel.topAnchor constraintEqualToAnchor:_tabView.bottomAnchor constant:8],
        [searchLabel.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:20],
        [searchLabel.centerYAnchor constraintEqualToAnchor:_searchField.centerYAnchor],

        [_searchField.leadingAnchor constraintEqualToAnchor:searchLabel.trailingAnchor constant:6],
        [_searchField.topAnchor constraintEqualToAnchor:_tabView.bottomAnchor constant:8],
        [_searchField.widthAnchor constraintGreaterThanOrEqualToConstant:200],

        [_spinner.leadingAnchor constraintEqualToAnchor:_searchField.trailingAnchor constant:8],
        [_spinner.centerYAnchor constraintEqualToAnchor:_searchField.centerYAnchor],
        [_spinner.widthAnchor constraintEqualToConstant:16],
        [_spinner.heightAnchor constraintEqualToConstant:16],

        [_actionButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:_spinner.trailingAnchor constant:10],
        [_actionButton.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-20],
        [_actionButton.centerYAnchor constraintEqualToAnchor:_searchField.centerYAnchor],
        [_actionButton.widthAnchor constraintEqualToConstant:90],

        // Table
        [scrollView.topAnchor constraintEqualToAnchor:_searchField.bottomAnchor constant:8],
        [scrollView.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:20],
        [scrollView.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-20],
        [scrollView.heightAnchor constraintGreaterThanOrEqualToConstant:150],

        // Description
        [descScroll.topAnchor constraintEqualToAnchor:scrollView.bottomAnchor constant:8],
        [descScroll.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:20],
        [descScroll.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-20],
        [descScroll.heightAnchor constraintGreaterThanOrEqualToConstant:80],
        [descScroll.heightAnchor constraintLessThanOrEqualToConstant:160],

        // Footer row: version label (top) + stats label (below), repo link right
        [_versionLabel.topAnchor constraintEqualToAnchor:descScroll.bottomAnchor constant:10],
        [_versionLabel.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:20],

        [_statsLabel.topAnchor constraintEqualToAnchor:_versionLabel.bottomAnchor constant:2],
        [_statsLabel.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:20],

        [_repoLink.centerYAnchor constraintEqualToAnchor:_versionLabel.centerYAnchor],
        [_repoLink.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-20],

        // Close button centered, pinned to bottom with adequate room
        [_closeButton.topAnchor constraintEqualToAnchor:_statsLabel.bottomAnchor constant:10],
        [_closeButton.centerXAnchor constraintEqualToAnchor:cv.centerXAnchor],
        [_closeButton.widthAnchor constraintEqualToConstant:100],
        [_closeButton.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor constant:-14],
    ]];
}

// ── Data fetching ───────────────────────────────────────────────────────

- (void)fetchPluginList {
    [_spinner startAnimation:nil];

    // Fetch both lists concurrently, merge when both complete
    __block NSData *winData = nil;
    __block NSData *macData = nil;
    dispatch_group_t group = dispatch_group_create();
    NSURLSession *session = [NSURLSession sharedSession];

    dispatch_group_enter(group);
    [[session dataTaskWithURL:[NSURL URLWithString:kWinPluginListURL]
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!err && data) winData = data;
        else NSLog(@"[PluginsAdmin] Failed to fetch Windows plugin list: %@", err);
        dispatch_group_leave(group);
    }] resume];

    dispatch_group_enter(group);
    [[session dataTaskWithURL:[NSURL URLWithString:kMacPluginListURL]
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!err && data) macData = data;
        else NSLog(@"[PluginsAdmin] Failed to fetch macOS plugin list: %@", err);
        dispatch_group_leave(group);
    }] resume];

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [self->_spinner stopAnimation:nil];
        [self mergePluginListsWin:winData mac:macData];
        [self refreshForCurrentTab];
    });
}

- (void)mergePluginListsWin:(NSData *)winData mac:(NSData *)macData {
    // macOS plugin list is the source of truth for what the "Available" tab
    // offers — our macOS binaries are independently built, signed, and hosted
    // under the nextpad-plus-plus org, so a plugin must be present in
    // pl.macos-arm64.json to be installable. The Windows list is consulted
    // twice:
    //   1. as a metadata fallback for mac entries that also exist upstream
    //      (supplies Win version for the info pane, and any missing
    //      description/author/homepage);
    //   2. as the sole source for the "Incompatible" tab, which lists
    //      Windows-only plugins that haven't been ported yet.
    //
    // A mac entry is linked to its Windows counterpart via a three-tier
    // match on folder-name → display-name → homepage. The homepage tier
    // catches renamed ports (e.g. the macOS "NppLLM" fork of Windows
    // "NppOpenAI" — both share github.com/Krazal/nppopenai).
    [_allAvailable removeAllObjects];

    // ── Parse Windows list into lookup dicts ───────────────────────────
    NSMutableDictionary<NSString *, NSDictionary *> *winByFolder   = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSDictionary *> *winByName     = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSDictionary *> *winByHomepage = [NSMutableDictionary dictionary];
    NSArray *winPlugins = nil;
    if (winData) {
        NSError *err = nil;
        NSDictionary *winRoot = [NSJSONSerialization JSONObjectWithData:winData options:0 error:&err];
        if (!err && [winRoot isKindOfClass:[NSDictionary class]]) {
            id wp = winRoot[@"npp-plugins"];
            if ([wp isKindOfClass:[NSArray class]]) {
                winPlugins = (NSArray *)wp;
                for (NSDictionary *e in winPlugins) {
                    if (![e isKindOfClass:[NSDictionary class]]) continue;
                    NSString *folder = e[@"folder-name"] ?: @"";
                    NSString *name   = e[@"display-name"] ?: @"";
                    NSString *home   = e[@"homepage"] ?: @"";
                    if (folder.length > 0) winByFolder[folder] = e;
                    if (name.length > 0)   winByName[name] = e;
                    if (home.length > 0)   winByHomepage[home.lowercaseString] = e;
                }
            }
        }
        if (!winPlugins)
            NSLog(@"[PluginsAdmin] Windows plugin list unparseable — Incompatible tab will be empty");
    } else {
        NSLog(@"[PluginsAdmin] Windows plugin list not fetched — Incompatible tab will be empty");
    }

    // ── Parse macOS list ───────────────────────────────────────────────
    NSArray *macPlugins = nil;
    if (macData) {
        NSError *err = nil;
        NSDictionary *macRoot = [NSJSONSerialization JSONObjectWithData:macData options:0 error:&err];
        if (!err && [macRoot isKindOfClass:[NSDictionary class]]) {
            id mp = macRoot[@"npp-plugins"];
            if ([mp isKindOfClass:[NSArray class]]) macPlugins = (NSArray *)mp;
        }
    }
    if (!macPlugins) {
        NSLog(@"[PluginsAdmin] macOS plugin list missing/invalid — Available tab will be empty");
        macPlugins = @[];
    }

    NSSet *installedNames = [self installedFolderNames];
    NSMutableSet<NSString *> *matchedWinFolders = [NSMutableSet set];

    // ── Primary pass: iterate macOS entries ────────────────────────────
    for (NSDictionary *macEntry in macPlugins) {
        if (![macEntry isKindOfClass:[NSDictionary class]]) continue;

        NppPluginEntry *pe = [[NppPluginEntry alloc] init];
        pe.folderName        = macEntry[@"folder-name"] ?: @"";
        pe.displayName       = macEntry[@"display-name"] ?: pe.folderName;
        pe.pluginDescription = macEntry[@"description"] ?: @"";
        pe.author            = macEntry[@"author"] ?: @"";
        pe.homepage          = macEntry[@"homepage"] ?: @"";
        pe.macVersion        = macEntry[@"version"] ?: @"";
        pe.macRepository     = macEntry[@"repository"] ?: @"";
        pe.macPluginID       = macEntry[@"id"] ?: @"";
        pe.macDylibID        = macEntry[@"dylib-id"] ?: @"";
        pe.macDylibBuilt     = macEntry[@"dylib-built"] ?: @"";
        pe.macNppMinVersion  = macEntry[@"npp-min-version"] ?: @"";
        pe.isMacAvailable    = YES;

        // Three-tier lookup for the Windows counterpart (if any).
        NSDictionary *winMatch = nil;
        if (pe.folderName.length > 0)
            winMatch = winByFolder[pe.folderName];
        if (!winMatch && pe.displayName.length > 0)
            winMatch = winByName[pe.displayName];
        if (!winMatch && pe.homepage.length > 0)
            winMatch = winByHomepage[pe.homepage.lowercaseString];

        if (winMatch) {
            NSString *winFolder = winMatch[@"folder-name"] ?: @"";
            if (winFolder.length > 0) [matchedWinFolders addObject:winFolder];

            pe.version    = winMatch[@"version"] ?: @"";
            pe.repository = winMatch[@"repository"] ?: @"";
            pe.pluginID   = winMatch[@"id"] ?: @"";

            if (pe.pluginDescription.length == 0)
                pe.pluginDescription = winMatch[@"description"] ?: @"";
            if (pe.author.length == 0)
                pe.author = winMatch[@"author"] ?: @"";
            if (pe.homepage.length == 0)
                pe.homepage = winMatch[@"homepage"] ?: @"";
        }

        pe.isInstalled = [installedNames containsObject:pe.folderName];
        [_allAvailable addObject:pe];
    }

    // ── Secondary pass: Windows-only orphans for the Incompatible tab ──
    if (winPlugins) {
        for (NSDictionary *winEntry in winPlugins) {
            if (![winEntry isKindOfClass:[NSDictionary class]]) continue;
            NSString *winFolder = winEntry[@"folder-name"] ?: @"";
            if (winFolder.length == 0) continue;
            if ([matchedWinFolders containsObject:winFolder]) continue;

            NppPluginEntry *pe = [[NppPluginEntry alloc] init];
            pe.folderName        = winFolder;
            pe.displayName       = winEntry[@"display-name"] ?: winFolder;
            pe.version           = winEntry[@"version"] ?: @"";
            pe.pluginDescription = winEntry[@"description"] ?: @"";
            pe.author            = winEntry[@"author"] ?: @"";
            pe.homepage          = winEntry[@"homepage"] ?: @"";
            pe.repository        = winEntry[@"repository"] ?: @"";
            pe.pluginID          = winEntry[@"id"] ?: @"";
            pe.isMacAvailable    = NO;
            pe.isInstalled       = [installedNames containsObject:pe.folderName];
            [_allAvailable addObject:pe];
        }
    }

    // Sort: macOS-available first, then alphabetical within each group.
    [_allAvailable sortUsingComparator:^NSComparisonResult(NppPluginEntry *a, NppPluginEntry *b) {
        if (a.isMacAvailable != b.isMacAvailable)
            return a.isMacAvailable ? NSOrderedAscending : NSOrderedDescending;
        return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
    }];

    NSInteger macCount = 0;
    for (NppPluginEntry *pe in _allAvailable)
        if (pe.isMacAvailable) macCount++;

    NSLog(@"[PluginsAdmin] Catalog: %lu total (%ld macOS-available, %ld Windows-only)",
          (unsigned long)_allAvailable.count, (long)macCount,
          (long)((NSInteger)_allAvailable.count - macCount));

    // Footer stats line — same font/colour as the version label above it.
    // %lu = total rows in the Available list (macOS ports + unported
    // Windows entries, each counted exactly once), %ld = how many of
    // those are actually installable on macOS today.
    _statsLabel.stringValue = [NSString stringWithFormat:
        @"Plugins in catalog:  %lu  ·  Installable on macOS:  %ld",
        (unsigned long)_allAvailable.count, (long)macCount];

    // Enrich _installed with catalog fields so the Installed tab can
    // render version / built date / OS columns. Without this the
    // entries are bare (just folder-name) and the table shows blanks.
    [self enrichInstalledFromCatalog];
}

// Pull display metadata from the catalog into the bare entries produced
// by scanInstalledPlugins. Two cases:
//   - Installed folder matches a catalog entry → copy displayName,
//     macVersion, macDylibBuilt, author/description/homepage, and mark
//     isMacAvailable=YES so the OS column renders "macOS 11+".
//   - Installed folder not in catalog (e.g. a locally-built plugin like
//     NppBeads that we don't publish) → still mark isMacAvailable=YES
//     because it's literally running on macOS, and use the dylib's
//     file mtime as a best-effort "built date" substitute.
- (void)enrichInstalledFromCatalog {
    NSMutableDictionary<NSString *, NppPluginEntry *> *catalogByFolder =
        [NSMutableDictionary dictionary];
    for (NppPluginEntry *pe in _allAvailable) {
        if (pe.folderName.length > 0)
            catalogByFolder[pe.folderName] = pe;
    }

    NSString *pluginsDir = NppConfigSubpath(@"plugins");

    for (NppPluginEntry *ip in _installed) {
        NppPluginEntry *c = catalogByFolder[ip.folderName];
        if (c && c.isMacAvailable) {
            ip.displayName       = c.displayName;
            ip.pluginDescription = c.pluginDescription;
            ip.author            = c.author;
            ip.homepage          = c.homepage;
            ip.macVersion        = c.macVersion;
            ip.macRepository     = c.macRepository;
            ip.macPluginID       = c.macPluginID;
            ip.macDylibID        = c.macDylibID;
            ip.macDylibBuilt     = c.macDylibBuilt;
            ip.macNppMinVersion  = c.macNppMinVersion;
            ip.isMacAvailable    = YES;
        } else {
            // Unknown plugin — at minimum tag it as macOS (it IS installed
            // in the mac plugin folder as a mac dylib) and fall back to
            // file mtime for the built date.
            ip.isMacAvailable = YES;
            NSString *dylibPath = [[pluginsDir
                stringByAppendingPathComponent:ip.folderName]
                stringByAppendingPathComponent:
                    [ip.folderName stringByAppendingPathExtension:@"dylib"]];
            NSString *mtimeDate = mtimeDateOfFile(dylibPath);
            if (mtimeDate) ip.macDylibBuilt = mtimeDate;
        }
    }
}

- (void)scanInstalledPlugins {
    [_installed removeAllObjects];
    NSString *pluginsDir = NppConfigSubpath(@"plugins");
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *subdirs = [fm contentsOfDirectoryAtPath:pluginsDir error:nil];

    for (NSString *dirName in subdirs) {
        NSString *dirPath = [pluginsDir stringByAppendingPathComponent:dirName];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dirPath isDirectory:&isDir] || !isDir) continue;

        NSString *dylibPath = [dirPath stringByAppendingPathComponent:
            [dirName stringByAppendingPathExtension:@"dylib"]];
        if (![fm fileExistsAtPath:dylibPath]) continue;

        NppPluginEntry *pe = [[NppPluginEntry alloc] init];
        pe.folderName   = dirName;
        pe.displayName  = dirName;
        pe.version      = @"";
        pe.isInstalled  = YES;

        // Try to get version from the loaded plugin manager
        pe.pluginDescription = @"Installed macOS plugin";

        [_installed addObject:pe];
    }
}

- (NSSet<NSString *> *)installedFolderNames {
    NSMutableSet *names = [NSMutableSet set];
    for (NppPluginEntry *pe in _installed)
        [names addObject:pe.folderName];
    return names;
}

// ── Updates-tab scan helpers ────────────────────────────────────────────

// Compute sha256 of a file on disk. Returns lowercase hex, or nil on
// error (missing/unreadable). Uses a 64KB streaming buffer so large
// plugin dylibs (ComparePlus is ~700KB; the theoretical upper bound
// matters if plugins grow) don't spike memory.
static NSString *sha256OfFile(NSString *path) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    const NSUInteger chunk = 64 * 1024;
    @try {
        while (1) {
            NSData *d = [fh readDataOfLength:chunk];
            if (d.length == 0) break;
            CC_SHA256_Update(&ctx, d.bytes, (CC_LONG)d.length);
        }
    } @catch (NSException *e) {
        [fh closeFile];
        return nil;
    }
    [fh closeFile];

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

// mtime of a file formatted as YYYY-MM-DD in the local calendar. That
// matches the catalog's `dylib-built` resolution exactly (day-level, no
// time-of-day component), so string compare sorts correctly.
static NSString *mtimeDateOfFile(NSString *path) {
    NSError *err = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:path error:&err];
    NSDate *mtime = attrs[NSFileModificationDate];
    if (!mtime) return nil;
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd";
    df.timeZone  = [NSTimeZone localTimeZone];
    return [df stringFromDate:mtime];
}

// Very small semver compare — splits on "." and numeric-compares each
// component left-to-right. Missing components are treated as 0 so
// "1.0" == "1.0.0" == "1.0.0.0". Returns -1 / 0 / +1.
static NSInteger compareSemver(NSString *a, NSString *b) {
    NSArray<NSString *> *aa = [a componentsSeparatedByString:@"."];
    NSArray<NSString *> *bb = [b componentsSeparatedByString:@"."];
    NSUInteger n = MAX(aa.count, bb.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSInteger av = (i < aa.count) ? [aa[i] integerValue] : 0;
        NSInteger bv = (i < bb.count) ? [bb[i] integerValue] : 0;
        if (av < bv) return -1;
        if (av > bv) return +1;
    }
    return 0;
}

// Scan every installed plugin's dylib and populate pe.installedDylibSHA
// + pe.installedDylibDate on the matching _allAvailable entry. Cheap —
// one hash and one stat per installed dylib. Called when the user opens
// the Updates tab; re-run on each open so we pick up any manual edits.
- (void)refreshInstalledDylibFingerprints {
    NSString *pluginsDir = NppConfigSubpath(@"plugins");
    NSFileManager *fm = [NSFileManager defaultManager];

    // Build a folder-name → full-dylib-path map from _installed (which
    // scanInstalledPlugins already populated with every valid plugin dir).
    NSMutableDictionary<NSString *, NSString *> *pathByFolder =
        [NSMutableDictionary dictionary];
    for (NppPluginEntry *ip in _installed) {
        NSString *dylib = [[pluginsDir
            stringByAppendingPathComponent:ip.folderName]
            stringByAppendingPathComponent:
                [ip.folderName stringByAppendingPathExtension:@"dylib"]];
        if ([fm fileExistsAtPath:dylib])
            pathByFolder[ip.folderName] = dylib;
    }

    // Stamp _allAvailable entries (the objects the Updates tab iterates).
    for (NppPluginEntry *pe in _allAvailable) {
        NSString *path = pathByFolder[pe.folderName];
        if (!path) {
            pe.installedDylibSHA  = nil;
            pe.installedDylibDate = nil;
            continue;
        }
        pe.installedDylibSHA  = sha256OfFile(path);
        pe.installedDylibDate = mtimeDateOfFile(path);
    }
}

// Three-gate filter that picks entries for the Updates tab:
//   1. Plugin must be installed and present in the catalog with all
//      three Updates-tab fields.
//   2. Installed dylib sha256 must differ from catalog dylib-id.
//   3. Catalog dylib-built must be strictly newer (by date) than the
//      installed file's mtime date, AND host NPP version must be >=
//      catalog npp-min-version.
//
// Any entry that fails a gate is silently skipped — the tab is meant
// to show only what the user can act on right now.
- (NSArray<NppPluginEntry *> *)updateCandidates {
    NSString *hostVer = [[NSBundle mainBundle].infoDictionary
        objectForKey:@"CFBundleShortVersionString"] ?: @"0.0.0";

    NSMutableArray<NppPluginEntry *> *out = [NSMutableArray array];
    for (NppPluginEntry *pe in _allAvailable) {
        if (!pe.isMacAvailable || !pe.isInstalled) continue;
        if (pe.macDylibID.length != 64)         continue;  // no backfill
        if (pe.macDylibBuilt.length == 0)       continue;
        if (pe.macNppMinVersion.length == 0)    continue;
        if (pe.installedDylibSHA.length != 64)  continue;  // scan failed

        if ([pe.installedDylibSHA.lowercaseString
                isEqualToString:pe.macDylibID.lowercaseString])
            continue;  // gate 1: up to date

        if (pe.installedDylibDate.length == 0)  continue;
        // YYYY-MM-DD strings sort lexicographically == chronologically.
        if ([pe.macDylibBuilt compare:pe.installedDylibDate] != NSOrderedDescending)
            continue;  // gate 2: catalog not newer than installed

        if (compareSemver(hostVer, pe.macNppMinVersion) < 0)
            continue;  // gate 3: host too old for this release

        [out addObject:pe];
    }
    return out;
}

// ── Tab & filter logic ──────────────────────────────────────────────────

- (void)refreshForCurrentTab {
    [_checkedPlugins removeAllObjects];
    [_filteredList removeAllObjects];

    NppLocalizer *loc = [NppLocalizer shared];
    switch (_currentTab) {
        case PluginAdminTabAvailable:
            _actionButton.title = [loc translate:@"Install"];
            _actionButton.hidden = NO;
            [_filteredList addObjectsFromArray:_allAvailable];
            break;

        case PluginAdminTabUpdates: {
            _actionButton.title = [loc translate:@"Update"];
            _actionButton.hidden = NO;
            // Re-scan on every Updates-tab open — cheap, and keeps us
            // honest against manual edits to ~/Library/Application Support/Nextpad++/plugins/.
            [self refreshInstalledDylibFingerprints];
            [_filteredList addObjectsFromArray:[self updateCandidates]];
            break;
        }

        case PluginAdminTabInstalled:
            _actionButton.title = [loc translate:@"Remove"];
            _actionButton.hidden = NO;
            [_filteredList addObjectsFromArray:_installed];
            break;

        case PluginAdminTabIncompatible:
            _actionButton.hidden = YES;
            // Windows-only plugins not yet ported to macOS
            for (NppPluginEntry *pe in _allAvailable) {
                if (!pe.isMacAvailable)
                    [_filteredList addObject:pe];
            }
            break;
    }

    // Apply search filter
    if (_searchText.length > 0) {
        NSPredicate *pred = [NSPredicate predicateWithFormat:
            @"displayName CONTAINS[cd] %@ OR pluginDescription CONTAINS[cd] %@",
            _searchText, _searchText];
        NSArray *filtered = [_filteredList filteredArrayUsingPredicate:pred];
        [_filteredList setArray:[filtered mutableCopy]];
    }

    [_tableView reloadData];
    [_descriptionView setString:@""];
    _actionButton.enabled = NO;
}

// ── NSTabViewDelegate ───────────────────────────────────────────────────

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)tabViewItem {
    NSInteger idx = [tabView indexOfTabViewItem:tabViewItem];
    _currentTab = (PluginAdminTab)idx;
    [self refreshForCurrentTab];
}

// ── NSTableViewDataSource ───────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return (NSInteger)_filteredList.count;
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NppPluginEntry *pe = _filteredList[row];
    NSString *ident = col.identifier;
    BOOL canInstall = pe.isMacAvailable || pe.isInstalled;

    if ([ident isEqualToString:@"check"]) {
        NSButton *cb = [tv makeViewWithIdentifier:@"check" owner:self];
        if (!cb) {
            cb = [NSButton checkboxWithTitle:@"" target:self action:@selector(checkboxToggled:)];
            cb.identifier = @"check";
        }

        if (_currentTab == PluginAdminTabIncompatible) {
            // Incompatible is read-only — there's no action you can take
            // from this tab, so a checkbox would be misleading.
            cb.hidden = YES;
        } else if (_currentTab == PluginAdminTabAvailable) {
            cb.hidden = !pe.isMacAvailable;
            if (pe.isInstalled) {
                // Already installed: show checked but disabled
                cb.enabled = NO;
                cb.state = NSControlStateValueOn;
            } else {
                cb.enabled = pe.isMacAvailable;
                cb.state = [_checkedPlugins containsObject:pe.folderName]
                             ? NSControlStateValueOn : NSControlStateValueOff;
            }
        } else {
            cb.hidden = NO;
            cb.enabled = YES;
            cb.state = [_checkedPlugins containsObject:pe.folderName]
                         ? NSControlStateValueOn : NSControlStateValueOff;
        }
        cb.tag = row;
        return cb;
    }

    NSTextField *tf = [tv makeViewWithIdentifier:ident owner:self];
    if (!tf) {
        tf = [NSTextField labelWithString:@""];
        tf.identifier = ident;
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        tf.font = [NSFont systemFontOfSize:12];
    }

    if ([ident isEqualToString:@"plugin"]) {
        tf.stringValue = pe.displayName ?: @"";
    } else if ([ident isEqualToString:@"version"]) {
        // Show macOS version for available macOS plugins, Windows version otherwise
        if (pe.isMacAvailable && pe.macVersion.length > 0)
            tf.stringValue = pe.macVersion;
        else
            tf.stringValue = pe.version ?: @"";
    } else if ([ident isEqualToString:@"built"]) {
        // Catalog-supplied build date from `dylib-built`. Populated only
        // on mac-available entries; Windows-only plugins have no
        // equivalent field in pl.x64.json and display as a blank cell.
        tf.stringValue = (pe.isMacAvailable && pe.macDylibBuilt.length > 0)
            ? pe.macDylibBuilt
            : @"";
    } else if ([ident isEqualToString:@"os"]) {
        tf.stringValue = pe.isMacAvailable ? @"macOS 11+" : @"Windows only";
    }

    // Dim text for installed or Windows-only plugins (Available tab)
    if (_currentTab == PluginAdminTabAvailable && (!canInstall || pe.isInstalled)) {
        tf.textColor = [NSColor tertiaryLabelColor];
    } else {
        tf.textColor = [NSColor labelColor];
    }

    return tf;
}

// ── NSTableViewDelegate ─────────────────────────────────────────────────

- (void)tableViewSelectionDidChange:(NSNotification *)notif {
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_filteredList.count) {
        [_descriptionView setString:@""];
        return;
    }

    NppPluginEntry *pe = _filteredList[row];
    NSMutableString *desc = [NSMutableString string];

    if (_currentTab == PluginAdminTabAvailable) {
        if (pe.isMacAvailable) {
            [desc appendFormat:@"[macOS available — v%@]\n\n",
             pe.macVersion.length > 0 ? pe.macVersion : pe.version];
        } else {
            [desc appendString:@"[Windows only — macOS port not yet available]\n\n"];
        }
    }

    if (pe.pluginDescription.length > 0)
        [desc appendFormat:@"%@\n\n", pe.pluginDescription];
    if (pe.author.length > 0)
        [desc appendFormat:@"Author: %@\n", pe.author];
    if (pe.homepage.length > 0)
        [desc appendFormat:@"Homepage: %@\n", pe.homepage];

    [_descriptionView setString:desc];
}

// ── Actions ─────────────────────────────────────────────────────────────

- (void)checkboxToggled:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)_filteredList.count) return;

    NppPluginEntry *pe = _filteredList[row];
    if (sender.state == NSControlStateValueOn)
        [_checkedPlugins addObject:pe.folderName];
    else
        [_checkedPlugins removeObject:pe.folderName];

    _actionButton.enabled = _checkedPlugins.count > 0;
}

- (void)searchChanged:(id)sender {
    _searchText = _searchField.stringValue;
    [self refreshForCurrentTab];
}

// Live filter on every keystroke
- (void)controlTextDidChange:(NSNotification *)notif {
    if (notif.object == _searchField) {
        _searchText = _searchField.stringValue;
        [self refreshForCurrentTab];
    }
}

- (void)actionPressed:(id)sender {
    if (_checkedPlugins.count == 0) return;

    switch (_currentTab) {
        case PluginAdminTabAvailable:
            [self installCheckedPlugins];
            break;
        case PluginAdminTabInstalled:
            [self removeCheckedPlugins];
            break;
        case PluginAdminTabUpdates:
            [self updateCheckedPlugins];
            break;
        case PluginAdminTabIncompatible:
            break;
    }
}

- (void)installCheckedPlugins {
    // Collect macOS-available plugins that are checked
    NSMutableArray<NppPluginEntry *> *toInstall = [NSMutableArray array];
    for (NppPluginEntry *pe in _allAvailable) {
        if ([_checkedPlugins containsObject:pe.folderName] && pe.isMacAvailable)
            [toInstall addObject:pe];
    }

    if (toInstall.count == 0) return;

    NSMutableArray *names = [NSMutableArray array];
    for (NppPluginEntry *pe in toInstall)
        [names addObject:pe.displayName];

    NppLocalizer *loc = [NppLocalizer shared];
    NSAlert *confirm = [[NSAlert alloc] init];
    confirm.messageText = [loc translate:@"Install Plugins"];
    confirm.informativeText = [NSString stringWithFormat:
        @"%@\n\n%@\n\n%@",
        [loc translate:@"Install the following plugins?"],
        [names componentsJoinedByString:@"\n"],
        [loc translate:@"Restart the application for changes to take effect."]];
    [confirm addButtonWithTitle:[loc translate:@"Install"]];
    [confirm addButtonWithTitle:[loc translate:@"Cancel"]].keyEquivalent = @"\033";

    [confirm beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse resp) {
        if (resp != NSAlertFirstButtonReturn) return;
        [self downloadAndInstallPlugins:toInstall index:0];
    }];
}

// ── Update flow (Updates tab) ──────────────────────────────────────────

- (void)updateCheckedPlugins {
    // Intersect _checkedPlugins with the Updates-tab candidate set so we
    // never act on stale checks left behind after a tab switch.
    NSMutableArray<NppPluginEntry *> *toUpdate = [NSMutableArray array];
    for (NppPluginEntry *pe in [self updateCandidates]) {
        if ([_checkedPlugins containsObject:pe.folderName])
            [toUpdate addObject:pe];
    }
    if (toUpdate.count == 0) return;

    NSMutableArray *names = [NSMutableArray array];
    for (NppPluginEntry *pe in toUpdate)
        [names addObject:[NSString stringWithFormat:@"%@ → v%@",
                          pe.displayName, pe.macVersion]];

    NppLocalizer *loc = [NppLocalizer shared];
    NSAlert *confirm = [[NSAlert alloc] init];
    confirm.messageText = [loc translate:@"Update Plugins"];
    confirm.informativeText = [NSString stringWithFormat:
        @"%@\n\n%@\n\n%@\n\n%@",
        [loc translate:@"Update the following plugins?"],
        [names componentsJoinedByString:@"\n"],
        [loc translate:@"Current versions are backed up to ~/Library/Application Support/Nextpad++/plugin-backups/ before being replaced."],
        [loc translate:@"Restart the application for changes to take effect."]];
    [confirm addButtonWithTitle:[loc translate:@"Update"]];
    [confirm addButtonWithTitle:[loc translate:@"Cancel"]].keyEquivalent = @"\033";

    [confirm beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse resp) {
        if (resp != NSAlertFirstButtonReturn) return;

        // Phase 1: synchronous backup+delete per plugin. Only plugins
        // whose backup+delete succeeded move on to phase 2 — a plugin
        // whose backup failed stays intact on disk (nothing gets deleted
        // if we can't prove we have a recovery copy).
        NSMutableArray<NppPluginEntry *> *ready = [NSMutableArray array];
        for (NppPluginEntry *pe in toUpdate) {
            if ([self backupAndDeletePluginFolder:pe])
                [ready addObject:pe];
        }
        if (ready.count == 0) return;

        // Phase 2: reuse the existing install chain. It downloads each
        // zip, verifies its sha against catalog `id`, and extracts into
        // the plugins dir. Because phase 1 deleted the old folder, the
        // extraction lands on a clean slate (no stale files surviving
        // from the previous version).
        [self downloadAndInstallPlugins:ready index:0];
    }];
}

// Zip the plugin folder to ~/Library/Application Support/Nextpad++/plugin-backups/<folder>_<ts>.zip
// via ditto -c -k --keepParent, then remove the folder. Returns YES iff
// both steps succeeded so the caller knows it's safe to let the
// extraction step overwrite.
- (BOOL)backupAndDeletePluginFolder:(NppPluginEntry *)pe {
    NSString *pluginDir  = [NppConfigSubpath(@"plugins")
        stringByAppendingPathComponent:pe.folderName];
    NSString *backupDir  = NppConfigSubpath(@"plugin-backups");
    NSFileManager *fm    = [NSFileManager defaultManager];

    // If there's nothing on disk, there's nothing to back up or remove —
    // treat as success so a fresh install can proceed.
    if (![fm fileExistsAtPath:pluginDir]) return YES;

    NSError *err = nil;
    if (![fm createDirectoryAtPath:backupDir withIntermediateDirectories:YES
                        attributes:nil error:&err]) {
        NSLog(@"[PluginsAdmin] Backup dir create failed: %@", err);
        [self showInstallError:pe.displayName
                       detail:@"Could not create the plugin-backups folder. Update skipped — existing plugin folder is untouched."];
        return NO;
    }

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd_HHmmss";
    df.timeZone   = [NSTimeZone localTimeZone];
    NSString *ts  = [df stringFromDate:[NSDate date]];
    NSString *backupZip = [backupDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@_%@.zip", pe.folderName, ts]];

    // `ditto -c -k --keepParent` produces a PKZip archive whose top
    // level is the plugin folder itself — so the backup mirrors the
    // shape of an install zip and unzips back into <folder>/… cleanly.
    NSTask *zipTask = [[NSTask alloc] init];
    zipTask.launchPath = @"/usr/bin/ditto";
    zipTask.arguments  = @[@"-c", @"-k", @"--keepParent", pluginDir, backupZip];
    zipTask.standardOutput = [NSPipe pipe];
    zipTask.standardError  = [NSPipe pipe];
    BOOL zipOK = NO;
    @try {
        [zipTask launch];
        [zipTask waitUntilExit];
        zipOK = (zipTask.terminationStatus == 0);
    } @catch (NSException *e) {
        NSLog(@"[PluginsAdmin] ditto backup threw for %@: %@", pe.displayName, e);
    }
    if (!zipOK) {
        [self showInstallError:pe.displayName
                       detail:@"Backup step failed — existing plugin folder is untouched, update skipped."];
        return NO;
    }
    NSLog(@"[PluginsAdmin] Backup %@ → %@", pe.displayName, backupZip);

    if (![fm removeItemAtPath:pluginDir error:&err]) {
        NSLog(@"[PluginsAdmin] Remove failed for %@: %@", pluginDir, err);
        [self showInstallError:pe.displayName
                       detail:[NSString stringWithFormat:
            @"Backup saved at plugin-backups/, but could not remove existing folder: %@. Update skipped.",
            err.localizedDescription ?: @"unknown"]];
        return NO;
    }
    return YES;
}

- (void)downloadAndInstallPlugins:(NSArray<NppPluginEntry *> *)plugins index:(NSUInteger)idx {
    if (idx >= plugins.count) {
        // All done — refresh
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_spinner stopAnimation:nil];
            [self scanInstalledPlugins];
            // Re-merge installed state
            NSSet *inst = [self installedFolderNames];
            for (NppPluginEntry *pe in self->_allAvailable)
                pe.isInstalled = [inst containsObject:pe.folderName];
            [self enrichInstalledFromCatalog];
            [self refreshForCurrentTab];

            NppLocalizer *loc = [NppLocalizer shared];
            NSAlert *done = [[NSAlert alloc] init];
            done.messageText = [loc translate:@"Installation Complete"];
            done.informativeText = [loc translate:@"Restart the application to load the installed plugins."];
            [done beginSheetModalForWindow:self.window completionHandler:nil];
        });
        return;
    }

    NppPluginEntry *pe = plugins[idx];
    NSString *url = pe.macRepository;
    if (url.length == 0) {
        NSLog(@"[PluginsAdmin] No macOS repository URL for %@", pe.displayName);
        [self downloadAndInstallPlugins:plugins index:idx + 1];
        return;
    }

    [_spinner startAnimation:nil];
    NSLog(@"[PluginsAdmin] Downloading %@ from %@", pe.displayName, url);

    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:url]
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:120];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (err || !data) {
                    NSLog(@"[PluginsAdmin] Download failed for %@: %@", pe.displayName, err);
                    [self showInstallError:pe.displayName
                                   detail:[NSString stringWithFormat:@"Download failed: %@",
                                           err.localizedDescription ?: @"unknown error"]];
                    [self downloadAndInstallPlugins:plugins index:idx + 1];
                    return;
                }

                // Verify SHA-256
                if (pe.macPluginID.length == 64) {
                    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
                    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
                    NSMutableString *hexHash = [NSMutableString stringWithCapacity:64];
                    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
                        [hexHash appendFormat:@"%02x", hash[i]];

                    if (![hexHash isEqualToString:pe.macPluginID.lowercaseString]) {
                        NSLog(@"[PluginsAdmin] SHA-256 mismatch for %@: expected %@, got %@",
                              pe.displayName, pe.macPluginID, hexHash);
                        [self showInstallError:pe.displayName
                                       detail:@"SHA-256 hash mismatch — download may be corrupt."];
                        [self downloadAndInstallPlugins:plugins index:idx + 1];
                        return;
                    }
                }

                // Extract ZIP to ~/Library/Application Support/Nextpad++/plugins/
                NSString *pluginsDir = NppConfigSubpath(@"plugins");
                NSFileManager *fm = [NSFileManager defaultManager];
                [fm createDirectoryAtPath:pluginsDir withIntermediateDirectories:YES
                               attributes:nil error:nil];

                if (![self extractZipData:data toDirectory:pluginsDir forPlugin:pe]) {
                    [self showInstallError:pe.displayName detail:@"Failed to extract ZIP archive."];
                }

                [self downloadAndInstallPlugins:plugins index:idx + 1];
            });
        }];
    [task resume];
}

- (BOOL)extractZipData:(NSData *)zipData toDirectory:(NSString *)destDir
             forPlugin:(NppPluginEntry *)pe {
    // Write ZIP to a temp file, then use NSFileCoordinator/unzip
    NSString *tmpPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"npp_plugin_%@.zip", pe.folderName]];
    if (![zipData writeToFile:tmpPath atomically:YES]) return NO;

    // Use /usr/bin/ditto to extract (handles ZIP natively on macOS)
    // The ZIP contains files inside a subfolder (e.g. nppURLPlugin/nppURLPlugin.dylib)
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/ditto";
    task.arguments = @[@"-xk", tmpPath, destDir];
    task.standardOutput = [NSPipe pipe];
    task.standardError  = [NSPipe pipe];

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        NSLog(@"[PluginsAdmin] ditto failed for %@: %@", pe.displayName, e);
        [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
        return NO;
    }

    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];

    if (task.terminationStatus != 0) {
        NSLog(@"[PluginsAdmin] ditto exit %d for %@", task.terminationStatus, pe.displayName);
        return NO;
    }

    // Verify the dylib exists after extraction
    NSString *dylibPath = [destDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@/%@.dylib", pe.folderName, pe.folderName]];
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:dylibPath];
    if (!exists) {
        NSLog(@"[PluginsAdmin] Warning: %@ not found after extraction", dylibPath);
    } else {
        NSLog(@"[PluginsAdmin] Installed %@ → %@", pe.displayName, dylibPath);
    }
    return exists;
}

- (void)showInstallError:(NSString *)pluginName detail:(NSString *)detail {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"%@ %@", [[NppLocalizer shared] translate:@"Failed to Install"], pluginName];
    alert.informativeText = detail;
    alert.alertStyle = NSAlertStyleWarning;
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)removeCheckedPlugins {
    NSString *names = [[_checkedPlugins allObjects] componentsJoinedByString:@", "];
    NppLocalizer *loc = [NppLocalizer shared];
    NSAlert *confirm = [[NSAlert alloc] init];
    confirm.messageText = [loc translate:@"Remove Plugins"];
    confirm.informativeText = [NSString stringWithFormat:
        @"%@\n\n%@\n\n%@ %@",
        [loc translate:@"Remove the following plugins?"], names,
        [loc translate:@"This will delete the plugin files."],
        [loc translate:@"Restart the application for changes to take effect."]];
    [confirm addButtonWithTitle:[loc translate:@"Remove"]];
    [confirm addButtonWithTitle:[loc translate:@"Cancel"]].keyEquivalent = @"\033";
    confirm.alertStyle = NSAlertStyleWarning;

    [confirm beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse resp) {
        if (resp != NSAlertFirstButtonReturn) return;

        NSString *pluginsDir = NppConfigSubpath(@"plugins");
        NSFileManager *fm = [NSFileManager defaultManager];

        for (NSString *name in self->_checkedPlugins) {
            NSString *dir = [pluginsDir stringByAppendingPathComponent:name];
            NSError *err = nil;
            [fm removeItemAtPath:dir error:&err];
            if (err)
                NSLog(@"[PluginsAdmin] Failed to remove %@: %@", name, err);
        }

        [self scanInstalledPlugins];
        NSSet *inst = [self installedFolderNames];
        for (NppPluginEntry *pe in self->_allAvailable)
            pe.isInstalled = [inst containsObject:pe.folderName];
        [self enrichInstalledFromCatalog];
        [self refreshForCurrentTab];
    }];
}

- (void)closePressed:(id)sender {
    [self.window close];
}

- (void)openRepoLink:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:kPluginListRepoURL]];
}

@end
