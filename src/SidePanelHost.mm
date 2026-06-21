#import "SidePanelHost.h"
#import "PanelFrame.h"
#import "FloatingPanelWindow.h"

// Each panel shows its own content with a PanelFrame-provided title bar +
// close button. Docked panels live inside a vertical NSSplitView; popped
// panels live inside a FloatingPanelWindow, one per panel. The PanelFrame
// is the same NSView in both states — only its superview (and therefore
// its window) changes, so selection / scroll / first-responder / outline
// expansion state survive pop/dock.
//
// The split view holds PanelFrame wrappers, not raw content views. Callers
// continue to pass content views via showPanel:/hidePanel:/hasPanel: —
// SidePanelHost maps content→frame internally via NSMapTable, so existing
// MainWindowController code that does `[host hasPanel:_docMapPanel]`
// works unchanged regardless of pop state.
//
// Resize semantics: whenever the *set* of docked panels changes (show,
// hide, pop-out, dock-back), heights are redistributed equally so N panels
// always start at 1/N each. Between change events, the user can drag any
// divider and the custom sizes hold. Per-panel minimum height is dynamic,
// scaled to the side-area height (Option 1: max(40pt, 10% of total) with
// a safety clamp so N panels at min always fit).

@interface SidePanelHost () <PanelFrameDelegate, NSSplitViewDelegate>
@end

// Dynamic per-panel minimum height. Computed fresh on every drag tick from
// the delegate methods, so it tracks window resizes live. The safety clamp
// at the end guarantees N×min + (N-1)×divider never exceeds the available
// height — without it, on tiny side areas the constrainMin/Max methods
// could become mutually unsatisfiable.
static CGFloat panelMinHeight(NSSplitView *sv) {
    static const CGFloat kAbsoluteFloor = 40.0;  // 24pt title bar + 16pt content sliver
    static const CGFloat kPercentFloor  = 0.10;  // 10% of side-area height

    NSInteger n = (NSInteger)sv.arrangedSubviews.count;
    if (n <= 0) return kAbsoluteFloor;

    CGFloat h = sv.bounds.size.height;
    CGFloat dividers = (CGFloat)(n - 1) * sv.dividerThickness;
    CGFloat available = MAX(0.0, h - dividers);

    CGFloat desired = MAX(kAbsoluteFloor, h * kPercentFloor);
    CGFloat ceiling = (n > 0) ? (available / (CGFloat)n) : kAbsoluteFloor;
    return MIN(desired, ceiling);
}

@implementation SidePanelHost {
    // Vertical NSSplitView (horizontal divider line between panels). Use a
    // split view, not a stack view, so dividers are draggable. arranged-
    // Subviews is the single source of truth for "what's docked."
    NSSplitView *_split;
    // Maps content-view → wrapping PanelFrame. A frame lives here as long
    // as the panel is registered (docked OR popped); its superview tells
    // us which state it's in.
    NSMapTable<NSView *, PanelFrame *> *_frames;
    // Insertion order for stacked display. Kept in sync with _frames.
    NSMutableArray<NSView *> *_order;
    // Maps content-view → FloatingPanelWindow for every currently-popped
    // panel. Strong-to-strong — the host owns the window retain while the
    // panel is popped.
    NSMapTable<NSView *, FloatingPanelWindow *> *_poppedWindows;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _frames         = [NSMapTable strongToStrongObjectsMapTable];
        _order          = [NSMutableArray array];
        _poppedWindows  = [NSMapTable strongToStrongObjectsMapTable];
        [self _buildLayout];
    }
    return self;
}

- (instancetype)init { return [self initWithFrame:NSZeroRect]; }

