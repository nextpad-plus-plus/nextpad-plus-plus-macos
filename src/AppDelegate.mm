#import "AppDelegate.h"
#import "NppPaths.h"
#import "NppApplication.h"
#import "MainWindowController.h"
#import "MenuBuilder.h"
#import "NppLocalizer.h"
#import "NppPluginManager.h"
#import "NppCommandLineParams.h"
#import "PreferencesWindowController.h"
#import "StyleConfiguratorWindowController.h"
#import "UserDefineLangManager.h"
#import "NppLangsManager.h"
#import "EditorView.h"

// Files opened from a folder beyond this count trigger a confirmation.
static const NSUInteger kFolderOpenConfirmThreshold = 20;

@interface AppDelegate ()
- (NSArray<NSString *> *)_expandFolderArguments:(NSArray<NSString *> *)paths;
@end

@implementation AppDelegate {
    NSMutableArray<NSString *> *_pendingFilePaths;
    BOOL _didFinishLaunching;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _windowControllers = [NSMutableArray array];
        _pendingFilePaths  = [NSMutableArray array];
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Disable the macOS press-and-hold accent picker so key repeat works in the editor.
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"ApplePressAndHoldEnabled"];

    // Issue #126 — wire the "Open with Nextpad++" Finder service. The NSServices
    // entry in Info.plist declares the menu item; this registers the object that
    // receives the file URLs. NSUpdateDynamicServices() nudges the system to pick
    // it up promptly (notably right after a fresh install).
    [NSApp setServicesProvider:self];
    NSUpdateDynamicServices();

    // Load config.xml preferences before building UI (applies saved XML → NSUserDefaults)
    readConfigXML();

    [MenuBuilder buildMainMenu];

    // Apply saved shortcut overrides from shortcuts.xml <InternalCommands>
    [self _loadShortcutOverrides];

    // Load built-in language definitions from langs.xml (keywords, extensions, comments).
    [[NppLangsManager shared] loadLangs];

    // Load User Defined Languages from bundled + user directories.
    [[UserDefineLangManager shared] loadAll];

    // On first launch, auto-detect language from macOS system preferences.
    // Maps ISO language codes to our XML filename stems.
    if (![[NSUserDefaults standardUserDefaults] objectForKey:kPrefLanguage]) {
        static NSDictionary *langCodeMap = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            langCodeMap = @{
                @"en": @"english",
                @"af": @"afrikaans", @"sq": @"albanian", @"am": @"amharic",
                @"ar": @"arabic", @"hy": @"armenian", @"az": @"azerbaijani",
                @"eu": @"basque", @"be": @"belarusian", @"bn": @"bengali",
                @"bs": @"bosnian", @"pt-BR": @"brazilian_portuguese",
                @"bg": @"bulgarian", @"ca": @"catalan",
                @"zh-Hans": @"chineseSimplified", @"zh": @"chineseSimplified",
                @"hr": @"croatian", @"cs": @"czech", @"da": @"danish",
                @"nl": @"dutch", @"et": @"estonian", @"fi": @"finnish",
                @"fr": @"french", @"gl": @"galician", @"ka": @"georgian",
                @"de": @"german", @"el": @"greek", @"gu": @"gujarati",
                @"he": @"hebrew", @"hi": @"hindi", @"hu": @"hungarian",
                @"id": @"indonesian", @"ga": @"irish", @"it": @"italian",
                @"ja": @"japanese", @"kn": @"kannada", @"kk": @"kazakh",
                @"ko": @"korean", @"ku": @"kurdish", @"ky": @"kyrgyz",
                @"lo": @"lao", @"lv": @"latvian", @"lt": @"lithuanian",
                @"lb": @"luxembourgish", @"mk": @"macedonian", @"ms": @"malay",
                @"ml": @"malayalam", @"mr": @"marathi", @"mn": @"mongolian",
                @"my": @"myanmar", @"ne": @"nepali", @"nb": @"norwegian",
                @"nn": @"nynorsk", @"or": @"odia", @"ps": @"pashto",
                @"fa": @"farsi", @"pl": @"polish", @"pt": @"portuguese",
                @"pa": @"punjabi", @"ro": @"romanian", @"ru": @"russian",
                @"sr": @"serbian", @"si": @"sinhala", @"sk": @"slovak",
                @"sl": @"slovenian", @"so": @"somali", @"es": @"spanish",
                @"sw": @"swahili", @"sv": @"swedish", @"tl": @"tagalog",
                @"zh-Hant": @"taiwaneseMandarin", @"ta": @"tamil",
                @"te": @"telugu", @"th": @"thai", @"ti": @"tigrinya",
                @"tr": @"turkish", @"tk": @"turkmen", @"uk": @"ukrainian",
                @"ur": @"urdu", @"uz": @"uzbek", @"vi": @"vietnamese",
                @"cy": @"welsh", @"xh": @"xhosa", @"yo": @"yoruba",
                @"zu": @"zulu",
            };
        });

        NSString *systemLang = [NSLocale preferredLanguages].firstObject;
        NSString *stem = langCodeMap[systemLang];
        // Try base code if full code didn't match (e.g., "fr-FR" → "fr")
        if (!stem && systemLang.length > 2) {
            NSString *base = [systemLang componentsSeparatedByString:@"-"].firstObject;
            stem = langCodeMap[base];
        }
        if (stem) {
            [[NSUserDefaults standardUserDefaults] setObject:stem forKey:kPrefLanguage];
        }
    }

    // Apply the user's saved language to the freshly-built English menu.
    [[NppLocalizer shared] autoLoad];

    // Create the primary window
    self.mainWindowController = [[MainWindowController alloc] init];
    [_windowControllers addObject:self.mainWindowController];

    // ── Apply CLI params BEFORE showing window ─────────────────────────

    NppCommandLineParams *cli = self.cliParams;

    // Window position (-x, -y)
    if (cli && (!isnan(cli.windowX) || !isnan(cli.windowY))) {
        NSRect frame = self.mainWindowController.window.frame;
        CGFloat x = isnan(cli.windowX) ? frame.origin.x : cli.windowX;
        CGFloat y = isnan(cli.windowY) ? frame.origin.y : cli.windowY;
        [self.mainWindowController.window setFrameOrigin:NSMakePoint(x, y)];
    }

    // Always on top (-alwaysOnTop)
    if (cli.alwaysOnTop) {
        self.mainWindowController.window.level = NSFloatingWindowLevel;
    }

    // Title bar addition (-titleAdd)
    if (cli.titleAdd.length) {
        NSString *base = self.mainWindowController.window.title ?: @"Nextpad++";
        self.mainWindowController.window.title = [NSString stringWithFormat:@"%@ - %@", base, cli.titleAdd];
    }

    [self.mainWindowController showWindow:nil];

    // Tab bar visibility (-notabbar)
    if (cli.noTabBar) {
        [self.mainWindowController performSelector:@selector(_hideTabBarForCLI)];
    }

    // ── Session / file handling ─────────────────────────────────────────

    BOOL hasContent = NO;
    if (cli.sessionFile.length) {
        [self.mainWindowController loadSessionFromPath:cli.sessionFile];
        hasContent = YES;
    } else if (cli.filePaths.count > 0) {
        [self _openFilesFromCLI:cli inController:self.mainWindowController];
        hasContent = YES;
    } else if (!cli.noSession &&
               [[NSUserDefaults standardUserDefaults] boolForKey:kPrefRememberSession]) {
        // Issue #87 — Preferences > Backup > "Remember current session for next launch"
        // mirrors the Windows NPP RememberLastSession option. Off → start with a clean
        // editor on each launch. -nosession CLI flag still overrides per-invocation.
        hasContent = [self.mainWindowController restoreLastSession];
    }
    // If nothing was opened, create an empty tab (first launch or -nosession with no files)
    if (!hasContent) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.mainWindowController performSelector:@selector(newDocument:) withObject:nil];
        #pragma clang diagnostic pop
    }

    // Re-open side panels that were open last quit (issue #132). Primary
    // window only — secondary windows from Window > New Window must not
    // inherit the restore. Deferred onto the main queue so it runs AFTER
    // the side-panel collapse block that buildContentView enqueues during
    // -init: that block was enqueued first, so FIFO ordering guarantees
    // the collapse runs before this restore. Calling restore synchronously
    // here would let the later-running collapse re-hide the panels.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.mainWindowController restoreSidePanels];
    });

    // ── Plugins ─────────────────────────────────────────────────────────

    if (!cli.noPlugin) {
        NppPluginManager *pm = [NppPluginManager shared];
        [pm setMainWindowController:self.mainWindowController];
        [pm loadPlugins];

        if (pm.hasPlugins) {
            [MenuBuilder insertPluginMenuItems:[pm pluginMenuItems]];
        }
        [pm fireReady];

        // Re-apply shortcut overrides now that plugin menu items exist.
        // The first call at startup (line 38) ran before plugins loaded,
        // so PluginCommands entries in shortcuts.xml found no matching
        // menu items. This second pass picks them up. InternalCommands,
        // Macro, and Run sections harmlessly re-apply the same shortcuts.
        [self _loadShortcutOverrides];

        // Regenerate toolbar example XML with plugin entries
        regenerateToolbarExample();
    }

    // ── Build recordable selectors for macro recording ────────────────
    [(NppApplication *)NSApp buildRecordableSelectorsFromMenu];

    // ── Build editor context menu (after plugins + full menu are ready) ──
    [self.mainWindowController applyEditorContextMenuToAll];

    // ── Loading time (-loadingTime) ─────────────────────────────────────

    if (self.launchStart) {
        NSTimeInterval elapsed = -[self.launchStart timeIntervalSinceNow];
        NSString *msg = [NSString stringWithFormat:@"Loading time: %.2f seconds", elapsed];
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = [[NppLocalizer shared] translate:@"Nextpad++ Loading Time"];
        a.informativeText = msg;
        a.icon = [[NSImage alloc] initWithContentsOfFile:
            NppConfigSubpath(@"plugins/Config/logo100px.png")];
        [a runModal];
    }

    // ── Quick print (-quickPrint) ───────────────────────────────────────

    if (cli.quickPrint && cli.filePaths.count > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.mainWindowController performSelector:@selector(printDocument:) withObject:nil];
            #pragma clang diagnostic pop
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [NSApp terminate:nil];
            });
        });
    }

    // ── Multi-instance (-multiInst): open a second empty window ─────────

    if (cli.multiInstance) {
        [self openNewWindow];
    }

    // ── Mark launch complete and process any pending file-open requests ────
    _didFinishLaunching = YES;
    if (_pendingFilePaths.count > 0) {
        NSArray<NSString *> *files = [self _expandFolderArguments:_pendingFilePaths];
        [_pendingFilePaths removeAllObjects];
        for (NSString *path in files) {
            [self.mainWindowController openFileAtPath:path];
        }
        // Files queued during launch mean the user explicitly asked us to
        // open something. NSApplication usually foregrounds a launching
        // app naturally, but state restoration can leave the window
        // miniaturized — call the helper so the freshly-loaded files are
        // actually visible (issue #63).
        if (files.count > 0) [self.mainWindowController bringWindowForward];
    }

    // ── Initial keyboard focus to the active editor (issue #34) ─────────
    // Without this, the user's first keystrokes after relaunch go nowhere
    // and VoiceOver announces a splitter instead of the editor. The fix
    // has two parts: (1) target SCIContentView via .content, not the
    // ScintillaView NSView wrapper — ScintillaView itself is not in the
    // editor's keyDown: chain, so making it first responder leaves typing
    // dead until the user clicks inside the editor; (2) defer the call
    // to the next runloop tick so it runs after AppKit has finished
    // settling the freshly-shown window's first responder.
    dispatch_async(dispatch_get_main_queue(), ^{
        EditorView *ed = [self.mainWindowController currentEditor];
        if (ed.scintillaView.content) {
            [self.mainWindowController.window makeFirstResponder:ed.scintillaView.content];
        }
    });

    // ── Background update check (non-blocking, after 5 second delay) ────
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self checkForUpdateUserInitiated:NO];
    });
}

