#import "NppTabBar.h"
#import "NppPaths.h"
#import "NppThemeManager.h"
#import "PreferencesWindowController.h"
#import "NppLocalizer.h"   // match tab-menu items by normalized English title (locale-proof)

@class _NppTabItem;

@interface NppTabBar (ContextMenu)
- (NSMenu *)buildTabContextMenu;
@end

@interface NppTabBar (TabItemEvents)
- (void)tabItemMouseDown:(_NppTabItem *)item event:(NSEvent *)event;
- (void)tabItemClosed:(_NppTabItem *)item;
@end

// ── Constants ─────────────────────────────────────────────────────────────────
// Bar layout: baseBarH = kTabTopGap + inactiveTabH + 1(border).
// inactiveTabH = barH - kTabTopGap - 1.  activeTabH = inactiveTabH + kActiveBoost.
// In wrap mode the view reports a taller intrinsic height as rows are added.
static const CGFloat kTabBarBaseHeight = 25.0;
static const CGFloat kTabTopGap    = 5.0;   // dead space at bar top (gap below toolbar)
static const CGFloat kActiveBoost  = 3.0;   // px active tab is taller than inactive
static const CGFloat kTabMinWidth  = 80.0;
static const CGFloat kTabMaxWidth  = 190.0;
static const CGFloat kIconSize     = 16.0;
static const CGFloat kCloseSize    = 14.0;
static const CGFloat kArrowBtnW    = 14.0;  // width of each scroll-arrow button

// ── Colors (all routed through NppThemeManager) ──────────────────────────────
#define TM [NppThemeManager shared]
static NSColor *tabBarBgColor()    { return TM.tabBarBackground; }
static NSColor *activeTabColor()   { return TM.activeTabFill; }
static NSColor *accentColor()      { return TM.accentStripe; }
// Per-tab color palette (same for light/dark)
static NSColor *tabColorForId(NSInteger colorId) {
    switch (colorId) {
        case 0: return [NSColor colorWithRed:0xFC/255.0 green:0xE3/255.0 blue:0x86/255.0 alpha:1]; // Yellow
        case 1: return [NSColor colorWithRed:0xA9/255.0 green:0xF0/255.0 blue:0x8C/255.0 alpha:1]; // Green
        case 2: return [NSColor colorWithRed:0x7A/255.0 green:0xC9/255.0 blue:0xF5/255.0 alpha:1]; // Blue
        case 3: return [NSColor colorWithRed:0xF5/255.0 green:0xB6/255.0 blue:0x7A/255.0 alpha:1]; // Orange
        case 4: return [NSColor colorWithRed:0xF0/255.0 green:0x8C/255.0 blue:0xF0/255.0 alpha:1]; // Pink
        default: return nil; // -1 = use default accent
    }
}
static NSColor *tabBorderColor()   { return TM.tabBorder; }
static NSColor *dividerGray()      { return TM.dividerDark; }
static NSColor *dividerWhite()     { return TM.dividerLight; }

// ── Icon helpers (routed through NppThemeManager) ────────────────────────────
static NSImage *tabIcon(NSString *name) {
    return [TM tabbarIconNamed:name];
}
static NSImage *toolbarIcon(NSString *name) {
    return [TM toolbarIconNamed:name];
}

// ── Windows-style scroll arrow button ────────────────────────────────────────
@interface _NppScrollArrowButton : NSButton {
    BOOL _pointsRight;
    BOOL _hovering;
}
- (instancetype)initPointingRight:(BOOL)right target:(id)tgt action:(SEL)act;
@end

@implementation _NppScrollArrowButton

- (instancetype)initPointingRight:(BOOL)right target:(id)tgt action:(SEL)act {
    self = [super init];
    if (self) {
        _pointsRight = right;
        [self setBordered:NO];
        self.buttonType = NSButtonTypeMomentaryChange;
        self.title  = @"";
        self.target = tgt;
        self.action = act;
        self.hidden = YES;
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

- (void)mouseEntered:(NSEvent *)e { _hovering = YES;  [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)e  { _hovering = NO;   [self setNeedsDisplay:YES]; }

- (void)drawRect:(NSRect)dirtyRect {
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    // Background — slightly brighter on hover
    NSColor *bg = _hovering ? TM.arrowHoverBg : TM.arrowPressBg;
    [bg setFill];
    NSRectFill(self.bounds);

    // 1px border
    [TM.arrowBorder setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds, 0.5, 0.5)];
    border.lineWidth = 0.5;
    [border stroke];

    // Small solid triangle centered in the button
    CGFloat aw = 4.0, ah = 7.0;
    CGFloat ax = floor((w - aw) / 2.0);
    CGFloat ay = floor((h - ah) / 2.0);

    NSBezierPath *tri = [NSBezierPath bezierPath];
    if (_pointsRight) {
        [tri moveToPoint:NSMakePoint(ax,      ay)];
        [tri lineToPoint:NSMakePoint(ax + aw, ay + ah / 2.0)];
        [tri lineToPoint:NSMakePoint(ax,      ay + ah)];
    } else {
        [tri moveToPoint:NSMakePoint(ax + aw, ay)];
        [tri lineToPoint:NSMakePoint(ax,      ay + ah / 2.0)];
        [tri lineToPoint:NSMakePoint(ax + aw, ay + ah)];
    }
    [tri closePath];
    [TM.arrowFill setFill];
    [tri fill];
}
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - _NppTabItem (private)

@interface _NppTabItem : NSView {
    BOOL _hovered;
    BOOL _closeHovered;
    NSTrackingArea *_trackingArea;
}
@property (nonatomic) NSInteger tabIndex;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) BOOL isSelected;
@property (nonatomic) BOOL isModified;
@property (nonatomic) BOOL isPinned;
@property (nonatomic) NSInteger colorId;  // -1 = default orange, 0–4 = color 1–5
@property (nonatomic, weak) id target;
@property (nonatomic) SEL selectAction;
@property (nonatomic) SEL closeAction;
@property (nonatomic, readonly) BOOL hovered;  // exposed so the bar can gate close-button hits on hover state
- (CGFloat)preferredWidth;
@end

@implementation _NppTabItem

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) { self.wantsLayer = YES; _colorId = -1; }
    return self;
}

static const CGFloat kPinSize = 11.0; // pin icon drawn at ~80% of original ~14px

// ── Tab width helpers (wrap-mode auto-fill) ───────────────────────────────────
static CGFloat effectiveTabMaxWidth(void) {
    NSInteger maxW = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefTabMaxLabelWidth];
    if (maxW < (NSInteger)kTabMinWidth) maxW = (NSInteger)kTabMinWidth;
    return (CGFloat)maxW;
}

static CGFloat tabChromeWidth(_NppTabItem *item) {
    CGFloat closeGap = 4 + kCloseSize + 4;
    CGFloat pinGap   = item.isPinned ? (kPinSize + 2) : 0;
    BOOL showClose = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefTabCloseButton];
    if (!showClose) closeGap = 0;
    return 8 + kIconSize + 4 + pinGap + closeGap + 8;
}

static CGFloat tabContentWidth(_NppTabItem *item) {
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightRegular]};
    CGFloat tw = [item.title sizeWithAttributes:attrs].width;
    return tabChromeWidth(item) + tw;
}

/// Minimum width during wrap-mode auto-shrink: honour full short titles; long
/// titles may truncate (middle ellipsis) but never shrink below max-tab pref.
static CGFloat tabShrinkFloor(_NppTabItem *item) {
    CGFloat maxW    = effectiveTabMaxWidth();
    CGFloat content = tabContentWidth(item);
    if (content > maxW) return maxW;
    return MAX(kTabMinWidth, content);
}

- (CGFloat)preferredWidth {
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightRegular]};
    CGFloat tw       = [_title sizeWithAttributes:attrs].width;
    CGFloat closeGap = 4 + kCloseSize + 4;
    CGFloat pinGap   = _isPinned ? (kPinSize + 2) : 0; // pin icon to left of close
    NSInteger maxW = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefTabMaxLabelWidth];
    if (maxW < 80) maxW = 80;
    BOOL showClose = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefTabCloseButton];
    if (!showClose) closeGap = 0;
    return MAX(kTabMinWidth, MIN((CGFloat)maxW, 8 + kIconSize + 4 + tw + pinGap + closeGap + 8));
}

