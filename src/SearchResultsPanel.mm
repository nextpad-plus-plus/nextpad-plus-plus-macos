#import "SearchResultsPanel.h"
#import "NppThemeManager.h"
#import "StyleConfiguratorWindowController.h"
#import "NppLocalizer.h"
#import "ScintillaView.h"
#import "Scintilla.h"
#import "SciLexer.h"
#include <vector>

// Forward-declare Lexilla's CreateLexer (statically linked)
#include "ILexer.h"
extern "C" Scintilla::ILexer5 *CreateLexer(const char *name);

// Fold levels matching LexSearchResult.cxx
enum { searchHeaderLevel = SC_FOLDLEVELBASE, fileHeaderLevel, resultLevel };

// ── Internal data for tracking results ───────────────────────────────────────

struct _SRLineInfo {
    std::string filePath;
    int lineNumber;       // 1-based, 0 = header line
};

// ── SearchResultsPanel ───────────────────────────────────────────────────────

@implementation SearchResultsPanel {
    ScintillaView *_sci;
    NSScrollView  *_scrollContainer;
    NSView        *_titleBar;

    // Parallel data — one entry per line in the ScintillaView
    std::vector<_SRLineInfo> _lineInfos;

    // SearchResultMarkings for the lexer
    std::vector<SearchResultMarkingLine> _markingLines;
    SearchResultMarkings _markingsStruct;

    // Toggle states
    BOOL _wordWrapEnabled;
    BOOL _purgeBeforeSearch;

    // Filter bar (incremental search within results)
    NSView              *_filterBar;
    NSTextField         *_filterField;
    NSButton            *_filterMatchCase;
    NSButton            *_filterWholeWord;
    NSTextField         *_filterStatusLabel;
    NSLayoutConstraint  *_filterBarHeight;

    NSBox               *_filterSep;

    // Key event monitor for Cmd+C interception
    id _keyMonitor;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self _buildUI];
        [self _applyTheme];
        // Tahoe: rounded-card corners to match the editor / side panels. Gated —
        // Classic stays square.
        if ([NppThemeManager shared].usesGlassMaterials) {
            self.wantsLayer = YES;
            self.layer.cornerRadius  = 8.0;
            self.layer.masksToBounds = YES;
        }
        _markingsStruct._length   = 0;
        _markingsStruct._markings = nullptr;
        _wordWrapEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"SearchResultsWordWrap"];
        _purgeBeforeSearch = [[NSUserDefaults standardUserDefaults] boolForKey:@"SearchResultsPurge"];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_themeChanged:)
                                                     name:@"NPPPreferencesChanged" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_darkModeChanged:)
                                                     name:NPPDarkModeChangedNotification object:nil];

        // Intercept Cmd+C when our ScintillaView has focus — route to visibility-aware copy
        __weak typeof(self) wSelf = self;
        _keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
            typeof(self) sSelf = wSelf;
            if (!sSelf) return event;
            if ((event.modifierFlags & NSEventModifierFlagCommand) &&
                [event.charactersIgnoringModifiers isEqualToString:@"c"]) {
                // Check if our ScintillaView (or its content view) is the first responder
                NSResponder *fr = event.window.firstResponder;
                NSView *v = [fr isKindOfClass:[NSView class]] ? (NSView *)fr : nil;
                while (v) {
                    if (v == sSelf->_sci) {
                        [sSelf _copy:nil];
                        return nil; // consume the event
                    }
                    v = v.superview;
                }
            }
            return event;
        }];
    }
    return self;
}

- (instancetype)init { return [self initWithFrame:NSZeroRect]; }

