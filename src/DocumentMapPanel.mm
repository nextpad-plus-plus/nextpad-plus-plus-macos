#import "DocumentMapPanel.h"
#import "ScintillaView.h"
#import "Scintilla.h"
#import "ScintillaMessages.h"
#import "NppThemeManager.h"
#import "StyleConfiguratorWindowController.h"
#import "TabManager.h"

// The map shares the tracked editor's Scintilla document (SCI_SETDOCPOINTER),
// so it must never take keyboard focus: SCI_SETREADONLY is a document
// property, so the map cannot protect itself without making the editor
// read-only too. The viewport overlay already swallows mouse input; this
// content view keeps the map out of the key-view loop and menu targeting,
// and refuses drops: Scintilla's drop path ignores read-only, so a text drag
// from the editor onto the map would otherwise move text in the document.
// _configureMapSci also unregisters its drag types; these overrides are the
// backstop if anything registers them again.
@interface _DMMapContentView : SCIContentView
@end
@implementation _DMMapContentView
- (BOOL)acceptsFirstResponder { return NO; }
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return NSDragOperationNone; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender { return NSDragOperationNone; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender { return NO; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender { return NO; }
@end

@interface _DMMapScintillaView : ScintillaView
@end
@implementation _DMMapScintillaView
+ (Class)contentViewClass { return [_DMMapContentView class]; }
@end

// ─────────────────────────────────────────────────────────────────────────────
@class _DMViewportOverlay;

@interface DocumentMapPanel ()
- (NSRect)_viewportRectForOverlay:(_DMViewportOverlay *)overlay;
- (NSColor *)_viewportColor;
- (void)_overlayMouseDown:(NSPoint)pt;
- (void)_overlayMouseDragged:(NSPoint)pt;
- (void)_overlayScrollWheel:(NSEvent *)event;
@end

// ─────────────────────────────────────────────────────────────────────────────
@interface _DMViewportOverlay : NSView
@property (nonatomic, weak) DocumentMapPanel *panel;
@end

@implementation _DMViewportOverlay

- (BOOL)isOpaque                          { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e    { return YES; }
- (void)cursorUpdate:(NSEvent *)e         { [[NSCursor arrowCursor] set]; }

- (void)drawRect:(NSRect)dirty {
    NSRect vr = [self.panel _viewportRectForOverlay:self];
    if (NSIsEmptyRect(vr)) return;
    [[self.panel _viewportColor] setFill];
    [NSBezierPath fillRect:vr];
}

- (void)mouseDown:(NSEvent *)e {
    [self.panel _overlayMouseDown:[self convertPoint:e.locationInWindow fromView:nil]];
}
- (void)mouseDragged:(NSEvent *)e {
    [self.panel _overlayMouseDragged:[self convertPoint:e.locationInWindow fromView:nil]];
}
- (void)mouseUp:(NSEvent *)e     { /* intentionally empty */ }
- (void)scrollWheel:(NSEvent *)e { [self.panel _overlayScrollWheel:e]; }

@end

// ─────────────────────────────────────────────────────────────────────────────
// Phase 2 migration: title bar + close button + separator formerly owned
// by this file now live in PanelFrame (shared chrome). The panel body is
// just the map Scintilla + viewport overlay, mounted flush to edges.
// ─────────────────────────────────────────────────────────────────────────────

@implementation DocumentMapPanel {
    ScintillaView      *_mapSci;
    sptr_t              _mapDoc;       // document shared with _trackedEditor (0 = own empty doc)
    _DMViewportOverlay *_overlay;
    __weak EditorView  *_trackedEditor;
    NSTimer            *_contentDebounce;
    NSColor            *_viewportColor; // theme-derived; see -_applyChromeForBackground:
    CGFloat             _grabOffset;   // fromTop offset from mouse to rect center at mouseDown
}

// ── Init / dealloc ────────────────────────────────────────────────────────────

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self _buildLayout];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_cursorMoved:)
                   name:EditorViewCursorDidMoveNotification object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_prefsChanged:)
                   name:@"NPPPreferencesChanged" object:nil];
        // In Auto mode the dark-mode switch commits a new editor theme; in
        // forced Light/Dark it only changes the chrome. Either way re-derive.
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_prefsChanged:)
                   name:NPPDarkModeChangedNotification object:nil];
    }
    return self;
}

- (instancetype)init { return [self initWithFrame:NSZeroRect]; }
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_contentDebounce invalidate];
}

// ── Layout ────────────────────────────────────────────────────────────────────

