#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import "ScintillaView.h"
#include <cmath>
#include <cstdio>
// Recreate the out-of-range clip geometry captured from a real elastic return.
// Seeding bypasses constraints only while installing the fixture, not while
// processing gestures or calculating the document's actual scroll limits.
@interface SeedableClip : NSClipView
@property BOOL installingFixture;
@end
@implementation SeedableClip
- (NSRect)constrainBoundsRect:(NSRect)rect {
    return self.installingFixture ? rect : [super constrainBoundsRect:rect];
}
- (NSPoint)constrainScrollPoint:(NSPoint)point {
    return self.installingFixture ? point : [super constrainScrollPoint:point];
}
@end
@interface FlippedDocument : NSView
@end
@implementation FlippedDocument
- (BOOL)isFlipped { return YES; }
@end
static int failures=0;
static void check(bool okay,const char *name) {
    printf("%s %s\n",okay?"PASS":"FAIL",name); failures+=!okay;
}
static void wheel(NSScrollView *scroll,int dx,int dy,CGScrollPhase phase,
                  CGMomentumScrollPhase momentum=kCGMomentumScrollPhaseNone) {
    CGEventRef cg=CGEventCreateScrollWheelEvent(nullptr,kCGScrollEventUnitPixel,2,dy,dx);
    CGEventSetIntegerValueField(cg,kCGScrollWheelEventIsContinuous,1);
    CGEventSetIntegerValueField(cg,kCGScrollWheelEventScrollPhase,phase);
    CGEventSetIntegerValueField(cg,kCGScrollWheelEventMomentumPhase,momentum);
    [scroll scrollWheel:[NSEvent eventWithCGEvent:cg]];
    CFRelease(cg);
}
static NSPoint seed(SeedableClip *clip,double x,double y) {
    clip.installingFixture=YES; [clip setBoundsOrigin:NSMakePoint(x,y)];
    clip.installingFixture=NO; return clip.bounds.origin;
}
static void end(NSScrollView *scroll) { wheel(scroll,0,0,kCGScrollPhaseEnded); }
int main(){@autoreleasepool{
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,600)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;
    SCIScrollView *scroll=[[SCIScrollView alloc] initWithFrame:window.contentView.bounds];
    window.contentView=scroll;
    SeedableClip *clip=[[SeedableClip alloc] initWithFrame:scroll.bounds];
    scroll.contentView=clip;
    scroll.documentView=[[FlippedDocument alloc] initWithFrame:NSMakeRect(0,0,2000,20000)];
    scroll.horizontalScrollElasticity=NSScrollElasticityAutomatic;
    NSPoint before=seed(clip,-2,5003.5);
    check(before.x<0,"fixture reproduces the captured residual left overscroll");
    wheel(scroll,0,-1,kCGScrollPhaseBegan);
    check(clip.bounds.origin.x==0 && std::abs(clip.bounds.origin.y-before.y)<.001,
        "vertical gesture settles left overscroll without changing Y"); end(scroll);
    before=seed(clip,2000,5003.5);
    double right=[clip constrainBoundsRect:clip.bounds].origin.x;
    wheel(scroll,0,-1,kCGScrollPhaseBegan);
    check(clip.bounds.origin.x==right && std::abs(clip.bounds.origin.y-before.y)<.001,
        "vertical gesture settles right overscroll using actual clip limits"); end(scroll);
    before=seed(clip,-2,5000);
    wheel(scroll,0,0,kCGScrollPhaseBegan);
    check(clip.bounds.origin.x==before.x,"zero-delta begin waits for a direction");
    wheel(scroll,0,-6,kCGScrollPhaseChanged);
    check(clip.bounds.origin.x==0,"vertical direction after zero-delta begin settles overscroll"); end(scroll);
    seed(clip,-2,5000);
    wheel(scroll,1,0,kCGScrollPhaseBegan);
    check(clip.bounds.origin.x<0,"horizontal gesture retains native elastic geometry");
    wheel(scroll,0,-6,kCGScrollPhaseChanged);
    check(clip.bounds.origin.x==0,"initial horizontal jitter does not hide subsequent vertical direction"); end(scroll);
    seed(clip,120,5000); wheel(scroll,0,-1,kCGScrollPhaseBegan);
    check(clip.bounds.origin.x==120,"valid horizontal position is preserved"); end(scroll);
    before=seed(clip,-2,-3);
    wheel(scroll,0,-1,kCGScrollPhaseBegan);
    check(clip.bounds.origin.x==0 && clip.bounds.origin.y==before.y,
        "corner transition preserves the active vertical elastic displacement"); end(scroll);
    before=seed(clip,-2,5000);
    wheel(scroll,10,0,(CGScrollPhase)0,kCGMomentumScrollPhaseBegin);
    check(clip.bounds.origin.x==before.x,"horizontal momentum preserves active horizontal bounce");
    wheel(scroll,0,0,(CGScrollPhase)0,kCGMomentumScrollPhaseEnd);
    // Insets affect the legal horizontal origin; zero is not a universal limit.
    clip.contentInsets=NSEdgeInsetsMake(0,20,0,30);
    before=seed(clip,-50,5000);
    double insetLeft=[clip constrainBoundsRect:clip.bounds].origin.x;
    wheel(scroll,0,-1,kCGScrollPhaseBegan);
    check(clip.bounds.origin.x==insetLeft,"settlement respects configured content insets"); end(scroll);
    // Mirror the captured failure: vertical return at the bottom suppresses
    // horizontal momentum even while X is far from either horizontal edge.
    clip.contentInsets=NSEdgeInsetsMake(0,0,0,0);
    before=seed(clip,400,-2);
    wheel(scroll,-1,0,kCGScrollPhaseBegan);
    check(clip.bounds.origin.y==0 && clip.bounds.origin.x==before.x,
        "horizontal gesture settles top overscroll without changing X"); end(scroll);
    before=seed(clip,400,20000);
    double bottom=[clip constrainBoundsRect:clip.bounds].origin.y;
    wheel(scroll,-1,0,kCGScrollPhaseBegan);
    check(clip.bounds.origin.y==bottom && clip.bounds.origin.x==before.x,
        "horizontal gesture settles bottom overscroll while away from horizontal edges"); end(scroll);
    seed(clip,400,20000); wheel(scroll,0,0,kCGScrollPhaseBegan);
    wheel(scroll,-6,0,kCGScrollPhaseChanged);
    check(clip.bounds.origin.y==bottom,
        "horizontal direction after zero-delta begin settles bottom overscroll"); end(scroll);
    seed(clip,400,20000); wheel(scroll,0,1,kCGScrollPhaseBegan);
    wheel(scroll,-6,0,kCGScrollPhaseChanged);
    check(clip.bounds.origin.y==bottom,
        "initial vertical jitter does not hide subsequent horizontal direction"); end(scroll);
    before=seed(clip,-2,20000);
    wheel(scroll,-1,0,kCGScrollPhaseBegan);
    check(clip.bounds.origin.y==bottom && clip.bounds.origin.x==before.x,
        "corner transition preserves active horizontal elastic displacement"); end(scroll);
    before=seed(clip,400,20000);
    wheel(scroll,0,-1,kCGScrollPhaseBegan);
    check(clip.bounds.origin.y==before.y,
        "vertical gesture retains native vertical elastic geometry"); end(scroll);
    before=seed(clip,400,20000);
    wheel(scroll,0,-10,(CGScrollPhase)0,kCGMomentumScrollPhaseBegin);
    check(clip.bounds.origin.y==before.y,
        "vertical momentum preserves active vertical bounce");
    wheel(scroll,0,0,(CGScrollPhase)0,kCGMomentumScrollPhaseEnd);
    // Native capture: inactive-axis overscroll may appear after the first
    // touch event, so recheck at the distinct touch-to-momentum transition.
    seed(clip,400,5000); wheel(scroll,-1,0,kCGScrollPhaseBegan);
    before=seed(clip,400,bottom+1); end(scroll);
    wheel(scroll,-20,0,(CGScrollPhase)0,kCGMomentumScrollPhaseBegin);
    check(clip.bounds.origin.y==bottom && clip.bounds.origin.x==before.x,
        "momentum start settles bottom residue created late in a horizontal gesture");
    wheel(scroll,0,0,(CGScrollPhase)0,kCGMomentumScrollPhaseEnd);
    seed(clip,400,5000); wheel(scroll,0,-1,kCGScrollPhaseBegan);
    before=seed(clip,-1,5000); end(scroll);
    wheel(scroll,0,-20,(CGScrollPhase)0,kCGMomentumScrollPhaseBegin);
    check(clip.bounds.origin.x==0 && clip.bounds.origin.y==before.y,
        "momentum start settles left residue created late in a vertical gesture");
    wheel(scroll,0,0,(CGScrollPhase)0,kCGMomentumScrollPhaseEnd);
    seed(clip,400,bottom+1);
    wheel(scroll,0,0,(CGScrollPhase)0,kCGMomentumScrollPhaseBegin);
    wheel(scroll,-20,0,(CGScrollPhase)0,kCGMomentumScrollPhaseContinue);
    check(clip.bounds.origin.y==bottom,
        "zero-delta momentum begin waits for the first directional momentum event");
    wheel(scroll,0,0,(CGScrollPhase)0,kCGMomentumScrollPhaseEnd);
    // A new touch while momentum is running must keep its normal cancellation
    // semantics: the host must not keep an armed correction or replay deltas.
    seed(clip,400,5000);
    wheel(scroll,0,0,(CGScrollPhase)0,kCGMomentumScrollPhaseBegin);
    before=seed(clip,-2,5000);
    wheel(scroll,0,0,kCGScrollPhaseMayBegin);
    wheel(scroll,0,-20,(CGScrollPhase)0,kCGMomentumScrollPhaseContinue);
    check(clip.bounds.origin.x==before.x,
        "touch-to-stop clears pending momentum correction without restarting it");
    wheel(scroll,0,0,(CGScrollPhase)0,kCGMomentumScrollPhaseEnd);
    before=seed(clip,-2,bottom+3);
    wheel(scroll,-20,-6,(CGScrollPhase)0,kCGMomentumScrollPhaseBegin);
    check(clip.bounds.origin.x==before.x && clip.bounds.origin.y==before.y,
        "diagonal corner momentum keeps both active elastic displacements");
    wheel(scroll,-20,0,(CGScrollPhase)0,kCGMomentumScrollPhaseContinue);
    check(clip.bounds.origin.y==bottom && clip.bounds.origin.x==before.x,
        "momentum waits for an unambiguous axis before settling the other one");
    wheel(scroll,0,0,(CGScrollPhase)0,kCGMomentumScrollPhaseEnd);
    printf("failures=%d\n",failures);return failures?1:0;
}}