- (void)dealloc {
    if (_keyMonitor) [NSEvent removeMonitor:_keyMonitor];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UI Construction

- (void)_buildUI {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    _sci = [[ScintillaView alloc] initWithFrame:NSZeroRect];
    _sci.translatesAutoresizingMaskIntoConstraints = NO;

    // Install LexSearchResult lexer
    Scintilla::ILexer5 *lexer = CreateLexer("searchResult");
    if (lexer) {
        [_sci message:SCI_SETILEXER wParam:0 lParam:(sptr_t)lexer];
    }

    // Read-only
    [_sci message:SCI_SETREADONLY wParam:1];

    // Folding setup
    [_sci message:SCI_SETPROPERTY wParam:(uptr_t)"fold" lParam:(sptr_t)"1"];
    [_sci message:SCI_SETMARGINTYPEN  wParam:2 lParam:SC_MARGIN_SYMBOL];
    [_sci message:SCI_SETMARGINMASKN  wParam:2 lParam:SC_MASK_FOLDERS];
    [_sci message:SCI_SETMARGINWIDTHN wParam:2 lParam:16];
    [_sci message:SCI_SETMARGINSENSITIVEN wParam:2 lParam:1];
    [_sci message:SCI_SETAUTOMATICFOLD wParam:SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE];

    // Fold markers: box style
    [_sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEROPEN    lParam:SC_MARK_BOXMINUS];
    [_sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDER        lParam:SC_MARK_BOXPLUS];
    [_sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERSUB     lParam:SC_MARK_VLINE];
    [_sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERTAIL    lParam:SC_MARK_LCORNER];
    [_sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEREND     lParam:SC_MARK_BOXPLUSCONNECTED];
    [_sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEROPENMID lParam:SC_MARK_BOXMINUSCONNECTED];
    [_sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERMIDTAIL lParam:SC_MARK_TCORNER];

    // Fold marker colors
    for (int i = SC_MARKNUM_FOLDEREND; i <= SC_MARKNUM_FOLDEROPEN; i++) {
        [_sci message:SCI_MARKERSETFORE wParam:i lParam:0xFFFFFF];
        [_sci message:SCI_MARKERSETBACK wParam:i lParam:0x808080];
    }

    // Hide line number margin, show only fold margin
    [_sci message:SCI_SETMARGINWIDTHN wParam:0 lParam:0];
    [_sci message:SCI_SETMARGINWIDTHN wParam:1 lParam:0];

    // No caret line highlight by default
    [_sci message:SCI_SETCARETLINEVISIBLE wParam:1];

    // EOL-filled styles for headers
    [_sci message:SCI_STYLESETEOLFILLED wParam:SCE_SEARCHRESULT_FILE_HEADER lParam:1];
    [_sci message:SCI_STYLESETEOLFILLED wParam:SCE_SEARCHRESULT_SEARCH_HEADER lParam:1];

    // Set self as ScintillaView delegate to receive notifications
    _sci.delegate = (id)self;

    // Replace default Scintilla context menu with our custom one
    _sci.menu = [self _buildContextMenu];

    // Apply persisted word wrap setting
    if (_wordWrapEnabled)
        [_sci message:SCI_SETWRAPMODE wParam:SC_WRAP_WORD];

    // Apply persisted zoom level
    NSInteger savedZoom = [[NSUserDefaults standardUserDefaults] integerForKey:@"PanelZoom_SearchResults"];
    if (savedZoom != 0)
        [_sci message:SCI_SETZOOM wParam:(uptr_t)savedZoom];

    // ── Title bar with close button ─────────────────────────────────────
    _titleBar = [[NSView alloc] init];
    _titleBar.translatesAutoresizingMaskIntoConstraints = NO;
    _titleBar.wantsLayer = YES;
    _titleBar.layer.backgroundColor = [NppThemeManager shared].panelBackground.CGColor;
    NSView *titleBar = _titleBar;

    NSTextField *titleLabel = [NSTextField labelWithString:[[NppLocalizer shared] translate:@"Search results"]];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = [NSFont systemFontOfSize:11];
    [titleBar addSubview:titleLabel];

    NSButton *closeBtn = [[NSButton alloc] init];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    closeBtn.bezelStyle = NSBezelStyleSmallSquare;
    closeBtn.bordered = NO;
    closeBtn.title = @"\u2715";
    closeBtn.font = [NSFont systemFontOfSize:10];
    closeBtn.toolTip = [[NppLocalizer shared] translate:@"Close Search Results"];
    closeBtn.target = self;
    closeBtn.action = @selector(_closePanel:);
    [closeBtn.widthAnchor constraintEqualToConstant:18].active = YES;
    [closeBtn.heightAnchor constraintEqualToConstant:18].active = YES;
    [titleBar addSubview:closeBtn];

    [NSLayoutConstraint activateConstraints:@[
        [titleBar.heightAnchor constraintEqualToConstant:22],
        [titleLabel.leadingAnchor constraintEqualToAnchor:titleBar.leadingAnchor constant:6],
        [titleLabel.centerYAnchor constraintEqualToAnchor:titleBar.centerYAnchor],
        [closeBtn.trailingAnchor constraintEqualToAnchor:titleBar.trailingAnchor constant:-4],
        [closeBtn.centerYAnchor constraintEqualToAnchor:titleBar.centerYAnchor],
    ]];

    NSBox *sep = [[NSBox alloc] init];
    sep.boxType = NSBoxSeparator;
    sep.translatesAutoresizingMaskIntoConstraints = NO;

    // ── Filter bar (incremental search within results) ─────────────────
    _filterBar = [[NSView alloc] init];
    _filterBar.translatesAutoresizingMaskIntoConstraints = NO;
    _filterBar.wantsLayer = YES;
    _filterBar.layer.backgroundColor = [NSColor controlBackgroundColor].CGColor;

    NppLocalizer *loc = [NppLocalizer shared];

    NSTextField *filterLabel = [NSTextField labelWithString:[loc translate:@"Find:"]];
    filterLabel.translatesAutoresizingMaskIntoConstraints = NO;
    filterLabel.font = [NSFont systemFontOfSize:11];
    [_filterBar addSubview:filterLabel];

    _filterField = [[NSTextField alloc] init];
    _filterField.translatesAutoresizingMaskIntoConstraints = NO;
    _filterField.font = [NSFont systemFontOfSize:11];
    _filterField.placeholderString = [loc translate:@"Type to search\u2026"];
    _filterField.delegate = (id)self;
    [_filterBar addSubview:_filterField];

    _filterMatchCase = [NSButton checkboxWithTitle:[loc translate:@"Match case"] target:nil action:nil];
    _filterMatchCase.translatesAutoresizingMaskIntoConstraints = NO;
    _filterMatchCase.font = [NSFont systemFontOfSize:11];
    _filterMatchCase.target = self;
    _filterMatchCase.action = @selector(_filterChanged:);
    [_filterBar addSubview:_filterMatchCase];

    _filterWholeWord = [NSButton checkboxWithTitle:[loc translate:@"Whole word"] target:nil action:nil];
    _filterWholeWord.translatesAutoresizingMaskIntoConstraints = NO;
    _filterWholeWord.font = [NSFont systemFontOfSize:11];
    _filterWholeWord.target = self;
    _filterWholeWord.action = @selector(_filterChanged:);
    [_filterBar addSubview:_filterWholeWord];

    _filterStatusLabel = [NSTextField labelWithString:@""];
    _filterStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _filterStatusLabel.font = [NSFont systemFontOfSize:11];
    _filterStatusLabel.textColor = [NSColor secondaryLabelColor];
    [_filterBar addSubview:_filterStatusLabel];

    NSButton *filterClose = [[NSButton alloc] init];
    filterClose.translatesAutoresizingMaskIntoConstraints = NO;
    filterClose.bezelStyle = NSBezelStyleSmallSquare;
    filterClose.bordered = NO;
    filterClose.title = @"\u2715";
    filterClose.font = [NSFont systemFontOfSize:10];
    filterClose.target = self;
    filterClose.action = @selector(_closeFilterBar:);
    [filterClose.widthAnchor constraintEqualToConstant:18].active = YES;
    [filterClose.heightAnchor constraintEqualToConstant:18].active = YES;
    [_filterBar addSubview:filterClose];

    [NSLayoutConstraint activateConstraints:@[
        [filterLabel.leadingAnchor constraintEqualToAnchor:_filterBar.leadingAnchor constant:6],
        [filterLabel.centerYAnchor constraintEqualToAnchor:_filterBar.centerYAnchor],
        [_filterField.leadingAnchor constraintEqualToAnchor:filterLabel.trailingAnchor constant:4],
        [_filterField.centerYAnchor constraintEqualToAnchor:_filterBar.centerYAnchor],
        [_filterField.widthAnchor constraintGreaterThanOrEqualToConstant:150],
        [_filterMatchCase.leadingAnchor constraintEqualToAnchor:_filterField.trailingAnchor constant:8],
        [_filterMatchCase.centerYAnchor constraintEqualToAnchor:_filterBar.centerYAnchor],
        [_filterWholeWord.leadingAnchor constraintEqualToAnchor:_filterMatchCase.trailingAnchor constant:8],
        [_filterWholeWord.centerYAnchor constraintEqualToAnchor:_filterBar.centerYAnchor],
        [_filterStatusLabel.leadingAnchor constraintEqualToAnchor:_filterWholeWord.trailingAnchor constant:8],
        [_filterStatusLabel.centerYAnchor constraintEqualToAnchor:_filterBar.centerYAnchor],
        [_filterStatusLabel.widthAnchor constraintGreaterThanOrEqualToConstant:60],
        [filterClose.trailingAnchor constraintEqualToAnchor:_filterBar.trailingAnchor constant:-4],
        [filterClose.centerYAnchor constraintEqualToAnchor:_filterBar.centerYAnchor],
    ]];

    NSBox *sep2 = [[NSBox alloc] init];
    sep2.boxType = NSBoxSeparator;
    sep2.translatesAutoresizingMaskIntoConstraints = NO;

    // ── Layout ───────────────────────────────────────────────────────────
    [self addSubview:titleBar];
    [self addSubview:sep];
    [self addSubview:_sci];
    [self addSubview:sep2];
    [self addSubview:_filterBar];

    _filterBarHeight = [_filterBar.heightAnchor constraintEqualToConstant:0];
    _filterBar.hidden = YES;
    sep2.hidden = YES;
    _filterSep = sep2;

    [NSLayoutConstraint activateConstraints:@[
        [titleBar.topAnchor      constraintEqualToAnchor:self.topAnchor],
        [titleBar.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [titleBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [sep.topAnchor           constraintEqualToAnchor:titleBar.bottomAnchor],
        [sep.leadingAnchor       constraintEqualToAnchor:self.leadingAnchor],
        [sep.trailingAnchor      constraintEqualToAnchor:self.trailingAnchor],
        [sep.heightAnchor        constraintEqualToConstant:1],
        [_sci.topAnchor          constraintEqualToAnchor:sep.bottomAnchor],
        [_sci.leadingAnchor      constraintEqualToAnchor:self.leadingAnchor],
        [_sci.trailingAnchor     constraintEqualToAnchor:self.trailingAnchor],
        [_sci.bottomAnchor       constraintEqualToAnchor:sep2.topAnchor],
        [sep2.leadingAnchor      constraintEqualToAnchor:self.leadingAnchor],
        [sep2.trailingAnchor     constraintEqualToAnchor:self.trailingAnchor],
        [sep2.heightAnchor       constraintEqualToConstant:1],
        [_filterBar.topAnchor    constraintEqualToAnchor:sep2.bottomAnchor],
        [_filterBar.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_filterBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_filterBar.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
        _filterBarHeight,
    ]];
}

#pragma mark - Theme

/// Convert NSColor to Scintilla BGR integer.
static sptr_t _srSciColor(NSColor *c) {
    c = [c colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
    if (!c) return 0;
    long r = (long)([c redComponent]   * 255);
    long g = (long)([c greenComponent] * 255);
    long b = (long)([c blueComponent]  * 255);
    return (b << 16) | (g << 8) | r;
}

- (void)_applyTheme {
    BOOL dark = [NppThemeManager shared].isDark;
    NPPStyleStore *store = [NPPStyleStore sharedStore];
    NSAppearance *panelAppearance = [NSAppearance appearanceNamed:
        dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];

    // Background & foreground from editor theme
    NSColor *bgColor = [store globalBg];
    NSColor *fgColor = [store globalFg];
    sptr_t bg = _srSciColor(bgColor);
    sptr_t fg = _srSciColor(fgColor);
    CGFloat bgBrightness = bgColor.brightnessComponent;

    [_sci message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:bg];
    [_sci message:SCI_STYLESETFORE wParam:STYLE_DEFAULT lParam:fg];
    [_sci message:SCI_STYLECLEARALL];

    // Search header: purple-ish bg #bebefc, dark blue fg #01057e
    [_sci message:SCI_STYLESETFORE  wParam:SCE_SEARCHRESULT_SEARCH_HEADER lParam:(dark ? 0xFCBEBE : 0x7E0501)];
    [_sci message:SCI_STYLESETBACK  wParam:SCE_SEARCHRESULT_SEARCH_HEADER lParam:(dark ? 0x3A3A50 : 0xFCBEBE)];
    [_sci message:SCI_STYLESETBOLD  wParam:SCE_SEARCHRESULT_SEARCH_HEADER lParam:1];

    // File header: green bg #d0f0d0, green fg #007000
    [_sci message:SCI_STYLESETFORE  wParam:SCE_SEARCHRESULT_FILE_HEADER lParam:(dark ? 0x80FF80 : 0x007000)];
    [_sci message:SCI_STYLESETBACK  wParam:SCE_SEARCHRESULT_FILE_HEADER lParam:(dark ? 0x2E4A2E : 0xD0F0D0)];
    [_sci message:SCI_STYLESETBOLD  wParam:SCE_SEARCHRESULT_FILE_HEADER lParam:1];

    // Line number: green
    [_sci message:SCI_STYLESETFORE  wParam:SCE_SEARCHRESULT_LINE_NUMBER lParam:(dark ? 0x808080 : 0x008000)];
    [_sci message:SCI_STYLESETBACK  wParam:SCE_SEARCHRESULT_LINE_NUMBER lParam:bg];

    // Matched text: red fg #ff0b05, yellow bg #ffffbf
    [_sci message:SCI_STYLESETFORE  wParam:SCE_SEARCHRESULT_WORD2SEARCH lParam:(dark ? 0x00AAFF : 0x050BFF)];
    [_sci message:SCI_STYLESETBACK  wParam:SCE_SEARCHRESULT_WORD2SEARCH lParam:(dark ? 0x404000 : 0xBFFFFF)];
    [_sci message:SCI_STYLESETBOLD  wParam:SCE_SEARCHRESULT_WORD2SEARCH lParam:1];

    // Default text
    [_sci message:SCI_STYLESETFORE  wParam:SCE_SEARCHRESULT_DEFAULT lParam:fg];
    [_sci message:SCI_STYLESETBACK  wParam:SCE_SEARCHRESULT_DEFAULT lParam:bg];

    // Current line highlight
    sptr_t caretBg = dark ? 0x404040 : 0xE8E8E8;
    [_sci message:SCI_STYLESETBACK  wParam:SCE_SEARCHRESULT_CURRENT_LINE lParam:caretBg];
    [_sci message:SCI_SETCARETLINEBACK wParam:caretBg];

    // EOL-filled for headers
    [_sci message:SCI_STYLESETEOLFILLED wParam:SCE_SEARCHRESULT_FILE_HEADER lParam:1];
    [_sci message:SCI_STYLESETEOLFILLED wParam:SCE_SEARCHRESULT_SEARCH_HEADER lParam:1];

    // ── Fold markers: match editor theme ─────────────────────────────────
    // Fold margin background
    NPPStyleEntry *gsFoldMargin = [store globalStyleNamed:@"Fold margin"];
    sptr_t foldMarginBGR;
    if (gsFoldMargin && gsFoldMargin.bgColor) {
        foldMarginBGR = _srSciColor(gsFoldMargin.bgColor);
    } else {
        foldMarginBGR = dark ? 0x2D2D2D : 0xF2F2F2;
    }
    [_sci message:SCI_SETFOLDMARGINCOLOUR   wParam:1 lParam:foldMarginBGR];
    [_sci message:SCI_SETFOLDMARGINHICOLOUR wParam:1 lParam:foldMarginBGR];

    // Fold marker fore/back colors from "Fold" global style
    NPPStyleEntry *gsFold = [store globalStyleNamed:@"Fold"];
    NSColor *foldFore = gsFold.fgColor ?: (bgBrightness > 0.5 ? [NSColor blackColor]
                                                                : [NSColor colorWithWhite:0.80 alpha:1.0]);
    NSColor *foldBack = gsFold.bgColor ?: (bgBrightness > 0.5 ? [NSColor colorWithWhite:0.82 alpha:1.0]
                                                                : [NSColor colorWithWhite:bgBrightness + 0.22 alpha:1.0]);
    for (int mn = SC_MARKNUM_FOLDEREND; mn <= SC_MARKNUM_FOLDEROPEN; mn++) {
        [_sci message:SCI_MARKERSETFORE wParam:mn lParam:_srSciColor(foldFore)];
        [_sci message:SCI_MARKERSETBACK wParam:mn lParam:_srSciColor(foldBack)];
    }

    // ── Title bar and filter bar background ─────────────────────────────
    // Use a concrete color here, not a dynamic NSColor bridged to CGColor:
    // layer colors are resolved at assignment time and can otherwise pick up
    // the system appearance instead of Nextpad++'s forced light/dark mode.
    NSColor *panelBg = [NppThemeManager shared].statusBarBackground;
    _titleBar.layer.backgroundColor = panelBg.CGColor;
    _filterBar.layer.backgroundColor = panelBg.CGColor;
    self.appearance = panelAppearance;
    _titleBar.appearance = panelAppearance;
    _filterBar.appearance = panelAppearance;
    _filterField.appearance = panelAppearance;

    // ── Appearance for dark/light disclosure triangles ────────────────────
    _sci.appearance = panelAppearance;

    // Re-colourise if we have content
    if ([_sci message:SCI_GETLENGTH] > 0)
        [_sci message:SCI_COLOURISE wParam:0 lParam:-1];
}

- (void)_themeChanged:(NSNotification *)n {
    [self _applyTheme];
}

- (void)_darkModeChanged:(NSNotification *)n {
    [self _applyTheme];
}

#pragma mark - Scintilla notifications

// ScintillaNotificationProtocol
- (void)notification:(SCNotification *)scn {
    if (scn->nmhdr.code == SCN_DOUBLECLICK) {
        sptr_t line = [_sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)scn->position];
        [self _navigateToResultLine:line];
    }
}

- (void)_navigateToResultLine:(sptr_t)lineIdx {
    if (lineIdx < 0 || (size_t)lineIdx >= _lineInfos.size()) return;

    const _SRLineInfo &info = _lineInfos[lineIdx];
    if (info.lineNumber <= 0) return; // header line — don't navigate

    NSString *path = [NSString stringWithUTF8String:info.filePath.c_str()];
    [_delegate searchResultsPanel:self navigateToFile:path atLine:info.lineNumber
                        matchText:@"" matchCase:NO];
}

- (void)_closePanel:(id)sender {
    [_delegate searchResultsPanel:self navigateToFile:@"" atLine:0 matchText:@"" matchCase:NO];
    // Notify delegate to collapse the panel — we use a special "close" signal
    if ([_delegate respondsToSelector:@selector(searchResultsPanelDidRequestClose:)])
        [(id)_delegate searchResultsPanelDidRequestClose:self];
}

#pragma mark - Public API

- (void)addResults:(NSArray<NPPFileResults *> *)fileResults
     forSearchText:(NSString *)searchText
           options:(NPPFindOptions *)opts
      filesSearched:(NSInteger)filesSearched {
    if (!fileResults.count) return;

    // Purge previous results if enabled
    if (_purgeBeforeSearch) [self clearAll];

    [_sci message:SCI_SETREADONLY wParam:0];

    // Count total hits (a line can hold several)
    NSInteger totalHits = 0;
    for (NPPFileResults *fr in fileResults)
        totalHits += fr.hitCount;

    // Search mode label
    NSString *modeLabel = @"Normal";
    if (opts.searchType == NPPSearchExtended) modeLabel = @"Extended";
    else if (opts.searchType == NPPSearchRegex) modeLabel = @"Regex";

    NSMutableString *optLabel = [NSMutableString string];
    if (opts.matchCase) [optLabel appendString:@"Case"];
    if (opts.wholeWord) {
        if (optLabel.length) [optLabel appendString:@"/"];
        [optLabel appendString:@"Word"];
    }

    NSString *suffix = @"";
    if (optLabel.length) suffix = [NSString stringWithFormat:@" [%@: %@]", modeLabel, optLabel];
    else suffix = [NSString stringWithFormat:@" [%@]", modeLabel];

    // Timestamp (date + time to the second) appended at the end of the
    // search-header line. The lexer classifies a line solely by its first
    // character, so trailing content is safe.
    static NSDateFormatter *tsFormatter;
    static dispatch_once_t tsOnce;
    dispatch_once(&tsOnce, ^{
        tsFormatter = [[NSDateFormatter alloc] init];
        // Fixed locale so the 12-hour clock and the AM/PM marker are
        // deterministic regardless of the user's region settings.
        tsFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        tsFormatter.dateFormat = @"yyyy-MM-dd hh:mm:ss a";
    });
    // Lowercase so the marker reads "am" / "pm".
    NSString *timestamp = [[tsFormatter stringFromDate:[NSDate date]] lowercaseString];

    // Search header
    NSString *header = [NSString stringWithFormat:@"Search \"%@\" (%ld hit%@ in %ld file%@ of %ld searched)%@  %@\n",
        searchText,
        (long)totalHits, totalHits == 1 ? @"" : @"s",
        (long)fileResults.count, fileResults.count == 1 ? @"" : @"s",
        (long)filesSearched,
        suffix,
        timestamp];

    sptr_t startPos = [_sci message:SCI_GETLENGTH];
    // SCI_APPENDTEXT wParam is the UTF-8 BYTE count, not the NSString character
    // count. For non-ASCII content these differ (Punjabi/Cyrillic/CJK etc.), and
    // passing .length truncates the buffer mid-byte — Scintilla drops the
    // trailing newline, the next APPENDTEXT concatenates inline, and the
    // results view looks "scrambled" (issue #46). lengthOfBytesUsingEncoding:
    // returns the exact UTF-8 byte count and is correct for any string.
    [_sci message:SCI_APPENDTEXT
                 wParam:[header lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
                 lParam:(sptr_t)header.UTF8String];

    // Add line info for search header
    _SRLineInfo headerInfo = {};
    headerInfo.lineNumber = 0;
    _lineInfos.push_back(headerInfo);

    // Empty marking for header line
    SearchResultMarkingLine emptyMarking = {};
    _markingLines.push_back(emptyMarking);

    for (NPPFileResults *fileRes in fileResults) {
        // File header
        const NSInteger fileHits = fileRes.hitCount;
        NSString *fileHeader = [NSString stringWithFormat:@" %@ (%ld hit%@)\n",
            fileRes.filePath,
            (long)fileHits,
            fileHits == 1 ? @"" : @"s"];
        // wParam = UTF-8 byte count, not character count — see issue #46 note above.
        [_sci message:SCI_APPENDTEXT
                     wParam:[fileHeader lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
                     lParam:(sptr_t)fileHeader.UTF8String];

        _SRLineInfo fileInfo = {};
        fileInfo.filePath = fileRes.filePath.UTF8String ?: "";
        fileInfo.lineNumber = 0;
        _lineInfos.push_back(fileInfo);
        _markingLines.push_back(SearchResultMarkingLine{});

        for (NPPSearchResult *r in fileRes.results) {
            // Result line: \tLine NNNN: text\n
            NSString *linePrefix = [NSString stringWithFormat:@"\tLine %6ld: ", (long)r.lineNumber];
            NSString *resultLine = [NSString stringWithFormat:@"%@%@\n", linePrefix, r.lineText];

            // Calculate marking position for highlighted match
            const char *prefixUTF8 = linePrefix.UTF8String;
            size_t prefixBytes = strlen(prefixUTF8);

            // One highlighted segment per hit on the line (as Notepad++ lists a
            // line once, with all its hits). Ranges are UTF-16 offsets into
            // lineText; the lexer wants UTF-8 byte offsets into the result line.
            // Hits come left to right, so convert incrementally.
            SearchResultMarkingLine marking = {};
            const NSUInteger textLength = r.lineText.length;
            NSUInteger convertedUnits = 0;
            size_t convertedBytes = 0;
            auto bytesUpTo = [&](NSUInteger units) -> size_t {
                units = MIN(units, textLength);
                if (units < convertedUnits) { convertedUnits = 0; convertedBytes = 0; }
                convertedBytes += [[r.lineText substringWithRange:NSMakeRange(convertedUnits, units - convertedUnits)]
                                     lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                convertedUnits = units;
                return convertedBytes;
            };
            NSArray<NSValue *> *ranges = r.matchRanges;
            if (!ranges.count)
                ranges = @[[NSValue valueWithRange:NSMakeRange((NSUInteger)r.matchStart, (NSUInteger)r.matchLength)]];
            for (NSValue *v in ranges) {
                const NSRange range = v.rangeValue;
                const size_t matchByteStart = bytesUpTo(range.location);
                const size_t matchByteEnd   = bytesUpTo(range.location + range.length);
                if (matchByteEnd <= matchByteStart) continue;   // empty match: nothing to colour
                // LexSearchResult: ColourTo(startLine + mi.first - 1, DEFAULT) then
                // ColourTo(startLine + mi.second - 1, WORD2SEARCH).
                // So mi.first = offset of first highlighted byte (0-based within line buffer)
                // and mi.second = offset of last highlighted byte + 1
                intptr_t segStart = (intptr_t)(prefixBytes + matchByteStart);
                intptr_t segEnd   = (intptr_t)(prefixBytes + matchByteEnd);
                marking._segmentPostions.push_back(std::make_pair(segStart, segEnd));
            }
            _markingLines.push_back(marking);

            // wParam = UTF-8 byte count, not character count — see issue #46 note above.
            [_sci message:SCI_APPENDTEXT
                         wParam:[resultLine lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
                         lParam:(sptr_t)resultLine.UTF8String];

            _SRLineInfo lineInfo = {};
            lineInfo.filePath = r.filePath.UTF8String ?: "";
            lineInfo.lineNumber = (int)r.lineNumber;
            _lineInfos.push_back(lineInfo);
        }
    }

    // Update markings struct pointer for lexer
    _markingsStruct._length   = (intptr_t)_markingLines.size();
    _markingsStruct._markings = _markingLines.data();

    // Pass pointer to lexer
    char ptrStr[64];
    snprintf(ptrStr, sizeof(ptrStr), "%p", &_markingsStruct);
    [_sci message:SCI_SETPROPERTY wParam:(uptr_t)"@MarkingsStruct" lParam:(sptr_t)ptrStr];

    [_sci message:SCI_SETREADONLY wParam:1];

    // Trigger re-colourise
    [_sci message:SCI_COLOURISE wParam:0 lParam:-1];

    // Scroll to show the new results
    sptr_t lastLine = [_sci message:SCI_GETLINECOUNT] - 1;
    sptr_t firstNewLine = [_sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)startPos];
    [_sci message:SCI_GOTOLINE wParam:(uptr_t)firstNewLine];

    // Expand all folds in new results
    for (sptr_t line = firstNewLine; line <= lastLine; line++) {
        sptr_t level = [_sci message:SCI_GETFOLDLEVEL wParam:(uptr_t)line];
        if (level & SC_FOLDLEVELHEADERFLAG) {
            if (!([_sci message:SCI_GETFOLDEXPANDED wParam:(uptr_t)line]))
                [_sci message:SCI_TOGGLEFOLD wParam:(uptr_t)line];
        }
    }
}

- (void)clearAll {
    [_sci message:SCI_SETREADONLY wParam:0];
    [_sci message:SCI_CLEARALL];
    [_sci message:SCI_SETREADONLY wParam:1];
    _lineInfos.clear();
    _markingLines.clear();
    _markingsStruct._length = 0;
    _markingsStruct._markings = nullptr;
}

/// Select an entire line in the search results panel so it stays highlighted.
- (void)_selectResultLine:(sptr_t)line {
    sptr_t lineStart = [_sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)line];
    sptr_t lineEnd   = [_sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)line];
    [_sci message:SCI_SETSEL wParam:(uptr_t)lineStart lParam:lineEnd];
    [_sci message:SCI_SCROLLCARET];
}

- (BOOL)navigateToNextResult {
    sptr_t currentLine = [_sci message:SCI_LINEFROMPOSITION
                                wParam:(uptr_t)[_sci message:SCI_GETCURRENTPOS]];
    sptr_t lineCount = [_sci message:SCI_GETLINECOUNT];

    for (sptr_t line = currentLine + 1; line < lineCount; line++) {
        if ((size_t)line < _lineInfos.size() && _lineInfos[line].lineNumber > 0) {
            [self _selectResultLine:line];
            [self _navigateToResultLine:line];
            return YES;
        }
    }
    // Wrap to beginning
    for (sptr_t line = 0; line <= currentLine && line < lineCount; line++) {
        if ((size_t)line < _lineInfos.size() && _lineInfos[line].lineNumber > 0) {
            [self _selectResultLine:line];
            [self _navigateToResultLine:line];
            return YES;
        }
    }
    return NO;
}

- (BOOL)navigateToPreviousResult {
    sptr_t currentLine = [_sci message:SCI_LINEFROMPOSITION
                                wParam:(uptr_t)[_sci message:SCI_GETCURRENTPOS]];
    sptr_t lineCount = [_sci message:SCI_GETLINECOUNT];

    for (sptr_t line = currentLine - 1; line >= 0; line--) {
        if ((size_t)line < _lineInfos.size() && _lineInfos[line].lineNumber > 0) {
            [self _selectResultLine:line];
            [self _navigateToResultLine:line];
            return YES;
        }
    }
    // Wrap to end
    for (sptr_t line = lineCount - 1; line > currentLine; line--) {
        if ((size_t)line < _lineInfos.size() && _lineInfos[line].lineNumber > 0) {
            [self _selectResultLine:line];
            [self _navigateToResultLine:line];
            return YES;
        }
    }
    return NO;
}

- (void)foldAll {
    sptr_t lineCount = [_sci message:SCI_GETLINECOUNT];
    for (sptr_t line = 0; line < lineCount; line++) {
        sptr_t level = [_sci message:SCI_GETFOLDLEVEL wParam:(uptr_t)line];
        if ((level & SC_FOLDLEVELHEADERFLAG) && [_sci message:SCI_GETFOLDEXPANDED wParam:(uptr_t)line])
            [_sci message:SCI_TOGGLEFOLD wParam:(uptr_t)line];
    }
}

- (void)unfoldAll {
    sptr_t lineCount = [_sci message:SCI_GETLINECOUNT];
    for (sptr_t line = 0; line < lineCount; line++) {
        sptr_t level = [_sci message:SCI_GETFOLDLEVEL wParam:(uptr_t)line];
        if ((level & SC_FOLDLEVELHEADERFLAG) && !([_sci message:SCI_GETFOLDEXPANDED wParam:(uptr_t)line]))
            [_sci message:SCI_TOGGLEFOLD wParam:(uptr_t)line];
    }
}

#pragma mark - Context menu

- (NSMenu *)_buildContextMenu {
    NSMenu *m = [[NSMenu alloc] init];
    m.delegate = (id)self;
    NppLocalizer *loc = [NppLocalizer shared];

    // 1. Find in these search results...
    [m addItemWithTitle:[loc translate:@"Find in these search results..."]
                 action:@selector(_findInResults:) keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];

    // 2-3. Fold/Unfold
    [m addItemWithTitle:[loc translate:@"Fold all"]   action:@selector(_foldAll:)   keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Unfold all"] action:@selector(_unfoldAll:) keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];

    // 4-8. Copy, Copy Lines, Copy Paths, Select all, Clear all
    [m addItemWithTitle:[loc translate:@"Copy"]                      action:@selector(_copy:)          keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Copy Selected Line(s)"]     action:@selector(_copyLines:)     keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Copy Selected Pathname(s)"] action:@selector(_copyPathnames:) keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Select all"]                action:@selector(_selectAll:)     keyEquivalent:@""];
    [m addItemWithTitle:[loc translate:@"Clear all"]                 action:@selector(_clearAll:)      keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];

    // 9. Open Selected Pathname(s)
    [m addItemWithTitle:[loc translate:@"Open Selected Pathname(s)"] action:@selector(_openPathnames:) keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];

    // 10-11. Toggles
    NSMenuItem *wrapItem = [[NSMenuItem alloc] initWithTitle:[loc translate:@"Word wrap long lines"]
                                                     action:@selector(_toggleWordWrap:) keyEquivalent:@""];
    wrapItem.tag = 1001;
    [m addItem:wrapItem];

    NSMenuItem *purgeItem = [[NSMenuItem alloc] initWithTitle:[loc translate:@"Purge for every search"]
                                                      action:@selector(_togglePurge:) keyEquivalent:@""];
    purgeItem.tag = 1002;
    [m addItem:purgeItem];

    for (NSMenuItem *mi in m.itemArray) {
        if (!mi.isSeparatorItem) mi.target = self;
    }
    return m;
}

// Update checkmarks before menu is shown
- (void)menuNeedsUpdate:(NSMenu *)menu {
    for (NSMenuItem *mi in menu.itemArray) {
        if (mi.tag == 1001) mi.state = _wordWrapEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        if (mi.tag == 1002) mi.state = _purgeBeforeSearch ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

#pragma mark - Context menu actions

/// Get text of a single line, or nil if line is hidden or empty.
- (NSString *)_visibleLineText:(sptr_t)line {
    if (![_sci message:SCI_GETLINEVISIBLE wParam:(uptr_t)line]) return nil;
    sptr_t linePos = [_sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)line];
    sptr_t lineEndPos = [_sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)line];
    sptr_t len = lineEndPos - linePos;
    if (len <= 0) return nil;
    char *buf = (char *)calloc(len + 1, 1);
    struct Sci_TextRangeFull tr = {};
    tr.chrg.cpMin = linePos;
    tr.chrg.cpMax = lineEndPos;
    tr.lpstrText = buf;
    [_sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&tr];
    NSString *text = [NSString stringWithUTF8String:buf] ?: @"";
    free(buf);
    return text;
}

- (void)_copy:(id)sender {
    // Copy only visible lines in selection
    sptr_t selStart = [_sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [_sci message:SCI_GETSELECTIONEND];
    sptr_t lineStart = [_sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selStart];
    sptr_t lineEnd   = [_sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selEnd];

    NSMutableString *result = [NSMutableString string];
    for (sptr_t line = lineStart; line <= lineEnd; line++) {
        NSString *text = [self _visibleLineText:line];
        if (text) [result appendFormat:@"%@\n", text];
    }
    if (result.length > 0) {
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:result forType:NSPasteboardTypeString];
    }
}

- (void)_selectAll:(id)sender { [_sci message:SCI_SELECTALL]; }

- (void)_clearAll:(id)sender { [self clearAll]; }

- (void)_foldAll:(id)sender { [self foldAll]; }

- (void)_unfoldAll:(id)sender { [self unfoldAll]; }

- (void)_copyLines:(id)sender {
    // Copy only visible result lines WITH line numbers (exactly as shown)
    sptr_t selStart = [_sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [_sci message:SCI_GETSELECTIONEND];
    sptr_t lineStart = [_sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selStart];
    sptr_t lineEnd   = [_sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selEnd];

    NSMutableString *result = [NSMutableString string];
    for (sptr_t line = lineStart; line <= lineEnd; line++) {
        NSString *lineText = [self _visibleLineText:line];
        if (!lineText) continue;

        // Include result lines (tab-prefixed) with their line numbers
        if ([lineText hasPrefix:@"\t"]) {
            // Remove leading tab, keep "Line NNN: content"
            [result appendFormat:@"%@\n", [lineText substringFromIndex:1]];
        }
    }

    if (result.length > 0) {
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:result forType:NSPasteboardTypeString];
    }
}

- (void)_copyPathnames:(id)sender {
    NSArray<NSString *> *paths = [self _selectedPathnames];
    if (paths.count == 0) return;
    NSString *joined = [paths componentsJoinedByString:@"\n"];
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:joined forType:NSPasteboardTypeString];
}

- (void)_openPathnames:(id)sender {
    NSArray<NSString *> *paths = [self _selectedPathnames];
    for (NSString *path in paths) {
        [_delegate searchResultsPanel:self navigateToFile:path atLine:1 matchText:@"" matchCase:NO];
    }
}

- (void)_toggleWordWrap:(id)sender {
    _wordWrapEnabled = !_wordWrapEnabled;
    [_sci message:SCI_SETWRAPMODE wParam:_wordWrapEnabled ? SC_WRAP_WORD : SC_WRAP_NONE];
    [[NSUserDefaults standardUserDefaults] setBool:_wordWrapEnabled forKey:@"SearchResultsWordWrap"];
}

- (void)_togglePurge:(id)sender {
    _purgeBeforeSearch = !_purgeBeforeSearch;
    [[NSUserDefaults standardUserDefaults] setBool:_purgeBeforeSearch forKey:@"SearchResultsPurge"];
}

- (void)_findInResults:(id)sender {
    // Show the filter bar
    _filterBarHeight.constant = 30;
    _filterBar.hidden = NO;
    _filterSep.hidden = NO;
    [self.window makeFirstResponder:_filterField];
}

- (void)_closeFilterBar:(id)sender {
    _filterBarHeight.constant = 0;
    _filterBar.hidden = YES;
    _filterSep.hidden = YES;
    _filterField.stringValue = @"";
    _filterStatusLabel.stringValue = @"";
    // Unhide all lines
    [self _showAllLines];
}

- (void)_filterChanged:(id)sender {
    [self _applyFilter];
}

// NSTextFieldDelegate — live filtering as user types
- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object == _filterField) {
        [self _applyFilter];
    }
}

// Handle Escape key in filter field
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    if (control == _filterField && commandSelector == @selector(cancelOperation:)) {
        [self _closeFilterBar:nil];
        return YES;
    }
    return NO;
}

- (void)_applyFilter {
    NSString *filter = _filterField.stringValue;
    if (!filter.length) {
        [self _showAllLines];
        _filterStatusLabel.stringValue = @"";
        return;
    }

    BOOL matchCase = (_filterMatchCase.state == NSControlStateValueOn);
    BOOL wholeWord = (_filterWholeWord.state == NSControlStateValueOn);
    NSStringCompareOptions cmpOpts = matchCase ? 0 : NSCaseInsensitiveSearch;

    sptr_t lineCount = [_sci message:SCI_GETLINECOUNT];
    NSInteger matchCount = 0;

    // First pass: determine which result lines match
    // Track which file headers have matching children
    NSMutableIndexSet *matchingLines = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *fileHeadersWithMatches = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *searchHeaders = [NSMutableIndexSet indexSet];

    sptr_t currentFileHeader = -1;

    for (sptr_t line = 0; line < lineCount; line++) {
        sptr_t linePos = [_sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)line];
        sptr_t lineEndPos = [_sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)line];
        sptr_t len = lineEndPos - linePos;
        if (len <= 0) continue;

        char firstChar = (char)[_sci message:SCI_GETCHARAT wParam:(uptr_t)linePos];

        if (firstChar != '\t' && firstChar != ' ') {
            // Search header — always visible
            [searchHeaders addIndex:(NSUInteger)line];
            [matchingLines addIndex:(NSUInteger)line];
            continue;
        }

        if (firstChar == ' ') {
            // File header — remember it, show later if children match
            currentFileHeader = line;
            continue;
        }

        // Result line (tab-prefixed) — check if it matches filter
        char *buf = (char *)calloc(len + 1, 1);
        struct Sci_TextRangeFull tr = {};
        tr.chrg.cpMin = linePos;
        tr.chrg.cpMax = lineEndPos;
        tr.lpstrText = buf;
        [_sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&tr];
        NSString *lineText = [NSString stringWithUTF8String:buf] ?: @"";
        free(buf);

        NSRange matchRange = [lineText rangeOfString:filter options:cmpOpts];
        BOOL matched = (matchRange.location != NSNotFound);

        // Whole word check
        if (matched && wholeWord) {
            NSCharacterSet *wordChars = [NSCharacterSet alphanumericCharacterSet];
            if (matchRange.location > 0) {
                unichar c = [lineText characterAtIndex:matchRange.location - 1];
                if ([wordChars characterIsMember:c] || c == '_') matched = NO;
            }
            NSUInteger endPos = matchRange.location + matchRange.length;
            if (matched && endPos < lineText.length) {
                unichar c = [lineText characterAtIndex:endPos];
                if ([wordChars characterIsMember:c] || c == '_') matched = NO;
            }
        }

        if (matched) {
            [matchingLines addIndex:(NSUInteger)line];
            matchCount++;
            if (currentFileHeader >= 0) {
                [fileHeadersWithMatches addIndex:(NSUInteger)currentFileHeader];
            }
        }
    }

    // Add file headers that have matching children
    [matchingLines addIndexes:fileHeadersWithMatches];

    // Second pass: show/hide lines
    [_sci message:SCI_SETREADONLY wParam:0];
    for (sptr_t line = 0; line < lineCount; line++) {
        if ([matchingLines containsIndex:(NSUInteger)line]) {
            [_sci message:SCI_SHOWLINES wParam:(uptr_t)line lParam:(uptr_t)line];
        } else {
            [_sci message:SCI_HIDELINES wParam:(uptr_t)line lParam:(uptr_t)line];
        }
    }
    [_sci message:SCI_SETREADONLY wParam:1];

    // Update status
    if (matchCount > 0) {
        _filterStatusLabel.stringValue = [NSString stringWithFormat:@"%ld match%@",
            (long)matchCount, matchCount == 1 ? @"" : @"es"];
        _filterStatusLabel.textColor = [NSColor secondaryLabelColor];
    } else {
        _filterStatusLabel.stringValue = [[NppLocalizer shared] translate:@"Not found"];
        _filterStatusLabel.textColor = [NSColor systemRedColor];
    }
}