- (void)drawRect:(NSRect)dirtyRect {
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    // Tahoe: same top-corner rounding as the editor/panel cards (8pt). Classic: 2pt.
    CGFloat r = TM.usesGlassMaterials ? 8.0 : 2.0;

    // ── Tab shape: rounded top corners, flat bottom ───────────────────────────
    NSBezierPath *tabPath = [NSBezierPath bezierPath];
    [tabPath moveToPoint:NSMakePoint(0, 0)];
    [tabPath lineToPoint:NSMakePoint(0, h - r)];
    [tabPath appendBezierPathWithArcWithCenter:NSMakePoint(r, h - r)
                                         radius:r startAngle:180 endAngle:90 clockwise:YES];
    [tabPath lineToPoint:NSMakePoint(w - r, h)];
    [tabPath appendBezierPathWithArcWithCenter:NSMakePoint(w - r, h - r)
                                         radius:r startAngle:90 endAngle:0 clockwise:YES];
    [tabPath lineToPoint:NSMakePoint(w, 0)];
    [tabPath closePath];

    // ── Fill ──────────────────────────────────────────────────────────────────
    if (TM.usesGlassMaterials) {
        // Tahoe: flat tabs. The per-tab color (the "apply color to tabs" feature)
        // is painted as a full-tab TRANSLUCENT vertical gradient instead of the
        // Classic 3px accent stripe; uncolored tabs stay neutral/flat. The Classic
        // branch below is left byte-for-byte unchanged.
        NSColor *base = tabColorForId(_colorId);          // nil when no custom color assigned
        if (!base && _isSelected) base = accentColor();   // default active tab → Classic orange accent gradient
        [NSGraphicsContext saveGraphicsState];
        [tabPath addClip];
        if (base) {
            CGFloat topA = _isSelected ? 0.42 : (_hovered ? 0.30 : 0.22);
            CGFloat botA = _isSelected ? 0.24 : (_hovered ? 0.16 : 0.12);
            NSGradient *g = [[NSGradient alloc]
                initWithStartingColor:[base colorWithAlphaComponent:topA]
                          endingColor:[base colorWithAlphaComponent:botA]];
            [g drawInRect:self.bounds angle:270];
        } else if (_hovered) {
            [TM.hoverTabFill setFill];
            NSRectFill(self.bounds);
        }
        // inactive + uncolored → no fill (the flat bar background shows through)
        [NSGraphicsContext restoreGraphicsState];
    } else if (_isSelected) {
        [activeTabColor() setFill];
        [tabPath fill];
    } else {
        NSColor *top    = _hovered ? TM.hoverTabGradientTop    : TM.inactiveTabGradientTop;
        NSColor *bottom = _hovered ? TM.hoverTabGradientBottom : TM.inactiveTabGradientBottom;
        NSGradient *g = [[NSGradient alloc] initWithStartingColor:top endingColor:bottom];
        [NSGraphicsContext saveGraphicsState];
        [tabPath addClip];
        [g drawInRect:self.bounds angle:270];
        [NSGraphicsContext restoreGraphicsState];
    }

    // ── Border ────────────────────────────────────────────────────────────────
    if (TM.usesGlassMaterials) {
        // Tahoe: a soft border only a few tones darker than the tab itself — for a
        // colored tab a slightly stronger shade of its own color; for an uncolored
        // tab a faint dark outline. (Classic keeps the grey tabBorder, untouched.)
        NSColor *bbase = tabColorForId(_colorId);
        if (!bbase && _isSelected) bbase = accentColor();
        NSColor *bcol = bbase ? [bbase colorWithAlphaComponent:0.6]
                              : [NSColor colorWithWhite:0.0 alpha:0.12];
        [bcol setStroke];
    } else {
        [tabBorderColor() setStroke];
    }
    tabPath.lineWidth = 0.5;
    [tabPath stroke];

    // ── Accent stripe: 3px at top, clipped to tab shape (CLASSIC ONLY) ──────
    // Active tab always shows a stripe (per-tab color or default orange).
    // Inactive tabs with a color assigned also show the stripe.
    // Tahoe shows the per-tab color as a full-tab translucent tint (Fill above),
    // so the stripe is suppressed there.
    if (!TM.usesGlassMaterials) {
        NSColor *stripe = tabColorForId(_colorId) ?: accentColor();
        if (_isSelected || _colorId >= 0) {
            [NSGraphicsContext saveGraphicsState];
            [tabPath addClip];
            [stripe setFill];
            NSRectFill(NSMakeRect(0, h - 3, w, 3));
            [NSGraphicsContext restoreGraphicsState];
        }
    }

    // ── Floppy icon ───────────────────────────────────────────────────────────
    NSImage *icon = _isModified ? toolbarIcon(@"saveFileRed") : toolbarIcon(@"saveFile");
    if (icon) {
        CGFloat sz  = kIconSize * 0.704;
        NSRect  ir  = NSMakeRect(8 + (kIconSize - sz) / 2.0, (h - sz) / 2.0, sz, sz);
        [icon drawInRect:ir fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver fraction:1.0];
    }

    // ── Title ─────────────────────────────────────────────────────────────────
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSColor *textColor = _isSelected ? TM.tabText : TM.tabTextInactive;
    NSFont  *font      = _isSelected ? [NSFont systemFontOfSize:11 weight:NSFontWeightMedium]
                                     : [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    NSDictionary *attrs = @{NSFontAttributeName: font,
                             NSForegroundColorAttributeName: textColor,
                             NSParagraphStyleAttributeName: ps};
    CGFloat textX = 8 + kIconSize + 4;
    CGFloat rightPad = kCloseSize + 8 + (_isPinned ? kPinSize + 2 : 0);
    CGFloat textW = w - textX - rightPad;
    CGFloat textY = _isSelected ? 3.0 : 1.5;  // bottom space (active 3.0, inactive 1.5)
    [_title drawInRect:NSMakeRect(textX, textY, textW, font.pointSize + 4)
        withAttributes:attrs];

    // ── Close button (rightmost, hidden if pref is off) ─────────────────────
    BOOL showClose = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefTabCloseButton];
    CGFloat cx = w - kCloseSize - 6;
    CGFloat cy = (h - kCloseSize) / 2.0;
    if (showClose && (_isSelected || _hovered)) {
        NSImage *closeImg = nil;
        if (_closeHovered)    closeImg = tabIcon(@"closeTabButton_hoverIn");
        else if (_isSelected) closeImg = tabIcon(@"closeTabButton");
        else                  closeImg = tabIcon(@"closeTabButton_hoverOnTab");
        if (closeImg) { closeImg.size = NSMakeSize(32, 32);
            [closeImg drawInRect:NSMakeRect(cx, cy, kCloseSize, kCloseSize)
                       fromRect:NSZeroRect
                      operation:NSCompositingOperationSourceOver fraction:1.0];
        } else {
            NSDictionary *xa = @{NSFontAttributeName: [NSFont systemFontOfSize:11],
                                  NSForegroundColorAttributeName: textColor};
            [@"×" drawAtPoint:NSMakePoint(cx + 1, cy - 1) withAttributes:xa];
        }
    }

    // ── Pin icon (to the left of close button, only when pinned) ─────────────
    if (_isPinned) {
        NSString *pinPath = [[NSBundle mainBundle] pathForResource:@"pinTabButton_pinned" ofType:@"png"
                                                       inDirectory:@"icons/standard/tabbar"];
        NSImage *pinImg = pinPath ? [[NSImage alloc] initWithContentsOfFile:pinPath] : nil;
        if (pinImg) {
            CGFloat px = cx - kPinSize - 2;
            CGFloat py = (h - kPinSize) / 2.0;
            [pinImg drawInRect:NSMakeRect(px, py, kPinSize, kPinSize)
                     fromRect:NSZeroRect
                    operation:NSCompositingOperationSourceOver fraction:1.0];
        }
    }
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) [self removeTrackingArea:_trackingArea];
    _trackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseEnteredAndExited |
                      NSTrackingMouseMoved            |
                      NSTrackingActiveInKeyWindow)
               owner:self userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent *)e { _hovered = YES;  [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)e  { _hovered = NO; _closeHovered = NO; [self setNeedsDisplay:YES]; }
- (void)mouseMoved:(NSEvent *)e {
    NSPoint p  = [self convertPoint:e.locationInWindow fromView:nil];
    CGFloat cx = self.bounds.size.width - kCloseSize - 6;
    BOOL oc    = p.x >= cx && p.x <= cx + kCloseSize;
    if (oc != _closeHovered) { _closeHovered = oc; [self setNeedsDisplay:YES]; }
}

- (void)mouseDown:(NSEvent *)event {
    [(NppTabBar *)_target tabItemMouseDown:self event:event];
}

// Middle-click closes the tab, as Notepad++ does off WM_MBUTTONUP — hence
// acting on the up, and only when it lands back on the tab. A view that
// doesn't claim the down event is never sent the matching up, so
// otherMouseDown: has to swallow the middle button even though it does nothing.
- (void)otherMouseDown:(NSEvent *)event {
    if (event.buttonNumber != 2) [super otherMouseDown:event];
}

- (void)otherMouseUp:(NSEvent *)event {
    if (event.buttonNumber != 2) { [super otherMouseUp:event]; return; }
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(p, self.bounds)) return;
    [(NppTabBar *)_target tabItemClosed:self];
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [_target performSelector:_selectAction withObject:self];
#pragma clang diagnostic pop
    return [(NppTabBar *)_target buildTabContextMenu];
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - _NppTabBarContainer
//
// Document view that backs the tab bar's scroll view and holds the
// _NppTabItem subviews. Its sole responsibility beyond being a plain NSView
// is to detect a double-click on the empty space to the right of the last
// tab (or below the last row in wrap mode) and ask its owning NppTabBar
// to fire `tabBarDidRequestNewTab:` on the delegate.
//
// AppKit's hit-test guarantees that mouseDown only reaches us when the click
// did NOT land on any _NppTabItem subview — so we don't need any
// point-in-rect math to know "the click was on empty space."
//
// Same-view double-click guard:
//   NSEvent.clickCount is window-scoped, not view-scoped. A user click
//   sequence like `tab → empty area within 400 ms` would deliver a
//   clickCount=2 event to us even though click #1 landed on a different
//   view (the tab). Without this guard, that sequence would spuriously
//   open a new tab. We track the timestamp of every mouseDown WE receive
//   and only fire on clickCount=2 if the previous click was also ours
//   within [NSEvent doubleClickInterval]. Click sequences that don't
//   originate inside this view never trigger the gesture.

// Private NppTabBar API used by _NppTabBarContainer below. Declared in a
// class extension so the container's mouseDown can call it under ARC
// without falling back to performSelector.
@interface NppTabBar (_NppTabBarPrivate)
- (void)_emptyAreaDoubleClicked;
- (NSArray<NSArray<_NppTabItem *> *> *)_wrapRowsForTabs:(NSArray<_NppTabItem *> *)tabs
                                                widths:(NSArray<NSNumber *> *)widths
                                              barWidth:(CGFloat)barW;
- (NSArray<NSNumber *> *)_baseLayoutWidthsForWrapTabs:(NSArray<_NppTabItem *> *)tabs
                                             barWidth:(CGFloat)barW;
- (NSArray<NSArray<_NppTabItem *> *> *)_resolvedWrapRowsForTabs:(NSArray<_NppTabItem *> *)tabs
                                                    layoutWidths:(NSArray<NSNumber *> *)layoutWidths
                                                        barWidth:(CGFloat)barW;
- (NSArray<NSArray<_NppTabItem *> *> *)_finalWrapRowsForTabs:(NSArray<_NppTabItem *> *)tabs
                                                    barWidth:(CGFloat)barW
                                               layoutWidths:(NSArray<NSNumber *> * _Nullable)layoutWidths;
- (NSArray<NSNumber *> *)_autoSizedWidthsForRowTabs:(NSArray<_NppTabItem *> *)rowTabs
                                        baseWidths:(NSArray<NSNumber *> *)baseWidths
                                          barWidth:(CGFloat)barW;
- (void)_layoutWrapTabs:(NSArray<_NppTabItem *> *)tabs
               barWidth:(CGFloat)barW
               neededH:(CGFloat)neededH
               activeH:(CGFloat)activeH
            inactiveH:(CGFloat)inactiveH
               skipItem:(_NppTabItem * _Nullable)skipItem
                gapRect:(NSRect * _Nullable)gapRectOut
            applyFrames:(BOOL)applyFrames;
- (void)_layoutScrollTabs:(NSArray<_NppTabItem *> *)tabs
                 barWidth:(CGFloat)barW
                     barH:(CGFloat)barH
                  activeH:(CGFloat)activeH
               inactiveH:(CGFloat)inactiveH
                 skipItem:(_NppTabItem * _Nullable)skipItem
                  gapRect:(NSRect * _Nullable)gapRectOut
              applyFrames:(BOOL)applyFrames;
- (NSArray<_NppTabItem *> *)_previewTabsMovingFrom:(NSInteger)from to:(NSInteger)to;
- (CGFloat)_preferredHeightForTabs:(NSArray<_NppTabItem *> *)tabs barWidth:(CGFloat)barW;
- (NSRect)_gapRectPreviewMoveFrom:(NSInteger)from to:(NSInteger)to;
@end

@interface _NppTabBarContainer : NSView
@property (nonatomic, weak, nullable) NppTabBar *tabBar;
@end

@implementation _NppTabBarContainer {
    NSTimeInterval _lastClickHere;  // timestamp of last mouseDown delivered to us
}

- (void)mouseDown:(NSEvent *)event {
    NSTimeInterval now = event.timestamp;

    if (event.clickCount == 2 &&
        _lastClickHere > 0 &&
        (now - _lastClickHere) <= [NSEvent doubleClickInterval])
    {
        // Both clicks of the pair landed on us → genuine empty-area
        // double-click. Reset the timestamp so a subsequent quick click
        // doesn't pair with this completed gesture.
        _lastClickHere = 0;
        if (self.tabBar) [self.tabBar _emptyAreaDoubleClicked];
        return;
    }

    // Single-click on empty area, or first click of a future pair.
    // Stash the timestamp so the same-view guard above can recognise the
    // pair if a second click follows in time.
    _lastClickHere = now;
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - NppTabBar

@implementation NppTabBar {
    NSScrollView                  *_scrollView;
    _NppTabBarContainer           *_containerView;
    NSMutableArray<_NppTabItem *> *_items;
    NSInteger                      _selectedIndex;
    BOOL                           _wrapMode;
    CGFloat                        _preferredHeight;
    _NppScrollArrowButton         *_scrollLeftBtn;
    _NppScrollArrowButton         *_scrollRightBtn;
    /// During drag-reorder: index of the tab being moved (-1 = none).
    NSInteger                      _dragReorderFromIndex;
    /// Drop slot index.
    NSInteger                      _dragReorderToIndex;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _items         = [NSMutableArray array];
        _selectedIndex = -1;
        _preferredHeight = kTabBarBaseHeight;
        _dragReorderFromIndex = -1;
        _dragReorderToIndex   = -1;
        [self _buildUI];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_darkModeChanged:)
                   name:NPPDarkModeChangedNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    // Pair the addObserver: in init so a torn-down tab bar can never
    // leave a dangling pointer in CoreFoundation's observer list — the
    // signature of the long-session crash in incident 647E563D / 18618486.
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_darkModeChanged:(NSNotification *)n {
    // Redraw all tabs and the bar itself with updated theme colors
    for (_NppTabItem *item in _items)
        [item setNeedsDisplay:YES];
    [_scrollLeftBtn setNeedsDisplay:YES];
    [_scrollRightBtn setNeedsDisplay:YES];
    [self setNeedsDisplay:YES];
}

- (void)_buildUI {
    _containerView = [[_NppTabBarContainer alloc] initWithFrame:NSZeroRect];
    _containerView.tabBar = self;

    _scrollView                       = [[NSScrollView alloc] initWithFrame:self.bounds];
    _scrollView.autoresizingMask      = NSViewNotSizable;   // managed in relayout
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.hasVerticalScroller   = NO;
    _scrollView.drawsBackground       = NO;
    _scrollView.documentView          = _containerView;
    [self addSubview:_scrollView];

    _scrollLeftBtn  = [[_NppScrollArrowButton alloc] initPointingRight:NO
                                                                target:self
                                                                action:@selector(_scrollLeft:)];
    _scrollRightBtn = [[_NppScrollArrowButton alloc] initPointingRight:YES
                                                                target:self
                                                                action:@selector(_scrollRight:)];
    [self addSubview:_scrollLeftBtn];
    [self addSubview:_scrollRightBtn];
}

// Legacy alias — kept so any external caller still compiles.
- (void)buildScrollView { /* init already called _buildUI */ }

- (void)drawRect:(NSRect)dirtyRect {
    if (TM.usesGlassMaterials) {
        // Tahoe: transparent tab strip with no bottom separator — the window
        // gradient shows behind the tabs. Gated; Classic keeps its #eeeeee fill.
        return;
    }
    [tabBarBgColor() setFill];
    NSRectFill(self.bounds);
    [[NSColor separatorColor] setFill];
    NSRectFill(NSMakeRect(0, 0, self.bounds.size.width, 1));
}

// Called by Auto Layout whenever the view is sized — use this to guarantee
// relayout runs with correct bounds (fixes arrow visibility without window resize).
- (void)layout {
    [super layout];
    [self relayout];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self relayout];
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, _preferredHeight);
}

