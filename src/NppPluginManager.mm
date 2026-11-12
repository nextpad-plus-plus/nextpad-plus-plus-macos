#import "NppPluginManager.h"
#import "NppPaths.h"
#import "MainWindowController.h"
#import "MenuBuilder.h"        // kMenuTagPlugins
#import "PreferencesWindowController.h"
#import "TabManager.h"
#import "EditorView.h"
#import "ScintillaView.h"

#include <dlfcn.h>
#include <malloc/malloc.h>
#include <string>
#include <vector>
#include <memory>

#include "Scintilla.h"
#include "NppPluginInterfaceMac.h"
#include "NppScintillaIDs.h"

NSNotificationName const NppPluginsDidLoadNotification = @"NppPluginsDidLoadNotification";

// saveSessionToPath: is implemented in MainWindowController.mm but lives outside
// its public header (loadSessionFromPath: IS in the header). Declare it locally
// so the NPPM_SAVECURRENTSESSION handler below can call it without a header
// change. Symmetric to the existing public loadSessionFromPath: API.
@interface MainWindowController (NppPluginManagerPrivate)
- (void)saveSessionToPath:(NSString *)path;
@end

// ═══════════════════════════════════════════════════════════════════════════
// ID Allocator — hands out non-overlapping integer ranges
// ═══════════════════════════════════════════════════════════════════════════

// Hands out IDs from [start, limit): limit itself is never returned.
// Fails when count <= 0, outStart is null, or the request would run past
// limit, matching Windows NPP's IDAllocator. On failure *outStart is not
// written; the NPPM_ALLOCATE* handlers decide what the caller sees.
class IDAllocator {
public:
    IDAllocator() : _start(0), _current(0), _limit(0) {}
    IDAllocator(int start, int limit)
        : _start(start), _current(start), _limit(limit) {}

    bool allocate(int count, int *outStart) {
        if (count <= 0 || !outStart || count > _limit - _current)
            return false;
        *outStart = _current;
        _current += count;
        return true;
    }

    bool isInRange(int id) const {
        return id >= _start && id < _current;
    }

private:
    int _start;
    int _current;
    int _limit;
};

// ═══════════════════════════════════════════════════════════════════════════
// PluginInfo — one loaded plugin
// ═══════════════════════════════════════════════════════════════════════════

struct PluginInfo {
    void           *handle = nullptr;   // dlopen handle
    std::string     moduleName;         // e.g. "ReverseLines"
    std::string     displayName;        // from getName()

    PFUNCSETINFO         pSetInfo       = nullptr;
    PFUNCGETNAME         pGetName       = nullptr;
    PFUNCGETFUNCSARRAY   pGetFuncsArray = nullptr;
    PBENOTIFIED          pBeNotified    = nullptr;
    PMESSAGEPROC         pMessageProc   = nullptr;

    struct FuncItem     *funcItems      = nullptr;
    int                  nbFuncItems    = 0;

    // Per-plugin subscriptions for UI-related Scintilla notifications.
    // Default is "wants everything". A plugin may clear these via
    // NPPM_SETPLUGINSUBSCRIPTIONS (see NppPluginInterfaceMac.h) to opt out
    // of specific notification codes that conflict with host-level behavior.
    BOOL                 wantsUpdateUI  = YES;   // SCN_UPDATEUI
    BOOL                 wantsPainted   = YES;   // SCN_PAINTED

    ~PluginInfo() {
        if (handle)
            dlclose(handle);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Forward declaration of the C sendMessage callback
// ═══════════════════════════════════════════════════════════════════════════

static intptr_t nppSendMessageCallback(uintptr_t handle, uint32_t msg,
                                        uintptr_t wParam, intptr_t lParam);

// ═══════════════════════════════════════════════════════════════════════════
// Opaque handle constants
// ═══════════════════════════════════════════════════════════════════════════

static const uintptr_t kHandleNpp            = 0x4E505000;  // "NPP\0"
static const uintptr_t kHandleScintillaMain  = 0x5343490A;  // "SCI\n"
static const uintptr_t kHandleScintillaSub   = 0x5343490B;  // "SCI\v"

// ═══════════════════════════════════════════════════════════════════════════
// Private interface
// ═══════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════
// Plugin-panel registration record
//
// Wraps an NSView that a plugin has registered as a side panel via
// NPPM_DMM_REGISTERPANEL. Host strong-retains the view via this record so
// plugins that pass `self.contentView` and then release their own reference
// don't leave the host with a dangling pointer (the critical R3 mitigation
// from the Phase 1 design analysis).
// ═══════════════════════════════════════════════════════════════════════════

@interface _NppPluginPanelRecord : NSObject
@property(nonatomic, strong)   NSView   *view;    // strong retain — keeps plugin view alive
@property(nonatomic, copy)     NSString *title;   // copied from lParam at registration
@property(nonatomic, assign)   BOOL      visible; // currently in SidePanelHost stack?
@property(nonatomic, readonly) uint64_t  handle;
- (instancetype)initWithHandle:(uint64_t)h view:(NSView *)v title:(NSString *)t;
@end

@implementation _NppPluginPanelRecord
- (instancetype)initWithHandle:(uint64_t)h view:(NSView *)v title:(NSString *)t {
    self = [super init];
    if (self) { _handle = h; _view = v; _title = [t copy]; _visible = NO; }
    return self;
}
@end

@interface NppPluginManager () {
    __weak MainWindowController *_mwc;

    std::vector<std::unique_ptr<PluginInfo>> _plugins;

    IDAllocator _cmdIDAlloc;
    IDAllocator _markerAlloc;
    IDAllocator _indicatorAlloc;

    BOOL _shutdownFired;
    BOOL _forwardingNotification;  // reentrancy guard for SCN_* forwarding
    int  _nextPluginCmdBase;  // base cmdID for next plugin's FuncItems

    // Plugin-panel registry. Handle → record. Declared AFTER _plugins so
    // ARC releases it FIRST during dealloc: that way the plugin NSViews
    // (whose classes live in dlopen'd dylibs) are deallocated while the
    // dylibs are still mapped, avoiding a message-to-freed-code crash
    // when the panel views' -dealloc runs.
    NSMutableDictionary<NSNumber *, _NppPluginPanelRecord *> *_panelRegistry;
    uint64_t _nextPanelHandle;
}
@end

// ═══════════════════════════════════════════════════════════════════════════
// Implementation
// ═══════════════════════════════════════════════════════════════════════════

@implementation NppPluginManager

+ (instancetype)shared {
    static NppPluginManager *inst;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[NppPluginManager alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Ranges are [first, limit) and must stay clear of every host-owned
        // marker/indicator; see NppScintillaIDs.h for the full map and the
        // compile-time overlap checks.
        _cmdIDAlloc     = IDAllocator(kPluginDynamicCmdIDFirst, kPluginDynamicCmdIDLimit);
        _markerAlloc    = IDAllocator(kPluginMarkerFirst, kPluginMarkerLimit);
        _indicatorAlloc = IDAllocator(kPluginIndicatorFirst, kPluginIndicatorLimit);
        _nextPluginCmdBase = kPluginCmdIDFirst;  // ID_PLUGINS_CMD
        _shutdownFired = NO;

        _panelRegistry   = [NSMutableDictionary dictionary];
        _nextPanelHandle = 1;   // 0 is reserved for "invalid handle"
    }
    return self;
}

- (void)setMainWindowController:(MainWindowController *)mwc {
    _mwc = mwc;
}

// ── Plugin directory ────────────────────────────────────────────────────

static NSString *pluginBaseDir(void) {
    return NppConfigSubpath(@"plugins");
}

// All editors across primary + secondary (V + H split) tab managers, in
// primary-first order. Used by the open-file enumeration messages
// (NPPM_GETNBOPENFILES / NPPM_GETOPENFILENAMES) and NPPM_GETPOSFROMBUFFERID.
// `filter`: 0 = all views, 1 = primary only, 2 = secondary only — matches the
// Windows NPP lParam convention for NPPM_GETNBOPENFILES. KVC for the sub
// tab-manager ivars follows the same access pattern this file already uses
// elsewhere (e.g. _pluginToolbarItems at NPPM_ADDTOOLBARICON handling).
static NSArray<EditorView *> *nppAllEditors(MainWindowController *mwc, int filter) {
    NSMutableArray<EditorView *> *out = [NSMutableArray array];
    if (!mwc) return out;
    if (filter == 0 || filter == 1) {
        TabManager *p = [mwc valueForKey:@"_tabManager"];
        if (p) [out addObjectsFromArray:p.allEditors];
    }
    if (filter == 0 || filter == 2) {
        for (NSString *key in @[@"_subTabManagerV", @"_subTabManagerH"]) {
            TabManager *s = [mwc valueForKey:key];
            if (s) [out addObjectsFromArray:s.allEditors];
        }
    }
    return out;
}

// ── Loading ─────────────────────────────────────────────────────────────

- (void)loadPlugins {
    NSString *baseDir = pluginBaseDir();
    NSFileManager *fm = [NSFileManager defaultManager];

    // Ensure the plugins directory exists
    if (![fm fileExistsAtPath:baseDir]) {
        [fm createDirectoryAtPath:baseDir withIntermediateDirectories:YES attributes:nil error:nil];
        return; // no plugins yet
    }

    // Scan for plugin subdirectories: plugins/PluginName/PluginName.dylib
    NSArray<NSString *> *subdirs = [fm contentsOfDirectoryAtPath:baseDir error:nil];
    if (!subdirs)
        return;

    for (NSString *dirName in subdirs) {
        NSString *dirPath = [baseDir stringByAppendingPathComponent:dirName];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dirPath isDirectory:&isDir] || !isDir)
            continue;

        NSString *dylibName = [dirName stringByAppendingPathExtension:@"dylib"];
        NSString *dylibPath = [dirPath stringByAppendingPathComponent:dylibName];

        if (![fm fileExistsAtPath:dylibPath]) {
            // Also try .bundle extension
            NSString *bundleName = [dirName stringByAppendingPathExtension:@"bundle"];
            NSString *bundlePath = [dirPath stringByAppendingPathComponent:bundleName];
            if ([fm fileExistsAtPath:bundlePath])
                dylibPath = bundlePath;
            else
                continue;
        }

        [self loadPluginAtPath:dylibPath moduleName:dirName];
    }

