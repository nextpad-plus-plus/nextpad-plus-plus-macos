/* Run from the repository root in a macOS GUI session (no visible window):
   cmake -S . -B build
   cmake --build build --target scintilla
   clang++ -std=c++17 -fobjc-arc -O2 -I scintilla/cocoa -I scintilla/include tests/cocoa/MarginClippingProbe.mm build/libscintilla.a -framework Cocoa -framework QuartzCore -o build/MarginClippingProbe
   build/MarginClippingProbe
   Paths assume the Unix Makefiles or Ninja CMake layout.
*/
#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"
#import "Scintilla.h"
#include <cstdio>

// Catch a partial first/last line painting outside the ruler on an incremental
// redraw, where neighboring tab/status views are not redrawn to cover it up.
int main() { @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 360)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    ScintillaView *sci = [[ScintillaView alloc] initWithFrame:NSMakeRect(0, 0, 600, 300)];
    [window.contentView addSubview:sci];
    [sci setFontName:@"Menlo" size:22 bold:NO italic:NO];
    [sci message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:0x202020];
    [sci message:SCI_STYLECLEARALL];
    [sci message:SCI_STYLESETBACK wParam:STYLE_LINENUMBER lParam:0x443322];
    [sci message:SCI_STYLESETFORE wParam:STYLE_LINENUMBER lParam:0xFFFFFF];
    [sci message:SCI_SETMARGINTYPEN wParam:0 lParam:SC_MARGIN_NUMBER];
    [sci message:SCI_SETMARGINWIDTHN wParam:0 lParam:80];
    NSMutableString *text = [NSMutableString string];
    for (int i = 0; i < 1000; ++i) [text appendFormat:@"Line %d abc\n", i];
    [sci setString:text];
    NSScrollView *scroll = sci.scrollView;
    [scroll tile];
    NSView *margin = scroll.verticalRulerView;
    const int lineHeight = (int)[sci message:SCI_TEXTHEIGHT wParam:0];
    int failures = 0;
    for (int scale : {1, 2}) for (int buffered : {0, 1}) for (int offset : {1, 7, 13}) {
        [sci message:SCI_SETBUFFEREDDRAW wParam:buffered];
        // Moving the caret invalidates the margin even when the viewport stays put.
        [sci message:SCI_GOTOPOS wParam:[sci message:SCI_POSITIONFROMLINE wParam:276]];
        [scroll.contentView scrollToPoint:NSMakePoint(0, 276 * lineHeight + offset)];
        [scroll reflectScrolledClipView:scroll.contentView];
        const int pad = 40;
        const int right = pad + (int)NSWidth(margin.bounds);
        const int bottom = pad + (int)NSHeight(margin.bounds);
        const int width = (right + pad) * scale, height = (bottom + pad) * scale;
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
            pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4
            hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
            bytesPerRow:width * 4 bitsPerPixel:32];
        NSGraphicsContext *bitmapContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
        CGContextRef gc = bitmapContext.CGContext;
        NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithCGContext:gc flipped:YES];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:context];
        CGContextSetRGBFillColor(gc, 1, 0, 1, 1);
        CGContextFillRect(gc, CGRectMake(0, 0, width, height));
        CGContextTranslateCTM(gc, pad * scale, height - pad * scale);
        CGContextScaleCTM(gc, scale, -scale);
        // AppKit applies the production view's clipping policy, not a test clip.
        [margin displayRectIgnoringOpacity:margin.bounds inContext:context];
        [NSGraphicsContext restoreGraphicsState];
        int escaped = 0, glyphPixels = 0;
        for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
            const unsigned char *pixel = bitmap.bitmapData + y * bitmap.bytesPerRow + x * 4;
            bool outside = x < pad * scale || x >= right * scale ||
                y < pad * scale || y >= bottom * scale;
            if (outside) escaped += pixel[0] != 255 || pixel[1] != 0 || pixel[2] != 255;
            else glyphPixels += pixel[0] > 200 && pixel[1] > 200 && pixel[2] > 200;
        }
        bool passed = escaped == 0 && glyphPixels > 0;
        printf("%s ruler clipping scale=%d buffered=%d offset=%d escaped=%d glyphs=%d\n",
            passed ? "PASS" : "FAIL", scale, buffered, offset, escaped, glyphPixels);
        failures += !passed;
    }
    return failures ? 1 : 0;
}}