#pragma mark - Public API

- (void)addTabWithTitle:(NSString *)title modified:(BOOL)modified {
    _NppTabItem *item  = [[_NppTabItem alloc] initWithFrame:NSZeroRect];
    item.title         = title;
    item.isModified    = modified;
    item.isSelected    = NO;
    item.tabIndex      = _items.count;
    item.target        = self;
    item.selectAction  = @selector(tabItemSelected:);
    item.closeAction   = @selector(tabItemClosed:);
    [_items addObject:item];
    [_containerView addSubview:item];
    [self relayout];
    [self setNeedsLayout:YES];   // schedule Auto Layout pass → layout → relayout
}

- (void)removeTabAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_items.count) return;
    [_items[index] removeFromSuperview];
    [_items removeObjectAtIndex:index];
    for (NSInteger i = index; i < (NSInteger)_items.count; i++)
        _items[i].tabIndex = i;
    if (_selectedIndex >= (NSInteger)_items.count)
        _selectedIndex = (NSInteger)_items.count - 1;
    if (_selectedIndex >= 0)
        _items[_selectedIndex].isSelected = YES;
    [self relayout];
    [self setNeedsLayout:YES];
}

- (void)setTitle:(NSString *)title modified:(BOOL)modified atIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_items.count) return;
    _items[index].title      = title;
    _items[index].isModified = modified;
    [_items[index] setNeedsDisplay:YES];
}