- (void)_buildLayout {
    _mapSci = [[_DMMapScintillaView alloc] initWithFrame:NSZeroRect];
    _mapSci.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_mapSci];
    [NSLayoutConstraint activateConstraints:@[
        [_mapSci.topAnchor      constraintEqualToAnchor:self.topAnchor],
        [_mapSci.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_mapSci.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_mapSci.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
    ]];
    [self _configureMapSci];

    // Files dropped on the map open like files dropped on the editor.
    [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

    _overlay = [[_DMViewportOverlay alloc] initWithFrame:NSZeroRect];
    _overlay.translatesAutoresizingMaskIntoConstraints = NO;
    _overlay.panel = self;
    [self addSubview:_overlay positioned:NSWindowAbove relativeTo:_mapSci];
    [NSLayoutConstraint activateConstraints:@[
        [_overlay.topAnchor      constraintEqualToAnchor:self.topAnchor],
        [_overlay.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_overlay.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_overlay.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
    ]];
}

- (void)_configureMapSci {
    // Not a drop target for text (see _DMMapContentView). File drops are
    // taken by the panel itself and handed to the editor area.
    [_mapSci.content unregisterDraggedTypes];
    // No SCI_SETREADONLY: it would mark the shared document read-only.
    [_mapSci message:SCI_SETMODEVENTMASK     wParam:0];
    for (int m = 0; m < 5; m++)
        [_mapSci message:SCI_SETMARGINWIDTHN wParam:(uptr_t)m lParam:0];
    [_mapSci message:SCI_SETCARETLINEVISIBLE wParam:0];
    [_mapSci message:SCI_SETCARETWIDTH       wParam:0];
    [_mapSci message:SCI_SETHSCROLLBAR       wParam:0];
    [_mapSci message:SCI_SETVSCROLLBAR       wParam:0];
    [_mapSci message:SCI_SETWRAPMODE         wParam:SC_WRAP_NONE];
    [_mapSci message:SCI_STYLESETSIZEFRACTIONAL wParam:STYLE_DEFAULT lParam:400]; // 4pt
    [_mapSci message:SCI_STYLECLEARALL];
    // Indicators live in the shared document; hide them so the editor's
    // find marks, smart highlights and spell-check squiggles do not render
    // with Scintilla's default indicator styles in the map.
    for (int i = 0; i <= INDICATOR_MAX; i++)
        [_mapSci message:SCI_INDICSETSTYLE wParam:(uptr_t)i lParam:INDIC_HIDDEN];
}

// ── Public API ────────────────────────────────────────────────────────────────

- (void)setTrackedEditor:(EditorView *)editor {
    _trackedEditor = editor;
    [self _updateMapContent];
}

// Informal hook called by MainWindowController on every hide path (title-bar
// close, toolbar/menu toggle, plugin hide). A hidden map is not re-targeted
// on tab switches, so drop the shared document now rather than keep a closed
// tab's document alive. Reopening calls -setTrackedEditor: again.
- (void)panelWillClose {
    [self setTrackedEditor:nil];
}

// ── File drops ────────────────────────────────────────────────────────────────
//
// The editor area's NppDropView opens dropped files; it is not an ancestor of
// the side panel, so forward to the one that hosts the tracked editor.

- (nullable NppDropView *)_editorDropView {
    for (NSView *v = _trackedEditor.superview; v; v = v.superview)
        if ([v isKindOfClass:[NppDropView class]]) return (NppDropView *)v;
    return nil;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NppDropView *dv = [self _editorDropView];
    return dv ? [dv draggingEntered:sender] : NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    return [self draggingEntered:sender];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    return [[self _editorDropView] performDragOperation:sender];
}

// ── Content update (debounced) ────────────────────────────────────────────────

- (void)_scheduleContentUpdate {
    [_contentDebounce invalidate];
    _contentDebounce = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                        target:self
                                                      selector:@selector(_updateMapContent)
                                                      userInfo:nil
                                                       repeats:NO];
}

// The map views the editor's own document, so text, lexer state, keyword
// lists and style bytes all come from the editor's lexing; nothing is copied.
// This only re-attaches when the editor swapped documents (file load/reload
// creates a fresh document) and refreshes the per-view style colours.
- (void)_updateMapContent {
    [self _syncDocument];
    [self _applyThemeFromEditor:_trackedEditor];
    [self _syncScroll];
    [_overlay setNeedsDisplay:YES];
}

- (void)_syncDocument {
    EditorView *ed = _trackedEditor;
    sptr_t doc = ed ? [ed.scintillaView message:SCI_GETDOCPOINTER] : 0;
    if (doc == _mapDoc) return;
    // SCI_SETDOCPOINTER adds a reference to the new document and releases
    // the old one; 0 gives the map a fresh empty document of its own.
    [_mapSci message:SCI_SETDOCPOINTER wParam:0 lParam:doc];
    _mapDoc = doc;
}

// ── Theme mirroring ───────────────────────────────────────────────────────────

// Scintilla colours are 0xBBGGRR.
static NSColor *_dmColorFromBGR(sptr_t bgr) {
    return [NSColor colorWithSRGBRed:(bgr & 0xFF) / 255.0
                               green:((bgr >> 8) & 0xFF) / 255.0
                                blue:((bgr >> 16) & 0xFF) / 255.0
                               alpha:1.0];
}

static sptr_t _dmBGRFromColor(NSColor *c) {
    NSColor *rgb = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!rgb) return 0;
    return (sptr_t)lround(rgb.redComponent * 255)
         | ((sptr_t)lround(rgb.greenComponent * 255) << 8)
         | ((sptr_t)lround(rgb.blueComponent * 255) << 16);
}

