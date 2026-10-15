#import "UDLStylerDialog.h"
#import "NppLocalizer.h"

// ── Helper: convert hex "RRGGBB" to NSColor ──────────────────────────────────
static NSColor *colorFromHex(NSString *hex) {
    if (hex.length < 6) return [NSColor blackColor];
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:hex] scanHexInt:&rgb];
    return [NSColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

static NSString *hexFromColor(NSColor *c) {
    NSColor *rgb = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!rgb) rgb = c;
    return [NSString stringWithFormat:@"%02X%02X%02X",
            (int)(rgb.redComponent * 255),
            (int)(rgb.greenComponent * 255),
            (int)(rgb.blueComponent * 255)];
}

// ── Target for OK/Cancel buttons ─────────────────────────────────────────────
@interface _UDLStylerModalHelper : NSObject <NSWindowDelegate>
@property (nonatomic) NSModalResponse response;
@property (nonatomic, weak) NSColorWell *fgWell, *bgWell;
@property (nonatomic, weak) NSButton *fgTrans, *bgTrans;
- (void)okClicked:(id)sender;
- (void)cancelClicked:(id)sender;
- (void)transparentToggled:(id)sender;
@end

@implementation _UDLStylerModalHelper
- (void)okClicked:(id)sender     { _response = NSModalResponseOK;     [NSApp stopModal]; }
- (void)cancelClicked:(id)sender { _response = NSModalResponseCancel; [NSApp stopModal]; }
// A transparent colour is not painted, so its well is disabled (Windows StylerDlg).
- (void)transparentToggled:(id)sender {
    _fgWell.enabled = (_fgTrans.state != NSControlStateValueOn);
    _bgWell.enabled = (_bgTrans.state != NSControlStateValueOn);
}
// Handle the window X (close) button — treat as Cancel
- (BOOL)windowShouldClose:(NSWindow *)sender {
    _response = NSModalResponseCancel;
    [NSApp stopModal];
    return YES;
}
@end

// ═════════════════════════════════════════════════════════════════════════════
@implementation UDLStylerDialog

