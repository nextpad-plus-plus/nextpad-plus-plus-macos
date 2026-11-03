#import <Cocoa/Cocoa.h>
#import "EditorView.h"
#import "NppApplication.h"
#import "Scintilla.h"
#import "NppScintillaIDs.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>
@interface EditorView (Probe)
- (void)updateClickableLinks;
@end
@interface CountingEditor : EditorView
@property int linkScans;
@end
@implementation CountingEditor
- (void)updateClickableLinks { _linkScans++; [super updateClickableLinks]; }
@end
int main(int argc,char**argv){@autoreleasepool{
    [NppApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1000,700)
       styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;
    CountingEditor *editor=[[CountingEditor alloc] initWithFrame:window.contentView.bounds];
    window.contentView=editor;
    ScintillaView *sci=editor.scintillaView;
    NSMutableString *text=[NSMutableString string];
    for(int i=0;i<10000;i++)[text appendFormat:@"%05d alpha beta gamma delta epsilon zeta eta theta iota kappa lambda\n",i];
    [sci setString:text];
    NSBitmapImageRep *image=[editor bitmapImageRepForCachingDisplayInRect:editor.bounds];
    [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:image];
    const long height=[sci message:SCI_TEXTHEIGHT wParam:0];
    const double base=height*100.0;
    [sci.scrollView.contentView scrollToPoint:NSMakePoint(0,base+2.0)];
    [sci.scrollView reflectScrolledClipView:sci.scrollView.contentView];
    [editor updateClickableLinks];
    [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:image];
    double after=sci.scrollView.contentView.bounds.origin.y;
    bool retained=std::abs(after-(base+2.0))<0.01;
    printf("%s link marking + draw preserves fractional origin: requested=%.2f actual=%.2f\n",retained?"PASS":"FAIL",base+2.0,after);
    editor.linkScans=0;
    std::vector<double> times;
    for(int i=0;i<120;i++){@autoreleasepool{
        [sci.scrollView.contentView scrollToPoint:NSMakePoint(0,base+i*120+2.0)];
        [sci.scrollView reflectScrolledClipView:sci.scrollView.contentView];
        double begin=NSDate.timeIntervalSinceReferenceDate;
        [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:image];
        times.push_back((NSDate.timeIntervalSinceReferenceDate-begin)*1000);
    }}
    std::sort(times.begin(),times.end());
    printf("fast_full_editor_draw_ms median=%.3f p95=%.3f max=%.3f link_scans_inside_120_draws=%d\n",times[60],times[114],times.back(),editor.linkScans);
    bool deferred=editor.linkScans==0;
    printf("%s viewport link analysis is outside the paint loop\n",deferred?"PASS":"FAIL");
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:0.2];
    while(until.timeIntervalSinceNow>0)[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:until];
    printf("link_scans_after_idle=%d\n",editor.linkScans);
    bool coalesced=editor.linkScans==1;
    printf("%s rapid viewport changes coalesce into one link refresh\n",coalesced?"PASS":"FAIL");
    // A real link must still be marked after the idle refresh, and removing
    // it in the same viewport must clear the old indicator.
    [sci setString:@"https://example.com hello\n"];
    [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:image];
    until=[NSDate dateWithTimeIntervalSinceNow:0.2];
    while(until.timeIntervalSinceNow>0)[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:until];
    bool linkMarked=[sci message:SCI_INDICATORVALUEAT wParam:kClickableLinkIndicator lParam:0]!=0;
    printf("%s URL still gets its clickable indicator after idle\n",linkMarked?"PASS":"FAIL");
    int scansAfterLink=editor.linkScans;
    [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:image];
    until=[NSDate dateWithTimeIntervalSinceNow:0.2];
    while(until.timeIntervalSinceNow>0)[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:until];
    bool noFeedback=editor.linkScans==scansAfterLink;
    printf("%s link-indicator changes do not trigger another scan\n",noFeedback?"PASS":"FAIL");
    [sci setString:@"plain text with no link\n"];
    [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:image];
    until=[NSDate dateWithTimeIntervalSinceNow:0.2];
    while(until.timeIntervalSinceNow>0)[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:until];
    bool cleared=[sci message:SCI_INDICATORVALUEAT wParam:kClickableLinkIndicator lParam:0]==0;
    printf("%s editing text in the same viewport clears stale links\n",cleared?"PASS":"FAIL");
    [sci setString:@"https://example.com pending close\n"];
    [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:image];
    int scansBeforeClose=editor.linkScans;
    [editor prepareForClose];
    until=[NSDate dateWithTimeIntervalSinceNow:0.2];
    while(until.timeIntervalSinceNow>0)[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:until];
    bool cancelled=editor.linkScans==scansBeforeClose;
    printf("%s closing an editor cancels its pending link refresh\n",cancelled?"PASS":"FAIL");
    return retained&&deferred&&coalesced&&linkMarked&&noFeedback&&cleared&&cancelled?0:1;
}}
