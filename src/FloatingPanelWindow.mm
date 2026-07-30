#import "FloatingPanelWindow.h"
#import "PanelFrame.h"
#import "NppThemeManager.h"

// Default geometry for a freshly-popped panel. setFrameAutosaveName:
// overrides this with the last-used frame whenever one is remembered.
static const CGFloat kDefaultWidth  = 320.0;
static const CGFloat kDefaultHeight = 480.0;
static const CGFloat kFPWIconSize   = 11;

// Default subdir pair — Dock-back / pop-in lives under panels/toolbar/.
static NSImage *_FPWLoadIcon(NSString *name) {
    NSString *subdir = [NppThemeManager shared].isDark
        ? @"icons/dark/panels/toolbar"
        : @"icons/standard/panels/toolbar";
    NSURL *url = [[NSBundle mainBundle] URLForResource:name withExtension:@"png"
                                          subdirectory:subdir];
    NSImage *img = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
    if (img) img.size = NSMakeSize(kFPWIconSize, kFPWIconSize);
    return img;
}

// Load the pin icons from the tabbar/ subtree where they already live.
// `pinned=YES` picks pinTabButton_pinned.png (green tack) regardless of
// theme — the user explicitly specified a single pinned asset. For the
// unpinned state we honor the current theme (standard vs dark).
static NSImage *_FPWLoadPinIcon(BOOL pinned) {
    NSString *name;
    NSString *subdir;
    if (pinned) {
        // Single pinned asset; green tack is visible in both themes.
        name   = @"pinTabButton_pinned";
        subdir = @"icons/standard/tabbar";
    } else {
        name   = @"pinTabButton";
        subdir = [NppThemeManager shared].isDark
            ? @"icons/dark/tabbar"
            : @"icons/standard/tabbar";
    }
    NSURL *url = [[NSBundle mainBundle] URLForResource:name withExtension:@"png"
                                          subdirectory:subdir];
    NSImage *img = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
    if (img) img.size = NSMakeSize(kFPWIconSize, kFPWIconSize);
    return img;
}

// ─────────────────────────────────────────────────────────────────────────────
// _FPWDockBackButton — SF Symbol button lives in the window's native title
// bar (via NSTitlebarAccessoryViewController). Clicking it asks the
// PanelFrame to flip back to docked state through the existing delegate
// chain — same route the in-chrome pop button uses when docked, so both
// paths converge on SidePanelHost.panelFrameRequestedTogglePop:.
// ─────────────────────────────────────────────────────────────────────────────

@interface _FPWDockBackButton : NSButton {
    BOOL _hovering;
}
@end

@implementation _FPWDockBackButton

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.bordered   = NO;
        self.buttonType = NSButtonTypeMomentaryChange;
        self.title      = @"";
        self.toolTip    = @"Dock back";
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

