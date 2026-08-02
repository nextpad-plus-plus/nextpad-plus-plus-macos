#import "FindWindow.h"
#import "EditorView.h"
#import "SearchResultsPanel.h"
#import "ProjectPanel.h"
#import "NppLocalizer.h"
#import "PreferencesWindowController.h"
#import <objc/runtime.h>

// ── History keys ─────────────────────────────────────────────────────────────

static NSString * const kHistoryFind    = @"FindWindow_FindHistory";
static NSString * const kHistoryReplace = @"FindWindow_ReplaceHistory";
static NSString * const kHistoryFilter  = @"FindWindow_FilterHistory";
static NSString * const kHistoryDir     = @"FindWindow_DirHistory";
static const NSInteger kMaxHistory = 20;

// Issue #143 — Find window transparency (Windows parity). The control lives in
// the Find/Replace tabs (see _buildTransparencyGroup:inView:). When enabled in
// "on losing focus" mode the window dims to kPrefFindTransparencyAlpha on
// resignKey and restores on becomeKey; in "always" mode it stays dimmed.
// kTransparencyMin/Max bound the slider.
static const CGFloat kTransparencyMin = 0.2;
static const CGFloat kTransparencyMax = 0.9;

// ── Layout constants (matching Windows NPP proportions) ──────────────────────

static const CGFloat kWinW      = 620;   // default window width
static const CGFloat kLeftM     = 30;    // left margin for checkboxes
static const CGFloat kLabelR    = 140;   // right edge of "Find what:" label
static const CGFloat kFieldL    = 145;   // left edge of combo boxes
static const CGFloat kFieldR    = 410;   // right edge of combo boxes (from left)
// Button width: computed in +initialize so "Find All in All Opened" fits on one line
// and "Documents" wraps to the next line.
static CGFloat kBtnW = 200;
static CGFloat kBtnL = 408;
static const CGFloat kBtnH      = 28;    // single-line button height
static const CGFloat kRowH      = 32;    // vertical spacing between rows
static const CGFloat kChkH      = 20;    // checkbox height

// ── FindWindow ───────────────────────────────────────────────────────────────

@implementation FindWindow {
    NSSegmentedControl *_tabControl;

    // 5 tab content views
    NSView *_views[5];

    // Per-tab controls — each tab owns its own instances to avoid re-parenting
    // Find what combo is shared (moved between tabs)
    NSComboBox *_findCombo;
    NSComboBox *_replaceCombo;
    NSComboBox *_filtersCombo;
    NSComboBox *_directoryCombo;

    // Options — per-tab instances (separate for Find/Replace vs FiF/FiP vs Mark)
    // Find & Replace tab options
    NSButton *_frBackward, *_frWholeWord, *_frMatchCase, *_frWrapAround;
    NSButton *_frInSelection;
    // Find in Files tab options
    NSButton *_fifWholeWord, *_fifMatchCase;
    NSButton *_fifInSubFolders, *_fifInHiddenFolders;
    // Find in Projects tab options
    NSButton *_fipWholeWord, *_fipMatchCase;
    NSButton *_fipPanel1, *_fipPanel2, *_fipPanel3;
    // Mark tab options
    NSButton *_mkBookmarkLine, *_mkPurge, *_mkBackward;
    NSButton *_mkWholeWord, *_mkMatchCase, *_mkWrapAround;
    NSButton *_mkInSelection;

    // Search mode — per-tab instances (Find, Replace, FiF, FiP, Mark)
    NSButton *_smNormal[5], *_smExtended[5], *_smRegex[5], *_smDotNL[5];

    // Status bar
    NSTextField *_statusLabel;

    FindWindowTab _currentTab;
    BOOL _cancelSearch;

    // Issue #143 — Transparency controls, one set per tab (indices match
    // FindWindowTab: 0=Find 1=Replace 2=FiF 3=FiP 4=Mark). Kept in sync via
    // _syncTransparencyControls.
    NSButton *_trEnable[5];
    NSButton *_trLosingFocus[5];
    NSButton *_trAlways[5];
    NSSlider *_trSlider[5];
}

static FindWindow *_sharedInstance = nil;

+ (void)initialize {
    if (self != [FindWindow class]) return;
    NSFont *font = [NSFont systemFontOfSize:12];
    NSString *longestPrefix = @"Replace All in All Opened";
    NSSize sz = [longestPrefix sizeWithAttributes:@{NSFontAttributeName: font}];
    kBtnW = ceil(sz.width) + 30;
    kBtnL = kWinW - kBtnW - 12;
}

+ (instancetype)sharedWindow {
    if (!_sharedInstance) _sharedInstance = [[FindWindow alloc] init];
    return _sharedInstance;
}

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, kWinW, 355)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered defer:NO];
    win.title = [[NppLocalizer shared] translate:@"Find"];
    // Issue #120 — let Tab / Shift+Tab cycle the form controls. AppKit
    // builds and maintains the key-view loop automatically, including
    // across tab switches that re-parent the shared combo boxes.
    win.autorecalculatesKeyViewLoop = YES;
    // Issue #143 — float above the editor so clicking into the document
    // doesn't bury the Find window (which made "dim on losing focus"
    // pointless). hidesOnDeactivate keeps it from hovering over other apps
    // when Nextpad++ isn't frontmost — it reappears when we return.
    win.level = NSFloatingWindowLevel;
    win.hidesOnDeactivate = YES;
    [win center];

    self = [super initWithWindow:win];
    if (self) {
        // Issue #143 — we observe windowDidBecomeKey:/windowDidResignKey: to
        // drive the transparency setting. Set after super init so the window is
        // fully owned by self.
        win.delegate = self;

        _currentTab = FindWindowTabFind;
        [self _buildAllTabs];
        [self _restoreHistory];
        [self _switchToTab:FindWindowTabFind];
    }
    return self;
}

#pragma mark - Public

- (void)showTab:(FindWindowTab)tab {
    _currentTab = tab;
    _tabControl.selectedSegment = tab;
    [self _switchToTab:tab];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:_findCombo];
    // Issue #143 — apply transparency for the just-shown window. In "always"
    // mode this dims immediately; in "on losing focus" the window is key here
    // so it stays opaque until focus leaves.
    [self _applyTransparency];
}

- (NSString *)searchText { return _findCombo.stringValue ?: @""; }

- (void)setSearchText:(NSString *)text {
    if (text.length) _findCombo.stringValue = text;
}

- (void)setDirectory:(NSString *)path {
    if (path.length) _directoryCombo.stringValue = path;
}

- (void)selectProjectPanel:(NSInteger)index {
    _fipPanel1.state = (index == 0) ? NSControlStateValueOn : NSControlStateValueOff;
    _fipPanel2.state = (index == 1) ? NSControlStateValueOn : NSControlStateValueOff;
    _fipPanel3.state = (index == 2) ? NSControlStateValueOn : NSControlStateValueOff;
}

