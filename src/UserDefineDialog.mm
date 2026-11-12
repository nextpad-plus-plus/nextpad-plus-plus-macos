#import "UserDefineDialog.h"
#import "UDLStylerDialog.h"
#import "NppLocalizer.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// ═══════════════════════════════════════════════════════════════════════════════
// Flipped view: origin at top-left (like Windows), needed for scroll content.
@interface _UDLFlippedView : NSView @end
@implementation _UDLFlippedView
- (BOOL)isFlipped { return YES; }
@end

// ═══════════════════════════════════════════════════════════════════════════════
#pragma mark — Helpers

static NSTextField *L(NSString *t) {
    NSTextField *f = [NSTextField labelWithString:t]; f.font = [NSFont systemFontOfSize:11]; return f;
}

/// Multi-line text field (NSTextView in scroll view) — used for ALL UDL input fields.
/// No scrollbars shown (content scrolls naturally). Border provides the field look.
/// Create a multi-line text field. Call setFrame: on the returned scroll view
/// then call fixWidth() to sync the text container to the actual width.
static NSScrollView *MF(CGFloat h) {
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,400,h)];
    sv.hasVerticalScroller = NO;
    sv.hasHorizontalScroller = NO;
    sv.borderType = NSBezelBorder;

    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0,0,396,h)];
    tv.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    tv.richText = NO; tv.allowsUndo = YES;
    tv.textContainerInset = NSMakeSize(2,1);
    tv.textContainer.widthTracksTextView = YES;
    tv.minSize = NSMakeSize(0, h);
    tv.maxSize = NSMakeSize(1e7, 1e7);
    sv.documentView = tv;
    return sv;
}

/// After setting the frame on an MF() scroll view, call this to sync the
/// text container width so word wrap works at the correct field width.
static void fixWidth(NSScrollView *sv) {
    NSTextView *tv = (NSTextView *)sv.documentView;
    CGFloat w = sv.contentSize.width;
    tv.frame = NSMakeRect(0, 0, w, sv.contentSize.height);
    tv.textContainer.containerSize = NSMakeSize(w, 1e7);
}

static void setText(NSScrollView *sv, NSString *t) {
    fixWidth(sv); // sync text container to actual field width
    [((NSTextView *)sv.documentView) setString:t ?: @""];
}
static NSString *getText(NSScrollView *sv) {
    return ((NSTextView *)sv.documentView).string ?: @"";
}

static NSButton *stylerBtn(id tgt, SEL a) {
    return [NSButton buttonWithTitle:@"Styler" target:tgt action:a];
}
static NSButton *chk(NSString *t) {
    return [NSButton checkboxWithTitle:t target:nil action:nil];
}

/// Scrollable tab content: wraps a flipped content view of given height in a scroll view
/// that fills the tab. Returns the flipped content view (add subviews to it with frame-based layout).
static NSView *scrollableTab(NSTabViewItem *tab, CGFloat contentHeight) {
    _UDLFlippedView *content = [[_UDLFlippedView alloc]
        initWithFrame:NSMakeRect(0, 0, 700, contentHeight)];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,800,500)];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.hasVerticalScroller = NO;
    sv.borderType = NSNoBorder;
    sv.drawsBackground = NO;
    sv.documentView = content;

    // Wrapper view to pin scroll view via Auto Layout
    NSView *wrapper = [[NSView alloc] init];
    [wrapper addSubview:sv];
    [NSLayoutConstraint activateConstraints:@[
        [sv.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
        [sv.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor],
        [sv.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor],
        [sv.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor],
    ]];
    tab.view = wrapper;
    return content;
}

/// NSBox group with titled border. Returns the box; add subviews to box.contentView.
static NSBox *groupBox(NSString *title, CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    NSBox *b = [[NSBox alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    b.title = title; b.titlePosition = NSAtTop; b.autoresizingMask = NSViewWidthSizable;
    return b;
}

// Add Styler + Open/Middle/Close multi-line fields inside a box's contentView.
// NSBox.contentView is NOT flipped — y=0 is bottom, so lay out top-down.
static void addFoldFields(NSBox *box, NSScrollView **oO, NSScrollView **oM, NSScrollView **oC,
                           id stylerTgt, SEL stylerAction) {
    NSView *v = box.contentView;
    // Use a fixed field width that won't overflow, regardless of box/contentView width
    CGFloat cw = 300, fh = 36;
    CGFloat y = box.frame.size.height - 22;

    y -= 26;
    NSButton *sb = stylerBtn(stylerTgt, stylerAction);
    sb.frame = NSMakeRect(4, y, 70, 22); [v addSubview:sb];

    y -= 16;
    NSTextField *lo = L(@"Open:"); lo.frame = NSMakeRect(4, y, 50, 14); [v addSubview:lo];
    y -= fh;
    *oO = MF(fh); (*oO).frame = NSMakeRect(4, y, cw, fh); [v addSubview:*oO];

    y -= 16;
    NSTextField *lm = L(@"Middle:"); lm.frame = NSMakeRect(4, y, 50, 14); [v addSubview:lm];
    y -= fh;
    *oM = MF(fh); (*oM).frame = NSMakeRect(4, y, cw, fh); [v addSubview:*oM];

    y -= 16;
    NSTextField *lc = L(@"Close:"); lc.frame = NSMakeRect(4, y, 50, 14); [v addSubview:lc];
    y -= fh;
    *oC = MF(fh); (*oC).frame = NSMakeRect(4, y, cw, fh); [v addSubview:*oC];
}

// ═══════════════════════════════════════════════════════════════════════════════
#pragma mark — UserDefineDialog
// ═══════════════════════════════════════════════════════════════════════════════

@implementation UserDefineDialog {
    NSPopUpButton *_langPopup;
    NSTextField   *_extField;
    NSButton      *_ignoreCaseCheck;
    NSTabView     *_tabView;

    // Tab 1
    NSButton *_foldCompactCheck;
    NSScrollView *_c1Open, *_c1Mid, *_c1Close;
    NSScrollView *_c2Open, *_c2Mid, *_c2Close;
    NSScrollView *_cfOpen, *_cfMid, *_cfClose;

    // Tab 2
    NSButton *_kwPfx[8]; NSScrollView *_kwArea[8];

    // Tab 3
    NSButton *_radioAny, *_radioBOL, *_radioWS, *_foldCmtCheck;
    NSScrollView *_clOpen, *_clCont, *_clClose;
    NSScrollView *_bcOpen, *_bcClose;
    NSScrollView *_nP1, *_nP2, *_nE1, *_nE2, *_nS1, *_nS2, *_nR;
    NSButton *_decDot, *_decComma, *_decBoth;

    // Tab 4
    NSScrollView *_op1, *_op2;
    NSScrollView *_dO[8], *_dE[8], *_dC[8];

    UserDefinedLang *_cur;
    // Form state as last loaded or saved (see _formState). _commitEdits
    // compares against it so an untouched UDL is never rewritten, and only
    // the keyword lists that actually changed are re-encoded.
    NSDictionary *_snapshot;
    BOOL _stylesDirty;   // a Styler dialog edit is not yet on disk
}

+ (instancetype)sharedController {
    static UserDefineDialog *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [[self alloc] init]; }); return s;
}

- (instancetype)init {
    NSWindow *w = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0,0,740,680)
                  styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|
                            NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered defer:NO];
    w.title = [[NppLocalizer shared] translate:@"User Defined Language v.2.1"];
    [w center];
    self = [super initWithWindow:w];
    if (self) {
        w.delegate = self;
        [self _buildUI];
        // Quitting with the dialog open (or hidden by the main window closing)
        // never sends windowWillClose:, so flush pending edits here too.
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_appWillTerminate:)
                   name:NSApplicationWillTerminateNotification object:nil];
    }
    return self;
}

- (void)showWithLanguage:(nullable NSString *)n {
    // The window may have been hidden (orderOut) with edits still in the form.
    // If saving them fails, show the form as it is rather than reloading it.
    if (![self _commitEdits]) { [self showWindow:nil]; return; }
    NSString *keep = n ?: _cur.name;
    [self showWindow:nil]; [self _rebuildPopup];
    if (keep) [_langPopup selectItemWithTitle:keep];
    [self _load];
}

- (void)_appWillTerminate:(NSNotification *)n { [self _commitEditsReloading:NO]; }

#pragma mark — Main layout