- (void)_applyThemeFromEditor:(nullable EditorView *)ed {
    ScintillaView *src = ed.scintillaView;
    if (!src) {
        // No editor to mirror: paint the empty map with the theme instead of
        // Scintilla's built-in white, which glares under a dark theme.
        NPPStyleStore *store = [NPPStyleStore sharedStore];
        sptr_t bg = _dmBGRFromColor(store.globalBg);
        [_mapSci message:SCI_STYLESETFORE wParam:STYLE_DEFAULT lParam:_dmBGRFromColor(store.globalFg)];
        [_mapSci message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:bg];
        [self _applyChromeForBackground:_dmColorFromBGR(bg)];
        return;
    }
    sptr_t defaultFg = [src message:SCI_STYLEGETFORE wParam:STYLE_DEFAULT];
    sptr_t defaultBg = [src message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT];
    [_mapSci message:SCI_STYLESETFORE wParam:STYLE_DEFAULT lParam:defaultFg];
    [_mapSci message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:defaultBg];
    [self _applyChromeForBackground:_dmColorFromBGR(defaultBg)];
    // 0-255 so lexer substyles (e.g. LexCPP 128+, LexHTML 192+) are mirrored too.
    for (int s = 0; s < 256; s++) {
        sptr_t fg = [src message:SCI_STYLEGETFORE wParam:(uptr_t)s];
        [_mapSci message:SCI_STYLESETFORE wParam:(uptr_t)s lParam:fg];
        [_mapSci message:SCI_STYLESETBACK wParam:(uptr_t)s lParam:defaultBg];
        [_mapSci message:SCI_STYLESETBOLD wParam:(uptr_t)s
                  lParam:[src message:SCI_STYLEGETBOLD wParam:(uptr_t)s]];
        [_mapSci message:SCI_STYLESETITALIC wParam:(uptr_t)s
                  lParam:[src message:SCI_STYLEGETITALIC wParam:(uptr_t)s]];
    }
}

// The map body is painted with the editor theme, which need not match the
// chrome (dark title bar over a light theme, or the reverse). Key the native
// appearance and the viewport highlight off that background, not -isDark.
- (void)_applyChromeForBackground:(NSColor *)bg {
    _mapSci.appearance = [NppThemeManager appearanceForBackground:bg];
    NSColor *focus = [[NPPStyleStore sharedStore] globalStyleNamed:@"Document map"].fgColor;
    _viewportColor = [[NppThemeManager shared] documentMapViewportColorOnBackground:bg
                                                                         themeColor:focus];
    [_overlay setNeedsDisplay:YES];
}

- (NSColor *)_viewportColor {
    if (!_viewportColor) [self _applyThemeFromEditor:_trackedEditor];
    return _viewportColor;
}

// ── Scroll sync (proportional — immediate on every cursor/scroll event) ───────
//
// Proportional strategy: src at p% of scrollable range → map at p%.
// This lets the viewport rect reach the very top and bottom of the panel.