- (NPPFindOptions *)currentOptions {
    NPPFindOptions *o = [[NPPFindOptions alloc] init];
    o.searchText  = _findCombo.stringValue ?: @"";
    o.replaceText = _replaceCombo.stringValue ?: @"";

    // Read from active tab's controls
    NSInteger t = _currentTab;
    if (t == FindWindowTabFind) {
        o.matchCase  = (_frMatchCase.state == NSControlStateValueOn);
        o.wholeWord  = (_frWholeWord.state == NSControlStateValueOn);
        o.wrapAround = (_frWrapAround.state == NSControlStateValueOn);
        o.inSelection = (_frInSelection.state == NSControlStateValueOn);
        o.direction  = (_frBackward.state == NSControlStateValueOn) ? NPPSearchUp : NPPSearchDown;
        o.searchType = [self _searchModeFromGroup:0];
        o.dotMatchesNewline = (_smDotNL[0].state == NSControlStateValueOn);
    } else if (t == FindWindowTabReplace) {
        NSButton *mc = objc_getAssociatedObject(_views[1], "matchcase");
        NSButton *ww = objc_getAssociatedObject(_views[1], "wholeword");
        NSButton *wa = objc_getAssociatedObject(_views[1], "wraparound");
        NSButton *bk = objc_getAssociatedObject(_views[1], "backward");
        o.matchCase  = (mc.state == NSControlStateValueOn);
        o.wholeWord  = (ww.state == NSControlStateValueOn);
        o.wrapAround = (wa.state == NSControlStateValueOn);
        o.inSelection = (_frInSelection.state == NSControlStateValueOn);
        o.direction  = (bk.state == NSControlStateValueOn) ? NPPSearchUp : NPPSearchDown;
        o.searchType = [self _searchModeFromGroup:1];
        o.dotMatchesNewline = (_smDotNL[1].state == NSControlStateValueOn);
    } else if (t == FindWindowTabFindInFiles) {
        o.matchCase  = (_fifMatchCase.state == NSControlStateValueOn);
        o.wholeWord  = (_fifWholeWord.state == NSControlStateValueOn);
        o.wrapAround = YES;
        o.filters    = _filtersCombo.stringValue ?: @"*.*";
        o.directory  = _directoryCombo.stringValue ?: @"";
        o.isRecursive = (_fifInSubFolders.state == NSControlStateValueOn);
        o.isInHiddenDirs = (_fifInHiddenFolders.state == NSControlStateValueOn);
        o.searchType = [self _searchModeFromGroup:2];
        o.dotMatchesNewline = (_smDotNL[2].state == NSControlStateValueOn);
    } else if (t == FindWindowTabFindInProjects) {
        o.matchCase  = (_fipMatchCase.state == NSControlStateValueOn);
        o.wholeWord  = (_fipWholeWord.state == NSControlStateValueOn);
        o.wrapAround = YES;
        o.filters    = _filtersCombo.stringValue ?: @"*.*";
        o.projectPanel1 = (_fipPanel1.state == NSControlStateValueOn);
        o.projectPanel2 = (_fipPanel2.state == NSControlStateValueOn);
        o.projectPanel3 = (_fipPanel3.state == NSControlStateValueOn);
        o.searchType = [self _searchModeFromGroup:3];
        o.dotMatchesNewline = (_smDotNL[3].state == NSControlStateValueOn);
    } else if (t == FindWindowTabMark) {
        o.matchCase  = (_mkMatchCase.state == NSControlStateValueOn);
        o.wholeWord  = (_mkWholeWord.state == NSControlStateValueOn);
        o.wrapAround = (_mkWrapAround.state == NSControlStateValueOn);
        o.inSelection = (_mkInSelection.state == NSControlStateValueOn);
        o.direction  = (_mkBackward.state == NSControlStateValueOn) ? NPPSearchUp : NPPSearchDown;
        o.doBookmarkLine = (_mkBookmarkLine.state == NSControlStateValueOn);
        o.doPurge    = (_mkPurge.state == NSControlStateValueOn);
        o.searchType = [self _searchModeFromGroup:4];
        o.dotMatchesNewline = (_smDotNL[4].state == NSControlStateValueOn);
    }
    return o;
}

- (NPPSearchType)_searchModeFromGroup:(int)g {
    if (_smRegex[g].state == NSControlStateValueOn) return NPPSearchRegex;
    if (_smExtended[g].state == NSControlStateValueOn) return NPPSearchExtended;
    return NPPSearchNormal;
}

#pragma mark - Factory helpers

static NSComboBox *_mkCombo(void) {
    NSComboBox *c = [[NSComboBox alloc] init];
    c.translatesAutoresizingMaskIntoConstraints = NO;
    c.font = [NSFont systemFontOfSize:12];
    c.numberOfVisibleItems = 15;
    c.completes = NO;
    c.usesDataSource = NO;
    return c;
}

static NSButton *_mkChk(NSString *title) {
    NSButton *b = [NSButton checkboxWithTitle:title target:nil action:nil];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.font = [NSFont systemFontOfSize:12];
    return b;
}

static NSButton *_mkRadio(NSString *title) {
    NSButton *b = [NSButton radioButtonWithTitle:title target:nil action:nil];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.font = [NSFont systemFontOfSize:12];
    return b;
}

static NSButton *_mkBtn(NSString *title, SEL action, id target) {
    NSButton *b = [[NSButton alloc] init];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.title = title;
    b.bezelStyle = NSBezelStyleRounded;
    b.target = target;
    b.action = action;
    b.font = [NSFont systemFontOfSize:12];
    return b;
}

static NSTextField *_mkLabel(NSString *text) {
    NSTextField *l = [NSTextField labelWithString:text];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = [NSFont systemFontOfSize:12];
    l.alignment = NSTextAlignmentRight;
    return l;
}

/// Place a label + combo row. Returns the combo's top anchor Y for chaining.
static void _placeFieldRow(NSView *parent, NSTextField *label, NSComboBox *combo,
                           CGFloat topY, CGFloat labelRight, CGFloat fieldLeft, CGFloat fieldRight) {
    [parent addSubview:label];
    [parent addSubview:combo];
    label.frame  = NSMakeRect(labelRight - 100, topY + 2, 100, 18);
    combo.frame  = NSMakeRect(fieldLeft, topY, fieldRight - fieldLeft, 24);
}

/// Place a button in the right column (fixed frame, for tabs that don't need dynamic height).
static void _placeBtn(NSView *parent, NSButton *btn, CGFloat topY) {
    btn.translatesAutoresizingMaskIntoConstraints = YES;
    [parent addSubview:btn];
    btn.frame = NSMakeRect(kBtnL, topY, kBtnW, kBtnH);
}

/// Check if title text fits in one line at kBtnW. If not, find the natural
/// break point and insert a newline so NSButton renders it as two lines.
static NSString *_wrapTitle(NSString *title, NSFont *font) {
    CGFloat innerW = kBtnW - 20;
    NSSize sz = [title sizeWithAttributes:@{NSFontAttributeName: font}];
    if (sz.width <= innerW) return title; // fits in one line

    // Find the last space that fits on the first line
    NSArray *words = [title componentsSeparatedByString:@" "];
    NSMutableString *line1 = [NSMutableString string];
    NSInteger breakIdx = 0;
    for (NSInteger i = 0; i < (NSInteger)words.count; i++) {
        NSString *test = line1.length > 0
            ? [NSString stringWithFormat:@"%@ %@", line1, words[i]]
            : words[i];
        NSSize testSz = [test sizeWithAttributes:@{NSFontAttributeName: font}];
        if (testSz.width > innerW && line1.length > 0) {
            breakIdx = i;
            break;
        }
        [line1 setString:test];
        breakIdx = i + 1;
    }
    if (breakIdx >= (NSInteger)words.count) return title; // couldn't break

    NSString *part1 = [[words subarrayWithRange:NSMakeRange(0, breakIdx)]
                        componentsJoinedByString:@" "];
    NSString *part2 = [[words subarrayWithRange:NSMakeRange(breakIdx, words.count - breakIdx)]
                        componentsJoinedByString:@" "];
    return [NSString stringWithFormat:@"%@\n%@", part1, part2];
}

/// Place a button with dynamic height. Returns Y for next button.
static CGFloat _placeBtnDyn(NSView *parent, NSButton *btn, CGFloat topY) {
    btn.translatesAutoresizingMaskIntoConstraints = YES;
    btn.alignment = NSTextAlignmentCenter;

    NSString *wrapped = _wrapTitle(btn.title, btn.font);
    BOOL multiLine = [wrapped containsString:@"\n"];
    if (multiLine) {
        btn.title = wrapped;
    }

    CGFloat h = multiLine ? kBtnH + 18 : kBtnH;
    [parent addSubview:btn];
    btn.frame = NSMakeRect(kBtnL, topY, kBtnW, h);
    return topY - h - 4;
}

/// Place a checkbox at the given position.
static void _placeChk(NSView *parent, NSButton *chk, CGFloat x, CGFloat y) {
    [parent addSubview:chk];
    [chk sizeToFit];
    NSRect f = chk.frame;
    f.origin = NSMakePoint(x, y);
    chk.frame = f;
}