    if (_plugins.size() > 0) {
        NSLog(@"[Plugins] Loaded %zu plugin(s)", _plugins.size());
    }
}

- (BOOL)loadPluginAtPath:(NSString *)path moduleName:(NSString *)moduleName {
    void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_LOCAL);
    if (!handle) {
        NSLog(@"[Plugins] Failed to load %@: %s", path, dlerror());
        return NO;
    }

    // Resolve required exports
    auto pSetInfo       = (PFUNCSETINFO)       dlsym(handle, "setInfo");
    auto pGetName       = (PFUNCGETNAME)       dlsym(handle, "getName");
    auto pGetFuncsArray = (PFUNCGETFUNCSARRAY)  dlsym(handle, "getFuncsArray");
    auto pBeNotified    = (PBENOTIFIED)         dlsym(handle, "beNotified");
    auto pMessageProc   = (PMESSAGEPROC)        dlsym(handle, "messageProc");

    if (!pSetInfo || !pGetName || !pGetFuncsArray || !pBeNotified) {
        NSLog(@"[Plugins] %@ is missing required exports — skipping", moduleName);
        dlclose(handle);
        return NO;
    }

    // Build NppData for this plugin
    struct NppData nppData;
    nppData._nppHandle            = kHandleNpp;
    nppData._scintillaMainHandle  = kHandleScintillaMain;
    nppData._scintillaSecondHandle = kHandleScintillaSub;
    nppData._sendMessage          = nppSendMessageCallback;

    // Call setInfo (plugin stores handles and initializes FuncItems)
    @try {
        pSetInfo(nppData);
    } @catch (NSException *e) {
        NSLog(@"[Plugins] %@ crashed in setInfo: %@", moduleName, e);
        dlclose(handle);
        return NO;
    }

    // Get plugin name
    const char *name = nullptr;
    @try {
        name = pGetName();
    } @catch (NSException *e) {
        NSLog(@"[Plugins] %@ crashed in getName: %@", moduleName, e);
        dlclose(handle);
        return NO;
    }

    // Get function items
    int nbFunc = 0;
    struct FuncItem *funcItems = nullptr;
    @try {
        funcItems = pGetFuncsArray(&nbFunc);
    } @catch (NSException *e) {
        NSLog(@"[Plugins] %@ crashed in getFuncsArray: %@", moduleName, e);
        dlclose(handle);
        return NO;
    }

    // Assign command IDs to each FuncItem. The static range stops below
    // kPluginDynamicCmdIDFirst so it can never collide with IDs handed out
    // by NPPM_ALLOCATECMDID. Once it is exhausted, remaining items keep
    // _cmdID 0 and get no menu entry. The plugin itself stays loaded:
    // setInfo has already run, so it may own timers or blocks that would
    // dangle if the dylib were unmapped now.
    int nbDropped = 0;
    for (int i = 0; i < nbFunc; i++) {
        if (!funcItems[i]._pFunc) continue;
        if (_nextPluginCmdBase < kPluginCmdIDLimit) {
            funcItems[i]._cmdID = _nextPluginCmdBase++;
        } else {
            funcItems[i]._cmdID = 0;
            nbDropped++;
        }
    }
    if (nbDropped > 0) {
        NSLog(@"[Plugins] %@: plugin command IDs %d-%d exhausted; %d of its "
              @"commands get no menu item.", moduleName,
              kPluginCmdIDFirst, kPluginCmdIDLimit - 1, nbDropped);
    }

    // Store plugin info
    auto pi = std::make_unique<PluginInfo>();
    pi->handle         = handle;
    pi->moduleName     = moduleName.UTF8String;
    pi->displayName    = name ? name : moduleName.UTF8String;
    pi->pSetInfo       = pSetInfo;
    pi->pGetName       = pGetName;
    pi->pGetFuncsArray = pGetFuncsArray;
    pi->pBeNotified    = pBeNotified;
    pi->pMessageProc   = pMessageProc;
    pi->funcItems      = funcItems;
    pi->nbFuncItems    = nbFunc;

    NSLog(@"[Plugins] Loaded \"%s\" (%d commands)", pi->displayName.c_str(), nbFunc);
    _plugins.push_back(std::move(pi));
    return YES;
}

// ── Notifications ───────────────────────────────────────────────────────

- (void)fireReady {
    [self notifyPluginsWithCode:NPPN_READY];
    [self notifyPluginsWithCode:NPPN_TBMODIFICATION];

    [[NSNotificationCenter defaultCenter]
        postNotificationName:NppPluginsDidLoadNotification object:self];
}

- (void)shutdown {
    if (_shutdownFired) return;
    _shutdownFired = YES;

    [self notifyPluginsWithCode:NPPN_BEFORESHUTDOWN];
    [self notifyPluginsWithCode:NPPN_SHUTDOWN];

    // Unload all plugins (destructors call dlclose)
    _plugins.clear();
}

- (void)notifyPluginsWithCode:(unsigned int)code {
    [self notifyPluginsWithCode:code bufferID:0];
}

- (void)notifyPluginsWithCode:(unsigned int)code bufferID:(intptr_t)bufferID {
    if (_shutdownFired && code != NPPN_SHUTDOWN)
        return;

    // Build an SCNotification on the stack
    SCNotification scn = {};
    scn.nmhdr.code     = code;
    scn.nmhdr.hwndFrom = (void *)(uintptr_t)kHandleNpp;
    scn.nmhdr.idFrom   = (uptr_t)bufferID;

    for (auto &pi : _plugins) {
        if (!pi->pBeNotified) continue;
        @try {
            pi->pBeNotified(&scn);
        } @catch (NSException *e) {
            NSLog(@"[Plugins] \"%s\" crashed in beNotified (code=%u): %@",
                  pi->displayName.c_str(), code, e);
        }
    }
}