- (void)selectTabAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_items.count) return;
    if (_selectedIndex >= 0 && _selectedIndex < (NSInteger)_items.count) {
        _items[_selectedIndex].isSelected = NO;
        [_items[_selectedIndex] setNeedsDisplay:YES];
    }
    _selectedIndex                = index;
    _items[index].isSelected      = YES;
    [_items[index] setNeedsDisplay:YES];
    [self relayout];
    [self scrollTabToVisible:index];
}

- (NSInteger)tabCount { return (NSInteger)_items.count; }

- (void)pinTabAtIndex:(NSInteger)index toggle:(BOOL)toggle {
    if (index < 0 || index >= (NSInteger)_items.count) return;
    _items[index].isPinned = toggle;
    [_items[index] setNeedsDisplay:YES];
    [self relayout];
}

- (BOOL)wrapMode { return _wrapMode; }
- (void)setWrapMode:(BOOL)wrap {
    if (_wrapMode == wrap) return;
    _wrapMode = wrap;
    [self relayout];
    [self invalidateIntrinsicContentSize];
    [self setNeedsDisplay:YES];
}

- (BOOL)isTabPinnedAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_items.count) return NO;
    return _items[index].isPinned;
}

- (void)swapTabAtIndex:(NSInteger)a withIndex:(NSInteger)b {
    NSInteger count = (NSInteger)_items.count;
    if (a < 0 || a >= count || b < 0 || b >= count || a == b) return;
    [_items exchangeObjectAtIndex:(NSUInteger)a withObjectAtIndex:(NSUInteger)b];
    // Re-assign tabIndex to match new positions
    _items[a].tabIndex = a;
    _items[b].tabIndex = b;
    [self relayout];
}

- (void)setTabColorAtIndex:(NSInteger)index colorId:(NSInteger)colorId {
    if (index < 0 || index >= (NSInteger)_items.count) return;
    _items[index].colorId = colorId;
    [_items[index] setNeedsDisplay:YES];
}

- (NSInteger)tabColorAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_items.count) return -1;
    return _items[index].colorId;
}

+ (nullable NSColor *)tabFillColorForId:(NSInteger)colorId {
    return tabColorForId(colorId);
}

#pragma mark - Tab item callbacks

- (NSInteger)_dropTargetIndexForContainerPoint:(NSPoint)p fromIndex:(NSInteger)from {
    NSInteger n = (NSInteger)_items.count;
    if (n <= 1) return 0;
    if (from < 0 || from >= n) return 0;

    NSInteger best = from;
    CGFloat bestD = CGFLOAT_MAX;
    for (NSInteger cand = 0; cand < n; cand++) {
        NSRect gr = [self _gapRectPreviewMoveFrom:from to:cand];
        if (NSIsEmptyRect(gr)) continue;
        NSPoint c = NSMakePoint(NSMidX(gr), NSMidY(gr));
        CGFloat d = hypot(p.x - c.x, p.y - c.y);
        if (d < bestD) {
            bestD = d;
            best = cand;
        }
    }
    return best;
}

- (NSArray<_NppTabItem *> *)_previewTabsMovingFrom:(NSInteger)from to:(NSInteger)to {
    NSInteger n = (NSInteger)_items.count;
    to = MAX(0, MIN(n - 1, to));
    NSMutableArray<_NppTabItem *> *preview = [_items mutableCopy];
    _NppTabItem *moving = preview[from];
    [preview removeObjectAtIndex:(NSUInteger)from];
    [preview insertObject:moving atIndex:(NSUInteger)to];
    return preview;
}

- (NSRect)_gapRectPreviewMoveFrom:(NSInteger)from to:(NSInteger)to {
    NSInteger n = (NSInteger)_items.count;
    if (from < 0 || from >= n || n == 0) return NSZeroRect;

    NSArray<_NppTabItem *> *preview = [self _previewTabsMovingFrom:from to:to];
    _NppTabItem *moving = _items[from];
    CGFloat barW = self.bounds.size.width;
    if (barW < 1) return NSZeroRect;

    CGFloat inactiveH = kTabBarBaseHeight - kTabTopGap - 1;
    CGFloat activeH   = inactiveH + kActiveBoost;
    NSRect gap = NSZeroRect;

    if (_wrapMode) {
        CGFloat neededH = [self _preferredHeightForTabs:preview barWidth:barW];
        [self _layoutWrapTabs:preview barWidth:barW neededH:neededH
                       activeH:activeH inactiveH:inactiveH
                      skipItem:moving gapRect:&gap applyFrames:NO];
    } else {
        CGFloat barH = self.bounds.size.height;
        if (barH < 1) barH = kTabBarBaseHeight;
        [self _layoutScrollTabs:preview barWidth:barW barH:barH
                        activeH:activeH inactiveH:inactiveH
                       skipItem:moving gapRect:&gap applyFrames:NO];
    }
    return gap;
}

- (void)moveTabAtIndex:(NSInteger)fromIndex toIndex:(NSInteger)toIndex {
    NSInteger count = (NSInteger)_items.count;
    if (fromIndex < 0 || fromIndex >= count ||
        toIndex < 0 || toIndex >= count ||
        fromIndex == toIndex) return;

    _NppTabItem *movingItem = _items[fromIndex];
    [_items removeObjectAtIndex:(NSUInteger)fromIndex];
    [_items insertObject:movingItem atIndex:(NSUInteger)toIndex];

    if (_selectedIndex == fromIndex) {
        _selectedIndex = toIndex;
    } else if (fromIndex < _selectedIndex && _selectedIndex <= toIndex) {
        _selectedIndex--;
    } else if (toIndex <= _selectedIndex && _selectedIndex < fromIndex) {
        _selectedIndex++;
    }

    for (NSInteger i = 0; i < (NSInteger)_items.count; i++) {
        _items[i].tabIndex = i;
        _items[i].isSelected = (i == _selectedIndex);
    }
    [self relayout];
}

- (NSImage *)_dragImageForTabItem:(_NppTabItem *)item {
    NSBitmapImageRep *rep = [item bitmapImageRepForCachingDisplayInRect:item.bounds];
    if (!rep) return nil;
    [item cacheDisplayInRect:item.bounds toBitmapImageRep:rep];

    NSImage *image = [[NSImage alloc] initWithSize:item.bounds.size];
    [image addRepresentation:rep];
    return image;
}