- (void)_buildUI {
    NSView *r = self.window.contentView;
    NppLocalizer *loc = [NppLocalizer shared];

    // Row 1
    NSTextField *ll = L([loc translate:@"User language:"]);
    ll.translatesAutoresizingMaskIntoConstraints = NO; [r addSubview:ll];
    _langPopup = [[NSPopUpButton alloc] init];
    _langPopup.translatesAutoresizingMaskIntoConstraints = NO;
    _langPopup.target = self; _langPopup.action = @selector(_langChanged:);
    [_langPopup.widthAnchor constraintGreaterThanOrEqualToConstant:180].active = YES;
    [r addSubview:_langPopup];

    NSArray *bt = @[[loc translate:@"Create new…"], [loc translate:@"Save as…"], [loc translate:@"Rename"], [loc translate:@"Remove"]];
    SEL ba[] = {@selector(_createNew:), @selector(_saveAs:), @selector(_rename:), @selector(_remove:)};
    NSMutableArray *bs = [NSMutableArray array];
    for (int i = 0; i < 4; i++) {
        NSButton *b = [NSButton buttonWithTitle:bt[i] target:self action:ba[i]];
        b.translatesAutoresizingMaskIntoConstraints = NO; b.font = [NSFont systemFontOfSize:11];
        [r addSubview:b]; [bs addObject:b];
    }

    // Row 2
    NSButton *bI = [NSButton buttonWithTitle:[loc translate:@"Import…"] target:self action:@selector(_import:)];
    NSButton *bE = [NSButton buttonWithTitle:[loc translate:@"Export…"] target:self action:@selector(_export:)];
    for (NSButton *b in @[bI, bE]) { b.translatesAutoresizingMaskIntoConstraints = NO; b.font = [NSFont systemFontOfSize:11]; [r addSubview:b]; }
    NSTextField *el = L([loc translate:@"Ext.:"]); el.translatesAutoresizingMaskIntoConstraints = NO; [r addSubview:el];
    _extField = [[NSTextField alloc] init]; _extField.translatesAutoresizingMaskIntoConstraints = NO; _extField.font = [NSFont systemFontOfSize:11];
    [_extField.widthAnchor constraintGreaterThanOrEqualToConstant:100].active = YES; [r addSubview:_extField];
    _ignoreCaseCheck = chk([loc translate:@"Ignore case"]); _ignoreCaseCheck.translatesAutoresizingMaskIntoConstraints = NO; [r addSubview:_ignoreCaseCheck];

    _tabView = [[NSTabView alloc] init]; _tabView.translatesAutoresizingMaskIntoConstraints = NO; [r addSubview:_tabView];
    [_tabView addTabViewItem:[self _tab1]]; [_tabView addTabViewItem:[self _tab2]];
    [_tabView addTabViewItem:[self _tab3]]; [_tabView addTabViewItem:[self _tab4]];

    // Constraints
    [NSLayoutConstraint activateConstraints:@[
        [ll.topAnchor constraintEqualToAnchor:r.topAnchor constant:10],
        [ll.leadingAnchor constraintEqualToAnchor:r.leadingAnchor constant:10],
        [_langPopup.centerYAnchor constraintEqualToAnchor:ll.centerYAnchor],
        [_langPopup.leadingAnchor constraintEqualToAnchor:ll.trailingAnchor constant:4],
    ]];
    NSView *prev = _langPopup;
    for (NSButton *b in bs) {
        [b.centerYAnchor constraintEqualToAnchor:ll.centerYAnchor].active = YES;
        [b.leadingAnchor constraintEqualToAnchor:prev.trailingAnchor constant:6].active = YES;
        prev = b;
    }
    [NSLayoutConstraint activateConstraints:@[
        [bI.topAnchor constraintEqualToAnchor:ll.bottomAnchor constant:6],
        [bI.leadingAnchor constraintEqualToAnchor:r.leadingAnchor constant:10],
        [bE.centerYAnchor constraintEqualToAnchor:bI.centerYAnchor],
        [bE.leadingAnchor constraintEqualToAnchor:bI.trailingAnchor constant:4],
        [el.centerYAnchor constraintEqualToAnchor:bI.centerYAnchor],
        [el.leadingAnchor constraintEqualToAnchor:bE.trailingAnchor constant:12],
        [_extField.centerYAnchor constraintEqualToAnchor:bI.centerYAnchor],
        [_extField.leadingAnchor constraintEqualToAnchor:el.trailingAnchor constant:4],
        [_ignoreCaseCheck.centerYAnchor constraintEqualToAnchor:bI.centerYAnchor],
        [_ignoreCaseCheck.leadingAnchor constraintEqualToAnchor:_extField.trailingAnchor constant:12],
        [_tabView.topAnchor constraintEqualToAnchor:bI.bottomAnchor constant:8],
        [_tabView.leadingAnchor constraintEqualToAnchor:r.leadingAnchor constant:4],
        [_tabView.trailingAnchor constraintEqualToAnchor:r.trailingAnchor constant:-4],
        [_tabView.bottomAnchor constraintEqualToAnchor:r.bottomAnchor constant:-4],
    ]];
}

#pragma mark — Tab 1: Folder & Default

- (NSTabViewItem *)_tab1 {
    NppLocalizer *loc = [NppLocalizer shared];
    NSTabViewItem *t = [[NSTabViewItem alloc] initWithIdentifier:@"f"]; t.label = [loc translate:@"Folder && Default"];
    NSView *c = scrollableTab(t, 650);
    CGFloat W = 700, hw = W/2 - 16, y = 8;

    // Left column X and width, right column X and width
    CGFloat lx = 8, rx = W/2 + 10;

    // Row 1 left: Documentation
    NSBox *docBox = groupBox(@"Documentation", lx, y, hw, 50);
    NSTextField *link = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 6, 350, 16)];
    link.editable = NO; link.bordered = NO; link.drawsBackground = NO;
    link.allowsEditingTextAttributes = YES; link.selectable = YES;
    NSMutableAttributedString *linkStr = [[NSMutableAttributedString alloc]
        initWithString:@"User Defined Languages online help"
            attributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:11],
                NSForegroundColorAttributeName: [NSColor linkColor],
                NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
                NSLinkAttributeName: [NSURL URLWithString:@"https://npp-user-manual.org/docs/user-defined-language-system/"],
            }];
    link.attributedStringValue = linkStr;
    [docBox.contentView addSubview:link];
    [c addSubview:docBox];

    // Row 1 right: Folding in comment style (moved up to top)
    NSScrollView *tfo, *tfm, *tfc;
    NSBox *cf = groupBox(@"Folding in comment style", rx, y, hw, 240);
    addFoldFields(cf, &tfo, &tfm, &tfc, self, @selector(_stylerNYI:));
    _cfOpen = tfo; _cfMid = tfm; _cfClose = tfc;
    [c addSubview:cf];
    y += 58;

    // Row 2 left: Default style — Styler button centered in the box
    NSBox *defBox = groupBox(@"Default style", lx, y, hw, 50);
    NSButton *defSb = stylerBtn(self, @selector(_stylerNYI:));
    defSb.translatesAutoresizingMaskIntoConstraints = NO;
    [defBox.contentView addSubview:defSb];
    [NSLayoutConstraint activateConstraints:@[
        [defSb.centerXAnchor constraintEqualToAnchor:defBox.contentView.centerXAnchor],
        [defSb.centerYAnchor constraintEqualToAnchor:defBox.contentView.centerYAnchor],
    ]];
    [c addSubview:defBox]; y += 70;

    // Fold compact checkbox
    _foldCompactCheck = chk([loc translate:@"Fold compact (fold empty lines too)"]);
    _foldCompactCheck.frame = NSMakeRect(16, y, 350, 18);
    [c addSubview:_foldCompactCheck]; y += 128;

    // Row 3: Folding in code 1 (left) + Folding in code 2 (right, moved from Row 4)
    NSScrollView *t1o, *t1m, *t1c;
    NSBox *c1 = groupBox(@"Folding in code 1 style", lx, y, hw, 240);
    addFoldFields(c1, &t1o, &t1m, &t1c, self, @selector(_stylerNYI:));
    _c1Open = t1o; _c1Mid = t1m; _c1Close = t1c;
    [c addSubview:c1];

    NSScrollView *t2o, *t2m, *t2c;
    NSBox *c2 = groupBox(@"Folding in code 2 style (separators needed)", rx, y, hw, 240);
    addFoldFields(c2, &t2o, &t2m, &t2c, self, @selector(_stylerNYI:));
    _c2Open = t2o; _c2Mid = t2m; _c2Close = t2c;
    [c addSubview:c2];

    return t;
}

#pragma mark — Tab 2: Keywords Lists

- (NSTabViewItem *)_tab2 {
    NppLocalizer *loc = [NppLocalizer shared];
    NSTabViewItem *t = [[NSTabViewItem alloc] initWithIdentifier:@"k"]; t.label = [loc translate:@"Keywords Lists"];
    CGFloat colW = 310, rowH = 130, pad = 6;
    NSView *c = scrollableTab(t, 4 * (rowH + pad) + pad);

    for (int i = 0; i < 8; i++) {
        int col = i % 2, row = i / 2;
        CGFloat x = pad + col * (colW + pad);
        CGFloat y = pad + row * (rowH + pad);

        NSString *ord = @[@"1st",@"2nd",@"3rd",@"4th",@"5th",@"6th",@"7th",@"8th"][i];
        NSBox *box = groupBox([NSString stringWithFormat:@"%@ group", ord], x, y, colW, rowH);
        NSView *bv = box.contentView;
        CGFloat bw = colW - 16;

        // Explicit content height: rowH(160) - 20(title) = 140
        CGFloat bvH = rowH - 20;
        // Styler + Prefix at bottom (y=0 is bottom in NSBox contentView)
        NSButton *sb = stylerBtn(self, @selector(_stylerNYI:));
        sb.frame = NSMakeRect(4, 2, 70, 20); [bv addSubview:sb];
        _kwPfx[i] = chk([loc translate:@"Prefix mode"]); _kwPfx[i].frame = NSMakeRect(80, 2, 110, 18); [bv addSubview:_kwPfx[i]];
        // Keyword text area fills the rest above
        CGFloat aH = bvH - 28;
        _kwArea[i] = MF(aH - 15); _kwArea[i].frame = NSMakeRect(4, 28, bw - 20, aH - 15);
        [bv addSubview:_kwArea[i]];
        [c addSubview:box];
    }
    return t;
}

#pragma mark — Tab 3: Comment & Number

