#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"
#import "ScintillaTypes.h"
#import "ScintillaMessages.h"
#import "ScintillaStructures.h"
#import "Debugging.h"
#import "Geometry.h"
#import "Platform.h"
#import "ScintillaCocoa.h"
#import "Scintilla.h"
#include <cstdio>
@interface ScintillaView (Probe)
@property(nonatomic,readonly) Scintilla::Internal::ScintillaCocoa *backend;
@end
int main(int argc,char**argv){@autoreleasepool{
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
 NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,800,500) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
 window.releasedWhenClosed=NO;
 ScintillaView *sci=[[ScintillaView alloc] initWithFrame:window.contentView.bounds];window.contentView=sci;
 [sci setFontName:@"Menlo" size:13 bold:NO italic:NO];
 [sci message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:0x444444];
 [sci message:SCI_STYLESETFORE wParam:STYLE_DEFAULT lParam:0xDDDDDD];
 [sci message:SCI_STYLECLEARALL];
 [sci message:SCI_SETCARETLINEVISIBLE wParam:1];
 [sci message:SCI_SETCARETLINEBACK wParam:0x080808];
 [sci setString:@"FIRST LINE\nsecond line\nthird line\n"];
 int failures=0;
 for(int overshoot : {5,25,70}) for(bool aboveOnly : {false,true}){
  const int width=800,height=aboveOnly?overshoot:overshoot+60;
  NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:width*4 bitsPerPixel:32];
  NSGraphicsContext *graphics=[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
  CGContextRef gc=graphics.CGContext;
  CGContextTranslateCTM(gc,0,height);CGContextScaleCTM(gc,1,-1);
  CGContextTranslateCTM(gc,0,overshoot);
  // Native responsive drawing may include the elastically exposed region.
  const NSRect rect=NSMakeRect(0,-overshoot,width,height);
  sci.backend->WillDraw(rect);
  bool success=sci.backend->Draw(rect,gc);
  int stripes=0;
  for(int row=0;row<overshoot;row++){
   const unsigned char *pixel=bitmap.bitmapData+row*bitmap.bytesPerRow+500*4;
   if(abs(int(pixel[0])-0x44)>2||abs(int(pixel[1])-0x44)>2||abs(int(pixel[2])-0x44)>2||pixel[3]<250)stripes++;
  }
  bool textVisible=aboveOnly;
  if(!aboveOnly) for(int row=overshoot;row<height;row++)for(int x=0;x<100;x++){
   const unsigned char *pixel=bitmap.bitmapData+row*bitmap.bytesPerRow+x*4;
   if(pixel[0]>128 && pixel[1]>128 && pixel[2]>128)textVisible=true;
  }
  printf("%s overshoot=%d above_only=%d non_background_rows=%d text_preserved=%d paint_success=%d\n",stripes==0&&textVisible?"PASS":"FAIL",overshoot,aboveOnly,stripes,textVisible,success);
  failures+=!textVisible;
  failures+=stripes!=0;
  if(argc>1&&!aboveOnly){NSString *path=[NSString stringWithFormat:@"%s-%d.png",argv[1],overshoot];[[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];}
 }
 return failures?1:0;
}}