/// Build a Search Mode group box at the given position. Returns the 4 control pointers.
- (void)_buildSearchModeGroup:(int)idx inView:(NSView *)parent atY:(CGFloat)y {
    NSBox *box = [[NSBox alloc] initWithFrame:NSMakeRect(kLeftM, y, kFieldR - kLeftM + 20, 88)];
    box.title = [[NppLocalizer shared] translate:@"Search Mode"];
    box.titleFont = [NSFont systemFontOfSize:11];
    [parent addSubview:box];

    NSView *bc = box.contentView;
    _smNormal[idx]   = _mkRadio([[NppLocalizer shared] translate:@"Normal"]);
    _smExtended[idx] = _mkRadio([[NppLocalizer shared] translate:@"Extended (\\n, \\r, \\t, \\0, \\x...)"]);
    _smRegex[idx]    = _mkRadio([[NppLocalizer shared] translate:@"Regular expression"]);
    _smDotNL[idx]    = _mkChk([[NppLocalizer shared] translate:@". matches newline"]);
    _smNormal[idx].state = NSControlStateValueOn;
    _smDotNL[idx].enabled = NO;

    // Mode change handler
    _smNormal[idx].target = self;   _smNormal[idx].action = @selector(_modeChanged:);
    _smExtended[idx].target = self; _smExtended[idx].action = @selector(_modeChanged:);
    _smRegex[idx].target = self;    _smRegex[idx].action = @selector(_modeChanged:);

    CGFloat radioShift = (idx == 0) ? -8 : -8; // Find tab: 8px down, others: 8px down
    _placeChk(bc, _smNormal[idx],   8, 48 + radioShift);
    _placeChk(bc, _smExtended[idx], 8, 28 + radioShift);
    _placeChk(bc, _smRegex[idx],    8, 8 + radioShift);

    [bc addSubview:_smDotNL[idx]];
    [_smDotNL[idx] sizeToFit];
    NSRect rf = _smRegex[idx].frame;
    _smDotNL[idx].frame = NSMakeRect(NSMaxX(rf) + 16, 8 + radioShift,
                                     _smDotNL[idx].frame.size.width,
                                     _smDotNL[idx].frame.size.height);
}

/// Issue #143 — Build the Transparency control group (checkbox + 2 radios +
/// slider) in the empty bottom-right pocket of the Find/Replace tabs. The
/// pocket is bounded by the Close button (bottom edge y=133) and the Search
/// Mode box (right edge x=430); all controls sit at x>=434, parked low in the
/// bottom-right corner so they never collide with existing elements. NSView
/// doesn't clip subviews, so the slider's slightly-negative y renders fine in
/// the gap above the status bar. idx selects the per-tab slot (0=Find, 1=Replace).
- (void)_buildTransparencyGroup:(int)idx inView:(NSView *)parent {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL enabled   = [ud boolForKey:kPrefFindTransparencyEnabled];
    NSInteger mode = [ud integerForKey:kPrefFindTransparencyMode];
    double alpha   = [ud doubleForKey:kPrefFindTransparencyAlpha];

    NSButton *chk = _mkChk([[NppLocalizer shared] translate:@"Transparency"]);
    chk.target = self; chk.action = @selector(_transparencyToggled:);
    chk.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    [parent addSubview:chk];
    chk.frame = NSMakeRect(434, 61, 174, 18);

    NSButton *r1 = _mkRadio([[NppLocalizer shared] translate:@"On losing focus"]);
    r1.target = self; r1.action = @selector(_transparencyModeChanged:);
    r1.state = (mode == 1) ? NSControlStateValueOff : NSControlStateValueOn;
    [parent addSubview:r1];
    r1.frame = NSMakeRect(450, 39, 158, 18);

    NSButton *r2 = _mkRadio([[NppLocalizer shared] translate:@"Always"]);
    r2.target = self; r2.action = @selector(_transparencyModeChanged:);
    r2.state = (mode == 1) ? NSControlStateValueOn : NSControlStateValueOff;
    [parent addSubview:r2];
    r2.frame = NSMakeRect(450, 17, 158, 18);

    NSSlider *sl = [NSSlider sliderWithValue:alpha
                                    minValue:kTransparencyMin
                                    maxValue:kTransparencyMax
                                      target:self
                                      action:@selector(_transparencyAlphaChanged:)];
    sl.continuous = YES;
    [parent addSubview:sl];
    sl.frame = NSMakeRect(450, -9, 150, 20);

    _trEnable[idx]      = chk;
    _trLosingFocus[idx] = r1;
    _trAlways[idx]      = r2;
    _trSlider[idx]      = sl;

    r1.enabled = enabled;
    r2.enabled = enabled;
    sl.enabled = enabled;
}

#pragma mark - Build all 5 tabs

- (void)_buildAllTabs {
    NSView *cv = self.window.contentView;

    // ── Tab control (segmented, top) ─────────────────────────────────────
    NppLocalizer *loc = [NppLocalizer shared];
    _tabControl = [NSSegmentedControl segmentedControlWithLabels:
        @[[loc translate:@"Find"], [loc translate:@"Replace"], [loc translate:@"Find in Files"],
          [loc translate:@"Find in Projects"], [loc translate:@"Mark"]]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(_tabChanged:)];
    _tabControl.translatesAutoresizingMaskIntoConstraints = NO;
    _tabControl.selectedSegment = 0;
    _tabControl.font = [NSFont systemFontOfSize:11];
    _tabControl.frame = NSMakeRect(12, NSHeight(cv.frame) - 32, 420, 24);
    _tabControl.autoresizingMask = NSViewMinYMargin;
    [cv addSubview:_tabControl];

    // ── Status bar (bottom) ──────────────────────────────────────────────
    _statusLabel = [NSTextField labelWithString:@""];
    _statusLabel.frame = NSMakeRect(12, 6, kWinW - 24, 18);
    _statusLabel.font = [NSFont boldSystemFontOfSize:10];
    _statusLabel.textColor = [NSColor secondaryLabelColor];
    _statusLabel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [cv addSubview:_statusLabel];

    // ── Shared combos ────────────────────────────────────────────────────
    _findCombo    = _mkCombo();
    // Issue #37 — Enter inside the Find-what combo's field editor is
    // consumed by NSComboBox before our window's keyDown: ever fires.
    // Wiring target/action lets us catch it and route to a tab-gated
    // wrapper that only auto-fires on the Find tab.
    _findCombo.target = self;
    _findCombo.action = @selector(_findComboEnterPressed:);
    _replaceCombo = _mkCombo();
    _filtersCombo = _mkCombo();
    _filtersCombo.stringValue = @"*.*";
    _directoryCombo = _mkCombo();

    // ── Build each tab ───────────────────────────────────────────────────
    [self _buildFindTab];
    [self _buildReplaceTab];
    [self _buildFindInFilesTab];
    [self _buildFindInProjectsTab];
    [self _buildMarkTab];
}

/// Anchor Y offset from top of content view. Since we use flipped-like placement
/// (origin at top-left conceptually), all Y values are measured from the top.
/// But NSView origin is bottom-left, so we convert: actualY = containerHeight - topY - elementHeight
static CGFloat _fromTop(NSView *container, CGFloat topOffset, CGFloat height) {
    return NSHeight(container.frame) - topOffset - height;
}

// ── Tab 0: Find ──────────────────────────────────────────────────────────────

- (void)_buildFindTab {
    NSRect cvFrame = self.window.contentView.frame;
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 26, NSWidth(cvFrame), NSHeight(cvFrame) - 60)];
    v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    CGFloat H = NSHeight(v.frame);

    // "Find what:" + combo
    NSTextField *lbl = _mkLabel([[NppLocalizer shared] translate:@"Find what:"]);
    _placeFieldRow(v, lbl, _findCombo, H - 30, kLabelR, kFieldL, kFieldR);

    // "In selection" checkbox — centered between fields and buttons
    _frInSelection = _mkChk([[NppLocalizer shared] translate:@"In selection"]);
    _placeChk(v, _frInSelection, kFieldR - 88, H - 60);

    // Buttons (right column, dynamic height for wrapping labels)
    NppLocalizer *loc = [NppLocalizer shared];
    CGFloat btnY = H - 34;
    btnY = _placeBtnDyn(v, _mkBtn([loc translate:@"Find Next"],                        @selector(_findNext:), self),        btnY);
    btnY = _placeBtnDyn(v, _mkBtn([loc translate:@"Count"],                            @selector(_count:), self),           btnY);
    btnY = _placeBtnDyn(v, _mkBtn([loc translate:@"Find in Current Document"],     @selector(_findAllCurrent:), self),  btnY);
    btnY = _placeBtnDyn(v, _mkBtn([loc translate:@"Find in All Documents"], @selector(_findAllOpened:), self),   btnY);
    btnY = _placeBtnDyn(v, _mkBtn([loc translate:@"Close"],                            @selector(_close:), self),           btnY);

    // Left-side checkboxes (below the field row, matching Windows)
    _frBackward  = _mkChk([[NppLocalizer shared] translate:@"Backward direction"]);
    _frWholeWord = _mkChk([[NppLocalizer shared] translate:@"Match whole word only"]);
    _frMatchCase = _mkChk([[NppLocalizer shared] translate:@"Match case"]);
    _frWrapAround = _mkChk([[NppLocalizer shared] translate:@"Wrap around"]);
    _frWrapAround.state = NSControlStateValueOn;

    CGFloat chkY = H - 90;
    _placeChk(v, _frBackward,  kLeftM, chkY);
    _placeChk(v, _frWholeWord, kLeftM, chkY - 22);
    _placeChk(v, _frMatchCase, kLeftM, chkY - 44);
    _placeChk(v, _frWrapAround,kLeftM, chkY - 66);

    // Search Mode group box
    [self _buildSearchModeGroup:0 inView:v atY:chkY - 166];

    // Issue #143 — Transparency group in the empty bottom-right pocket
    [self _buildTransparencyGroup:0 inView:v];

    _views[0] = v;
    [self.window.contentView addSubview:v];
}