- (NSTabViewItem *)_tab3 {
    NppLocalizer *loc = [NppLocalizer shared];
    NSTabViewItem *t = [[NSTabViewItem alloc] initWithIdentifier:@"c"]; t.label = [loc translate:@"Comment && Number"];
    CGFloat W = 700, hw = W/2 - 16;
    NSView *c = scrollableTab(t, 800);
    CGFloat y = 8;

    // Line comment position (left)
    NSBox *lcpBox = groupBox(@"Line comment position", 8, y, hw, 90);
    _radioAny = [NSButton radioButtonWithTitle:[loc translate:@"Allow anywhere"] target:nil action:nil];
    _radioBOL = [NSButton radioButtonWithTitle:[loc translate:@"Force at beginning of line"] target:nil action:nil];
    _radioWS  = [NSButton radioButtonWithTitle:[loc translate:@"Allow preceding whitespace"] target:nil action:nil];
    _radioAny.state = NSControlStateValueOn;
    _radioAny.frame = NSMakeRect(10, 48, 250, 16);
    _radioBOL.frame = NSMakeRect(10, 28, 250, 16);
    _radioWS.frame  = NSMakeRect(10, 8, 250, 16);
    [lcpBox.contentView addSubview:_radioAny]; [lcpBox.contentView addSubview:_radioBOL]; [lcpBox.contentView addSubview:_radioWS];
    [c addSubview:lcpBox];

    // Allow folding (right)
    _foldCmtCheck = chk([loc translate:@"Allow folding of comments"]);
    _foldCmtCheck.frame = NSMakeRect(W/2 + 10, y + 10, 250, 18); [c addSubview:_foldCmtCheck];
    y += 100;

    // Comment line style (left) — layout top-down, explicit height (220 - 20 = 200)
    NSBox *clBox = groupBox(@"Comment line style", 8, y, hw, 220);
    NSView *clV = clBox.contentView; CGFloat cy = 200;
    cy -= 26;
    NSButton *clSb = stylerBtn(self, @selector(_stylerNYI:)); clSb.frame = NSMakeRect(hw/2 - 35 + 123, cy, 70, 22); [clV addSubview:clSb];
    cy -= 16;
    NSTextField *clOL = L(@"Open:"); clOL.frame = NSMakeRect(4, cy, 100, 14); [clV addSubview:clOL];
    cy -= 36;
    _clOpen = MF(36); _clOpen.frame = NSMakeRect(4, cy, 290, 36); [clV addSubview:_clOpen];
    cy -= 16;
    NSTextField *clCL = L(@"Continue character:"); clCL.frame = NSMakeRect(4, cy, 120, 14); [clV addSubview:clCL];
    cy -= 36;
    _clCont = MF(36); _clCont.frame = NSMakeRect(4, cy, 290, 36); [clV addSubview:_clCont];
    cy -= 16;
    NSTextField *clXL = L(@"Close:"); clXL.frame = NSMakeRect(4, cy, 100, 14); [clV addSubview:clXL];
    cy -= 36;
    _clClose = MF(36); _clClose.frame = NSMakeRect(4, cy, 290, 36); [clV addSubview:_clClose];
    [c addSubview:clBox];

    // Comment style (right) — top-down, explicit height (160 - 20 = 140)
    NSBox *bcBox = groupBox(@"Comment style", W/2 + 10, y, hw, 160);
    NSView *bcV = bcBox.contentView; CGFloat by = 140;
    by -= 26;
    NSButton *bcSb = stylerBtn(self, @selector(_stylerNYI:)); bcSb.frame = NSMakeRect(hw - 80, by, 70, 22); [bcV addSubview:bcSb];
    by -= 16;
    NSTextField *bcOL = L(@"Open:"); bcOL.frame = NSMakeRect(4, by, 50, 14); [bcV addSubview:bcOL];
    by -= 36;
    _bcOpen = MF(36); _bcOpen.frame = NSMakeRect(4, by, 290, 36); [bcV addSubview:_bcOpen];
    by -= 16;
    NSTextField *bcCL = L(@"Close:"); bcCL.frame = NSMakeRect(4, by, 50, 14); [bcV addSubview:bcCL];
    by -= 36;
    _bcClose = MF(36); _bcClose.frame = NSMakeRect(4, by, 290, 36); [bcV addSubview:_bcClose];
    [c addSubview:bcBox];
    y += 230;

    // Number style (full width) — top-down, explicit height (300 - 20 = 280)
    NSBox *numBox = groupBox(@"Number style", 8, y, W - 16, 300);
    NSView *nv = numBox.contentView; CGFloat nw = (W - 50) / 2;
    CGFloat ny = 280 - 50;
    ny -= 26;
    // Styler button — right-aligned inside the Number box
    NSButton *nSb = stylerBtn(self, @selector(_stylerNYI:)); nSb.frame = NSMakeRect(W - 95, ny + 50, 70, 22); [nv addSubview:nSb];
    ny -= 20;
    ny += 22; // move fields up (net: 40 - 18 = 22)

    // Number fields: label and field on same row, label to the left of field
    // Each row = 38pt (32pt field + 6pt gap)
    CGFloat fh = 28, rh = 36, fw = 230, rx = nw + 20;

    NSTextField *np1L = L(@"Prefix 1:"); np1L.frame = NSMakeRect(8, ny + 8, 62, 16); [nv addSubview:np1L];
    _nP1 = MF(fh); _nP1.frame = NSMakeRect(72, ny, fw, fh); [nv addSubview:_nP1];
    NSTextField *np2L = L(@"Prefix 2:"); np2L.frame = NSMakeRect(rx, ny + 8, 62, 16); [nv addSubview:np2L];
    _nP2 = MF(fh); _nP2.frame = NSMakeRect(rx + 64, ny, fw, fh); [nv addSubview:_nP2];
    ny -= rh;

    NSTextField *ne1L = L(@"Extras 1:"); ne1L.frame = NSMakeRect(8, ny + 8, 62, 16); [nv addSubview:ne1L];
    _nE1 = MF(fh); _nE1.frame = NSMakeRect(72, ny, fw, fh); [nv addSubview:_nE1];
    NSTextField *ne2L = L(@"Extras 2:"); ne2L.frame = NSMakeRect(rx, ny + 8, 62, 16); [nv addSubview:ne2L];
    _nE2 = MF(fh); _nE2.frame = NSMakeRect(rx + 64, ny, fw, fh); [nv addSubview:_nE2];
    ny -= rh;

    NSTextField *ns1L = L(@"Suffix 1:"); ns1L.frame = NSMakeRect(8, ny + 8, 62, 16); [nv addSubview:ns1L];
    _nS1 = MF(fh); _nS1.frame = NSMakeRect(72, ny, fw, fh); [nv addSubview:_nS1];
    NSTextField *ns2L = L(@"Suffix 2:"); ns2L.frame = NSMakeRect(rx, ny + 8, 62, 16); [nv addSubview:ns2L];
    _nS2 = MF(fh); _nS2.frame = NSMakeRect(rx + 64, ny, fw, fh); [nv addSubview:_nS2];
    ny -= rh;

    NSTextField *nrl = L(@"Range:"); nrl.frame = NSMakeRect(8, ny + 8, 62, 16); [nv addSubview:nrl];
    _nR = MF(fh); _nR.frame = NSMakeRect(72, ny, fw, fh); [nv addSubview:_nR];

    // Decimal separator box — below Range row, right column
    // ny is now at the Range field position; go below it
    NSBox *decBox = groupBox(@"Decimal separator", rx, ny - 44 - 35 + 50, 300, 44);
    _decDot = [NSButton radioButtonWithTitle:[loc translate:@"Dot"] target:nil action:nil];
    _decComma = [NSButton radioButtonWithTitle:[loc translate:@"Comma"] target:nil action:nil];
    _decBoth = [NSButton radioButtonWithTitle:[loc translate:@"Both"] target:nil action:nil];
    _decDot.state = NSControlStateValueOn;
    _decDot.frame = NSMakeRect(8, 4, 60, 16); _decComma.frame = NSMakeRect(78, 4, 80, 16); _decBoth.frame = NSMakeRect(168, 4, 60, 16);
    [decBox.contentView addSubview:_decDot]; [decBox.contentView addSubview:_decComma]; [decBox.contentView addSubview:_decBoth];
    [nv addSubview:decBox];

    [c addSubview:numBox];
    return t;
}

#pragma mark — Tab 4: Operators & Delimiters

- (NSTabViewItem *)_tab4 {
    NppLocalizer *loc = [NppLocalizer shared];
    NSTabViewItem *t = [[NSTabViewItem alloc] initWithIdentifier:@"o"]; t.label = [loc translate:@"Operators && Delimiters"];
    CGFloat W = 700, hw = W/2 - 16, dH = 98;
    NSView *c = scrollableTab(t, 130 + 4 * (dH + 6) + 10);
    CGFloat y = 8;

    // Operators
    NSBox *opBox = groupBox(@"Operators style", 8, y, W - 16, 110);
    NSView *opV = opBox.contentView;
    // Operators box: top-down, explicit height (110 box - 20 title = 90 content)
    CGFloat opCH = 90;
    NSButton *opSb = stylerBtn(self, @selector(_stylerNYI:)); opSb.frame = NSMakeRect(4, opCH - 26, 70, 22); [opV addSubview:opSb];
    NSTextField *o1L = L(@"Operators 1"); o1L.frame = NSMakeRect(4, opCH - 42, 120, 14); [opV addSubview:o1L];
    NSTextField *o2L = L(@"Operators 2 (separators required)"); o2L.frame = NSMakeRect(hw + 5, opCH - 42, 250, 14); [opV addSubview:o2L];
    CGFloat opfw = hw - 12;
    _op1 = MF(36); _op1.frame = NSMakeRect(4, 4, opfw, 36); [opV addSubview:_op1];
    _op2 = MF(36); _op2.frame = NSMakeRect(hw + 5, 4, opfw, 36); [opV addSubview:_op2];
    [c addSubview:opBox]; y += 120;

    // 8 delimiters in 2×4 grid
    // Each box: title row has Styler button, then Open/Escape/Close rows
    CGFloat dvH = dH - 20; // content height (box height minus title)
    CGFloat fw = hw - 150;  // field width: fits inside box with label + margins
    for (int i = 0; i < 8; i++) {
        int col = i % 2, row = i / 2;
        CGFloat dx = 8 + col * (hw + 10);
        CGFloat dy = y + row * (dH + 6);
        NSBox *dBox = groupBox([NSString stringWithFormat:@"Delimiter %d style", i+1], dx, dy, hw, dH);
        NSView *dv = dBox.contentView;

        // Styler button at top-right of content, above fields
        NSButton *dSb = stylerBtn(self, @selector(_stylerNYI:));
        dSb.frame = NSMakeRect(hw - 80, 45, 66, 18);
        [dv addSubview:dSb];

        // 3 field rows, top-down from below Styler
        CGFloat ry = dvH - 24;
        NSTextField *oL = L(@"Open:");  oL.frame = NSMakeRect(4, ry - 2, 50, 14);
        _dO[i] = MF(20); _dO[i].frame = NSMakeRect(56, ry - 4, fw, 20);
        [dv addSubview:oL]; [dv addSubview:_dO[i]];

        ry -= 24;
        NSTextField *eL = L(@"Escape:"); eL.frame = NSMakeRect(4, ry - 2, 50, 14);
        _dE[i] = MF(20); _dE[i].frame = NSMakeRect(56, ry - 4, fw, 20);
        [dv addSubview:eL]; [dv addSubview:_dE[i]];

        ry -= 24;
        NSTextField *cL = L(@"Close:"); cL.frame = NSMakeRect(4, ry - 2, 50, 14);
        _dC[i] = MF(20); _dC[i].frame = NSMakeRect(56, ry - 4, fw, 20);
        [dv addSubview:cL]; [dv addSubview:_dC[i]];

        [c addSubview:dBox];
    }
    return t;
}

#pragma mark — Styler (placeholder)

