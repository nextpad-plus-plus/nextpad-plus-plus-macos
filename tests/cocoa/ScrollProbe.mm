#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"
#import "Scintilla.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

// Substitute only the current input-event metadata; all editor/scrolling/drawing
// code below is the real Cocoa Scintilla implementation. No OS events are posted.
@interface ProbeEvent : NSEvent
@property BOOL precise;
@end
@implementation ProbeEvent
- (NSEventType)type { return NSEventTypeScrollWheel; }
- (BOOL)hasPreciseScrollingDeltas { return _precise; }
@end
@interface ProbeApplication : NSApplication
@property NSEvent *probeEvent;
@end
@implementation ProbeApplication
- (NSEvent *)currentEvent { return _probeEvent; }
@end
static int failures = 0;
static void check(bool ok, const char *name) {
    printf("%s %s\n", ok ? "PASS" : "FAIL", name);
    failures += !ok;
}
static double adjust(ScintillaView *editor, double y) {
    NSRect r = editor.scrollView.contentView.bounds;
    r.origin.y = y;
    return [editor.content adjustScroll:r].origin.y;
}
static void scroll(ScintillaView *editor, double y) {
    NSClipView *clip = editor.scrollView.contentView;
    [clip scrollToPoint:NSMakePoint(0, y)];
    [editor.scrollView reflectScrolledClipView:clip];
}
int main(int argc, char **argv) {
    @autoreleasepool {
        ProbeApplication *app = [ProbeApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1000,700)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        ScintillaView *editor = [[ScintillaView alloc] initWithFrame:window.contentView.bounds];
        window.contentView = editor;
        [editor setFontName:@"Menlo" size:13 bold:NO italic:NO];
        [editor message:SCI_SETMARGINTYPEN wParam:0 lParam:SC_MARGIN_NUMBER];
        [editor message:SCI_SETMARGINWIDTHN wParam:0 lParam:50];
        [editor message:SCI_SETLAYOUTCACHE wParam:SC_CACHE_PAGE];
        NSMutableString *text = [NSMutableString string];
        for (int i=0; i<10000; ++i)
            [text appendFormat:@"%05d  alpha beta gamma delta epsilon zeta eta theta iota kappa lambda\n", i];
        [editor setString:text];
        [editor layoutSubtreeIfNeeded];
        NSBitmapImageRep *bitmap = [editor bitmapImageRepForCachingDisplayInRect:editor.bounds];
        [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:bitmap];
        const long h = [editor message:SCI_TEXTHEIGHT wParam:0];
        const double base = h * 100.0;
        printf("line_height=%ld document_lines=10000 viewport=1000x700\n", h);
        // Optional images of the real rendered viewport for visual/row alignment QA.
        if (argc > 1) {
            for (int offset : {0, 2}) {
                scroll(editor, base);
                scroll(editor, adjust(editor, base + offset));
                [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:bitmap];
                NSString *path = [NSString stringWithFormat:@"%s-%d.png", argv[1], offset];
                [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                    writeToFile:path atomically:YES];
            }
        }
        scroll(editor, base);
        ProbeEvent *event = [ProbeEvent new];
        event.precise = YES;
        app.probeEvent = event;
        printf("precise_requested=%.2f adjusted=%.2f\n", base+2, adjust(editor,base+2));
        check(std::abs(adjust(editor,base+2)-(base+2)) < 0.01,
            "precise input retains a two-point movement smaller than one line");
        check(std::abs(adjust(editor,base+0.5)-(base+0.5)) < 0.01,
            "precise input retains a fractional-point movement");
        app.probeEvent = nil;
        check(std::abs(adjust(editor,base+3)-(base+3)) < 0.01,
            "animation/momentum without a current wheel event retains pixel position");
        app.probeEvent = event;
        event.precise = NO;
        check(std::abs(adjust(editor,base+2)-(base+h)) < 0.01,
            "a slow discrete wheel notch still advances a whole line");
        check(std::abs(adjust(editor,base-2)-(base-h)) < 0.01,
            "a slow reverse discrete wheel notch still advances a whole line");
        event.precise = YES;
        check(adjust(editor,-4) == -4, "top elastic overscroll is not snapped");
        app.probeEvent = nil;
        [editor message:SCI_SETFIRSTVISIBLELINE wParam:100];
        check(std::abs(editor.scrollView.contentView.bounds.origin.y-base)<0.01,
            "Go To Line remains aligned to the requested display line");
        app.probeEvent = event;
        int moved=0, held=0; double maxStep=0, previous=base;
        std::vector<double> ms;
        for (int i=1; i<=120; ++i) {
            @autoreleasepool {
                double y=adjust(editor, base+i*2.0);
                double d=std::abs(y-previous);
                moved += d>0.01; held += d<=0.01; maxStep=std::max(maxStep,d);
                scroll(editor,y);
                double begin=NSDate.timeIntervalSinceReferenceDate;
                [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:bitmap];
                ms.push_back((NSDate.timeIntervalSinceReferenceDate-begin)*1000);
                previous=y;
            }
        }
        std::sort(ms.begin(),ms.end());
        printf("simulated_120Hz_240pt_per_sec moved=%d held=%d max_step_pt=%.2f\n", moved,held,maxStep);
        printf("offscreen_full_view_draw_ms median=%.3f p95=%.3f max=%.3f (not display FPS)\n",ms[60],ms[114],ms.back());
        check(moved==120 && maxStep<=2.01,"slow precise motion changes every sample without line-height jumps");
        scroll(editor,base+3.5);
        long first=[editor message:SCI_GETFIRSTVISIBLELINE];
        check(first==100,"fractional scroll keeps the correct first visible line");
        [editor message:SCI_SETXOFFSET wParam:10];
        check(std::abs(editor.scrollView.contentView.bounds.origin.y-(base+3.5))<0.01,
            "horizontal scroll preserves the fractional vertical offset");
        const long hit = [editor message:SCI_POSITIONFROMPOINT wParam:70 lParam:1];
        check([editor message:SCI_LINEFROMPOSITION wParam:hit] == 100,
            "hit testing at a partially visible first line maps to that line");
        [editor message:SCI_SETSEL wParam:hit lParam:hit+5];
        check(std::abs(editor.scrollView.contentView.bounds.origin.y-(base+3.5))<0.01,
            "selection does not snap the partial line back to a line boundary");
        // Exercise wrapped display lines, not just physical document lines.
        [editor message:SCI_SETWRAPMODE wParam:SC_WRAP_WORD];
        editor.frame = NSMakeRect(0,0,350,700);
        [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:bitmap];
        [editor message:SCI_SETFIRSTVISIBLELINE wParam:100];
        const double wrappedBase = editor.scrollView.contentView.bounds.origin.y;
        check(std::abs(adjust(editor,wrappedBase+2)-(wrappedBase+2))<0.01,
            "precise scrolling also retains sub-line movement with word wrap");
        const double bottom = editor.content.bounds.size.height;
        NSRect endRect = editor.scrollView.contentView.bounds;
        endRect.origin.y = bottom - endRect.size.height + 4;
        check([editor.content adjustScroll:endRect].origin.y == endRect.origin.y,
            "bottom elastic overscroll is not snapped");
        // Fast scrolling and partial first lines in a dark theme. A fresh
        // bitmap each time detects unpainted strips instead of preserving a
        // previous frame's pixels.
        [editor message:SCI_SETWRAPMODE wParam:SC_WRAP_NONE];
        editor.frame = NSMakeRect(0,0,1000,700);
        [editor message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:0x404040];
        [editor message:SCI_STYLESETFORE wParam:STYLE_DEFAULT lParam:0xDDDDDD];
        [editor message:SCI_STYLECLEARALL];
        int strips = 0;
        std::vector<double> fastMs;
        for (int i=0; i<120; i++) {
            @autoreleasepool {
                const double y = base + i*120.0 + (i%29)*0.5;
                scroll(editor,adjust(editor,y));
                NSBitmapImageRep *frame = [editor bitmapImageRepForCachingDisplayInRect:editor.bounds];
                const double begin=NSDate.timeIntervalSinceReferenceDate;
                [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:frame];
                fastMs.push_back((NSDate.timeIntervalSinceReferenceDate-begin)*1000);
                const int x=800;
                for (int row=0;row<h;row++) {
                    const unsigned char *pixel=frame.bitmapData+row*frame.bytesPerRow+x*frame.samplesPerPixel;
                    if (pixel[0] < 50 || pixel[1] < 50 || pixel[2] < 50) { strips++; break; }
                }
                if (argc>1 && i==17) {
                    NSString *path=[NSString stringWithFormat:@"%s-fast.png",argv[1]];
                    [[frame representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                        writeToFile:path atomically:YES];
                }
            }
        }
        std::sort(fastMs.begin(),fastMs.end());
        printf("fast_120_samples_14400pt_per_sec black_top_strips=%d draw_ms_median=%.3f p95=%.3f max=%.3f\n",
            strips,fastMs[60],fastMs[114],fastMs.back());
        check(strips==0,"fast dark-theme scrolling paints every partial first line");
        app.probeEvent=nil;
        printf("failures=%d\n", failures);
        return failures ? 1 : 0;
    }
}