- (void)_buildLayout {
    _split = [[NSSplitView alloc] init];
    _split.translatesAutoresizingMaskIntoConstraints = NO;
    _split.vertical     = NO;                          // horizontal divider line
    _split.dividerStyle = NSSplitViewDividerStyleThin; // matches outer split views
    _split.delegate     = self;
    [self addSubview:_split];
    [NSLayoutConstraint activateConstraints:@[
        [_split.topAnchor      constraintEqualToAnchor:self.topAnchor],
        [_split.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_split.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_split.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
    ]];
}

// ── Public API ────────────────────────────────────────────────────────────

- (void)showPanel:(NSView *)panel withTitle:(NSString *)title {
    if (!panel) return;

    PanelFrame *frame = [_frames objectForKey:panel];
    if (frame) {
        // Already hosted — just update the title in case the caller wants
        // to refresh a localized string. The frame is already in the stack
        // OR in a floating window; either way, updating the title keeps
        // both surfaces in sync.
        frame.title = title ?: @"";
        FloatingPanelWindow *w = [_poppedWindows objectForKey:panel];
        if (w) w.title = title ?: @"";
        return;
    }

    // First-time registration: wrap in PanelFrame and add to the stack.
    frame = [[PanelFrame alloc] initWithContentView:panel title:(title ?: @"")];
    frame.delegate = self;

    [_frames setObject:frame forKey:panel];
    [_order addObject:panel];

    NSString *cls = NSStringFromClass([panel class]);
    NSString *key = [@"NppFloatingPanelPopped_" stringByAppendingString:cls];
    BOOL shouldPop = [[NSUserDefaults standardUserDefaults] boolForKey:key];

    if (shouldPop) {
        FloatingPanelWindow *w = [[FloatingPanelWindow alloc] initWithPanelFrame:frame];
        [_poppedWindows setObject:w forKey:panel];
        frame.popped = YES;
        [w makeKeyAndOrderFront:nil];
        [self _notifyLayoutChanged];
    } else {
        [self _installFrameInStack:frame];
    }
}

// Add a frame to the bottom of the stack and equalize all docked heights.
// Extracted so popOut/dockBack can reinstall the same frame after a round-
// trip without duplicating layout wiring. NSSplitView in vertical orientation
// sizes arranged-subview width to match the splitview, so explicit
// leading/trailing pins (needed by NSStackView) are dropped.
- (void)_installFrameInStack:(PanelFrame *)frame {
    [_split addArrangedSubview:frame];
    [self _redistributeEqually];
}

- (void)hidePanel:(NSView *)panel {
    if (!panel) return;
    PanelFrame *frame = [_frames objectForKey:panel];
    if (!frame) return;

    // Popped path: close and release the floating window. The PanelFrame
    // is the window's contentView, so closing the window drops the frame
    // from its view hierarchy; clearing our _poppedWindows entry drops the
    // last strong ref and AppKit deallocates the window.
    BOOL wasDocked = NO;
    FloatingPanelWindow *w = [_poppedWindows objectForKey:panel];
    if (w) {
        // Break the window→frame link so any late -windowShouldClose: from
        // a racy close click can't re-enter the hide chain.
        w.delegate = nil;
        // Detach the frame from the window before -close so the frame
        // survives (we discard it explicitly below) and the window's
        // dealloc doesn't drag it down.
        w.contentView = [[NSView alloc] initWithFrame:NSZeroRect];
        [w close];
        [_poppedWindows removeObjectForKey:panel];
    } else {
        // Docked path.
        [_split removeArrangedSubview:frame];
        wasDocked = YES;
    }

    [frame removeFromSuperview];
    [_frames removeObjectForKey:panel];
    [_order removeObject:panel];

    // Only re-equalize when the docked set actually changed. Hiding a
    // popped panel must not disturb the docked layout (the user may have
    // dragged custom heights and we do not want to clobber them).
    if (wasDocked) [self _redistributeEqually];
}

- (BOOL)hasPanel:(NSView *)panel {
    if (!panel) return NO;
    return [_frames objectForKey:panel] != nil;
}

- (BOOL)hasVisiblePanels {
    // Only docked panels count — popped panels live in their own windows
    // and should not keep the side split open.
    return _split.arrangedSubviews.count > 0;
}

- (BOOL)isPanelPopped:(NSView *)panel {
    if (!panel) return NO;
    return [_poppedWindows objectForKey:panel] != nil;
}

- (void)popOutPanel:(NSView *)panel {
    if (!panel) return;
    PanelFrame *frame = [_frames objectForKey:panel];
    if (!frame) return;
    if ([_poppedWindows objectForKey:panel]) return;  // already popped

    // Remove from the split. Any width/height constraints we may have
    // added against _split's anchors die with the removal — AppKit
    // deactivates them as soon as the frame leaves the splitview.
    [_split removeArrangedSubview:frame];
    [frame removeFromSuperview];

    // Re-equalize remaining docked panels before the floating window
    // appears. Doing this before the window construction keeps any
    // side-effects of the new window's appearance (focus, layout) from
    // racing with the splitview's redistribution pass.
    [self _redistributeEqually];

    // Re-parent into a fresh floating window. Assigning contentView moves
    // the frame's view hierarchy into the window; AppKit fires
    // -viewWillMoveToWindow:/-viewDidMoveToWindow: on every descendant so
    // window-sensitive state (e.g. first responder) is rebound cleanly.
    FloatingPanelWindow *w = [[FloatingPanelWindow alloc] initWithPanelFrame:frame];
    [_poppedWindows setObject:w forKey:panel];

    frame.popped = YES;
    [w makeKeyAndOrderFront:nil];

    NSString *cls = NSStringFromClass([panel class]);
    NSString *key = [@"NppFloatingPanelPopped_" stringByAppendingString:cls];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:key];

    [self _notifyLayoutChanged];
}

- (void)dockBackPanel:(NSView *)panel {
    if (!panel) return;
    PanelFrame *frame = [_frames objectForKey:panel];
    if (!frame) return;

    FloatingPanelWindow *w = [_poppedWindows objectForKey:panel];
    if (!w) return;  // not popped

    // Detach the frame from the window so -close doesn't walk into our
    // contentView hierarchy. Assigning contentView to a throwaway NSView
    // is the standard Cocoa way to "evict" a contentView cleanly.
    w.delegate = nil;
    w.contentView = [[NSView alloc] initWithFrame:NSZeroRect];
    [w close];
    [_poppedWindows removeObjectForKey:panel];

    frame.popped = NO;
    [self _installFrameInStack:frame];

    NSString *cls = NSStringFromClass([panel class]);
    NSString *key = [@"NppFloatingPanelPopped_" stringByAppendingString:cls];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:key];

    [self _notifyLayoutChanged];
}