- (void)_stylerNYI:(id)sender {
    // Walk up to find the parent NSBox to determine which style this is
    NSView *v = (NSView *)sender;
    NSString *boxTitle = nil;
    while (v) {
        if ([v isKindOfClass:[NSBox class]]) { boxTitle = ((NSBox *)v).title; break; }
        v = v.superview;
    }

    // Map box title to style name + nesting flag
    NSString *styleName = nil;
    BOOL enableNesting = NO;

    if (!boxTitle) styleName = @"DEFAULT";
    else if ([boxTitle containsString:@"Default"])     styleName = @"DEFAULT";
    else if ([boxTitle containsString:@"code 1"])      styleName = @"FOLDER IN CODE1";
    else if ([boxTitle containsString:@"code 2"])      styleName = @"FOLDER IN CODE2";
    else if ([boxTitle containsString:@"comment"] && [boxTitle containsString:@"Folding"])
                                                        styleName = @"FOLDER IN COMMENT";
    else if ([boxTitle containsString:@"Comment line"]) { styleName = @"LINE COMMENTS"; enableNesting = YES; }
    else if ([boxTitle containsString:@"Comment style"]) { styleName = @"COMMENTS"; enableNesting = YES; }
    else if ([boxTitle containsString:@"Number"])       styleName = @"NUMBERS";
    else if ([boxTitle containsString:@"Operators"])     styleName = @"OPERATORS";
    else if ([boxTitle containsString:@"Delimiter 1"])  { styleName = @"DELIMITERS1"; enableNesting = YES; }
    else if ([boxTitle containsString:@"Delimiter 2"])  { styleName = @"DELIMITERS2"; enableNesting = YES; }
    else if ([boxTitle containsString:@"Delimiter 3"])  { styleName = @"DELIMITERS3"; enableNesting = YES; }
    else if ([boxTitle containsString:@"Delimiter 4"])  { styleName = @"DELIMITERS4"; enableNesting = YES; }
    else if ([boxTitle containsString:@"Delimiter 5"])  { styleName = @"DELIMITERS5"; enableNesting = YES; }
    else if ([boxTitle containsString:@"Delimiter 6"])  { styleName = @"DELIMITERS6"; enableNesting = YES; }
    else if ([boxTitle containsString:@"Delimiter 7"])  { styleName = @"DELIMITERS7"; enableNesting = YES; }
    else if ([boxTitle containsString:@"Delimiter 8"])  { styleName = @"DELIMITERS8"; enableNesting = YES; }
    else if ([boxTitle containsString:@"1st"])  styleName = @"KEYWORDS1";
    else if ([boxTitle containsString:@"2nd"])  styleName = @"KEYWORDS2";
    else if ([boxTitle containsString:@"3rd"])  styleName = @"KEYWORDS3";
    else if ([boxTitle containsString:@"4th"])  styleName = @"KEYWORDS4";
    else if ([boxTitle containsString:@"5th"])  styleName = @"KEYWORDS5";
    else if ([boxTitle containsString:@"6th"])  styleName = @"KEYWORDS6";
    else if ([boxTitle containsString:@"7th"])  styleName = @"KEYWORDS7";
    else if ([boxTitle containsString:@"8th"])  styleName = @"KEYWORDS8";

    if (!styleName) styleName = @"DEFAULT";

    // If no language loaded, open with a default style
    if (!_cur) {
        NSMutableDictionary *ds = [@{@"name":styleName, @"fgColor":@"000000",
                                      @"bgColor":@"FFFFFF", @"fontStyle":@"0"} mutableCopy];
        [UDLStylerDialog runForStyle:ds enableNesting:enableNesting parentWindow:self.window];
        return;
    }

    // Find the matching style dictionary and make it mutable
    NSMutableArray *mutableStyles = [_cur.styles mutableCopy];
    NSMutableDictionary *targetStyle = nil;
    for (NSUInteger i = 0; i < mutableStyles.count; i++) {
        if ([mutableStyles[i][@"name"] caseInsensitiveCompare:styleName] == NSOrderedSame) {
            NSMutableDictionary *ms = [mutableStyles[i] mutableCopy];
            mutableStyles[i] = ms;
            _cur.styles = mutableStyles;
            targetStyle = ms;
            break;
        }
    }

    BOOL isNew = (targetStyle == nil);
    if (isNew) {
        targetStyle = [@{@"name":styleName, @"fgColor":@"000000",
                          @"bgColor":@"FFFFFF", @"fontStyle":@"0"} mutableCopy];
    }

    if (![UDLStylerDialog runForStyle:targetStyle enableNesting:enableNesting parentWindow:self.window])
        return;
    // A style missing from the file is added to the UDL so the edit is kept.
    if (isNew) _cur.styles = [(_cur.styles ?: @[]) arrayByAddingObject:targetStyle];
    // Styler OK is an explicit commit: save and re-apply to open editors now.
    _stylesDirty = YES;
    [self _commitEdits];
}

#pragma mark — Comments / Delimiters decode & encode

/// Decode a prefix-encoded keyword list string into an array of field values.
/// The format is: "00val1 val2 01val3 02val4 03val5 04val6"
/// where "00"-"04" (or "00"-"23") are 2-digit prefix selectors.
/// Returns an NSArray where index i = all values with prefix i, joined by spaces.
static NSArray<NSString *> *decodeFields(NSString *raw, int fieldCount) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:fieldCount];
    for (int i = 0; i < fieldCount; i++) [result addObject:@""];

    if (!raw.length) return result;

    // Works on UTF-16 units, not UTF-8 bytes, so non-ASCII delimiters survive.
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSUInteger len = raw.length;
    __block NSUInteger valStart = 0;
    __block int curField = -1;

    void (^flush)(NSUInteger) = ^(NSUInteger end) {
        if (curField < 0 || curField >= fieldCount) return;
        NSString *trimmed = [[raw substringWithRange:NSMakeRange(valStart, end - valStart)]
                             stringByTrimmingCharactersInSet:ws];
        if (!trimmed.length) return;
        if (((NSString *)result[curField]).length)
            result[curField] = [NSString stringWithFormat:@"%@ %@", result[curField], trimmed];
        else
            result[curField] = trimmed;
    };

    for (NSUInteger i = 0; i + 1 < len; i++) {
        // A 2-digit prefix at a word boundary (start or after whitespace)
        BOOL atBoundary = (i == 0) || [ws characterIsMember:[raw characterAtIndex:i - 1]];
        unichar c0 = [raw characterAtIndex:i], c1 = [raw characterAtIndex:i + 1];
        if (!atBoundary || c0 < '0' || c0 > '9' || c1 < '0' || c1 > '9') continue;
        int newField = (c0 - '0') * 10 + (c1 - '0');
        if (newField >= fieldCount) continue;
        flush(i);
        curField = newField;
        i += 1;              // skip the 2-digit prefix
        valStart = i + 1;
    }
    flush(len);
    return result;
}

/// Encode an array of field values back into prefix-encoded format.
/// Inverse of decodeFields. Port of Windows CommentStyleDialog::convertTo:
/// every word gets its field prefix ("03``` 03` 03~~~") except inside a
/// "((...))" group, and an empty slot emits the bare prefix ("01 02").
/// LexUser's GenerateVector only reads prefixed words, so a field like
/// "![ [" must be written "00![ 00[" or its second word is lost.
static NSString *encodeFields(NSArray<NSString *> *fields) {
    NSMutableString *out = [NSMutableString string];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (int i = 0; i < (int)fields.count; i++) {
        NSString *prefix = [NSString stringWithFormat:@"%02d", i];
        if (out.length) [out appendString:@" "];
        [out appendString:prefix];
        BOOL first = YES, inGroup = NO;
        for (NSString *w in [fields[i] componentsSeparatedByCharactersInSet:ws]) {
            if (!w.length) continue;
            if (!first) {
                [out appendString:@" "];
                if (!inGroup) [out appendString:prefix];
            }
            [out appendString:w];
            if (!inGroup && [w hasPrefix:@"(("]) inGroup = YES;
            if (inGroup && [w hasSuffix:@"))"]) inGroup = NO;
            first = NO;
        }
    }
    return out;
}

#pragma mark — Data loading

- (void)_rebuildPopup {
    [_langPopup removeAllItems];
    [_langPopup addItemWithTitle:@"User Defined Language"];
    for (UserDefinedLang *u in [UserDefineLangManager shared].allLanguages)
        [_langPopup addItemWithTitle:u.name];
}
- (void)_langChanged:(id)s {
    // _cur is still the previously selected UDL: save its edits before
    // the form is refilled with the new one. If that fails, stay on it so
    // the edits are not discarded.
    if (![self _commitEdits]) {
        if (_cur.name) [_langPopup selectItemWithTitle:_cur.name];
        return;
    }
    [self _load];
}
- (void)_load {
    _cur = [[UserDefineLangManager shared] languageNamed:_langPopup.selectedItem.title];
    _stylesDirty = NO;
    if (_cur) [self _fill];
    _snapshot = _cur ? [self _formState] : nil;
}
- (void)_fill {
    UserDefinedLang *L = _cur; NSDictionary *kw = L.keywordLists;
    _extField.stringValue = L.extensions ?: @"";
    _ignoreCaseCheck.state = L.caseIgnored ? NSControlStateValueOn : NSControlStateValueOff;
    _foldCompactCheck.state = L.foldCompact ? NSControlStateValueOn : NSControlStateValueOff;
    _foldCmtCheck.state = L.allowFoldOfComments ? NSControlStateValueOn : NSControlStateValueOff;
    _radioAny.state = (L.forcePureLC==0) ? NSControlStateValueOn : NSControlStateValueOff;
    _radioBOL.state = (L.forcePureLC==1) ? NSControlStateValueOn : NSControlStateValueOff;
    _radioWS.state  = (L.forcePureLC==2) ? NSControlStateValueOn : NSControlStateValueOff;
    _decDot.state   = (L.decimalSeparator==0) ? NSControlStateValueOn : NSControlStateValueOff;
    _decComma.state = (L.decimalSeparator==1) ? NSControlStateValueOn : NSControlStateValueOff;
    _decBoth.state  = (L.decimalSeparator==2) ? NSControlStateValueOn : NSControlStateValueOff;

    NSArray *kn = @[@"Keywords1",@"Keywords2",@"Keywords3",@"Keywords4",@"Keywords5",@"Keywords6",@"Keywords7",@"Keywords8"];
    for (int i=0;i<8;i++) {
        setText(_kwArea[i], kw[kn[i]]);
        _kwPfx[i].state = (i<(int)L.isPrefix.count && L.isPrefix[i].boolValue) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    setText(_c1Open, kw[@"Folders in code1, open"]); setText(_c1Mid, kw[@"Folders in code1, middle"]); setText(_c1Close, kw[@"Folders in code1, close"]);
    setText(_c2Open, kw[@"Folders in code2, open"]); setText(_c2Mid, kw[@"Folders in code2, middle"]); setText(_c2Close, kw[@"Folders in code2, close"]);
    setText(_cfOpen, kw[@"Folders in comment, open"]); setText(_cfMid, kw[@"Folders in comment, middle"]); setText(_cfClose, kw[@"Folders in comment, close"]);
    // Decode Comments: 00=lineOpen, 01=lineContinue, 02=lineClose, 03=blockOpen, 04=blockClose
    NSArray *cmtFields = decodeFields(kw[@"Comments"], 5);
    setText(_clOpen, cmtFields[0]);
    setText(_clCont, cmtFields[1]);
    setText(_clClose, cmtFields[2]);
    setText(_bcOpen, cmtFields[3]);
    setText(_bcClose, cmtFields[4]);
    setText(_nP1, kw[@"Numbers, prefix1"]); setText(_nP2, kw[@"Numbers, prefix2"]);
    setText(_nE1, kw[@"Numbers, extras1"]); setText(_nE2, kw[@"Numbers, extras2"]);
    setText(_nS1, kw[@"Numbers, suffix1"]); setText(_nS2, kw[@"Numbers, suffix2"]);
    setText(_nR, kw[@"Numbers, range"]);
    setText(_op1, kw[@"Operators1"]); setText(_op2, kw[@"Operators2"]);
    // Decode Delimiters: 24 fields (8 delimiters × 3: open/escape/close)
    // Delimiter 1: 00=open, 01=escape, 02=close
    // Delimiter 2: 03=open, 04=escape, 05=close ... Delimiter 8: 21=open, 22=escape, 23=close
    NSArray *delimFields = decodeFields(kw[@"Delimiters"], 24);
    for (int i = 0; i < 8; i++) {
        setText(_dO[i], delimFields[i * 3]);
        setText(_dE[i], delimFields[i * 3 + 1]);
        setText(_dC[i], delimFields[i * 3 + 2]);
    }
}

#pragma mark — In-place XML patching

// UDL files are patched as raw text rather than re-serialised through
// NSXMLDocument, so comments, the prolog, indentation and entity forms such
// as &#x000D;&#x000A; survive (be64746). Every edit is scoped to the one
// <UserLang name="..."> block being saved, so a multi-language container
// (legacy userDefineLang.xml) only has that block touched.

/// XML-escape a string for safe embedding in element content.
static NSString *xmlEscape(NSString *s) {
    NSMutableString *r = [s mutableCopy];
    [r replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, r.length)];
    [r replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, r.length)];
    [r replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, r.length)];
    return r;
}