// ── New Window ──────────────────────────────────────────────────────────────

- (MainWindowController *)openNewWindow {
    MainWindowController *mwc = [[MainWindowController alloc] init];
    [_windowControllers addObject:mwc];

    // Offset from the primary window so they don't stack exactly
    NSRect primaryFrame = self.mainWindowController.window.frame;
    NSRect newFrame = NSOffsetRect(primaryFrame, 30, -30);
    [mwc.window setFrame:newFrame display:NO];

    [mwc showWindow:nil];

    // Observe close to remove from our array. Keep the returned token and
    // remove the observer when it fires — otherwise the notification center
    // retains the block (which strongly captures mwc) for the app's lifetime,
    // leaking every opened-and-closed secondary window's controller and its
    // whole object graph.
    __block id closeToken =
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification
                                                          object:mwc.window
                                                           queue:nil
                                                      usingBlock:^(NSNotification *note) {
        [self.windowControllers removeObject:mwc];
        [[NSNotificationCenter defaultCenter] removeObserver:closeToken];
        // Also drop the __block storage's strong ref to the token, otherwise
        // token -> block -> __block storage -> token stays a retained island
        // (which captures mwc) even after the center deregisters it. The center
        // retains the block across this in-flight post, so it is safe to release
        // our last ref here. (Bug B leak fix.)
        closeToken = nil;
    }];

    return mwc;
}