- (void)tabItemMouseDown:(_NppTabItem *)item event:(NSEvent *)event {
    NSPoint p  = [item convertPoint:event.locationInWindow fromView:nil];
    CGFloat cx = item.bounds.size.width - kCloseSize - 6;
    BOOL closeVisible = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefTabCloseButton];
    // Issue #84 hardening #4 — restore the (isSelected || hovered) precondition.
    // Without it, an unhovered/unselected tab can be closed by a click that lands
    // in the close-button rect (e.g. blind clicks on a tab the user hasn't aimed at).
    BOOL overClose = closeVisible && (item.isSelected || item.hovered)
                     && p.x >= cx && p.x <= cx + kCloseSize;
    // Double-click anywhere on tab to close (if enabled) — independent of hover.
    if (!overClose && event.clickCount == 2 &&
        [[NSUserDefaults standardUserDefaults] boolForKey:kPrefDoubleClickTabClose]) {
        overClose = YES;
    }

    if (overClose) {
        [self tabItemClosed:item];
        return;
    }

    // Issue #84 hardening #5 — reject drag init for unlaid-out tabs.
    // bitmapImageRepForCachingDisplayInRect: returns nil for zero-sized views,
    // and a hidden source with no ghost is a confusing UI state. Treat as
    // a plain click instead of starting a half-broken drag.
    if (item.bounds.size.width < 1 || item.bounds.size.height < 1) {
        [self tabItemSelected:item];
        return;
    }

    NSInteger fromIndex = item.tabIndex;
    NSInteger toIndex = fromIndex;
    BOOL dragging = NO;
    NSPoint downPoint = [_containerView convertPoint:event.locationInWindow fromView:nil];
    NSPoint dragOffsetInItem = [item convertPoint:event.locationInWindow fromView:nil];
    NSImageView *dragGhost = nil;
    const CGFloat dragThreshold = 4.0;

    BOOL aborted = NO;  // Issue #84 hardening #2 — flag for abort-on-removal path

    while (YES) {
        NSEvent *nextEvent = [self.window nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)];
        if (!nextEvent) break;

        // Issue #84 hardening #2 — re-anchor fromIndex by object identity each
        // tick. If external code mutated _items between events (a plugin or
        // file watcher firing on a tracking-mode source), the captured
        // tabIndex from drag-start would point at the wrong slot, or out of
        // bounds. NSNotFound means the dragged tab was removed; abort cleanly
        // through the unified cleanup below.
        NSInteger live = [_items indexOfObjectIdenticalTo:item];
        if (live == NSNotFound) { aborted = YES; break; }
        fromIndex = live;

        NSPoint currentPoint = [_containerView convertPoint:nextEvent.locationInWindow fromView:nil];
        if (nextEvent.type == NSEventTypeLeftMouseDragged) {
            CGFloat dx = currentPoint.x - downPoint.x;
            CGFloat dy = currentPoint.y - downPoint.y;
            if (!dragging && hypot(dx, dy) >= dragThreshold) dragging = YES;
            if (dragging) {
                if (_dragReorderFromIndex < 0) {
                    NSImage *image = [self _dragImageForTabItem:item];
                    if (image) {
                        dragGhost = [[NSImageView alloc] initWithFrame:[self convertRect:item.bounds fromView:item]];
                        dragGhost.image = image;
                        dragGhost.imageScaling = NSImageScaleAxesIndependently;
                        dragGhost.alphaValue = 0.65;
                        dragGhost.wantsLayer = YES;
                        dragGhost.layer.shadowOpacity = 0.25;
                        dragGhost.layer.shadowRadius = 4.0;
                        dragGhost.layer.shadowOffset = NSMakeSize(0, -2);
                        [self addSubview:dragGhost positioned:NSWindowAbove relativeTo:nil];
                    }
                    _dragReorderFromIndex = fromIndex;
                    _dragReorderToIndex = fromIndex;
                    item.hidden = YES;
                    [self relayout];
                } else if (_dragReorderFromIndex != fromIndex) {
                    // External mutation shifted the dragged tab to a new slot
                    // mid-drag — re-anchor the preview origin so layout draws
                    // the gap at the correct (live) position.
                    _dragReorderFromIndex = fromIndex;
                    [self relayout];
                }
                if (dragGhost) {
                    NSPoint ghostPoint = [self convertPoint:nextEvent.locationInWindow fromView:nil];
                    dragGhost.frame = NSMakeRect(ghostPoint.x - dragOffsetInItem.x,
                                                 ghostPoint.y - dragOffsetInItem.y,
                                                 item.bounds.size.width,
                                                 item.bounds.size.height);
                }
                NSInteger dropIndex = [self _dropTargetIndexForContainerPoint:currentPoint fromIndex:fromIndex];
                if (dropIndex != _dragReorderToIndex) {
                    _dragReorderToIndex = dropIndex;
                    [self relayout];
                }
                toIndex = dropIndex;
            }
            continue;
        }

        if (nextEvent.type == NSEventTypeLeftMouseUp) break;
    }

    // Issue #84 hardening #3 — single cleanup point. Restores the source tab,
    // removes the ghost, clears preview-state ivars, and forces a relayout so
    // the gap-preview is torn down. Reached via every loop exit (mouseUp,
    // nil-event, identity-abort).
    [self _endDragCleanup:item ghost:dragGhost];

    if (aborted) return;  // dragged tab was removed mid-drag; nothing to commit/select

    if (dragging && toIndex != fromIndex && toIndex >= 0 && toIndex < (NSInteger)_items.count) {
        [self moveTabAtIndex:fromIndex toIndex:toIndex];
        [self selectTabAtIndex:toIndex];
        if ([self.delegate respondsToSelector:@selector(tabBar:didMoveTabFromIndex:toIndex:)])
            [self.delegate tabBar:self didMoveTabFromIndex:fromIndex toIndex:toIndex];
        [self.delegate tabBar:self didSelectTabAtIndex:toIndex];
        return;
    }

    [self tabItemSelected:item];
}

// Issue #84 hardening #3 — unified cleanup helper. Idempotent on already-clean
// state; safe to call from any drag-loop exit path.
- (void)_endDragCleanup:(_NppTabItem *)item ghost:(NSImageView *)ghost {
    if (item) item.hidden = NO;
    [ghost removeFromSuperview];
    BOOL hadPreview = (_dragReorderFromIndex >= 0);
    _dragReorderFromIndex = -1;
    _dragReorderToIndex   = -1;
    if (hadPreview) [self relayout];
}

- (void)tabItemSelected:(_NppTabItem *)item {
    if (item.tabIndex != _selectedIndex)
        [self selectTabAtIndex:item.tabIndex];
    // Always fire delegate — even for already-selected tabs — so that
    // _activeTabManager updates when the user clicks/right-clicks in any pane.
    [_delegate tabBar:self didSelectTabAtIndex:item.tabIndex];
}

- (void)tabItemClosed:(_NppTabItem *)item {
    [_delegate tabBar:self didCloseTabAtIndex:item.tabIndex];
}

#pragma mark - Layout

static BOOL wrapRowsHaveOrphanLast(NSArray<NSArray *> *rows) {
    return rows.count >= 2 && rows.lastObject.count == 1;
}

- (NSArray<NSArray<_NppTabItem *> *> *)_wrapRowsForTabs:(NSArray<_NppTabItem *> *)tabs
                                                widths:(NSArray<NSNumber *> *)widths
                                              barWidth:(CGFloat)barW {
    NSMutableArray<NSMutableArray<_NppTabItem *> *> *rows = [NSMutableArray array];
    NSMutableArray<_NppTabItem *> *current = [NSMutableArray array];
    CGFloat x = 0;

    for (NSInteger i = 0; i < (NSInteger)tabs.count; i++) {
        _NppTabItem *item = tabs[i];
        CGFloat w = (i < (NSInteger)widths.count) ? widths[i].doubleValue : item.preferredWidth;
        if (x + w > barW && x > 0) {
            [rows addObject:current];
            current = [NSMutableArray array];
            x = 0;
        }
        [current addObject:item];
        x += w;
    }
    if (current.count > 0) [rows addObject:current];
    return rows;
}

- (NSArray<NSNumber *> *)_preferredWidthsForTabs:(NSArray<_NppTabItem *> *)tabs {
    NSMutableArray<NSNumber *> *widths = [NSMutableArray arrayWithCapacity:tabs.count];
    for (_NppTabItem *tab in tabs)
        [widths addObject:@(tab.preferredWidth)];
    return widths;
}

- (NSArray<NSNumber *> *)_widthsByUniformShrink:(NSArray<_NppTabItem *> *)tabs
                                      preferred:(NSArray<NSNumber *> *)preferred
                                          delta:(CGFloat)delta {
    NSInteger n = (NSInteger)tabs.count;
    NSMutableArray<NSNumber *> *widths = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    for (NSInteger i = 0; i < n; i++) {
        CGFloat floor = tabShrinkFloor(tabs[i]);
        CGFloat w     = MAX(floor, preferred[i].doubleValue - delta);
        [widths addObject:@(w)];
    }
    return widths;
}

/// When a new tab would sit alone on the last row, uniformly shrink every tab
/// (down to per-tab floors) just enough to pull at least one neighbour down
/// with it — or to collapse back to a single row — so the layout looks balanced.
- (NSArray<NSNumber *> *)_baseLayoutWidthsForWrapTabs:(NSArray<_NppTabItem *> *)tabs
                                             barWidth:(CGFloat)barW {
    NSInteger n = (NSInteger)tabs.count;
    if (n == 0) return @[];

    NSArray<NSNumber *> *preferred = [self _preferredWidthsForTabs:tabs];
    if (n == 1) return preferred;

    NSArray<NSArray<_NppTabItem *> *> *rows =
        [self _wrapRowsForTabs:tabs widths:preferred barWidth:barW];
    if (!wrapRowsHaveOrphanLast(rows)) return preferred;

    CGFloat maxDelta = 0;
    for (NSInteger i = 0; i < n; i++) {
        CGFloat floor = tabShrinkFloor(tabs[i]);
        maxDelta = MAX(maxDelta, preferred[i].doubleValue - floor);
    }
    if (maxDelta < 0.01) return preferred;

    CGFloat lo = 0, hi = maxDelta;
    for (NSInteger iter = 0; iter < 24; iter++) {
        CGFloat mid = (lo + hi) * 0.5;
        NSArray<NSNumber *> *trial =
            [self _widthsByUniformShrink:tabs preferred:preferred delta:mid];
        rows = [self _wrapRowsForTabs:tabs widths:trial barWidth:barW];
        if (wrapRowsHaveOrphanLast(rows))
            lo = mid;
        else
            hi = mid;
    }

    return [self _widthsByUniformShrink:tabs preferred:preferred delta:hi];
}