// ── Tab 1: Replace ───────────────────────────────────────────────────────────

- (void)_buildReplaceTab {
    NSRect cvFrame = self.window.contentView.frame;
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 26, NSWidth(cvFrame), NSHeight(cvFrame) - 60)];
    v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    CGFloat H = NSHeight(v.frame);

    NSTextField *lbl1 = _mkLabel([[NppLocalizer shared] translate:@"Find what:"]);
    _placeFieldRow(v, lbl1, _findCombo, H - 30, kLabelR, kFieldL, kFieldR);

    NSTextField *lbl2 = _mkLabel([[NppLocalizer shared] translate:@"Replace with:"]);
    _placeFieldRow(v, lbl2, _replaceCombo, H - 62, kLabelR, kFieldL, kFieldR);

    // "In selection"
    _frInSelection = _mkChk([[NppLocalizer shared] translate:@"In selection"]);
    _placeChk(v, _frInSelection, kFieldR - 90, H - 92);

    // Buttons
    _placeBtn(v, _mkBtn([[NppLocalizer shared] translate:@"Find Next"],                            @selector(_findNext:), self),        H - 34);
    _placeBtn(v, _mkBtn([[NppLocalizer shared] translate:@"Replace"],                              @selector(_replace:), self),         H - 66);
    _placeBtn(v, _mkBtn([[NppLocalizer shared] translate:@"Replace All"],                          @selector(_replaceAll:), self),      H - 98);
    _placeBtn(v, _mkBtn([[NppLocalizer shared] translate:@"Replace in All Documents"],  @selector(_replaceAllOpened:), self),H - 130);
    _placeBtn(v, _mkBtn([[NppLocalizer shared] translate:@"Close"],                                @selector(_close:), self),           H - 162);

    // Checkboxes (same as Find tab, reuse the same ivars since only one tab visible at a time)
    // But we need separate instances to avoid re-parenting. The _fr* ivars are set per-tab-switch.
    // Actually, Find and Replace share the same option ivars (they're the same set of controls).
    // We created them in _buildFindTab. For Replace, we reference the SAME ivars.
    // Problem: they can't exist in two views. Solution: on tab switch, move them.
    // Better solution: create per-tab instances and sync values on tab switch.

    // For simplicity, create local copies that are read in currentOptions via the _fr* pointers
    // We'll recreate these for each tab that uses them:
    NSButton *bk = _mkChk([[NppLocalizer shared] translate:@"Backward direction"]);
    NSButton *ww = _mkChk([[NppLocalizer shared] translate:@"Match whole word only"]);
    NSButton *mc = _mkChk([[NppLocalizer shared] translate:@"Match case"]);
    NSButton *wa = _mkChk([[NppLocalizer shared] translate:@"Wrap around"]);
    wa.state = NSControlStateValueOn;

    CGFloat chkY = H - 110;
    _placeChk(v, bk, kLeftM, chkY);
    _placeChk(v, ww, kLeftM, chkY - 22);
    _placeChk(v, mc, kLeftM, chkY - 44);
    _placeChk(v, wa, kLeftM, chkY - 66);

    // Store references — on tab switch to Replace, point _fr* to these
    // We'll use objc_setAssociatedObject to tag them
    objc_setAssociatedObject(v, "backward",  bk,  OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(v, "wholeword", ww,  OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(v, "matchcase", mc,  OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(v, "wraparound",wa,  OBJC_ASSOCIATION_RETAIN);

    [self _buildSearchModeGroup:1 inView:v atY:chkY - 166];

    // Issue #143 — Transparency group (same layout as Find tab)
    [self _buildTransparencyGroup:1 inView:v];

    _views[1] = v;
    v.hidden = YES;
    [self.window.contentView addSubview:v];
}

// ── Tab 2: Find in Files ─────────────────────────────────────────────────────

- (void)_buildFindInFilesTab {
    NSRect cvFrame = self.window.contentView.frame;
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 26, NSWidth(cvFrame), NSHeight(cvFrame) - 60)];
    v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    CGFloat H = NSHeight(v.frame);

    _placeFieldRow(v, _mkLabel([[NppLocalizer shared] translate:@"Find what:"]),    _findCombo,      H - 30, kLabelR, kFieldL, kFieldR);
    _placeFieldRow(v, _mkLabel([[NppLocalizer shared] translate:@"Replace with:"]), _replaceCombo,   H - 62, kLabelR, kFieldL, kFieldR);
    _placeFieldRow(v, _mkLabel([[NppLocalizer shared] translate:@"Filters:"]),      _filtersCombo,   H - 94, kLabelR, kFieldL, kFieldR);
    _placeFieldRow(v, _mkLabel([[NppLocalizer shared] translate:@"Directory:"]),    _directoryCombo, H -126, kLabelR, kFieldL, kFieldR - 70);

    // Browse & fill buttons next to directory
    NSButton *browseBtn = _mkBtn(@"...", @selector(_browseDir:), self);
    browseBtn.frame = NSMakeRect(kFieldR - 78, H - 131, 30, 24);
    [v addSubview:browseBtn];
    NSButton *fillBtn = _mkBtn(@"<<", @selector(_fillDirFromDoc:), self);
    fillBtn.frame = NSMakeRect(kFieldR - 45, H - 131, 30, 24);
    [v addSubview:fillBtn];

    // Buttons
    _placeBtn(v, _mkBtn([[NppLocalizer shared] translate:@"Find All"],         @selector(_findInFiles:), self),    H - 34);
    _placeBtn(v, _mkBtn([[NppLocalizer shared] translate:@"Replace in Files"], @selector(_replaceInFiles:), self), H - 66);
    _placeBtn(v, _mkBtn([[NppLocalizer shared] translate:@"Close"],            @selector(_close:), self),          H - 98);

    // Left options
    _fifWholeWord = _mkChk([[NppLocalizer shared] translate:@"Match whole word only"]);
    _fifMatchCase = _mkChk([[NppLocalizer shared] translate:@"Match case"]);
    CGFloat chkY = H - 160;
    _placeChk(v, _fifWholeWord, kLeftM, chkY);
    _placeChk(v, _fifMatchCase, kLeftM, chkY - 22);

    // Right options
    _fifInSubFolders   = _mkChk([[NppLocalizer shared] translate:@"In all sub-folders"]);
    _fifInSubFolders.state = NSControlStateValueOn;
    _fifInHiddenFolders = _mkChk([[NppLocalizer shared] translate:@"In hidden folders"]);
    _placeChk(v, _fifInSubFolders,   kBtnL, chkY);
    _placeChk(v, _fifInHiddenFolders, kBtnL, chkY - 22);

    [self _buildSearchModeGroup:2 inView:v atY:chkY - 120];
    [self _buildTransparencyGroup:2 inView:v];

    _views[2] = v;
    v.hidden = YES;
    [self.window.contentView addSubview:v];
}

// ── Tab 3: Find in Projects ──────────────────────────────────────────────────

