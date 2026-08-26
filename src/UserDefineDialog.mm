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
    }
    return self;
}

- (void)showWithLanguage:(nullable NSString *)n {
    [self showWindow:nil]; [self _rebuildPopup];
    if (n) [_langPopup selectItemWithTitle:n];
    [self _load];
}

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

    if (!targetStyle) {
        targetStyle = [@{@"name":styleName, @"fgColor":@"000000",
                          @"bgColor":@"FFFFFF", @"fontStyle":@"0"} mutableCopy];
    }

    [UDLStylerDialog runForStyle:targetStyle enableNesting:enableNesting parentWindow:self.window];
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

    const char *s = raw.UTF8String;
    size_t len = strlen(s);
    int curField = -1;
    NSMutableString *curVal = [NSMutableString string];

    size_t i = 0;
    while (i < len) {
        // Check for a 2-digit prefix at a word boundary (start or after space)
        BOOL atBoundary = (i == 0) || (s[i - 1] == ' ');
        if (atBoundary && i + 1 < len && s[i] >= '0' && s[i] <= '9' && s[i+1] >= '0' && s[i+1] <= '9') {
            int newField = (s[i] - '0') * 10 + (s[i+1] - '0');
            if (newField < fieldCount) {
                // Save previous field value
                if (curField >= 0 && curField < fieldCount) {
                    NSString *trimmed = [curVal stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (trimmed.length) {
                        if (((NSString *)result[curField]).length)
                            result[curField] = [NSString stringWithFormat:@"%@ %@", result[curField], trimmed];
                        else
                            result[curField] = trimmed;
                    }
                }
                curField = newField;
                [curVal setString:@""];
                i += 2; // skip the 2-digit prefix
                continue;
            }
        }
        [curVal appendFormat:@"%c", s[i]];
        i++;
    }
    // Save last field
    if (curField >= 0 && curField < fieldCount) {
        NSString *trimmed = [curVal stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length) {
            if (((NSString *)result[curField]).length)
                result[curField] = [NSString stringWithFormat:@"%@ %@", result[curField], trimmed];
            else
                result[curField] = trimmed;
        }
    }
    return result;
}