/// XML-escape a string for an attribute value. Both quote characters are
/// escaped, so the result is safe whichever quote the existing attribute
/// uses (name='Bob&apos;s', not name='Bob's').
static NSString *xmlAttrEscape(NSString *s) {
    return [[xmlEscape(s ?: @"") stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"]
            stringByReplacingOccurrencesOfString:@"'" withString:@"&apos;"];
}

/// Decode the predefined and numeric entity references in raw XML text.
static NSString *xmlUnescape(NSString *s) {
    if ([s rangeOfString:@"&"].location == NSNotFound) return s;
    NSMutableString *r = [NSMutableString string];
    NSUInteger i = 0, n = s.length;
    while (i < n) {
        unichar c = [s characterAtIndex:i];
        if (c == '&') {
            NSRange semi = [s rangeOfString:@";" options:0 range:NSMakeRange(i, MIN(n - i, (NSUInteger)12))];
            if (semi.location != NSNotFound) {
                NSString *ent = [s substringWithRange:NSMakeRange(i + 1, semi.location - i - 1)];
                NSString *rep = @{@"lt":@"<", @"gt":@">", @"amp":@"&", @"quot":@"\"", @"apos":@"'"}[ent];
                if (!rep && [ent hasPrefix:@"#"] && ent.length > 1) {
                    unsigned int v = 0;
                    if ([ent characterAtIndex:1] == 'x' || [ent characterAtIndex:1] == 'X')
                        [[NSScanner scannerWithString:[ent substringFromIndex:2]] scanHexInt:&v];
                    else
                        v = (unsigned int)[ent substringFromIndex:1].intValue;
                    if (v) rep = [[NSString alloc] initWithBytes:&v length:4 encoding:NSUTF32LittleEndianStringEncoding];
                }
                if (rep) { [r appendString:rep]; i = semi.location + 1; continue; }
            }
        }
        [r appendFormat:@"%C", c];
        i++;
    }
    return r;
}

/// Convert newlines in keyword text to &#x000D;&#x000A; entities (Windows NPP format).
static NSString *nlToEntity(NSString *s) {
    NSMutableString *r = [s mutableCopy];
    [r replaceOccurrencesOfString:@"\r\n" withString:@"&#x000D;&#x000A;" options:0 range:NSMakeRange(0, r.length)];
    [r replaceOccurrencesOfString:@"\n" withString:@"&#x000D;&#x000A;" options:0 range:NSMakeRange(0, r.length)];
    [r replaceOccurrencesOfString:@"\r" withString:@"&#x000D;&#x000A;" options:0 range:NSMakeRange(0, r.length)];
    return r;
}

static BOOL isXMLSpace(unichar c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

/// Raw (still escaped) value of `attr` inside the start tag at `tagR`;
/// nil when the tag has no such attribute. `valR` receives its range.
static NSString *attrValue(NSString *x, NSRange tagR, NSString *attr, NSRange *valR) {
    NSString *pat = [NSString stringWithFormat:@"\\s%@\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')",
                     [NSRegularExpression escapedPatternForString:attr]];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:x options:0 range:tagR];
    if (!m) return nil;
    NSRange vr = [m rangeAtIndex:1];
    if (vr.location == NSNotFound) vr = [m rangeAtIndex:2];
    if (valR) *valR = vr;
    return [x substringWithRange:vr];
}

static BOOL hasAt(NSString *x, NSUInteger loc, NSString *s) {
    return loc + s.length <= x.length &&
           [x compare:s options:NSLiteralSearch range:NSMakeRange(loc, s.length)] == NSOrderedSame;
}

/// When a comment, CDATA section, processing instruction or DOCTYPE starts
/// at `loc`, the index just past its end (x.length if unterminated);
/// NSNotFound otherwise. Tag searches skip these spans, so a commented-out
/// <UserLang> or </Keywords> is never matched.
static NSUInteger skipMarkup(NSString *x, NSUInteger loc) {
    NSString *close = hasAt(x, loc, @"<!--") ? @"-->"
                    : hasAt(x, loc, @"<![CDATA[") ? @"]]>"
                    : hasAt(x, loc, @"<?") ? @"?>"
                    : hasAt(x, loc, @"<!") ? @">" : nil;
    if (!close) return NSNotFound;
    NSRange r = [x rangeOfString:close options:NSLiteralSearch range:NSMakeRange(loc + 2, x.length - loc - 2)];
    return r.location == NSNotFound ? x.length : NSMaxRange(r);
}

/// Next `<...` at or after `pos` (before `end`) that is not inside a
/// comment/CDATA/PI; NSNotFound when there is none.
static NSUInteger nextTagOpen(NSString *x, NSUInteger pos, NSUInteger end) {
    while (pos < end) {
        NSRange r = [x rangeOfString:@"<" options:NSLiteralSearch range:NSMakeRange(pos, end - pos)];
        if (r.location == NSNotFound) return NSNotFound;
        NSUInteger skip = skipMarkup(x, r.location);
        if (skip == NSNotFound) return r.location;
        pos = skip;
    }
    return NSNotFound;
}

/// Range of the first start tag `<tag ...>` within `scope` (closing `>`
/// included) whose `attr` decodes to `val`, or the first one at all when
/// `attr` is nil. location is NSNotFound when there is none.
static NSRange findStartTag(NSString *x, NSString *tag, NSRange scope,
                            NSString *attr, NSString *val, BOOL caseInsensitive) {
    NSString *open = [@"<" stringByAppendingString:tag];
    NSUInteger pos = scope.location, end = MIN(NSMaxRange(scope), x.length);
    while (pos < end) {
        NSUInteger lt = nextTagOpen(x, pos, end);
        if (lt == NSNotFound) break;
        if (!hasAt(x, lt, open)) { pos = lt + 1; continue; }
        NSRange r = NSMakeRange(lt, open.length);
        NSUInteger k = NSMaxRange(r);
        if (k >= x.length) break;
        unichar c = [x characterAtIndex:k];
        if (c != '>' && c != '/' && !isXMLSpace(c)) { pos = k; continue; } // <KeywordLists vs <Keywords
        // Quote-aware scan to the end of the start tag
        unichar q = 0;
        for (; k < x.length; k++) {
            unichar d = [x characterAtIndex:k];
            if (q) { if (d == q) q = 0; }
            else if (d == '"' || d == '\'') q = d;
            else if (d == '>') break;
        }
        if (k >= x.length) break;
        NSRange tagR = NSMakeRange(r.location, k + 1 - r.location);
        if (!attr) return tagR;
        NSString *v = attrValue(x, tagR, attr, NULL);
        if (v) {
            v = xmlUnescape(v);
            if (caseInsensitive ? [v caseInsensitiveCompare:val] == NSOrderedSame : [v isEqualToString:val])
                return tagR;
        }
        pos = NSMaxRange(tagR);
    }
    return NSMakeRange(NSNotFound, 0);
}

/// Like findStartTag but returns the LAST match. Used for <UserLang>:
/// UserDefineLangManager keeps the last block when a file repeats a
/// name, so the writer must patch that same one.
static NSRange findLastStartTag(NSString *x, NSString *tag, NSString *attr, NSString *val) {
    NSRange last = NSMakeRange(NSNotFound, 0);
    for (NSRange r = findStartTag(x, tag, NSMakeRange(0, x.length), attr, val, NO);
         r.location != NSNotFound;
         r = findStartTag(x, tag, NSMakeRange(NSMaxRange(r), x.length - NSMaxRange(r)), attr, val, NO))
        last = r;
    return last;
}

/// Set `attr` on the start tag at `tagR` (inserting it when missing). An
/// attribute that already decodes to `value` is left byte-for-byte alone.
static void setAttr(NSMutableString *x, NSRange tagR, NSString *attr, NSString *value) {
    if (tagR.location == NSNotFound) return;
    NSRange vr;
    NSString *cur = attrValue(x, tagR, attr, &vr);
    if (cur) {
        if (![xmlUnescape(cur) isEqualToString:value])
            [x replaceCharactersInRange:vr withString:xmlAttrEscape(value)];
        return;
    }
    NSUInteger ins = NSMaxRange(tagR) - 1;                       // at '>'
    if (ins > tagR.location && [x characterAtIndex:ins - 1] == '/') ins--;
    while (ins > tagR.location && isXMLSpace([x characterAtIndex:ins - 1])) ins--;
    [x insertString:[NSString stringWithFormat:@" %@=\"%@\"", attr, xmlAttrEscape(value)] atIndex:ins];
}

/// Content range of the element whose start tag is at `tagR`. A
/// self-closing element is first expanded to <tag ...></tag>.
static NSRange elementContent(NSMutableString *x, NSRange tagR, NSString *tag) {
    if (tagR.location == NSNotFound) return tagR;
    NSUInteger gt = NSMaxRange(tagR) - 1;
    if (gt > tagR.location && [x characterAtIndex:gt - 1] == '/') {
        NSUInteger from = gt - 1;   // "/>", plus any whitespace before it
        while (from > tagR.location && isXMLSpace([x characterAtIndex:from - 1])) from--;
        [x replaceCharactersInRange:NSMakeRange(from, gt + 1 - from)
                         withString:[NSString stringWithFormat:@"></%@>", tag]];
        return NSMakeRange(from + 1, 0);
    }
    NSUInteger start = NSMaxRange(tagR);
    NSString *close = [NSString stringWithFormat:@"</%@>", tag];
    for (NSUInteger pos = start, lt; (lt = nextTagOpen(x, pos, x.length)) != NSNotFound; pos = lt + 1)
        if (hasAt(x, lt, close)) return NSMakeRange(start, lt - start);
    return NSMakeRange(NSNotFound, 0);
}

/// Start tag of the `<tag attr="val">` child inside `parent` (a content
/// range), appended as an empty element when missing. When the parent's
/// closing tag sits on its own line the new child gets its own line,
/// indented one level deeper.
static NSRange ensureChild(NSMutableString *x, NSRange parent, NSString *tag,
                           NSString *attr, NSString *val, BOOL caseInsensitive) {
    if (parent.location == NSNotFound) return parent;
    NSRange r = findStartTag(x, tag, parent, attr, val, caseInsensitive);
    if (r.location != NSNotFound) return r;

    NSString *elem = attr
        ? [NSString stringWithFormat:@"<%@ %@=\"%@\" />", tag, attr, xmlAttrEscape(val)]
        : [NSString stringWithFormat:@"<%@ />", tag];
    NSUInteger end = NSMaxRange(parent), ls = end;
    while (ls > parent.location && ([x characterAtIndex:ls - 1] == ' ' || [x characterAtIndex:ls - 1] == '\t')) ls--;
    if (ls > parent.location && [x characterAtIndex:ls - 1] == '\n') {
        NSString *nl = [x rangeOfString:@"\r\n"].location != NSNotFound ? @"\r\n" : @"\n";
        NSString *indent = [x substringWithRange:NSMakeRange(ls, end - ls)];
        [x insertString:[NSString stringWithFormat:@"%@    %@%@", indent, elem, nl] atIndex:ls];
        return NSMakeRange(ls + indent.length + 4, elem.length);
    }
    [x insertString:elem atIndex:end];
    return NSMakeRange(end, elem.length);
}

/// Apply `u` to the raw text of a UDL file, editing only the
/// <UserLang name="matchName"> block: UserLang name/ext, Settings/Global,
/// Settings/Prefix, the Keywords lists in `kwChanges` (raw text, replaced
/// whole) and every WordsStyle attribute in u.styles. Anything the dialog
/// does not edit (udlVersion, darkModeTheme, unknown attributes, comments)
/// is kept as is. Returns nil when the block is not found.
static NSString *UDLPatchedXML(NSString *xml, NSString *matchName, UserDefinedLang *u,
                               NSDictionary<NSString *, NSString *> *kwChanges) {
    NSMutableString *x = [xml mutableCopy];
    // Ranges move with every edit, so each step re-locates from the top.
    NSRange (^langTag)(void) = ^NSRange { return findLastStartTag(x, @"UserLang", @"name", matchName); };
    if (langTag().location == NSNotFound) return nil;
    NSRange (^section)(NSString *) = ^NSRange(NSString *tag) {
        NSRange body = elementContent(x, langTag(), @"UserLang");
        return elementContent(x, ensureChild(x, body, tag, nil, nil, NO), tag);
    };
    NSRange (^global)(void) = ^NSRange { return ensureChild(x, section(@"Settings"), @"Global", nil, nil, NO); };
    NSRange (^prefix)(void) = ^NSRange { return ensureChild(x, section(@"Settings"), @"Prefix", nil, nil, NO); };

    setAttr(x, global(), @"caseIgnored",         u.caseIgnored ? @"yes" : @"no");
    setAttr(x, global(), @"allowFoldOfComments", u.allowFoldOfComments ? @"yes" : @"no");
    setAttr(x, global(), @"foldCompact",         u.foldCompact ? @"yes" : @"no");
    setAttr(x, global(), @"forcePureLC",         [@(u.forcePureLC) stringValue]);
    setAttr(x, global(), @"decimalSeparator",    [@(u.decimalSeparator) stringValue]);
    for (int i = 0; i < 8; i++) {
        BOOL pf = i < (int)u.isPrefix.count && u.isPrefix[i].boolValue;
        setAttr(x, prefix(), [NSString stringWithFormat:@"Keywords%d", i + 1], pf ? @"yes" : @"no");
    }

    for (NSString *name in [kwChanges.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSRange t = ensureChild(x, section(@"KeywordLists"), @"Keywords", @"name", name, NO);
        NSRange c = elementContent(x, t, @"Keywords");
        if (c.location != NSNotFound)
            [x replaceCharactersInRange:c withString:nlToEntity(xmlEscape(kwChanges[name]))];
    }

    // Known WordsStyle attributes in Windows order, then any others.
    NSArray *order = @[@"fgColor", @"bgColor", @"colorStyle", @"fontName", @"fontStyle", @"fontSize", @"nesting"];
    for (NSDictionary *style in u.styles) {
        NSString *sn = style[@"name"];
        if (!sn.length) continue;
        NSMutableArray *keys = [NSMutableArray array];
        for (NSString *k in order) if (style[k]) [keys addObject:k];
        for (NSString *k in [style.allKeys sortedArrayUsingSelector:@selector(compare:)])
            if (![k isEqualToString:@"name"] && ![order containsObject:k]) [keys addObject:k];
        for (NSString *k in keys) {
            NSRange t = ensureChild(x, section(@"Styles"), @"WordsStyle", @"name", sn, YES);
            setAttr(x, t, k, [style[k] description]);
        }
    }

    // The block is located by its old name, so the name goes last.
    setAttr(x, langTag(), @"ext", u.extensions ?: @"");
    setAttr(x, langTag(), @"name", u.name);
    return x;
}

/// Text for a new standalone file holding just the `name` block of `xml`.
/// A single-language file is kept whole so its header comment survives.
/// The caller writes the result as UTF-8 (see UDLEncodedData).
static NSString *UDLStandaloneXML(NSString *xml, NSString *name) {
    NSMutableString *x = [xml mutableCopy];
    NSUInteger count = 0;
    for (NSRange r = findStartTag(x, @"UserLang", NSMakeRange(0, x.length), nil, nil, NO);
         r.location != NSNotFound;
         r = findStartTag(x, @"UserLang", NSMakeRange(NSMaxRange(r), x.length - NSMaxRange(r)), nil, nil, NO))
        count++;
    if (count <= 1) return xml;
    NSRange t = findLastStartTag(x, @"UserLang", @"name", name);
    NSRange c = elementContent(x, t, @"UserLang");
    if (c.location == NSNotFound) return nil;
    NSUInteger end = NSMaxRange(c) + @"</UserLang>".length;
    return [NSString stringWithFormat:@"<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<NotepadPlus>\n    %@\n</NotepadPlus>\n",
            [x substringWithRange:NSMakeRange(t.location, end - t.location)]];
}

#pragma mark — File encoding

// Files are read and written in the encoding their <?xml encoding="..."?>
// declaration names (UTF-8 when there is none), which is what NSXMLDocument
// uses when UserDefineLangManager loads them.

/// Range of the encoding name inside a leading <?xml ...?> declaration.
static NSRange xmlDeclEncodingRange(NSString *s) {
    NSRange head = NSMakeRange(0, MIN(s.length, (NSUInteger)512));
    NSRange decl = [s rangeOfString:@"<?xml" options:NSLiteralSearch range:head];
    if (decl.location == NSNotFound || decl.location > 8) return NSMakeRange(NSNotFound, 0); // BOM at most
    NSRange endR = [s rangeOfString:@"?>" options:NSLiteralSearch range:NSMakeRange(decl.location, NSMaxRange(head) - decl.location)];
    if (endR.location == NSNotFound) return endR;
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"\\sencoding\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0
                                               range:NSMakeRange(decl.location, endR.location - decl.location)];
    if (!m) return NSMakeRange(NSNotFound, 0);
    NSRange vr = [m rangeAtIndex:1];
    return vr.location != NSNotFound ? vr : [m rangeAtIndex:2];
}

/// The encoding `data` declares: UTF-16 in the byte order of its BOM when
/// it has one, else the <?xml encoding="..."?> name, else UTF-8. The BOM's
/// order is returned explicitly (not NSUTF16StringEncoding, which writes
/// host order) so a big-endian file is written back big-endian; the BOM is
/// then kept in the decoded text as U+FEFF and written back unchanged.
static NSStringEncoding UDLDeclaredEncoding(NSData *data) {
    const unsigned char *b = (const unsigned char *)data.bytes;
    if (data.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) return NSUTF16BigEndianStringEncoding;
    if (data.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) return NSUTF16LittleEndianStringEncoding;
    // Latin-1 maps every byte, so the ASCII prolog is readable whatever follows.
    NSString *head = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, MIN(data.length, (NSUInteger)512))]
                                           encoding:NSISOLatin1StringEncoding];
    NSRange r = xmlDeclEncodingRange(head);
    if (r.location == NSNotFound) return NSUTF8StringEncoding;
    CFStringEncoding cf = CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)[head substringWithRange:r]);
    if (cf == kCFStringEncodingInvalidId) return NSUTF8StringEncoding;
    NSStringEncoding enc = CFStringConvertEncodingToNSStringEncoding(cf);
    return enc == kCFStringEncodingInvalidId ? NSUTF8StringEncoding : enc;
}