// ── Folder argument expansion ────────────────────────────────────────────────

// Expands any directory in `paths` to its TOP-LEVEL regular files. There
// is no recursion: subdirectories and hidden entries (dotfiles) are
// skipped. Plain file paths — and non-existent paths — pass through
// unchanged so the opener keeps its existing behaviour. If expanding a
// folder pushes the total file count past kFolderOpenConfirmThreshold the
// user is asked once; returns nil if they decline.
- (NSArray<NSString *> *)_expandFolderArguments:(NSArray<NSString *> *)paths {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    BOOL anyFolderExpanded = NO;

    for (NSString *path in paths) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
            [result addObject:path];
            continue;
        }
        anyFolderExpanded = YES;
        NSArray<NSString *> *entries =
            [[fm contentsOfDirectoryAtPath:path error:nil]
                sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        for (NSString *name in entries) {
            if ([name hasPrefix:@"."]) continue;            // skip hidden
            NSString *full = [path stringByAppendingPathComponent:name];
            BOOL childIsDir = NO;
            [fm fileExistsAtPath:full isDirectory:&childIsDir];
            if (childIsDir) continue;                       // skip subfolders
            [result addObject:full];
        }
    }

    if (anyFolderExpanded && result.count > kFolderOpenConfirmThreshold) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [[NppLocalizer shared] translate:@"Open all files in folder?"];
        alert.informativeText = [NSString stringWithFormat:
            [[NppLocalizer shared] translate:@"This will open %lu files in new tabs."],
            (unsigned long)result.count];
        [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Open"]];
        [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Cancel"]];
        if ([alert runModal] != NSAlertFirstButtonReturn) return nil;
    }
    return result;
}