- (void)_buildFindInProjectsTab {
    NSRect cvFrame = self.window.contentView.frame;
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 26, NSWidth(cvFrame), NSHeight(cvFrame) - 60)];
    v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    CGFloat H = NSHeight(v.frame);

    _placeFieldRow(v, _mkLabel([[NppLocalizer shared] translate:@"Find what:"]),    _findCombo,    H - 30, kLabelR, kFieldL, kFieldR);
    _placeFieldRow(v, _mkLabel([[NppLocalizer shared] translate:@"Replace with:"]), _replaceCombo, H - 62, kLabelR, kFieldL, kFieldR);
    _placeFieldRow(v, _mkLabel([[NppLocalizer shared] translate:@"Filters:"]),      _filtersCombo, H - 94, kLabelR, kFieldL, kFieldR);

    // Buttons
    _placeBtn(v, _mkBtn([[NppLocalizer shared] translate:@"Find All"],            @selector(_findInProjects:), self),    H - 34);
    _placeBtn(v, _mkBtn([[NppLocalizer shared] translate:@"Replace in Projects"], @selector(_replaceInProjects:), self), H - 66);
    _placeBtn(v, _mkBtn([[NppLocalizer shared] translate:@"Close"],               @selector(_close:), self),             H - 98);

    // Left options
    _fipWholeWord = _mkChk([[NppLocalizer shared] translate:@"Match whole word only"]);
    _fipMatchCase = _mkChk([[NppLocalizer shared] translate:@"Match case"]);
    CGFloat chkY = H - 130;
    _placeChk(v, _fipWholeWord, kLeftM, chkY);
    _placeChk(v, _fipMatchCase, kLeftM, chkY - 22);

    // Right options: Project Panel 1/2/3
    _fipPanel1 = _mkChk([[NppLocalizer shared] translate:@"Project Panel 1"]);
    _fipPanel2 = _mkChk([[NppLocalizer shared] translate:@"Project Panel 2"]);
    _fipPanel3 = _mkChk([[NppLocalizer shared] translate:@"Project Panel 3"]);
    _placeChk(v, _fipPanel1, kBtnL, chkY);
    _placeChk(v, _fipPanel2, kBtnL, chkY - 22);
    _placeChk(v, _fipPanel3, kBtnL, chkY - 44);

    [self _buildSearchModeGroup:3 inView:v atY:chkY - 120];
    [self _buildTransparencyGroup:3 inView:v];

    _views[3] = v;
    v.hidden = YES;
    [self.window.contentView addSubview:v];
}

// ── Tab 4: Mark ──────────────────────────────────────────────────────────────

- (void)_buildMarkTab {
    NSRect cvFrame = self.window.contentView.frame;
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 26, NSWidth(cvFrame), NSHeight(cvFrame) - 60)];
    v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    CGFloat H = NSHeight(v.frame);

    _placeFieldRow(v, _mkLabel([[NppLocalizer shared] translate:@"Find what:"]), _findCombo, H - 30, kLabelR, kFieldL, kFieldR);

    // "In selection" — centered
    _mkInSelection = _mkChk([[NppLocalizer shared] translate:@"In selection"]);
    _placeChk(v, _mkInSelection, kFieldR - 90, H - 60);

    // Buttons
    _placeBtn(v, _mkBtn([[NppLocalizer shared] translate:@"Mark All"],         @selector(_markAll:), self),   H - 34);
    _placeBtn(v, _mkBtn([[NppLocalizer shared] translate:@"Clear all marks"],  @selector(_clearMarks:), self),H - 66);
    _placeBtn(v, _mkBtn([[NppLocalizer shared] translate:@"Copy Marked Text"], @selector(_copyMarked:), self),H - 98);
    _placeBtn(v, _mkBtn([[NppLocalizer shared] translate:@"Close"],            @selector(_close:), self),     H - 130);

    // Left-side checkboxes (matching Windows Mark tab exactly)
    _mkBookmarkLine = _mkChk([[NppLocalizer shared] translate:@"Bookmark line"]);
    _mkPurge        = _mkChk([[NppLocalizer shared] translate:@"Purge for each search"]);
    _mkBackward     = _mkChk([[NppLocalizer shared] translate:@"Backward direction"]);
    _mkWholeWord    = _mkChk([[NppLocalizer shared] translate:@"Match whole word only"]);
    _mkMatchCase    = _mkChk([[NppLocalizer shared] translate:@"Match case"]);
    _mkWrapAround   = _mkChk([[NppLocalizer shared] translate:@"Wrap around"]);
    _mkWrapAround.state = NSControlStateValueOn;

    CGFloat chkY = H - 80;
    _placeChk(v, _mkBookmarkLine, kLeftM, chkY);
    _placeChk(v, _mkPurge,       kLeftM, chkY - 22);
    _placeChk(v, _mkBackward,    kLeftM, chkY - 44);
    _placeChk(v, _mkWholeWord,   kLeftM, chkY - 66);
    _placeChk(v, _mkMatchCase,   kLeftM, chkY - 88);
    _placeChk(v, _mkWrapAround,  kLeftM, chkY - 110);

    [self _buildSearchModeGroup:4 inView:v atY:chkY - 210];
    [self _buildTransparencyGroup:4 inView:v];

    _views[4] = v;
    v.hidden = YES;
    [self.window.contentView addSubview:v];
}

#pragma mark - Tab switching

- (void)_tabChanged:(id)sender {
    _currentTab = (FindWindowTab)_tabControl.selectedSegment;
    [self _switchToTab:_currentTab];
}

- (void)_switchToTab:(FindWindowTab)tab {
    NppLocalizer *loc = [NppLocalizer shared];
    NSArray *titles = @[[loc translate:@"Find"], [loc translate:@"Replace"],
                        [loc translate:@"Find in Files"], [loc translate:@"Find in Projects"],
                        [loc translate:@"Mark"]];

    // Move shared combos to the target tab view
    // First remove from current parent
    [_findCombo removeFromSuperview];
    [_replaceCombo removeFromSuperview];
    [_filtersCombo removeFromSuperview];
    [_directoryCombo removeFromSuperview];

    for (int i = 0; i < 5; i++) _views[i].hidden = (i != tab);
    self.window.title = titles[tab];

    // Re-add shared combos to the active tab's view
    // The _placeFieldRow calls in each _build*Tab already placed them,
    // but since we're removing/re-adding, we need to re-set their frames.
    NSView *tv = _views[tab];
    CGFloat H = NSHeight(tv.frame);

    [tv addSubview:_findCombo];
    _findCombo.frame = NSMakeRect(kFieldL, H - 30, kFieldR - kFieldL, 24);

    if (tab == FindWindowTabReplace || tab == FindWindowTabFindInFiles || tab == FindWindowTabFindInProjects) {
        [tv addSubview:_replaceCombo];
        _replaceCombo.frame = NSMakeRect(kFieldL, H - 62, kFieldR - kFieldL, 24);
    }
    if (tab == FindWindowTabFindInFiles || tab == FindWindowTabFindInProjects) {
        [tv addSubview:_filtersCombo];
        CGFloat filtersY = (tab == FindWindowTabFindInFiles) ? H - 94 : H - 94;
        _filtersCombo.frame = NSMakeRect(kFieldL, filtersY, kFieldR - kFieldL, 24);
    }
    if (tab == FindWindowTabFindInFiles) {
        [tv addSubview:_directoryCombo];
        _directoryCombo.frame = NSMakeRect(kFieldL, H - 126, kFieldR - kFieldL - 70, 24);
    }

    // Point _fr* to the correct tab's checkboxes for Find/Replace
    if (tab == FindWindowTabFind) {
        // _fr* already point to Find tab's controls (set in _buildFindTab)
    } else if (tab == FindWindowTabReplace) {
        // Point to Replace tab's copies
        _frBackward  = objc_getAssociatedObject(tv, "backward");
        _frWholeWord = objc_getAssociatedObject(tv, "wholeword");
        _frMatchCase = objc_getAssociatedObject(tv, "matchcase");
        _frWrapAround = objc_getAssociatedObject(tv, "wraparound");
    }

    _statusLabel.stringValue = @"";
}

#pragma mark - Status

- (void)_showStatus:(NSString *)msg found:(BOOL)found {
    _statusLabel.stringValue = msg;
    _statusLabel.textColor = found
        ? [NSColor colorWithRed:0 green:0 blue:0.7 alpha:1]
        : [NSColor colorWithRed:0.8 green:0 blue:0 alpha:1];
}

- (void)_showReplaceWriteFailures:(NSArray<NSString *> *)failures {
    if (!failures.count) return;
    NSUInteger shownCount = MIN(failures.count, (NSUInteger)10);
    NSMutableArray<NSString *> *details = [[failures subarrayWithRange:NSMakeRange(0, shownCount)] mutableCopy];
    if (failures.count > shownCount)
        [details addObject:[NSString stringWithFormat:[[NppLocalizer shared] translate:@"...and %lu more"],
            (unsigned long)(failures.count - shownCount)]];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = [[NppLocalizer shared] translate:@"Some files could not be replaced"];
    alert.informativeText = [details componentsJoinedByString:@"\n"];
    [alert runModal];
}

#pragma mark - History

- (void)_addToHistory:(NSComboBox *)combo key:(NSString *)key {
    NSString *text = combo.stringValue;
    if (!text.length) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableArray *h = [[ud arrayForKey:key] mutableCopy] ?: [NSMutableArray array];
    [h removeObject:text];
    [h insertObject:text atIndex:0];
    if (h.count > (NSUInteger)kMaxHistory)
        [h removeObjectsInRange:NSMakeRange(kMaxHistory, h.count - kMaxHistory)];
    [ud setObject:h forKey:key];
    [combo removeAllItems];
    [combo addItemsWithObjectValues:h];
}