static BOOL isUnicodeEncoding(NSStringEncoding enc) {
    return enc == NSUTF8StringEncoding || enc == NSUTF16StringEncoding ||
           enc == NSUTF16LittleEndianStringEncoding || enc == NSUTF16BigEndianStringEncoding;
}

/// `s` with every character `enc` cannot hold written as a &#xNNNN;
/// reference. Only edited values can contain such characters (the rest of
/// the text was decoded from `enc`), and references are valid there.
static NSString *encodableText(NSString *s, NSStringEncoding enc) {
    if ([s canBeConvertedToEncoding:enc]) return s;
    NSMutableString *r = [NSMutableString stringWithCapacity:s.length];
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length)
                          options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *ch, NSRange sr, NSRange er, BOOL *stop) {
        if ([ch canBeConvertedToEncoding:enc]) { [r appendString:ch]; return; }
        NSData *u32 = [ch dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
        const uint32_t *cp = (const uint32_t *)u32.bytes;
        for (NSUInteger i = 0; i < u32.length / 4; i++) {
            NSString *one = [[NSString alloc] initWithBytes:&cp[i] length:4 encoding:NSUTF32LittleEndianStringEncoding];
            if ([one canBeConvertedToEncoding:enc]) [r appendString:one];
            else [r appendFormat:@"&#x%X;", cp[i]];
        }
    }];
    return r;
}