/// Evenly split `tabs` across `rowCount` rows (earlier rows receive extras).
/// e.g. 5 tabs / 2 rows → 3 + 2, never 4 + 1.
- (NSArray<NSArray<_NppTabItem *> *> *)_wrapRowsBalancedForTabs:(NSArray<_NppTabItem *> *)tabs
                                                      rowCount:(NSInteger)rowCount {
    NSInteger n = (NSInteger)tabs.count;
    if (n == 0) return @[];
    rowCount = MAX(1, MIN(rowCount, n));

    if (rowCount == 1)
        return @[tabs];

    NSMutableArray<NSMutableArray<_NppTabItem *> *> *rows = [NSMutableArray array];
    NSInteger base = n / rowCount;
    NSInteger rem  = n % rowCount;
    NSInteger idx  = 0;
    for (NSInteger r = 0; r < rowCount; r++) {
        NSInteger count = base + (r < rem ? 1 : 0);
        NSMutableArray<_NppTabItem *> *row = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
        for (NSInteger j = 0; j < count && idx < n; j++)
            [row addObject:tabs[idx++]];
        [rows addObject:row];
    }
    return rows;
}

static CGFloat sumTabShrinkFloors(NSArray<_NppTabItem *> *tabs) {
    CGFloat sum = 0;
    for (_NppTabItem *tab in tabs)
        sum += tabShrinkFloor(tab);
    return sum;
}

/// Greedy wrap to learn the minimum row count; when multi-row, assign tabs in
/// balanced counts (12+11 not 20+3) so auto-filled tab widths stay similar.
- (NSArray<NSArray<_NppTabItem *> *> *)_resolvedWrapRowsForTabs:(NSArray<_NppTabItem *> *)tabs
                                                    layoutWidths:(NSArray<NSNumber *> *)layoutWidths
                                                        barWidth:(CGFloat)barW {
    NSArray<NSArray<_NppTabItem *> *> *greedyRows =
        [self _wrapRowsForTabs:tabs widths:layoutWidths barWidth:barW];
    NSInteger minRows = (NSInteger)greedyRows.count;
    if (minRows <= 1) return greedyRows;

    NSInteger n = (NSInteger)tabs.count;
    for (NSInteger rowCount = minRows; rowCount <= n; rowCount++) {
        NSArray<NSArray<_NppTabItem *> *> *rows =
            [self _wrapRowsBalancedForTabs:tabs rowCount:rowCount];

        BOOL allFit = YES;
        for (NSArray<_NppTabItem *> *row in rows) {
            if (sumTabShrinkFloors(row) > barW + 0.5) {
                allFit = NO;
                break;
            }
        }
        if (allFit && !wrapRowsHaveOrphanLast(rows))
            return rows;
    }

    return greedyRows;
}

/// Peel tabs off the end of an over-wide row until the remainder fits at shrink floors.
- (NSArray<NSArray<_NppTabItem *> *> *)_splitRowAtShrinkFloors:(NSArray<_NppTabItem *> *)rowTabs
                                                      barWidth:(CGFloat)barW {
    if (rowTabs.count == 0) return @[];

    NSMutableArray<_NppTabItem *> *row = [rowTabs mutableCopy];
    NSMutableArray<_NppTabItem *> *peeled = [NSMutableArray array];

    while (row.count > 1 && sumTabShrinkFloors(row) > barW + 0.5) {
        [peeled insertObject:row.lastObject atIndex:0];
        [row removeLastObject];
    }

    NSMutableArray<NSArray<_NppTabItem *> *> *result = [NSMutableArray array];
    if (row.count > 0) [result addObject:row];

    if (peeled.count > 0) {
        for (NSArray<_NppTabItem *> *extra in [self _splitRowAtShrinkFloors:peeled barWidth:barW])
            [result addObject:extra];
    }
    return result;
}

- (NSArray<NSArray<_NppTabItem *> *> *)_splitRowsExceedingBarWidth:(NSArray<NSArray<_NppTabItem *> *> *)rows
                                                          barWidth:(CGFloat)barW {
    NSMutableArray<NSArray<_NppTabItem *> *> *result = [NSMutableArray array];
    for (NSArray<_NppTabItem *> *row in rows)
        [result addObjectsFromArray:[self _splitRowAtShrinkFloors:row barWidth:barW]];
    return result;
}

/// Full row pipeline: shrink → balanced assignment → floor-aware split → orphan fix.
- (NSArray<NSArray<_NppTabItem *> *> *)_finalWrapRowsForTabs:(NSArray<_NppTabItem *> *)tabs
                                                    barWidth:(CGFloat)barW
                                               layoutWidths:(NSArray<NSNumber *> * _Nullable)layoutWidths {
    if (!layoutWidths)
        layoutWidths = [self _baseLayoutWidthsForWrapTabs:tabs barWidth:barW];
    NSArray<NSArray<_NppTabItem *> *> *rows =
        [self _resolvedWrapRowsForTabs:tabs layoutWidths:layoutWidths barWidth:barW];
    rows = [self _splitRowsExceedingBarWidth:rows barWidth:barW];

    if (wrapRowsHaveOrphanLast(rows)) {
        rows = [self _wrapRowsBalancedForTabs:tabs rowCount:(NSInteger)rows.count];
        rows = [self _splitRowsExceedingBarWidth:rows barWidth:barW];
    }
    return rows;
}

- (NSArray<NSNumber *> *)_autoSizedWidthsForRowTabs:(NSArray<_NppTabItem *> *)rowTabs
                                        baseWidths:(NSArray<NSNumber *> *)baseWidths
                                          barWidth:(CGFloat)barW {
    NSInteger n = (NSInteger)rowTabs.count;
    if (n == 0) return @[];

    NSMutableArray<NSNumber *> *widths = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    NSMutableArray<NSNumber *> *floors = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    CGFloat sumPref = 0;

    for (NSInteger i = 0; i < n; i++) {
        _NppTabItem *tab = rowTabs[i];
        CGFloat p = (i < (NSInteger)baseWidths.count) ? baseWidths[i].doubleValue : tab.preferredWidth;
        CGFloat f = tabShrinkFloor(tab);
        [widths addObject:@(MAX(p, f))];
        [floors addObject:@(f)];
        sumPref += MAX(p, f);
    }

    if (fabs(sumPref - barW) < 0.5) return widths;

    if (sumPref < barW) {
        NSInteger extraPx = (NSInteger)lround(barW - sumPref);
        NSInteger basePx  = extraPx / n;
        NSInteger remPx   = extraPx % n;
        CGFloat   placed  = 0;
        for (NSInteger i = 0; i < n; i++) {
            CGFloat w = widths[i].doubleValue + (CGFloat)basePx + (i < remPx ? 1.0 : 0.0);
            if (i == n - 1)
                w = MAX(floors[n - 1].doubleValue, barW - placed);
            else
                placed += w;
            widths[i] = @(w);
        }
        return widths;
    }

    // Shrink proportionally down to per-tab floors (short titles stay intact;
    // long titles stop at max-tab pref where middle-ellipsis truncation applies).
    NSMutableArray<NSNumber *> *w = [widths mutableCopy];
    for (NSInteger iter = 0; iter < 32; iter++) {
        CGFloat total = 0;
        for (NSNumber *num in w) total += num.doubleValue;
        if (total <= barW + 0.5) break;

        CGFloat excess = total - barW;
        CGFloat totalShrinkable = 0;
        for (NSInteger i = 0; i < n; i++)
            totalShrinkable += MAX(0, w[i].doubleValue - floors[i].doubleValue);
        if (totalShrinkable < 0.01) break;

        for (NSInteger i = 0; i < n; i++) {
            CGFloat shrinkable = MAX(0, w[i].doubleValue - floors[i].doubleValue);
            if (shrinkable <= 0) continue;
            CGFloat delta = excess * (shrinkable / totalShrinkable);
            w[i] = @(MAX(floors[i].doubleValue, w[i].doubleValue - delta));
        }
    }

    return w;
}