+ (BOOL)runForStyle:(NSMutableDictionary *)style
      enableNesting:(BOOL)enableNesting
       parentWindow:(NSWindow *)parentWindow {

    NSDictionary *initialStyle = [style copy];
    _UDLStylerModalHelper *helper = [[_UDLStylerModalHelper alloc] init];
    helper.response = NSModalResponseCancel;

    // ── Window ───────────────────────────────────────────────────────────
    CGFloat W = 500, H = enableNesting ? 560 : 260;
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, W, H)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered defer:NO];
    NppLocalizer *loc = [NppLocalizer shared];
    panel.title = [loc translate:@"Styler Dialog"];
    panel.level = NSModalPanelWindowLevel;
    panel.delegate = helper;
    if (parentWindow) {
        NSRect pf = parentWindow.frame;
        NSPoint center = NSMakePoint(NSMidX(pf) - W/2, NSMidY(pf) - H/2);
        [panel setFrameOrigin:center];
    } else {
        [panel center];
    }

    NSView *root = panel.contentView;

    // ── Font Options group ───────────────────────────────────────────────
    NSBox *fontBox = [[NSBox alloc] initWithFrame:NSMakeRect(12, H - 190, W - 24, 175)];
    fontBox.title = [loc translate:@"Font options"]; fontBox.titlePosition = NSAtTop;
    [root addSubview:fontBox];
    NSView *fv = fontBox.contentView;
    CGFloat fvH = 155; // approximate content height

    // Name dropdown
    NSTextField *nameL = [NSTextField labelWithString:[loc translate:@"Name:"]];
    nameL.frame = NSMakeRect(20, fvH - 35, 45, 16);
    [fv addSubview:nameL];

    NSPopUpButton *fontPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(70, fvH - 40, 200, 24) pullsDown:NO];
    fontPop.font = [NSFont systemFontOfSize:11];
    [fontPop addItemWithTitle:@""]; // empty = inherit
    for (NSString *fam in [[NSFontManager sharedFontManager].availableFontFamilies
            sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)])
        [fontPop addItemWithTitle:fam];
    // A stored font the popup does not list (e.g. a Windows font that is
    // not installed) is added as an item, so OK writes it back unchanged.
    NSString *curFont = style[@"fontName"] ?: @"";
    if (curFont.length && ![fontPop itemWithTitle:curFont]) [fontPop insertItemWithTitle:curFont atIndex:1];
    if (curFont.length) [fontPop selectItemWithTitle:curFont];
    [fv addSubview:fontPop];

    // Size dropdown
    NSTextField *sizeL = [NSTextField labelWithString:[loc translate:@"Size:"]];
    sizeL.frame = NSMakeRect(20, fvH - 70, 45, 16);
    [fv addSubview:sizeL];

    NSPopUpButton *sizePop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(70, fvH - 75, 200, 24) pullsDown:NO];
    sizePop.font = [NSFont systemFontOfSize:11];
    for (NSString *s in @[@"",@"5",@"6",@"7",@"8",@"9",@"10",@"11",@"12",@"14",@"16",@"18",@"20",@"22",@"24",@"26",@"28"])
        [sizePop addItemWithTitle:s];
    NSString *curSize = style[@"fontSize"] ?: @"";
    if (curSize.length && ![sizePop itemWithTitle:curSize]) [sizePop insertItemWithTitle:curSize atIndex:1];
    if (curSize.length) [sizePop selectItemWithTitle:curSize];
    [fv addSubview:sizePop];

    // Bold / Italic / Underline
    int fontStyle = [style[@"fontStyle"] intValue];
    NSButton *boldCk = [NSButton checkboxWithTitle:[loc translate:@"Bold"] target:nil action:nil];
    boldCk.frame = NSMakeRect(300, fvH - 30, 80, 18);
    boldCk.state = (fontStyle & 1) ? NSControlStateValueOn : NSControlStateValueOff;
    NSButton *italicCk = [NSButton checkboxWithTitle:[loc translate:@"Italic"] target:nil action:nil];
    italicCk.frame = NSMakeRect(300, fvH - 52, 80, 18);
    italicCk.state = (fontStyle & 2) ? NSControlStateValueOn : NSControlStateValueOff;
    NSButton *underCk = [NSButton checkboxWithTitle:[loc translate:@"Underline"] target:nil action:nil];
    underCk.frame = NSMakeRect(300, fvH - 74, 100, 18);
    underCk.state = (fontStyle & 4) ? NSControlStateValueOn : NSControlStateValueOff;
    [fv addSubview:boldCk]; [fv addSubview:italicCk]; [fv addSubview:underCk];

    // Foreground color
    NSTextField *fgL = [NSTextField labelWithString:[loc translate:@"Foreground color:"]];
    fgL.frame = NSMakeRect(20, fvH - 105, 115, 16);
    [fv addSubview:fgL];
    NSColorWell *fgWell = [[NSColorWell alloc] initWithFrame:NSMakeRect(140, fvH - 110, 30, 24)];
    fgWell.color = colorFromHex(style[@"fgColor"] ?: @"000000");
    [fv addSubview:fgWell];
    // colorStyle bits (Windows COLORSTYLE_FOREGROUND = 1, _BACKGROUND = 2):
    // a cleared bit means that colour is transparent. Absent means both set.
    NSString *curColorStyle = style[@"colorStyle"];
    int colorStyle = curColorStyle.length ? curColorStyle.intValue : 3;
    NSButton *fgTrans = [NSButton checkboxWithTitle:[loc translate:@"Transparent"]
                                             target:helper action:@selector(transparentToggled:)];
    fgTrans.frame = NSMakeRect(20, fvH - 132, 120, 18);
    fgTrans.state = (colorStyle & 1) ? NSControlStateValueOff : NSControlStateValueOn;
    [fv addSubview:fgTrans];

    // Background color
    NSTextField *bgL = [NSTextField labelWithString:[loc translate:@"Background color:"]];
    bgL.frame = NSMakeRect(260, fvH - 105, 120, 16);
    [fv addSubview:bgL];
    NSColorWell *bgWell = [[NSColorWell alloc] initWithFrame:NSMakeRect(385, fvH - 110, 30, 24)];
    bgWell.color = colorFromHex(style[@"bgColor"] ?: @"FFFFFF");
    [fv addSubview:bgWell];
    NSButton *bgTrans = [NSButton checkboxWithTitle:[loc translate:@"Transparent"]
                                             target:helper action:@selector(transparentToggled:)];
    bgTrans.frame = NSMakeRect(260, fvH - 132, 120, 18);
    bgTrans.state = (colorStyle & 2) ? NSControlStateValueOff : NSControlStateValueOn;
    [fv addSubview:bgTrans];

    helper.fgWell = fgWell; helper.bgWell = bgWell;
    helper.fgTrans = fgTrans; helper.bgTrans = bgTrans;
    [helper transparentToggled:nil];

    // ── Nesting group (only for delimiters/comments) ─────────────────────
    // Each checkbox carries its SCE_USER_MASK_NESTING_* bit as its tag; the
    // checked bits form the style's nesting attribute (Windows nestingMapper).
    NSMutableArray<NSButton *> *nestChecks = [NSMutableArray array];
    int nesting = [style[@"nesting"] intValue];
    if (enableNesting) {
        NSBox *nestBox = [[NSBox alloc] initWithFrame:NSMakeRect(12, 50, W - 24, 280)];
        nestBox.title = [loc translate:@"Nesting"]; nestBox.titlePosition = NSAtTop;
        [root addSubview:nestBox];
        NSView *nv = nestBox.contentView;

        // 3 columns of checkboxes
        NSArray *col1 = @[@"Delimiter 1",@"Delimiter 2",@"Delimiter 3",@"Delimiter 4",
                          @"Delimiter 5",@"Delimiter 6",@"Delimiter 7",@"Delimiter 8"];
        NSArray *col2 = @[@"Keyword 1",@"Keyword 2",@"Keyword 3",@"Keyword 4",
                          @"Keyword 5",@"Keyword 6",@"Keyword 7",@"Keyword 8"];
        NSArray *col3 = @[@"Comment",@"Comment line",@"Operators 1",@"Operators 2",@"Numbers"];
        // Delimiter n = 0x1 << (n-1), Keyword n = 0x400 << (n-1).
        const int col3Masks[] = { 0x100, 0x200, 0x1000000, 0x2000000, 0x4000000 };

        CGFloat ny = 230;
        void (^addCheck)(NSString *, CGFloat, CGFloat, int) = ^(NSString *title, CGFloat x, CGFloat y, int mask) {
            NSButton *cb = [NSButton checkboxWithTitle:title target:nil action:nil];
            cb.frame = NSMakeRect(x, y, 120, 18); cb.font = [NSFont systemFontOfSize:11];
            cb.tag = mask;
            cb.state = (nesting & mask) ? NSControlStateValueOn : NSControlStateValueOff;
            [nv addSubview:cb];
            [nestChecks addObject:cb];
        };
        for (NSUInteger i = 0; i < col1.count; i++)
            addCheck(col1[i], 20, ny - i * 26, 0x1 << i);
        for (NSUInteger i = 0; i < col2.count; i++)
            addCheck(col2[i], 170, ny - i * 26, 0x400 << i);
        for (NSUInteger i = 0; i < col3.count; i++)
            addCheck(col3[i], 320, ny - i * 26, col3Masks[i]);
    }

    // ── OK / Cancel buttons ──────────────────────────────────────────────
    NSButton *okBtn = [NSButton buttonWithTitle:[loc translate:@"OK"] target:helper action:@selector(okClicked:)];
    okBtn.frame = NSMakeRect(W/2 - 90, 12, 80, 28);
    okBtn.keyEquivalent = @"\r";
    [root addSubview:okBtn];

    NSButton *cancelBtn = [NSButton buttonWithTitle:[loc translate:@"Cancel"] target:helper action:@selector(cancelClicked:)];
    cancelBtn.frame = NSMakeRect(W/2 + 10, 12, 80, 28);
    cancelBtn.keyEquivalent = @"\033";
    [root addSubview:cancelBtn];

    // ── Run modal ────────────────────────────────────────────────────────
    [NSApp runModalForWindow:panel];

    if (helper.response == NSModalResponseOK) {
        // Collect results
        // Empty font name / size means "inherit"; clear a previous value
        // rather than leaving it in place.
        NSString *selFont = fontPop.selectedItem.title ?: @"";
        if (selFont.length || style[@"fontName"]) style[@"fontName"] = selFont;
        NSString *selSize = sizePop.selectedItem.title ?: @"";
        if (selSize.length || style[@"fontSize"]) style[@"fontSize"] = selSize;

        int fs = 0;
        if (boldCk.state == NSControlStateValueOn)  fs |= 1;
        if (italicCk.state == NSControlStateValueOn) fs |= 2;
        if (underCk.state == NSControlStateValueOn)  fs |= 4;
        style[@"fontStyle"] = [NSString stringWithFormat:@"%d", fs];

        style[@"fgColor"] = hexFromColor(fgWell.color);
        style[@"bgColor"] = hexFromColor(bgWell.color);

        int cs = 0;
        if (fgTrans.state != NSControlStateValueOn) cs |= 1;
        if (bgTrans.state != NSControlStateValueOn) cs |= 2;
        // The attribute is optional when both colours are used (Windows
        // omits it); an existing one is kept in step rather than dropped.
        if (cs != 3 || style[@"colorStyle"]) style[@"colorStyle"] = [NSString stringWithFormat:@"%d", cs];

        if (enableNesting) {
            // Bits without a checkbox (the folder masks) are kept as they were.
            int newNesting = nesting;
            for (NSButton *cb in nestChecks) {
                if (cb.state == NSControlStateValueOn) newNesting |= (int)cb.tag;
                else newNesting &= ~(int)cb.tag;
            }
            if (newNesting != nesting || style[@"nesting"])
                style[@"nesting"] = [NSString stringWithFormat:@"%d", newNesting];
        }

        [panel close];
        return YES;
    } else {
        // Cancel — restore
        [style setDictionary:initialStyle];
        [panel close];
        return NO;
    }
}

@end