- (void)_syncScroll {
    EditorView *ed = _trackedEditor;
    if (!ed) return;

    intptr_t srcFirst   = [ed.scintillaView message:SCI_GETFIRSTVISIBLELINE];
    intptr_t srcVisible = MAX((intptr_t)1, [ed.scintillaView message:SCI_LINESONSCREEN]);
    intptr_t srcTotal   = MAX((intptr_t)1, [ed.scintillaView message:SCI_GETLINECOUNT]);
    intptr_t mapTotal   = MAX((intptr_t)1, [_mapSci message:SCI_GETLINECOUNT]);
    intptr_t mapLineH   = MAX((intptr_t)1, [_mapSci message:SCI_TEXTHEIGHT wParam:0]);
    intptr_t panelH     = MAX((intptr_t)1, (intptr_t)_mapSci.bounds.size.height);
    intptr_t mapVisLines = panelH / mapLineH;

    intptr_t maxSrcFirst = MAX((intptr_t)1, srcTotal - srcVisible);
    intptr_t maxMapFirst = MAX((intptr_t)0, mapTotal - mapVisLines);

    CGFloat p = (CGFloat)srcFirst / (CGFloat)maxSrcFirst;
    p = MAX(0.0f, MIN(1.0f, p));
    intptr_t newFirst = (intptr_t)(p * (CGFloat)maxMapFirst + 0.5f);
    newFirst = MAX((intptr_t)0, MIN(maxMapFirst, newFirst));

    intptr_t curFirst = [_mapSci message:SCI_GETFIRSTVISIBLELINE];
    if (newFirst != curFirst)
        [_mapSci message:SCI_SETFIRSTVISIBLELINE wParam:(uptr_t)newFirst];

    [_overlay setNeedsDisplay:YES];
}

// ── Viewport rectangle ────────────────────────────────────────────────────────
//
// The rect is 50% of the viewport-band height. It slides within the band:
// aligned to the band's top at the document start, bottom at document end.
// This guarantees the rect reaches both edges of the panel.
//
// The rect center is a LINEAR function of srcFirst:
//   center_fromTop(srcFirst) = srcFirst * K + rectH/2
//   K = [(maxSrcFirst - maxMapFirst)*mapLineH + (bandH - rectH)] / maxSrcFirst
//
// This linearity is exploited in _dragToFromTop: to compute the exact srcFirst
// for any target mouse position — giving true 1:1 mouse tracking.

- (NSRect)_viewportRectForOverlay:(_DMViewportOverlay *)overlay {
    EditorView *ed = _trackedEditor;
    if (!ed) return NSZeroRect;

    intptr_t srcFirst   = [ed.scintillaView message:SCI_GETFIRSTVISIBLELINE];
    intptr_t srcVisible = MAX((intptr_t)1, [ed.scintillaView message:SCI_LINESONSCREEN]);
    intptr_t srcTotal   = MAX((intptr_t)1, [ed.scintillaView message:SCI_GETLINECOUNT]);
    intptr_t mapFirst   = [_mapSci message:SCI_GETFIRSTVISIBLELINE];
    intptr_t mapTotal   = MAX((intptr_t)1, [_mapSci message:SCI_GETLINECOUNT]);
    intptr_t mapLineH   = MAX((intptr_t)1, [_mapSci message:SCI_TEXTHEIGHT wParam:0]);

    // Pixel positions of the viewport band measured from the top of the map content.
    intptr_t mapVpStart = (srcFirst * mapTotal) / srcTotal;
    intptr_t mapVpEnd   = MIN(mapTotal, ((srcFirst + srcVisible) * mapTotal) / srcTotal + 1);
    CGFloat pixTop  = (CGFloat)(mapVpStart - mapFirst) * (CGFloat)mapLineH;
    CGFloat pixBtm  = (CGFloat)(mapVpEnd   - mapFirst) * (CGFloat)mapLineH;
    CGFloat bandH   = MAX(4.0f, pixBtm - pixTop);
    CGFloat rectH   = bandH * 0.5f;   // 50% of the viewport band

    // Slide: p=0 → rect at band top; p=1 → rect at band bottom.
    intptr_t maxSrcFirst = MAX((intptr_t)1, srcTotal - srcVisible);
    CGFloat p = MAX(0.0f, MIN(1.0f, (CGFloat)srcFirst / (CGFloat)maxSrcFirst));
    CGFloat pixRectTop = pixTop + p * (bandH - rectH);
    CGFloat pixRectBtm = pixRectTop + rectH;

    // Convert from top-origin pixel coords to AppKit (bottom-origin).
    CGFloat h     = overlay.bounds.size.height;
    CGFloat w     = overlay.bounds.size.width;
    CGFloat rectY = h - pixRectBtm;

    if (rectY < 0)          { rectH += rectY; rectY = 0; }
    if (rectH < 2)            rectH = 2;
    if (rectY + rectH > h)    rectH = h - rectY;
    if (rectH <= 0)           return NSZeroRect;

    return NSMakeRect(0, rectY, w, rectH);
}