- (void)_restoreHistory {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *a;
    if ((a = [ud arrayForKey:kHistoryFind]).count)    { [_findCombo    removeAllItems]; [_findCombo    addItemsWithObjectValues:a]; }
    if ((a = [ud arrayForKey:kHistoryReplace]).count)  { [_replaceCombo removeAllItems]; [_replaceCombo addItemsWithObjectValues:a]; }
    if ((a = [ud arrayForKey:kHistoryFilter]).count)   { [_filtersCombo removeAllItems]; [_filtersCombo addItemsWithObjectValues:a]; }
    if ((a = [ud arrayForKey:kHistoryDir]).count)      { [_directoryCombo removeAllItems]; [_directoryCombo addItemsWithObjectValues:a]; }
}

- (void)_modeChanged:(id)sender {
    // Enable ". matches newline" only when regex is selected
    for (int i = 0; i < 5; i++) {
        if (_smDotNL[i] && _smRegex[i])
            _smDotNL[i].enabled = (_smRegex[i].state == NSControlStateValueOn);
    }
}

#pragma mark - Actions: Find

- (void)_findNext:(id)sender {
    NPPFindOptions *opts = [self currentOptions];
    if (!opts.searchText.length) return;
    [self _addToHistory:_findCombo key:kHistoryFind];
    EditorView *ed = [_delegate currentEditor];
    if (!ed) return;
    BOOL forward = (opts.direction == NPPSearchDown);
    BOOL found = [SearchEngine findInView:ed.scintillaView options:opts forward:forward];
    if (!found) {
        [self _showStatus:[NSString stringWithFormat:[[NppLocalizer shared] translate:@"Find: Can't find the text \"%@\""], opts.searchText] found:NO];
    } else {
        [self _showStatus:@"" found:YES];
    }
}

- (void)_count:(id)sender {
    NPPFindOptions *opts = [self currentOptions];
    if (!opts.searchText.length) return;
    [self _addToHistory:_findCombo key:kHistoryFind];
    EditorView *ed = [_delegate currentEditor];
    if (!ed) return;
    NSInteger count = [SearchEngine countInView:ed.scintillaView options:opts];
    [self _showStatus:[NSString stringWithFormat:[[NppLocalizer shared] translate:@"Count: %ld match(es)."], (long)count] found:(count > 0)];
}

- (void)_findAllCurrent:(id)sender {
    NPPFindOptions *opts = [self currentOptions];
    if (!opts.searchText.length) return;
    [self _addToHistory:_findCombo key:kHistoryFind];
    EditorView *ed = [_delegate currentEditor];
    if (!ed) return;
    NSString *path = ed.filePath ?: ed.displayName;
    NSArray *results = [SearchEngine findAllInView:ed.scintillaView filePath:path options:opts];
    if (results.count) {
        NPPFileResults *fr = [[NPPFileResults alloc] init];
        fr.filePath = path;
        [fr.results addObjectsFromArray:results];
        [_delegate findWindow:self showResults:@[fr] forSearchText:opts.searchText options:opts filesSearched:1];
        [_delegate findWindowShowSearchResultsPanel:self];
    } else {
        [self _showStatus:[NSString stringWithFormat:[[NppLocalizer shared] translate:@"Find: Can't find the text \"%@\""], opts.searchText] found:NO];
    }
}

- (void)_findAllOpened:(id)sender {
    NPPFindOptions *opts = [self currentOptions];
    if (!opts.searchText.length) return;
    [self _addToHistory:_findCombo key:kHistoryFind];
    NSArray<EditorView *> *editors = [_delegate allOpenEditors];
    NSMutableArray *allResults = [NSMutableArray array];
    for (EditorView *ed in editors) {
        NSString *path = ed.filePath ?: ed.displayName;
        NSArray *results = [SearchEngine findAllInView:ed.scintillaView filePath:path options:opts];
        if (results.count) {
            NPPFileResults *fr = [[NPPFileResults alloc] init];
            fr.filePath = path;
            [fr.results addObjectsFromArray:results];
            [allResults addObject:fr];
        }
    }
    if (allResults.count) {
        [_delegate findWindow:self showResults:allResults forSearchText:opts.searchText
                      options:opts filesSearched:(NSInteger)editors.count];
        [_delegate findWindowShowSearchResultsPanel:self];
    } else {
        [self _showStatus:[NSString stringWithFormat:[[NppLocalizer shared] translate:@"Find: Can't find the text \"%@\""], opts.searchText] found:NO];
    }
}

#pragma mark - Actions: Replace

- (void)_replace:(id)sender {
    NPPFindOptions *opts = [self currentOptions];
    if (!opts.searchText.length) return;
    [self _addToHistory:_findCombo key:kHistoryFind];
    [self _addToHistory:_replaceCombo key:kHistoryReplace];
    EditorView *ed = [_delegate currentEditor];
    if (!ed) return;
    BOOL found = [SearchEngine replaceInView:ed.scintillaView options:opts];
    if (!found)
        [self _showStatus:[NSString stringWithFormat:[[NppLocalizer shared] translate:@"Find: Can't find the text \"%@\""], opts.searchText] found:NO];
    else
        [self _showStatus:@"" found:YES];
}

- (void)_replaceAll:(id)sender {
    NPPFindOptions *opts = [self currentOptions];
    if (!opts.searchText.length) return;
    [self _addToHistory:_findCombo key:kHistoryFind];
    [self _addToHistory:_replaceCombo key:kHistoryReplace];
    EditorView *ed = [_delegate currentEditor];
    if (!ed) return;
    NSInteger count = [SearchEngine replaceAllInView:ed.scintillaView options:opts];
    NppLocalizer *loc = [NppLocalizer shared];
    NSString *scope = opts.inSelection ? [loc translate:@"in selection"] : [loc translate:@"in entire file"];
    [self _showStatus:[NSString stringWithFormat:[loc translate:@"Replace All: %ld occurrence(s) were replaced %@."], (long)count, scope]
                found:(count > 0)];
}

- (void)_replaceAllOpened:(id)sender {
    NPPFindOptions *opts = [self currentOptions];
    if (!opts.searchText.length) return;
    [self _addToHistory:_findCombo key:kHistoryFind];
    [self _addToHistory:_replaceCombo key:kHistoryReplace];
    NSArray<EditorView *> *editors = [_delegate allOpenEditors];
    NSInteger total = 0;
    for (EditorView *ed in editors)
        total += [SearchEngine replaceAllInView:ed.scintillaView options:opts];
    [self _showStatus:[NSString stringWithFormat:[[NppLocalizer shared] translate:@"Replace in Opened Files: %ld occurrence(s) were replaced."], (long)total]
                found:(total > 0)];
}

#pragma mark - Actions: Find in Files

- (void)_findInFiles:(id)sender {
    NPPFindOptions *opts = [self currentOptions];
    if (!opts.searchText.length || !opts.directory.length) return;
    [self _addToHistory:_findCombo key:kHistoryFind];
    [self _addToHistory:_filtersCombo key:kHistoryFilter];
    [self _addToHistory:_directoryCombo key:kHistoryDir];
    _cancelSearch = NO;
    [self _showStatus:[[NppLocalizer shared] translate:@"Searching..."] found:YES];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSInteger scannedCount = 0;
        NSArray<NPPFileResults *> *results = [SearchEngine findInDirectory:opts.directory
            options:opts
            progressBlock:^(NSString *file, NSInteger hits) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self _showStatus:[NSString stringWithFormat:[[NppLocalizer shared] translate:@"Searching... %ld hit(s) — %@"],
                        (long)hits, file.lastPathComponent] found:YES];
                });
            }
            cancelFlag:&self->_cancelSearch
            totalFilesScanned:&scannedCount];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (results.count) {
                [self->_delegate findWindow:self showResults:results forSearchText:opts.searchText
                              options:opts filesSearched:scannedCount];
                [self->_delegate findWindowShowSearchResultsPanel:self];
                NSInteger totalHits = 0;
                for (NPPFileResults *fr in results) totalHits += (NSInteger)fr.results.count;
                [self _showStatus:[NSString stringWithFormat:[[NppLocalizer shared] translate:@"Find in Files: %ld hit(s) in %ld file(s)."],
                    (long)totalHits, (long)results.count] found:YES];
            } else {
                [self _showStatus:[[NppLocalizer shared] translate:@"Find in Files: 0 hits."] found:NO];
            }
        });
    });
}