- (void)forwardScintillaNotification:(SCNotification *)scn {
    if (_shutdownFired || _plugins.empty()) return;

    // Reentrancy guard: if a plugin modifies the document inside a notification
    // handler (e.g. SCI_SETLINEINDENTATION), Scintilla fires another SCN_MODIFIED.
    // Without this guard we'd recurse infinitely.
    if (_forwardingNotification) return;
    _forwardingNotification = YES;

    // Filter SCN_MODIFIED to only forward relevant modification types
    // (matches Windows NPP behavior)
    if (scn->nmhdr.code == SCN_MODIFIED) {
        static const int kForwardedModFlags =
            SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT |
            SC_PERFORMED_UNDO | SC_PERFORMED_REDO |
            SC_MOD_CHANGEFOLD | SC_MOD_CHANGEINDICATOR;
        if (!(scn->modificationType & kForwardedModFlags)) {
            _forwardingNotification = NO;
            return;
        }
    }

    // Make a copy so plugins can't corrupt the original.
    // hwndFrom is set to kHandleScintillaMain — plugins that need to know
    // which view sent the notification call NPPM_GETCURRENTSCINTILLA instead.
    SCNotification copy = *scn;
    copy.nmhdr.hwndFrom = (void *)(uintptr_t)kHandleScintillaMain;

    unsigned int code = copy.nmhdr.code;

    for (auto &pi : _plugins) {
        if (!pi->pBeNotified) continue;

        // Per-plugin subscription filter for UI-related notifications.
        // Default-on — only plugins that explicitly opted out via
        // NPPM_SETPLUGINSUBSCRIPTIONS get filtered.
        if (code == SCN_UPDATEUI && !pi->wantsUpdateUI) continue;
        if (code == SCN_PAINTED  && !pi->wantsPainted)  continue;

        @try {
            pi->pBeNotified(&copy);
        } @catch (NSException *e) {
            NSLog(@"[Plugins] \"%s\" crashed in beNotified (SCN code=%u): %@",
                  pi->displayName.c_str(), copy.nmhdr.code, e);
        }
    }

    _forwardingNotification = NO;
}

// ── Menu ────────────────────────────────────────────────────────────────

- (BOOL)hasPlugins {
    return _plugins.size() > 0;
}

- (NSInteger)pluginCount {
    return (NSInteger)_plugins.size();
}

- (NSArray<NSMenuItem *> *)pluginMenuItems {
    NSMutableArray *items = [NSMutableArray array];

    for (auto &pi : _plugins) {
        NSString *pluginName = [NSString stringWithUTF8String:pi->displayName.c_str()];
        NSMenu *submenu = [[NSMenu alloc] initWithTitle:pluginName];

        for (int i = 0; i < pi->nbFuncItems; i++) {
            struct FuncItem *fi = &pi->funcItems[i];

            // Separator: _pFunc == NULL and empty name
            if (!fi->_pFunc) {
                [submenu addItem:[NSMenuItem separatorItem]];
                continue;
            }
            // No cmdID assigned (static range exhausted at load time).
            if (fi->_cmdID == 0) continue;

            NSString *title = [NSString stringWithUTF8String:fi->_itemName];
            NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:title
                                                        action:@selector(pluginMenuAction:)
                                                 keyEquivalent:@""];
            mi.tag = fi->_cmdID;
            mi.target = self;

            if (fi->_init2Check)
                mi.state = NSControlStateValueOn;

            // TODO: wire up keyboard shortcut from _pShKey

            [submenu addItem:mi];
        }

        NSMenuItem *pluginItem = [[NSMenuItem alloc] initWithTitle:pluginName
                                                            action:nil
                                                     keyEquivalent:@""];
        pluginItem.submenu = submenu;
        [items addObject:pluginItem];
    }

    return items;
}

- (void)pluginMenuAction:(NSMenuItem *)sender {
    [self runPluginCommandWithID:(int)sender.tag];
}

- (NSArray<NSDictionary *> *)allPluginActions {
    NSMutableArray *actions = [NSMutableArray array];
    // Collect cmdIDs that have registered toolbar icons
    NSMutableSet *toolbarCmdIDs = [NSMutableSet set];
    for (NSDictionary *pti in [_mwc valueForKey:@"_pluginToolbarItems"])
        if (pti[@"cmdID"]) [toolbarCmdIDs addObject:pti[@"cmdID"]];

    for (auto &pi : _plugins) {
        NSString *pluginName = [NSString stringWithUTF8String:pi->displayName.c_str()];
        for (int i = 0; i < pi->nbFuncItems; i++) {
            struct FuncItem *fi = &pi->funcItems[i];
            if (!fi->_pFunc) continue; // skip separators
            if (fi->_cmdID == 0) continue; // no cmdID assigned
            NSString *actionName = [NSString stringWithUTF8String:fi->_itemName];
            BOOL hasIcon = [toolbarCmdIDs containsObject:@(fi->_cmdID)];
            [actions addObject:@{
                @"pluginName": pluginName,
                @"actionName": actionName,
                @"cmdID": @(fi->_cmdID),
                @"hasToolbarIcon": @(hasIcon)
            }];
        }
    }
    return actions;
}