- (void)mouseEntered:(NSEvent *)e { _hovering = YES; [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)e  { _hovering = NO;  [self setNeedsDisplay:YES]; }

- (void)drawRect:(NSRect)dirtyRect {
    // Matches the in-panel toolbar button style exactly: no border at rest,
    // blueish border + light-blue fill (light mode only) on hover/press.
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

    NSImage *icon = _FPWLoadIcon(@"pop_in");
    if (!icon) return;

    NSSize isz = icon.size;
    NSRect target = NSMakeRect(NSMidX(self.bounds) - isz.width / 2.0,
                               NSMidY(self.bounds) - isz.height / 2.0,
                               isz.width, isz.height);
    [icon drawInRect:target
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0
      respectFlipped:YES
               hints:nil];
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// _FPWPinButton — toggle button that flips the enclosing window between
// NSFloatingWindowLevel (pinned, always on top) and NSNormalWindowLevel
// (unpinned, can be covered by other apps).
//
// Draws with the same hover+pressed chrome as _FPWDockBackButton — blue
// border + light-blue fill on hover, no border at rest. Icon switches
// between pinTabButton.png (unpinned, theme-aware) and
// pinTabButton_pinned.png (pinned, single green-tack asset that reads
// well in both themes).
// ─────────────────────────────────────────────────────────────────────────────

@interface _FPWPinButton : NSButton {
    BOOL _hovering;
    BOOL _pinned;
}
- (void)setPinned:(BOOL)pinned;
- (BOOL)pinned;
@end

@implementation _FPWPinButton

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.bordered   = NO;
        self.buttonType = NSButtonTypeMomentaryChange;
        self.title      = @"";
        self.toolTip    = @"Pin window on top";
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

- (void)mouseEntered:(NSEvent *)e { _hovering = YES; [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)e  { _hovering = NO;  [self setNeedsDisplay:YES]; }

- (BOOL)pinned { return _pinned; }

- (void)setPinned:(BOOL)pinned {
    if (_pinned == pinned) return;
    _pinned = pinned;
    self.toolTip = pinned
        ? @"Window is pinned on top — click to unpin"
        : @"Pin window on top";
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    // Same hover/pressed chrome as _FPWDockBackButton so both buttons
    // read as a pair. Border color matches exactly.
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

    NSImage *icon = _FPWLoadPinIcon(_pinned);
    if (!icon) return;

    NSSize isz = icon.size;
    NSRect target = NSMakeRect(NSMidX(self.bounds) - isz.width / 2.0,
                               NSMidY(self.bounds) - isz.height / 2.0,
                               isz.width, isz.height);
    [icon drawInRect:target
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0
      respectFlipped:YES
               hints:nil];
}

@end

@interface FloatingPanelWindow () <NSWindowDelegate>
@property (nonatomic, weak) PanelFrame *panelFrame;
// The live pin button so the window can query its state when toggling,
// and drive its appearance when theme changes. Strong because the
// titlebar accessory view is the real retainer; a weak pointer here is
// safe too, but keeping strong avoids the weak-ref unload dance.
@property (nonatomic, strong) _FPWPinButton *pinButton;
@end

@implementation FloatingPanelWindow

- (instancetype)initWithPanelFrame:(PanelFrame *)frame {
    NSParameterAssert(frame != nil);

    NSRect defaultRect = NSMakeRect(0, 0, kDefaultWidth, kDefaultHeight);
    NSUInteger style = NSWindowStyleMaskTitled    |
                       NSWindowStyleMaskClosable  |
                       NSWindowStyleMaskResizable |
                       NSWindowStyleMaskUtilityWindow;

    self = [super initWithContentRect:defaultRect
                            styleMask:style
                              backing:NSBackingStoreBuffered
                                defer:YES];
    if (!self) return nil;

    _panelFrame           = frame;
    self.title            = frame.title ?: @"";
    // Pin state defaults to unpinned (NSNormalWindowLevel). Prior
    // releases forced every popped panel to always-on-top; now the user
    // opts in via the pin button. The level is set inside
    // -_applyPinnedState: which is called after the window+button are
    // set up and the persisted state has been loaded (see below).
    // Only become key when the user actually interacts with a control
    // inside the panel — keeps typing in the editor snappy.
    self.becomesKeyOnlyIfNeeded = YES;
    self.hidesOnDeactivate      = NO;
    // SidePanelHost owns the strong retain; we don't want AppKit releasing
    // the window object out from under us when the user clicks the red X.
    self.releasedWhenClosed     = NO;
    self.delegate               = self;

    // Install the PanelFrame as the contentView. This reparents its view
    // hierarchy from SidePanelHost's stack into this NSPanel; AppKit sends
    // -viewWillMoveToWindow: / -viewDidMoveToWindow: to every descendant.
    self.contentView = frame;

    // Titlebar accessory — pin button to the left of dock-back. Both
    // buttons are 17×17 (sizes the blue hover chrome), with a 1pt gap
    // between them so they read as a near-touching pair.
    _FPWDockBackButton *dockBtn = [[_FPWDockBackButton alloc]
        initWithFrame:NSMakeRect(0, 0, 17, 17)];
    dockBtn.target = self;
    dockBtn.action = @selector(_dockBackClicked:);
    dockBtn.translatesAutoresizingMaskIntoConstraints = NO;

    _FPWPinButton *pinBtn = [[_FPWPinButton alloc]
        initWithFrame:NSMakeRect(0, 0, 17, 17)];
    pinBtn.target = self;
    pinBtn.action = @selector(_pinClicked:);
    pinBtn.translatesAutoresizingMaskIntoConstraints = NO;
    _pinButton = pinBtn;

    // Holder width: 17 + 1 (gap) + 17 + 4 (trailing pad) + 2 (leading
    // slack) = 41.
    NSView *holder = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 41, 17)];
    [holder addSubview:pinBtn];
    [holder addSubview:dockBtn];
    [NSLayoutConstraint activateConstraints:@[
        // Dock-back pinned to the trailing edge.
        [dockBtn.trailingAnchor constraintEqualToAnchor:holder.trailingAnchor constant:-4],
        [dockBtn.centerYAnchor  constraintEqualToAnchor:holder.centerYAnchor],
        [dockBtn.widthAnchor    constraintEqualToConstant:17],
        [dockBtn.heightAnchor   constraintEqualToConstant:17],

        // Pin button sits 1pt to the left of dock-back (was 2pt —
        // ~30% closer per design request).
        [pinBtn.trailingAnchor  constraintEqualToAnchor:dockBtn.leadingAnchor constant:-1],
        [pinBtn.centerYAnchor   constraintEqualToAnchor:holder.centerYAnchor],
        [pinBtn.widthAnchor     constraintEqualToConstant:17],
        [pinBtn.heightAnchor    constraintEqualToConstant:17],
    ]];

    NSTitlebarAccessoryViewController *acc = [[NSTitlebarAccessoryViewController alloc] init];
    acc.layoutAttribute = NSLayoutAttributeRight;
    acc.view = holder;
    [self addTitlebarAccessoryViewController:acc];

    if (frame.contentView) {
        NSString *cls = NSStringFromClass([frame.contentView class]);
        NSString *autosave = [@"NppFloatingPanelRect_" stringByAppendingString:cls];
        NSString *savedRectStr = [[NSUserDefaults standardUserDefaults] stringForKey:autosave];
        if (savedRectStr.length > 0) {
            NSRect rect = NSRectFromString(savedRectStr);
            BOOL isVisible = NO;
            for (NSScreen *screen in [NSScreen screens]) {
                if (NSIntersectsRect(rect, screen.visibleFrame)) {
                    isVisible = YES;
                    break;
                }
            }
            if (isVisible) {
                [self setFrame:rect display:NO];
            } else {
                [self center];
            }
        } else {
            [self center];
        }
    } else {
        [self center];
    }

    // Restore per-panel pin state from NSUserDefaults. Default is
    // unpinned (NSNormalWindowLevel) — a brand-new pop-out will NOT
    // float on top, but if the user explicitly pinned this panel on a
    // previous run, we honour that.
    [self _applyPinnedState:[self _loadPinnedStateDefault:NO]];

    return self;
}

// ── Pin-state persistence ────────────────────────────────────────────────

// Per-panel NSUserDefaults key. Shares the autosave name with the frame
// autosave so each panel class remembers its pin state independently.
- (NSString *)_pinDefaultsKey {
    if (!self.panelFrame.contentView) return @"";
    NSString *cls = NSStringFromClass([self.panelFrame.contentView class]);
    return [@"NppFloatingPanelPinned_" stringByAppendingString:cls];
}

- (BOOL)_loadPinnedStateDefault:(BOOL)fallback {
    NSString *key = [self _pinDefaultsKey];
    if (key.length == 0) return fallback;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:key] == nil) return fallback;
    return [d boolForKey:key];
}