- (void)_replaceInFiles:(id)sender {
    NPPFindOptions *opts = [self currentOptions];
    if (!opts.searchText.length || !opts.directory.length) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [[NppLocalizer shared] translate:@"Replace in Files"];
    alert.informativeText = [NSString stringWithFormat:
        [[NppLocalizer shared] translate:@"Replace all occurrences of \"%@\" with \"%@\" in directory:\n%@\n\nThis cannot be undone."],
        opts.searchText, opts.replaceText, opts.directory];
    [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Replace"]];
    [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Cancel"]];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    [self _addToHistory:_findCombo key:kHistoryFind];
    [self _addToHistory:_replaceCombo key:kHistoryReplace];
    [self _addToHistory:_filtersCombo key:kHistoryFilter];
    [self _addToHistory:_directoryCombo key:kHistoryDir];
    [self _showStatus:[[NppLocalizer shared] translate:@"Replacing in files..."] found:YES];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NPPFileResults *> *results = [SearchEngine findInDirectory:opts.directory
            options:opts progressBlock:nil cancelFlag:NULL totalFilesScanned:NULL];
        __block NSInteger totalReplacements = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSInteger changedFiles = 0;
            NSMutableArray<NSString *> *writeFailures = [NSMutableArray array];
            for (NPPFileResults *fr in results) {
                NSString *content = [NSString stringWithContentsOfFile:fr.filePath
                                                             encoding:NSUTF8StringEncoding error:nil];
                if (!content) continue;
                NSInteger replacementCount = 0;
                NSString *replaced = [SearchEngine stringByReplacingAllInString:content
                                                                         options:opts
                                                                replacementCount:&replacementCount];
                // A replacement can be a no-op ("foo" -> "foo", regex (foo) -> \1).
                // Comparing the text as well as the count keeps those files from
                // being rewritten, which would bump their mtime for no reason.
                if (replacementCount > 0 && ![replaced isEqualToString:content]) {
                    NSError *writeError = nil;
                    if ([replaced writeToFile:fr.filePath atomically:YES
                                     encoding:NSUTF8StringEncoding error:&writeError]) {
                        totalReplacements += replacementCount;
                        changedFiles++;
                    } else {
                        [writeFailures addObject:[NSString stringWithFormat:@"%@: %@",
                            fr.filePath, writeError.localizedDescription ?: @"Unknown write error"]];
                    }
                }
            }
            [self _showStatus:[NSString stringWithFormat:[[NppLocalizer shared] translate:@"Replace in Files: %ld replacement(s) in %ld file(s)."],
                (long)totalReplacements, (long)changedFiles] found:(totalReplacements > 0)];
            [self _showReplaceWriteFailures:writeFailures];
        });
    });
}

#pragma mark - Actions: Find in Projects

- (void)_findInProjects:(id)sender {
    NPPFindOptions *opts = [self currentOptions];
    NppLocalizer *loc = [NppLocalizer shared];
    if (!opts.searchText.length) return;

    // Validate: Project Panel must be open
    ProjectPanel *pp = [_delegate projectPanel];
    if (!pp) {
        [self _showStatus:[loc translate:@"Open a Project Panel first."] found:NO];
        return;
    }

    // Validate: at least one checkbox checked
    if (!opts.projectPanel1 && !opts.projectPanel2 && !opts.projectPanel3) {
        [self _showStatus:[loc translate:@"Select at least one Project Panel to search."] found:NO];
        return;
    }

    // Collect file paths from checked workspaces that have content
    NSMutableArray<NSString *> *allPaths = [NSMutableArray array];
    NSMutableArray<NSString *> *emptyPanels = [NSMutableArray array];
    if (opts.projectPanel1) {
        if ([pp workspaceHasContent:0]) [allPaths addObjectsFromArray:[pp allFilePathsFromWorkspace:0]];
        else [emptyPanels addObject:@"1"];
    }
    if (opts.projectPanel2) {
        if ([pp workspaceHasContent:1]) [allPaths addObjectsFromArray:[pp allFilePathsFromWorkspace:1]];
        else [emptyPanels addObject:@"2"];
    }
    if (opts.projectPanel3) {
        if ([pp workspaceHasContent:2]) [allPaths addObjectsFromArray:[pp allFilePathsFromWorkspace:2]];
        else [emptyPanels addObject:@"3"];
    }

    if (allPaths.count == 0) {
        [self _showStatus:[NSString stringWithFormat:@"%@ %@",
            [loc translate:@"No files to search."],
            emptyPanels.count ? [NSString stringWithFormat:@"Panel %@ has no workspace loaded.",
                [emptyPanels componentsJoinedByString:@", "]] : @""]
                    found:NO];
        return;
    }

    [self _addToHistory:_findCombo key:kHistoryFind];
    [self _addToHistory:_filtersCombo key:kHistoryFilter];
    _cancelSearch = NO;
    [self _showStatus:[loc translate:@"Searching..."] found:YES];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSInteger scannedCount = 0;
        NSArray<NPPFileResults *> *results = [SearchEngine findInFilePaths:allPaths
            options:opts
            progressBlock:^(NSString *file, NSInteger hits) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self _showStatus:[NSString stringWithFormat:
                        [[NppLocalizer shared] translate:@"Searching... %ld hit(s) — %@"],
                        (long)hits, file.lastPathComponent] found:YES];
                });
            }
            cancelFlag:&self->_cancelSearch
            totalFilesScanned:&scannedCount];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (results.count) {
                [self->_delegate findWindow:self showResults:results forSearchText:opts.searchText
                              options:opts filesSearched:scannedCount];
                [self->_delegate findWindowShowSearchResultsPanel:self];
                NSInteger totalHits = 0;
                for (NPPFileResults *fr in results) totalHits += (NSInteger)fr.results.count;
                [self _showStatus:[NSString stringWithFormat:
                    [[NppLocalizer shared] translate:@"Find in Projects: %ld hit(s) in %ld file(s)."],
                    (long)totalHits, (long)results.count] found:YES];
            } else {
                [self _showStatus:[[NppLocalizer shared] translate:@"Find in Projects: 0 hits."] found:NO];
            }
        });
    });
}

- (void)_replaceInProjects:(id)sender {
    NPPFindOptions *opts = [self currentOptions];
    NppLocalizer *loc = [NppLocalizer shared];
    if (!opts.searchText.length) return;

    ProjectPanel *pp = [_delegate projectPanel];
    if (!pp) {
        [self _showStatus:[loc translate:@"Open a Project Panel first."] found:NO];
        return;
    }
    if (!opts.projectPanel1 && !opts.projectPanel2 && !opts.projectPanel3) {
        [self _showStatus:[loc translate:@"Select at least one Project Panel to search."] found:NO];
        return;
    }

    NSMutableArray<NSString *> *allPaths = [NSMutableArray array];
    if (opts.projectPanel1 && [pp workspaceHasContent:0]) [allPaths addObjectsFromArray:[pp allFilePathsFromWorkspace:0]];
    if (opts.projectPanel2 && [pp workspaceHasContent:1]) [allPaths addObjectsFromArray:[pp allFilePathsFromWorkspace:1]];
    if (opts.projectPanel3 && [pp workspaceHasContent:2]) [allPaths addObjectsFromArray:[pp allFilePathsFromWorkspace:2]];

    if (allPaths.count == 0) {
        [self _showStatus:[loc translate:@"No files to search."] found:NO];
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [loc translate:@"Replace in Projects"];
    alert.informativeText = [NSString stringWithFormat:
        @"%@ \"%@\" %@ \"%@\" %@ %ld %@",
        [loc translate:@"Replace all occurrences of"],
        opts.searchText,
        [loc translate:@"with"],
        opts.replaceText,
        [loc translate:@"in"],
        (long)allPaths.count,
        [loc translate:@"project file(s). This cannot be undone."]];
    [alert addButtonWithTitle:[loc translate:@"Replace"]];
    [alert addButtonWithTitle:[loc translate:@"Cancel"]];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    [self _addToHistory:_findCombo key:kHistoryFind];
    [self _addToHistory:_replaceCombo key:kHistoryReplace];
    [self _addToHistory:_filtersCombo key:kHistoryFilter];
    [self _showStatus:[loc translate:@"Replacing in files..."] found:YES];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NPPFileResults *> *results = [SearchEngine findInFilePaths:allPaths
            options:opts progressBlock:nil cancelFlag:NULL totalFilesScanned:NULL];
        __block NSInteger totalReplacements = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSInteger changedFiles = 0;
            NSMutableArray<NSString *> *writeFailures = [NSMutableArray array];
            for (NPPFileResults *fr in results) {
                NSString *content = [NSString stringWithContentsOfFile:fr.filePath
                                                             encoding:NSUTF8StringEncoding error:nil];
                if (!content) continue;
                NSInteger replacementCount = 0;
                NSString *replaced = [SearchEngine stringByReplacingAllInString:content
                                                                         options:opts
                                                                replacementCount:&replacementCount];
                // A replacement can be a no-op ("foo" -> "foo", regex (foo) -> \1).
                // Comparing the text as well as the count keeps those files from
                // being rewritten, which would bump their mtime for no reason.
                if (replacementCount > 0 && ![replaced isEqualToString:content]) {
                    NSError *writeError = nil;
                    if ([replaced writeToFile:fr.filePath atomically:YES
                                     encoding:NSUTF8StringEncoding error:&writeError]) {
                        totalReplacements += replacementCount;
                        changedFiles++;
                    } else {
                        [writeFailures addObject:[NSString stringWithFormat:@"%@: %@",
                            fr.filePath, writeError.localizedDescription ?: @"Unknown write error"]];
                    }
                }
            }
            [self _showStatus:[NSString stringWithFormat:
                [[NppLocalizer shared] translate:@"Replace in Projects: %ld replacement(s) in %ld file(s)."],
                (long)totalReplacements, (long)changedFiles] found:(totalReplacements > 0)];
            [self _showReplaceWriteFailures:writeFailures];
        });
    });
}