- (void)runPluginCommandWithID:(int)cmdID {
    if (cmdID == 0) return;  // separators and items without an assigned cmdID
    for (auto &pi : _plugins) {
        for (int i = 0; i < pi->nbFuncItems; i++) {
            if (pi->funcItems[i]._cmdID == cmdID && pi->funcItems[i]._pFunc) {
                @try {
                    pi->funcItems[i]._pFunc();
                } @catch (NSException *e) {
                    NSLog(@"[Plugins] \"%s\" crashed running command %d: %@",
                          pi->displayName.c_str(), cmdID, e);
                    NSAlert *alert = [[NSAlert alloc] init];
                    alert.messageText = @"Plugin Error";
                    alert.informativeText = [NSString stringWithFormat:
                        @"Plugin \"%s\" encountered an error running command \"%s\".\n\n%@",
                        pi->displayName.c_str(), pi->funcItems[i]._itemName, e.reason];
                    alert.alertStyle = NSAlertStyleWarning;
                    [alert runModal];
                }
                return;
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Plugin panel docking — implementation
//
// The four NPPM_DMM_* messages go through these helpers. All four marshal
// to the main thread before touching AppKit — plugins that call from a
// background queue (rare but possible) don't crash. All registry lookups
// take O(n) over a dictionary so they're effectively O(1) for practical
// plugin counts.
//
// Design notes:
//  - Registration is idempotent by NSView identity. Calling REGISTER with
//    the same view twice returns the same handle.
//  - SHOW/HIDE are idempotent — no-op on already-shown/hidden panels.
//  - UNREGISTER hides first (safe on a hidden panel), then drops the
//    strong retain so the view can deallocate if the plugin released its
//    own reference.
//  - Per-window: we dock to `_mwc` only (the primary window). A secondary
//    window created via Window > New Window won't show plugin panels in
//    v1.0.3. This is documented and deferred.
// ═══════════════════════════════════════════════════════════════════════════

// Run `block` synchronously on the main queue if we're not already there.
// Returns the block's result. Avoids the deadlock that `dispatch_sync` to
// main from main would otherwise cause.
static intptr_t _npp_run_on_main(intptr_t (^block)(void)) {
    if ([NSThread isMainThread]) return block();
    __block intptr_t result = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = block(); });
    return result;
}

- (uint64_t)registerPluginPanel:(NSView *)view title:(const char *)titleC {
    if (!view) return 0;
    NSString *title = titleC ? [NSString stringWithUTF8String:titleC] : @"";
    if (!title) title = @"";   // defensive: invalid UTF-8 → empty

    return (uint64_t)_npp_run_on_main(^intptr_t{
        // Idempotency: same view → same handle.
        for (NSNumber *key in self->_panelRegistry) {
            _NppPluginPanelRecord *r = self->_panelRegistry[key];
            if (r.view == view) return (intptr_t)r.handle;
        }

        uint64_t handle = self->_nextPanelHandle++;
        _NppPluginPanelRecord *rec =
            [[_NppPluginPanelRecord alloc] initWithHandle:handle
                                                     view:view
                                                    title:title];
        self->_panelRegistry[@(handle)] = rec;
        return (intptr_t)handle;
    });
}

- (intptr_t)showPluginPanelWithHandle:(uint64_t)handle {
    if (handle == 0) return 0;
    return _npp_run_on_main(^intptr_t{
        _NppPluginPanelRecord *rec = self->_panelRegistry[@(handle)];
        if (!rec) return 0;

        MainWindowController *mwc = self->_mwc;
        if (!mwc) return 0;          // host not ready yet

        // SidePanelHost.showPanel:withTitle: is idempotent by design — if
        // the view is already in the stack, it no-ops. So we don't rely
        // on our own cached `visible` flag (which can drift if the main
        // window is torn down while we're still tracking the record).
        [mwc showPluginPanel:rec.view withTitle:rec.title];
        rec.visible = YES;
        return 1;
    });
}

- (intptr_t)hidePluginPanelWithHandle:(uint64_t)handle {
    if (handle == 0) return 0;
    return _npp_run_on_main(^intptr_t{
        _NppPluginPanelRecord *rec = self->_panelRegistry[@(handle)];
        if (!rec) return 0;

        // hidePanel: on SidePanelHost no-ops on a non-member view, so
        // calling it when we're already hidden (or never shown) is safe.
        MainWindowController *mwc = self->_mwc;
        if (mwc) [mwc hidePluginPanel:rec.view];
        rec.visible = NO;
        return 1;
    });
}

- (intptr_t)unregisterPluginPanelWithHandle:(uint64_t)handle {
    if (handle == 0) return 0;
    return _npp_run_on_main(^intptr_t{
        _NppPluginPanelRecord *rec = self->_panelRegistry[@(handle)];
        if (!rec) return 0;

        if (rec.visible) {
            MainWindowController *mwc = self->_mwc;
            if (mwc) [mwc hidePluginPanel:rec.view];
            rec.visible = NO;
        }
        // Dropping the record releases the host's strong retain on rec.view.
        // If the plugin still holds its own reference the view lives on;
        // otherwise ARC deallocates it now (safe — we're on the main thread
        // and the view is out of any view hierarchy).
        [self->_panelRegistry removeObjectForKey:@(handle)];
        return 1;
    });
}

// ── NPPM_* message dispatch ─────────────────────────────────────────────

- (intptr_t)handleNppMessage:(uint32_t)msg wParam:(uintptr_t)wParam lParam:(intptr_t)lParam {
    switch (msg) {

        // ── Editor / view queries ──────────────────────────────────────
        case NPPM_GETCURRENTSCINTILLA: {
            // Write 0 (main) or 1 (sub) to *lParam
            int viewId = MAIN_VIEW;
            if ([[NSUserDefaults standardUserDefaults] boolForKey:kPrefPluginSplitViewRouting]) {
                MainWindowController *mwc = _mwc;
                if (mwc) {
                    EditorView *focused = [mwc currentEditor];
                    EditorView *primary = [mwc editorForPluginView:MAIN_VIEW];
                    if (focused && primary && focused != primary)
                        viewId = SUB_VIEW;
                }
            }
            if (lParam) {
                int *result = (int *)lParam;
                *result = viewId;
            }
            return viewId;
        }

        case NPPM_GETCURRENTVIEW: {
            if ([[NSUserDefaults standardUserDefaults] boolForKey:kPrefPluginSplitViewRouting]) {
                MainWindowController *mwc = _mwc;
                if (mwc) {
                    EditorView *focused = [mwc currentEditor];
                    EditorView *primary = [mwc editorForPluginView:MAIN_VIEW];
                    if (focused && primary && focused != primary)
                        return SUB_VIEW;
                }
            }
            return MAIN_VIEW;
        }

        case NPPM_GETCURRENTBUFFERID: {
            // Use the EditorView pointer as a buffer ID
            MainWindowController *mwc = _mwc;
            if (!mwc) return 0;
            EditorView *ed = [mwc currentEditor];
            return (intptr_t)(__bridge void *)ed;
        }

        case NPPM_GETFULLPATHFROMBUFFERID: {
            // wParam = bufferID (EditorView*), lParam = char* buffer to fill (≥ 1024).
            //
            // Crash-safe on bogus wParam: must NOT trigger ARC retain. Storing
            // the __bridge cast result in a __strong local would call
            // objc_retain on whatever wParam happens to be — a plugin that
            // cached a now-freed bufferID would crash the host. Walk the
            // host's own editor list and only adopt the pointer once it's
            // verified to be one of ours. Mirrors NPPM_GETPOSFROMBUFFERID below.
            MainWindowController *mwc = _mwc;
            void *target = (void *)wParam;
            char *buf = (char *)lParam;
            if (!mwc || !target) {
                if (buf) buf[0] = '\0';
                return 0;
            }
            EditorView *ed = nil;
            for (EditorView *cand in nppAllEditors(mwc, 0)) {
                if ((__bridge void *)cand == target) { ed = cand; break; }
            }
            if (ed && ed.filePath && buf) {
                strlcpy(buf, ed.filePath.UTF8String, 1024);
                return (intptr_t)strlen(buf);
            }
            if (buf) buf[0] = '\0';
            return 0;
        }

        // ── Language detection ─────────────────────────────────────────
        // Windows NPP exposes an integer LangType enum (see
        // notepad-plus-plus/PowerEditor/src/MISC/PluginsManager/Notepad_plus_msgs.h
        // line 27). Plugins use NPPM_GETCURRENTLANGTYPE to detect which
        // language the current buffer is classified as. The macOS host
        // stores the language as an NSString on EditorView.currentLanguage;
        // these two handlers translate between the NSString name and the
        // canonical Windows integer value.
        //
        // Unknown / untyped buffers return L_TEXT = 0, matching Windows.
        // UDL (L_USER = 15) is not implemented on macOS — the host has no
        // user-defined language engine. External lexers (L_EXTERNAL = 95)
        // are likewise not used.
        case NPPM_GETCURRENTLANGTYPE: {
            int *out = (int *)lParam;
            if (!out) return 0;

            MainWindowController *mwc = _mwc;
            EditorView *ed = mwc ? [mwc currentEditor] : nil;
            NSString *langName = ed.currentLanguage ?: @"";

            static NSDictionary<NSString *, NSNumber *> *nameToLangType;
            static dispatch_once_t onceLangType;
            dispatch_once(&onceLangType, ^{
                nameToLangType = @{
                    // Canonical Windows NPP LangType values.
                    // Reference: Notepad_plus_msgs.h line 27.
                    @"c"            : @2,    // L_C
                    @"cpp"          : @3,    // L_CPP
                    @"cs"           : @4,    // L_CS
                    @"objc"         : @5,    // L_OBJC
                    @"java"         : @6,    // L_JAVA
                    @"rc"           : @7,    // L_RC
                    @"html"         : @8,    // L_HTML
                    @"xml"          : @9,    // L_XML
                    @"makefile"     : @10,   // L_MAKEFILE
                    @"pascal"       : @11,   // L_PASCAL
                    @"batch"        : @12,   // L_BATCH
                    @"ini"          : @13,   // L_INI
                    // 14 = L_ASCII/L_NFO, 15 = L_USER (UDL — not supported)
                    @"asp"          : @16,   // L_ASP
                    @"sql"          : @17,   // L_SQL
                    @"vb"           : @18,   // L_VB
                    // 19 = L_JS_EMBEDDED (deprecated)
                    @"css"          : @20,   // L_CSS
                    @"perl"         : @21,   // L_PERL
                    @"python"       : @22,   // L_PYTHON
                    @"lua"          : @23,   // L_LUA
                    @"tex"          : @24,   // L_TEX
                    @"fortran"      : @25,   // L_FORTRAN
                    @"bash"         : @26,   // L_BASH
                    @"actionscript" : @27,   // L_FLASH
                    @"nsis"         : @28,   // L_NSIS
                    @"tcl"          : @29,   // L_TCL
                    @"lisp"         : @30,   // L_LISP
                    @"scheme"       : @31,   // L_SCHEME
                    @"asm"          : @32,   // L_ASM
                    @"diff"         : @33,   // L_DIFF
                    @"props"        : @34,   // L_PROPS
                    @"postscript"   : @35,   // L_PS
                    @"ruby"         : @36,   // L_RUBY
                    @"smalltalk"    : @37,   // L_SMALLTALK
                    @"vhdl"         : @38,   // L_VHDL
                    @"kix"          : @39,   // L_KIX
                    @"autoit"       : @40,   // L_AU3
                    @"caml"         : @41,   // L_CAML
                    @"ada"          : @42,   // L_ADA
                    @"verilog"      : @43,   // L_VERILOG
                    @"matlab"       : @44,   // L_MATLAB
                    @"haskell"      : @45,   // L_HASKELL
                    @"inno"         : @46,   // L_INNO
                    // 47 = L_SEARCHRESULT (host-internal)
                    @"cmake"        : @48,   // L_CMAKE
                    @"yaml"         : @49,   // L_YAML
                    @"cobol"        : @50,   // L_COBOL
                    // 51 = L_GUI4CLI (not in host)
                    @"d"            : @52,   // L_D
                    @"powershell"   : @53,   // L_POWERSHELL
                    @"r"            : @54,   // L_R
                    // 55 = L_JSP (not in host)
                    @"coffeescript" : @56,   // L_COFFEESCRIPT
                    @"json"         : @57,   // L_JSON
                    @"javascript"   : @58,   // L_JAVASCRIPT
                    @"javascript.js": @58,   // alternate host alias
                    @"fortran77"    : @59,   // L_FORTRAN_77
                    @"baanc"        : @60,   // L_BAANC
                    // 61-63 = L_SREC/L_IHEX/L_TEHEX (not in host)
                    @"swift"        : @64,   // L_SWIFT
                    // 65 = L_ASN1 (not in host)
                    @"avs"          : @66,   // L_AVS
                    @"blitzbasic"   : @67,   // L_BLITZBASIC
                    @"purebasic"    : @68,   // L_PUREBASIC
                    @"freebasic"    : @69,   // L_FREEBASIC
                    @"csound"       : @70,   // L_CSOUND
                    @"erlang"       : @71,   // L_ERLANG
                    @"escript"      : @72,   // L_ESCRIPT
                    @"forth"        : @73,   // L_FORTH
                    @"latex"        : @74,   // L_LATEX
                    // 75 = L_MMIXAL (not in host)
                    @"nim"          : @76,   // L_NIM
                    @"nncrontab"    : @77,   // L_NNCRONTAB
                    @"oscript"      : @78,   // L_OSCRIPT
                    // 79 = L_REBOL (not in host)
                    @"registry"     : @80,   // L_REGISTRY
                    @"rust"         : @81,   // L_RUST
                    @"spice"        : @82,   // L_SPICE
                    // 83 = L_TXT2TAGS (not in host)
                    @"visualprolog" : @84,   // L_VISUALPROLOG
                    @"typescript"   : @85,   // L_TYPESCRIPT
                    // 86 = L_JSON5 (not in host)
                    @"mssql"        : @87,   // L_MSSQL
                    @"gdscript"     : @88,   // L_GDSCRIPT
                    @"hollywood"    : @89,   // L_HOLLYWOOD
                    @"go"           : @90,   // L_GOLANG
                    @"raku"         : @91,   // L_RAKU
                    @"toml"         : @92,   // L_TOML
                    @"sas"          : @93,   // L_SAS
                    // 94 = L_ERRORLIST (host-internal)
                    // 95 = L_EXTERNAL (reserved)
                };
            });

            NSNumber *val = nameToLangType[langName.lowercaseString];
            *out = val ? val.intValue : 0;    // L_TEXT for unknown / plain text
            return 0;
        }

        case NPPM_GETLANGUAGENAME: {
            // wParam = int langType, lParam = char* out buffer (assumed ≥1024 bytes)
            // Returns: number of bytes written (excluding the terminating NUL),
            //          or 0 if the langType is unknown / out buffer is null.
            int langType = (int)wParam;
            char *out = (char *)lParam;
            if (!out) return 0;

            static NSDictionary<NSNumber *, NSString *> *langTypeToName;
            static dispatch_once_t onceLangName;
            dispatch_once(&onceLangName, ^{
                langTypeToName = @{
                    // Display names match Windows NPP's default langs.xml.
                    // Used by plugins that want human-readable labels.
                    @0  : @"Normal text",
                    @1  : @"PHP",
                    @2  : @"C",
                    @3  : @"C++",
                    @4  : @"C#",
                    @5  : @"Objective-C",
                    @6  : @"Java",
                    @7  : @"RC",
                    @8  : @"HTML",
                    @9  : @"XML",
                    @10 : @"Makefile",
                    @11 : @"Pascal",
                    @12 : @"Batch",
                    @13 : @"ini",
                    @16 : @"ASP",
                    @17 : @"SQL",
                    @18 : @"Visual Basic",
                    @20 : @"CSS",
                    @21 : @"Perl",
                    @22 : @"Python",
                    @23 : @"Lua",
                    @24 : @"TeX",
                    @25 : @"Fortran",
                    @26 : @"Shell",
                    @27 : @"Flash ActionScript",
                    @28 : @"NSIS",
                    @29 : @"TCL",
                    @30 : @"Lisp",
                    @31 : @"Scheme",
                    @32 : @"Assembly",
                    @33 : @"Diff",
                    @34 : @"Properties",
                    @35 : @"PostScript",
                    @36 : @"Ruby",
                    @37 : @"Smalltalk",
                    @38 : @"VHDL",
                    @39 : @"KiXtart",
                    @40 : @"AutoIt",
                    @41 : @"CAML",
                    @42 : @"Ada",
                    @43 : @"Verilog",
                    @44 : @"MATLAB",
                    @45 : @"Haskell",
                    @46 : @"Inno Setup",
                    @48 : @"CMake",
                    @49 : @"YAML",
                    @50 : @"COBOL",
                    @52 : @"D",
                    @53 : @"PowerShell",
                    @54 : @"R",
                    @56 : @"CoffeeScript",
                    @57 : @"JSON",
                    @58 : @"JavaScript",
                    @59 : @"Fortran 77",
                    @60 : @"BaanC",
                    @64 : @"Swift",
                    @66 : @"AviSynth",
                    @67 : @"BlitzBasic",
                    @68 : @"PureBasic",
                    @69 : @"FreeBasic",
                    @70 : @"Csound",
                    @71 : @"Erlang",
                    @72 : @"ESCRIPT",
                    @73 : @"Forth",
                    @74 : @"LaTeX",
                    @76 : @"Nim",
                    @77 : @"nnCron",
                    @78 : @"OScript",
                    @80 : @"Registry",
                    @81 : @"Rust",
                    @82 : @"Spice",
                    @84 : @"Visual Prolog",
                    @85 : @"TypeScript",
                    @87 : @"MS-SQL",
                    @88 : @"GDScript",
                    @89 : @"Hollywood",
                    @90 : @"Go",
                    @91 : @"Raku",
                    @92 : @"TOML",
                    @93 : @"SAS",
                };
            });

            NSString *name = langTypeToName[@(langType)];
            if (!name) {
                out[0] = '\0';
                return 0;
            }
            strlcpy(out, name.UTF8String, 1024);
            return (intptr_t)strlen(out);
        }

        case NPPM_GETNBOPENFILES: {
            // wParam unused, lParam: 0=ALL, 1=PRIMARY_VIEW, 2=SECOND_VIEW (Windows NPP convention).
            MainWindowController *mwc = _mwc;
            if (!mwc) return 0;
            return (intptr_t)nppAllEditors(mwc, (int)lParam).count;
        }

        case NPPM_GETOPENFILENAMES: {
            // Windows contract: INT NPPM_GETOPENFILENAMES(TCHAR **fileNames, INT nbFile)
            // wParam = char **files — caller-allocated array of nbFile slots,
            //                          each slot ≥ MAX_PATH (1024) bytes.
            // lParam = int nbFile — number of slots available.
            // Fills slots with UTF-8 paths of open buffers across ALL views,
            // skipping untitled tabs (no filePath) — matches the convention used
            // by the host's own saveSessionToPath:. Returns the actual count
            // written. Plugin should call NPPM_GETNBOPENFILES first to size.
            char **files = (char **)wParam;
            int maxN = (int)lParam;
            MainWindowController *mwc = _mwc;
            if (!mwc || !files || maxN <= 0) return 0;
            NSArray<EditorView *> *all = nppAllEditors(mwc, 0);
            int n = 0;
            for (EditorView *ed in all) {
                if (n >= maxN) break;
                if (!ed.filePath) continue;             // skip untitled
                if (!files[n]) continue;                // defensive: caller didn't allocate this slot
                strlcpy(files[n], ed.filePath.UTF8String, 1024);
                n++;
            }
            return (intptr_t)n;
        }

        case NPPM_SAVECURRENTSESSION: {
            // wParam unused, lParam = const char *path (UTF-8). Writes the host's
            // own session format (plist with tabs / firstVisibleLine / cursorLine
            // / selectedIndex) by reusing -[MainWindowController saveSessionToPath:],
            // the same method backing File ▸ Save Session As… and the --sessionFile
            // CLI restore path. Returns 1 on success (synchronous), 0 on invalid input.
            const char *path = (const char *)lParam;
            MainWindowController *mwc = _mwc;
            if (!path || !mwc) return 0;
            NSString *p = [NSString stringWithUTF8String:path];
            if (!p) return 0;
            [mwc saveSessionToPath:p];
            return 1;
        }

        case NPPM_LOADSESSION: {
            // wParam unused, lParam = const char *path (UTF-8). Replaces current
            // tabs with the saved set by reusing -[MainWindowController loadSessionFromPath:],
            // the same method backing File ▸ Load Session… and --sessionFile. The file
            // must already exist; returns 0 if missing (so a plugin can distinguish
            // "no session yet" from "session loaded"). Returns 1 on success.
            const char *path = (const char *)lParam;
            MainWindowController *mwc = _mwc;
            if (!path || !mwc) return 0;
            NSString *p = [NSString stringWithUTF8String:path];
            if (!p || ![[NSFileManager defaultManager] fileExistsAtPath:p]) return 0;
            [mwc loadSessionFromPath:p];
            return 1;
        }

        case NPPM_GETPOSFROMBUFFERID: {
            // Windows contract: INT NPPM_GETPOSFROMBUFFERID(UINT_PTR bufferID, INT priorityView)
            // Returns the buffer's (view | tab-index) packed into one int:
            //   top 2 bits  = view (MAIN_VIEW=0, SUB_VIEW=1)
            //   low 30 bits = 0-based tab index within that view
            // -1 if the bufferID isn't found in any view. `priorityView` (0/1)
            // controls which view is searched first.
            //
            // Crash-safe on bogus wParam: must NOT trigger ARC retain. Storing
            // the bridge-cast result in a __strong local would call objc_retain
            // on whatever wParam happens to be (crash on garbage). Use the raw
            // void* throughout and compare by pointer identity — no ObjC method
            // is ever sent to the candidate `target` pointer.
            MainWindowController *mwc = _mwc;
            void *target = (void *)wParam;
            if (!mwc || !target) return -1;
            int priority = ((int)lParam == 1) ? 1 : 0;
            int viewOrder[2] = { priority, 1 - priority };
            for (int i = 0; i < 2; ++i) {
                int v = viewOrder[i];
                // primary == view 0; combined V+H secondary == view 1.
                NSArray<EditorView *> *eds = nppAllEditors(mwc, v == 0 ? 1 : 2);
                NSUInteger idx = 0;
                for (EditorView *ed in eds) {
                    if ((__bridge void *)ed == target) {
                        return ((intptr_t)(v & 0x3) << 30) | ((intptr_t)idx & 0x3FFFFFFF);
                    }
                    idx++;
                }
            }
            return -1;
        }

        case NPPM_GETNPPVERSION: {
            // Return version as (major << 16) | minor
            // Our macOS port version: 0.1.0 → we'll report as 8.7 for compat
            return (8 << 16) | 7;
        }

        case NPPM_GETPLUGINHOMEPATH: {
            // Write the plugins directory path to (char*)lParam
            char *buf = (char *)lParam;
            if (buf) {
                NSString *path = pluginBaseDir();
                strlcpy(buf, path.UTF8String, 1024);
                return (intptr_t)strlen(buf);
            }
            return 0;
        }

        case NPPM_GETPLUGINSCONFIGDIR: {
            char *buf = (char *)lParam;
            if (buf) {
                NSString *path = [pluginBaseDir() stringByAppendingPathComponent:@"Config"];
                // Ensure it exists
                [[NSFileManager defaultManager] createDirectoryAtPath:path
                                         withIntermediateDirectories:YES attributes:nil error:nil];
                strlcpy(buf, path.UTF8String, 1024);
                return (intptr_t)strlen(buf);
            }
            return 0;
        }

        case NPPM_GETNPPSETTINGSDIRPATH: {
            char *buf = (char *)lParam;
            if (buf) {
                NSString *path = NppConfigDir();
                strlcpy(buf, path.UTF8String, 1024);
                return (intptr_t)strlen(buf);
            }
            return 0;
        }

        // ── File operations ──────────────────────────────────────────
        case NPPM_DOOPEN: {
            // lParam = const char* filePath (UTF-8)
            const char *path = (const char *)lParam;
            if (path) {
                MainWindowController *mwc = _mwc;
                if (mwc) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [mwc openFileAtPath:[NSString stringWithUTF8String:path]];
                    });
                    return 1;
                }
            }
            return 0;
        }

        case NPPM_SAVECURRENTFILE: {
            MainWindowController *mwc = _mwc;
            if (mwc) {
                EditorView *ed = [mwc currentEditor];
                if (ed) {
                    NSError *err = nil;
                    return [ed saveError:&err] ? 1 : 0;
                }
            }
            return 0;
        }

        // ── Menu ────────────────────────────────────────────────────
        case NPPM_SETMENUITEMCHECK: {
            // wParam = cmdID, lParam = checked (BOOL)
            // Find the plugin menu item by tag and set its state.
            //
            // Valid plugin cmdIDs start at 22000 (see _nextPluginCmdBase).
            // A cmdID of 0 means the plugin passed a separator's _cmdID
            // (the host only allocates IDs to items with _pFunc != null,
            // so separators keep the default-zero value). Without this
            // guard, findMenuItemWithTag:0 would walk the plugins menu
            // and match the first NSMenuItem with the default-zero tag —
            // typically a static submenu wrapper like "MIME Tools" — and
            // erroneously toggle its checkmark.
            int cmdID = (int)wParam;
            BOOL checked = (BOOL)lParam;
            if (cmdID == 0) {
                NSLog(@"[Plugins] NPPM_SETMENUITEMCHECK called with cmdID=0 "
                      @"— likely a plugin bug (calling on a separator or an "
                      @"uninitialized funcItem slot). Ignoring.");
                return 0;
            }
            NSMenu *pluginsMenu = [self findPluginsMenu];
            if (pluginsMenu) {
                NSMenuItem *item = [self findMenuItemWithTag:cmdID inMenu:pluginsMenu];
                if (item) {
                    item.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
                }
            }
            return 0;
        }

        // ── ID allocation ───────────────────────────────────────────
        // wParam = count, lParam = int* receiving the first ID. Returns
        // FALSE if the range can't satisfy the request. On failure, as on
        // Windows (PluginsManager.cpp), CMDID and MARKER set *lParam to 0
        // and INDICATOR leaves it untouched. Ranges are documented in
        // NppScintillaIDs.h.
        case NPPM_ALLOCATECMDID: {
            int count = (int)wParam;
            int *start = (int *)lParam;
            if (!start) return FALSE;
            if (_cmdIDAlloc.allocate(count, start)) return TRUE;
            *start = 0;
            NSLog(@"[Plugins] NPPM_ALLOCATECMDID(%d) refused: range %d-%d exhausted "
                  @"or invalid request.", count,
                  kPluginDynamicCmdIDFirst, kPluginDynamicCmdIDLimit - 1);
            return FALSE;
        }

        case NPPM_ALLOCATEMARKER: {
            int count = (int)wParam;
            int *start = (int *)lParam;
            if (!start) return FALSE;
            if (_markerAlloc.allocate(count, start)) return TRUE;
            *start = 0;
            NSLog(@"[Plugins] NPPM_ALLOCATEMARKER(%d) refused: range %d-%d exhausted "
                  @"or invalid request.", count,
                  kPluginMarkerFirst, kPluginMarkerLimit - 1);
            return FALSE;
        }

        case NPPM_ALLOCATEINDICATOR: {
            int count = (int)wParam;
            int *start = (int *)lParam;
            if (_indicatorAlloc.allocate(count, start)) return TRUE;
            NSLog(@"[Plugins] NPPM_ALLOCATEINDICATOR(%d) refused: range %d-%d exhausted "
                  @"or invalid request.", count,
                  kPluginIndicatorFirst, kPluginIndicatorLimit - 1);
            return FALSE;
        }

        case NPPM_GETBOOKMARKID: {
            // The marker the host actually uses for bookmarks, so plugins
            // can read/set them with SCI_MARKER*.
            return kBookmarkMarker;
        }

        // ── Dark mode ──────────────────────────────────────────────
        case NPPM_ISDARKMODEENABLED: {
            if (@available(macOS 10.14, *)) {
                NSAppearanceName name = [NSApp.effectiveAppearance
                    bestMatchFromAppearancesWithNames:@[
                        NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
                return [name isEqualToString:NSAppearanceNameDarkAqua] ? 1 : 0;
            }
            return 0;
        }

        case NPPM_DARKMODESUBCLASSANDTHEME: {
            // On macOS, dark mode is automatic via NSAppearance. No-op.
            return 1;
        }

        // ── Menu command dispatch ────────────────────────────────────
        case NPPM_MENUCOMMAND: {
            // lParam = IDM_* command ID
            int idm = (int)lParam;
            MainWindowController *mwc = _mwc;
            if (!mwc) return 0;

            SEL action = nil;
            switch (idm) {
                case 41001: action = @selector(newDocument:);    break; // IDM_FILE_NEW
                case 41002: action = @selector(openDocument:);   break; // IDM_FILE_OPEN
                case 41006: action = @selector(saveDocument:);   break; // IDM_FILE_SAVE
                case 41003: action = @selector(closeCurrentTab:); break; // IDM_FILE_CLOSE
                case 41004: action = @selector(closeAllTabs:);   break; // IDM_FILE_CLOSEALL — used by SessionMgr to swap sessions
                default:
                    NSLog(@"[Plugins] Unhandled NPPM_MENUCOMMAND IDM=%d", idm);
                    return 0;
            }
            if (action && [mwc respondsToSelector:action]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    // Use performSelector for action methods defined in .mm only
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [mwc performSelector:action withObject:nil];
                    #pragma clang diagnostic pop
                });
                return 1;
            }
            return 0;
        }

        // ── Toolbar icon registration ───────────────────────────────
        case NPPM_ADDTOOLBARICON_FORDARKMODE: {
            // wParam = cmdID assigned to a FuncItem
            // lParam = (const char *) icon filename hint (optional, macOS extension)
            //          if NULL, the host falls back to toolbar.png. In dark mode
            //          the host additionally probes <hint>_dark.<ext> /
            //          toolbar_dark.png — see Path A in MWC's
            //          _resolvePluginToolbarIconForDir:hint:.
            //
            // The host (MainWindowController) is the single source of truth
            // for icon lookup and re-loads icons on theme change. This handler
            // just hands it the strings.
            int cmdID = (int)wParam;
            if (cmdID == 0) return 0;  // separator or a FuncItem left without an ID

            std::string pluginDirName;
            std::string funcItemName;
            for (auto &pi : _plugins) {
                for (int i = 0; i < pi->nbFuncItems; i++) {
                    if (pi->funcItems[i]._cmdID == cmdID) {
                        pluginDirName = pi->moduleName;
                        funcItemName  = pi->funcItems[i]._itemName;
                        break;
                    }
                }
                if (!pluginDirName.empty()) break;
            }

            if (pluginDirName.empty()) {
                NSLog(@"[Plugins] ADDTOOLBARICON: no plugin owns cmdID %d", cmdID);
                return 0;
            }

            NSString *pluginDir = [NSString stringWithFormat:@"%@/%s",
                                   pluginBaseDir(), pluginDirName.c_str()];
            NSString *iconHint  = lParam
                ? [NSString stringWithUTF8String:(const char *)lParam]
                : nil;
            NSString *tooltip   = funcItemName.empty()
                ? @""
                : [NSString stringWithUTF8String:funcItemName.c_str()];

            MainWindowController *mwc = _mwc;
            if (!mwc) return 0;

            dispatch_async(dispatch_get_main_queue(), ^{
                [mwc addPluginToolbarIconForPluginDir:pluginDir
                                             iconHint:iconHint
                                              tooltip:tooltip
                                                cmdID:cmdID];
            });
            return 1;
        }

        // ── Stubs for messages plugins query but don't critically need ─
        case NPPM_GETWINDOWSVERSION:
            return 0;  // Not Windows

        case NPPM_GETAPPDATAPLUGINSALLOWED:
            return 1;  // Always allow

        case NPPM_ISDARKMODEENABLED + 1:  // NPPM_GETCURRENTCMDLINE
        case NPPM_ISTABBARHIDDEN:
        case NPPM_ISTOOLBARHIDDEN:
        case NPPM_ISMENUHIDDEN:
        case NPPM_ISSTATUSBARHIDDEN:
            return 0;

        case NPPM_GETMENUHANDLE:
            return 0;  // No HMENU on macOS

        // ── Inter-plugin communication ──────────────────────────────
        case NPPM_MSGTOPLUGIN: {
            const char *destModule = (const char *)wParam;
            struct CommunicationInfo *ci = (struct CommunicationInfo *)lParam;
            if (!destModule || !ci) return 0;

            for (auto &pi : _plugins) {
                if (pi->moduleName == destModule && pi->pMessageProc) {
                    @try {
                        return pi->pMessageProc(NPPM_MSGTOPLUGIN, 0, (intptr_t)ci);
                    } @catch (NSException *e) {
                        NSLog(@"[Plugins] \"%s\" crashed in messageProc: %@",
                              pi->displayName.c_str(), e);
                        return 0;
                    }
                }
            }
            return 0;
        }

        // ── RUNCOMMAND_USER submessages ─────────────────────────────
        case NPPM_GETFULLCURRENTPATH: {
            char *buf = (char *)lParam;
            if (buf) {
                MainWindowController *mwc = _mwc;
                EditorView *ed = mwc ? [mwc currentEditor] : nil;
                if (ed && ed.filePath) {
                    strlcpy(buf, ed.filePath.UTF8String, 1024);
                } else {
                    buf[0] = '\0';
                }
            }
            return 0;
        }

        case NPPM_GETCURRENTDIRECTORY: {
            char *buf = (char *)lParam;
            if (buf) {
                MainWindowController *mwc = _mwc;
                EditorView *ed = mwc ? [mwc currentEditor] : nil;
                if (ed && ed.filePath) {
                    NSString *dir = [ed.filePath stringByDeletingLastPathComponent];
                    strlcpy(buf, dir.UTF8String, 1024);
                } else {
                    buf[0] = '\0';
                }
            }
            return 0;
        }

        case NPPM_GETFILENAME: {
            char *buf = (char *)lParam;
            if (buf) {
                MainWindowController *mwc = _mwc;
                EditorView *ed = mwc ? [mwc currentEditor] : nil;
                if (ed && ed.filePath) {
                    NSString *name = [ed.filePath lastPathComponent];
                    strlcpy(buf, name.UTF8String, 1024);
                } else {
                    buf[0] = '\0';
                }
            }
            return 0;
        }

        case NPPM_GETNAMEPART: {
            char *buf = (char *)lParam;
            if (buf) {
                MainWindowController *mwc = _mwc;
                EditorView *ed = mwc ? [mwc currentEditor] : nil;
                if (ed && ed.filePath) {
                    NSString *name = [[ed.filePath lastPathComponent] stringByDeletingPathExtension];
                    strlcpy(buf, name.UTF8String, 1024);
                } else {
                    buf[0] = '\0';
                }
            }
            return 0;
        }

        case NPPM_GETEXTPART: {
            char *buf = (char *)lParam;
            if (buf) {
                MainWindowController *mwc = _mwc;
                EditorView *ed = mwc ? [mwc currentEditor] : nil;
                if (ed && ed.filePath) {
                    NSString *ext = [ed.filePath pathExtension];
                    strlcpy(buf, ext.UTF8String, 1024);
                } else {
                    buf[0] = '\0';
                }
            }
            return 0;
        }

        case NPPM_GETNPPDIRECTORY: {
            char *buf = (char *)lParam;
            if (buf) {
                NSString *path = [[NSBundle mainBundle] bundlePath];
                strlcpy(buf, path.UTF8String, 1024);
            }
            return 0;
        }

        case NPPM_GETCURRENTLINE: {
            MainWindowController *mwc = _mwc;
            EditorView *ed = mwc ? [mwc currentEditor] : nil;
            if (ed && ed.scintillaView) {
                return [ed.scintillaView message:SCI_LINEFROMPOSITION
                                          wParam:[ed.scintillaView message:SCI_GETCURRENTPOS wParam:0 lParam:0]
                                          lParam:0];
            }
            return 0;
        }

        case NPPM_GETCURRENTCOLUMN: {
            MainWindowController *mwc = _mwc;
            EditorView *ed = mwc ? [mwc currentEditor] : nil;
            if (ed && ed.scintillaView) {
                return [ed.scintillaView message:SCI_GETCOLUMN
                                          wParam:[ed.scintillaView message:SCI_GETCURRENTPOS wParam:0 lParam:0]
                                          lParam:0];
            }
            return 0;
        }

        // ── macOS-specific: per-plugin notification subscriptions ─────
        case NPPM_SETPLUGINSUBSCRIPTIONS: {
            // wParam: subscription bitmask (NPPPLUGIN_WANTS_* flags)
            // lParam: const char* plugin module name (required)
            // Returns 1 on success, 0 if the named plugin is not loaded.
            const char *moduleName = (const char *)lParam;
            if (!moduleName) return 0;

            unsigned int mask = (unsigned int)wParam;
            std::string wanted(moduleName);

            for (auto &pi : _plugins) {
                if (pi->moduleName == wanted) {
                    pi->wantsUpdateUI = (mask & NPPPLUGIN_WANTS_UPDATEUI) != 0;
                    pi->wantsPainted  = (mask & NPPPLUGIN_WANTS_PAINTED)  != 0;
                    NSLog(@"[Plugins] \"%s\" subscriptions: updateUI=%d painted=%d",
                          pi->displayName.c_str(),
                          (int)pi->wantsUpdateUI, (int)pi->wantsPainted);
                    return 1;
                }
            }
            NSLog(@"[Plugins] NPPM_SETPLUGINSUBSCRIPTIONS: no plugin with moduleName \"%s\"",
                  moduleName);
            return 0;
        }

        // ── macOS-specific: plugin panel docking ──────────────────────
        case NPPM_DMM_REGISTERPANEL: {
            // Plugin hands in an NSView for host retention. We MUST NOT pass
            // raw wParam to an ObjC method without validation — the ARC retain
            // inserted at the call boundary (registerPluginPanel: takes a
            // __strong NSView*) dereferences the pointer inside objc_retain.
            // A garbage value like 0xDEADBEEF segfaults the host before our
            // method body runs. There's no master list to validate against
            // here (unlike the bufferID handlers), so use malloc_zone_from_ptr
            // as a cheap "is this a live heap allocation" guard — NSView
            // instances are always malloc-allocated; garbage or stale 32-bit
            // sentinels are not. Reject anything that's clearly not.
            void *target = (void *)wParam;
            if (!target || !malloc_zone_from_ptr(target)) return 0;
            return (intptr_t)[self registerPluginPanel:(__bridge NSView *)target
                                                 title:(const char *)lParam];
        }
        case NPPM_DMM_SHOWPANEL:
            return [self showPluginPanelWithHandle:(uint64_t)wParam];
        case NPPM_DMM_HIDEPANEL:
            return [self hidePluginPanelWithHandle:(uint64_t)wParam];
        case NPPM_DMM_UNREGISTERPANEL:
            return [self unregisterPluginPanelWithHandle:(uint64_t)wParam];

        default:
            // Log unimplemented messages (but not too verbosely)
            if (msg >= (uint32_t)NPPMSG && msg <= (uint32_t)(NPPMSG + 200)) {
                static NSMutableSet *logged;
                static dispatch_once_t once;
                dispatch_once(&once, ^{ logged = [NSMutableSet set]; });
                NSNumber *key = @(msg);
                if (![logged containsObject:key]) {
                    [logged addObject:key];
                    NSLog(@"[Plugins] Unimplemented NPPM message: %u (NPPMSG+%u)",
                          msg, msg - (uint32_t)NPPMSG);
                }
            }
            return 0;
    }
}