- (void)_persistPinnedState:(BOOL)pinned {
    NSString *key = [self _pinDefaultsKey];
    if (key.length == 0) return;
    [[NSUserDefaults standardUserDefaults] setBool:pinned forKey:key];
}

// Apply pin state to the window + button. Centralises so the init
// path and the toggle-click path go through the same code.
- (void)_applyPinnedState:(BOOL)pinned {
    self.level         = pinned ? NSFloatingWindowLevel : NSNormalWindowLevel;
    self.floatingPanel = pinned;  // keep NSPanel's property in sync
    [self.pinButton setPinned:pinned];
}

// Toggle action — button click.
- (void)_pinClicked:(id)sender {
    BOOL next = !self.pinButton.pinned;
    [self _applyPinnedState:next];
    [self _persistPinnedState:next];
}

// ── Dock-back action ──────────────────────────────────────────────────────

// Clicking the accessory button routes through the PanelFrame's pop
// delegate — same entry point the in-chrome pop-out button uses when
// docked. SidePanelHost detects current state and flips to docked.
- (void)_dockBackClicked:(id)sender {
    PanelFrame *frame = self.panelFrame;
    id delegate = frame.delegate;
    if ([delegate respondsToSelector:@selector(panelFrameRequestedTogglePop:)])
        [delegate panelFrameRequestedTogglePop:frame];
}