- (void)_notifyLayoutChanged {
    id<SidePanelHostDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(sidePanelHostDidChangePanelLayout:)])
        [d sidePanelHostDidChangePanelLayout:self];
}

// ── PanelFrameDelegate ────────────────────────────────────────────────────

- (void)panelFrameRequestedClose:(PanelFrame *)frame {
    NSView *contentView = frame.contentView;
    if (!contentView) return;
    id<SidePanelHostDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(sidePanelHost:didRequestCloseForContentView:)])
        [d sidePanelHost:self didRequestCloseForContentView:contentView];
}

- (void)panelFrameRequestedTogglePop:(PanelFrame *)frame {
    NSView *contentView = frame.contentView;
    if (!contentView) return;
    if ([self isPanelPopped:contentView])
        [self dockBackPanel:contentView];
    else
        [self popOutPanel:contentView];
}

// ── Equal-redistribute on docked-set change ───────────────────────────────
//
// Called from showPanel:/_installFrameInStack: (after add), hidePanel:
// (after docked-path remove), and popOutPanel: (after remove). Forces
// layout first so bounds reflect the current side-area height; if the
// host has not yet been sized by its parent split (first show before
// MainWindowController's _editorSplitView lays out), defers one runloop
// turn so the bounds are valid by the time we set divider positions.
- (void)_redistributeEqually {
    NSArray<__kindof NSView *> *subs = _split.arrangedSubviews;
    NSInteger n = (NSInteger)subs.count;
    if (n < 2) return;  // 0 or 1 panel: no dividers to position

    // Force a synchronous layout so bounds are accurate.
    [_split layoutSubtreeIfNeeded];
    CGFloat totalH = _split.bounds.size.height;
    if (totalH <= 0.0) {
        // Host not yet sized — defer one runloop turn. By then the parent
        // split has placed us and bounds are valid. Capture self weakly
        // because the host could in principle be torn down between turns.
        __weak SidePanelHost *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf _redistributeEqually];
        });
        return;
    }

    CGFloat divider   = _split.dividerThickness;
    CGFloat available = MAX(0.0, totalH - (CGFloat)(n - 1) * divider);
    CGFloat slice     = available / (CGFloat)n;

    // Walk top-down, setting each divider's y to the boundary between
    // panel i and panel i+1. The delegate methods may clamp on tiny
    // areas; the safety clamp inside panelMinHeight() guarantees the
    // requested positions are at least achievable.
    for (NSInteger i = 0; i < n - 1; i++) {
        CGFloat pos = (CGFloat)(i + 1) * slice + (CGFloat)i * divider;
        [_split setPosition:pos ofDividerAtIndex:i];
    }
}

// ── NSSplitViewDelegate ───────────────────────────────────────────────────

// Disable drag-collapse. Panels are hidden via the title-bar X button —
// allowing a divider drag to fully collapse a panel would leave it in a
// confusing zero-height state with no visible affordance to recover.
- (BOOL)splitView:(NSSplitView *)sv canCollapseSubview:(NSView *)sub {
    return NO;
}

// Floor on divider position from above. Divider `idx` separates the
// arranged subview at `idx` from the one at `idx+1`. The divider's
// minimum y is the sum of fixed-height subviews above it plus the
// minimum height required for subview `idx` itself.
- (CGFloat)splitView:(NSSplitView *)sv
    constrainMinCoordinate:(CGFloat)proposed
              ofSubviewAt:(NSInteger)idx
{
    CGFloat kMin = panelMinHeight(sv);
    NSArray<__kindof NSView *> *subs = sv.arrangedSubviews;
    if (idx < 0 || idx >= (NSInteger)subs.count) return proposed;

    CGFloat top = 0.0;
    for (NSInteger i = 0; i < idx; i++) {
        top += subs[i].bounds.size.height + sv.dividerThickness;
    }
    return top + kMin;
}

// Ceiling on divider position from below. Reserves min-height per
// remaining subview (and a divider before each) below the dragged
// divider, so the user cannot crush any subview below the floor.
- (CGFloat)splitView:(NSSplitView *)sv
    constrainMaxCoordinate:(CGFloat)proposed
              ofSubviewAt:(NSInteger)idx
{
    CGFloat kMin = panelMinHeight(sv);
    NSArray<__kindof NSView *> *subs = sv.arrangedSubviews;
    NSInteger n = (NSInteger)subs.count;
    if (idx < 0 || idx >= n - 1) return proposed;

    CGFloat reservedBelow = kMin;  // subview at idx+1 must be at least kMin
    for (NSInteger i = idx + 2; i < n; i++) {
        reservedBelow += sv.dividerThickness + kMin;
    }
    return sv.bounds.size.height - reservedBelow;
}

@end