// ── Mouse handling ────────────────────────────────────────────────────────────
//
// On mouseDown: if the click lands on the rect, record the grab offset so the
// grabbed point tracks the mouse exactly. If outside the rect, snap the rect
// center to the mouse (grabOffset = 0).
//
// On drag: _dragToFromTop: inverts the linear rect-center formula to compute
// the exact srcFirst that places the rect center at the target position.
// Result: 1:1 pixel tracking regardless of document size or panel height.

- (void)_overlayMouseDown:(NSPoint)pt {
    NSRect   vr            = [self _viewportRectForOverlay:_overlay];
    CGFloat  h             = _overlay.bounds.size.height;
    CGFloat  fromTop       = h - pt.y;                        // distance from panel top
    CGFloat  rectCenterFT  = h - NSMidY(vr);                 // rect center, fromTop

    // Grab offset: keeps the exact grab point under the pointer during drag.
    _grabOffset = NSPointInRect(pt, vr) ? (fromTop - rectCenterFT) : 0.0f;

    [self _dragToFromTop:fromTop - _grabOffset];
}

- (void)_overlayMouseDragged:(NSPoint)pt {
    CGFloat fromTop = _overlay.bounds.size.height - pt.y;
    [self _dragToFromTop:fromTop - _grabOffset];
}

// Sets srcFirst so the viewport rect center lands at targetCenterFromTop.
// Uses the analytical inverse of:  center = srcFirst * K + rectH/2
- (void)_dragToFromTop:(CGFloat)targetCenterFromTop {
    EditorView *ed = _trackedEditor;
    if (!ed) return;

    intptr_t srcTotal   = MAX((intptr_t)1, [ed.scintillaView message:SCI_GETLINECOUNT]);
    intptr_t srcVisible = MAX((intptr_t)1, [ed.scintillaView message:SCI_LINESONSCREEN]);
    intptr_t mapTotal   = MAX((intptr_t)1, [_mapSci message:SCI_GETLINECOUNT]);
    intptr_t mapLineH   = MAX((intptr_t)1, [_mapSci message:SCI_TEXTHEIGHT wParam:0]);
    intptr_t panelH     = MAX((intptr_t)1, (intptr_t)_mapSci.bounds.size.height);
    intptr_t mapVisLines = panelH / mapLineH;
    intptr_t maxSrcFirst = MAX((intptr_t)1, srcTotal - srcVisible);
    intptr_t maxMapFirst = MAX((intptr_t)0, mapTotal - mapVisLines);

    // bandH and rectH must match _viewportRectForOverlay: exactly.
    CGFloat bandH = (CGFloat)srcVisible * (CGFloat)mapLineH;
    CGFloat rectH = bandH * 0.5f;

    // K = d(rectCenter)/d(srcFirst) — derived from the proportional-scroll geometry.
    // Since mapTotal == srcTotal (same document), this simplifies to:
    //   K = [(maxSrcFirst - maxMapFirst)*mapLineH + (bandH - rectH)] / maxSrcFirst
    CGFloat K = ((CGFloat)(maxSrcFirst - maxMapFirst) * (CGFloat)mapLineH + (bandH - rectH))
                / (CGFloat)maxSrcFirst;
    if (K < 0.01f) K = 0.01f;   // guard: tiny documents where geometry degenerates

    // Invert: srcFirst = (targetCenter - rectH/2) / K
    intptr_t newSrcFirst = (intptr_t)((targetCenterFromTop - rectH * 0.5f) / K + 0.5f);
    newSrcFirst = MAX((intptr_t)0, MIN(maxSrcFirst, newSrcFirst));

    [ed.scintillaView message:SCI_SETFIRSTVISIBLELINE wParam:(uptr_t)newSrcFirst];
    [self _syncScroll];
}

- (void)_overlayScrollWheel:(NSEvent *)event {
    [_trackedEditor.scintillaView scrollWheel:event];
}

// ── Notifications ─────────────────────────────────────────────────────────────

- (void)_cursorMoved:(NSNotification *)note {
    if (note.object != _trackedEditor) return;
    [self _syncDocument];
    [self _syncScroll];
    [self _scheduleContentUpdate];
}

- (void)_prefsChanged:(NSNotification *)note {
    // Both notifications are posted synchronously and every EditorView
    // re-applies its theme from its own observer. Observers run in
    // registration order, so an editor opened after the map would still hold
    // the old theme here and the map would copy stale colours. Read the
    // editor once the current notification has been delivered to everyone.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self _applyThemeFromEditor:self->_trackedEditor];
    });
}


@end