// ── Zoom forwarding ───────────────────────────────────────────────────────
//
// When this window is key, the main menu's Cmd+/-/0 actions dispatch via
// the key window's responder chain. MainWindowController (which handles
// zoom for the main window) is NOT in our chain — it owns the main
// window, not this popped one. Implementing zoomIn:/zoomOut:/resetZoom:
// here puts the floating window itself in the chain so the same shortcut
// keys work, routed to the popped panel's own -panelZoomIn/Out/Reset.
//
// Each method is a no-op if the hosted panel doesn't implement the
// matching zoom selector (plugin panels may not). -respondsToSelector:
// on a nil recipient returns NO, so the `panelFrame` being released
// mid-transition is also safe.

- (void)zoomIn:(id)sender {
    id cv = self.panelFrame.contentView;
    if ([cv respondsToSelector:@selector(panelZoomIn)])
        [cv performSelector:@selector(panelZoomIn)];
}

- (void)zoomOut:(id)sender {
    id cv = self.panelFrame.contentView;
    if ([cv respondsToSelector:@selector(panelZoomOut)])
        [cv performSelector:@selector(panelZoomOut)];
}

- (void)resetZoom:(id)sender {
    id cv = self.panelFrame.contentView;
    if ([cv respondsToSelector:@selector(panelZoomReset)])
        [cv performSelector:@selector(panelZoomReset)];
}

// ── NSWindowDelegate ──────────────────────────────────────────────────────

- (void)windowDidMove:(NSNotification *)notification {
    [self _persistFrameRect];
}

- (void)windowDidResize:(NSNotification *)notification {
    [self _persistFrameRect];
}

- (void)_persistFrameRect {
    if (!self.panelFrame.contentView) return;
    NSString *cls = NSStringFromClass([self.panelFrame.contentView class]);
    NSString *autosave = [@"NppFloatingPanelRect_" stringByAppendingString:cls];
    [[NSUserDefaults standardUserDefaults] setObject:NSStringFromRect(self.frame) forKey:autosave];
}

// Red traffic-light close: route through the PanelFrame's close chain so
// the hide flow (panelWillClose → _setPanelVisible:show:NO → SidePanelHost
// hidePanel:) runs exactly as if the user had clicked the X in the title
// bar. Return NO so AppKit doesn't perform its own close — SidePanelHost's
// hidePanel: will call -[NSWindow close] after cleanup.
- (BOOL)windowShouldClose:(NSWindow *)sender {
    [self.panelFrame simulateCloseClick];
    return NO;
}

@end
