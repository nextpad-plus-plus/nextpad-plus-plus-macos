#import <Cocoa/Cocoa.h>
#import "EditorView.h"
#import "NppApplication.h"
#import "MainWindowController.h"
#import "DocumentMapPanel.h"
#import "UserDefineLangManager.h"
#import "PreferencesWindowController.h"
#import "NppScintillaIDs.h"
#import "Scintilla.h"
#import "SciLexer.h"
#include <cstdio>
#include <initializer_list>
@interface EditorView (WorkProbe)
- (void)applyPreferencesFromDefaults;
- (void)updateSmartHighlight;
- (void)updateBraceHighlight;
- (void)notification:(SCNotification *)note;
@end
@interface MainWindowController (WorkProbe)
- (void)setUDLLanguageFromMenu:(id)sender;
- (void)editorCursorMoved:(NSNotification *)note;
- (void)updateStatusBar;
- (void)refreshCurrentTab;
@end
@interface DocumentMapPanel (WorkProbe)
- (void)_applyThemeFromEditor:(EditorView *)editor;
@end
@interface WorkEditor : EditorView
@property int smartCalls;
@property int braceCalls;
@property int styleNotifications;
@end
@implementation WorkEditor
- (void)notification:(SCNotification *)note {
    if (note->nmhdr.code==SCN_MODIFIED && (note->modificationType & SC_MOD_CHANGESTYLE)) self.styleNotifications++;
    [super notification:note];
}
- (void)updateSmartHighlight { self.smartCalls++; [super updateSmartHighlight]; }
- (void)updateBraceHighlight { self.braceCalls++; [super updateBraceHighlight]; }
@end
@interface WorkHost : MainWindowController
@property EditorView *tracked;
@property int statusCalls;
@property int tabCalls;
@end
@implementation WorkHost
- (EditorView *)currentEditor { return self.tracked; }
- (void)updateStatusBar { self.statusCalls++; }
- (void)refreshCurrentTab { self.tabCalls++; }
@end
@interface WorkMap : DocumentMapPanel
@property int themeCalls;
@end
@implementation WorkMap
- (void)_applyThemeFromEditor:(EditorView *)editor { self.themeCalls++; [super _applyThemeFromEditor:editor]; }
@end
static void idle(double seconds) {
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(until.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:until];
}
int main(){@autoreleasepool{
    [NppApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    [[NSUserDefaults standardUserDefaults] setVolatileDomain:@{kPrefSmartHighlight:@YES} forName:NSArgumentDomain];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;
    WorkEditor *ed=[[WorkEditor alloc] initWithFrame:window.contentView.bounds]; window.contentView=ed;
    ScintillaView *sci=ed.scintillaView;
    NSMutableString *text=[NSMutableString string]; for(int i=0;i<400;i++) [text appendString:@"alpha beta alpha\n"];
    [sci setString:text]; [sci message:SCI_SETSEL wParam:0 lParam:5];
    NSBitmapImageRep *image=[ed bitmapImageRepForCachingDisplayInRect:ed.bounds];
    [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:image]; idle(.2);
    WorkHost *host=[[WorkHost alloc] initWithWindow:nil]; host.tracked=ed;
    id observer=[[NSNotificationCenter defaultCenter] addObserverForName:EditorViewCursorDidMoveNotification object:ed queue:nil usingBlock:^(NSNotification *note){ [host editorCursorMoved:note]; }];
    WorkMap *map=[[WorkMap alloc] initWithFrame:NSMakeRect(0,0,140,600)]; [map setTrackedEditor:ed]; idle(.3);
    ed.smartCalls=ed.braceCalls=host.statusCalls=host.tabCalls=map.themeCalls=0;
    for(int i=1;i<=12;i++) {
        [sci.scrollView.contentView scrollToPoint:NSMakePoint(0,i*30+2)];
        [sci.scrollView reflectScrolledClipView:sci.scrollView.contentView];
        [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:image];
    }
    idle(.35);
    bool quiet=ed.smartCalls==0 && ed.braceCalls==0 && host.statusCalls==0 && host.tabCalls==0 && map.themeCalls==0;
    printf("%s pure scrolling: smart=%d brace=%d status=%d tabs=%d mapThemes=%d\n",quiet?"PASS":"FAIL",ed.smartCalls,ed.braceCalls,host.statusCalls,host.tabCalls,map.themeCalls);
    bool selected=[sci message:SCI_INDICATORVALUEAT wParam:kHighlightIndicator lParam:11]!=0;
    printf("%s selected-word matches survive scrolling\n",selected?"PASS":"FAIL");
    [host editorCursorMoved:[NSNotification notificationWithName:EditorViewCursorDidMoveNotification object:ed]];
    bool manual=host.statusCalls==1 && host.tabCalls==1;
    printf("%s manual cursor metadata notifications remain supported\n",manual?"PASS":"FAIL");
    ed.smartCalls=ed.braceCalls=0;
    [sci message:SCI_INSERTTEXT wParam:11 lParam:(sptr_t)"alpha "];
    [sci message:SCI_SETSEL wParam:0 lParam:5];
    [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:image];
    bool edited=ed.smartCalls>0 && ed.braceCalls>0 && [sci message:SCI_INDICATORVALUEAT wParam:kHighlightIndicator lParam:17]!=0;
    printf("%s text edits refresh matches for the selected word\n",edited?"PASS":"FAIL");
    [[NSUserDefaults standardUserDefaults] setVolatileDomain:@{kPrefSmartHighlight:@NO} forName:NSArgumentDomain];
    [ed applyPreferencesFromDefaults];
    bool disabled=[sci message:SCI_INDICATORVALUEAT wParam:kHighlightIndicator lParam:17]==0;
    printf("%s disabling smart highlighting clears matches immediately\n",disabled?"PASS":"FAIL");
    [sci setString:@"(abc)\n"]; [sci message:SCI_SETSEL wParam:0 lParam:0];
    [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:image];
    bool brace=[[ed valueForKey:@"lastMatchPos"] longLongValue]==4;
    ed.smartCalls=ed.braceCalls=0;
    [sci message:SCI_STARTSTYLING wParam:0]; [sci message:SCI_SETSTYLING wParam:1 lParam:1];
    [sci message:SCI_SETSTYLING wParam:4 lParam:0];
    [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:image];
    idle(.15);
    bool style=brace && ed.braceCalls>0 && ed.smartCalls==0 && [[ed valueForKey:@"lastMatchPos"] longLongValue]==-1;
    printf("%s lexer style changes invalidate brace matching without word searches\n",style?"PASS":"FAIL");
    sptr_t originalDoc=[sci message:SCI_GETDOCPOINTER];
    map.themeCalls=0;
    [ed setLanguage:@"cpp"];
    [ed setLanguage:@"Python"]; idle(.1);
    ScintillaView *mapSci=[map valueForKey:@"mapSci"];
    bool language=map.themeCalls>0 && [sci message:SCI_GETDOCPOINTER]==originalDoc;
    for(int styleID=0;styleID<256;styleID++) {
        for(unsigned int message : {SCI_STYLEGETFORE,SCI_STYLEGETBOLD,SCI_STYLEGETITALIC})
            language=language && [sci message:message wParam:styleID]==[mapSci message:message wParam:styleID];
    }
    language=language && [mapSci message:SCI_STYLEGETBACK wParam:1]==[sci message:SCI_STYLEGETBACK wParam:STYLE_DEFAULT];
    printf("%s same-document language changes mirror map styles\n",language?"PASS":"FAIL");
    UserDefineLangManager *manager=[UserDefineLangManager shared]; [manager loadAll];
    UserDefinedLang *udl=[manager languageNamed:@"Python"];
    NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:@"Probe UDL" action:nil keyEquivalent:@""];
    item.representedObject=udl.name;
    map.themeCalls=0;
    [host setUDLLanguageFromMenu:item]; idle(.1);
    bool udlMenu=[sci message:SCI_GETLEXER]==SCLEX_USER && udl && map.themeCalls>0 && [ed.currentLanguage isEqualToString:udl.name];
    for(int styleID=0;styleID<256;styleID++)
        udlMenu=udlMenu && [sci message:SCI_STYLEGETFORE wParam:styleID]==[mapSci message:SCI_STYLEGETFORE wParam:styleID];
    printf("%s menu UDL changes mirror map styles\n",udlMenu?"PASS":"FAIL");
    // Direct functions are available to plugins and bypass host language setters.
    idle(.15); map.themeCalls=0;
    SciFnDirect direct=(SciFnDirect)[sci message:SCI_GETDIRECTFUNCTION];
    sptr_t pointer=[sci message:SCI_GETDIRECTPOINTER];
    direct(pointer,SCI_STYLESETFORE,1,0x123456);
    direct(pointer,SCI_STYLESETBOLD,1,1);
    direct(pointer,SCI_STYLESETITALIC,1,1);
    idle(.15);
    bool pluginStyles=map.themeCalls==1 && [mapSci message:SCI_STYLEGETFORE wParam:1]==0x123456 &&
        [mapSci message:SCI_STYLEGETBOLD wParam:1] && [mapSci message:SCI_STYLEGETITALIC wParam:1];
    printf("%s direct plugin style changes coalesce into one map refresh\n",pluginStyles?"PASS":"FAIL");
    idle(.15);
    bool noMapFeedback=map.themeCalls==1;
    printf("%s mirroring map styles does not feed back into another refresh\n",noMapFeedback?"PASS":"FAIL");
    // Force real lazy C++ lexing while an unchanged caret sits at an unmatched brace.
    NSMutableString *code=[NSMutableString stringWithString:@"{\n"];
    for(int line=0;line<2000;line++)[code appendString:@"int alpha = 42; // style this newly exposed line\n"];
    [sci setString:code]; [ed setLanguage:@"cpp"];
    [sci message:SCI_SETIDLESTYLING wParam:SC_IDLESTYLING_NONE];
    [sci message:SCI_CLEARDOCUMENTSTYLE]; [sci message:SCI_STARTSTYLING wParam:0]; [sci message:SCI_SETSEL wParam:0 lParam:0];
    [sci.scrollView.contentView scrollToPoint:NSMakePoint(0,0)];
    [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:image]; idle(.15);
    ed.braceCalls=ed.smartCalls=ed.styleNotifications=0;
    for(int frame=1;frame<=12;frame++) {
        [sci.scrollView.contentView scrollToPoint:NSMakePoint(0,frame*200)];
        [sci.scrollView reflectScrolledClipView:sci.scrollView.contentView];
        [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:image];
    }
    bool lazyDeferred=ed.styleNotifications>0 && ed.braceCalls==0 && ed.smartCalls==0;
    printf("%s lazy lexer changes avoid brace searches inside scrolling (styles=%d braces=%d)\n",
        lazyDeferred?"PASS":"FAIL",ed.styleNotifications,ed.braceCalls);
    idle(.2);
    bool lazyCoalesced=ed.braceCalls==1 && [[ed valueForKey:@"lastMatchPos"] longLongValue]==-1;
    printf("%s lazy lexer changes coalesce to one idle brace refresh\n",lazyCoalesced?"PASS":"FAIL");
    map.themeCalls=0;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NPPPreferencesChanged" object:nil]; idle(.1);
    bool prefs=map.themeCalls>0;
    printf("%s preferences still refresh map styles\n",prefs?"PASS":"FAIL");
    sptr_t newDoc=[sci message:SCI_CREATEDOCUMENT];
    [sci message:SCI_SETDOCPOINTER wParam:0 lParam:newDoc];
    [sci message:SCI_RELEASEDOCUMENT wParam:0 lParam:newDoc];
    [[NSNotificationCenter defaultCenter] postNotificationName:EditorViewCursorDidMoveNotification object:ed];
    bool swapped=[mapSci message:SCI_GETDOCPOINTER]==newDoc;
    printf("%s document replacement reattaches the map\n",swapped?"PASS":"FAIL");
    [[NSNotificationCenter defaultCenter] removeObserver:observer]; [ed prepareForClose];
    return quiet&&selected&&manual&&edited&&disabled&&style&&language&&udlMenu&&pluginStyles&&noMapFeedback&&lazyDeferred&&lazyCoalesced&&prefs&&swapped?0:1;
}}