// ── Scintilla message routing ───────────────────────────────────────────

- (intptr_t)handleScintillaMessage:(uint32_t)msg
                          forHandle:(uintptr_t)handle
                             wParam:(uintptr_t)wParam
                             lParam:(intptr_t)lParam {
    MainWindowController *mwc = _mwc;
    if (!mwc) return 0;

    EditorView *ed = nil;

    if ([[NSUserDefaults standardUserDefaults] boolForKey:kPrefPluginSplitViewRouting]) {
        // Route based on handle: main handle → primary editor, sub handle → secondary editor
        int viewId = (handle == kHandleScintillaSub) ? SUB_VIEW : MAIN_VIEW;
        ed = [mwc editorForPluginView:viewId];
    }

    // Fallback: route to current editor (original behavior)
    if (!ed)
        ed = [mwc currentEditor];

    if (!ed) return 0;

    ScintillaView *sv = ed.scintillaView;
    if (!sv) return 0;

    return [sv message:msg wParam:wParam lParam:lParam];
}

// ── Menu helpers ────────────────────────────────────────────────────────

- (nullable NSMenu *)findPluginsMenu {
    // Tag-based lookup is required because the menu's English title is
    // overwritten with the active language's translation (e.g. "Плагины")
    // before any plugin command registration runs, so a title-based scan
    // would silently fail and the plugin's commands would never appear.
    return [[[NSApp mainMenu] itemWithTag:kMenuTagPlugins] submenu];
}