- (void)_layoutWrapTabs:(NSArray<_NppTabItem *> *)tabs
               barWidth:(CGFloat)barW
               neededH:(CGFloat)neededH
               activeH:(CGFloat)activeH
            inactiveH:(CGFloat)inactiveH
               skipItem:(_NppTabItem * _Nullable)skipItem
                gapRect:(NSRect * _Nullable)gapRectOut
            applyFrames:(BOOL)applyFrames {
    if (gapRectOut) *gapRectOut = NSZeroRect;

    NSArray<NSNumber *> *layoutWidths = [self _baseLayoutWidthsForWrapTabs:tabs barWidth:barW];
    NSArray<NSArray<_NppTabItem *> *> *rows =
        [self _finalWrapRowsForTabs:tabs barWidth:barW layoutWidths:layoutWidths];
    BOOL autoFill = rows.count >= 2;
    CGFloat rowStep = activeH + 1;

    void (^placeTab)(NSInteger row, CGFloat x, CGFloat w, _NppTabItem *item, BOOL sel) =
        ^(NSInteger row, CGFloat x, CGFloat w, _NppTabItem *item, BOOL sel) {
            CGFloat y = neededH - (kTabTopGap - kActiveBoost) - activeH - ((CGFloat)row * rowStep);
            NSRect frame = NSMakeRect(x, y, w, sel ? activeH : inactiveH);
            if (skipItem && item == skipItem) {
                if (gapRectOut) *gapRectOut = frame;
                return;
            }
            if (applyFrames) item.frame = frame;
        };

    if (autoFill) {
        NSInteger row = 0;
        for (NSArray<_NppTabItem *> *rowTabs in rows) {
            NSMutableArray<NSNumber *> *rowBase = [NSMutableArray arrayWithCapacity:rowTabs.count];
            for (_NppTabItem *item in rowTabs) {
                NSUInteger idx = [tabs indexOfObjectIdenticalTo:item];
                CGFloat w = (idx != NSNotFound && idx < layoutWidths.count)
                    ? layoutWidths[idx].doubleValue : item.preferredWidth;
                [rowBase addObject:@(w)];
            }
            NSArray<NSNumber *> *widths =
                [self _autoSizedWidthsForRowTabs:rowTabs baseWidths:rowBase barWidth:barW];
            CGFloat x = 0;
            for (NSInteger i = 0; i < (NSInteger)rowTabs.count; i++) {
                _NppTabItem *item = rowTabs[i];
                CGFloat w = widths[i].doubleValue;
                BOOL sel = (item.tabIndex == _selectedIndex);
                placeTab(row, x, w, item, sel);
                x += w;
            }
            row++;
        }
        return;
    }

    CGFloat x = 0;
    NSInteger row = 0;
    for (NSInteger i = 0; i < (NSInteger)tabs.count; i++) {
        _NppTabItem *item = tabs[i];
        CGFloat w = layoutWidths[i].doubleValue;
        if (x + w > barW && x > 0) { x = 0; row++; }
        BOOL sel = (item.tabIndex == _selectedIndex);
        placeTab(row, x, w, item, sel);
        x += w;
    }
}

- (void)_layoutScrollTabs:(NSArray<_NppTabItem *> *)tabs
                 barWidth:(CGFloat)barW
                     barH:(CGFloat)barH
                  activeH:(CGFloat)activeH
               inactiveH:(CGFloat)inactiveH
                 skipItem:(_NppTabItem * _Nullable)skipItem
                  gapRect:(NSRect * _Nullable)gapRectOut
              applyFrames:(BOOL)applyFrames {
    if (gapRectOut) *gapRectOut = NSZeroRect;

    CGFloat totalTabsW = 0;
    for (_NppTabItem *item in tabs) totalTabsW += item.preferredWidth;

    BOOL    needsArrows = (totalTabsW > barW);
    CGFloat arrowsW     = needsArrows ? (2.0 * kArrowBtnW) : 0.0;
    CGFloat scrollW     = barW - arrowsW;

    if (applyFrames) {
        _scrollView.frame = NSMakeRect(0, 0, scrollW, barH);
        _scrollLeftBtn.hidden  = !needsArrows;
        _scrollRightBtn.hidden = !needsArrows;
        if (needsArrows) {
            _scrollLeftBtn.frame  = NSMakeRect(scrollW,              0, kArrowBtnW, barH);
            _scrollRightBtn.frame = NSMakeRect(scrollW + kArrowBtnW, 0, kArrowBtnW, barH);
        }
    }

    CGFloat x = 0;
    for (_NppTabItem *item in tabs) {
        CGFloat w = item.preferredWidth;
        BOOL sel = (item.tabIndex == _selectedIndex);
        if (skipItem && item == skipItem) {
            if (gapRectOut) *gapRectOut = NSMakeRect(x, 1, w, inactiveH);
            x += w;
            continue;
        }
        if (applyFrames)
            item.frame = NSMakeRect(x, 1, w, sel ? activeH : inactiveH);
        x += w;
    }

    if (applyFrames)
        _containerView.frame = NSMakeRect(0, 0, MAX(x, scrollW), barH);
}

- (CGFloat)_preferredHeightForTabs:(NSArray<_NppTabItem *> *)tabs barWidth:(CGFloat)barW {
    if (!_wrapMode || tabs.count == 0) return kTabBarBaseHeight;

    CGFloat inactiveH = kTabBarBaseHeight - kTabTopGap - 1;
    CGFloat activeH   = inactiveH + kActiveBoost;
    CGFloat rowStep   = activeH + 1;
    NSInteger rows = (NSInteger)[self _finalWrapRowsForTabs:tabs barWidth:barW layoutWidths:nil].count;
    if (rows < 1) rows = 1;

    return 1 + ((CGFloat)rows - 1) * rowStep + activeH + (kTabTopGap - kActiveBoost);
}

- (CGFloat)_preferredHeightForWidth:(CGFloat)barW {
    return [self _preferredHeightForTabs:_items barWidth:barW];
}

- (void)_setPreferredHeight:(CGFloat)height {
    height = MAX(kTabBarBaseHeight, ceil(height));
    if (fabs(_preferredHeight - height) < 0.5) return;

    _preferredHeight = height;
    [self invalidateIntrinsicContentSize];
    [self.superview setNeedsLayout:YES];
}

/// Live reorder preview: lays tabs out in drop order with an empty gap where the tab will land.
- (void)_relayoutDragPreview {
    NSInteger from = _dragReorderFromIndex;
    NSInteger to = _dragReorderToIndex;
    NSInteger n = (NSInteger)_items.count;
    if (from < 0 || from >= n || n == 0) return;

    to = MAX(0, MIN(n - 1, to));

    NSArray<_NppTabItem *> *preview = [self _previewTabsMovingFrom:from to:to];
    _NppTabItem *moving = _items[from];

    CGFloat barW = self.bounds.size.width;
    CGFloat barH = self.bounds.size.height;
    if (barW < 1 || barH < 1) return;

    CGFloat inactiveH = kTabBarBaseHeight - kTabTopGap - 1;
    CGFloat activeH = inactiveH + kActiveBoost;

    if (_wrapMode) {
        CGFloat neededH = [self _preferredHeightForTabs:preview barWidth:barW];
        [self _setPreferredHeight:neededH];

        _scrollLeftBtn.hidden = YES;
        _scrollRightBtn.hidden = YES;
        _scrollView.frame = NSMakeRect(0, 0, barW, barH);
        [_scrollView.contentView scrollToPoint:NSZeroPoint];

        [self _layoutWrapTabs:preview barWidth:barW neededH:neededH
                       activeH:activeH inactiveH:inactiveH
                      skipItem:moving gapRect:NULL applyFrames:YES];
        _containerView.frame = NSMakeRect(0, 0, barW, neededH);
        [self setNeedsDisplay:YES];
        return;
    }

    [self _setPreferredHeight:kTabBarBaseHeight];
    [self _layoutScrollTabs:preview barWidth:barW barH:barH
                    activeH:activeH inactiveH:inactiveH
                   skipItem:moving gapRect:NULL applyFrames:YES];
    [self setNeedsDisplay:YES];
}

- (void)relayout {
    if (_dragReorderFromIndex >= 0) {
        [self _relayoutDragPreview];
        return;
    }

    CGFloat barW = self.bounds.size.width;
    CGFloat barH = self.bounds.size.height;
    if (barW < 1 || barH < 1) return;  // not yet sized — skip

    CGFloat inactiveH = kTabBarBaseHeight - kTabTopGap - 1; // visible inactive tab height
    CGFloat activeH   = inactiveH + kActiveBoost;          // active tab is slightly taller

    if (_wrapMode) {
        CGFloat neededH = [self _preferredHeightForWidth:barW];
        [self _setPreferredHeight:neededH];

        _scrollLeftBtn.hidden  = YES;
        _scrollRightBtn.hidden = YES;
        _scrollView.frame = NSMakeRect(0, 0, barW, barH);
        [_scrollView.contentView scrollToPoint:NSZeroPoint];

        [self _layoutWrapTabs:_items barWidth:barW neededH:neededH
                       activeH:activeH inactiveH:inactiveH
                      skipItem:nil gapRect:NULL applyFrames:YES];
        _containerView.frame = NSMakeRect(0, 0, barW, neededH);
        [self setNeedsDisplay:YES];
        return;
    }

    [self _setPreferredHeight:kTabBarBaseHeight];

    [self _layoutScrollTabs:_items barWidth:barW barH:barH
                    activeH:activeH inactiveH:inactiveH
                   skipItem:nil gapRect:NULL applyFrames:YES];
    [self setNeedsDisplay:YES];
}