- (void)_showAllLines {
    sptr_t lineCount = [_sci message:SCI_GETLINECOUNT];
    [_sci message:SCI_SETREADONLY wParam:0];
    [_sci message:SCI_SHOWLINES wParam:0 lParam:(uptr_t)(lineCount - 1)];
    [_sci message:SCI_SETREADONLY wParam:1];
}

#pragma mark - Helpers

- (NSArray<NSString *> *)_selectedPathnames {
    sptr_t selStart = [_sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [_sci message:SCI_GETSELECTIONEND];
    sptr_t lineStart = [_sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selStart];
    sptr_t lineEnd   = [_sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selEnd];

    // If nothing selected, use all lines
    if (selStart == selEnd) {
        lineStart = 0;
        lineEnd = (sptr_t)_lineInfos.size() - 1;
    }

    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    for (sptr_t line = lineStart; line <= lineEnd; line++) {
        // Skip hidden lines
        if (![_sci message:SCI_GETLINEVISIBLE wParam:(uptr_t)line]) continue;
        if ((size_t)line < _lineInfos.size() && _lineInfos[line].filePath.length() > 0) {
            NSString *path = [NSString stringWithUTF8String:_lineInfos[line].filePath.c_str()];
            if (path.length && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
                [paths addObject:path];
            }
        }
    }
    return [paths array];
}

#pragma mark - Panel Zoom

- (void)panelZoomIn   { [_sci message:SCI_ZOOMIN]; [[NSUserDefaults standardUserDefaults] setInteger:[_sci message:SCI_GETZOOM] forKey:@"PanelZoom_SearchResults"]; }
- (void)panelZoomOut  { [_sci message:SCI_ZOOMOUT]; [[NSUserDefaults standardUserDefaults] setInteger:[_sci message:SCI_GETZOOM] forKey:@"PanelZoom_SearchResults"]; }
- (void)panelZoomReset { [_sci message:SCI_SETZOOM wParam:0]; [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:@"PanelZoom_SearchResults"]; }

@end