/// `text` with its <?xml encoding="..."?> (if any) naming UTF-8.
static NSString *UDLWithUTF8Declaration(NSString *text) {
    NSRange r = xmlDeclEncodingRange(text);
    if (r.location == NSNotFound || [[text substringWithRange:r] caseInsensitiveCompare:@"UTF-8"] == NSOrderedSame)
        return text;
    return [text stringByReplacingCharactersInRange:r withString:@"UTF-8"];
}

/// Bytes for `text` in `enc`. Characters `enc` lacks become numeric
/// references; should that still fail, the text is written as UTF-8 and
/// its declaration rewritten to match, so the bytes never contradict it.
static NSData *UDLEncodedData(NSString *text, NSStringEncoding enc) {
    NSData *d = nil;
    if (!isUnicodeEncoding(enc)) d = [encodableText(text, enc) dataUsingEncoding:enc allowLossyConversion:NO];
    else d = [text dataUsingEncoding:enc allowLossyConversion:NO];
    if (d) return d;
    return [UDLWithUTF8Declaration(text) dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark — File locations

/// `p` with symlinks resolved, so a bundle or user-dir prefix check holds
/// whether paths come via /tmp or /private/tmp, and a symlinked UDL file
/// is written through to its target instead of being replaced.
static NSString *resolvedPath(NSString *p) {
    return [NSURL fileURLWithPath:p].URLByResolvingSymlinksInPath.path ?: p;
}

static BOOL pathIsInside(NSString *p, NSString *dir) {
    NSString *d = resolvedPath(dir);
    if (![d hasSuffix:@"/"]) d = [d stringByAppendingString:@"/"];
    return [resolvedPath(p) hasPrefix:d];
}

/// YES for the read-only UDLs shipped inside the app bundle: edits to those
/// are written to a copy in the user userDefineLangs dir, which overrides
/// the bundled file by name on the next loadAll.
static BOOL isBundledUDLPath(NSString *p) {
    return p.length && pathIsInside(p, NSBundle.mainBundle.bundlePath);
}

#pragma mark — Save current form state back to XML

/// Plain (unprefixed) keyword lists and the text views that edit them.
- (NSDictionary<NSString *, NSScrollView *> *)_plainListViews {
    NSMutableDictionary *m = [@{
        @"Numbers, prefix1": _nP1, @"Numbers, prefix2": _nP2,
        @"Numbers, extras1": _nE1, @"Numbers, extras2": _nE2,
        @"Numbers, suffix1": _nS1, @"Numbers, suffix2": _nS2, @"Numbers, range": _nR,
        @"Operators1": _op1, @"Operators2": _op2,
        @"Folders in code1, open": _c1Open, @"Folders in code1, middle": _c1Mid, @"Folders in code1, close": _c1Close,
        @"Folders in code2, open": _c2Open, @"Folders in code2, middle": _c2Mid, @"Folders in code2, close": _c2Close,
        @"Folders in comment, open": _cfOpen, @"Folders in comment, middle": _cfMid, @"Folders in comment, close": _cfClose,
    } mutableCopy];
    for (int i = 0; i < 8; i++) m[[NSString stringWithFormat:@"Keywords%d", i + 1]] = _kwArea[i];
    return m;
}

/// Every editable control's value. Plain lists are keyed by their
/// Keywords name; the prefix-encoded Comments/Delimiters lists are kept as
/// their decoded field arrays so an untouched list is never re-encoded.
- (NSDictionary *)_formState {
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    s[@"ext"] = [_extField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";
    s[@"caseIgnored"] = @(_ignoreCaseCheck.state == NSControlStateValueOn);
    s[@"foldCompact"] = @(_foldCompactCheck.state == NSControlStateValueOn);
    s[@"allowFoldOfComments"] = @(_foldCmtCheck.state == NSControlStateValueOn);
    s[@"forcePureLC"] = @((_radioBOL.state == NSControlStateValueOn) ? 1 : (_radioWS.state == NSControlStateValueOn) ? 2 : 0);
    s[@"decimalSeparator"] = @((_decComma.state == NSControlStateValueOn) ? 1 : (_decBoth.state == NSControlStateValueOn) ? 2 : 0);
    NSMutableArray *pfx = [NSMutableArray array];
    for (int i = 0; i < 8; i++) [pfx addObject:@(_kwPfx[i].state == NSControlStateValueOn)];
    s[@"prefix"] = pfx;

    NSDictionary *views = [self _plainListViews];
    for (NSString *k in views) s[k] = getText(views[k]);
    s[@"Comments"] = @[getText(_clOpen), getText(_clCont), getText(_clClose), getText(_bcOpen), getText(_bcClose)];
    NSMutableArray *d = [NSMutableArray arrayWithCapacity:24];
    for (int i = 0; i < 8; i++) { [d addObject:getText(_dO[i])]; [d addObject:getText(_dE[i])]; [d addObject:getText(_dC[i])]; }
    s[@"Delimiters"] = d;
    return s;
}

/// A new UDL object holding _cur with the form state `st` applied and the
/// name `name`. `outKw` receives the keyword lists that changed since the
/// last load/save, already encoded for disk; only those are rewritten.
- (UserDefinedLang *)_editedLangNamed:(NSString *)name state:(NSDictionary *)st
                       keywordChanges:(NSDictionary<NSString *, NSString *> **)outKw {
    UserDefinedLang *u = [[UserDefinedLang alloc] init];
    u.name = name;
    u.extensions = st[@"ext"];
    u.caseIgnored = [st[@"caseIgnored"] boolValue];
    u.foldCompact = [st[@"foldCompact"] boolValue];
    u.allowFoldOfComments = [st[@"allowFoldOfComments"] boolValue];
    u.forcePureLC = [st[@"forcePureLC"] intValue];
    u.decimalSeparator = [st[@"decimalSeparator"] intValue];
    u.isPrefix = st[@"prefix"];
    u.isDarkModeTheme = _cur.isDarkModeTheme;
    u.xmlPath = _cur.xmlPath;
    u.styles = _cur.styles ?: @[];

    NSMutableDictionary *changes = [NSMutableDictionary dictionary];
    for (NSString *k in [self _plainListViews])
        if (![st[k] isEqual:_snapshot[k]]) changes[k] = st[k];
    for (NSString *k in @[@"Comments", @"Delimiters"])
        if (![st[k] isEqual:_snapshot[k]]) changes[k] = encodeFields(st[k]);
    NSMutableDictionary *kw = [_cur.keywordLists mutableCopy] ?: [NSMutableDictionary dictionary];
    [kw addEntriesFromDictionary:changes];
    u.keywordLists = kw;
    if (outKw) *outKw = changes;
    return u;
}

/// Write `u` into `dest`, starting from the text of `src` and patching the
/// block currently named `matchName`. In place, the file keeps the encoding
/// its declaration names; a new file is standalone UTF-8. Tells the user
/// and returns NO on failure.
- (BOOL)_writeLang:(UserDefinedLang *)u matching:(NSString *)matchName
    keywordChanges:(NSDictionary *)kw from:(NSString *)src to:(NSString *)dest {
    NSData *data = src ? [NSData dataWithContentsOfFile:src] : nil;
    NSStringEncoding enc = data ? UDLDeclaredEncoding(data) : NSUTF8StringEncoding;
    NSString *text = data ? [[NSString alloc] initWithData:data encoding:enc] : nil;
    if (data && !text) {
        // Bytes contradict the declaration: an undeclared ANSI file from
        // Windows NPP. Read it as Windows-1252 and write valid UTF-8.
        text = [[NSString alloc] initWithData:data encoding:NSWindowsCP1252StringEncoding];
        enc = NSUTF8StringEncoding;
    }
    if (text && ![dest isEqualToString:resolvedPath(src)]) {
        text = UDLStandaloneXML(text, matchName);
        enc = NSUTF8StringEncoding;
    }
    NSString *out = text ? UDLPatchedXML(text, matchName, u, kw) : nil;
    if (out && enc == NSUTF8StringEncoding) out = UDLWithUTF8Declaration(out);
    NSData *bytes = out ? UDLEncodedData(out, enc) : nil;

    NSError *err = nil;
    BOOL ok = bytes && [bytes writeToFile:dest options:NSDataWritingAtomic error:&err];
    if (!ok) {
        NSLog(@"UDL save error (%@ -> %@): %@", src, dest, err);
        [self _alertSaveFailed:u.name detail:err.localizedDescription ?: dest];
    }
    return ok;
}

- (void)_alertSaveFailed:(NSString *)name detail:(NSString *)detail {
    NppLocalizer *loc = [NppLocalizer shared];
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:[loc translate:@"Could not save user defined language: %@"], name];
    a.informativeText = detail;
    [a addButtonWithTitle:[loc translate:@"OK"]];
    [a runModal];
}

/// Where an edit to the UDL file `src` is written: the file itself
/// (through any symlink) when writable, or a new user-dir file named for
/// `nm` when it ships in the app bundle. Any other read-only file is an
/// error (nil, after telling the user): a copy would pile up "Name (N)"
/// files in the user dir, and would not even override the legacy
/// userDefineLang.xml, which loads after the user dir.
- (nullable NSString *)_writeTargetFor:(NSString *)src name:(NSString *)nm {
    if (isBundledUDLPath(src)) return [self _newUserPathForName:nm];
    NSString *real = src.length ? resolvedPath(src) : nil;
    if (real && [[NSFileManager defaultManager] isWritableFileAtPath:real]) return real;
    [self _alertSaveFailed:nm detail:[NSString stringWithFormat:
        [[NppLocalizer shared] translate:@"This file is read-only: %@"], src ?: @""]];
    return nil;
}

/// YES, after telling the user, when `nm` already names a UDL.
- (BOOL)_nameTaken:(NSString *)nm {
    if (![[UserDefineLangManager shared] languageNamed:nm]) return NO;
    NppLocalizer *loc = [NppLocalizer shared];
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:
        [loc translate:@"A user defined language with this name already exists: %@"], nm];
    [a addButtonWithTitle:[loc translate:@"OK"]];
    [a runModal];
    return YES;
}

/// A fresh file path in the user userDefineLangs dir for a UDL named `nm`.
- (NSString *)_newUserPathForName:(NSString *)nm {
    NSString *base = [[nm stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
                      stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    NSString *dir = [UserDefineLangManager userUDLDirectory];
    NSString *p = [dir stringByAppendingPathComponent:[base stringByAppendingString:@".udl.xml"]];
    for (int i = 2; [[NSFileManager defaultManager] fileExistsAtPath:p]; i++)
        p = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ (%d).udl.xml", base, i]];
    return p;
}

/// Reload every UDL from disk, re-point _cur at `name`, and tell open
/// editors and the Language menu. Editors showing `oldName` (a rename)
/// move to `name`.
- (void)_reloadAndNotify:(NSString *)name oldName:(nullable NSString *)oldName {
    UserDefineLangManager *mgr = [UserDefineLangManager shared];
    [mgr loadAll];
    _cur = name ? [mgr languageNamed:name] : nil;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (name) info[@"name"] = name;
    if (oldName) info[@"oldName"] = oldName;
    [[NSNotificationCenter defaultCenter] postNotificationName:UserDefineLangsDidChangeNotification
                                                        object:self userInfo:info];
}

/// Save the form's edits to the current UDL, if anything changed since it
/// was loaded or last saved, and re-apply it to open editors. Windows NPP
/// applies UDL edits live; here they are committed when the dialog closes,
/// the selected language changes, a Styler edit is confirmed, or before
/// Export / Create / Import. A bundled UDL is never written in place.
- (BOOL)_commitEdits { return [self _commitEditsReloading:YES]; }

/// `reload` NO skips the reload and editor re-apply (used at app quit,
/// where relexing every open buffer would be wasted work).
- (BOOL)_commitEditsReloading:(BOOL)reload {
    if (!_cur) return YES;
    NSDictionary *st = [self _formState];
    if (!_stylesDirty && [st isEqualToDictionary:_snapshot]) return YES;

    NSString *name = _cur.name, *src = _cur.xmlPath;
    NSDictionary *kw = nil;
    UserDefinedLang *u = [self _editedLangNamed:name state:st keywordChanges:&kw];
    NSString *dest = [self _writeTargetFor:src name:name];
    if (!dest || ![self _writeLang:u matching:name keywordChanges:kw from:src to:dest]) return NO;

    _snapshot = st;
    _stylesDirty = NO;
    if (reload) [self _reloadAndNotify:name oldName:nil];
    return YES;
}

/// Called when the window is about to close: save pending edits.
- (void)windowWillClose:(NSNotification *)notification {
    [self _commitEdits];
    // Reload so in-memory Styler state matches what is on disk
    [[UserDefineLangManager shared] loadAll];
    _cur = [[UserDefineLangManager shared] languageNamed:_cur.name ?: @""];
}

#pragma mark — CRUD

- (void)_createNew:(id)s {
    if (![self _commitEdits]) return;   // keep the unsaved edits in the form
    NppLocalizer *loc = [NppLocalizer shared];
    NSAlert *a=[[NSAlert alloc]init]; a.messageText=[loc translate:@"Create New Language"]; a.informativeText=[loc translate:@"Enter a name:"];
    NSTextField *inp=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,250,24)]; inp.placeholderString=[loc translate:@"Language name"];
    a.accessoryView=inp; [a addButtonWithTitle:[loc translate:@"Create"]]; [a addButtonWithTitle:[loc translate:@"Cancel"]].keyEquivalent = @"\033";
    if([a runModal]!=NSAlertFirstButtonReturn)return;
    NSString *nm=[inp.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if(!nm.length||[self _nameTaken:nm])return;
    [self _writeBlank:nm]; [self _reloadAndNotify:nm oldName:nil]; [self _rebuildPopup]; [_langPopup selectItemWithTitle:nm]; [self _load];
}
- (void)_writeBlank:(NSString *)nm {
    NSMutableString *x=[NSMutableString stringWithFormat:@"<NotepadPlus>\n<UserLang name=\"%@\" ext=\"\" udlVersion=\"2.1\">\n<Settings><Global caseIgnored=\"no\" allowFoldOfComments=\"no\" foldCompact=\"no\" forcePureLC=\"0\" decimalSeparator=\"0\"/><Prefix Keywords1=\"no\" Keywords2=\"no\" Keywords3=\"no\" Keywords4=\"no\" Keywords5=\"no\" Keywords6=\"no\" Keywords7=\"no\" Keywords8=\"no\"/></Settings>\n<KeywordLists>\n",xmlAttrEscape(nm)];
    for(NSString *k in @[@"Comments",@"Numbers, prefix1",@"Numbers, prefix2",@"Numbers, extras1",@"Numbers, extras2",@"Numbers, suffix1",@"Numbers, suffix2",@"Numbers, range",@"Operators1",@"Operators2",@"Folders in code1, open",@"Folders in code1, middle",@"Folders in code1, close",@"Folders in code2, open",@"Folders in code2, middle",@"Folders in code2, close",@"Folders in comment, open",@"Folders in comment, middle",@"Folders in comment, close",@"Keywords1",@"Keywords2",@"Keywords3",@"Keywords4",@"Keywords5",@"Keywords6",@"Keywords7",@"Keywords8",@"Delimiters"])
        [x appendFormat:@"<Keywords name=\"%@\"></Keywords>\n",k];
    [x appendString:@"</KeywordLists>\n<Styles>\n"];
    for(NSString *s in @[@"DEFAULT",@"COMMENTS",@"LINE COMMENTS",@"NUMBERS",@"KEYWORDS1",@"KEYWORDS2",@"KEYWORDS3",@"KEYWORDS4",@"KEYWORDS5",@"KEYWORDS6",@"KEYWORDS7",@"KEYWORDS8",@"OPERATORS",@"FOLDER IN CODE1",@"FOLDER IN CODE2",@"FOLDER IN COMMENT",@"DELIMITERS1",@"DELIMITERS2",@"DELIMITERS3",@"DELIMITERS4",@"DELIMITERS5",@"DELIMITERS6",@"DELIMITERS7",@"DELIMITERS8"])
        [x appendFormat:@"<WordsStyle name=\"%@\" fgColor=\"000000\" bgColor=\"FFFFFF\" fontStyle=\"0\"/>\n",s];
    [x appendString:@"</Styles>\n</UserLang>\n</NotepadPlus>\n"];
    [x writeToFile:[self _newUserPathForName:nm] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
/// Write the current UDL, including unsaved form edits, as a new UDL named
/// `nm` in the user dir. The original keeps its last saved state.
- (void)_saveAs:(id)s {
    if(!_cur)return; NppLocalizer *loc = [NppLocalizer shared]; NSAlert *a=[[NSAlert alloc]init]; a.messageText=[loc translate:@"Save As"];
    NSTextField *inp=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,250,24)]; inp.stringValue=_cur.name;
    a.accessoryView=inp; [a addButtonWithTitle:[loc translate:@"Save"]]; [a addButtonWithTitle:[loc translate:@"Cancel"]].keyEquivalent = @"\033";
    if([a runModal]!=NSAlertFirstButtonReturn)return;
    NSString *nm=[inp.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if(!nm.length||[nm isEqualToString:_cur.name]||[self _nameTaken:nm])return;
    NSDictionary *kw = nil;
    UserDefinedLang *u = [self _editedLangNamed:nm state:[self _formState] keywordChanges:&kw];
    if (![self _writeLang:u matching:_cur.name keywordChanges:kw from:_cur.xmlPath to:[self _newUserPathForName:nm]]) return;
    [self _reloadAndNotify:nm oldName:nil]; [self _rebuildPopup]; [_langPopup selectItemWithTitle:nm]; [self _load];
}
- (void)_remove:(id)s {
    if(!_cur)return; NppLocalizer *loc = [NppLocalizer shared]; NSAlert *a=[[NSAlert alloc]init];
    a.messageText=[NSString stringWithFormat:@"%@ \"%@\"?", [loc translate:@"Remove"], _cur.name];
    [a addButtonWithTitle:[loc translate:@"Remove"]]; [a addButtonWithTitle:[loc translate:@"Cancel"]].keyEquivalent = @"\033"; a.buttons.firstObject.hasDestructiveAction=YES;
    if([a runModal]!=NSAlertFirstButtonReturn)return;
    NSString *nm = _cur.name;
    if (![[UserDefineLangManager shared]deleteLanguage:_cur]) return;
    // Reload: removing a user override brings the bundled original back.
    [self _reloadAndNotify:nm oldName:nil]; _cur=nil; [self _rebuildPopup]; [self _load];
}
/// Rename the current UDL, saving unsaved form edits in the same write. A
/// bundled UDL cannot be rewritten: the renamed copy goes to the user dir
/// and the shipped original stays available under its old name.
- (void)_rename:(id)s {
    if(!_cur)return; NppLocalizer *loc = [NppLocalizer shared]; NSAlert *a=[[NSAlert alloc]init]; a.messageText=[loc translate:@"Rename"];
    NSTextField *inp=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,250,24)]; inp.stringValue=_cur.name;
    a.accessoryView=inp; [a addButtonWithTitle:[loc translate:@"Rename"]]; [a addButtonWithTitle:[loc translate:@"Cancel"]].keyEquivalent = @"\033";
    if([a runModal]!=NSAlertFirstButtonReturn)return;
    NSString *nm=[inp.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if(!nm.length||[nm isEqualToString:_cur.name]||[self _nameTaken:nm])return;
    NSString *old = _cur.name, *src = _cur.xmlPath;
    NSDictionary *kw = nil;
    UserDefinedLang *u = [self _editedLangNamed:nm state:[self _formState] keywordChanges:&kw];
    NSString *dest = [self _writeTargetFor:src name:nm];
    if (!dest || ![self _writeLang:u matching:old keywordChanges:kw from:src to:dest]) return;
    [self _reloadAndNotify:nm oldName:old]; [self _rebuildPopup]; [_langPopup selectItemWithTitle:nm]; [self _load];
}
- (void)_import:(id)s {
    if (![self _commitEdits]) return;   // keep the unsaved edits in the form
    NSOpenPanel *p=[NSOpenPanel openPanel]; p.allowedContentTypes=@[[UTType typeWithFilenameExtension:@"xml"]];
    if([p runModal]!=NSModalResponseOK)return;
    UserDefinedLang *u=[[UserDefineLangManager shared]importFromPath:p.URL.path];
    if(u){NSString *nm=u.name; [self _reloadAndNotify:nm oldName:nil]; [self _rebuildPopup];[_langPopup selectItemWithTitle:nm];[self _load];}
}
- (void)_export:(id)s {
    // Export copies the file on disk, so save pending edits into it first.
    if(!_cur||![self _commitEdits])return; NSSavePanel *p=[NSSavePanel savePanel]; p.allowedContentTypes=@[[UTType typeWithFilenameExtension:@"xml"]];
    p.nameFieldStringValue=[NSString stringWithFormat:@"%@.udl.xml",_cur.name];
    if([p runModal]==NSModalResponseOK)[[UserDefineLangManager shared]exportLanguage:_cur toPath:p.URL.path];
}

@end