// Minimal-scroll: only move the viewport if the tab isn't already fully visible.
// New tabs added at right edge scroll into view from the right — never push
// existing tabs off the left.
- (void)scrollTabToVisible:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_items.count) return;
    if (_wrapMode) {
        [_scrollView.contentView scrollToPoint:NSZeroPoint];
        [_scrollView reflectScrolledClipView:_scrollView.contentView];
        return;
    }
    NSRect     tab = _items[index].frame;
    NSClipView *cv = _scrollView.contentView;
    CGFloat     cx = cv.bounds.origin.x;
    CGFloat     sw = _scrollView.bounds.size.width;
    CGFloat     nx = cx;

    if (NSMinX(tab) < cx)           // tab is off the left edge
        nx = NSMinX(tab);
    else if (NSMaxX(tab) > cx + sw) // tab is off the right edge
        nx = NSMaxX(tab) - sw;

    if (nx != cx) {
        [cv scrollToPoint:NSMakePoint(MAX(0, nx), 0)];
        [_scrollView reflectScrolledClipView:cv];
    }
}

#pragma mark - Empty-area gesture

// Called from _NppTabBarContainer when the user double-clicks empty space
// to the right of the last tab (or below the last row in wrap mode). The
// container has already validated that both clicks of the pair landed on
// itself — no further geometry checks needed here.
- (void)_emptyAreaDoubleClicked {
    if ([self.delegate respondsToSelector:@selector(tabBarDidRequestNewTab:)])
        [self.delegate tabBarDidRequestNewTab:self];
}

#pragma mark - Scroll actions

- (void)_scrollLeft:(id)sender {
    NSClipView *cv  = _scrollView.contentView;
    CGFloat     cur = cv.bounds.origin.x;
    [cv scrollToPoint:NSMakePoint(MAX(0, cur - kTabMinWidth), 0)];
    [_scrollView reflectScrolledClipView:cv];
}

- (void)_scrollRight:(id)sender {
    NSClipView *cv   = _scrollView.contentView;
    CGFloat     cur  = cv.bounds.origin.x;
    CGFloat     maxX = MAX(0, _containerView.frame.size.width - _scrollView.bounds.size.width);
    [cv scrollToPoint:NSMakePoint(MIN(maxX, cur + kTabMinWidth), 0)];
    [_scrollView reflectScrolledClipView:cv];
}

#pragma mark - Context menu

/// Walk a menu recursively to find an item by title (case-insensitive, strips shortcuts).
static NSMenuItem *_findMenuItemByTitle(NSMenu *menu, NSString *title) {
    // Match against each item's ORIGINAL ENGLISH title (the localizer stashes it),
    // normalized the same way the localizer normalizes — so this resolves the XML's
    // English MenuItemName regardless of the active UI language AND irons out the
    // "..." vs "…" / accelerator differences. (Old code compared the localized
    // display title verbatim, which dropped every item in non-English languages
    // and the ellipsis items even in English.)
    NSString *target = [NppLocalizer normalizedTitleKey:title];
    for (NSMenuItem *mi in menu.itemArray) {
        if (mi.isSeparatorItem) continue;
        NSString *eng = [NppLocalizer englishTitleOfMenuItem:mi];
        if ([[NppLocalizer normalizedTitleKey:eng] isEqualToString:target]) return mi;

        // Recurse into submenus
        if (mi.submenu) {
            NSMenuItem *found = _findMenuItemByTitle(mi.submenu, title);
            if (found) return found;
        }
    }
    return nil;
}

/// Load tab context menu from XML. Returns nil if file not found or parse fails.
static NSMenu *_buildTabContextMenuFromXML(NSString *xmlPath) {
    NSData *data = [NSData dataWithContentsOfFile:xmlPath];
    if (!data) return nil;

    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:nil];
    if (!doc) return nil;

    NSArray *items = [doc nodesForXPath:@"//TabContextMenu/Item" error:nil];
    if (!items.count) return nil;

    NSMenu *mainMenu = [NSApp mainMenu];
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@""];
    NSMutableDictionary<NSString *, NSMenu *> *folders = [NSMutableDictionary dictionary];
    // Track folder insertion order for consistent submenu placement
    NSMutableArray<NSString *> *folderOrder = [NSMutableArray array];

    for (NSXMLElement *el in items) {
        NSString *folderName = [[el attributeForName:@"FolderName"] stringValue];
        NSString *menuEntry  = [[el attributeForName:@"MenuEntryName"] stringValue];
        NSString *menuItem   = [[el attributeForName:@"MenuItemName"] stringValue];
        NSString *displayAs  = [[el attributeForName:@"ItemNameAs"] stringValue];
        NSString *builtIn    = [[el attributeForName:@"BuiltIn"] stringValue];
        NSInteger itemId     = [[[el attributeForName:@"id"] stringValue] integerValue];

        // Separator
        if ([[el attributeForName:@"id"] stringValue] && itemId == 0) {
            NSMenu *target = folderName.length ? folders[folderName] : contextMenu;
            if (target) [target addItem:[NSMenuItem separatorItem]];
            continue;
        }

        // Built-in special commands (not in main menu)
        if (builtIn.length) {
            if ([builtIn isEqualToString:@"PinTab"]) {
                NSMenuItem *pinItem = [[NSMenuItem alloc] initWithTitle:@"Pin Tab"
                                                                action:@selector(pinCurrentTab:)
                                                         keyEquivalent:@""];
                [contextMenu addItem:pinItem];
            }
            continue;
        }

        if (!menuEntry.length || !menuItem.length) continue;

        // Find the top-level menu matching MenuEntryName by its ENGLISH title
        // (locale-proof — the localized bar shows "Файл" etc., so a verbatim
        // "File" compare failed in non-English languages and dropped every child).
        NSMenu *entryMenu = nil;
        NSString *entryTarget = [NppLocalizer normalizedTitleKey:menuEntry];
        for (NSMenuItem *top in mainMenu.itemArray) {
            if (!top.submenu) continue;
            // Top-level menu *items* have an empty title (the name "File"/"Edit"/…
            // lives on the SUBMENU), so match the submenu's English title; fall
            // back to the item's just in case.
            NSString *engMenu = [NppLocalizer englishTitleOfMenu:top.submenu];
            NSString *engItem = [NppLocalizer englishTitleOfMenuItem:top];
            if ([[NppLocalizer normalizedTitleKey:engMenu] isEqualToString:entryTarget] ||
                [[NppLocalizer normalizedTitleKey:engItem] isEqualToString:entryTarget]) {
                entryMenu = top.submenu;
                break;
            }
        }
        if (!entryMenu) continue;

        // Find the specific item within that menu (recursive search)
        NSMenuItem *found = _findMenuItemByTitle(entryMenu, menuItem);
        if (!found || !found.action) continue;

        // Build context menu item with the resolved action
        NSString *title = displayAs.length ? displayAs : found.title;
        NSMenuItem *ctxItem = [[NSMenuItem alloc] initWithTitle:title
                                                         action:found.action
                                                  keyEquivalent:@""];
        ctxItem.target = found.target;

        // Copy color swatch image from main menu item (for Apply Color items)
        if (found.image) ctxItem.image = found.image;

        // Add to folder submenu or top level
        if (folderName.length) {
            if (!folders[folderName]) {
                folders[folderName] = [[NSMenu alloc] initWithTitle:folderName];
                [folderOrder addObject:folderName];
                NSMenuItem *parent = [[NSMenuItem alloc] initWithTitle:folderName
                                                                action:nil keyEquivalent:@""];
                parent.submenu = folders[folderName];
                parent.tag = 99000 + (NSInteger)folderOrder.count; // unique tag for ordering
                [contextMenu addItem:parent];
            }
            [folders[folderName] addItem:ctxItem];
        } else {
            [contextMenu addItem:ctxItem];
        }
    }

    // Clean up: remove trailing/leading/duplicate separators
    while (contextMenu.numberOfItems > 0 && [contextMenu itemAtIndex:0].isSeparatorItem)
        [contextMenu removeItemAtIndex:0];
    while (contextMenu.numberOfItems > 0 &&
           [contextMenu itemAtIndex:contextMenu.numberOfItems - 1].isSeparatorItem)
        [contextMenu removeItemAtIndex:contextMenu.numberOfItems - 1];

    return contextMenu.numberOfItems > 0 ? contextMenu : nil;
}

- (NSMenu *)buildTabContextMenu {
    // Try user-customized tabContextMenu.xml first
    NSString *configDir = NppConfigDir();
    NSString *customPath = [configDir stringByAppendingPathComponent:@"tabContextMenu.xml"];
    NSMenu *menu = _buildTabContextMenuFromXML(customPath);
    if (menu) return menu;

    // Fall back to bundled default
    NSString *bundledPath = [[NSBundle mainBundle] pathForResource:@"tabContextMenu" ofType:@"xml"];
    menu = _buildTabContextMenuFromXML(bundledPath);
    if (menu) return menu;

    // Ultimate fallback: minimal hardcoded menu
    menu = [[NSMenu alloc] initWithTitle:@""];
    [menu addItemWithTitle:@"Close" action:@selector(closeCurrentTab:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Save" action:@selector(saveDocument:) keyEquivalent:@""];
    return menu;
}

@end