// ── Open files from CLI ─────────────────────────────────────────────────────

- (void)_openFilesFromCLI:(NppCommandLineParams *)cli inController:(MainWindowController *)mwc {
    NSFileManager *fm = [NSFileManager defaultManager];
    EditorView *lastEditor = nil;

    for (NSString *path in cli.filePaths) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
            if (cli.openFoldersAsWorkspace) continue;
        }

        if (isDir && cli.openFoldersAsWorkspace) {
            [mwc performSelector:@selector(showFolderAsWorkspace:) withObject:nil];
            continue;
        }

        if (isDir && cli.recursive) {
            NSDirectoryEnumerator *en = [fm enumeratorAtPath:path];
            NSString *sub;
            while ((sub = [en nextObject])) {
                NSString *fullPath = [path stringByAppendingPathComponent:sub];
                BOOL subIsDir = NO;
                [fm fileExistsAtPath:fullPath isDirectory:&subIsDir];
                if (!subIsDir) {
                    [mwc openFileAtPath:fullPath];
                    lastEditor = [mwc currentEditor];
                }
            }
            continue;
        }

        if (isDir) {
            // Bare folder (no -r / -openFoldersAsWorkspace): open its
            // top-level files — same behaviour as a folder handed to an
            // already-running instance (issue #131).
            NSArray<NSString *> *folderFiles = [self _expandFolderArguments:@[path]];
            for (NSString *folderFile in folderFiles) {
                [mwc openFileAtPath:folderFile];
                lastEditor = [mwc currentEditor];
            }
            continue;
        }

        [mwc openFileAtPath:path];
        lastEditor = [mwc currentEditor];
    }

    if (lastEditor) {
        if (cli.language.length) [lastEditor setLanguage:cli.language];
        if (cli.udlName.length) [lastEditor setLanguage:cli.udlName];
        if (cli.readOnly) [lastEditor.scintillaView message:SCI_SETREADONLY wParam:1 lParam:0];
        if (cli.monitorFiles) lastEditor.monitoringMode = YES;

        if (cli.bytePosition >= 0) {
            [lastEditor.scintillaView message:SCI_GOTOPOS wParam:(uptr_t)cli.bytePosition lParam:0];
            [lastEditor.scintillaView message:SCI_SCROLLCARET wParam:0 lParam:0];
        } else if (cli.lineNumber > 0) {
            if (cli.columnNumber > 0) {
                sptr_t pos = [lastEditor.scintillaView message:SCI_FINDCOLUMN
                                                        wParam:(uptr_t)(cli.lineNumber - 1)
                                                        lParam:(sptr_t)(cli.columnNumber - 1)];
                [lastEditor.scintillaView message:SCI_GOTOPOS wParam:(uptr_t)pos lParam:0];
            } else {
                [lastEditor goToLineNumber:cli.lineNumber];
            }
            [lastEditor.scintillaView message:SCI_SCROLLCARET wParam:0 lParam:0];
        }
    }
}