- (nullable NSMenuItem *)findMenuItemWithTag:(int)tag inMenu:(NSMenu *)menu {
    // Sentinel: tag 0 is NSMenuItem's default "unset" value. Every static
    // submenu wrapper (MIME Tools, Converter, etc.) built without an
    // explicit tag would otherwise match here and cause false positives
    // when a caller asks for tag 0. Plugin cmdIDs are always >= 22000.
    if (tag == 0) return nil;

    for (NSMenuItem *item in menu.itemArray) {
        if (item.tag == tag)
            return item;
        if (item.submenu) {
            NSMenuItem *found = [self findMenuItemWithTag:tag inMenu:item.submenu];
            if (found) return found;
        }
    }
    return nil;
}

@end

// ═══════════════════════════════════════════════════════════════════════════
// C callback — the function pointer stored in NppData._sendMessage
// ═══════════════════════════════════════════════════════════════════════════

static intptr_t nppSendMessageCallback(uintptr_t handle, uint32_t msg,
                                        uintptr_t wParam, intptr_t lParam) {
    NppPluginManager *mgr = [NppPluginManager shared];

    if (handle == kHandleNpp) {
        // Route to NPPM_* message handler
        return [mgr handleNppMessage:msg wParam:wParam lParam:lParam];
    }

    if (handle == kHandleScintillaMain || handle == kHandleScintillaSub) {
        // Route to Scintilla
        return [mgr handleScintillaMessage:msg forHandle:handle wParam:wParam lParam:lParam];
    }

    NSLog(@"[Plugins] sendMessage called with unknown handle: 0x%lx", (unsigned long)handle);
    return 0;
}