#pragma mark - Actions: Mark

- (void)_markAll:(id)sender {
    NPPFindOptions *opts = [self currentOptions];
    if (!opts.searchText.length) return;
    [self _addToHistory:_findCombo key:kHistoryFind];
    EditorView *ed = [_delegate currentEditor];
    if (!ed) return;
    NSInteger count = [SearchEngine markAllInView:ed.scintillaView options:opts];
    [self _showStatus:[NSString stringWithFormat:[[NppLocalizer shared] translate:@"Mark: %ld match(es) marked."], (long)count] found:(count > 0)];
}

- (void)_clearMarks:(id)sender {
    EditorView *ed = [_delegate currentEditor];
    if (!ed) return;
    ScintillaView *sci = ed.scintillaView;
    [sci message:SCI_SETINDICATORCURRENT wParam:31];
    [sci message:SCI_INDICATORCLEARRANGE wParam:0 lParam:[sci message:SCI_GETLENGTH]];
    [sci message:SCI_MARKERDELETEALL wParam:20];
    [self _showStatus:[[NppLocalizer shared] translate:@"All marks cleared."] found:YES];
}

- (void)_copyMarked:(id)sender {
    EditorView *ed = [_delegate currentEditor];
    if (!ed) return;
    ScintillaView *sci = ed.scintillaView;
    sptr_t docLen = [sci message:SCI_GETLENGTH];
    NSMutableString *copied = [NSMutableString string];
    sptr_t pos = 0;
    while (pos < docLen) {
        sptr_t start = [sci message:SCI_INDICATORSTART wParam:31 lParam:pos];
        sptr_t val   = [sci message:SCI_INDICATORVALUEAT wParam:31 lParam:start];
        if (val == 0) { pos = [sci message:SCI_INDICATOREND wParam:31 lParam:start]; continue; }
        sptr_t end   = [sci message:SCI_INDICATOREND wParam:31 lParam:start];
        if (end <= start) break;
        sptr_t len = end - start;
        char *buf = (char *)calloc(len + 1, 1);
        struct Sci_TextRangeFull tr = {};
        tr.chrg.cpMin = start; tr.chrg.cpMax = end; tr.lpstrText = buf;
        [sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&tr];
        NSString *text = [NSString stringWithUTF8String:buf];
        if (text) [copied appendFormat:@"%@\n", text];
        free(buf);
        pos = end;
    }
    if (copied.length) {
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:copied forType:NSPasteboardTypeString];
        [self _showStatus:[[NppLocalizer shared] translate:@"Marked text copied to clipboard."] found:YES];
    } else {
        [self _showStatus:[[NppLocalizer shared] translate:@"No marked text to copy."] found:NO];
    }
}

#pragma mark - Common actions

- (void)_close:(id)sender { [self.window orderOut:nil]; }

- (void)_browseDir:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    if ([panel runModal] == NSModalResponseOK)
        _directoryCombo.stringValue = panel.URL.path;
}

- (void)_fillDirFromDoc:(id)sender {
    EditorView *ed = [_delegate currentEditor];
    if (ed.filePath)
        _directoryCombo.stringValue = ed.filePath.stringByDeletingLastPathComponent;
}

#pragma mark - Keyboard

- (void)keyDown:(NSEvent *)event {
    unichar ch = event.characters.length > 0 ? [event.characters characterAtIndex:0] : 0;
    if (ch == '\r' || ch == '\n') {
        [self _findNext:nil];
        return;
    }
    // Escape is handled by cancelOperation: below — that path also fires
    // when focus is in a field editor (NSComboBox), where this keyDown:
    // would never see the event.
    [super keyDown:event];
}

// Issue #37 — Enter inside the Find-what combo box. This fires from the
// combo's target/action wired in _buildAllTabs. We strictly gate on
// FindWindowTabFind: applying the dim-on-find behaviour to the Replace /
// Find-in-Files / Find-in-Projects / Mark tabs would be surprising and
// risk side effects (e.g. a user in Replace pressing Enter expects to
// step focus to the Replace combo, not run a find).
- (void)_findComboEnterPressed:(id)sender {
    if (_currentTab != FindWindowTabFind) return;
    [self _findNext:nil];
}

#pragma mark - Transparency (issue #143)

- (void)_transparencyToggled:(NSButton *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kPrefFindTransparencyEnabled];
    [self _syncTransparencyControls];
    [self _applyTransparency];
}

- (void)_transparencyModeChanged:(NSButton *)sender {
    // Sender is one of the per-tab radios; an "Always" radio means mode 1.
    BOOL always = NO;
    for (int i = 0; i < 5; i++) if (sender == _trAlways[i]) { always = YES; break; }
    [[NSUserDefaults standardUserDefaults] setInteger:(always ? 1 : 0)
                                               forKey:kPrefFindTransparencyMode];
    [self _syncTransparencyControls];
    [self _applyTransparency];
}

- (void)_transparencyAlphaChanged:(NSSlider *)sender {
    [[NSUserDefaults standardUserDefaults] setDouble:sender.doubleValue
                                              forKey:kPrefFindTransparencyAlpha];
    [self _syncTransparencyControls];
    [self _applyTransparency];
}

/// Push the persisted transparency state onto every tab's control set so the
/// Find and Replace tabs always agree, and gray out the sub-controls when the
/// feature is off.
- (void)_syncTransparencyControls {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL enabled   = [ud boolForKey:kPrefFindTransparencyEnabled];
    NSInteger mode = [ud integerForKey:kPrefFindTransparencyMode];
    double alpha   = [ud doubleForKey:kPrefFindTransparencyAlpha];
    for (int i = 0; i < 5; i++) {
        if (!_trEnable[i]) continue;
        _trEnable[i].state      = enabled ? NSControlStateValueOn : NSControlStateValueOff;
        _trLosingFocus[i].state = (mode == 1) ? NSControlStateValueOff : NSControlStateValueOn;
        _trAlways[i].state      = (mode == 1) ? NSControlStateValueOn  : NSControlStateValueOff;
        _trSlider[i].doubleValue = alpha;
        _trLosingFocus[i].enabled = enabled;
        _trAlways[i].enabled      = enabled;
        _trSlider[i].enabled      = enabled;
    }
}

/// Set the window alpha from the current setting and key state.
- (void)_applyTransparency {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL enabled   = [ud boolForKey:kPrefFindTransparencyEnabled];
    NSInteger mode = [ud integerForKey:kPrefFindTransparencyMode];
    double alpha   = [ud doubleForKey:kPrefFindTransparencyAlpha];
    CGFloat target = 1.0;
    if (enabled) {
        if (mode == 1) target = alpha;                                  // always
        else           target = self.window.isKeyWindow ? 1.0 : alpha;  // on losing focus
    }
    self.window.animator.alphaValue = target;
}

#pragma mark - NSWindowDelegate

// Issue #143 — drive transparency from focus changes.
- (void)windowDidBecomeKey:(NSNotification *)notification {
    [self _applyTransparency];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    [self _applyTransparency];
}

// Escape closes the window. cancelOperation: bubbles up the responder chain
// even when focus is in a field editor, which is why we use it instead of
// catching 0x1B in keyDown:.
- (void)cancelOperation:(id)sender {
    [self _close:nil];
}

@end