// ── App lifecycle ───────────────────────────────────────────────────────────

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    // Windows NPP behaviour: no save prompts on quit.
    // Each window saves session + backups, then closes silently.
    for (NSInteger i = (NSInteger)_windowControllers.count - 1; i >= 0; i--) {
        MainWindowController *mwc = _windowControllers[i];
        NSWindow *win = mwc.window;
        if (win) {
            [(id<NSWindowDelegate>)mwc windowShouldClose:win];
            [_windowControllers removeObjectAtIndex:i];
            [win close];
        }
    }
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [[NppPluginManager shared] shutdown];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    if (!_didFinishLaunching) {
        // App still launching — queue the file for processing after init completes
        [_pendingFilePaths addObject:filename];
        return YES;
    }
    // A folder argument expands to its top-level files (issue #131).
    NSArray<NSString *> *files = [self _expandFolderArguments:@[filename]];
    if (files.count == 0) return YES;  // empty folder, or large-open declined
    MainWindowController *mwc = [self _activeWindowController];
    for (NSString *path in files) {
        [mwc openFileAtPath:path];
    }
    // Issue #63: surface the window to the user. Without this, opening a
    // file from Finder while the app is minimized silently adds the file
    // to a tab inside an invisible window and the user has to hunt for
    // the Dock icon to see it.
    [mwc bringWindowForward];
    return YES;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    if (!_didFinishLaunching) {
        [_pendingFilePaths addObjectsFromArray:filenames];
        [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
        return;
    }
    // Folder arguments expand to their top-level files (issue #131).
    NSArray<NSString *> *files = [self _expandFolderArguments:filenames];
    if (files.count > 0) {
        MainWindowController *mwc = [self _activeWindowController];
        for (NSString *path in files) {
            [mwc openFileAtPath:path];
        }
        // Issue #63: bring the window forward AFTER all files are added so
        // there's no flicker between batches and the front-most tab is the
        // last one opened (the standard macOS behaviour for multi-file open).
        [mwc bringWindowForward];
    }
    [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

/// Issue #126 — "Open with Nextpad++" Finder service handler. Declared via
/// NSServices in Info.plist (NSMessage=openFilesService). Finder places the
/// selected items on the pasteboard as file URLs; we route them through the
/// same open path as Apple-event opens (folder expansion + window surfacing),
/// so files and folders behave identically to a Finder double-click / drag.
- (void)openFilesService:(NSPasteboard *)pboard
                userData:(NSString *)userData
                   error:(NSString **)error {
    NSArray *objs = [pboard readObjectsForClasses:@[[NSURL class]]
                                          options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *url in objs) {
        if (url.isFileURL && url.path.length) [paths addObject:url.path];
    }
    // Fallback: a sender that only supplied a plain string path.
    if (paths.count == 0) {
        NSString *s = [pboard stringForType:NSPasteboardTypeString];
        if (s.length) [paths addObject:s];
    }
    if (paths.count == 0) return;

    // Service can cold-start the app: queue until launch completes, where
    // applicationDidFinishLaunching drains _pendingFilePaths (with folder
    // expansion) and surfaces the window.
    if (!_didFinishLaunching) {
        [_pendingFilePaths addObjectsFromArray:paths];
        return;
    }

    NSArray<NSString *> *files = [self _expandFolderArguments:paths];
    if (files.count == 0) return;  // empty folder, or large-open declined
    MainWindowController *mwc = [self _activeWindowController];
    for (NSString *path in files) {
        [mwc openFileAtPath:path];
    }
    [mwc bringWindowForward];  // activates Nextpad++ over Finder
}

/// Returns the window controller for the key window, or mainWindowController as fallback.
- (MainWindowController *)_activeWindowController {
    NSWindow *key = [NSApp keyWindow];
    for (MainWindowController *mwc in _windowControllers) {
        if (mwc.window == key) return mwc;
    }
    return self.mainWindowController;
}

// ── Preferences / About ─────────────────────────────────────────────────────

/// Load shortcut overrides from shortcuts.xml <InternalCommands> and apply to live menu items.
- (void)_loadShortcutOverrides {
    NSString *path = NppConfigSubpath(@"shortcuts.xml");
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        NSLog(@"[Shortcuts] No shortcuts.xml found at %@ — skipping overrides", path);
        return;
    }

    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:nil];
    if (!doc) return;

    // Helper block to apply a shortcut override to a menu item
    void (^applyOverride)(NSXMLElement *, NSMenuItem *) = ^(NSXMLElement *sc, NSMenuItem *mi) {
        BOOL hasCtrl  = [[[sc attributeForName:@"Ctrl"]  stringValue] isEqualToString:@"yes"];
        BOOL hasAlt   = [[[sc attributeForName:@"Alt"]   stringValue] isEqualToString:@"yes"];
        BOOL hasShift = [[[sc attributeForName:@"Shift"] stringValue] isEqualToString:@"yes"];
        BOOL hasCmd   = [[[sc attributeForName:@"Cmd"]   stringValue] isEqualToString:@"yes"];
        NSUInteger keyCode = [[[sc attributeForName:@"Key"] stringValue] integerValue];

        if (!hasCmd && hasCtrl && ![sc attributeForName:@"Cmd"]) {
            hasCmd = YES; hasCtrl = NO;
        }

        if (keyCode == 0) {
            mi.keyEquivalent = @"";
            mi.keyEquivalentModifierMask = 0;
        } else {
            NSEventModifierFlags mods = 0;
            if (hasCmd)   mods |= NSEventModifierFlagCommand;
            if (hasCtrl)  mods |= NSEventModifierFlagControl;
            if (hasAlt)   mods |= NSEventModifierFlagOption;
            if (hasShift) mods |= NSEventModifierFlagShift;

            NSString *key = @"";
            if (keyCode >= 'A' && keyCode <= 'Z')
                key = [[NSString stringWithFormat:@"%c", (char)keyCode] lowercaseString];
            else if (keyCode >= '0' && keyCode <= '9')
                key = [NSString stringWithFormat:@"%c", (char)keyCode];
            else if (keyCode >= 112 && keyCode <= 123) {
                unichar fk = NSF1FunctionKey + (keyCode - 112);
                key = [NSString stringWithCharacters:&fk length:1];
            } else
                key = [[NSString stringWithFormat:@"%c", (char)keyCode] lowercaseString];

            mi.keyEquivalent = key;
            mi.keyEquivalentModifierMask = mods;
        }
    };

    NSInteger totalApplied = 0;

    // ── InternalCommands (main menu shortcuts) ──
    for (NSXMLElement *sc in [doc nodesForXPath:@"//InternalCommands/Shortcut" error:nil]) {
        NSString *selectorName = [[sc attributeForName:@"id"] stringValue];
        if (!selectorName.length) continue;
        SEL sel = NSSelectorFromString(selectorName);
        NSMenuItem *mi = [self _findMenuItemWithAction:sel inMenu:[NSApp mainMenu]];
        if (!mi) { NSLog(@"[Shortcuts] WARNING: not found '%@'", selectorName); continue; }
        applyOverride(sc, mi);
        totalApplied++;
    }

    // ── PluginCommands ──
    // Look up the Plugins / Macro / Run top-level menus by tag rather than
    // English title — when the user runs in a non-English locale the menu
    // titles are translated by NppLocalizer (e.g. "Плагины", "Макрос",
    // "Запустить"), and an isEqualToString:@"Plugins" check would silently
    // skip the entire shortcut-override pass. Tags are assigned in
    // MenuBuilder at build time and survive translation.
    NSMenu *pluginsMenu = [[[NSApp mainMenu] itemWithTag:kMenuTagPlugins] submenu];
    if (pluginsMenu) {
        for (NSXMLElement *pc in [doc nodesForXPath:@"//PluginCommands/PluginCommand" error:nil]) {
            NSString *pluginName = [[pc attributeForName:@"moduleName"] stringValue];
            NSInteger internalID = [[[pc attributeForName:@"internalID"] stringValue] integerValue];
            for (NSMenuItem *pluginItem in pluginsMenu.itemArray) {
                if (![pluginItem.title isEqualToString:pluginName]) continue;
                if (!pluginItem.submenu) continue;
                NSInteger cmdIdx = 0;
                for (NSMenuItem *cmdItem in pluginItem.submenu.itemArray) {
                    if (cmdItem.isSeparatorItem || !cmdItem.action) continue;
                    if (cmdItem.tag == internalID || cmdIdx == internalID) {
                        applyOverride(pc, cmdItem);
                        totalApplied++;
                        goto nextPlugin;
                    }
                    cmdIdx++;
                }
            }
            nextPlugin:;
        }
    }

    // ── Macro shortcuts ──
    NSMenu *macroMenu = [[[NSApp mainMenu] itemWithTag:kMenuTagMacro] submenu];
    if (macroMenu) {
        for (NSXMLElement *mc in [doc nodesForXPath:@"//Macros/Macro" error:nil]) {
            NSString *macroName = [[mc attributeForName:@"name"] stringValue];
            NSUInteger keyCode = [[[mc attributeForName:@"Key"] stringValue] integerValue];
            if (keyCode == 0) continue;
            for (NSMenuItem *mi in macroMenu.itemArray) {
                if ([mi.title isEqualToString:macroName]) {
                    applyOverride(mc, mi);
                    totalApplied++;
                    break;
                }
            }
        }
    }

    // ── Run Commands (UserDefinedCommands) ──
    NSMenu *runMenu = [[[NSApp mainMenu] itemWithTag:kMenuTagRun] submenu];
    if (runMenu) {
        for (NSXMLElement *rc in [doc nodesForXPath:@"//UserDefinedCommands/Command" error:nil]) {
            NSString *cmdName = [[rc attributeForName:@"name"] stringValue];
            NSUInteger keyCode = [[[rc attributeForName:@"Key"] stringValue] integerValue];
            if (keyCode == 0 || !cmdName.length) continue;
            for (NSMenuItem *mi in runMenu.itemArray) {
                if ([mi.title isEqualToString:cmdName]) {
                    applyOverride(rc, mi);
                    totalApplied++;
                    break;
                }
            }
        }
    }

    NSLog(@"[Shortcuts] Applied %ld shortcut override(s) from shortcuts.xml", (long)totalApplied);
}

