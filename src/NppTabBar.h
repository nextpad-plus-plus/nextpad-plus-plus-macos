#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class NppTabBar;

@protocol NppTabBarDelegate <NSObject>
- (void)tabBar:(NppTabBar *)bar didSelectTabAtIndex:(NSInteger)index;
- (void)tabBar:(NppTabBar *)bar didCloseTabAtIndex:(NSInteger)index;
@optional
- (void)tabBar:(NppTabBar *)bar didMoveTabFromIndex:(NSInteger)fromIndex toIndex:(NSInteger)toIndex;
/// Fires when the user double-clicks empty space to the right of the last
/// tab (or below the last row in wrap mode). Implementer typically opens
/// a new untitled tab in the tab manager that owns `bar`. Optional — bars
/// with no implementer simply don't react to the gesture.
- (void)tabBarDidRequestNewTab:(NppTabBar *)bar;

// ── Tab tear-off ──
// A drag that leaves the bar (vertically past a small band, or out of its
// window) detaches the tab. Released over another visible NppTabBar, the tab
// is offered to that bar; released anywhere else, it is torn off. A delegate
// that implements neither of the did… methods keeps every drag inside the bar.

/// Whether the tab may be torn off into a new window. Not consulted for a
/// drop onto another bar. Defaults to YES when not implemented.
- (BOOL)tabBar:(NppTabBar *)bar canDetachTabAtIndex:(NSInteger)index;
/// The tab was released outside every tab bar. `screenPoint` is the pointer
/// position in screen coordinates.
- (void)tabBar:(NppTabBar *)bar didDetachTabAtIndex:(NSInteger)index
     atScreenPoint:(NSPoint)screenPoint;
/// The tab was released over `target` (another bar, possibly in another
/// window) at insertion slot `targetIndex` (0…target.tabCount).
- (void)tabBar:(NppTabBar *)bar didDropTabAtIndex:(NSInteger)index
      onTabBar:(NppTabBar *)target atIndex:(NSInteger)targetIndex;
@end

/// Left-aligned tab bar styled after Nextpad++.
@interface NppTabBar : NSView

@property (nonatomic, weak, nullable) id<NppTabBarDelegate> delegate;
@property (nonatomic, readonly) NSInteger selectedIndex;
@property (nonatomic, readonly) NSInteger tabCount;

- (void)addTabWithTitle:(NSString *)title modified:(BOOL)modified;
/// Insert a tab at `index` (clamped to 0…tabCount). The selection stays on
/// the tab that was selected.
- (void)insertTabWithTitle:(NSString *)title modified:(BOOL)modified atIndex:(NSInteger)index;
- (void)removeTabAtIndex:(NSInteger)index;
- (void)setTitle:(NSString *)title modified:(BOOL)modified atIndex:(NSInteger)index;
- (void)selectTabAtIndex:(NSInteger)index;

/// Pin or unpin the tab at index. Pinned tabs hide the × button and block close.
- (void)pinTabAtIndex:(NSInteger)index toggle:(BOOL)toggle;
/// Returns YES if the tab at index is pinned.
- (BOOL)isTabPinnedAtIndex:(NSInteger)index;

/// Swap two tab items by index (preserves all properties including pin and color).
- (void)swapTabAtIndex:(NSInteger)a withIndex:(NSInteger)b;

/// Set a per-tab color identifier (-1 = none/default orange, 0–4 = color 1–5).
- (void)setTabColorAtIndex:(NSInteger)index colorId:(NSInteger)colorId;
/// Returns the color identifier for the tab at index (-1 if none).
- (NSInteger)tabColorAtIndex:(NSInteger)index;
/// The fill NSColor for a color identifier (0–4), or nil for -1/none. Lets other
/// UI (e.g. the Document List) tint records to match a colored tab.
+ (nullable NSColor *)tabFillColorForId:(NSInteger)colorId;

/// When YES tabs wrap to multiple rows instead of scrolling horizontally.
/// The view's intrinsic height grows to fit all rows.
@property (nonatomic) BOOL wrapMode;

/// Recompute tab frames after a preference change (max width, close button, etc.).
- (void)relayout;

/// Builds the tab right-click context menu (from tabContextMenu.xml, with a
/// bundled fallback). Exposed so other surfaces — e.g. the Document List
/// panel — can present the identical menu. The menu's commands act on the
/// current document, so callers should select the target tab first.
- (NSMenu *)buildTabContextMenu;

@end

NS_ASSUME_NONNULL_END