/// Encode an array of field values back into prefix-encoded format.
/// Inverse of decodeFields. Empty slots emit bare prefix (e.g. "01 02")
/// to preserve the Windows NPP on-disk format.
static NSString *encodeFields(NSArray<NSString *> *fields) {
    NSMutableString *out = [NSMutableString string];
    for (int i = 0; i < (int)fields.count; i++) {
        NSString *val = fields[i];
        if (out.length) [out appendString:@" "];
        [out appendFormat:@"%02d", i];
        if (val.length) [out appendString:val];
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
- (void)_langChanged:(id)s { [self _load]; }
- (void)_load {
    _cur = [[UserDefineLangManager shared] languageNamed:_langPopup.selectedItem.title];
    if (_cur) [self _fill];
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

#pragma mark — Save current form state back to XML

/// Collect all form fields and write the UDL XML file.
/// XML-escape a string for safe embedding in element content.
static NSString *xmlEscape(NSString *s) {
    NSMutableString *r = [s mutableCopy];
    [r replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, r.length)];
    [r replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, r.length)];
    [r replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, r.length)];
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

/// Get text from a scrollview's textview, with newline→entity and XML escaping.
static NSString *getTextEscaped(NSScrollView *sv) {
    NSString *raw = ((NSTextView *)sv.documentView).string ?: @"";
    return xmlEscape(nlToEntity(raw));
}

- (void)_saveToXML {
    if (!_cur || !_cur.xmlPath) return;

    // Read the original file as raw text to preserve comments, prolog, entities, indentation.
    NSString *original = [NSString stringWithContentsOfFile:_cur.xmlPath
                                                  encoding:NSUTF8StringEncoding error:nil];
    if (!original) {
        // Try Windows-1252 for files from Windows NPP
        original = [NSString stringWithContentsOfFile:_cur.xmlPath
                                             encoding:NSWindowsCP1252StringEncoding error:nil];
    }
    if (!original) return;

    NSMutableString *x = [original mutableCopy];

    // Helper: replace content of an XML element found by attribute
    // e.g. <Keywords name="Comments">OLD</Keywords> → <Keywords name="Comments">NEW</Keywords>
    void (^replaceContent)(NSString *tag, NSString *attrName, NSString *attrVal, NSString *newContent) =
        ^(NSString *tag, NSString *attrName, NSString *attrVal, NSString *newContent) {
            // Find opening tag with attribute
            NSString *search = [NSString stringWithFormat:@"%@=\"%@\"", attrName, attrVal];
            NSRange attrRange = [x rangeOfString:search];
            if (attrRange.location == NSNotFound) return;
            // Find the closing > of the opening tag
            NSRange gtRange = [x rangeOfString:@">" options:0
                                         range:NSMakeRange(attrRange.location, x.length - attrRange.location)];
            if (gtRange.location == NSNotFound) return;
            NSUInteger contentStart = gtRange.location + 1;
            // Find the closing tag
            NSString *closeTag = [NSString stringWithFormat:@"</%@>", tag];
            NSRange closeRange = [x rangeOfString:closeTag options:0
                                            range:NSMakeRange(contentStart, x.length - contentStart)];
            if (closeRange.location == NSNotFound) return;
            // Replace content between > and </Tag>
            NSRange contentRange = NSMakeRange(contentStart, closeRange.location - contentStart);
            [x replaceCharactersInRange:contentRange withString:newContent];
        };

    // Helper: set an attribute value on an element
    void (^setAttr)(NSString *elemSearch, NSString *attrName, NSString *attrVal) =
        ^(NSString *elemSearch, NSString *attrName, NSString *attrVal) {
            NSRange elemRange = [x rangeOfString:elemSearch];
            if (elemRange.location == NSNotFound) return;
            // Find the attribute within this element
            NSString *attrSearch = [NSString stringWithFormat:@"%@=\"", attrName];
            NSRange searchArea = NSMakeRange(elemRange.location, MIN((NSUInteger)500, x.length - elemRange.location));
            NSRange attrStart = [x rangeOfString:attrSearch options:0 range:searchArea];
            if (attrStart.location == NSNotFound) return;
            NSUInteger valStart = attrStart.location + attrStart.length;
            NSRange closeQuote = [x rangeOfString:@"\"" options:0
                                            range:NSMakeRange(valStart, x.length - valStart)];
            if (closeQuote.location == NSNotFound) return;
            NSRange valRange = NSMakeRange(valStart, closeQuote.location - valStart);
            [x replaceCharactersInRange:valRange withString:attrVal];
        };

    // ── Update UserLang attributes ──────────────────────────────────────────
    setAttr(@"<UserLang ", @"name", _cur.name);
    setAttr(@"<UserLang ", @"ext", _extField.stringValue ?: @"");

    // ── Update Settings ─────────────────────────────────────────────────────
    BOOL ic = (_ignoreCaseCheck.state == NSControlStateValueOn);
    BOOL fc = (_foldCompactCheck.state == NSControlStateValueOn);
    BOOL afc = (_foldCmtCheck.state == NSControlStateValueOn);
    int lcp = (_radioBOL.state == NSControlStateValueOn) ? 1 : (_radioWS.state == NSControlStateValueOn) ? 2 : 0;
    int dec = (_decComma.state == NSControlStateValueOn) ? 1 : (_decBoth.state == NSControlStateValueOn) ? 2 : 0;

    setAttr(@"<Global ", @"caseIgnored", ic ? @"yes" : @"no");
    setAttr(@"<Global ", @"allowFoldOfComments", afc ? @"yes" : @"no");
    setAttr(@"<Global ", @"foldCompact", fc ? @"yes" : @"no");
    setAttr(@"<Global ", @"forcePureLC", [@(lcp) stringValue]);
    setAttr(@"<Global ", @"decimalSeparator", [@(dec) stringValue]);

    for (int i = 0; i < 8; i++) {
        BOOL pf = (_kwPfx[i].state == NSControlStateValueOn);
        setAttr(@"<Prefix", [NSString stringWithFormat:@"Keywords%d", i+1], pf ? @"yes" : @"no");
    }

    // ── Update KeywordLists (content replacement) ───────────────────────────
    // Comments: encode 5 fields
    NSArray *cmtVals = @[getTextEscaped(_clOpen), getTextEscaped(_clCont), getTextEscaped(_clClose),
                         getTextEscaped(_bcOpen), getTextEscaped(_bcClose)];
    replaceContent(@"Keywords", @"name", @"Comments", encodeFields(cmtVals));

    // Number fields
    NSArray *numNames = @[@"Numbers, prefix1", @"Numbers, prefix2",
                          @"Numbers, extras1", @"Numbers, extras2",
                          @"Numbers, suffix1", @"Numbers, suffix2", @"Numbers, range"];
    NSArray *numFields = @[_nP1, _nP2, _nE1, _nE2, _nS1, _nS2, _nR];
    for (int i = 0; i < 7; i++)
        replaceContent(@"Keywords", @"name", numNames[i], getTextEscaped(numFields[i]));

    // Operators
    replaceContent(@"Keywords", @"name", @"Operators1", getTextEscaped(_op1));
    replaceContent(@"Keywords", @"name", @"Operators2", getTextEscaped(_op2));

    // Folders
    NSArray *foldNames = @[@"Folders in code1, open", @"Folders in code1, middle", @"Folders in code1, close",
                           @"Folders in code2, open", @"Folders in code2, middle", @"Folders in code2, close",
                           @"Folders in comment, open", @"Folders in comment, middle", @"Folders in comment, close"];
    NSArray *foldFields = @[_c1Open, _c1Mid, _c1Close, _c2Open, _c2Mid, _c2Close, _cfOpen, _cfMid, _cfClose];
    for (int i = 0; i < 9; i++)
        replaceContent(@"Keywords", @"name", foldNames[i], getTextEscaped(foldFields[i]));

    // Keywords 1-8
    for (int i = 0; i < 8; i++)
        replaceContent(@"Keywords", @"name",
                       [NSString stringWithFormat:@"Keywords%d", i+1],
                       getTextEscaped(_kwArea[i]));

    // Delimiters: encode 24 fields
    NSMutableArray *delimVals = [NSMutableArray arrayWithCapacity:24];
    for (int i = 0; i < 8; i++) {
        [delimVals addObject:getTextEscaped(_dO[i])];
        [delimVals addObject:getTextEscaped(_dE[i])];
        [delimVals addObject:getTextEscaped(_dC[i])];
    }
    replaceContent(@"Keywords", @"name", @"Delimiters", encodeFields(delimVals));

    // ── Update Styles (attribute-level updates) ─────────────────────────────
    for (NSDictionary *style in _cur.styles) {
        NSString *styleName = style[@"name"];
        if (!styleName) continue;
        NSString *elemSearch = [NSString stringWithFormat:@"name=\"%@\"", styleName];
        for (NSString *key in style) {
            if ([key isEqualToString:@"name"]) continue;
            setAttr(elemSearch, key, style[key]);
        }
    }

    // Write back
    NSError *err;
    [x writeToFile:_cur.xmlPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) NSLog(@"UDL save error: %@", err);
}

/// Called when the window is about to close.
/// No auto-save — user must explicitly use Save or Save As.
- (void)windowWillClose:(NSNotification *)notification {
    // Reload the manager so the lexer picks up any changes saved by the user
    [[UserDefineLangManager shared] loadAll];
}

#pragma mark — CRUD

- (void)_createNew:(id)s {
    NppLocalizer *loc = [NppLocalizer shared];
    NSAlert *a=[[NSAlert alloc]init]; a.messageText=[loc translate:@"Create New Language"]; a.informativeText=[loc translate:@"Enter a name:"];
    NSTextField *inp=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,250,24)]; inp.placeholderString=[loc translate:@"Language name"];
    a.accessoryView=inp; [a addButtonWithTitle:[loc translate:@"Create"]]; [a addButtonWithTitle:[loc translate:@"Cancel"]].keyEquivalent = @"\033";
    if([a runModal]!=NSAlertFirstButtonReturn)return;
    NSString *nm=[inp.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if(!nm.length||[[UserDefineLangManager shared]languageNamed:nm])return;
    [self _writeBlank:nm]; [[UserDefineLangManager shared]loadAll]; [self _rebuildPopup]; [_langPopup selectItemWithTitle:nm]; [self _load];
}
- (void)_writeBlank:(NSString *)nm {
    NSMutableString *x=[NSMutableString stringWithFormat:@"<NotepadPlus>\n<UserLang name=\"%@\" ext=\"\" udlVersion=\"2.1\">\n<Settings><Global caseIgnored=\"no\" allowFoldOfComments=\"no\" foldCompact=\"no\" forcePureLC=\"0\" decimalSeparator=\"0\"/><Prefix Keywords1=\"no\" Keywords2=\"no\" Keywords3=\"no\" Keywords4=\"no\" Keywords5=\"no\" Keywords6=\"no\" Keywords7=\"no\" Keywords8=\"no\"/></Settings>\n<KeywordLists>\n",nm];
    for(NSString *k in @[@"Comments",@"Numbers, prefix1",@"Numbers, prefix2",@"Numbers, extras1",@"Numbers, extras2",@"Numbers, suffix1",@"Numbers, suffix2",@"Numbers, range",@"Operators1",@"Operators2",@"Folders in code1, open",@"Folders in code1, middle",@"Folders in code1, close",@"Folders in code2, open",@"Folders in code2, middle",@"Folders in code2, close",@"Folders in comment, open",@"Folders in comment, middle",@"Folders in comment, close",@"Keywords1",@"Keywords2",@"Keywords3",@"Keywords4",@"Keywords5",@"Keywords6",@"Keywords7",@"Keywords8",@"Delimiters"])
        [x appendFormat:@"<Keywords name=\"%@\"></Keywords>\n",k];
    [x appendString:@"</KeywordLists>\n<Styles>\n"];
    for(NSString *s in @[@"DEFAULT",@"COMMENTS",@"LINE COMMENTS",@"NUMBERS",@"KEYWORDS1",@"KEYWORDS2",@"KEYWORDS3",@"KEYWORDS4",@"KEYWORDS5",@"KEYWORDS6",@"KEYWORDS7",@"KEYWORDS8",@"OPERATORS",@"FOLDER IN CODE1",@"FOLDER IN CODE2",@"FOLDER IN COMMENT",@"DELIMITERS1",@"DELIMITERS2",@"DELIMITERS3",@"DELIMITERS4",@"DELIMITERS5",@"DELIMITERS6",@"DELIMITERS7",@"DELIMITERS8"])
        [x appendFormat:@"<WordsStyle name=\"%@\" fgColor=\"000000\" bgColor=\"FFFFFF\" fontStyle=\"0\"/>\n",s];
    [x appendString:@"</Styles>\n</UserLang>\n</NotepadPlus>\n"];
    NSString *p=[[UserDefineLangManager userUDLDirectory]stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.udl.xml",nm]];
    [x writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
- (void)_saveAs:(id)s {
    if(!_cur)return; NppLocalizer *loc = [NppLocalizer shared]; NSAlert *a=[[NSAlert alloc]init]; a.messageText=[loc translate:@"Save As"];
    NSTextField *inp=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,250,24)]; inp.stringValue=_cur.name;
    a.accessoryView=inp; [a addButtonWithTitle:[loc translate:@"Save"]]; [a addButtonWithTitle:[loc translate:@"Cancel"]].keyEquivalent = @"\033";
    if([a runModal]!=NSAlertFirstButtonReturn)return;
    NSString *nm=[inp.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if(!nm.length||[nm isEqualToString:_cur.name])return;
    NSString *d=[[UserDefineLangManager userUDLDirectory]stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.udl.xml",nm]];
    [[NSFileManager defaultManager]copyItemAtPath:_cur.xmlPath toPath:d error:nil];
    NSString *c=[NSString stringWithContentsOfFile:d encoding:NSUTF8StringEncoding error:nil];
    c=[c stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"name=\"%@\"",_cur.name] withString:[NSString stringWithFormat:@"name=\"%@\"",nm]];
    [c writeToFile:d atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [[UserDefineLangManager shared]loadAll]; [self _rebuildPopup]; [_langPopup selectItemWithTitle:nm]; [self _load];
}
- (void)_remove:(id)s {
    if(!_cur)return; NppLocalizer *loc = [NppLocalizer shared]; NSAlert *a=[[NSAlert alloc]init];
    a.messageText=[NSString stringWithFormat:@"%@ \"%@\"?", [loc translate:@"Remove"], _cur.name];
    [a addButtonWithTitle:[loc translate:@"Remove"]]; [a addButtonWithTitle:[loc translate:@"Cancel"]].keyEquivalent = @"\033"; a.buttons.firstObject.hasDestructiveAction=YES;
    if([a runModal]!=NSAlertFirstButtonReturn)return;
    [[UserDefineLangManager shared]deleteLanguage:_cur]; _cur=nil; [self _rebuildPopup]; [self _load];
}
- (void)_rename:(id)s {
    if(!_cur)return; NppLocalizer *loc = [NppLocalizer shared]; NSAlert *a=[[NSAlert alloc]init]; a.messageText=[loc translate:@"Rename"];
    NSTextField *inp=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,250,24)]; inp.stringValue=_cur.name;
    a.accessoryView=inp; [a addButtonWithTitle:[loc translate:@"Rename"]]; [a addButtonWithTitle:[loc translate:@"Cancel"]].keyEquivalent = @"\033";
    if([a runModal]!=NSAlertFirstButtonReturn)return;
    NSString *nm=[inp.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if(!nm.length||[nm isEqualToString:_cur.name])return;
    NSString *c=[NSString stringWithContentsOfFile:_cur.xmlPath encoding:NSUTF8StringEncoding error:nil];
    c=[c stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"name=\"%@\"",_cur.name] withString:[NSString stringWithFormat:@"name=\"%@\"",nm]];
    [c writeToFile:_cur.xmlPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [[UserDefineLangManager shared]loadAll]; [self _rebuildPopup]; [_langPopup selectItemWithTitle:nm]; [self _load];
}
- (void)_import:(id)s {
    NSOpenPanel *p=[NSOpenPanel openPanel]; p.allowedContentTypes=@[[UTType typeWithFilenameExtension:@"xml"]];
    if([p runModal]!=NSModalResponseOK)return;
    UserDefinedLang *u=[[UserDefineLangManager shared]importFromPath:p.URL.path];
    if(u){[self _rebuildPopup];[_langPopup selectItemWithTitle:u.name];[self _load];}
}
- (void)_export:(id)s {
    if(!_cur)return; NSSavePanel *p=[NSSavePanel savePanel]; p.allowedContentTypes=@[[UTType typeWithFilenameExtension:@"xml"]];
    p.nameFieldStringValue=[NSString stringWithFormat:@"%@.udl.xml",_cur.name];
    if([p runModal]==NSModalResponseOK)[[UserDefineLangManager shared]exportLanguage:_cur toPath:p.URL.path];
}

@end