- (nullable NSMenuItem *)_findMenuItemWithAction:(SEL)action inMenu:(NSMenu *)menu {
    for (NSMenuItem *mi in menu.itemArray) {
        if (mi.action == action) return mi;
        if (mi.submenu) {
            [mi.submenu update]; // force populate nested submenus
            NSMenuItem *found = [self _findMenuItemWithAction:action inMenu:mi.submenu];
            if (found) return found;
        }
    }
    return nil;
}

- (void)openNewWindow:(id)sender {
    [self openNewWindow];
}

- (void)showPreferences:(id)sender {
    [[PreferencesWindowController sharedController] showWindow:nil];
}

- (void)showStyleConfigurator:(id)sender {
    [[StyleConfiguratorWindowController sharedController] showWindow:nil];
}

- (void)importStyleTheme:(id)sender {
    NppLocalizer *loc = [NppLocalizer shared];

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = [loc translate:@"Import Style Theme"];
    panel.allowedFileTypes = @[@"xml"];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = NO;
    if ([panel runModal] != NSModalResponseOK) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *themesDir = NppConfigSubpath(@"themes");
    [fm createDirectoryAtPath:themesDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSInteger imported = 0;
    for (NSURL *url in panel.URLs) {
        NSString *destPath = [themesDir stringByAppendingPathComponent:url.lastPathComponent];
        [fm removeItemAtPath:destPath error:nil]; // overwrite existing
        if ([fm copyItemAtPath:url.path toPath:destPath error:nil]) {
            imported++;
        }
    }

    if (imported > 0) {
        // Open Style Configurator so user can select the newly imported theme
        [[StyleConfiguratorWindowController sharedController] showWindow:nil];
    }
}

- (void)showAboutPanel:(id)sender {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0.0";

#if defined(__arm64__)
    NSString *archStr = @"ARM 64-bit";
#elif defined(__x86_64__)
    NSString *archStr = @"64-bit";
#else
    NSString *archStr = @"unknown";
#endif

    NSAlert *about = [[NSAlert alloc] init];
    about.messageText = [NSString stringWithFormat:@"Nextpad++ macOS v%@     (%@)", version, archStr];

    NSString *license =
        @"GNU General Public Licence\n\n"
        @"This program is free software; you can redistribute it and/or "
        @"modify it under the terms of the GNU General Public License "
        @"as published by the Free Software Foundation; either version 3 "
        @"of the License, or at your option any later version.\n\n"
        @"This program is distributed in the hope that it will be useful, "
        @"but WITHOUT ANY WARRANTY; without even the implied warranty of "
        @"MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the "
        @"GNU General Public License for more details.\n\n"
        @"You should have received a copy of the GNU General Public "
        @"License along with this program. If not, see\n"
        @"<https://www.gnu.org/licenses/>.";

    about.informativeText = [NSString stringWithFormat:
        @"Build time: %s - %s\n\n"
        @"Home: https://nextpad.org\n\n"
        @"%@", __DATE__, __TIME__, license];

    // Use our logo
    NSImage *logo = [[NSImage alloc] initWithContentsOfFile:
        NppConfigSubpath(@"plugins/Config/logo100px.png")];
    if (!logo) {
        // Fallback: try bundle resource
        NSString *logoPath = [[NSBundle mainBundle] pathForResource:@"logo100px" ofType:@"png"
                                                        inDirectory:@"icons/standard/about"];
        if (logoPath) logo = [[NSImage alloc] initWithContentsOfFile:logoPath];
    }
    if (logo) about.icon = logo;

    [about addButtonWithTitle:[[NppLocalizer shared] translate:@"OK"]];
    [about runModal];
}

// ── Update check (GitHub Releases API) ──────────────────────────────────────

static NSString *const kGitHubReleasesAPI = @"https://api.github.com/repos/nextpad-plus-plus/nextpad-plus-plus-macos/releases/latest";
static NSString *const kUpdateMenuItemTag = @"checkForUpdatesMenuItem";

/// Find the "Check for Updates..." menu item in the app menu.
- (nullable NSMenuItem *)_updateMenuItem {
    NSMenu *appMenu = [NSApp mainMenu].itemArray.firstObject.submenu;
    for (NSMenuItem *mi in appMenu.itemArray) {
        if (mi.action == @selector(checkForUpdates:)) return mi;
    }
    return nil;
}

- (void)checkForUpdates:(id)sender {
    [self checkForUpdateUserInitiated:YES];
}

- (void)checkForUpdateUserInitiated:(BOOL)userInitiated {
    NSString *currentVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0.0.0";

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kGitHubReleasesAPI]];
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [req setValue:@"notepad-plus-plus-macos" forHTTPHeaderField:@"User-Agent"];
    req.timeoutInterval = 15.0;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !data) {
                if (userInitiated) {
                    NppLocalizer *loc = [NppLocalizer shared];
                    NSAlert *a = [[NSAlert alloc] init];
                    a.messageText = [loc translate:@"Unable to Check for Updates"];
                    a.informativeText = error.localizedDescription ?: [loc translate:@"No response from server."];
                    [a runModal];
                }
                return;
            }

            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (statusCode != 200) {
                if (userInitiated) {
                    NppLocalizer *loc = [NppLocalizer shared];
                    NSAlert *a = [[NSAlert alloc] init];
                    a.messageText = [loc translate:@"Unable to Check for Updates"];
                    a.informativeText = [NSString stringWithFormat:
                        @"%@ %ld. %@", [loc translate:@"Server returned status"], (long)statusCode, [loc translate:@"The repository may be private."]];
                    [a runModal];
                }
                return;
            }

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (!json) return;

            NSString *tagName = json[@"tag_name"]; // e.g. "v1.1.0"
            if (!tagName.length) return;

            // Strip leading 'v' if present
            NSString *latestVersion = tagName;
            if ([latestVersion hasPrefix:@"v"])
                latestVersion = [latestVersion substringFromIndex:1];

            NSComparisonResult cmp = [latestVersion compare:currentVersion options:NSNumericSearch];

            if (cmp == NSOrderedDescending) {
                // Update available — badge the menu item
                NSMenuItem *mi = [self _updateMenuItem];
                if (mi) {
                        mi.title = [NSString stringWithFormat:@"Update Available (v%@)", latestVersion];
                    NSString *imgPath = [[NSBundle mainBundle] pathForResource:@"icons/standard/status/status_yellow" ofType:@"png"];
                    if (imgPath) {
                        NSImage *img = [[NSImage alloc] initWithContentsOfFile:imgPath];
                        [img setSize:NSMakeSize(12, 12)];
                        mi.image = img;
                    }
                }

                if (userInitiated) {
                    [self _showUpdateAlertForVersion:latestVersion
                                       releaseNotes:json[@"body"]
                                          htmlURL:json[@"html_url"]
                                           assets:json[@"assets"]];
                }
            } else {
                // Up to date — leave the menu item plain (no badge / icon).
                NSMenuItem *mi = [self _updateMenuItem];
                if (mi) {
                    mi.title = @"Check for Updates…";
                    mi.image = nil;
                }

                if (userInitiated) {
                    NppLocalizer *loc = [NppLocalizer shared];
                    NSAlert *a = [[NSAlert alloc] init];
                    a.messageText = [loc translate:@"You're Up to Date"];
                    a.informativeText = [NSString stringWithFormat:
                        @"Nextpad++ %@ %@", currentVersion, [loc translate:@"is the latest version."]];
                    [a runModal];
                }
            }
        });
    }];
    [task resume];
}

- (void)_showUpdateAlertForVersion:(NSString *)version
                      releaseNotes:(NSString *)notes
                         htmlURL:(NSString *)htmlURL
                          assets:(NSArray *)assets {
    NSString *currentVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0.0.0";

    NppLocalizer *loc = [NppLocalizer shared];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Nextpad++ v%@ %@", version, [loc translate:@"is Available"]];
    alert.informativeText = [NSString stringWithFormat:
        @"%@ v%@.\n\n%@",
        [loc translate:@"You are currently running"],
        currentVersion,
        (notes.length > 500) ? [[notes substringToIndex:500] stringByAppendingString:@"…"] : (notes ?: @"")];
    [alert addButtonWithTitle:[loc translate:@"Download"]];
    [alert addButtonWithTitle:[loc translate:@"Release Page"]];
    [alert addButtonWithTitle:[loc translate:@"Later"]];

    NSModalResponse resp = [alert runModal];

    if (resp == NSAlertFirstButtonReturn) {
        // Find DMG asset in release assets
        NSString *downloadURL = nil;
        for (NSDictionary *asset in assets) {
            NSString *name = asset[@"name"];
            if ([name.lowercaseString hasSuffix:@".dmg"]) {
                downloadURL = asset[@"browser_download_url"];
                break;
            }
        }
        if (!downloadURL) downloadURL = htmlURL; // fallback to release page
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:downloadURL]];
    } else if (resp == NSAlertSecondButtonReturn) {
        if (htmlURL.length)
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:htmlURL]];
    }
}

@end
