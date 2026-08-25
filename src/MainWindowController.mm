#import "MainWindowController.h"
#import "NppPaths.h"                 // NppConfigDir()/NppConfigSubpath()
#import <QuartzCore/QuartzCore.h>   // CAGradientLayer (Tahoe window backdrop)
#import "TahoeToolbarConfig.h"      // Tahoe toolbar group layout (Liquid Glass)
#import "AppDelegate.h"
#import "NppBuiltinLanguages.h"
#import "NppCommandLineParams.h"
#import "TabManager.h"
#import "EditorView.h"
#import "FindReplacePanel.h"
#import "FindWindow.h"
#import "SearchResultsPanel.h"
#import "SearchEngine.h"
#import "NPPBatchDialog.h"
#import "MenuBuilder.h"
#import "ColumnEditorPanel.h"
// FindInFilesPanel removed — all search goes through FindWindow
#import "SidePanelHost.h"
#import "DocumentListPanel.h"
#import "ClipboardHistoryPanel.h"
#import "FunctionListPanel.h"
#import "DocumentMapPanel.h"
#import "ProjectPanel.h"
#import "PreferencesWindowController.h"
#import "StyleConfiguratorWindowController.h"
#import "ShortcutMapperWindowController.h"
#import "IncrementalSearchBar.h"
#import "CommandPalettePanel.h"
#import "GitHelper.h"
#import "GitPanel.h"
#import "FolderTreePanel.h"
#import "CharacterPanel.h"
#import "PluginsAdminWindowController.h"
#import "NppPluginManager.h"
#ifndef NPPN_BUFFERACTIVATED
#define NPPN_BUFFERACTIVATED 1010
#endif
#import "ShortcutMapperWindowController.h"
#import "UserDefineLangManager.h"
#import "UserDefineDialog.h"
#import "NppThemeManager.h"
#import "NppLocalizer.h"
#import <objc/runtime.h>
#include <sys/sysctl.h>
#include <sys/resource.h>

// ── Private helper for the Windows… dialog ───────────────────────────────────
@interface _NPPWindowsListHelper : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSArray<NSDictionary *> *rows;
@property (nonatomic, weak)   NSTableView *tableView;
@property (nonatomic, copy)   void (^activateHandler)(void);
@property (nonatomic, copy)   void (^closeHandler)(void);
- (instancetype)initWithRows:(NSArray<NSDictionary *> *)rows;
- (void)activatePressed:(id)sender;
- (void)closePressed:(id)sender;
@end

@implementation _NPPWindowsListHelper
- (instancetype)initWithRows:(NSArray<NSDictionary *> *)rows {
    self = [super init];
    _rows = rows;
    return self;
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)_rows.count; }
- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSTextField *f = [tv makeViewWithIdentifier:col.identifier owner:nil];
    if (!f) {
        f = [NSTextField labelWithString:@""];
        f.identifier = col.identifier;
        f.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
    NSDictionary *entry = _rows[row];
    if ([col.identifier isEqualToString:@"name"]) {
        NSString *name = entry[@"name"];
        f.stringValue = [entry[@"modified"] boolValue]
            ? [NSString stringWithFormat:@"* %@", name] : name;
    } else if ([col.identifier isEqualToString:@"ext"]) {
        NSString *path = entry[@"path"];
        f.stringValue = path.length ? path.pathExtension : @"";
    } else {
        f.stringValue = entry[@"path"];
    }
    return f;
}
- (void)activatePressed:(id)sender { if (_activateHandler) _activateHandler(); }
- (void)closePressed:(id)sender    { if (_closeHandler)    _closeHandler();    }
@end

static NSString *const kWindowFrameKey = @"MainWindowFrame";

// ── Config paths (mirrors %APPDATA%\Nextpad++ on Windows) ────────────────────
// Base dir is ~/Library/Application Support/Nextpad++ (see NppPaths.h); legacy
// ~/.nextpad++ installs are migrated on first use.
static NSString *nppConfigDir(void) {
    return NppConfigDir();
}
static NSString *nppBackupDir(void) {
    return [nppConfigDir() stringByAppendingPathComponent:@"backup"];
}
static NSString *nppSessionPath(void) {
    return [nppConfigDir() stringByAppendingPathComponent:@"session.plist"];
}
// Forward declarations for shortcuts.xml functions (defined after @implementation)
static NSString *nppShortcutsPath(void);
// Non-static so NPPBatchDialog can link against it. Forward-declared here for
// in-file callers; NPPBatchDialog.mm extern-declares it.
NSArray<NSDictionary *> *loadMacrosFromShortcutsXML(void);
static void addMacroToShortcutsXML(NSString *name, NSArray<NSDictionary *> *actions,
                                   BOOL ctrl, BOOL alt, BOOL shift, BOOL cmd, NSUInteger keyCode);
static void removeMacroFromShortcutsXML(NSString *name);

#pragma mark - Context menu XML parser

/// Walk a menu recursively to find an item by title (case-insensitive, strips shortcuts).
static NSMenuItem *_ctxFindMenuItemByTitle(NSMenu *menu, NSString *title) {
    NSString *target = title.lowercaseString;
    for (NSMenuItem *mi in menu.itemArray) {
        if (mi.isSeparatorItem) continue;
        NSString *clean = mi.title;
        NSRange tabR = [clean rangeOfString:@"\t"];
        if (tabR.location != NSNotFound) clean = [clean substringToIndex:tabR.location];
        clean = [clean stringByReplacingOccurrencesOfString:@"&" withString:@""];
        clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([clean.lowercaseString isEqualToString:target]) return mi;
        if (mi.submenu) {
            NSMenuItem *found = _ctxFindMenuItemByTitle(mi.submenu, title);
            if (found) return found;
        }
    }
    return nil;
}

/// Find a submenu by title (non-recursive, only direct children).
static NSMenu *_ctxFindSubMenuByTitle(NSMenu *menu, NSString *title) {
    NSString *target = title.lowercaseString;
    for (NSMenuItem *mi in menu.itemArray) {
        if (mi.isSeparatorItem || !mi.submenu) continue;
        NSString *clean = mi.title;
        clean = [clean stringByReplacingOccurrencesOfString:@"&" withString:@""];
        clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([clean.lowercaseString isEqualToString:target]) return mi.submenu;
        // Also check one level deeper for nested submenus
        NSMenu *deeper = _ctxFindSubMenuByTitle(mi.submenu, title);
        if (deeper) return deeper;
    }
    return nil;
}

/// Build editor context menu from XML. Returns nil if file not found or parse fails.
static NSMenu *_buildEditorContextMenuFromXML(NSString *xmlPath) {
    NSData *data = [NSData dataWithContentsOfFile:xmlPath];
    if (!data) return nil;

    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:nil];
    if (!doc) return nil;

    NSArray *items = [doc nodesForXPath:@"//ScintillaContextMenu/Item" error:nil];
    if (!items.count) return nil;

    NSMenu *mainMenu = [NSApp mainMenu];
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@""];
    NSMutableDictionary<NSString *, NSMenu *> *folders = [NSMutableDictionary dictionary];

    // The on-disk XML stays in English (so users edit a stable file). Each
    // lookup key and visible label is run through NppLocalizer here so the
    // matching against the (already-translated) main menu succeeds, and so
    // FolderName / ItemNameAs strings display in the active language.
    // -translate: returns its input unchanged when not in the dictionary —
    // safe to apply blindly (plugin names, macro names, custom user labels
    // come back as-is).
    NppLocalizer *loc = [NppLocalizer shared];
    NSString *(^xlate)(NSString *) = ^NSString *(NSString *s) {
        return s.length ? [loc translate:s] : s;
    };

    for (NSXMLElement *el in items) {
        NSString *folderName  = xlate([[el attributeForName:@"FolderName"] stringValue]);
        NSString *menuEntry   = xlate([[el attributeForName:@"MenuEntryName"] stringValue]);
        NSString *menuItem    = xlate([[el attributeForName:@"MenuItemName"] stringValue]);
        NSString *subMenuName = xlate([[el attributeForName:@"MenuSubMenuName"] stringValue]);
        NSString *displayAs   = xlate([[el attributeForName:@"ItemNameAs"] stringValue]);
        NSString *pluginEntry = xlate([[el attributeForName:@"PluginEntryName"] stringValue]);
        NSString *pluginCmd   = xlate([[el attributeForName:@"PluginCommandItemName"] stringValue]);
        NSString *macroEntry  = xlate([[el attributeForName:@"MacroEntryName"] stringValue]);
        NSInteger itemId      = [[[el attributeForName:@"id"] stringValue] integerValue];

        // Separator
        if ([[el attributeForName:@"id"] stringValue] && itemId == 0) {
            NSMenu *target = folderName.length ? folders[folderName] : contextMenu;
            if (target) [target addItem:[NSMenuItem separatorItem]];
            continue;
        }

        NSMenuItem *found = nil;

        // Plugin command lookup: Plugins > PluginName > CommandName
        if (pluginEntry.length && pluginCmd.length) {
            // Find the Plugins top-level menu
            NSMenu *pluginsMenu = nil;
            for (NSMenuItem *top in mainMenu.itemArray) {
                if (!top.submenu) continue;
                // Identify Plugins menu by looking for showPluginsAdmin: action
                for (NSMenuItem *mi in top.submenu.itemArray) {
                    if (mi.action == @selector(showPluginsAdmin:)) {
                        pluginsMenu = top.submenu;
                        break;
                    }
                }
                if (pluginsMenu) break;
            }
            if (pluginsMenu) {
                // Find plugin submenu by name
                NSMenu *pluginSub = _ctxFindSubMenuByTitle(pluginsMenu, pluginEntry);
                if (pluginSub) {
                    found = _ctxFindMenuItemByTitle(pluginSub, pluginCmd);
                }
            }
            if (!found || !found.action) continue;
        }
        // Macro command lookup: Macro menu > macro name
        else if (macroEntry.length) {
            for (NSMenuItem *top in mainMenu.itemArray) {
                if (!top.submenu) continue;
                NSMenuItem *f = _ctxFindMenuItemByTitle(top.submenu, macroEntry);
                if (f && f.action) { found = f; break; }
            }
            if (!found || !found.action) continue;
        }
        // Standard menu command lookup
        else if (menuEntry.length && menuItem.length) {
            // Find the top-level menu matching MenuEntryName
            NSMenu *entryMenu = nil;
            for (NSMenuItem *top in mainMenu.itemArray) {
                NSString *title = top.submenu.title ?: top.title;
                if ([title.lowercaseString isEqualToString:menuEntry.lowercaseString]) {
                    entryMenu = top.submenu;
                    break;
                }
            }
            if (!entryMenu) continue;

            // If MenuSubMenuName is specified, narrow search to that submenu
            NSMenu *searchIn = entryMenu;
            if (subMenuName.length) {
                NSMenu *sub = _ctxFindSubMenuByTitle(entryMenu, subMenuName);
                if (sub) searchIn = sub;
            }

            found = _ctxFindMenuItemByTitle(searchIn, menuItem);
            if (!found || !found.action) continue;
        } else {
            continue;
        }

        // Build context menu item with the resolved action
        NSString *title = displayAs.length ? displayAs : found.title;
        NSMenuItem *ctxItem = [[NSMenuItem alloc] initWithTitle:title
                                                         action:found.action
                                                  keyEquivalent:@""];
        ctxItem.target = found.target;
        // Preserve the original tag (e.g. style number) but if 0, mark as ours with sentinel
        ctxItem.tag = found.tag ?: 44000;
        if (found.image) ctxItem.image = found.image;

        // Add to folder submenu or top level
        if (folderName.length) {
            if (!folders[folderName]) {
                folders[folderName] = [[NSMenu alloc] initWithTitle:folderName];
                NSMenuItem *parent = [[NSMenuItem alloc] initWithTitle:folderName
                                                                action:nil keyEquivalent:@""];
                parent.submenu = folders[folderName];
                parent.tag = 44001; // mark as ours so menuNeedsUpdate: won't strip it
                [contextMenu addItem:parent];
            }
            [folders[folderName] addItem:ctxItem];
        } else {
            [contextMenu addItem:ctxItem];
        }
    }

    // Clean up trailing/leading/duplicate separators
    while (contextMenu.numberOfItems > 0 && [contextMenu itemAtIndex:0].isSeparatorItem)
        [contextMenu removeItemAtIndex:0];
    while (contextMenu.numberOfItems > 0 &&
           [contextMenu itemAtIndex:contextMenu.numberOfItems - 1].isSeparatorItem)
        [contextMenu removeItemAtIndex:contextMenu.numberOfItems - 1];

    return contextMenu.numberOfItems > 0 ? contextMenu : nil;
}

#pragma mark - config.xml read/write

static NSString *_configXmlPath(void) {
    return [nppConfigDir() stringByAppendingPathComponent:@"config.xml"];
}

/// Helper: "yes"/"no" string from BOOL
static NSString *_yn(BOOL v) { return v ? @"yes" : @"no"; }
/// Helper: "show"/"hide" string from BOOL
static NSString *_sh(BOOL v) { return v ? @"show" : @"hide"; }
/// Helper: BOOL from "yes"/"no" (default NO)
static BOOL _ynBool(NSString *s) { return [s.lowercaseString isEqualToString:@"yes"]; }
/// Helper: BOOL from "show"/"hide" (default NO)
static BOOL _shBool(NSString *s) { return [s.lowercaseString isEqualToString:@"show"]; }

/// Write current preferences from NSUserDefaults to ~/Library/Application Support/Nextpad++/config.xml.
void writeConfigXML(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    // Convenience: read prefs
    BOOL useTabs       = [ud boolForKey:kPrefUseTabs];
    NSInteger tabWidth = [ud integerForKey:kPrefTabWidth];
    NSInteger autoIndent = [ud integerForKey:kPrefAutoIndent];
    BOOL showLineNum   = [ud boolForKey:kPrefShowLineNumbers];
    BOOL highlightLine = [ud boolForKey:kPrefHighlightCurrentLine];
    NSInteger eolType  = [ud integerForKey:kPrefEOLType];
    NSInteger encoding = [ud integerForKey:kPrefEncoding];
    BOOL autoBackup    = [ud boolForKey:kPrefAutoBackup];
    NSInteger backupInterval = [ud integerForKey:kPrefBackupInterval];
    NSInteger zoom     = [ud integerForKey:kPrefZoomLevel];
    BOOL autoComplete  = [ud boolForKey:kPrefAutoCompleteEnable];
    NSInteger acMinChars = [ud integerForKey:kPrefAutoCompleteMinChars];
    BOOL autoClose     = [ud boolForKey:kPrefAutoCloseBrackets];
    BOOL fullPathTitle = [ud boolForKey:kPrefShowFullPathInTitle];
    NSInteger caretW   = [ud integerForKey:kPrefCaretWidth];
    NSInteger caretBlink = [ud integerForKey:kPrefCaretBlinkRate];
    NSInteger tabMaxW  = [ud integerForKey:kPrefTabMaxLabelWidth];
    BOOL tabClose      = [ud boolForKey:kPrefTabCloseButton];
    BOOL dblClickClose = [ud boolForKey:kPrefDoubleClickTabClose];
    BOOL tabBarWrap    = [ud boolForKey:kPrefTabBarWrap];
    BOOL virtualSpace  = [ud boolForKey:kPrefVirtualSpace];
    BOOL scrollBeyond  = [ud boolForKey:kPrefScrollBeyondLastLine];
    NSInteger fontQual = [ud integerForKey:kPrefFontQuality];
    BOOL copyLineNoSel = [ud boolForKey:kPrefCopyLineNoSelection];
    BOOL smartHL       = [ud boolForKey:kPrefSmartHighlight];
    BOOL fillFind      = [ud boolForKey:kPrefFillFindWithSelection];
    BOOL funcParams    = [ud boolForKey:kPrefFuncParamsHint];
    BOOL showStatus    = [ud boolForKey:kPrefShowStatusBar];
    BOOL muteSounds    = [ud boolForKey:kPrefMuteSounds];
    BOOL saveAllConf   = [ud boolForKey:kPrefSaveAllConfirm];
    BOOL rightClickSel = [ud boolForKey:kPrefRightClickKeepsSel];
    BOOL disableDrag   = [ud boolForKey:kPrefDisableTextDragDrop];
    BOOL monoFontFind  = [ud boolForKey:kPrefMonoFontFind];
    BOOL confirmRepl   = [ud boolForKey:kPrefConfirmReplaceAll];
    BOOL replStop      = [ud boolForKey:kPrefReplaceAndStop];
    BOOL smartCase     = [ud boolForKey:kPrefSmartHiliteCase];
    BOOL smartWord     = [ud boolForKey:kPrefSmartHiliteWord];
    BOOL dtReverse     = [ud boolForKey:kPrefDateTimeReverse];
    BOOL keepAbsent    = [ud boolForKey:kPrefKeepAbsentSession];
    BOOL showBookmark  = [ud boolForKey:kPrefShowBookmarkMargin];
    BOOL showEOL       = [ud boolForKey:kPrefShowEOL];
    BOOL showWS        = [ud boolForKey:kPrefShowWhitespace];
    NSInteger edgeCol  = [ud integerForKey:kPrefEdgeColumn];
    NSInteger edgeMode = [ud integerForKey:kPrefEdgeMode];
    NSInteger padL     = [ud integerForKey:kPrefPaddingLeft];
    NSInteger padR     = [ud integerForKey:kPrefPaddingRight];
    BOOL panelKeep     = [ud boolForKey:kPrefPanelKeepState];
    NSInteger foldStyle = [ud integerForKey:kPrefFoldStyle];
    BOOL dynLineNum    = [ud boolForKey:kPrefLineNumDynWidth];
    NSInteger inSelThr = [ud integerForKey:kPrefInSelThreshold];
    NSInteger darkMode = [ud integerForKey:kPrefDarkMode];
    BOOL spellCheck    = [ud boolForKey:kPrefSpellCheck];

    // Fold style names matching Windows: box, circle, arrow, simple, none
    NSArray *foldNames = @[@"box", @"circle", @"arrow", @"simple", @"none"];
    NSString *foldStr  = (foldStyle >= 0 && foldStyle < (NSInteger)foldNames.count)
                         ? foldNames[foldStyle] : @"box";

    // Dark mode mapping: 0=Auto, 1=Light, 2=Dark
    NSString *dmEnable = (darkMode == 2) ? @"yes" : @"no";

    // Build XML string
    NSMutableString *xml = [NSMutableString new];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n"];
    [xml appendString:@"<NotepadPlus>\n"];
    [xml appendString:@"    <GUIConfigs>\n"];

    // StatusBar
    [xml appendFormat:@"        <GUIConfig name=\"StatusBar\">%@</GUIConfig>\n",
     showStatus ? @"show" : @"hide"];

    // TabBar
    [xml appendFormat:@"        <GUIConfig name=\"TabBar\" closeButton=\"%@\" "
     @"doubleClick2Close=\"%@\" reduce=\"yes\" dragAndDrop=\"yes\" "
     @"drawTopBar=\"yes\" drawInactiveTab=\"yes\" "
     @"pinButton=\"yes\" multiLine=\"%@\" tabCompactLabelLen=\"%ld\" />\n",
     _yn(tabClose), _yn(dblClickClose), _yn(tabBarWrap), (long)tabMaxW];

    // TabSetting (global)
    [xml appendFormat:@"        <GUIConfig name=\"TabSetting\" replaceBySpace=\"%@\" size=\"%ld\" />\n",
     _yn(!useTabs), (long)tabWidth];

    // Per-language tab overrides
    NSDictionary *tabOverrides = [ud dictionaryForKey:kPrefTabOverrides];
    if (tabOverrides.count > 0) {
        [xml appendString:@"        <GUIConfig name=\"TabCustom\">\n"];
        for (NSString *lang in [tabOverrides.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSDictionary *ov = tabOverrides[lang];
            [xml appendFormat:@"            <Language name=\"%@\" tabSize=\"%ld\" useTabs=\"%@\" />\n",
             lang, (long)[ov[@"tabSize"] integerValue], _yn([ov[@"useTabs"] boolValue])];
        }
        [xml appendString:@"        </GUIConfig>\n"];
    }

    // MaintainIndent: 0=None, 1=Advanced, 2=Basic (matches Windows NPP)
    [xml appendFormat:@"        <GUIConfig name=\"MaintainIndent\">%ld</GUIConfig>\n",
     (long)autoIndent];

    // BackspaceUnindent
    [xml appendFormat:@"        <GUIConfig name=\"BackspaceUnindent\">%@</GUIConfig>\n",
     _yn([ud boolForKey:kPrefBackspaceUnindent])];

    // RememberLastSession
    [xml appendString:@"        <GUIConfig name=\"RememberLastSession\">yes</GUIConfig>\n"];

    // KeepSessionAbsentFileEntries
    [xml appendFormat:@"        <GUIConfig name=\"KeepSessionAbsentFileEntries\">%@</GUIConfig>\n",
     _yn(keepAbsent)];

    // SaveAllConfirm
    [xml appendFormat:@"        <GUIConfig name=\"SaveAllConfirm\">%@</GUIConfig>\n",
     _yn(saveAllConf)];

    // NewDocDefaultSettings
    [xml appendFormat:@"        <GUIConfig name=\"NewDocDefaultSettings\" format=\"%ld\" "
     @"encoding=\"%ld\" openAnsiAsUTF8=\"yes\" />\n",
     (long)eolType, (long)encoding];

    // Backup
    [xml appendFormat:@"        <GUIConfig name=\"Backup\" action=\"%@\" "
     @"isSnapshotMode=\"%@\" snapshotBackupTiming=\"%ld\" />\n",
     autoBackup ? @"2" : @"0", _yn(autoBackup), (long)(backupInterval * 1000)];

    // Caret
    [xml appendFormat:@"        <GUIConfig name=\"Caret\" width=\"%ld\" blinkRate=\"%ld\" />\n",
     (long)caretW, (long)caretBlink];

    // titleBar
    [xml appendFormat:@"        <GUIConfig name=\"titleBar\" short=\"%@\" />\n",
     _yn(!fullPathTitle)];

    // insertDateTime
    [xml appendFormat:@"        <GUIConfig name=\"insertDateTime\" reverseDefaultOrder=\"%@\" />\n",
     _yn(dtReverse)];

    // auto-completion
    [xml appendFormat:@"        <GUIConfig name=\"auto-completion\" autoCAction=\"%@\" "
     @"triggerFromNbChar=\"%ld\" funcParams=\"%@\" />\n",
     autoComplete ? @"3" : @"0", (long)acMinChars, _yn(funcParams)];

    // auto-insert
    [xml appendFormat:@"        <GUIConfig name=\"auto-insert\" parentheses=\"%@\" "
     @"brackets=\"%@\" curlyBrackets=\"%@\" quotes=\"%@\" doubleQuotes=\"%@\" />\n",
     _yn(autoClose), _yn(autoClose), _yn(autoClose), _yn(autoClose), _yn(autoClose)];

    // SmartHighLight
    [xml appendFormat:@"        <GUIConfig name=\"SmartHighLight\" matchCase=\"%@\" "
     @"wholeWordOnly=\"%@\">%@</GUIConfig>\n",
     _yn(smartCase), _yn(smartWord), _yn(smartHL)];

    // Searching
    [xml appendFormat:@"        <GUIConfig name=\"Searching\" monospacedFontFindDlg=\"%@\" "
     @"fillFindFieldWithSelected=\"%@\" confirmReplaceInAllOpenDocs=\"%@\" "
     @"replaceStopsWithoutFindingNext=\"%@\" inSelectionAutocheckThreshold=\"%ld\" />\n",
     _yn(monoFontFind), _yn(fillFind), _yn(confirmRepl), _yn(replStop), (long)inSelThr];

    // DarkMode
    [xml appendFormat:@"        <GUIConfig name=\"DarkMode\" enable=\"%@\" darkModeAuto=\"%@\" />\n",
     dmEnable, (darkMode == 0) ? @"yes" : @"no"];

    // MISC
    BOOL funcListXML = [ud boolForKey:kPrefFuncListUseXML];
    BOOL fileAutoDetect   = [ud boolForKey:kPrefFileStatusAutoDetection];
    BOOL fileUpdateSilent = [ud boolForKey:kPrefFileStatusUpdateSilently];
    [xml appendFormat:@"        <GUIConfig name=\"MISC\" muteSounds=\"%@\" "
     @"disableTextDragDrop=\"%@\" spellCheck=\"%@\" "
     @"panelKeepState=\"%@\" funcListUseXML=\"%@\" "
     @"fileStatusAutoDetection=\"%@\" fileStatusUpdateSilently=\"%@\" />\n",
     _yn(muteSounds), _yn(disableDrag), _yn(spellCheck), _yn(panelKeep), _yn(funcListXML),
     _yn(fileAutoDetect), _yn(fileUpdateSilent)];

    // ScintillaPrimaryView
    double lineMult = [ud doubleForKey:kPrefLineHeightMultiplier];
    if (lineMult <= 0) lineMult = 1.0;  // guard against stale/zero values
    [xml appendFormat:@"        <GUIConfig name=\"ScintillaPrimaryView\" "
     @"lineNumberMargin=\"%@\" lineNumberDynamicWidth=\"%@\" "
     @"bookMarkMargin=\"%@\" folderMarkStyle=\"%@\" "
     @"virtualSpace=\"%@\" scrollBeyondLastLine=\"%@\" "
     @"rightClickKeepsSelection=\"%@\" "
     @"lineCopyCutWithoutSelection=\"%@\" "
     @"currentLineIndicator=\"%@\" "
     @"whiteSpaceShow=\"%@\" eolShow=\"%@\" eolMode=\"%ld\" "
     @"zoom=\"%ld\" smoothFont=\"%ld\" "
     @"paddingLeft=\"%ld\" paddingRight=\"%ld\" "
     @"edgeMultiColumnPos=\"%@\" isEdgeBgMode=\"%@\" "
     @"lineHeightMultiplier=\"%g\" />\n",
     _sh(showLineNum), _yn(dynLineNum),
     _sh(showBookmark), foldStr,
     _yn(virtualSpace), _yn(scrollBeyond),
     _yn(rightClickSel),
     _yn(copyLineNoSel),
     highlightLine ? @"1" : @"0",
     showWS ? @"show" : @"hide", showEOL ? @"show" : @"hide", (long)eolType,
     (long)zoom, (long)fontQual,
     (long)padL, (long)padR,
     edgeCol > 0 ? [NSString stringWithFormat:@"%ld", (long)edgeCol] : @"",
     (edgeMode == 2) ? @"yes" : @"no",
     lineMult];

    // globalOverride — issue #149, matches Windows Parameters.cpp schema
    [xml appendFormat:@"        <GUIConfig name=\"globalOverride\" "
     @"fg=\"%@\" bg=\"%@\" font=\"%@\" fontSize=\"%@\" "
     @"bold=\"%@\" italic=\"%@\" underline=\"%@\" />\n",
     _yn([ud boolForKey:kPrefGlobalOverrideEnableFg]),
     _yn([ud boolForKey:kPrefGlobalOverrideEnableBg]),
     _yn([ud boolForKey:kPrefGlobalOverrideEnableFont]),
     _yn([ud boolForKey:kPrefGlobalOverrideEnableFontSize]),
     _yn([ud boolForKey:kPrefGlobalOverrideEnableBold]),
     _yn([ud boolForKey:kPrefGlobalOverrideEnableItalic]),
     _yn([ud boolForKey:kPrefGlobalOverrideEnableUnderline])];

    [xml appendString:@"    </GUIConfigs>\n"];
    [xml appendString:@"</NotepadPlus>\n"];

    [xml writeToFile:_configXmlPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

/// Read ~/Library/Application Support/Nextpad++/config.xml and apply settings to NSUserDefaults.
void readConfigXML(void) {
    NSString *path = _configXmlPath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;

    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:nil];
    if (!doc) return;

    NSArray<NSXMLElement *> *configs = [doc nodesForXPath:@"//GUIConfigs/GUIConfig" error:nil];
    if (!configs.count) return;

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    for (NSXMLElement *el in configs) {
        NSString *name = [[el attributeForName:@"name"] stringValue];
        NSString *text = [el stringValue];
        if (!name.length) continue;

        if ([name isEqualToString:@"StatusBar"]) {
            [ud setBool:_shBool(text) forKey:kPrefShowStatusBar];
        }
        else if ([name isEqualToString:@"TabBar"]) {
            NSString *v;
            if ((v = [el attributeForName:@"closeButton"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefTabCloseButton];
            if ((v = [el attributeForName:@"doubleClick2Close"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefDoubleClickTabClose];
            if ((v = [el attributeForName:@"multiLine"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefTabBarWrap];
            if ((v = [el attributeForName:@"tabCompactLabelLen"].stringValue))
                [ud setInteger:v.integerValue forKey:kPrefTabMaxLabelWidth];
        }
        else if ([name isEqualToString:@"TabSetting"]) {
            NSString *v;
            if ((v = [el attributeForName:@"replaceBySpace"].stringValue))
                [ud setBool:!_ynBool(v) forKey:kPrefUseTabs]; // inverted
            if ((v = [el attributeForName:@"size"].stringValue))
                [ud setInteger:v.integerValue forKey:kPrefTabWidth];
        }
        else if ([name isEqualToString:@"TabCustom"]) {
            NSMutableDictionary *overrides = [NSMutableDictionary dictionary];
            for (NSXMLElement *langEl in [el elementsForName:@"Language"]) {
                NSString *langName = [langEl attributeForName:@"name"].stringValue;
                if (!langName.length) continue;
                NSInteger tabSize = [langEl attributeForName:@"tabSize"].stringValue.integerValue;
                BOOL lUseTabs = _ynBool([langEl attributeForName:@"useTabs"].stringValue);
                if (tabSize < 1) tabSize = 4;
                overrides[langName] = @{@"tabSize": @(tabSize), @"useTabs": @(lUseTabs)};
            }
            if (overrides.count > 0)
                [ud setObject:overrides forKey:kPrefTabOverrides];
        }
        else if ([name isEqualToString:@"MaintainIndent"]) {
            // Backward compat: "yes"→1(Advanced), "no"→0(None), integer 0/1/2 direct
            if ([text isEqualToString:@"yes"]) [ud setInteger:1 forKey:kPrefAutoIndent];
            else if ([text isEqualToString:@"no"]) [ud setInteger:0 forKey:kPrefAutoIndent];
            else [ud setInteger:text.integerValue forKey:kPrefAutoIndent];
        }
        else if ([name isEqualToString:@"BackspaceUnindent"]) {
            [ud setBool:[text isEqualToString:@"yes"] forKey:kPrefBackspaceUnindent];
        }
        else if ([name isEqualToString:@"KeepSessionAbsentFileEntries"]) {
            [ud setBool:_ynBool(text) forKey:kPrefKeepAbsentSession];
        }
        else if ([name isEqualToString:@"SaveAllConfirm"]) {
            [ud setBool:_ynBool(text) forKey:kPrefSaveAllConfirm];
        }
        else if ([name isEqualToString:@"NewDocDefaultSettings"]) {
            NSString *v;
            if ((v = [el attributeForName:@"format"].stringValue))
                [ud setInteger:v.integerValue forKey:kPrefEOLType];
            if ((v = [el attributeForName:@"encoding"].stringValue))
                [ud setInteger:v.integerValue forKey:kPrefEncoding];
        }
        else if ([name isEqualToString:@"Backup"]) {
            NSString *v;
            if ((v = [el attributeForName:@"action"].stringValue))
                [ud setBool:(v.integerValue != 0) forKey:kPrefAutoBackup];
            if ((v = [el attributeForName:@"snapshotBackupTiming"].stringValue))
                [ud setInteger:MAX(1, v.integerValue / 1000) forKey:kPrefBackupInterval];
        }
        else if ([name isEqualToString:@"Caret"]) {
            NSString *v;
            if ((v = [el attributeForName:@"width"].stringValue))
                [ud setInteger:v.integerValue forKey:kPrefCaretWidth];
            if ((v = [el attributeForName:@"blinkRate"].stringValue))
                [ud setInteger:v.integerValue forKey:kPrefCaretBlinkRate];
        }
        else if ([name isEqualToString:@"titleBar"]) {
            NSString *v;
            if ((v = [el attributeForName:@"short"].stringValue))
                [ud setBool:!_ynBool(v) forKey:kPrefShowFullPathInTitle]; // inverted
        }
        else if ([name isEqualToString:@"insertDateTime"]) {
            NSString *v;
            if ((v = [el attributeForName:@"reverseDefaultOrder"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefDateTimeReverse];
        }
        else if ([name isEqualToString:@"auto-completion"]) {
            NSString *v;
            if ((v = [el attributeForName:@"autoCAction"].stringValue))
                [ud setBool:(v.integerValue != 0) forKey:kPrefAutoCompleteEnable];
            if ((v = [el attributeForName:@"triggerFromNbChar"].stringValue))
                [ud setInteger:v.integerValue forKey:kPrefAutoCompleteMinChars];
            if ((v = [el attributeForName:@"funcParams"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefFuncParamsHint];
        }
        else if ([name isEqualToString:@"auto-insert"]) {
            NSString *v;
            // macOS uses single toggle — take parentheses as representative
            if ((v = [el attributeForName:@"parentheses"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefAutoCloseBrackets];
        }
        else if ([name isEqualToString:@"SmartHighLight"]) {
            [ud setBool:_ynBool(text) forKey:kPrefSmartHighlight];
            NSString *v;
            if ((v = [el attributeForName:@"matchCase"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefSmartHiliteCase];
            if ((v = [el attributeForName:@"wholeWordOnly"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefSmartHiliteWord];
        }
        else if ([name isEqualToString:@"Searching"]) {
            NSString *v;
            if ((v = [el attributeForName:@"monospacedFontFindDlg"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefMonoFontFind];
            if ((v = [el attributeForName:@"fillFindFieldWithSelected"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefFillFindWithSelection];
            if ((v = [el attributeForName:@"confirmReplaceInAllOpenDocs"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefConfirmReplaceAll];
            if ((v = [el attributeForName:@"replaceStopsWithoutFindingNext"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefReplaceAndStop];
            if ((v = [el attributeForName:@"inSelectionAutocheckThreshold"].stringValue))
                [ud setInteger:v.integerValue forKey:kPrefInSelThreshold];
        }
        else if ([name isEqualToString:@"DarkMode"]) {
            NSString *enable = [el attributeForName:@"enable"].stringValue;
            NSString *autoMode = [el attributeForName:@"darkModeAuto"].stringValue;
            if (_ynBool(autoMode))
                [ud setInteger:0 forKey:kPrefDarkMode]; // Auto
            else if (_ynBool(enable))
                [ud setInteger:2 forKey:kPrefDarkMode]; // Dark
            else
                [ud setInteger:1 forKey:kPrefDarkMode]; // Light
        }
        else if ([name isEqualToString:@"MISC"]) {
            NSString *v;
            if ((v = [el attributeForName:@"muteSounds"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefMuteSounds];
            if ((v = [el attributeForName:@"disableTextDragDrop"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefDisableTextDragDrop];
            if ((v = [el attributeForName:@"spellCheck"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefSpellCheck];
            if ((v = [el attributeForName:@"panelKeepState"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefPanelKeepState];
            if ((v = [el attributeForName:@"funcListUseXML"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefFuncListUseXML];
            if ((v = [el attributeForName:@"fileStatusAutoDetection"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefFileStatusAutoDetection];
            if ((v = [el attributeForName:@"fileStatusUpdateSilently"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefFileStatusUpdateSilently];
        }
        else if ([name isEqualToString:@"ScintillaPrimaryView"]) {
            NSString *v;
            if ((v = [el attributeForName:@"lineNumberMargin"].stringValue))
                [ud setBool:_shBool(v) forKey:kPrefShowLineNumbers];
            if ((v = [el attributeForName:@"lineNumberDynamicWidth"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefLineNumDynWidth];
            if ((v = [el attributeForName:@"bookMarkMargin"].stringValue))
                [ud setBool:_shBool(v) forKey:kPrefShowBookmarkMargin];
            if ((v = [el attributeForName:@"folderMarkStyle"].stringValue)) {
                NSDictionary *foldMap = @{@"box":@0, @"circle":@1, @"arrow":@2, @"simple":@3, @"none":@4};
                NSNumber *n = foldMap[v.lowercaseString];
                if (n) [ud setInteger:n.integerValue forKey:kPrefFoldStyle];
            }
            if ((v = [el attributeForName:@"virtualSpace"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefVirtualSpace];
            if ((v = [el attributeForName:@"scrollBeyondLastLine"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefScrollBeyondLastLine];
            if ((v = [el attributeForName:@"rightClickKeepsSelection"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefRightClickKeepsSel];
            if ((v = [el attributeForName:@"lineCopyCutWithoutSelection"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefCopyLineNoSelection];
            if ((v = [el attributeForName:@"currentLineIndicator"].stringValue))
                [ud setBool:(v.integerValue != 0) forKey:kPrefHighlightCurrentLine];
            if ((v = [el attributeForName:@"whiteSpaceShow"].stringValue))
                [ud setBool:_shBool(v) forKey:kPrefShowWhitespace];
            if ((v = [el attributeForName:@"eolShow"].stringValue))
                [ud setBool:_shBool(v) forKey:kPrefShowEOL];
            if ((v = [el attributeForName:@"eolMode"].stringValue))
                [ud setInteger:v.integerValue forKey:kPrefEOLType];
            if ((v = [el attributeForName:@"zoom"].stringValue))
                [ud setInteger:v.integerValue forKey:kPrefZoomLevel];
            if ((v = [el attributeForName:@"smoothFont"].stringValue))
                [ud setInteger:v.integerValue forKey:kPrefFontQuality];
            if ((v = [el attributeForName:@"paddingLeft"].stringValue))
                [ud setInteger:v.integerValue forKey:kPrefPaddingLeft];
            if ((v = [el attributeForName:@"paddingRight"].stringValue))
                [ud setInteger:v.integerValue forKey:kPrefPaddingRight];
            if ((v = [el attributeForName:@"edgeMultiColumnPos"].stringValue))
                [ud setInteger:v.integerValue forKey:kPrefEdgeColumn];
            if ((v = [el attributeForName:@"isEdgeBgMode"].stringValue))
                [ud setInteger:_ynBool(v) ? 2 : ([ud integerForKey:kPrefEdgeColumn] > 0 ? 1 : 0)
                        forKey:kPrefEdgeMode];
            if ((v = [el attributeForName:@"lineHeightMultiplier"].stringValue)) {
                double m = v.doubleValue;
                if (m > 0) [ud setDouble:m forKey:kPrefLineHeightMultiplier];
            }
        }
        else if ([name isEqualToString:@"globalOverride"]) {
            // issue #149 — Force <attr> for all styles. Matches Windows
            // Parameters.cpp:6156 attribute names exactly.
            NSString *v;
            if ((v = [el attributeForName:@"fg"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefGlobalOverrideEnableFg];
            if ((v = [el attributeForName:@"bg"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefGlobalOverrideEnableBg];
            if ((v = [el attributeForName:@"font"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefGlobalOverrideEnableFont];
            if ((v = [el attributeForName:@"fontSize"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefGlobalOverrideEnableFontSize];
            if ((v = [el attributeForName:@"bold"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefGlobalOverrideEnableBold];
            if ((v = [el attributeForName:@"italic"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefGlobalOverrideEnableItalic];
            if ((v = [el attributeForName:@"underline"].stringValue))
                [ud setBool:_ynBool(v) forKey:kPrefGlobalOverrideEnableUnderline];
        }
    }
    NSLog(@"[Config] Loaded preferences from %@", path);
}

static void ensureNppDirs(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:nppBackupDir()
  withIntermediateDirectories:YES attributes:nil error:nil];

    // Copy default shortcuts.xml from app bundle if user copy doesn't exist
    NSString *shortcutsPath = nppShortcutsPath();
    if (![fm fileExistsAtPath:shortcutsPath]) {
        NSString *bundleCopy = [[NSBundle mainBundle] pathForResource:@"shortcuts" ofType:@"xml"];
        if (bundleCopy) {
            [fm copyItemAtPath:bundleCopy toPath:shortcutsPath error:nil];
            NSLog(@"[Shortcuts] Copied default shortcuts.xml from bundle");
        }
    }

    // Copy tabContextMenu_example.xml to ~/Library/Application Support/Nextpad++/ as a template for user customization.
    // User renames it to tabContextMenu.xml to activate custom tab context menu.
    NSString *tabCtxExamplePath = [nppConfigDir() stringByAppendingPathComponent:@"tabContextMenu_example.xml"];
    if (![fm fileExistsAtPath:tabCtxExamplePath]) {
        NSString *bundleCopy = [[NSBundle mainBundle] pathForResource:@"tabContextMenu" ofType:@"xml"];
        if (bundleCopy) {
            [fm copyItemAtPath:bundleCopy toPath:tabCtxExamplePath error:nil];
        }
    }

    // Copy contextMenu.xml from bundle if user copy doesn't exist.
    // User edits ~/Library/Application Support/Nextpad++/contextMenu.xml to customize the editor right-click menu.
    NSString *ctxMenuPath = [nppConfigDir() stringByAppendingPathComponent:@"contextMenu.xml"];
    if (![fm fileExistsAtPath:ctxMenuPath]) {
        NSString *bundleCopy = [[NSBundle mainBundle] pathForResource:@"contextMenu" ofType:@"xml"];
        if (bundleCopy) {
            [fm copyItemAtPath:bundleCopy toPath:ctxMenuPath error:nil];
            NSLog(@"[ContextMenu] Copied default contextMenu.xml from bundle");
        }
    }

    // Copy langs.model.xml from bundle as langs.xml if user copy doesn't exist.
    // User edits ~/Library/Application Support/Nextpad++/langs.xml to customize extensions, keywords, comment delimiters.
    NSString *langsPath = [nppConfigDir() stringByAppendingPathComponent:@"langs.xml"];
    if (![fm fileExistsAtPath:langsPath]) {
        NSString *bundleCopy = [[NSBundle mainBundle] pathForResource:@"langs.model" ofType:@"xml"];
        if (bundleCopy) {
            [fm copyItemAtPath:bundleCopy toPath:langsPath error:nil];
            NSLog(@"[Langs] Copied langs.model.xml as langs.xml to %@", nppConfigDir());
        }
    }

    // Copy stylers.model.xml from bundle as stylers.xml if user copy doesn't exist.
    // User edits ~/Library/Application Support/Nextpad++/stylers.xml to customize the Default theme styles.
    NSString *stylersPath = [nppConfigDir() stringByAppendingPathComponent:@"stylers.xml"];
    if (![fm fileExistsAtPath:stylersPath]) {
        NSString *bundleCopy = [[NSBundle mainBundle] pathForResource:@"stylers.model" ofType:@"xml"];
        if (bundleCopy) {
            [fm copyItemAtPath:bundleCopy toPath:stylersPath error:nil];
            NSLog(@"[Stylers] Copied stylers.model.xml as stylers.xml to %@", nppConfigDir());
        }
    }

    // Create ~/Library/Application Support/Nextpad++/themes/ for user-installed themes (empty on first run).
    NSString *userThemesDir = [nppConfigDir() stringByAppendingPathComponent:@"themes"];
    [fm createDirectoryAtPath:userThemesDir
  withIntermediateDirectories:YES attributes:nil error:nil];

    // Create ~/Library/Application Support/Nextpad++/functionList/ for user-defined function list parsers.
    NSString *userFuncListDir = [nppConfigDir() stringByAppendingPathComponent:@"functionList"];
    [fm createDirectoryAtPath:userFuncListDir
  withIntermediateDirectories:YES attributes:nil error:nil];

    // Copy toolbarButtonsConf.xml from bundle as _example — only if neither
    // the user's active config nor the example already exists.
    NSString *tbConfPath = [nppConfigDir() stringByAppendingPathComponent:@"toolbarButtonsConf.xml"];
    NSString *tbExPath   = [nppConfigDir() stringByAppendingPathComponent:@"toolbarButtonsConf_example.xml"];
    if (![fm fileExistsAtPath:tbConfPath] && ![fm fileExistsAtPath:tbExPath]) {
        NSString *bundleCopy = [[NSBundle mainBundle] pathForResource:@"toolbarButtonsConf" ofType:@"xml"];
        if (bundleCopy) [fm copyItemAtPath:bundleCopy toPath:tbExPath error:nil];
    }

    // Create ~/Library/Application Support/Nextpad++/toolbarIcons/ for user custom toolbar icon sets.
    NSString *toolbarIconsDir = [nppConfigDir() stringByAppendingPathComponent:@"toolbarIcons"];
    [fm createDirectoryAtPath:toolbarIconsDir
  withIntermediateDirectories:YES attributes:nil error:nil];
}

/// Regenerate toolbarButtonsConf_example.xml with current plugin entries.
/// Called after plugins are loaded so all plugin actions are included.
void regenerateToolbarExample(void) {
    // Skip if user already has an active toolbar config
    NSString *tbConfPath = [nppConfigDir() stringByAppendingPathComponent:@"toolbarButtonsConf.xml"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:tbConfPath]) return;

    // Read the bundled template
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"toolbarButtonsConf" ofType:@"xml"];
    if (!bundlePath) return;
    NSString *content = [NSString stringWithContentsOfFile:bundlePath encoding:NSUTF8StringEncoding error:nil];
    if (!content) return;

    // Build plugin section
    NSArray<NSDictionary *> *pluginActions = [[NppPluginManager shared] allPluginActions];
    if (pluginActions.count == 0) {
        // No plugins — just copy the template as-is
        NSString *exPath = [nppConfigDir() stringByAppendingPathComponent:@"toolbarButtonsConf_example.xml"];
        [content writeToFile:exPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }

    NSMutableString *pluginXML = [NSMutableString string];
    [pluginXML appendString:@"\n"];
    NSString *currentPlugin = @"";
    for (NSDictionary *action in pluginActions) {
        NSString *pluginName = action[@"pluginName"];
        if (![pluginName isEqualToString:currentPlugin]) {
            [pluginXML appendFormat:@"      <!-- ── %@ ── -->\n", pluginName];
            currentPlugin = pluginName;
        }
        NSString *hide = [action[@"hasToolbarIcon"] boolValue] ? @"no" : @"yes";
        int cmdID = [action[@"cmdID"] intValue];
        NSString *actionName = action[@"actionName"];
        // Escape XML special chars in action name
        actionName = [actionName stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
        actionName = [actionName stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
        actionName = [actionName stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
        actionName = [actionName stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
        [pluginXML appendFormat:@"      <Button hide=\"%@\" cmdID=\"%d\" plugin=\"%@\" name=\"%@\" trigger=\"click\" />\n",
            hide, cmdID, pluginName, actionName];
    }

    // Replace the empty <Plugin> section with populated one
    NSString *emptyPlugin = @"    <Plugin hideAll=\"no\">\n"
        @"      <!-- Plugin toolbar buttons are added dynamically at startup.\n"
        @"           Plugins that register toolbar icons appear here with hide=\"no\".\n"
        @"           To hide a plugin button, add:\n"
        @"           <Button hide=\"yes\" name=\"PluginName - Action\" />\n"
        @"      -->\n"
        @"    </Plugin>";
    NSMutableString *populatedPlugin = [NSMutableString string];
    [populatedPlugin appendString:@"    <Plugin hideAll=\"no\">"];
    [populatedPlugin appendString:pluginXML];
    [populatedPlugin appendString:@"    </Plugin>"];

    NSString *result = [content stringByReplacingOccurrencesOfString:emptyPlugin withString:populatedPlugin];

    NSString *exPath = [nppConfigDir() stringByAppendingPathComponent:@"toolbarButtonsConf_example.xml"];
    [result writeToFile:exPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// Toolbar item identifiers
static NSToolbarItemIdentifier const kTBNew         = @"TB_New";
static NSToolbarItemIdentifier const kTBOpen        = @"TB_Open";
static NSToolbarItemIdentifier const kTBSave        = @"TB_Save";
static NSToolbarItemIdentifier const kTBSaveAll     = @"TB_SaveAll";
static NSToolbarItemIdentifier const kTBClose       = @"TB_Close";
static NSToolbarItemIdentifier const kTBCloseAll    = @"TB_CloseAll";
static NSToolbarItemIdentifier const kTBPrint       = @"TB_Print";
static NSToolbarItemIdentifier const kTBCut         = @"TB_Cut";
static NSToolbarItemIdentifier const kTBCopy        = @"TB_Copy";
static NSToolbarItemIdentifier const kTBPaste       = @"TB_Paste";
static NSToolbarItemIdentifier const kTBUndo        = @"TB_Undo";
static NSToolbarItemIdentifier const kTBRedo        = @"TB_Redo";
static NSToolbarItemIdentifier const kTBFind        = @"TB_Find";
static NSToolbarItemIdentifier const kTBFindRep     = @"TB_FindRep";
static NSToolbarItemIdentifier const kTBZoomIn      = @"TB_ZoomIn";
static NSToolbarItemIdentifier const kTBZoomOut     = @"TB_ZoomOut";
static NSToolbarItemIdentifier const kTBSyncV       = @"TB_SyncV";
static NSToolbarItemIdentifier const kTBSyncH       = @"TB_SyncH";
static NSToolbarItemIdentifier const kTBWrap        = @"TB_Wrap";
static NSToolbarItemIdentifier const kTBAllChars    = @"TB_AllChars";
static NSToolbarItemIdentifier const kTBIndentGuide = @"TB_IndentGuide";
static NSToolbarItemIdentifier const kTBUDL         = @"TB_UDL";
static NSToolbarItemIdentifier const kTBDocMap      = @"TB_DocMap";
static NSToolbarItemIdentifier const kTBDocList     = @"TB_DocList";
static NSToolbarItemIdentifier const kTBFuncList    = @"TB_FuncList";
static NSToolbarItemIdentifier const kTBFileBrowser = @"TB_FileBrowser";
static NSToolbarItemIdentifier const kTBCharPanel   = @"TB_CharPanel";   // Tahoe-only (SF Symbol)
static NSToolbarItemIdentifier const kTBClipboard   = @"TB_Clipboard";   // Tahoe-only (SF Symbol)
static NSToolbarItemIdentifier const kTBProject     = @"TB_Project";     // Tahoe-only (SF Symbol)
static NSToolbarItemIdentifier const kTBMonitor     = @"TB_Monitor";
static NSToolbarItemIdentifier const kTBStartRecord = @"TB_StartRecord";
static NSToolbarItemIdentifier const kTBStopRecord  = @"TB_StopRecord";
static NSToolbarItemIdentifier const kTBPlayRecord  = @"TB_PlayRecord";
static NSToolbarItemIdentifier const kTBPlayRecordM = @"TB_PlayRecordM";
static NSToolbarItemIdentifier const kTBSaveRecord  = @"TB_SaveRecord";
static NSToolbarItemIdentifier const kTBSep1 = @"TB_Sep1";
static NSToolbarItemIdentifier const kTBSep2 = @"TB_Sep2";
static NSToolbarItemIdentifier const kTBSep3 = @"TB_Sep3";
static NSToolbarItemIdentifier const kTBSep4 = @"TB_Sep4";
static NSToolbarItemIdentifier const kTBSep5 = @"TB_Sep5";
static NSToolbarItemIdentifier const kTBSep6 = @"TB_Sep6";
static NSToolbarItemIdentifier const kTBSep7 = @"TB_Sep7";
static NSToolbarItemIdentifier const kTBSep8 = @"TB_Sep8";
static NSToolbarItemIdentifier const kTBSep9 = @"TB_Sep9";
static NSToolbarItemIdentifier const kTBTabControls = @"TB_TabControls"; // +  ▾  × right-aligned

// NSUserDefaults key: array of English title-keys of the built-in side
// panels that were open at last save (issue #132 — restore on launch).
static NSString *const kOpenSidePanelsKey = @"OpenSidePanels";

// Built-in side panels that participate in open-state persistence, mapped
// from PanelFrame title-key → the action selector that toggles them open.
// The Git ("Source Control") panel is deliberately excluded — restoring it
// on launch would spawn git. Search Results is a bottom panel (not in the
// side-panel host) and plugin panels carry unknown title-keys, so both are
// naturally excluded by not appearing here.
static NSDictionary<NSString *, NSString *> *_restorableSidePanels(void) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"Document List":               @"showDocumentList:",
            @"Clipboard History":           @"showClipboardHistory:",
            @"Document Map":                @"showDocumentMap:",
            @"Function List":               @"showFunctionList:",
            @"Folder as Workspace":         @"showFolderTreePanel:",
            @"Project Panel":               @"showProjectPanel1:",
            @"ASCII Codes Insertion Panel": @"characterPanel:",
        };
    });
    return map;
}
// Grouped toolbar items — each group becomes a single NSToolbarItem with tight icon packing
static NSToolbarItemIdentifier const kTBGroup1  = @"TB_G1";  // file ops
static NSToolbarItemIdentifier const kTBGroup2  = @"TB_G2";  // clipboard
static NSToolbarItemIdentifier const kTBGroup3  = @"TB_G3";  // undo/redo
static NSToolbarItemIdentifier const kTBGroup4  = @"TB_G4";  // find
static NSToolbarItemIdentifier const kTBGroup5  = @"TB_G5";  // zoom
static NSToolbarItemIdentifier const kTBGroup6  = @"TB_G6";  // scroll sync
static NSToolbarItemIdentifier const kTBGroup7  = @"TB_G7";  // view toggles (wrap, allchars, indent)
static NSToolbarItemIdentifier const kTBGroup8  = @"TB_G8";  // panels
static NSToolbarItemIdentifier const kTBGroup9  = @"TB_G9";  // monitoring
static NSToolbarItemIdentifier const kTBGroup10 = @"TB_G10"; // macro

// Default-mode plugin grouping: plugin toolbar buttons are packed into one
// toolbar item per plugin (grouped by plugin directory). The item identifier is
// this prefix followed by the plugin's group key (its pluginDir). See
// -makePluginGroupToolbarItemForKey: and -_rebuildPluginToolbarGroups.
static NSString *const kTBPluginGroupPrefix = @"TB_PluginGrp:";

// DEFAULT (Classic) mode: plugin items are coalesced into "segments" — a maximal run
// of consecutive standalone (single-icon) plugins becomes ONE item, while a multi-icon
// plugin (e.g. ComparePlus) is its own item and acts as a boundary. macOS 26 inserts a
// wide gap between separate NSToolbarItems, so one-item-per-plugin spread the standalone
// icons out under Tahoe; packing each run into one item keeps them tight AND lets the
// toolbar hide plugins run-by-run on resize (instead of all at once). The identifier is
// this prefix + the segment's first plugin group key. See -makePluginSegmentItemStartingAt:
// and -_rebuildPluginToolbarGroups. (Tahoe + user-config modes are unaffected.)
static NSString *const kTBPluginSegPrefix = @"TB_PluginSeg:";

// Tahoe profile: one NSToolbarItemGroup per semantic cluster (File/Edit/…). The
// item identifier is this prefix + the group label. See -makeTahoeGroupToolbarItem:
// and tahoeToolbarGroups(). Built only when the effective profile is Tahoe.
static NSString *const kTBTahoeGroupPrefix = @"TB_TGroup:";

// Tahoe profile: the single "Plugins" capsule — a few plugin icons + a label ▾
// exposing the rest. Built/refreshed dynamically as plugins register their icons.
static NSString *const kTBTahoePluginsGroup = @"TB_TPlugins";

// ── Toolbar metric helpers ──────────────────────────────────────────────────
// Single source of truth for toolbar button + icon dimensions and gaps. All
// values derive from kPrefToolbarIconScale (50/75/90/100/125/150 %), with
// 100 % matching the canonical 28 pt button + 26 pt icon baseline. The
// scale is read once per process via dispatch_once — a pref change requires
// an app restart to take effect, so no live-rebuild plumbing is needed and
// values stay consistent across all builder methods within one session.
//
// Replaces the per-method `static const CGFloat kBtnSize = 28.0;` constants
// that used to be sprinkled across makePluginToolbarItem / makeUserConfig /
// makeGroupToolbarItem / makeViewTogglesGroup. Calling sites still feel
// like consts (CGFloat kBtnSize = nppBtnSize();) — only the value source
// has changed.
static CGFloat _scaledBtn         = 28.0;
static CGFloat _scaledIcon        = 26.0;
static CGFloat _scaledSpacing     =  2.0;
static CGFloat _scaledSepGap      = 10.0;
static CGFloat _scaledInnerGap    =  2.0;
static CGFloat _scaledDropW       = 29.0;
static CGFloat _scaledPinSize     = 10.0;  // tab-bar pin glyph
static CGFloat _scaledCornerR     =  3.0;

static void _ensureToolbarMetrics(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        double s = [[NSUserDefaults standardUserDefaults] doubleForKey:kPrefToolbarIconScale];
        // Defensive clamp — stale or hand-edited values fall back to 100 %.
        if (s < 0.50 - 1e-6 || s > 1.50 + 1e-6) s = 1.0;
        _scaledBtn      = round(28.0 * s);
        _scaledIcon     = round(26.0 * s);
        _scaledSpacing  = round( 2.0 * s);
        _scaledSepGap   = round(10.0 * s);
        _scaledInnerGap = round( 2.0 * s);
        _scaledDropW    = round(29.0 * s);
        _scaledPinSize  = round(10.0 * s);
        _scaledCornerR  = MAX(2.0, round(3.0 * s));  // visible curvature floor
    });
}

static CGFloat nppBtnSize(void)      { _ensureToolbarMetrics(); return _scaledBtn; }
static CGFloat nppIconSize(void)     { _ensureToolbarMetrics(); return _scaledIcon; }
static CGFloat nppSpacing(void)      { _ensureToolbarMetrics(); return _scaledSpacing; }
static CGFloat nppSepGap(void)       { _ensureToolbarMetrics(); return _scaledSepGap; }
static CGFloat nppInnerGap(void)     { _ensureToolbarMetrics(); return _scaledInnerGap; }
static CGFloat nppDropArrowW(void)   { _ensureToolbarMetrics(); return _scaledDropW; }
static CGFloat nppToolbarCornerR(void) { _ensureToolbarMetrics(); return _scaledCornerR; }

// Load a toolbar icon using NppThemeManager (auto-switches light/dark).
// Sets the image's logical size to nppIconSize() so AppKit samples crisply
// from the 96×96 Fluent source on Retina at the user-selected scale.
// ── Toolbar icon colorization ────────────────────────────────────────────────
// Mirrors the Windows "Toolbar" preferences. Our toolbar PNGs are blue line-art
// (the only saturated content is the ~203° blue accent; everything else is
// greyscale structure), so:
//   • Partial  — repaint just the saturated (blue) pixels with the chosen color,
//     leaving low-saturation greys/blacks untouched. Matches Windows "Partial".
//   • Complete — fill every opaque pixel with the chosen color (mono silhouette).
// Off → image returned unchanged.

// Resolves the chosen target color from kPrefToolbarColorChoice (+ accent/custom).
static NSColor *_nppToolbarTargetColor(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    switch ([ud integerForKey:kPrefToolbarColorChoice]) {
        case 0: return [NSColor colorWithSRGBRed:0xE8/255.0 green:0x11/255.0 blue:0x23/255.0 alpha:1]; // red
        case 1: return [NSColor colorWithSRGBRed:0x00/255.0 green:0x8B/255.0 blue:0x00/255.0 alpha:1]; // green
        case 2: return [NSColor colorWithSRGBRed:0x00/255.0 green:0x78/255.0 blue:0xD4/255.0 alpha:1]; // blue
        case 3: return [NSColor colorWithSRGBRed:0xB1/255.0 green:0x46/255.0 blue:0xC2/255.0 alpha:1]; // purple
        case 4: return [NSColor colorWithSRGBRed:0x00/255.0 green:0xB7/255.0 blue:0xC3/255.0 alpha:1]; // cyan
        case 5: return [NSColor colorWithSRGBRed:0x49/255.0 green:0x82/255.0 blue:0x05/255.0 alpha:1]; // olive
        case 6: return [NSColor colorWithSRGBRed:0xFF/255.0 green:0xB9/255.0 blue:0x00/255.0 alpha:1]; // yellow
        case 7:
            if (@available(macOS 10.14, *)) return [NSColor controlAccentColor];
            return [NSColor systemBlueColor];
        case 8: {
            NSData *d = [ud dataForKey:kPrefToolbarCustomColor];
            if (d) {
                NSColor *c = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class] fromData:d error:nil];
                if (c) return c;
            }
            return [NSColor systemBlueColor];
        }
    }
    return [NSColor systemBlueColor];
}

// Reference hue (degrees) of the icon set's blue accent, measured across all
// toolbar PNGs (light + dark). Partial colorization rotates every pixel's hue
// by (targetHue - this), so the blue lands exactly on the chosen color.
static const double kNppToolbarSourceHueDeg = 203.0;

// RGB<->HSV on 0..1 components. A real-HSV hue rotation (vs CIHueAdjust) keeps
// each pixel's saturation and value, so greys (S≈0) are untouched, anti-aliased
// gradients are preserved, and the recolored hue is exact and fully saturated.
static void _rgb2hsv(double r, double g, double b, double *h, double *s, double *v) {
    double mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b)), d = mx - mn;
    *v = mx;
    *s = (mx <= 0.0) ? 0.0 : d / mx;
    if (d <= 0.0) { *h = 0.0; return; }
    double hh;
    if      (mx == r) hh = fmod((g - b) / d, 6.0);
    else if (mx == g) hh = (b - r) / d + 2.0;
    else              hh = (r - g) / d + 4.0;
    hh *= 60.0; if (hh < 0.0) hh += 360.0;
    *h = hh;
}
static void _hsv2rgb(double h, double s, double v, double *r, double *g, double *b) {
    if (s <= 0.0) { *r = *g = *b = v; return; }
    h = fmod(h, 360.0); if (h < 0.0) h += 360.0;
    h /= 60.0;
    int i = (int)h; double f = h - i;
    double p = v * (1.0 - s), q = v * (1.0 - s * f), t = v * (1.0 - s * (1.0 - f));
    switch (i) {
        case 0: *r = v; *g = t; *b = p; break;
        case 1: *r = q; *g = v; *b = p; break;
        case 2: *r = p; *g = v; *b = t; break;
        case 3: *r = p; *g = q; *b = v; break;
        case 4: *r = t; *g = p; *b = v; break;
        default:*r = v; *g = p; *b = q; break;
    }
}

// Applies the current colorization to a freshly-loaded toolbar icon. Returns the
// input unchanged when colorization is off or on failure (fail-safe).
static NSImage *_nppColorizeToolbarImage(NSImage *img) {
    if (!img) return img;
    NSInteger mode = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefToolbarColorMode];
    if (mode == 0) return img;   // Off

    NSSize sz = img.size;
    if (sz.width < 1 || sz.height < 1) return img;
    NSColor *target = _nppToolbarTargetColor();

    if (mode == 2) {
        // Complete: solid mono fill over the icon's alpha mask.
        NSImage *out = [[NSImage alloc] initWithSize:sz];
        [out lockFocus];
        [img drawInRect:NSMakeRect(0, 0, sz.width, sz.height)
               fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
        [target set];
        NSRectFillUsingOperation(NSMakeRect(0, 0, sz.width, sz.height), NSCompositingOperationSourceAtop);
        [out unlockFocus];
        out.cacheMode = NSImageCacheNever;
        return out;
    }

    // Partial: rotate every pixel's hue by (targetHue - sourceBlueHue) in real
    // HSV space, keeping saturation + value. Greys (S≈0) are unchanged and
    // anti-aliased edges are preserved (no hard threshold / no flat fill). Works
    // directly on premultiplied pixels because hsv->rgb is linear in V, so hue
    // rotation commutes with the alpha scaling.
    CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cg) return img;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w == 0 || h == 0) return img;

    CGFloat th = 0, tsat = 0, tbri = 0, ta = 0;
    [[target colorUsingColorSpace:[NSColorSpace sRGBColorSpace]]
        getHue:&th saturation:&tsat brightness:&tbri alpha:&ta];
    double deltaDeg = th * 360.0 - kNppToolbarSourceHueDeg;

    // Dark mode's blue accent is only ~70% saturated (vs ~100% in light); a hue
    // rotation preserves that, so rotating it to red yields a washed pink. Lift
    // the saturation for the Red choice in dark mode only — every other color and
    // light mode already read correctly with the source saturation untouched, and
    // boosting them would over-saturate and flatten their gradients.
    double satFloor = ([NppThemeManager shared].isDark &&
                       [[NSUserDefaults standardUserDefaults] integerForKey:kPrefToolbarColorChoice] == 0)
                      ? 0.90 : 0.0;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    size_t bpr = w * 4;
    uint8_t *buf = (uint8_t *)calloc(h * bpr, 1);
    if (!buf) { CGColorSpaceRelease(cs); return img; }
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, bpr, cs, kCGImageAlphaPremultipliedLast);
    if (!ctx) { free(buf); CGColorSpaceRelease(cs); return img; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);

    for (size_t i = 0; i < h * bpr; i += 4) {
        if (buf[i + 3] == 0) continue;          // fully transparent
        double H, S, V;
        _rgb2hsv(buf[i] / 255.0, buf[i + 1] / 255.0, buf[i + 2] / 255.0, &H, &S, &V);
        if (S <= 0.0) continue;                 // grey/black/white — no chroma to rotate
        double ns = (S < satFloor) ? satFloor : S;
        double R, G, B;
        _hsv2rgb(H + deltaDeg, ns, V, &R, &G, &B);
        buf[i]     = (uint8_t)lround(R * 255.0);
        buf[i + 1] = (uint8_t)lround(G * 255.0);
        buf[i + 2] = (uint8_t)lround(B * 255.0);
    }

    CGImageRef outCG = CGBitmapContextCreateImage(ctx);
    NSImage *out = nil;
    if (outCG) {
        out = [[NSImage alloc] initWithCGImage:outCG size:sz];
        out.cacheMode = NSImageCacheNever;
        CGImageRelease(outCG);
    }
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(buf);
    return out ?: img;
}

static NSImage *nppToolbarIcon(NSString *fileName) {
    // "sf:<symbol>" → a system SF Symbol (template-rendered). Used by Tahoe-only
    // toolbar items that have no bundled PNG (e.g. the Character/Clipboard/Project
    // panels). Returned as a template so menu items / buttons tint it correctly.
    if ([fileName hasPrefix:@"sf:"]) {
        NSImage *s = [NSImage imageWithSystemSymbolName:[fileName substringFromIndex:3]
                                accessibilityDescription:nil];
        if (s) {
            [s setTemplate:YES];
            s.size = NSMakeSize(nppIconSize(), nppIconSize());
        }
        return s;
    }
    NSImage *img = [[NppThemeManager shared] toolbarIconNamed:fileName];
    if (img) {
        img.size = NSMakeSize(nppIconSize(), nppIconSize());
        img.cacheMode = NSImageCacheNever;
        img = _nppColorizeToolbarImage(img);
        if (img) img.size = NSMakeSize(nppIconSize(), nppIconSize());
    }
    return img;
}

/// Load a custom toolbar icon from ~/Library/Application Support/Nextpad++/toolbarIcons/{folderName}/{buttonId}.png
/// Returns nil if not found.
static NSImage *_customToolbarIcon(NSString *buttonId, NSDictionary *toolbarConfig) {
    // Parse icoFolderName from the config (already parsed, but we need to read it here)
    // For simplicity, check the standard location directly
    NSString *iconDir = [nppConfigDir() stringByAppendingPathComponent:@"toolbarIcons"];

    // Check for icon directly in toolbarIcons/ (flat layout)
    NSString *flatPath = [iconDir stringByAppendingPathComponent:
        [buttonId stringByAppendingString:@".png"]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:flatPath]) {
        NSImage *img = [[NSImage alloc] initWithContentsOfFile:flatPath];
        if (img) { img.size = NSMakeSize(nppIconSize(), nppIconSize()); return img; }
    }

    // Check in toolbarIcons/default/ subfolder
    NSString *defaultPath = [[iconDir stringByAppendingPathComponent:@"default"]
        stringByAppendingPathComponent:[buttonId stringByAppendingString:@".png"]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:defaultPath]) {
        NSImage *img = [[NSImage alloc] initWithContentsOfFile:defaultPath];
        if (img) { img.size = NSMakeSize(nppIconSize(), nppIconSize()); return img; }
    }

    return nil;
}

// ── Flat toolbar button (28×28 pt, rounded hover border) ────────────────────
@interface NppToolbarButton : NSButton {
    BOOL _hovering;
}
@end

@implementation NppToolbarButton

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setBordered:NO];
        [self setButtonType:NSButtonTypeMomentaryChange];
        [self setImageScaling:NSImageScaleProportionallyUpOrDown];
        NSTrackingArea *ta = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:(NSTrackingMouseEnteredAndExited |
                          NSTrackingActiveInActiveApp     |
                          NSTrackingInVisibleRect)
                   owner:self userInfo:nil];
        [self addTrackingArea:ta];
    }
    return self;
}

- (void)mouseEntered:(NSEvent *)event { _hovering = YES;  [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)event  { _hovering = NO;   [self setNeedsDisplay:YES]; }

- (void)drawRect:(NSRect)dirtyRect {
    BOOL pressed = self.isHighlighted;
    if (pressed || _hovering) {
        BOOL isDark = [NppThemeManager shared].isDark;
        NSColor *bg, *bdr;
        if (isDark) {
            // Flat solid grey — border matches fill so it reads as a clean block.
            bg = pressed
                ? [NSColor colorWithRed:0x21/255.0 green:0x21/255.0 blue:0x21/255.0 alpha:1.0]
                : [NSColor colorWithRed:0x2e/255.0 green:0x2e/255.0 blue:0x2e/255.0 alpha:1.0];
            bdr = bg;
        } else {
            bg = pressed
                ? [NSColor colorWithRed:0xCC/255.0 green:0xE8/255.0 blue:0xFF/255.0 alpha:1.0]
                : [NSColor colorWithRed:0xE5/255.0 green:0xF3/255.0 blue:0xFF/255.0 alpha:1.0];
            bdr = [NSColor colorWithRed:0xD0/255.0 green:0xEA/255.0 blue:0xFF/255.0 alpha:1.0];
        }
        NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:nppToolbarCornerR() yRadius:nppToolbarCornerR()];
        [bg setFill]; [fill fill];
        NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                                               xRadius:nppToolbarCornerR() yRadius:nppToolbarCornerR()];
        border.lineWidth = 1.0; [bdr setStroke]; [border stroke];
    }
    if (self.image) {
        [self.image drawInRect:NSInsetRect(self.bounds, 1, 1)
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver
                      fraction:1.0
                respectFlipped:YES
                         hints:nil];
    }
}

@end

// ── Toggle toolbar button: on/off with blue highlight or desaturation ────────
@interface NppToggleToolbarButton : NppToolbarButton
@property (nonatomic) BOOL toggledOn;
@property (nonatomic) BOOL useBlueHighlight; // YES = panel style (blue bg), NO = desaturate when off
@end

@implementation NppToggleToolbarButton

- (void)drawRect:(NSRect)dirtyRect {
    BOOL pressed = self.isHighlighted;
    BOOL isDark  = [NppThemeManager shared].isDark;

    // Active-toggle: persistent background (panel style)
    if (self.toggledOn && self.useBlueHighlight) {
        NSColor *bg, *bdr;
        if (isDark) {
            // #232323 for active-toggle — darker than the chrome / hover states
            // but not pure black so the chip reads as part of the same surface
            // family. (Hover: #2E2E2E, Pressed: #212121, Toggled-on: #232323.)
            bg  = [NSColor colorWithRed:0x23/255.0 green:0x23/255.0 blue:0x23/255.0 alpha:1.0];
            bdr = bg;
        } else {
            bg  = [NSColor colorWithRed:0xCC/255.0 green:0xE8/255.0 blue:0xFF/255.0 alpha:0.65];
            bdr = [NSColor colorWithRed:0x80/255.0 green:0xC0/255.0 blue:0xFF/255.0 alpha:0.80];
        }
        NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:nppToolbarCornerR() yRadius:nppToolbarCornerR()];
        [bg setFill]; [fill fill];
        NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                                               xRadius:nppToolbarCornerR() yRadius:nppToolbarCornerR()];
        border.lineWidth = 1.0; [bdr setStroke]; [border stroke];
    } else if (pressed || _hovering) {
        NSColor *bg, *bdr;
        if (isDark) {
            bg = pressed
                ? [NSColor colorWithRed:0x21/255.0 green:0x21/255.0 blue:0x21/255.0 alpha:1.0]
                : [NSColor colorWithRed:0x2e/255.0 green:0x2e/255.0 blue:0x2e/255.0 alpha:1.0];
            bdr = bg;
        } else {
            bg = pressed
                ? [NSColor colorWithRed:0xCC/255.0 green:0xE8/255.0 blue:0xFF/255.0 alpha:1.0]
                : [NSColor colorWithRed:0xE5/255.0 green:0xF3/255.0 blue:0xFF/255.0 alpha:1.0];
            bdr = [NSColor colorWithRed:0xD0/255.0 green:0xEA/255.0 blue:0xFF/255.0 alpha:1.0];
        }
        NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:nppToolbarCornerR() yRadius:nppToolbarCornerR()];
        [bg setFill]; [fill fill];
        NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                                               xRadius:nppToolbarCornerR() yRadius:nppToolbarCornerR()];
        border.lineWidth = 1.0; [bdr setStroke]; [border stroke];
    }

    // Desaturation style: OFF = greyed out (alpha 0.30), ON = normal
    CGFloat alpha = 1.0;
    if (!self.useBlueHighlight && !self.toggledOn) alpha = 0.30;
    if (!self.isEnabled) alpha = 0.25;

    if (self.image) {
        [self.image drawInRect:NSInsetRect(self.bounds, 1, 1)
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver
                      fraction:alpha
                respectFlipped:YES
                         hints:nil];
    }
}

@end

// ── Show-All-Characters + dropdown arrow: unified hover group ─────────────────
// Plain image button — no hover border of its own; parent group handles hover.
@interface _FlatImgButton : NSButton @end
@implementation _FlatImgButton
- (void)drawRect:(NSRect)dirtyRect {
    if (self.isHighlighted) {
        NSColor *bg = [NppThemeManager shared].isDark
            ? [NSColor colorWithRed:0x21/255.0 green:0x21/255.0 blue:0x21/255.0 alpha:1.0]
            : [NSColor colorWithRed:0xCC/255.0 green:0xE8/255.0 blue:0xFF/255.0 alpha:1.0];
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:nppToolbarCornerR() yRadius:nppToolbarCornerR()];
        [bg setFill]; [p fill];
    }
    if (self.image)
        [self.image drawInRect:NSInsetRect(self.bounds, 1, 1)
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver
                      fraction:1.0
                respectFlipped:YES
                         hints:nil];
}
@end

// Dropdown arrow button — draws ▾ precisely centered; no hover border.
@interface _DropArrowButton : NSButton @end
@implementation _DropArrowButton
- (void)drawRect:(NSRect)dirtyRect {
    if (self.isHighlighted) {
        NSColor *bg = [NppThemeManager shared].isDark
            ? [NSColor colorWithRed:0x21/255.0 green:0x21/255.0 blue:0x21/255.0 alpha:1.0]
            : [NSColor colorWithRed:0xCC/255.0 green:0xE8/255.0 blue:0xFF/255.0 alpha:1.0];
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:nppToolbarCornerR() yRadius:nppToolbarCornerR()];
        [bg setFill]; [p fill];
    }
    static NSDictionary *attrs;
    if (!attrs)
        attrs = @{ NSFontAttributeName:            [NSFont systemFontOfSize:14],
                   NSForegroundColorAttributeName: NSColor.labelColor };
    NSString *glyph = @"▾";
    NSSize sz  = [glyph sizeWithAttributes:attrs];
    NSPoint pt = NSMakePoint(floor(NSMidX(self.bounds) - sz.width  / 2.0),
                             floor(NSMidY(self.bounds) - sz.height / 2.0));
    [glyph drawAtPoint:pt withAttributes:attrs];
}
@end

// Container view: shows unified highlight when the cursor is anywhere over
// the button+arrow group, and (in dark mode) paints a persistent #000000
// background while All-Chars is toggled ON. Toggle-on takes precedence
// over hover (matching NppToggleToolbarButton's pattern).
@interface _AllCharsHoverGroup : NSView { BOOL _hovering; }
@property (nonatomic) BOOL toggledOn;
@end
@implementation _AllCharsHoverGroup
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        NSTrackingArea *ta = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:(NSTrackingMouseEnteredAndExited |
                          NSTrackingActiveInActiveApp     |
                          NSTrackingInVisibleRect)
                   owner:self userInfo:nil];
        [self addTrackingArea:ta];
    }
    return self;
}
- (void)setToggledOn:(BOOL)toggledOn {
    if (_toggledOn == toggledOn) return;
    _toggledOn = toggledOn;
    [self setNeedsDisplay:YES];
}
- (void)mouseEntered:(NSEvent *)e { _hovering = YES;  [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)e  { _hovering = NO;   [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)dirty {
    BOOL isDark = [NppThemeManager shared].isDark;

    // Toggle-on: persistent background (mirrors NppToggleToolbarButton so the
    // pilcrow group reads the same as adjacent Word-Wrap / Indent-Guide chips).
    // Takes precedence over hover.
    //   Dark : #232323 (between Pressed #212121 and Hover #2E2E2E).
    //   Light: #CCE8FF @ 65% + #80C0FF border @ 80%.
    if (_toggledOn) {
        NSColor *bg, *bdr;
        if (isDark) {
            bg  = [NSColor colorWithRed:0x23/255.0 green:0x23/255.0 blue:0x23/255.0 alpha:1.0];
            bdr = bg;
        } else {
            bg  = [NSColor colorWithRed:0xCC/255.0 green:0xE8/255.0 blue:0xFF/255.0 alpha:0.65];
            bdr = [NSColor colorWithRed:0x80/255.0 green:0xC0/255.0 blue:0xFF/255.0 alpha:0.80];
        }
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:nppToolbarCornerR() yRadius:nppToolbarCornerR()];
        [bg setFill]; [p fill];
        NSBezierPath *q = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                                          xRadius:nppToolbarCornerR() yRadius:nppToolbarCornerR()];
        q.lineWidth = 1.0; [bdr setStroke]; [q stroke];
    } else if (_hovering) {
        NSColor *bg, *bdr;
        if (isDark) {
            bg  = [NSColor colorWithRed:0x2e/255.0 green:0x2e/255.0 blue:0x2e/255.0 alpha:1.0];
            bdr = bg;
        } else {
            bg  = [NSColor colorWithRed:0xE5/255.0 green:0xF3/255.0 blue:0xFF/255.0 alpha:1.0];
            bdr = [NSColor colorWithRed:0xD0/255.0 green:0xEA/255.0 blue:0xFF/255.0 alpha:1.0];
        }
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:nppToolbarCornerR() yRadius:nppToolbarCornerR()];
        [bg setFill];
        [p fill];
        NSBezierPath *q = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                                          xRadius:nppToolbarCornerR() yRadius:nppToolbarCornerR()];
        q.lineWidth = 1.0;
        [bdr setStroke];
        [q stroke];
    }
    [super drawRect:dirty];
}
@end

// ── Thin vertical | separator between toolbar groups ─────────────────────────
// 1 logical pixel wide (#b9b9b9), 80% of button height, vertically centered.
@interface NppSeparatorView : NSView @end
@implementation NppSeparatorView
- (void)drawRect:(NSRect)dirtyRect {
    CGFloat h     = self.bounds.size.height;
    CGFloat lineH = floor(h * 0.80);
    CGFloat y     = floor((h - lineH) / 2.0);
    CGFloat x     = floor(NSMidX(self.bounds));
    [[NSColor colorWithRed:0xB9/255.0 green:0xB9/255.0 blue:0xB9/255.0 alpha:1.0] set];
    NSRectFill(NSMakeRect(x, y, 1, lineH));
}
@end

// 1px horizontal line view (#cacaca), used above the tab bar.
@interface _ToolbarBorderLine : NSView @end
@implementation _ToolbarBorderLine
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithRed:0xCA/255.0 green:0xCA/255.0 blue:0xCA/255.0 alpha:1.0] set];
    NSRectFill(self.bounds);
}
@end

// ── Tahoe toolbar group (Option A) ───────────────────────────────────────────
// A condensed, slightly-rounded "capsule" holding a row of icon buttons with the
// group label beneath. When the group has hidden items, the label shows a ▾ and
// clicking it pops a menu of those items. Custom-drawn (Tahoe profile only) — this
// is what NSToolbarItemGroup can't do (it renders a separate ellipsis button and
// can't make the label a dropdown). Used via -makeTahoeGroupToolbarItem:.
static const CGFloat kTGOuterX   = 0.0;   // no outer margin: the pill fills the item so it covers the per-item system glass (else it peeks out as a white "remnant"). The gap between pills comes from a system Space item.
static const CGFloat kTGPadX     = 11.0;  // pill inset L/R (generous, mockup-like)
static const CGFloat kTGPadTop   = 8.0;   // pill inset top
static const CGFloat kTGPadBot   = 6.0;   // pill inset bottom
static const CGFloat kTGBtn      = 24.0;  // icon-button box
static const CGFloat kTGBtnGap   = 4.0;   // gap between icon buttons
static const CGFloat kTGLabelGap = 3.0;   // gap between icon row and label
static const CGFloat kTGLabelH   = 14.0;  // label row height
static const CGFloat kTGRadius   = 12.0;  // pill corner radius (rounded, mockup-like)

@interface NppTahoeGroupView : NSView
- (instancetype)initWithButtons:(NSArray<NSButton *> *)buttons
                          label:(NSString *)label
                   overflowMenu:(nullable NSMenu *)menu;
@end
@implementation NppTahoeGroupView {
    NSMenu   *_overflowMenu;   // nil when the group has no hidden items
    NSButton *_labelButton;
}

- (instancetype)initWithButtons:(NSArray<NSButton *> *)buttons
                          label:(NSString *)label
                   overflowMenu:(nullable NSMenu *)menu {
    NSUInteger n = buttons.count;
    CGFloat rowW     = n * kTGBtn + (n > 0 ? (n - 1) * kTGBtnGap : 0);
    CGFloat capsuleW = kTGPadX * 2 + rowW;
    CGFloat w = capsuleW + kTGOuterX * 2;   // outer margin separates adjacent capsules
    CGFloat h = kTGPadTop + kTGBtn + kTGLabelGap + kTGLabelH + kTGPadBot;
    self = [super initWithFrame:NSMakeRect(0, 0, w, h)];
    if (!self) return nil;
    self.wantsLayer = YES;
    _overflowMenu = menu;

    CGFloat x = kTGOuterX + kTGPadX;
    CGFloat btnY = h - kTGPadTop - kTGBtn;
    for (NSButton *b in buttons) {
        b.frame = NSMakeRect(x, btnY, kTGBtn, kTGBtn);
        [self addSubview:b];
        x += kTGBtn + kTGBtnGap;
    }

    // Group label centered within the capsule. With overflow, append a ⌄ raised
    // a few px and snug to the label (its own attribute run, minimal leading gap).
    _labelButton = [[NSButton alloc] initWithFrame:NSMakeRect(kTGOuterX, kTGPadBot, capsuleW, kTGLabelH)];
    _labelButton.bordered = NO;
    [_labelButton setButtonType:NSButtonTypeMomentaryChange];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    NSMutableAttributedString *att = [[NSMutableAttributedString alloc] initWithString:label attributes:@{
        NSFontAttributeName:            [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor labelColor],   // near-black like the mockup
        NSParagraphStyleAttributeName:  ps,
    }];
    if (menu) {
        [att appendAttributedString:[[NSAttributedString alloc] initWithString:@" ⌄" attributes:@{
            NSFontAttributeName:            [NSFont systemFontOfSize:10],
            NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
            NSParagraphStyleAttributeName:  ps,
            NSBaselineOffsetAttributeName:  @3.0,   // raise the arrow ~3px
        }]];
        _labelButton.target = self;
        _labelButton.action = @selector(_popOverflow:);
    }
    // No overflow → leave target nil; clicks are a harmless no-op.
    _labelButton.attributedTitle = att;
    [self addSubview:_labelButton];
    return self;
}

- (void)_popOverflow:(id)sender {
    // Drop the menu BELOW the label button so it doesn't cover the group title + ⌄.
    // popUpMenuPositioningItem treats the location's Y as top-down here, so a POSITIVE
    // Y moves the menu down on screen. The label button is kTGLabelH tall and sits
    // kTGPadBot above the capsule's bottom, so ~(kTGLabelH + kTGPadBot) clears the title.
    if (_overflowMenu)
        [_overflowMenu popUpMenuPositioningItem:nil
                                     atLocation:NSMakePoint(0, kTGLabelH + kTGPadBot + 5)
                                         inView:_labelButton];
}

- (void)drawRect:(NSRect)dirtyRect {
    BOOL dark = [NppThemeManager shared].isDark;
    // Fill the FULL item bounds so we fully cover macOS-26's per-item system glass
    // tray (which fills the whole item). Any inset would leave a 1pt ring of that
    // tray showing — invisible on a neutral background but a glaring white "halo"
    // against the gradient window. The opaque fill below also stops the tray from
    // bleeding through. (Border drawn on the bounds edge is fine — half-clipped.)
    NSRect cap = self.bounds;
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:cap
                                                      xRadius:kTGRadius yRadius:kTGRadius];

    // Subtle top-light → bottom-darker gradient = a gentle "raised" volume.
    // Opaque (alpha 1.0) so no system tray shows through the pill.
    NSColor *top = dark ? [NSColor colorWithWhite:0.27 alpha:1.0]
                        : [NSColor colorWithRed:0.995 green:1.0  blue:1.0   alpha:1.0];
    NSColor *bot = dark ? [NSColor colorWithWhite:0.21 alpha:1.0]
                        : [NSColor colorWithRed:0.925 green:0.94 blue:0.965 alpha:1.0];
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:top endingColor:bot];
    [g drawInBezierPath:p angle:-90];   // -90° → start (light) at top, end (darker) at bottom

    // Border — only a few tones darker (soft).
    NSColor *border = dark ? [NSColor colorWithWhite:1.0 alpha:0.10]
                           : [NSColor colorWithWhite:0.0 alpha:0.065];
    p.lineWidth = 0.75;
    [border setStroke];
    [p stroke];

    // Barely-visible divider between the icon row and the label.
    CGFloat dy = kTGPadBot + kTGLabelH + kTGLabelGap * 0.5;
    NSColor *div = dark ? [NSColor colorWithWhite:1.0 alpha:0.09]
                        : [NSColor colorWithWhite:0.0 alpha:0.06];
    NSBezierPath *line = [NSBezierPath bezierPath];
    line.lineWidth = 1.0;
    [line moveToPoint:NSMakePoint(NSMinX(cap) + 8, dy)];
    [line lineToPoint:NSMakePoint(NSMaxX(cap) - 8, dy)];
    [div setStroke];
    [line stroke];
}
@end

// ── Toolbar configuration from XML ──────────────────────────────────────────

/// Parse toolbarButtonsConf.xml and return the ordered list of visible buttons.
/// The XML document order determines toolbar button order (left to right).
/// Lookup order: ~/Library/Application Support/Nextpad++/toolbarButtonsConf.xml → bundled default.
static NSDictionary *_parseToolbarConfig(void) {
    NSString *userPath = [nppConfigDir() stringByAppendingPathComponent:@"toolbarButtonsConf.xml"];
    BOOL hasUserConfig = [[NSFileManager defaultManager] fileExistsAtPath:userPath];
    NSString *path = hasUserConfig
        ? userPath
        : [[NSBundle mainBundle] pathForResource:@"toolbarButtonsConf" ofType:@"xml"];
    if (!path) return @{};

    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]
                                                              options:0 error:nil];
    if (!doc) return @{};

    // Check <Standard hideAll="yes">
    NSArray *standardNodes = [doc nodesForXPath:@"//Standard" error:nil];
    BOOL hideAll = NO;
    if (standardNodes.count) {
        NSString *ha = [(NSXMLElement *)standardNodes[0] attributeForName:@"hideAll"].stringValue;
        hideAll = [ha isEqualToString:@"yes"];
    }

    // Collect ALL visible buttons in document order — this IS the toolbar sequence.
    NSMutableArray *visibleButtons = [NSMutableArray array];
    NSMutableSet *hiddenIDs = [NSMutableSet set];

    NSArray *buttons = [doc nodesForXPath:@"//Standard/Button" error:nil];
    for (NSXMLElement *el in buttons) {
        NSString *btnId  = [el attributeForName:@"id"].stringValue;
        NSString *hide   = [el attributeForName:@"hide"].stringValue;
        NSString *action = [el attributeForName:@"action"].stringValue;
        NSString *name   = [el attributeForName:@"name"].stringValue;
        NSString *trigger = [el attributeForName:@"trigger"].stringValue;
        if (!btnId) continue;

        BOOL isHidden = hideAll || [hide isEqualToString:@"yes"];
        if (isHidden) {
            [hiddenIDs addObject:btnId];
        } else {
            [visibleButtons addObject:@{
                @"id": btnId,
                @"action": action ?: @"",
                @"name": name ?: btnId,
                @"trigger": trigger ?: @"click"
            }];
        }
    }

    // Parse appearance
    NSMutableDictionary *appearance = [NSMutableDictionary dictionary];
    for (NSString *state in @[@"Hover", @"Active", @"ToggleOn", @"Normal"]) {
        NSArray *nodes = [doc nodesForXPath:
            [NSString stringWithFormat:@"//ToolbarAppearance/%@", state] error:nil];
        if (nodes.count) {
            NSXMLElement *el = nodes[0];
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            for (NSString *attr in @[@"bgColor", @"borderColor", @"borderWidth", @"cornerRadius"])
                if ([el attributeForName:attr]) d[attr] = [el attributeForName:attr].stringValue;
            appearance[state] = d;
        }
    }

    // Parse <Plugin> section — hidden and visible plugin cmdIDs
    NSMutableSet *hiddenPluginCmdIDs = [NSMutableSet set];
    NSMutableArray *visiblePluginButtons = [NSMutableArray array];
    BOOL hideAllPlugins = NO;
    NSArray *pluginNodes = [doc nodesForXPath:@"//Plugin" error:nil];
    if (pluginNodes.count) {
        NSString *ha = [(NSXMLElement *)pluginNodes[0] attributeForName:@"hideAll"].stringValue;
        hideAllPlugins = [ha isEqualToString:@"yes"];
    }
    NSArray *pluginButtons = [doc nodesForXPath:@"//Plugin/Button" error:nil];
    for (NSXMLElement *el in pluginButtons) {
        NSString *cmdIDStr = [el attributeForName:@"cmdID"].stringValue;
        NSString *hide     = [el attributeForName:@"hide"].stringValue;
        NSString *name     = [el attributeForName:@"name"].stringValue;
        NSString *plugin   = [el attributeForName:@"plugin"].stringValue;
        if (!cmdIDStr) continue;
        BOOL isHidden = hideAllPlugins || [hide isEqualToString:@"yes"];
        if (isHidden) {
            [hiddenPluginCmdIDs addObject:@(cmdIDStr.intValue)];
        } else {
            [visiblePluginButtons addObject:@{
                @"cmdID": @(cmdIDStr.intValue),
                @"name": name ?: @"Plugin",
                @"plugin": plugin ?: @""
            }];
        }
    }

    return @{
        @"hiddenIDs": hiddenIDs,
        @"visibleButtons": visibleButtons,
        @"visiblePluginButtons": visiblePluginButtons,
        @"hasUserConfig": @(hasUserConfig),
        @"hiddenPluginCmdIDs": hiddenPluginCmdIDs,
        @"hideAllPlugins": @(hideAllPlugins),
        @"appearance": appearance
    };
}

// Toolbar descriptor: {identifier, label, tooltip, icon-base-name, action-selector-string}
// icon-base-name maps to icons/light|dark/toolbar/filled/{name}_off.png
static NSArray<NSArray *> *toolbarDescriptors() {
    return @[
        // id              label          tooltip                       icon filename        action
        // filename → icons/standard/toolbar/{filename}.png
        @[kTBNew,         @"New",        @"New Tab",                  @"newFile",          @"newDocument:"],
        @[kTBOpen,        @"Open",       @"Open File",                @"openFile",         @"openDocument:"],
        @[kTBSave,        @"Save",       @"Save",                     @"saveFile",         @"saveDocument:"],
        @[kTBSaveAll,     @"Save All",   @"Save All",                 @"saveAll",          @"saveAllDocuments:"],
        @[kTBClose,       @"Close",      @"Close Tab",                @"closeFile",        @"closeCurrentTab:"],
        @[kTBCloseAll,    @"Close All",  @"Close All Tabs",           @"closeAll",         @"closeAllTabs:"],
        @[kTBPrint,       @"Print",      @"Print",                    @"print",            @"printDocument:"],
        @[kTBCut,         @"Cut",        @"Cut",                      @"cut",              @"cut:"],
        @[kTBCopy,        @"Copy",       @"Copy",                     @"copy",             @"copy:"],
        @[kTBPaste,       @"Paste",      @"Paste",                    @"paste",            @"paste:"],
        @[kTBUndo,        @"Undo",       @"Undo",                     @"undo",             @"undo:"],
        @[kTBRedo,        @"Redo",       @"Redo",                     @"redo",             @"redo:"],
        @[kTBFind,        @"Find",       @"Find",                     @"find",             @"showFindPanel:"],
        @[kTBFindRep,     @"Replace",    @"Replace",                  @"findReplace",      @"showReplacePanel:"],
        @[kTBZoomIn,      @"Zoom In",    @"Zoom In",                  @"zoomIn",           @"zoomIn:"],
        @[kTBZoomOut,     @"Zoom Out",   @"Zoom Out",                 @"zoomOut",          @"zoomOut:"],
        @[kTBSyncV,       @"Sync V",     @"Synchronize Vertical Scrolling",   @"syncV",    @"toggleSyncVerticalScrolling:"],
        @[kTBSyncH,       @"Sync H",     @"Synchronize Horizontal Scrolling", @"syncH",    @"toggleSyncHorizontalScrolling:"],
        @[kTBWrap,        @"Word Wrap",  @"Toggle Word Wrap",         @"wrap",             @"toggleWordWrap:"],
        @[kTBAllChars,    @"All Chars",  @"Show All Characters",      @"allChars",         @"toggleShowAllChars:"],
        @[kTBIndentGuide, @"Indent",     @"Toggle Indent Guide",      @"indentGuide",      @"toggleIndentGuides:"],
        @[kTBUDL,         @"Language",   @"Define Your Language",     @"udl",              @"showDefineLanguage:"],
        @[kTBDocMap,      @"Doc Map",    @"Document Map",             @"docMap",           @"showDocumentMap:"],
        @[kTBDocList,     @"Doc List",   @"Document List",            @"docList",          @"showDocumentList:"],
        @[kTBFuncList,    @"Func List",  @"Function List",            @"funcList",         @"showFunctionList:"],
        @[kTBFileBrowser, @"Workspace",  @"Folder as Workspace",      @"fileBrowser",      @"showFolderAsWorkspace:"],
        @[kTBCharPanel,   @"Characters", @"Character Panel",          @"sf:character",             @"characterPanel:"],
        @[kTBClipboard,   @"Clipboard",  @"Clipboard History",        @"sf:doc.on.clipboard",      @"showClipboardHistory:"],
        @[kTBProject,     @"Project",    @"Project Panel",            @"sf:list.bullet.rectangle", @"showProjectPanel1:"],
        @[kTBMonitor,     @"Monitor",    @"Monitoring (tail -f)",     @"monitoring",       @"toggleMonitoring:"],
        @[kTBStartRecord, @"Record",     @"Start Recording",          @"startRecord",      @"startMacroRecording:"],
        @[kTBStopRecord,  @"Stop",       @"Stop Recording",           @"stopRecord",       @"stopMacroRecording:"],
        @[kTBPlayRecord,  @"Playback",   @"Run Macro",                @"playRecord",       @"runMacro:"],
        @[kTBPlayRecordM, @"Run ×N",     @"Run Macro Multiple Times", @"playRecord_m",     @"runMacroMultipleTimes:"],
        @[kTBSaveRecord,  @"Save Mac",   @"Save Current Recorded Macro", @"saveRecord",    @"saveCurrentMacro:"],
    ];
}

// Maps group toolbar-item identifiers → ordered list of button identifiers within that group.
// Toggle buttons — these identifiers get NppToggleToolbarButton with desaturation
static NSSet *desatToggleIdents(void) {
    return [NSSet setWithObjects:kTBSyncV, kTBSyncH, kTBIndentGuide, kTBMonitor, nil];
}
// Panel toggle buttons — these get NppToggleToolbarButton with blue highlight
static NSSet *panelToggleIdents(void) {
    return [NSSet setWithObjects:kTBWrap, kTBUDL, kTBDocMap, kTBDocList, kTBFuncList, kTBFileBrowser, nil];
}

static NSDictionary<NSString *, NSArray *> *toolbarGroupMap(void) {
    return @{
        kTBGroup1:  @[kTBNew, kTBOpen, kTBSave, kTBSaveAll, kTBClose, kTBCloseAll, kTBPrint],
        kTBGroup2:  @[kTBCut, kTBCopy, kTBPaste],
        kTBGroup3:  @[kTBUndo, kTBRedo],
        kTBGroup4:  @[kTBFind, kTBFindRep],
        kTBGroup5:  @[kTBZoomIn, kTBZoomOut],
        kTBGroup6:  @[kTBSyncV, kTBSyncH],
        // Group7 = view toggles — handled specially (includes AllChars dropdown)
        kTBGroup8:  @[kTBUDL, kTBDocMap, kTBDocList, kTBFuncList, kTBFileBrowser],
        kTBGroup9:  @[kTBMonitor],
        kTBGroup10: @[kTBStartRecord, kTBStopRecord, kTBPlayRecord, kTBPlayRecordM, kTBSaveRecord],
    };
}

// Tahoe profile toolbar grouping: ordered [groupLabel, [primary ids], [overflow ids]].
// Each becomes an NSToolbarItemGroup (→ a Liquid Glass capsule on macOS 26) showing
// the PRIMARY buttons plus, when overflow is non-empty, a trailing ▾ menu button
// (NSMenuToolbarItem) exposing the rest. Separate construction from the Classic
// toolbarGroupMap (parallel-paths); includes the view-toggle buttons (Classic
// handles those specially). No vertical dividers between Tahoe groups (by design).
static NSArray<NSArray *> *tahoeToolbarGroups(void) {
    return @[
        @[@"File",    @[kTBNew, kTBOpen, kTBSave, kTBPrint],  @[kTBSaveAll, kTBClose, kTBCloseAll]],
        @[@"Edit",    @[kTBCopy, kTBPaste, kTBUndo, kTBRedo], @[kTBCut]],
        @[@"Find",    @[kTBFind],                             @[kTBFindRep]],
        @[@"Zoom",    @[kTBZoomIn, kTBZoomOut],               @[]],
        @[@"View",    @[kTBWrap, kTBIndentGuide],             @[kTBAllChars]],
        @[@"Sync",    @[kTBSyncV],                            @[kTBSyncH]],
        @[@"Panels",  @[kTBDocList, kTBFileBrowser, kTBFuncList], @[kTBUDL, kTBDocMap, kTBCharPanel, kTBClipboard, kTBProject]],
        @[@"Monitor", @[kTBMonitor],                          @[]],
        @[@"Macro",   @[kTBStartRecord, kTBStopRecord],       @[kTBPlayRecord, kTBPlayRecordM, kTBSaveRecord]],
    ];
}

// Tahoe-only: an NSSplitView whose divider is a wide, fully transparent GAP so
// the rounded editor/panel cards float apart with the window backdrop showing
// between them (macOS-26 inset look). Gated — under Classic it behaves exactly
// like a stock thin-divider NSSplitView. Used for _editorSplitView.
@interface NppGapSplitView : NSSplitView
@property (nonatomic) CGFloat tahoeGap;   // divider thickness under Tahoe (transparent)
@end
@implementation NppGapSplitView
- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) _tahoeGap = 12.0;
    return self;
}
- (CGFloat)dividerThickness {
    if ([NppThemeManager shared].usesGlassMaterials) return _tahoeGap;
    return [super dividerThickness];
}
- (void)drawDividerInRect:(NSRect)rect {
    if ([NppThemeManager shared].usesGlassMaterials) return;  // transparent → backdrop shows
    [super drawDividerInRect:rect];
}
@end

// Tahoe-only window backdrop: a diagonal gradient that follows the appearance —
//   light: #dce7fd (top-left) → #f5f3f6 (bottom-right)
//   dark:  #25252d (top-left) → #2e2e2e (bottom-right)
// Its backing layer IS the gradient, so it resizes automatically with the window.
// Gated — only instantiated under Tahoe.
@interface NppGradientView : NSView
@end
@implementation NppGradientView
- (NSArray *)_gradientColors {
    NSAppearanceName m = [self.effectiveAppearance
        bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    if ([m isEqualToString:NSAppearanceNameDarkAqua])
        return @[ (id)[NSColor colorWithSRGBRed:0x25/255.0 green:0x25/255.0 blue:0x2D/255.0 alpha:1.0].CGColor,
                  (id)[NSColor colorWithSRGBRed:0x2E/255.0 green:0x2E/255.0 blue:0x2E/255.0 alpha:1.0].CGColor ];
    return @[ (id)[NSColor colorWithSRGBRed:0xDC/255.0 green:0xE7/255.0 blue:0xFD/255.0 alpha:1.0].CGColor,
              (id)[NSColor colorWithSRGBRed:0xF5/255.0 green:0xF3/255.0 blue:0xF6/255.0 alpha:1.0].CGColor ];
}
- (CALayer *)makeBackingLayer {
    CAGradientLayer *g = [CAGradientLayer layer];
    g.colors     = [self _gradientColors];
    g.startPoint = CGPointMake(0.0, 1.0);   // top-left
    g.endPoint   = CGPointMake(1.0, 0.0);   // bottom-right
    return g;
}
- (void)_applyGradientColors {
    if ([self.layer isKindOfClass:[CAGradientLayer class]])
        ((CAGradientLayer *)self.layer).colors = [self _gradientColors];
}
// CGColors aren't dynamic, so re-resolve on a light/dark flip and when first shown.
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; [self _applyGradientColors]; }
- (void)viewDidMoveToWindow             { [super viewDidMoveToWindow];             [self _applyGradientColors]; }
@end

// Tahoe-only (gated): round an editor "card" — bottom-left + bottom-right on the
// container (its top edge is the transparent tab strip), and top-right on the
// content view (the white editor begins below the tab bar). Top-left stays square
// under the first tab. Mirrors the primary editor's rounding; used for the
// secondary (vertical/horizontal split) editors so every pane matches.
static void _nppTahoeRoundEditorCard(NSView *container, NSView *content) {
    if (![NppThemeManager shared].usesGlassMaterials) return;
    container.wantsLayer = YES;
    container.layer.cornerRadius  = 8.0;
    container.layer.masksToBounds = YES;
    container.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner; // bottom
    content.wantsLayer = YES;
    content.layer.cornerRadius  = 8.0;
    content.layer.masksToBounds = YES;
    content.layer.maskedCorners = kCALayerMaxXMaxYCorner;  // top-right
}

@interface MainWindowController ()
    <TabManagerDelegate, NSWindowDelegate,
     NSToolbarDelegate, FindReplacePanelDelegate, NSUserInterfaceValidations,
     NSSplitViewDelegate, IncrementalSearchBarDelegate,
     FolderTreePanelDelegate, GitPanelDelegate, ProjectPanelDelegate,
     FindWindowDelegate, SearchResultsPanelDelegate,
     ClipboardHistoryPanelDelegate, DocumentMapPanelDelegate,
     DocumentListPanelDelegate, CharacterPanelDelegate,
     SidePanelHostDelegate,
     NSMenuDelegate>
- (void)_saveOpenSidePanels;
- (void)_populatePluginOverflowMenu:(NSMenu *)menu;  // plugins overflow (≫) submenu
- (void)_closeEditors:(NSArray<EditorView *> *)editors inManager:(TabManager *)mgr;
@end

// Lazy delegate for the plugins overflow (≫) submenu: on open it asks the window
// controller to repopulate the menu with only the plugins whose toolbar segment is
// currently overflowed, so the single "Plugins" entry lists just the hidden ones.
@interface _NppPluginOverflowMenuDelegate : NSObject <NSMenuDelegate>
@property (nonatomic, weak) MainWindowController *owner;
@end
@implementation _NppPluginOverflowMenuDelegate
- (void)menuNeedsUpdate:(NSMenu *)menu { [self.owner _populatePluginOverflowMenu:menu]; }
@end

@implementation MainWindowController {
    TabManager       *_tabManager;
    FindReplacePanel *_findPanel;
    NSView           *_statusBar;
    NSTextField      *_statusLeft;
    NSTextField      *_statusRight;
    NSTextField      *_gitBranchLabel;
    NSLayoutConstraint *_findPanelHeightConstraint;
    // Issue #183 — primary tab bar height constraints for the "Hide tab bar"
    // pref. Normally _primaryTabBarMinHeight (>= 25, allows multi-row wrap) is
    // active; hiding swaps to _primaryTabBarZeroHeight (== 0) so the editor
    // reclaims the strip. Toggled by -_applyTabBarVisibility:.
    NSLayoutConstraint *_primaryTabBarMinHeight;
    NSLayoutConstraint *_primaryTabBarZeroHeight;
    // Same pair for the secondary split tab bars (horizontal/bottom + vertical/
    // right), so "Hide tab bar" also collapses them in split view.
    NSLayoutConstraint *_subTabBarHMinHeight;
    NSLayoutConstraint *_subTabBarHZeroHeight;
    NSLayoutConstraint *_subTabBarVMinHeight;
    NSLayoutConstraint *_subTabBarVZeroHeight;
    NSTimer          *_autoSaveTimer;
    /// YES once restoreLastSession has successfully opened ≥1 tab from the
    /// stored session this launch. Used by the session save to decide whether
    /// the "preserve when empty" guard applies — see the Issue #87
    /// comment for details. (Bug fix: closing all restored tabs and quitting
    /// would otherwise leave the prior session.plist untouched, so the same
    /// tabs reappeared on next launch.)
    BOOL              _didRestoreSession;
    BOOL              _isWindowReadyForResizeEvents;

    // Side panel host
    NSSplitView       *_editorSplitView;
    SidePanelHost     *_sidePanelHost;
    // Maps content-view → original (English) title key passed to
    // _setPanelVisible:title:show:YES. Lets NPPLocalizationChanged
    // retranslate every open panel's title without each panel needing
    // its own observer. Weak-to-strong so content views can deallocate
    // without leaving stale keys.
    NSMapTable<NSView *, NSString *> *_panelTitleKeys;
    DocumentListPanel *_docListPanel;
    ClipboardHistoryPanel *_clipboardPanel;
    FunctionListPanel     *_funcListPanel;
    DocumentMapPanel      *_docMapPanel;
    CommandPalettePanel   *_commandPalette;
    NSView                *_folderTreePanel;   // FolderTreePanel
    NSView                *_gitPanel;          // GitPanel
    CharacterPanel        *_charPanel;
    ProjectPanel          *_projectPanel;
    SearchResultsPanel    *_searchResultsPanel;
    NSSplitView           *_searchSplitView;    // wraps editor area + search results

    // Second editor view — horizontal (top/bottom)
    NSSplitView   *_hSplitView;
    TabManager    *_subTabManagerH;
    NSView        *_subEditorContainerH;

    // Second editor view — vertical (left/right)
    NSSplitView   *_vSplitView;
    TabManager    *_subTabManagerV;
    NSView        *_subEditorContainerV;

    TabManager    *_activeTabManager;   // defaults to _tabManager

    // View state
    BOOL _showAllChars;
    BOOL _showIndentGuides;
    BOOL _showLineNumbers;

    // Ctrl + scroll-wheel zoom
    id      _scrollZoomEventMonitor;
    CGFloat _scrollZoomAccumulator;

    // Scroll synchronization
    BOOL _syncVerticalScrolling;
    BOOL _syncHorizontalScrolling;
    intptr_t _syncColumnDelta;  // column offset between views when sync was enabled
    intptr_t _syncLineDelta;    // line offset between views when sync was enabled
    NSTimer *_scrollSyncTimer;
    sptr_t   _lastPrimaryXOffset, _lastSecondaryXOffset;
    sptr_t   _lastPrimaryLine, _lastSecondaryLine;

    // Incremental search bar
    IncrementalSearchBar *_incSearchBar;
    NSLayoutConstraint   *_incSearchBarHeightConstraint;

    // Toolbar toggle button references (for state refresh)
    NppToggleToolbarButton *_tbSyncV, *_tbSyncH;
    NppToggleToolbarButton *_tbWrap, *_tbIndentGuide;
    NppToggleToolbarButton *_tbUDL, *_tbDocMap, *_tbDocList, *_tbFuncList, *_tbFileBrowser;
    NppToggleToolbarButton *_tbMonitor;
    NppToolbarButton *_tbStartRecord, *_tbStopRecord, *_tbPlayRecord, *_tbPlayRecordM, *_tbSaveRecord;
    _AllCharsHoverGroup *_tbAllCharsHoverGroup;  // dark-mode toggle-on bg painter
    NSButton *_tbAllChars;  // pilcrow button — cached so _darkModeChanged: can refresh its image

    // Plugin toolbar icons: array of @{@"id": identifier, @"icon": NSImage, @"tooltip": NSString, @"cmdID": @(int)}
    NSMutableArray<NSDictionary *> *_pluginToolbarItems;

    // Lazy delegate for the plugins overflow (≫) submenu (Classic default mode).
    _NppPluginOverflowMenuDelegate *_pluginOverflowDelegate;

    // Toolbar configuration parsed from toolbarButtonsConf.xml
    NSDictionary *_toolbarConfig; // @{@"hiddenIDs": NSSet, @"extraButtons": NSArray, @"appearance": NSDictionary}

    // Tahoe profile: effective toolbar group layout (built-in + plugins groups),
    // loaded from toolbarButtonsTahoeConf.xml (or materialized from defaults).
    // See TahoeToolbarConfig. Array of @{label,kind,primary,overflow,hidden}.
    NSArray<NSDictionary *> *_tahoeModel;

    // View display modes
    BOOL              _postItMode;
    BOOL              _postItSavedToolbarVisible;
    NSWindowStyleMask _savedStyleMask;
    NSColor          *_savedBgColor;
    BOOL              _distractionFreeMode;
    BOOL              _savedToolbarVisible;

    // Editor right-click context menu (built from contextMenu.xml)
    NSMenu           *_editorContextMenu;

    // Top-level Language menu. Cached so menuWillOpen: can find it
    // without walking the menu bar every time. Set by
    // _installLanguagesMenuDelegate.
    NSMenu           *_languagesMenu;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1024, 768)
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable |
                             NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"Nextpad++";
    window.minSize = NSMakeSize(480, 320);
    [window center];

    // Tahoe: let the content view fill the whole window (under the titlebar +
    // toolbar) so the gradient backdrop covers the title/toolbar area too. The
    // editor stack is repinned to contentLayoutGuide (below the toolbar) in the
    // content layout. Gated — Classic keeps the standard below-titlebar content.
    if ([NppThemeManager shared].usesGlassMaterials) {
        window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    }

    self = [super initWithWindow:window];
    if (self) {
        // Disable macOS automatic window state restoration — we use our own session system
        window.restorable = NO;
        _showLineNumbers = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefShowLineNumbers];
        _showIndentGuides = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefShowIndentGuides];
        window.delegate = self;
        [self buildToolbar];
        [self buildContentView];
        [self restoreWindowFrame];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(editorCursorMoved:)
                   name:EditorViewCursorDidMoveNotification object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(editorDidGainFocus:)
                   name:EditorViewDidGainFocusNotification object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_editorDidSave:)
                   name:EditorViewDidSaveNotification object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_editorZoomDidChange:)
                   name:EditorViewZoomDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_shortcutsChanged:)
                   name:NPPShortcutsChangedNotification object:nil];
        // (scroll sync uses a timer, not notifications)
        [self rebuildRecentFilesMenu];
        [self rebuildUDLLanguageMenu];
        [self _installLanguagesMenuDelegate];
        _autoSaveTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                          target:self
                                                        selector:@selector(autoSaveTick:)
                                                        userInfo:nil
                                                         repeats:YES];
        [self _installScrollZoomMonitor];
    }
    return self;
}

- (void)_installScrollZoomMonitor {
    __weak typeof(self) weakSelf = self;
    _scrollZoomEventMonitor =
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                              handler:^NSEvent *(NSEvent *event) {
        // Only intercept Control + scroll
        if (!(event.modifierFlags & NSEventModifierFlagControl)) return event;

        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return event;

        // addLocalMonitorForEventsMatchingMask is APP-WIDE — every
        // MainWindowController's monitor sees every scroll event in
        // any window. event.locationInWindow is in the *originating*
        // window's coord space; converting it via self.window.contentView
        // when event.window != self.window yields a meaningless point
        // that can spuriously hit-test to an EditorView in self.window
        // and trigger zoom in the wrong window. Bail early when the
        // event isn't for us. (Also covers events from FloatingPanelWindow
        // pop-out side-panels and the Find window.)
        if (event.window != self.window) return event;

        // Confirm the pointer is over one of our editor views
        NSPoint loc = [self.window.contentView convertPoint:event.locationInWindow fromView:nil];
        NSView *hit = [self.window.contentView hitTest:loc];
        BOOL inEditor = NO;
        for (NSView *v = hit; v; v = v.superview) {
            if ([v isKindOfClass:[EditorView class]]) { inEditor = YES; break; }
        }
        if (!inEditor) return event;

        CGFloat delta;
        if (event.hasPreciseScrollingDeltas) {
            // Trackpad: accumulate small per-event deltas; fire once per threshold crossed
            self->_scrollZoomAccumulator += event.scrollingDeltaY;
            if (fabs(self->_scrollZoomAccumulator) < 8.0) return nil;
            delta = self->_scrollZoomAccumulator;
            self->_scrollZoomAccumulator = 0.0;
        } else {
            // Discrete mouse wheel: one notch = one zoom step
            delta = event.deltaY;
        }

        if      (delta > 0) [self zoomIn:nil];
        else if (delta < 0) [self zoomOut:nil];

        return nil; // consume — do not scroll the editor
    }];
}

- (void)dealloc {
    if (_scrollZoomEventMonitor) {
        [NSEvent removeMonitor:_scrollZoomEventMonitor];
        _scrollZoomEventMonitor = nil;
    }
    // Defensive: windowWillClose: already tears these down, but invalidate here
    // too in case the controller is released without a window-close notification.
    [_scrollSyncTimer invalidate];
    _scrollSyncTimer = nil;
    [_autoSaveTimer invalidate];
    _autoSaveTimer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Active editor accessor

/// Returns the current editor in whichever view the user last interacted with.
- (EditorView *)currentEditor { return _activeTabManager.currentEditor; }

/// Returns the editor for a specific plugin view ID (0=primary, 1=secondary vertical split).
/// Falls back to primary editor if secondary has no tabs or doesn't exist.
- (EditorView *)editorForPluginView:(int)viewId {
    if (viewId == 1 && _subTabManagerV && _subTabManagerV.allEditors.count > 0) {
        return _subTabManagerV.currentEditor;
    }
    return _tabManager.currentEditor;
}

/// Returns the EditorView that owns the window's first responder, falling back to currentEditor.
- (EditorView *)focusedEditor {
    NSView *v = [self.window.firstResponder isKindOfClass:[NSView class]]
                ? (NSView *)self.window.firstResponder : nil;
    while (v) {
        if ([v isKindOfClass:[EditorView class]]) return (EditorView *)v;
        v = v.superview;
    }
    return [self currentEditor];
}

#pragma mark - Toolbar (NSToolbarDelegate)

- (void)buildToolbar {
    // Parse toolbar configuration (hidden buttons, extra buttons, appearance)
    _toolbarConfig = _parseToolbarConfig();
    // Tahoe profile: load (or materialize) the group layout from
    // toolbarButtonsTahoeConf.xml before the toolbar delegate is queried.
    if ([self _toolbarUsesTahoe]) [self _loadTahoeToolbarModel];

    NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:@"NppToolbar"];
    tb.delegate = self;
    tb.allowsUserCustomization = NO;
    // Icon-only for both profiles: Classic packs buttons into one custom-view item
    // per group; the Tahoe profile uses custom NppTahoeGroupView capsules that draw
    // their OWN labels (and label-dropdowns). Either way there are no system labels.
    tb.displayMode = NSToolbarDisplayModeIconOnly;
    // Issue #26: each NSToolbarItem in our setup wraps a multi-button custom
    // view, not a single labelled button — so there's no per-item label to
    // render in "Icon and Text" mode. Hide the display-mode picker from the
    // toolbar's right-click context menu so users can't pick a mode that
    // would only render empty space below the icons. See
    // docs/issue-26-toolbar-icon-and-text.md for the full analysis. Will be
    // re-enabled when toolbar is refactored to one NSToolbarItem per button.
    // Issue #114 — `allowsDisplayModeCustomization` was actually added in
    // macOS 15 Sequoia (not 13, as the original commit message claimed). On
    // macOS 13/14 the runtime selector doesn't exist, and the bad @available
    // gate triggered an unrecognized-selector exception during init that
    // partially destroyed the window setup and made File > New fall through
    // to NSDocumentController. Gate set to the correct minimum below.
    if (@available(macOS 15.0, *)) {
        tb.allowsDisplayModeCustomization = NO;
    }
    self.window.toolbar = tb;
    self.window.toolbar.visible = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefToolbarVisible];
    // Expanded style keeps the toolbar in its OWN row below the title bar for
    // BOTH profiles — matching the Classic layout and the Tahoe mockup. (Unified
    // crammed the icons into the title row, so we don't use it.) For Tahoe we make
    // the titlebar transparent so the opaque chrome strip behind the pill groups
    // drops away and each pill reads as a separate floating element.
    if (@available(macOS 11.0, *)) {
        self.window.toolbarStyle = NSWindowToolbarStyleExpanded;
        self.window.titlebarAppearsTransparent = [NppThemeManager shared].usesGlassMaterials;
    }
}

- (void)addPluginToolbarIconForPluginDir:(NSString *)pluginDir
                                iconHint:(nullable NSString *)iconHint
                                 tooltip:(NSString *)tooltip
                                   cmdID:(int)cmdID
{
    // Check if user's toolbar config hides this plugin button
    if ([_toolbarConfig[@"hideAllPlugins"] boolValue]) return;
    NSSet *hiddenCmds = _toolbarConfig[@"hiddenPluginCmdIDs"];
    if ([hiddenCmds containsObject:@(cmdID)]) return;

    NSImage *icon = [self _resolvePluginToolbarIconForDir:pluginDir hint:iconHint];
    if (!icon) {
        NSLog(@"[Plugins] addPluginToolbarIcon: no icon found for cmdID %d in %@",
              cmdID, pluginDir ?: @"(nil)");
        return;
    }

    if (!_pluginToolbarItems)
        _pluginToolbarItems = [NSMutableArray array];

    NSString *ident = [NSString stringWithFormat:@"TB_Plugin_%d", cmdID];

    // Avoid duplicates
    for (NSDictionary *pti in _pluginToolbarItems) {
        if ([pti[@"id"] isEqualToString:ident]) return;
    }

    // Mutable so _refreshPluginToolbarIcons can update the cached icon in place
    // when the system appearance flips. pluginDir + iconHint are stored so the
    // re-resolution can run without revisiting the plugin manager.
    NSMutableDictionary *pti = [NSMutableDictionary dictionaryWithDictionary:@{
        @"id":         ident,
        @"icon":       icon,
        @"tooltip":    tooltip ?: @"",
        @"cmdID":      @(cmdID),
        @"pluginDir":  pluginDir ?: @"",
        @"iconHint":   iconHint ?: @"",
    }];
    [_pluginToolbarItems addObject:pti];

    // DEFAULT mode: plugins are packed into one toolbar item per plugin (grouped
    // by pluginDir) so a plugin that registers several icons gets them sitting
    // tightly together, with separators bracketing multi-icon plugin groups.
    // USER-CONFIG mode keeps the legacy per-icon individual items (in that mode
    // plugins also appear inside the single kTBUserConfig item built at load).
    NSToolbar *tb = self.window.toolbar;
    if ([self _toolbarUsesTahoe]) {
        // Tahoe: all plugins live in the single "Plugins" capsule — rebuild it.
        [self _rebuildTahoePluginsGroup];
    } else if ([_toolbarConfig[@"hasUserConfig"] boolValue]) {
        NSInteger insertIdx = tb.items.count;
        for (NSInteger i = 0; i < (NSInteger)tb.items.count; i++) {
            if ([tb.items[i].itemIdentifier isEqualToString:NSToolbarFlexibleSpaceItemIdentifier]) {
                insertIdx = i;
                break;
            }
        }
        [tb insertItemWithItemIdentifier:ident atIndex:insertIdx];
    } else {
        [self _rebuildPluginToolbarGroups];
    }
}

// Group key for a plugin toolbar item: its pluginDir, so all icons registered by
// one plugin share a group. Falls back to the item id for entries lacking a dir.
static NSString *npPluginGroupKey(NSDictionary *pti) {
    NSString *dir = pti[@"pluginDir"];
    return dir.length ? dir : pti[@"id"];
}

// Distinct plugin group keys in first-registration order.
- (NSArray<NSString *> *)_orderedPluginGroupKeys {
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *pti in _pluginToolbarItems) {
        NSString *k = npPluginGroupKey(pti);
        if (![seen containsObject:k]) { [seen addObject:k]; [keys addObject:k]; }
    }
    return keys;
}

// DEFAULT mode only: rebuild the per-plugin group toolbar items. Removes every
// existing plugin-group item and reinserts one per plugin (in registration order)
// just before the flexible space. A full rebuild keeps separator bracketing
// consistent — turning one plugin from single- to multi-icon can change a
// neighbour's leading separator (see -makePluginGroupToolbarItemForKey:).
- (void)_rebuildPluginToolbarGroups {
    NSToolbar *tb = self.window.toolbar;
    if (!tb) return;

    // Remove existing plugin segment items (and any legacy per-group items).
    for (NSInteger i = (NSInteger)tb.items.count - 1; i >= 0; i--) {
        NSString *ident = tb.items[i].itemIdentifier;
        if ([ident hasPrefix:kTBPluginSegPrefix] || [ident hasPrefix:kTBPluginGroupPrefix])
            [tb removeItemAtIndex:i];
    }

    // Partition the ordered plugin groups into segments: each multi-icon plugin is its
    // own segment (and acts as a boundary); a maximal run of consecutive single-icon
    // plugins is coalesced into one segment. Insert one item per segment, identified by
    // the segment's first group key. Coalescing the runs keeps standalone icons tight
    // (no macOS-26 inter-item gap between them) while letting the toolbar hide plugins
    // segment-by-segment on resize instead of all at once.
    NSArray<NSString *> *ordered = [self _orderedPluginGroupKeys];
    if (ordered.count == 0) return;

    NSMutableArray<NSString *> *segmentStarts = [NSMutableArray array];
    NSUInteger gi = 0;
    while (gi < ordered.count) {
        [segmentStarts addObject:ordered[gi]];
        if ([self _isMultiIconGroupKey:ordered[gi]]) {
            gi++;                                              // multi-icon group = one segment
        } else {
            gi++;
            while (gi < ordered.count && ![self _isMultiIconGroupKey:ordered[gi]]) gi++;  // run of singles
        }
    }

    for (NSString *startKey in segmentStarts) {
        NSInteger insertIdx = tb.items.count;
        for (NSInteger i = 0; i < (NSInteger)tb.items.count; i++) {
            if ([tb.items[i].itemIdentifier isEqualToString:NSToolbarFlexibleSpaceItemIdentifier]) {
                insertIdx = i;
                break;
            }
        }
        [tb insertItemWithItemIdentifier:[kTBPluginSegPrefix stringByAppendingString:startKey]
                                 atIndex:insertIdx];
    }
}

// Build the toolbar item for one plugin group (all icons whose group key matches).
// Buttons pack at nppSpacing(); a multi-icon group is bracketed by vertical
// separators like the dividers between standard groups. To avoid doubled dividers
// the leading separator is drawn only when there isn't already one to the left:
//   • leading separator  ⇔  (group is first)  OR  (multi-icon AND prev group single-icon)
//   • trailing separator ⇔  multi-icon
// The first group's leading separator also divides the standard buttons from the
// plugin section (the macro group no longer draws a trailing divider for plugins).
- (NSToolbarItem *)makePluginGroupToolbarItemForKey:(NSString *)groupKey {
    const CGFloat kBtnSize  = nppBtnSize();
    const CGFloat kSpacing  = nppSpacing();
    const CGFloat kSepInner = 4.0;  // gap between a separator and the adjacent button
    const CGFloat kSepOuter = 3.0;  // gap between a separator and the item edge

    // This group's plugin entries, in registration order.
    NSMutableArray<NSDictionary *> *members = [NSMutableArray array];
    for (NSDictionary *pti in _pluginToolbarItems)
        if ([npPluginGroupKey(pti) isEqualToString:groupKey]) [members addObject:pti];
    if (members.count == 0) return nil;

    NSArray<NSString *> *orderedKeys = [self _orderedPluginGroupKeys];
    NSInteger idx = (NSInteger)[orderedKeys indexOfObject:groupKey];
    BOOL isFirst = (idx == 0);
    BOOL isMulti = members.count > 1;

    BOOL prevIsMulti = NO;
    if (idx > 0) {
        NSString *prevKey = orderedKeys[idx - 1];
        NSUInteger cnt = 0;
        for (NSDictionary *pti in _pluginToolbarItems)
            if ([npPluginGroupKey(pti) isEqualToString:prevKey]) cnt++;
        prevIsMulti = (cnt > 1);
    }
    BOOL drawLeading  = isFirst || (isMulti && !prevIsMulti);
    BOOL drawTrailing = isMulti;

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kBtnSize, kBtnSize)];
    CGFloat x = 0;

    if (drawLeading) {
        x += kSepOuter;
        [container addSubview:[[NppSeparatorView alloc]
            initWithFrame:NSMakeRect(x, 0, 1, kBtnSize)]];
        x += 1 + kSepInner;
    }

    NSUInteger j = 0;
    for (NSDictionary *pti in members) {
        if (j > 0) x += kSpacing;
        NppToolbarButton *btn = [[NppToolbarButton alloc]
            initWithFrame:NSMakeRect(x, 0, kBtnSize, kBtnSize)];
        NSImage *icon = pti[@"icon"];
        icon.size = NSMakeSize(nppIconSize(), nppIconSize());
        btn.image   = icon;
        btn.toolTip = pti[@"tooltip"];
        btn.tag     = [pti[@"cmdID"] intValue];
        btn.target  = self;
        btn.action  = @selector(pluginToolbarAction:);
        // NOTE: deliberately no btn.identifier — that keeps the dark-mode reskin
        // loop (_reskinToolbarIcons) from reloading plugin icons via
        // nppToolbarIcon(); plugin icons are refreshed by _refreshPluginToolbarIcons.
        [container addSubview:btn];
        x += kBtnSize;
        j++;
    }

    if (drawTrailing) {
        x += kSepInner;
        [container addSubview:[[NppSeparatorView alloc]
            initWithFrame:NSMakeRect(x, 0, 1, kBtnSize)]];
        x += 1 + kSepOuter;
    }

    NSRect cf = container.frame; cf.size.width = x; container.frame = cf;

    NSToolbarItem *item = [[NSToolbarItem alloc]
        initWithItemIdentifier:[kTBPluginGroupPrefix stringByAppendingString:groupKey]];
    item.view    = container;
    item.minSize = NSMakeSize(x, kBtnSize);
    item.maxSize = NSMakeSize(x, kBtnSize);

    // Overflow (≫) menu: a single-icon group is one actionable item; a multi-icon
    // group becomes a submenu of its actions so nothing is lost when collapsed.
    if (members.count == 1) {
        NSDictionary *pti = members[0];
        NSString *title = pti[@"tooltip"] ?: groupKey.lastPathComponent ?: @"";
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:title
            action:@selector(pluginToolbarAction:) keyEquivalent:@""];
        mi.target  = self;
        mi.tag     = [pti[@"cmdID"] intValue];
        item.label = title;
        item.menuFormRepresentation = mi;
    } else {
        NSString *groupTitle = groupKey.lastPathComponent ?: @"Plugin";
        NSMenuItem *parent = [[NSMenuItem alloc] initWithTitle:groupTitle
            action:nil keyEquivalent:@""];
        NSMenu *sub = [[NSMenu alloc] initWithTitle:groupTitle];
        for (NSDictionary *pti in members) {
            NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:(pti[@"tooltip"] ?: @"")
                action:@selector(pluginToolbarAction:) keyEquivalent:@""];
            mi.target = self;
            mi.tag    = [pti[@"cmdID"] intValue];
            [sub addItem:mi];
        }
        parent.submenu = sub;
        item.label = groupTitle;
        item.menuFormRepresentation = parent;
    }

    return item;
}

// YES if the plugin group (keyed by pluginDir) registered more than one toolbar icon.
// A multi-icon plugin stays its own toolbar item (a segment boundary); runs of
// single-icon plugins between such boundaries are coalesced (see below).
- (BOOL)_isMultiIconGroupKey:(NSString *)groupKey {
    NSUInteger cnt = 0;
    for (NSDictionary *pti in _pluginToolbarItems)
        if ([npPluginGroupKey(pti) isEqualToString:groupKey]) {
            if (++cnt > 1) return YES;
        }
    return NO;
}

// Build the toolbar item for the plugin SEGMENT that starts at `firstKey`. A segment is
// either a single multi-icon plugin group, or a maximal run of consecutive single-icon
// plugin groups. Reconstructed deterministically from the ordered group list so the
// item identifier (prefix + firstKey) is stable across rebuilds.
// The plugin group keys forming the segment that starts at `firstKey`: a single
// multi-icon plugin, or a maximal run of consecutive single-icon plugins. Same
// partition as -_rebuildPluginToolbarGroups, so segment identifiers stay consistent.
- (NSArray<NSString *> *)_pluginSegmentKeysStartingAt:(NSString *)firstKey {
    NSArray<NSString *> *ordered = [self _orderedPluginGroupKeys];
    NSUInteger start = [ordered indexOfObject:firstKey];
    if (start == NSNotFound) return @[];
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithObject:ordered[start]];
    if (![self _isMultiIconGroupKey:ordered[start]]) {
        for (NSUInteger i = start + 1; i < ordered.count; i++) {
            if ([self _isMultiIconGroupKey:ordered[i]]) break;
            [keys addObject:ordered[i]];
        }
    }
    return keys;
}

- (NSToolbarItem *)makePluginSegmentItemStartingAt:(NSString *)firstKey {
    NSArray<NSString *> *ordered = [self _orderedPluginGroupKeys];
    if ([ordered indexOfObject:firstKey] == NSNotFound) return nil;
    NSArray<NSString *> *keys = [self _pluginSegmentKeysStartingAt:firstKey];
    if (keys.count == 0) return nil;

    NSToolbarItem *item = [self _makePluginItemForGroupKeys:keys
                                  identifier:[kTBPluginSegPrefix stringByAppendingString:firstKey]];
    if (!item) return nil;

    // Overflow (≫): collapse to a SINGLE "Plugins" submenu that lists only the HIDDEN
    // plugins. Only the LAST plugin segment carries it — NSToolbar overflows the plugin
    // block right-to-left, so the last segment is always present once any plugin hides.
    // Its submenu is populated lazily by -_populatePluginOverflowMenu: from whichever
    // segments are currently overflowed, so it stays correct as the window resizes.
    // Every other segment gets a hidden menu item so it adds nothing to the overflow.
    BOOL isLastSegment = [keys.lastObject isEqualToString:ordered.lastObject];
    if (isLastSegment) {
        if (!_pluginOverflowDelegate) {
            _pluginOverflowDelegate = [_NppPluginOverflowMenuDelegate new];
            _pluginOverflowDelegate.owner = self;
        }
        NSMenu *sub = [[NSMenu alloc] initWithTitle:@"Plugins"];
        sub.delegate = _pluginOverflowDelegate;
        NSMenuItem *parent = [[NSMenuItem alloc] initWithTitle:@"Plugins" action:nil keyEquivalent:@""];
        parent.submenu = sub;
        item.menuFormRepresentation = parent;
    } else {
        NSMenuItem *hidden = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
        hidden.hidden = YES;
        item.menuFormRepresentation = hidden;
    }
    return item;
}

// Populate the plugins overflow (≫) submenu with only the plugins whose toolbar segment
// is currently OVERFLOWED (in -items but not -visibleItems). Called lazily on menu open,
// so it always reflects the current window width.
- (void)_populatePluginOverflowMenu:(NSMenu *)menu {
    [menu removeAllItems];
    NSToolbar *tb = self.window.toolbar;
    if (!tb) return;
    NSArray<__kindof NSToolbarItem *> *visible = tb.visibleItems;
    for (NSToolbarItem *it in tb.items) {
        if (![it.itemIdentifier hasPrefix:kTBPluginSegPrefix]) continue;
        if ([visible containsObject:it]) continue;   // visible in the toolbar → not hidden
        NSString *firstKey = [it.itemIdentifier substringFromIndex:kTBPluginSegPrefix.length];
        for (NSString *gk in [self _pluginSegmentKeysStartingAt:firstKey]) {
            for (NSDictionary *pti in _pluginToolbarItems) {
                if (![npPluginGroupKey(pti) isEqualToString:gk]) continue;
                NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:(pti[@"tooltip"] ?: @"")
                    action:@selector(pluginToolbarAction:) keyEquivalent:@""];
                mi.target = self;
                mi.tag    = [pti[@"cmdID"] intValue];
                [menu addItem:mi];
            }
        }
    }
    if (menu.numberOfItems == 0) {   // safety: never leave the submenu empty
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
        none.enabled = NO;
        [menu addItem:none];
    }
}

// Render a contiguous slice of plugin groups into ONE NSToolbarItem. Mirrors
// -makePluginGroupToolbarItemForKey: (separators bracket multi-icon groups, normal
// inter-icon spacing elsewhere) but packs several groups into one item so macOS 26's
// inter-item gap can't appear between them. Separator decisions use the GLOBAL ordered
// list so dividers land exactly where the per-group layout used to put them.
- (NSToolbarItem *)_makePluginItemForGroupKeys:(NSArray<NSString *> *)groupKeys
                                    identifier:(NSString *)ident {
    const CGFloat kBtnSize  = nppBtnSize();
    const CGFloat kSpacing  = nppSpacing();
    const CGFloat kSepInner = 4.0;
    const CGFloat kSepOuter = 3.0;

    NSArray<NSString *> *ordered = [self _orderedPluginGroupKeys];
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kBtnSize, kBtnSize)];
    CGFloat x = 0;
    BOOL prevDrewTrailing = NO;
    BOOL firstInItem = YES;

    for (NSString *groupKey in groupKeys) {
        NSMutableArray<NSDictionary *> *members = [NSMutableArray array];
        for (NSDictionary *pti in _pluginToolbarItems)
            if ([npPluginGroupKey(pti) isEqualToString:groupKey]) [members addObject:pti];
        if (members.count == 0) continue;

        NSInteger gIdx    = (NSInteger)[ordered indexOfObject:groupKey];
        BOOL isMulti      = members.count > 1;
        BOOL prevIsMulti  = (gIdx > 0) ? [self _isMultiIconGroupKey:ordered[gIdx - 1]] : NO;
        BOOL drawLeading  = (gIdx == 0) || (isMulti && !prevIsMulti);
        BOOL drawTrailing = isMulti;

        // Inter-group gap: if neither a trailing (prev) nor a leading (this) separator
        // sits at the boundary, add the normal inter-icon gap so icons don't touch.
        if (!firstInItem && !drawLeading && !prevDrewTrailing) x += kSpacing;

        if (drawLeading) {
            x += kSepOuter;
            [container addSubview:[[NppSeparatorView alloc]
                initWithFrame:NSMakeRect(x, 0, 1, kBtnSize)]];
            x += 1 + kSepInner;
        }

        NSUInteger j = 0;
        for (NSDictionary *pti in members) {
            if (j > 0) x += kSpacing;
            NppToolbarButton *btn = [[NppToolbarButton alloc]
                initWithFrame:NSMakeRect(x, 0, kBtnSize, kBtnSize)];
            NSImage *icon = pti[@"icon"];
            icon.size = NSMakeSize(nppIconSize(), nppIconSize());
            btn.image   = icon;
            btn.toolTip = pti[@"tooltip"];
            btn.tag     = [pti[@"cmdID"] intValue];
            btn.target  = self;
            btn.action  = @selector(pluginToolbarAction:);
            // No btn.identifier — see -makePluginGroupToolbarItemForKey:; plugin icons
            // are refreshed by -_refreshPluginToolbarIcons (which matches kTBPluginSegPrefix).
            [container addSubview:btn];
            x += kBtnSize;
            j++;
        }

        if (drawTrailing) {
            x += kSepInner;
            [container addSubview:[[NppSeparatorView alloc]
                initWithFrame:NSMakeRect(x, 0, 1, kBtnSize)]];
            x += 1 + kSepOuter;
        }
        prevDrewTrailing = drawTrailing;
        firstInItem = NO;
    }

    if (x <= 0) return nil;
    NSRect cf = container.frame; cf.size.width = x; container.frame = cf;

    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    item.view    = container;
    item.minSize = NSMakeSize(x, kBtnSize);
    item.maxSize = NSMakeSize(x, kBtnSize);
    item.label   = @"Plugins";
    // menuFormRepresentation is set by the caller -makePluginSegmentItemStartingAt:
    // (single "Plugins" overflow menu on the last segment; hidden on the rest).
    return item;
}

// Try `filename` against each directory in `dirs` in order. Returns the
// first NSImage that loads, or nil if none of the candidate paths resolve
// to a readable image. Used by the plugin-icon resolver below to probe
// the plugin's root folder first and its resources/ subfolder second.
static NSImage *_loadPluginIconFromDirs(NSArray<NSString *> *dirs, NSString *filename) {
    if (filename.length == 0) return nil;
    for (NSString *dir in dirs) {
        if (dir.length == 0) continue;
        NSString *path = [dir stringByAppendingPathComponent:filename];
        NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
        if (img) return img;
    }
    return nil;
}

// Resolve a plugin's toolbar icon based on the current dark-mode state.
//
// Each candidate filename is probed first in `<pluginDir>/` and then in
// `<pluginDir>/resources/`. Plugin root takes precedence — every plugin
// shipped today with icons in root keeps working byte-for-byte. Plugins
// that organise their assets under `resources/` (e.g. NppBeads,
// NppJsonViewer) work without needing a duplicate copy at root.
//
// Lookup order (first hit wins):
//   1. Dark mode + iconHint   →  <base>_dark.<ext>
//                                e.g. iconHint="myicon.png" → "myicon_dark.png"
//   2.                        →  <iconHint>
//   3. Dark mode (no hint)    →  toolbar_dark.png
//   4.                        →  toolbar.png
//
// Plugins that ship a single icon (just toolbar.png) keep working unchanged.
// Plugins that drop a second `toolbar_dark.png` next to it automatically get
// dark-mode-aware icons. No plugin source changes required.
- (nullable NSImage *)_resolvePluginToolbarIconForDir:(NSString *)pluginDir
                                                 hint:(nullable NSString *)iconHint
{
    if (pluginDir.length == 0) return nil;
    BOOL isDark = [NppThemeManager shared].isDark;

    // Search dirs ordered by precedence. Plugin root first preserves the
    // existing behaviour for every plugin shipped today (their icons live
    // at root); resources/ second is purely additive — a new fallback
    // location, no path removed.
    NSArray<NSString *> *dirs = @[
        pluginDir,
        [pluginDir stringByAppendingPathComponent:@"resources"],
    ];

    NSImage *icon = nil;

    if (iconHint.length > 0) {
        if (isDark) {
            NSString *base = iconHint.stringByDeletingPathExtension;
            NSString *ext  = iconHint.pathExtension;
            NSString *darkName = ext.length
                ? [NSString stringWithFormat:@"%@_dark.%@", base, ext]
                : [NSString stringWithFormat:@"%@_dark", base];
            icon = _loadPluginIconFromDirs(dirs, darkName);
        }
        if (!icon) icon = _loadPluginIconFromDirs(dirs, iconHint);
    }

    if (!icon) {
        if (isDark) icon = _loadPluginIconFromDirs(dirs, @"toolbar_dark.png");
        if (!icon)  icon = _loadPluginIconFromDirs(dirs, @"toolbar.png");
    }

    if (icon) {
        icon.size = NSMakeSize(nppIconSize(), nppIconSize());
        // Extend toolbar colorization to plugin icons when the user opts in.
        if ([[NSUserDefaults standardUserDefaults] boolForKey:kPrefToolbarColorPlugins]) {
            icon = _nppColorizeToolbarImage(icon);
            if (icon) icon.size = NSMakeSize(nppIconSize(), nppIconSize());
        }
    }
    return icon;
}

// Re-resolve every plugin toolbar icon for the current appearance and update
// the live NSButton.image so a dark/light flip is reflected without restart.
// Entries that lack a stored pluginDir (legacy paths that pre-date Path A,
// if any survive) are skipped — they keep whatever icon they were given.
- (void)_refreshPluginToolbarIcons {
    if (!_pluginToolbarItems.count) return;

    NSToolbar *toolbar = self.window.toolbar;

    // Re-resolve every plugin icon for the current appearance. The resolver also
    // re-applies the toolbar colorization prefs, so this covers both the
    // dark/light flip and the "colorize plugin icons" preference change.
    for (NSMutableDictionary *pti in _pluginToolbarItems) {
        NSString *pluginDir = pti[@"pluginDir"];
        if (pluginDir.length == 0) continue;
        NSImage *newIcon = [self _resolvePluginToolbarIconForDir:pluginDir hint:pti[@"iconHint"]];
        if (newIcon) pti[@"icon"] = newIcon;
    }

    // cmdID → freshly-resolved icon, for updating the live buttons below.
    NSMutableDictionary<NSNumber *, NSImage *> *iconByCmd = [NSMutableDictionary dictionary];
    for (NSDictionary *pti in _pluginToolbarItems)
        if (pti[@"icon"]) iconByCmd[pti[@"cmdID"]] = pti[@"icon"];

    // Update live buttons. A plugin button lives either as a plugin item's view
    // directly (user-config mode: "TB_Plugin_<cmdID>") or as a subview of a
    // plugin-group container (default mode). Both carry btn.tag == cmdID. Items
    // collapsed into the overflow chevron aren't in -items; their cached icon is
    // picked up on the next layout pass via the builders.
    for (NSToolbarItem *item in toolbar.items) {
        NSString *ident = item.itemIdentifier;
        if (!([ident hasPrefix:kTBPluginSegPrefix] ||
              [ident hasPrefix:kTBPluginGroupPrefix] || [ident hasPrefix:@"TB_Plugin_"]))
            continue;

        NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
        if ([item.view isKindOfClass:[NSButton class]]) {
            [buttons addObject:(NSButton *)item.view];
        } else {
            for (NSView *sub in item.view.subviews)
                if ([sub isKindOfClass:[NSButton class]]) [buttons addObject:(NSButton *)sub];
        }
        for (NSButton *btn in buttons) {
            NSImage *icon = iconByCmd[@(btn.tag)];
            if (!icon) continue;
            icon.size = NSMakeSize(nppIconSize(), nppIconSize());
            btn.image = icon;
        }
    }
}

- (NSToolbarItem *)makePluginToolbarItem:(NSDictionary *)pti {
    const CGFloat kBtnSize = nppBtnSize();

    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:pti[@"id"]];

    // NppToolbarButton (not plain NSButton) so plugin buttons get the same
    // hover/pressed rounded-rect feedback as built-in toolbar items. The
    // base class wires up its own NSTrackingArea + theme-aware drawRect:
    // in -initWithFrame:, so target/action/image/tag/toolTip below stay
    // identical — only the visual feedback changes.
    NppToolbarButton *btn = [[NppToolbarButton alloc] initWithFrame:NSMakeRect(0, 0, kBtnSize, kBtnSize)];
    btn.image = pti[@"icon"];
    btn.image.size = NSMakeSize(nppIconSize(), nppIconSize());
    btn.toolTip = pti[@"tooltip"];
    btn.tag = [pti[@"cmdID"] intValue];
    btn.target = self;
    btn.action = @selector(pluginToolbarAction:);

    item.view = btn;
    item.label = pti[@"tooltip"];
    item.toolTip = pti[@"tooltip"];
    item.minSize = NSMakeSize(kBtnSize, kBtnSize);
    item.maxSize = NSMakeSize(kBtnSize, kBtnSize);

    // Overflow-menu mirror. When the window is too narrow to fit every
    // toolbar item AppKit pushes extras into a ">>" chevron popup and
    // auto-generates a menu item for each. Without menuFormRepresentation
    // the auto-generated item has NO target/action — clicks do nothing.
    // Wiring an explicit NSMenuItem with the same target+action+tag as
    // the button restores the click behavior so pluginToolbarAction:
    // fires correctly (it reads [sender tag] which NSMenuItem supports).
    NSString *menuTitle = pti[@"tooltip"] ?: (pti[@"id"] ?: @"");
    NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:menuTitle
                                                 action:@selector(pluginToolbarAction:)
                                          keyEquivalent:@""];
    mi.target = self;
    mi.tag    = [pti[@"cmdID"] intValue];
    item.menuFormRepresentation = mi;

    return item;
}

- (void)pluginToolbarAction:(id)sender {
    int cmdID = (int)[sender tag];
    [[NppPluginManager shared] runPluginCommandWithID:cmdID];
}

static NSToolbarItemIdentifier const kTBUserConfig = @"TB_UserConfig";

// YES when the toolbar should render the Tahoe (Liquid Glass) profile. Read at
// toolbar-build time; resolved by NppThemeManager.effectiveAppearanceStyle
// (Classic by default — see Step 2 of the Liquid Glass RFC).
- (BOOL)_toolbarUsesTahoe {
    return [NppThemeManager shared].effectiveAppearanceStyle == NppAppearanceTahoe;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)tb {
    if ([self _toolbarUsesTahoe]) return [self _tahoeDefaultItemIdentifiers:tb];
    return [self _classicDefaultItemIdentifiers:tb];
}

#pragma mark - Tahoe toolbar group model (Liquid Glass)

// Convert the static default group table (array-of-arrays) into the dict-form
// model TahoeToolbarConfig uses (kind=builtin). The id literals live ONLY in
// tahoeToolbarGroups() — this is the single source, reshaped for the config layer.
static NSArray<NSDictionary *> *_tahoeDefaultBuiltinGroupDicts(void) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSArray *g in tahoeToolbarGroups())
        [out addObject:@{ @"label": g[0], @"kind": @"builtin",
                          @"primary": g[1], @"overflow": g[2], @"hidden": @[] }];
    return out;
}

// Map of built-in button id → display name, from toolbarDescriptors().
static NSDictionary<NSString *, NSString *> *_tahoeButtonDisplayNames(void) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSArray *d in toolbarDescriptors()) m[d[0]] = d[1];
    return m;
}

// Default classification of the CURRENT plugin items into a "Plugins" group dict
// (mirrors the legacy curated-tooltip heuristic). Used only when first
// materializing the file; thereafter the file is authoritative.
- (NSDictionary *)_tahoeDefaultPluginsGroupDict {
    static NSArray<NSString *> *kPrimaryTips = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kPrimaryTips = @[ @"Compare", @"Clear Active Compare",
                          @"Spell Check Document Automatically",
                          @"Show Beads panel", @"Toggle Markdown Panel" ];
    });
    NSMutableArray<NSString *> *primary  = [NSMutableArray array];
    NSMutableArray<NSString *> *overflow = [NSMutableArray array];
    for (NSDictionary *pti in _pluginToolbarItems) {
        NSString *tip = pti[@"tooltip"] ?: @"";
        if (!tip.length) continue;
        BOOL isPrimary = NO;
        for (NSString *p in kPrimaryTips)
            if ([tip caseInsensitiveCompare:p] == NSOrderedSame) { isPrimary = YES; break; }
        [(isPrimary ? primary : overflow) addObject:tip];
    }
    if (primary.count == 0 && overflow.count > 0) {
        NSUInteger n = MIN((NSUInteger)3, overflow.count);
        primary  = [[overflow subarrayWithRange:NSMakeRange(0, n)] mutableCopy];
        overflow = [[overflow subarrayWithRange:NSMakeRange(n, overflow.count - n)] mutableCopy];
    }
    return @{ @"label": @"Plugins", @"kind": @"plugins",
              @"primary": primary, @"overflow": overflow, @"hidden": @[] };
}

// The plugins group dict in the current model (or nil).
- (NSDictionary *)_tahoePluginsGroup {
    for (NSDictionary *g in _tahoeModel)
        if ([g[@"kind"] isEqualToString:@"plugins"]) return g;
    return nil;
}

// Load (or materialize) the Tahoe group model + publish the catalog the
// Preferences editor reads. Called from buildToolbar (Tahoe only).
- (void)_loadTahoeToolbarModel {
    // Publish defaults + display names for the editor (single source of truth).
    [TahoeToolbarConfig setDefaultBuiltinGroups:_tahoeDefaultBuiltinGroupDicts()];
    [TahoeToolbarConfig setButtonDisplayNames:_tahoeButtonDisplayNames()];

    NSArray<NSDictionary *> *model = [TahoeToolbarConfig load];
    if (!model) {
        // First Tahoe use (or after Reset): defaults + current plugins, persisted.
        NSMutableArray *m = [_tahoeDefaultBuiltinGroupDicts() mutableCopy];
        [m addObject:[self _tahoeDefaultPluginsGroupDict]];
        model = m;
        [TahoeToolbarConfig saveModel:model];
    }
    _tahoeModel = model;
}

// Append newly-registered plugin command names (to the Plugins overflow) that
// aren't already classified; missing plugins are kept-but-skipped. Persists +
// returns YES if the model changed.
- (BOOL)_reconcileTahoePluginsIfNeeded {
    if (!_tahoeModel) return NO;
    NSMutableArray<NSDictionary *> *model = [_tahoeModel mutableCopy];
    NSInteger idx = -1;
    NSMutableDictionary *plug = nil;
    for (NSInteger i = 0; i < (NSInteger)model.count; i++)
        if ([model[i][@"kind"] isEqualToString:@"plugins"]) {
            idx = i; plug = [model[i] mutableCopy]; break;
        }
    if (!plug) plug = [[self _tahoeDefaultPluginsGroupDict] mutableCopy];

    BOOL changed = NO;
    if (![plug[@"customized"] boolValue]) {
        // Not yet customized by the user: re-derive the curated default split over
        // the CURRENT live plugin set. Plugins register one-by-one at startup with
        // no "all done" callback, so re-curating on each call keeps the default
        // correct as more plugins arrive (instead of freezing an early partial set).
        NSDictionary *fresh = [self _tahoeDefaultPluginsGroupDict];
        if (![(plug[@"primary"]  ?: @[]) isEqualToArray:fresh[@"primary"]] ||
            ![(plug[@"overflow"] ?: @[]) isEqualToArray:fresh[@"overflow"]]) {
            plug = [fresh mutableCopy];   // stays un-customized
            changed = YES;
        }
    } else {
        // User has taken over: only APPEND genuinely new plugin commands (to
        // overflow); preserve their arrangement. Missing plugins stay (skipped).
        NSMutableSet<NSString *> *known = [NSMutableSet set];
        for (NSString *s in @[@"primary", @"overflow", @"hidden"])
            [known addObjectsFromArray:(plug[s] ?: @[])];
        NSMutableArray<NSString *> *overflow = [(plug[@"overflow"] ?: @[]) mutableCopy];
        for (NSDictionary *pti in _pluginToolbarItems) {
            NSString *tip = pti[@"tooltip"] ?: @"";
            if (!tip.length || [known containsObject:tip]) continue;
            [overflow addObject:tip];
            [known addObject:tip];
            changed = YES;
        }
        plug[@"overflow"] = overflow;
    }
    if (!changed) return NO;

    if (idx >= 0) model[idx] = plug; else [model addObject:plug];
    _tahoeModel = model;
    [TahoeToolbarConfig saveModel:model];
    return YES;
}

// Tahoe profile: one capsule group per built-in cluster (from _tahoeModel),
// then the "Plugins" capsule (if any plugins have registered), flexible space, and
// the tab controls.
- (NSArray<NSToolbarItemIdentifier> *)_tahoeDefaultItemIdentifiers:(NSToolbar *)tb {
    if (!_tahoeModel) [self _loadTahoeToolbarModel];
    NSMutableArray<NSToolbarItemIdentifier> *ids = [NSMutableArray array];
    // A system Space item BETWEEN each group breaks the macOS-26 auto-grouping that
    // otherwise wraps all adjacent items in one enclosing glass bar, so each pill
    // stands alone (and the space provides the visible gap between pills).
    BOOL first = YES;
    for (NSDictionary *g in _tahoeModel) {
        if (![g[@"kind"] isEqualToString:@"builtin"]) continue;
        // Skip a group whose buttons are all hidden (nothing to show).
        if (((NSArray *)g[@"primary"]).count == 0 && ((NSArray *)g[@"overflow"]).count == 0)
            continue;
        if (!first) [ids addObject:NSToolbarSpaceItemIdentifier];
        first = NO;
        [ids addObject:[kTBTahoeGroupPrefix stringByAppendingString:g[@"label"]]];
    }
    if (_pluginToolbarItems.count > 0) {
        [ids addObject:NSToolbarSpaceItemIdentifier];
        [ids addObject:kTBTahoePluginsGroup];
    }
    [ids addObject:NSToolbarFlexibleSpaceItemIdentifier];
    [ids addObject:kTBTabControls];
    return ids;
}

// Classic profile (current default): today's group layout.
- (NSArray<NSToolbarItemIdentifier> *)_classicDefaultItemIdentifiers:(NSToolbar *)tb {
    // When user has a custom toolbar config, use a single dynamic item
    // containing all standard + plugin buttons in XML order
    if ([_toolbarConfig[@"hasUserConfig"] boolValue]) {
        return @[kTBUserConfig,
                 NSToolbarFlexibleSpaceItemIdentifier,
                 kTBTabControls];
    }
    return @[kTBGroup1,
             kTBGroup2,
             kTBGroup3,
             kTBGroup4,
             kTBGroup5,
             kTBGroup6,   // scroll sync
             kTBGroup7,   // view toggles (wrap, allchars, indent guide)
             kTBGroup8,   // panels
             kTBGroup9,   // monitoring
             kTBGroup10,  // macro (no trailing separator)
             NSToolbarFlexibleSpaceItemIdentifier,
             kTBTabControls];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)tb {
    return [self toolbarDefaultItemIdentifiers:tb];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)tb
     itemForItemIdentifier:(NSToolbarItemIdentifier)ident
 willBeInsertedIntoToolbar:(BOOL)flag {
    if ([self _toolbarUsesTahoe]) return [self _tahoeToolbarItemForIdentifier:ident];
    NSToolbarItem *item = [self _classicToolbarItemForIdentifier:ident];
    // The macOS-26 SDK gives every NSToolbarItem a bordered "Liquid Glass" capsule by
    // default, and adjacent items merge into one white tray. Classic mode must stay
    // flat like Sequoia, so strip the per-item background here — this covers every
    // Classic factory in one place. Harmless on pre-26 SDKs (no pill) and on nil.
    // Only the Classic path is touched; the Tahoe path is intentionally left as-is.
    item.bordered = NO;
    return item;
}

// Tahoe profile: build a capsule group for each semantic cluster + the Plugins
// capsule; reuse the Classic tab-controls item; fall back to Classic otherwise.
- (NSToolbarItem *)_tahoeToolbarItemForIdentifier:(NSToolbarItemIdentifier)ident {
    if ([ident isEqualToString:kTBTabControls])
        return [self makeTabControlsToolbarItem];
    if ([ident isEqualToString:kTBTahoePluginsGroup])
        return [self makeTahoePluginGroupToolbarItem:ident];
    if ([ident hasPrefix:kTBTahoeGroupPrefix]) {
        NSString *label = [ident substringFromIndex:kTBTahoeGroupPrefix.length];
        if (!_tahoeModel) [self _loadTahoeToolbarModel];
        for (NSDictionary *g in _tahoeModel)
            if ([g[@"kind"] isEqualToString:@"builtin"] && [g[@"label"] isEqualToString:label])
                return [self makeTahoeGroupToolbarItem:ident label:label
                                               primary:g[@"primary"] overflow:g[@"overflow"]];
        return nil;
    }
    return [self _classicToolbarItemForIdentifier:ident];
}

// Build one Tahoe NSToolbarItem subitem (current PNG icon + label) for a button id.
// Build one Tahoe group as an NppTahoeGroupView (Option A): a rounded-rect capsule
// with the PRIMARY icon buttons and the group label beneath; when overflow exists,
// the label carries a ▾ that pops a menu of the hidden items. Custom-drawn so the
// dropdown lives on the label (no separate ellipsis button). Respects the
// toolbar-config hidden-button set.
- (NSToolbarItem *)makeTahoeGroupToolbarItem:(NSString *)groupIdent
                                       label:(NSString *)groupLabel
                                     primary:(NSArray *)primaryIds
                                    overflow:(NSArray *)overflowIds {
    NSMutableDictionary *descMap = [NSMutableDictionary dictionary];
    for (NSArray *d in toolbarDescriptors()) descMap[d[0]] = d;
    NSSet *hiddenIDs = _toolbarConfig[@"hiddenIDs"];
    const CGFloat iconSz = [NppThemeManager shared].toolbarMetrics.iconSize;

    // Primary icon buttons (reuse NppToolbarButton for hover feedback).
    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    for (NSString *btnId in primaryIds) {
        if ([hiddenIDs containsObject:btnId]) continue;
        NSArray *desc = descMap[btnId];
        if (!desc) continue;
        NppToolbarButton *b = [[NppToolbarButton alloc]
            initWithFrame:NSMakeRect(0, 0, kTGBtn, kTGBtn)];
        NSImage *img = nppToolbarIcon(desc[3]);
        if (img) { img.size = NSMakeSize(iconSz, iconSz); b.image = img; }
        b.toolTip = desc[2];
        b.target  = self;
        b.action  = NSSelectorFromString(desc[4]);
        [buttons addObject:b];
    }

    // Overflow menu (the hidden items behind the label's ▾).
    NSMenu *menu = nil;
    if (overflowIds.count > 0) {
        menu = [[NSMenu alloc] initWithTitle:groupLabel];
        for (NSString *btnId in overflowIds) {
            if ([hiddenIDs containsObject:btnId]) continue;
            NSArray *desc = descMap[btnId];
            if (!desc) continue;
            NSMenuItem *mi = [[NSMenuItem alloc]
                initWithTitle:desc[1] action:NSSelectorFromString(desc[4]) keyEquivalent:@""];
            mi.target = self;
            NSImage *mIcon = nppToolbarIcon(desc[3]);
            if (mIcon) { mIcon.size = NSMakeSize(16, 16); mi.image = mIcon; }
            [menu addItem:mi];
        }
        if (menu.numberOfItems == 0) menu = nil;
    }

    if (buttons.count == 0 && !menu) return nil;

    NppTahoeGroupView *gv = [[NppTahoeGroupView alloc] initWithButtons:buttons
                                                                label:groupLabel
                                                         overflowMenu:menu];
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:groupIdent];
    item.view         = gv;
    item.label        = @"";          // the view draws its own label
    item.paletteLabel = groupLabel;
    item.minSize      = gv.frame.size;
    item.maxSize      = gv.frame.size;
    return item;
}

// The single Tahoe "Plugins" capsule: the first few registered plugin icons shown,
// the rest behind the label's ▾. Plugin buttons fire pluginToolbarAction: via tag
// (cmdID); icons come from the already-resolved pti[@"icon"] (colorization applied).
- (NSToolbarItem *)makeTahoePluginGroupToolbarItem:(NSString *)groupIdent {
    if (_pluginToolbarItems.count == 0) return nil;
    const CGFloat iconSz   = [NppThemeManager shared].toolbarMetrics.iconSize;

    // Classification comes from the Tahoe config's "Plugins" group (user-editable
    // in Preferences ▸ Toolbar). Reconcile first so any newly-registered plugins
    // are recorded (landing in overflow) before we read the split.
    if (!_tahoeModel) [self _loadTahoeToolbarModel];
    [self _reconcileTahoePluginsIfNeeded];
    NSDictionary *pg = [self _tahoePluginsGroup];
    NSArray<NSString *> *primNames = pg[@"primary"]  ?: @[];
    NSArray<NSString *> *overNames = pg[@"overflow"] ?: @[];

    // Live plugin items keyed by command name (tooltip) for ordered lookup.
    NSMutableDictionary<NSString *, NSDictionary *> *byTip = [NSMutableDictionary dictionary];
    for (NSDictionary *pti in _pluginToolbarItems) {
        NSString *t = pti[@"tooltip"] ?: @"";
        if (t.length && !byTip[t]) byTip[t] = pti;
    }
    NSMutableArray<NSDictionary *> *primary  = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *overflow = [NSMutableArray array];
    for (NSString *name in primNames) { NSDictionary *pti = byTip[name]; if (pti) [primary addObject:pti]; }
    for (NSString *name in overNames) { NSDictionary *pti = byTip[name]; if (pti) [overflow addObject:pti]; }
    // Names in the group's <Hidden> list (or absent entirely) are simply not shown.

    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    for (NSDictionary *pti in primary) {
        NppToolbarButton *b = [[NppToolbarButton alloc]
            initWithFrame:NSMakeRect(0, 0, kTGBtn, kTGBtn)];
        NSImage *img = pti[@"icon"];
        if (img) { img.size = NSMakeSize(iconSz, iconSz); b.image = img; }
        b.toolTip = pti[@"tooltip"] ?: (pti[@"id"] ?: @"");
        b.tag     = [pti[@"cmdID"] intValue];
        b.target  = self;
        b.action  = @selector(pluginToolbarAction:);
        [buttons addObject:b];
    }
    NSMenu *menu = nil;
    if (overflow.count > 0) {
        menu = [[NSMenu alloc] initWithTitle:@"Plugins"];
        for (NSDictionary *pti in overflow) {
            NSMenuItem *mi = [[NSMenuItem alloc]
                initWithTitle:(pti[@"tooltip"] ?: (pti[@"id"] ?: @""))
                       action:@selector(pluginToolbarAction:) keyEquivalent:@""];
            mi.target = self;
            mi.tag    = [pti[@"cmdID"] intValue];
            NSImage *mIcon = pti[@"icon"];
            if (mIcon) { NSImage *copy = [mIcon copy]; copy.size = NSMakeSize(16, 16); mi.image = copy; }
            [menu addItem:mi];
        }
    }
    if (buttons.count == 0 && !menu) return nil;

    NppTahoeGroupView *gv = [[NppTahoeGroupView alloc] initWithButtons:buttons
                                                                label:@"Plugins"
                                                         overflowMenu:menu];
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:groupIdent];
    item.view         = gv;
    item.label        = @"";
    item.paletteLabel = @"Plugins";
    item.minSize      = gv.frame.size;
    item.maxSize      = gv.frame.size;
    return item;
}

// Default(Tahoe) mode: rebuild the single Plugins capsule as plugins register
// their icons dynamically. Removes the existing item (and the Space we inserted
// before it) and reinserts both just before the flexible space — the leading
// Space gives the same inter-pill gap the static groups get.
- (void)_rebuildTahoePluginsGroup {
    NSToolbar *tb = self.window.toolbar;
    if (!tb) return;
    for (NSInteger i = (NSInteger)tb.items.count - 1; i >= 0; i--)
        if ([tb.items[i].itemIdentifier isEqualToString:kTBTahoePluginsGroup]) {
            [tb removeItemAtIndex:i];
            if (i - 1 >= 0 &&
                [tb.items[i - 1].itemIdentifier isEqualToString:NSToolbarSpaceItemIdentifier])
                [tb removeItemAtIndex:i - 1];
        }
    if (_pluginToolbarItems.count == 0) return;
    NSInteger insertIdx = tb.items.count;
    for (NSInteger i = 0; i < (NSInteger)tb.items.count; i++)
        if ([tb.items[i].itemIdentifier isEqualToString:NSToolbarFlexibleSpaceItemIdentifier]) {
            insertIdx = i; break;
        }
    [tb insertItemWithItemIdentifier:NSToolbarSpaceItemIdentifier atIndex:insertIdx];
    [tb insertItemWithItemIdentifier:kTBTahoePluginsGroup atIndex:insertIdx + 1];
}

// Classic profile (current default): today's group / plugin item builders.
- (NSToolbarItem *)_classicToolbarItemForIdentifier:(NSToolbarItemIdentifier)ident {
    if ([ident isEqualToString:kTBTabControls])
        return [self makeTabControlsToolbarItem];

    // User-configured toolbar: single item with all visible buttons in XML order
    if ([ident isEqualToString:kTBUserConfig])
        return [self makeUserConfigToolbarItem];

    // Group 7 gets special handling: Word Wrap + All Chars button + dropdown arrow + Indent Guide.
    if ([ident isEqualToString:kTBGroup7])
        return [self makeViewTogglesGroupToolbarItem];

    // Default Classic mode: one item per plugin segment (a run of standalone plugins,
    // or a single multi-icon plugin). Tight within a segment; hides segment-by-segment.
    if ([ident hasPrefix:kTBPluginSegPrefix])
        return [self makePluginSegmentItemStartingAt:
                    [ident substringFromIndex:kTBPluginSegPrefix.length]];

    // Legacy per-plugin-group item (no longer inserted in default mode; kept for safety).
    if ([ident hasPrefix:kTBPluginGroupPrefix])
        return [self makePluginGroupToolbarItemForKey:
                    [ident substringFromIndex:kTBPluginGroupPrefix.length]];

    // Individual plugin items (user-config mode): one item per icon.
    for (NSDictionary *pti in _pluginToolbarItems) {
        if ([pti[@"id"] isEqualToString:ident]) {
            return [self makePluginToolbarItem:pti];
        }
    }

    NSArray *idents = toolbarGroupMap()[ident];
    if (idents) return [self makeGroupToolbarItem:ident identifiers:idents];
    return nil;
}

/// Build a single toolbar item containing all visible buttons from the user's XML config,
/// in document order, with separator lines at default group boundaries.
- (NSToolbarItem *)makeUserConfigToolbarItem {
    const CGFloat kBtnSize = nppBtnSize();
    const CGFloat kSpacing = nppSpacing();
    const CGFloat kSepGap  = nppSepGap();   // total gap for a separator (padL + 1px line + padR)

    NSArray *visibleButtons = _toolbarConfig[@"visibleButtons"];
    if (!visibleButtons.count) return nil;

    // Default group membership: which buttons belong to which group (for separator placement).
    // Buttons at group boundaries get a separator line after the last button of the previous group.
    static NSDictionary *buttonToGroup = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *gmap = toolbarGroupMap();
        NSMutableDictionary *b2g = [NSMutableDictionary dictionary];
        for (NSString *gid in gmap)
            for (NSString *bid in gmap[gid])
                b2g[bid] = gid;
        // Group 7 buttons (handled specially in default mode)
        b2g[kTBWrap] = kTBGroup7;
        b2g[kTBAllChars] = kTBGroup7;
        b2g[kTBIndentGuide] = kTBGroup7;
        buttonToGroup = [b2g copy];
    });

    // Build the descriptor lookup (default 32 + any extra)
    NSMutableDictionary *descMap = [NSMutableDictionary dictionary];
    for (NSArray *desc in toolbarDescriptors()) descMap[desc[0]] = desc;

    NSSet *desatSet = desatToggleIdents();
    NSSet *panelSet = panelToggleIdents();

    // First pass: calculate total width
    NSString *prevGroup = nil;
    CGFloat totalW = 0;
    NSInteger btnCount = 0;
    for (NSDictionary *btn in visibleButtons) {
        NSString *btnId = btn[@"id"];
        NSString *group = buttonToGroup[btnId];
        if (prevGroup && group && ![group isEqualToString:prevGroup])
            totalW += kSepGap;
        else if (btnCount > 0)
            totalW += kSpacing;
        totalW += kBtnSize;
        prevGroup = group ?: prevGroup;
        btnCount++;
    }

    // Second pass: create buttons
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, totalW, kBtnSize)];
    CGFloat x = 0;
    prevGroup = nil;
    btnCount = 0;

    for (NSDictionary *btn in visibleButtons) {
        NSString *btnId = btn[@"id"];
        NSString *action = btn[@"action"];
        NSString *name = btn[@"name"];
        NSString *trigger = btn[@"trigger"];
        NSString *group = buttonToGroup[btnId];

        // Insert separator between groups
        if (prevGroup && group && ![group isEqualToString:prevGroup]) {
            CGFloat sepX = x + 3.0;
            _ToolbarBorderLine *sv = [[_ToolbarBorderLine alloc]
                initWithFrame:NSMakeRect(sepX, 0, 1, kBtnSize)];
            [container addSubview:sv];
            x += kSepGap;
        } else if (btnCount > 0) {
            x += kSpacing;
        }

        // Look up icon: custom icon → default descriptor → system symbol fallback
        NSArray *desc = descMap[btnId];
        NSImage *img = _customToolbarIcon(btnId, _toolbarConfig);
        if (!img && desc) img = nppToolbarIcon(desc[3]);
        if (!img) img = [NSImage imageWithSystemSymbolName:@"square" accessibilityDescription:name];

        // Determine button type
        BOOL isToggle = [trigger isEqualToString:@"toggle"];
        BOOL isDesatToggle = [desatSet containsObject:btnId];
        BOOL isPanelToggle = [panelSet containsObject:btnId];

        NppToolbarButton *button;
        if (isToggle || isDesatToggle || isPanelToggle) {
            NppToggleToolbarButton *tb = [[NppToggleToolbarButton alloc]
                initWithFrame:NSMakeRect(x, 0, kBtnSize, kBtnSize)];
            tb.useBlueHighlight = isPanelToggle || (isToggle && !isDesatToggle);
            button = tb;
        } else {
            button = [[NppToolbarButton alloc]
                initWithFrame:NSMakeRect(x, 0, kBtnSize, kBtnSize)];
        }
        button.image = img;
        button.toolTip = name;
        button.identifier = desc ? desc[3] : btnId; // icon name for dark mode refresh

        // Set action: use the descriptor's action if available, otherwise use the XML action
        SEL sel = NSSelectorFromString(desc ? desc[4] : action);
        button.action = sel;
        button.target = self;

        [container addSubview:button];

        // Store toggle button references for state refresh
        if ([btnId isEqualToString:kTBWrap])         _tbWrap = (NppToggleToolbarButton *)button;
        else if ([btnId isEqualToString:kTBSyncV])   _tbSyncV = (NppToggleToolbarButton *)button;
        else if ([btnId isEqualToString:kTBSyncH])   _tbSyncH = (NppToggleToolbarButton *)button;
        else if ([btnId isEqualToString:kTBMonitor])  _tbMonitor = (NppToggleToolbarButton *)button;
        else if ([btnId isEqualToString:kTBUDL])      _tbUDL = (NppToggleToolbarButton *)button;
        else if ([btnId isEqualToString:kTBDocMap])   _tbDocMap = (NppToggleToolbarButton *)button;
        else if ([btnId isEqualToString:kTBDocList])  _tbDocList = (NppToggleToolbarButton *)button;
        else if ([btnId isEqualToString:kTBFuncList]) _tbFuncList = (NppToggleToolbarButton *)button;
        else if ([btnId isEqualToString:kTBFileBrowser]) _tbFileBrowser = (NppToggleToolbarButton *)button;
        else if ([btnId isEqualToString:kTBIndentGuide]) _tbIndentGuide = (NppToggleToolbarButton *)button;

        x += kBtnSize;
        prevGroup = group ?: prevGroup;
        btnCount++;
    }

    // ── Append visible plugin buttons (from <Plugin> section) ────────────────
    NSArray *visPlugins = _toolbarConfig[@"visiblePluginButtons"];
    if (visPlugins.count) {
        // Separator before plugin section
        if (btnCount > 0) {
            CGFloat sepX = x + 3.0;
            _ToolbarBorderLine *sv = [[_ToolbarBorderLine alloc]
                initWithFrame:NSMakeRect(sepX, 0, 1, kBtnSize)];
            [container addSubview:sv];
            x += kSepGap;
        }
        for (NSDictionary *pb in visPlugins) {
            if (btnCount > 0 && pb != visPlugins[0])
                x += kSpacing;

            int cmdID = [pb[@"cmdID"] intValue];
            NSString *pName = pb[@"name"];

            // Try to find icon from plugin's registered toolbar items
            NSImage *pImg = nil;
            for (NSDictionary *pti in _pluginToolbarItems) {
                if ([pti[@"cmdID"] intValue] == cmdID) {
                    pImg = pti[@"icon"];
                    break;
                }
            }
            // Try custom icon by plugin cmdID
            if (!pImg) pImg = _customToolbarIcon(
                [NSString stringWithFormat:@"Plugin_%d", cmdID], _toolbarConfig);
            // Fallback
            if (!pImg) pImg = [NSImage imageWithSystemSymbolName:@"puzzlepiece"
                                        accessibilityDescription:pName];

            NppToolbarButton *pBtn = [[NppToolbarButton alloc]
                initWithFrame:NSMakeRect(x, 0, kBtnSize, kBtnSize)];
            pBtn.image = pImg;
            pBtn.toolTip = pName;
            pBtn.tag = cmdID;
            pBtn.target = self;
            pBtn.action = @selector(pluginToolbarAction:);
            [container addSubview:pBtn];

            x += kBtnSize;
            btnCount++;
        }
    }

    // Resize container to fit all buttons
    NSRect cf = container.frame;
    cf.size.width = x;
    container.frame = cf;

    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:kTBUserConfig];
    item.view = container;
    item.minSize = NSMakeSize(x, kBtnSize);
    item.maxSize = NSMakeSize(x, kBtnSize);
    return item;
}

// Whether this group should have a trailing separator line.
static BOOL groupHasTrailingSep(NSString *ident) {
    return ![ident isEqualToString:kTBGroup10]; // all groups except the last macro group
}

// Pack a set of buttons into a single NSToolbarItem view with 1pt spacing.
- (NSToolbarItem *)makeGroupToolbarItem:(NSString *)ident identifiers:(NSArray *)idents {
    const CGFloat kBtnSize = nppBtnSize();
    const CGFloat kSpacing = nppSpacing();
    static const CGFloat kSepPadL =  5.0; // padding left of separator (cosmetic)
    static const CGFloat kSepPadR = -4.0; // negative to compensate NSToolbar inter-item gap

    // Filter out hidden buttons from toolbar config
    NSSet *hiddenIDs = _toolbarConfig[@"hiddenIDs"];
    if (hiddenIDs.count) {
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSString *btnId in idents)
            if (![hiddenIDs containsObject:btnId]) [filtered addObject:btnId];
        idents = filtered;
    }
    if (idents.count == 0) return nil; // entire group hidden

    // The divider between the standard buttons and the plugin section is now
    // drawn by the first plugin group's leading separator (see
    // -makePluginGroupToolbarItemForKey:), so the macro group keeps its normal
    // "no trailing separator" rule regardless of whether plugins are present.
    BOOL hasSep = groupHasTrailingSep(ident);
    NSInteger n = (NSInteger)idents.count;
    CGFloat buttonsW = n * kBtnSize + (n - 1) * kSpacing;
    CGFloat totalW = buttonsW + (hasSep ? kSepPadL + 1 + kSepPadR : 0);

    NSMutableDictionary *descMap = [NSMutableDictionary dictionary];
    for (NSArray *desc in toolbarDescriptors()) descMap[desc[0]] = desc;

    NSSet *desatSet = desatToggleIdents();
    NSSet *panelSet = panelToggleIdents();

    NSView *groupView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, totalW, kBtnSize)];
    CGFloat x = 0;
    for (NSString *btnIdent in idents) {
        NSArray *desc = descMap[btnIdent];
        if (desc) {
            NSImage *img = _customToolbarIcon(btnIdent, _toolbarConfig);
            if (!img) img = nppToolbarIcon(desc[3]);
            if (!img) img = [NSImage imageWithSystemSymbolName:@"doc" accessibilityDescription:desc[1]];

            BOOL isDesatToggle = [desatSet containsObject:btnIdent];
            BOOL isPanelToggle = [panelSet containsObject:btnIdent];
            NppToolbarButton *btn;

            if (isDesatToggle || isPanelToggle) {
                NppToggleToolbarButton *tb = [[NppToggleToolbarButton alloc]
                    initWithFrame:NSMakeRect(x, 0, kBtnSize, kBtnSize)];
                tb.useBlueHighlight = isPanelToggle;
                tb.toggledOn = isDesatToggle ? NO : NO; // set in _refreshToolbarStates
                btn = tb;
            } else {
                btn = [[NppToolbarButton alloc]
                    initWithFrame:NSMakeRect(x, 0, kBtnSize, kBtnSize)];
            }
            btn.image   = img;
            btn.action  = NSSelectorFromString(desc[4]);
            btn.target  = self;
            btn.toolTip = desc[2];
            btn.identifier = desc[3]; // store icon filename for dark mode refresh
            [groupView addSubview:btn];

            // Store references for toggle state refresh
            if ([btnIdent isEqualToString:kTBWrap])        _tbWrap        = (NppToggleToolbarButton *)btn;
            else if ([btnIdent isEqualToString:kTBSyncV])       _tbSyncV       = (NppToggleToolbarButton *)btn;
            else if ([btnIdent isEqualToString:kTBSyncH])  _tbSyncH       = (NppToggleToolbarButton *)btn;
            else if ([btnIdent isEqualToString:kTBMonitor]) _tbMonitor     = (NppToggleToolbarButton *)btn;
            else if ([btnIdent isEqualToString:kTBUDL])     _tbUDL         = (NppToggleToolbarButton *)btn;
            else if ([btnIdent isEqualToString:kTBDocMap])  _tbDocMap      = (NppToggleToolbarButton *)btn;
            else if ([btnIdent isEqualToString:kTBDocList]) _tbDocList     = (NppToggleToolbarButton *)btn;
            else if ([btnIdent isEqualToString:kTBFuncList])_tbFuncList    = (NppToggleToolbarButton *)btn;
            else if ([btnIdent isEqualToString:kTBFileBrowser]) _tbFileBrowser = (NppToggleToolbarButton *)btn;
            else if ([btnIdent isEqualToString:kTBStartRecord]) _tbStartRecord = btn;
            else if ([btnIdent isEqualToString:kTBStopRecord])  _tbStopRecord  = btn;
            else if ([btnIdent isEqualToString:kTBPlayRecord])  _tbPlayRecord  = btn;
            else if ([btnIdent isEqualToString:kTBPlayRecordM]) _tbPlayRecordM = btn;
            else if ([btnIdent isEqualToString:kTBSaveRecord])  _tbSaveRecord  = btn;
        }
        x += kBtnSize + kSpacing;
    }

    // Append trailing separator line inside the group view
    if (hasSep) {
        CGFloat sepX = buttonsW + kSepPadL;
        NppSeparatorView *sv = [[NppSeparatorView alloc]
            initWithFrame:NSMakeRect(sepX, 0, 1, kBtnSize)];
        [groupView addSubview:sv];
    }

    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    item.view    = groupView;
    item.minSize = NSMakeSize(totalW, kBtnSize);
    item.maxSize = NSMakeSize(totalW, kBtnSize);
    return item;
}

// Group 7: Word Wrap | [Show All Characters + dropdown arrow] | Indent Guide
- (NSToolbarItem *)makeViewTogglesGroupToolbarItem {
    const CGFloat kBtnSize  = nppBtnSize();
    const CGFloat kDropW    = nppDropArrowW();
    const CGFloat kGap      = nppSpacing();
    const CGFloat kInnerGap = nppInnerGap();   // gap between chars button and dropdown arrow
    static const CGFloat kSepPadL = 5.0;       // cosmetic, not size-dependent
    static const CGFloat kSepPadR = -4.0;
    CGFloat hoverW  = kBtnSize + kInnerGap + kDropW;
    CGFloat buttonsW = kBtnSize + kGap + hoverW + kGap + kBtnSize; // wrap + allchars group + indent
    CGFloat totalW  = buttonsW + kSepPadL + 1 + kSepPadR; // + trailing separator

    NSView *outer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, totalW, kBtnSize)];
    CGFloat x = 0;

    // Word Wrap — toggle with blue highlight
    NppToggleToolbarButton *wrapBtn = [[NppToggleToolbarButton alloc]
        initWithFrame:NSMakeRect(x, 0, kBtnSize, kBtnSize)];
    wrapBtn.image   = nppToolbarIcon(@"wrap");
    wrapBtn.action  = @selector(toggleWordWrap:);
    wrapBtn.target  = self;
    wrapBtn.toolTip = [[NppLocalizer shared] translate:@"Toggle Word Wrap"];
    wrapBtn.useBlueHighlight = YES;
    [outer addSubview:wrapBtn];
    _tbWrap = wrapBtn;
    x += kBtnSize + kGap;

    // Hover group: All Characters button + dropdown arrow share one highlight
    _AllCharsHoverGroup *hoverGroup = [[_AllCharsHoverGroup alloc]
        initWithFrame:NSMakeRect(x, 0, hoverW, kBtnSize)];

    _FlatImgButton *charsBtn = [[_FlatImgButton alloc]
        initWithFrame:NSMakeRect(0, 0, kBtnSize, kBtnSize)];
    [charsBtn setBordered:NO];
    [charsBtn setButtonType:NSButtonTypeMomentaryChange];
    [charsBtn setImageScaling:NSImageScaleProportionallyUpOrDown];
    charsBtn.image   = nppToolbarIcon(@"allChars");
    charsBtn.action  = @selector(toggleShowAllChars:);
    charsBtn.target  = self;
    charsBtn.toolTip = [[NppLocalizer shared] translate:@"Show All Characters"];
    [hoverGroup addSubview:charsBtn];
    _tbAllChars = charsBtn;  // cached so dark-mode-change can refresh its image

    _DropArrowButton *dropBtn = [[_DropArrowButton alloc]
        initWithFrame:NSMakeRect(kBtnSize + kInnerGap, 0, kDropW, kBtnSize)];
    [dropBtn setBordered:NO];
    dropBtn.buttonType = NSButtonTypeMomentaryChange;
    dropBtn.title      = @"";   // drawn manually in drawRect:
    dropBtn.toolTip    = [[NppLocalizer shared] translate:@"Show Characters Options"];
    dropBtn.action     = @selector(_showAllCharsDropdown:);
    dropBtn.target     = self;
    [hoverGroup addSubview:dropBtn];

    [outer addSubview:hoverGroup];
    _tbAllCharsHoverGroup = hoverGroup;
    x += hoverW + kGap;

    // Indent Guide — toggle with desaturation
    NppToggleToolbarButton *indentBtn = [[NppToggleToolbarButton alloc]
        initWithFrame:NSMakeRect(x, 0, kBtnSize, kBtnSize)];
    indentBtn.image   = nppToolbarIcon(@"indentGuide");
    indentBtn.action  = @selector(toggleIndentGuides:);
    indentBtn.target  = self;
    indentBtn.toolTip = [[NppLocalizer shared] translate:@"Toggle Indent Guide"];
    indentBtn.useBlueHighlight = YES;
    indentBtn.toggledOn = _showIndentGuides;
    [outer addSubview:indentBtn];
    _tbIndentGuide = indentBtn;

    // Trailing separator
    NppSeparatorView *sv = [[NppSeparatorView alloc]
        initWithFrame:NSMakeRect(buttonsW + kSepPadL, 0, 1, kBtnSize)];
    [outer addSubview:sv];

    NSToolbarItem *it = [[NSToolbarItem alloc] initWithItemIdentifier:kTBGroup7];
    it.view    = outer;
    it.minSize = NSMakeSize(totalW, kBtnSize);
    it.maxSize = NSMakeSize(totalW, kBtnSize);
    return it;
}

// Builds the right-aligned +  ▾  × tab-control group.
- (NSToolbarItem *)makeTabControlsToolbarItem {
    static const CGFloat kW = 28.0, kH = 28.0, kSpc = 1.0;
    CGFloat totalW = 3 * kW + 2 * kSpc;

    NSView *groupView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, totalW, kH)];

    struct { NSString *title; NSString *tip; SEL action; } btns[3] = {
        { @"+", @"New Tab",         @selector(_tabControlNew:)   },
        { @"▾", @"Tab List",        @selector(_tabControlList:)  },
        { @"×", @"Close Active Tab",@selector(_tabControlClose:) },
    };

    for (int i = 0; i < 3; i++) {
        CGFloat x = i * (kW + kSpc);
        NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(x, 0, kW, kH)];
        [btn setBordered:NO];
        btn.buttonType = NSButtonTypeMomentaryChange;
        btn.title      = btns[i].title;
        btn.font       = [NSFont systemFontOfSize:16 weight:NSFontWeightMedium];
        btn.toolTip    = btns[i].tip;
        btn.action     = btns[i].action;
        btn.target     = self;
        [groupView addSubview:btn];
    }

    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:kTBTabControls];
    item.view    = groupView;
    item.minSize = NSMakeSize(totalW, kH);
    item.maxSize = NSMakeSize(totalW, kH);
    // Tahoe: drop macOS-26's per-item glass tray (the "white pill") so the +/▾/×
    // buttons read plain, like on Sequoia. Gated; no effect under Classic.
    if ([NppThemeManager shared].usesGlassMaterials)
        item.bordered = NO;
    return item;
}

// ── Toolbar toggle state refresh ──────────────────────────────────────────────

- (void)_refreshToolbarStates {
    // Scroll sync (desaturation)
    _tbSyncV.toggledOn = _syncVerticalScrolling;
    _tbSyncH.toggledOn = _syncHorizontalScrolling;
    [_tbSyncV setNeedsDisplay:YES];
    [_tbSyncH setNeedsDisplay:YES];

    // Indent guide (desaturation)
    _tbIndentGuide.toggledOn = _showIndentGuides;
    [_tbIndentGuide setNeedsDisplay:YES];

    // Word Wrap (blue highlight). Read kPrefWordWrap directly rather
    // than the focused editor's wordWrapEnabled to avoid a notification
    // observer-order race: when the user toggles the Preferences > Editor
    // checkbox, prefChanged: posts NPPPreferencesChanged and MWC's
    // observer (registered before any EditorView's observer) runs first.
    // At that moment the editor's _wordWrapEnabled ivar still holds the
    // old value because applyPreferencesFromDefaults hasn't run yet on
    // that editor. The pref, however, was written synchronously before
    // the notification was posted, so it's always current. Both UI
    // surfaces (toolbar/menu toggle path and Preferences-pane path)
    // write the pref first, so it's the authoritative cross-source.
    _tbWrap.toggledOn = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefWordWrap];
    [_tbWrap setNeedsDisplay:YES];

    // Panel toggles (blue highlight when panel is visible)
    _tbDocMap.toggledOn      = _docMapPanel && [_sidePanelHost hasPanel:_docMapPanel];
    _tbDocList.toggledOn     = _docListPanel && [_sidePanelHost hasPanel:_docListPanel];
    _tbFuncList.toggledOn    = _funcListPanel && [_sidePanelHost hasPanel:(NSView *)_funcListPanel];
    _tbFileBrowser.toggledOn = _folderTreePanel && [_sidePanelHost hasPanel:_folderTreePanel];
    [_tbDocMap setNeedsDisplay:YES];
    [_tbDocList setNeedsDisplay:YES];
    [_tbFuncList setNeedsDisplay:YES];
    [_tbFileBrowser setNeedsDisplay:YES];
    // UDL doesn't toggle a panel — leave as-is

    // All-Characters group (dark-mode persistent black bg when on). State
    // derives from Scintilla so it stays correct on tab switch.
    if (_tbAllCharsHoverGroup) {
        ScintillaView *acSci = [self currentEditor].scintillaView;
        BOOL acWs  = acSci ? ([acSci message:SCI_GETVIEWWS]  == SCWS_VISIBLEALWAYS) : NO;
        BOOL acEol = acSci ? ([acSci message:SCI_GETVIEWEOL] != 0)                  : NO;
        _tbAllCharsHoverGroup.toggledOn = acWs && acEol;
    }

    // Monitoring toggle
    EditorView *ed = [self currentEditor];
    BOOL hasFile = (ed.filePath.length > 0);
    _tbMonitor.enabled   = hasFile;
    _tbMonitor.toggledOn = hasFile && ed.monitoringMode;
    [_tbMonitor setNeedsDisplay:YES];

    // Macro buttons state
    BOOL recording = ed.isRecordingMacro;
    BOOL hasMacro  = (ed.macroActions.count > 0);
    _tbStartRecord.enabled = !recording;
    _tbStopRecord.enabled  = recording;
    _tbPlayRecord.enabled  = !recording && hasMacro;
    _tbPlayRecordM.enabled = !recording;   // can run saved macros even without current recording
    _tbSaveRecord.enabled  = !recording && hasMacro;
    // Dim disabled macro buttons
    _tbStartRecord.alphaValue = _tbStartRecord.isEnabled ? 1.0 : 0.30;
    _tbStopRecord.alphaValue  = _tbStopRecord.isEnabled  ? 1.0 : 0.30;
    _tbPlayRecord.alphaValue  = _tbPlayRecord.isEnabled  ? 1.0 : 0.30;
    _tbPlayRecordM.alphaValue = _tbPlayRecordM.isEnabled ? 1.0 : 0.30;
    _tbSaveRecord.alphaValue  = _tbSaveRecord.isEnabled  ? 1.0 : 0.30;
}

// ── Tab-control toolbar actions ───────────────────────────────────────────────

- (void)_tabControlNew:(id)sender {
    [_activeTabManager addNewTab];
    [self.window makeFirstResponder:[_activeTabManager currentEditor].scintillaView.content];
}

- (void)_tabControlList:(id)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    // Collect tabs from all three tab managers, prefixing group headers when
    // more than one manager has tabs.
    NSArray<TabManager *> *managers = @[_tabManager, _subTabManagerH, _subTabManagerV];
    NSArray<NSString *>   *labels   = @[@"Main", @"Bottom", @"Right"];

    BOOL multiGroup = NO;
    for (TabManager *tm in managers)
        if (tm.allEditors.count > 0) multiGroup = !multiGroup ? YES : (multiGroup = YES);
    // Only show group headers when more than one group has tabs
    NSUInteger groupsWithTabs = 0;
    for (TabManager *tm in managers) if (tm.allEditors.count) groupsWithTabs++;

    for (NSUInteger g = 0; g < managers.count; g++) {
        TabManager *tm = managers[g];
        if (!tm.allEditors.count) continue;
        if (groupsWithTabs > 1) {
            NSMenuItem *hdr = [[NSMenuItem alloc] initWithTitle:labels[g] action:nil keyEquivalent:@""];
            hdr.enabled = NO;
            [menu addItem:hdr];
        }
        for (EditorView *ed in tm.allEditors) {
            NSString *name = ed.displayName ?: @"Untitled";
            NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:name action:@selector(_tabControlListSelect:) keyEquivalent:@""];
            mi.target = self;
            mi.representedObject = @{ @"editor": ed, @"manager": tm };
            if (ed == tm.currentEditor) mi.state = NSControlStateValueOn;
            [menu addItem:mi];
        }
        if (groupsWithTabs > 1 && g < managers.count - 1)
            [menu addItem:[NSMenuItem separatorItem]];
    }

    // Pop up directly below the ▾ button
    NSButton *btn = (NSButton *)sender;
    NSPoint origin = NSMakePoint(0, -2);
    [menu popUpMenuPositioningItem:nil atLocation:origin inView:btn];
}

- (void)_tabControlListSelect:(NSMenuItem *)sender {
    NSDictionary *info  = sender.representedObject;
    TabManager   *tm    = info[@"manager"];
    EditorView   *ed    = info[@"editor"];
    NSArray      *all   = tm.allEditors;
    NSInteger     idx   = [all indexOfObject:ed];
    if (idx != NSNotFound) {
        _activeTabManager = tm;
        [tm selectTabAtIndex:idx];
        [self.window makeFirstResponder:ed.scintillaView.content];
    }
}

- (void)_tabControlClose:(id)sender {
    [_activeTabManager closeCurrentTab];
}

#pragma mark - Content View Layout

- (void)buildContentView {
    NSView *content = self.window.contentView;
    content.wantsLayer = YES;

    // ── Primary TabManager ─────────────────────────────────────────────────────
    _tabManager = [[TabManager alloc] init];
    _tabManager.delegate = self;
    _activeTabManager = _tabManager;   // primary is default active

    NppTabBar *primaryTabBar = _tabManager.tabBar;
    primaryTabBar.translatesAutoresizingMaskIntoConstraints = NO;
    primaryTabBar.wrapMode = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefTabBarWrap];
    [primaryTabBar setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
    [primaryTabBar setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
    NSView *primaryContentView = _tabManager.contentView;
    primaryContentView.translatesAutoresizingMaskIntoConstraints = NO;
    // Tahoe: round the editor's TOP-RIGHT corner. The white editor area begins
    // below the tab bar, so its top-right is here (not on primaryContainer, whose
    // top edge is the transparent tab strip). Bottom corners are rounded by
    // primaryContainer's clip above. Gated.
    if ([NppThemeManager shared].usesGlassMaterials) {
        primaryContentView.wantsLayer = YES;
        primaryContentView.layer.cornerRadius  = 8.0;
        primaryContentView.layer.masksToBounds = YES;
        primaryContentView.layer.maskedCorners = kCALayerMaxXMaxYCorner;  // top-right only
    }

    // Primary container wraps tab bar + editor content
    NSView *primaryContainer = [[NSView alloc] init];
    primaryContainer.translatesAutoresizingMaskIntoConstraints = NO;
    // Tahoe: round the editor "card" corners (macOS-26 inset content look).
    // Gated — Classic stays full-bleed with square corners.
    if ([NppThemeManager shared].usesGlassMaterials) {
        primaryContainer.wantsLayer = YES;
        primaryContainer.layer.cornerRadius  = 8.0;
        primaryContainer.layer.masksToBounds = YES;
        // Round only the BOTTOM corners of the whole card (its top edge is the
        // transparent tab strip — rounding there is invisible). The editor's
        // top-right is rounded on primaryContentView below (the white area starts
        // beneath the tab bar). (MinY = bottom in this layer.)
        primaryContainer.layer.maskedCorners =
            kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    }
    [primaryContainer addSubview:primaryTabBar];
    [primaryContainer addSubview:primaryContentView];
    // Issue #183: the tab bar's height is held by a swappable constraint so the
    // "Hide tab bar" pref can collapse it to 0 and let the editor reclaim the
    // strip (the editor top is pinned to the tab bar's bottom). Min-height (>= 25,
    // active by default) preserves multi-row wrap; the zero-height constraint
    // (created here, inactive) is swapped in by -_applyTabBarVisibility:.
    _primaryTabBarMinHeight  = [primaryTabBar.heightAnchor constraintGreaterThanOrEqualToConstant:25];
    _primaryTabBarZeroHeight = [primaryTabBar.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [primaryTabBar.topAnchor constraintEqualToAnchor:primaryContainer.topAnchor],
        [primaryTabBar.leadingAnchor constraintEqualToAnchor:primaryContainer.leadingAnchor],
        [primaryTabBar.trailingAnchor constraintEqualToAnchor:primaryContainer.trailingAnchor],
        _primaryTabBarMinHeight,
        [primaryContentView.topAnchor constraintEqualToAnchor:primaryTabBar.bottomAnchor],
        [primaryContentView.leadingAnchor constraintEqualToAnchor:primaryContainer.leadingAnchor],
        [primaryContentView.trailingAnchor constraintEqualToAnchor:primaryContainer.trailingAnchor],
        [primaryContentView.bottomAnchor constraintEqualToAnchor:primaryContainer.bottomAnchor],
    ]];

    // ── Secondary TabManager (second view, starts collapsed) ──────────────────
    _subTabManagerH = [[TabManager alloc] init];
    _subTabManagerH.delegate = self;

    NppTabBar *subTabBar = _subTabManagerH.tabBar;
    subTabBar.translatesAutoresizingMaskIntoConstraints = NO;
    subTabBar.wrapMode = primaryTabBar.wrapMode;
    [subTabBar setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
    [subTabBar setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
    NSView *subContentView = _subTabManagerH.contentView;
    subContentView.translatesAutoresizingMaskIntoConstraints = NO;

    _subEditorContainerH = [[NSView alloc] init];
    _subEditorContainerH.translatesAutoresizingMaskIntoConstraints = NO;
    [_subEditorContainerH addSubview:subTabBar];
    [_subEditorContainerH addSubview:subContentView];
    // #183: swappable height so "Hide tab bar" collapses the bottom split's bar too.
    _subTabBarHMinHeight  = [subTabBar.heightAnchor constraintGreaterThanOrEqualToConstant:25];
    _subTabBarHZeroHeight = [subTabBar.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [subTabBar.topAnchor constraintEqualToAnchor:_subEditorContainerH.topAnchor],
        [subTabBar.leadingAnchor constraintEqualToAnchor:_subEditorContainerH.leadingAnchor],
        [subTabBar.trailingAnchor constraintEqualToAnchor:_subEditorContainerH.trailingAnchor],
        _subTabBarHMinHeight,
        [subContentView.topAnchor constraintEqualToAnchor:subTabBar.bottomAnchor],
        [subContentView.leadingAnchor constraintEqualToAnchor:_subEditorContainerH.leadingAnchor],
        [subContentView.trailingAnchor constraintEqualToAnchor:_subEditorContainerH.trailingAnchor],
        [subContentView.bottomAnchor constraintEqualToAnchor:_subEditorContainerH.bottomAnchor],
    ]];
    _nppTahoeRoundEditorCard(_subEditorContainerH, subContentView);  // Tahoe rounded card (gated)

    // ── Secondary TabManager V (vertical/right view, starts collapsed) ─────────
    _subTabManagerV = [[TabManager alloc] init];
    _subTabManagerV.delegate = self;

    NppTabBar *subTabBarV = _subTabManagerV.tabBar;
    subTabBarV.translatesAutoresizingMaskIntoConstraints = NO;
    subTabBarV.wrapMode = primaryTabBar.wrapMode;
    [subTabBarV setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
    [subTabBarV setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
    NSView *subContentViewV = _subTabManagerV.contentView;
    subContentViewV.translatesAutoresizingMaskIntoConstraints = NO;

    _subEditorContainerV = [[NSView alloc] init];
    _subEditorContainerV.translatesAutoresizingMaskIntoConstraints = NO;
    [_subEditorContainerV addSubview:subTabBarV];
    [_subEditorContainerV addSubview:subContentViewV];
    // #183: swappable height so "Hide tab bar" collapses the right split's bar too.
    _subTabBarVMinHeight  = [subTabBarV.heightAnchor constraintGreaterThanOrEqualToConstant:25];
    _subTabBarVZeroHeight = [subTabBarV.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [subTabBarV.topAnchor constraintEqualToAnchor:_subEditorContainerV.topAnchor],
        [subTabBarV.leadingAnchor constraintEqualToAnchor:_subEditorContainerV.leadingAnchor],
        [subTabBarV.trailingAnchor constraintEqualToAnchor:_subEditorContainerV.trailingAnchor],
        _subTabBarVMinHeight,
        [subContentViewV.topAnchor constraintEqualToAnchor:subTabBarV.bottomAnchor],
        [subContentViewV.leadingAnchor constraintEqualToAnchor:_subEditorContainerV.leadingAnchor],
        [subContentViewV.trailingAnchor constraintEqualToAnchor:_subEditorContainerV.trailingAnchor],
        [subContentViewV.bottomAnchor constraintEqualToAnchor:_subEditorContainerV.bottomAnchor],
    ]];
    _nppTahoeRoundEditorCard(_subEditorContainerV, subContentViewV);  // Tahoe rounded card (gated)

    // #183: apply the persisted "Hide tab bar" state at launch — placed AFTER both
    // secondary tab bars are built so all three bars (primary + H + V) are
    // collapsed/shown together (their constraint ivars exist by this point).
    [self _applyTabBarVisibility:[[NSUserDefaults standardUserDefaults] boolForKey:kPrefHideTabBar]];

    // ── Left/right split between primary and vertical secondary ───────────────
    _vSplitView = [[NppGapSplitView alloc] init];   // Tahoe: 12pt transparent gap between editor panes (gated)
    _vSplitView.vertical = YES;   // left/right split
    _vSplitView.dividerStyle = NSSplitViewDividerStyleThin;
    _vSplitView.delegate = self;
    _vSplitView.translatesAutoresizingMaskIntoConstraints = NO;
    [_vSplitView addSubview:primaryContainer];
    [_vSplitView addSubview:_subEditorContainerV];
    [primaryContainer.widthAnchor constraintGreaterThanOrEqualToConstant:100].active = YES;
    [_subEditorContainerV.widthAnchor constraintGreaterThanOrEqualToConstant:100].active = YES;

    // ── Top/bottom split between _vSplitView and horizontal secondary ─────────
    _hSplitView = [[NppGapSplitView alloc] init];   // Tahoe: 12pt transparent gap between editor panes (gated)
    _hSplitView.vertical = NO;    // top/bottom split
    _hSplitView.dividerStyle = NSSplitViewDividerStyleThin;
    _hSplitView.delegate = self;
    _hSplitView.translatesAutoresizingMaskIntoConstraints = NO;
    [_hSplitView addSubview:_vSplitView];
    [_hSplitView addSubview:_subEditorContainerH];
    [_vSplitView.heightAnchor constraintGreaterThanOrEqualToConstant:100].active = YES;
    [_subEditorContainerH.heightAnchor constraintGreaterThanOrEqualToConstant:100].active = YES;

    // ── Incremental search bar ─────────────────────────────────────────────────
    _incSearchBar = [[IncrementalSearchBar alloc] initWithFrame:NSZeroRect];
    _incSearchBar.translatesAutoresizingMaskIntoConstraints = NO;
    _incSearchBar.hidden = YES;
    _incSearchBar.delegate = self;

    // ── Find panel ─────────────────────────────────────────────────────────────
    _findPanel = [[FindReplacePanel alloc] initWithFrame:NSZeroRect];
    _findPanel.translatesAutoresizingMaskIntoConstraints = NO;
    _findPanel.hidden = YES;
    _findPanel.delegate = self;

    // ── Status bar ─────────────────────────────────────────────────────────────
    _statusBar = [[NSView alloc] init];
    _statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    _statusBar.wantsLayer = YES;
    if ([NppThemeManager shared].usesGlassMaterials) {
        // Tahoe: blend the status bar into the window backdrop — no fill of its
        // own (the content-wide backdrop VFX shows through the clear layer) and,
        // below, no top separator. The status info then reads as sitting at the
        // bottom of the translucent window. Gated — Classic keeps its opaque bar.
        _statusBar.layer.backgroundColor = NSColor.clearColor.CGColor;
    } else {
        _statusBar.layer.backgroundColor = [NppThemeManager shared].statusBarBackground.CGColor;
    }

    NSBox *sep = [[NSBox alloc] init];
    sep.boxType = NSBoxSeparator;
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    sep.hidden = [NppThemeManager shared].usesGlassMaterials;  // Tahoe: no hard top line (blended)
    [_statusBar addSubview:sep];

    _statusLeft  = [self makeStatusLabel:NSTextAlignmentLeft];
    _statusRight = [self makeStatusLabel:NSTextAlignmentRight];
    // Git branch label: right-aligned, muted gray, before _statusRight
    _gitBranchLabel = [self makeStatusLabel:NSTextAlignmentRight];
    _gitBranchLabel.textColor = [NSColor secondaryLabelColor];
    [_statusBar addSubview:_statusLeft];
    [_statusBar addSubview:_statusRight];
    [_statusBar addSubview:_gitBranchLabel];

    // Issue #174: double-clicking the language token in the status bar opens the
    // Language menu (Windows parity). Purely additive — an invisible recognizer
    // on the bar; the status labels and layout are untouched, so the bar looks
    // identical in Classic and Tahoe. The handler hit-tests the language token's
    // x-range so only that part responds.
    NSClickGestureRecognizer *langClick =
        [[NSClickGestureRecognizer alloc] initWithTarget:self
                                                  action:@selector(_statusBarDoubleClicked:)];
    langClick.numberOfClicksRequired = 2;
    langClick.delaysPrimaryMouseButtonEvents = NO;
    [_statusBar addGestureRecognizer:langClick];

    [NSLayoutConstraint activateConstraints:@[
        [sep.topAnchor constraintEqualToAnchor:_statusBar.topAnchor],
        [sep.leadingAnchor constraintEqualToAnchor:_statusBar.leadingAnchor],
        [sep.trailingAnchor constraintEqualToAnchor:_statusBar.trailingAnchor],
        [sep.heightAnchor constraintEqualToConstant:1],
        [_statusLeft.leadingAnchor constraintEqualToAnchor:_statusBar.leadingAnchor constant:8],
        [_statusLeft.centerYAnchor constraintEqualToAnchor:_statusBar.centerYAnchor constant:1],
        [_statusLeft.trailingAnchor constraintLessThanOrEqualToAnchor:_statusBar.centerXAnchor],
        [_statusRight.trailingAnchor constraintEqualToAnchor:_statusBar.trailingAnchor constant:-8],
        [_statusRight.centerYAnchor constraintEqualToAnchor:_statusBar.centerYAnchor constant:1],
        [_statusRight.leadingAnchor constraintGreaterThanOrEqualToAnchor:_statusBar.centerXAnchor],
        [_gitBranchLabel.trailingAnchor constraintEqualToAnchor:_statusRight.leadingAnchor constant:-16],
        [_gitBranchLabel.centerYAnchor constraintEqualToAnchor:_statusBar.centerYAnchor constant:1],
    ]];

    // ── Dark mode observer ──────────────────────────────────────────────────────
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(_darkModeChanged:)
               name:NPPDarkModeChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(_prefsChanged:)
               name:@"NPPPreferencesChanged" object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(_toolbarColorChanged:)
               name:@"NPPToolbarColorChanged" object:nil];
    // Tahoe toolbar group layout edited in Preferences → rebuild the toolbar.
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(_tahoeToolbarConfigChanged:)
               name:NPPTahoeToolbarConfigChanged object:nil];
    // Phase 2: one observer refreshes every open PanelFrame title, so
    // each individual panel no longer needs its own NPPLocalizationChanged
    // subscriber for the title.
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(_refreshOpenPanelTitles)
               name:NPPLocalizationChanged object:nil];
    // Editor right-click context menu — built once from contextMenu.xml using
    // string-keyed lookups against the (already translated) main menu, then
    // cached on _editorContextMenu. A language switch retranslates the main
    // menu but leaves the cached context menu's by-value title copies stale,
    // so it stays in English forever. Rebuild from XML on every language
    // change; -applyEditorContextMenuToAll: discards the cache and re-pushes
    // the fresh menu to every open Scintilla view.
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(applyEditorContextMenuToAll)
               name:NPPLocalizationChanged object:nil];
    // Universal-in-session word wrap. Cross-window broadcast: when ANY
    // MainWindowController toggles wrap, every other one observes here
    // and propagates the new state to its own tab managers, so all
    // editors in all windows stay in sync.
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(_wordWrapSessionChanged:)
               name:@"NPPWordWrapSessionChanged" object:nil];

    // ── Horizontal (left/right) split: views | side panels ────────────────────
    _sidePanelHost = [[SidePanelHost alloc] init];
    _sidePanelHost.translatesAutoresizingMaskIntoConstraints = NO;
    _sidePanelHost.delegate = self;  // receive PanelFrame close callbacks

    _editorSplitView = [[NppGapSplitView alloc] init];   // Tahoe: transparent gap between editor & panel cards (gated)
    _editorSplitView.vertical = YES;
    _editorSplitView.dividerStyle = NSSplitViewDividerStyleThin;
    _editorSplitView.delegate = self;
    _editorSplitView.translatesAutoresizingMaskIntoConstraints = NO;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kPrefDockPanelsOnLeft]) {
        [_editorSplitView addSubview:_sidePanelHost];
        [_editorSplitView addSubview:_hSplitView];
    } else {
        [_editorSplitView addSubview:_hSplitView];
        [_editorSplitView addSubview:_sidePanelHost];
    }
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(_dockPanelsLeftChanged)
               name:@"NPPDockPanelsLeftChanged" object:nil];
    // Tahoe: round the side-panel "card" corners to match the editor card. Gated.
    if ([NppThemeManager shared].usesGlassMaterials) {
        _sidePanelHost.wantsLayer = YES;
        _sidePanelHost.layer.cornerRadius  = 8.0;
        _sidePanelHost.layer.masksToBounds = YES;
    }

    [_hSplitView.widthAnchor constraintGreaterThanOrEqualToConstant:200].active = YES;
    [_sidePanelHost.widthAnchor constraintGreaterThanOrEqualToConstant:150].active = YES;

    // Search results panel (bottom of main window, collapsible)
    _searchResultsPanel = [[SearchResultsPanel alloc] init];
    _searchResultsPanel.delegate = self;

    _searchSplitView = [[NppGapSplitView alloc] init];
    ((NppGapSplitView *)_searchSplitView).tahoeGap = 2.0;  // thin, transparent in Tahoe (no grey divider line)
    _searchSplitView.vertical = NO; // horizontal split: top/bottom
    _searchSplitView.dividerStyle = NSSplitViewDividerStyleThin;
    _searchSplitView.delegate = self;
    _searchSplitView.translatesAutoresizingMaskIntoConstraints = NO;
    [_searchSplitView addSubview:_editorSplitView];
    [_searchSplitView addSubview:_searchResultsPanel];

    // Tahoe: a single translucent window backdrop behind everything. The rounded
    // editor/panel cards (opaque) float on it; the inset margins, the inter-card
    // gap, and the (now-transparent) status bar all show it through — giving the
    // "items sitting on a translucent window" look. Gated — never added in Classic.
    if ([NppThemeManager shared].usesGlassMaterials) {
        // Translucent base (real-HW desktop blur) ...
        NSVisualEffectView *backdrop = [[NSVisualEffectView alloc] init];
        backdrop.translatesAutoresizingMaskIntoConstraints = NO;
        backdrop.material     = NSVisualEffectMaterialUnderWindowBackground;
        backdrop.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        backdrop.state        = NSVisualEffectStateFollowsWindowActiveState;
        [content addSubview:backdrop positioned:NSWindowBelow relativeTo:nil];
        // ... tinted by the #dce7fd → #f5f3f6 diagonal gradient (slightly
        // translucent so the material/desktop shows through → "translucent window").
        NppGradientView *grad = [[NppGradientView alloc] init];
        grad.translatesAutoresizingMaskIntoConstraints = NO;
        grad.wantsLayer  = YES;
        grad.alphaValue  = 0.9;
        [content addSubview:grad positioned:NSWindowAbove relativeTo:backdrop];
        for (NSView *bg in @[backdrop, grad]) {
            [NSLayoutConstraint activateConstraints:@[
                [bg.topAnchor      constraintEqualToAnchor:content.topAnchor],
                [bg.bottomAnchor   constraintEqualToAnchor:content.bottomAnchor],
                [bg.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor],
                [bg.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
            ]];
        }
        // The find panel / incremental search bar collapse to height 0 but their
        // top NSBox separators would still draw a stray 1pt line just above the
        // status bar. Clip them so a 0-height bar shows nothing. Gated.
        _findPanel.layer.masksToBounds   = YES;
        _incSearchBar.layer.masksToBounds = YES;
    }

    for (NSView *v in @[_searchSplitView, _incSearchBar, _findPanel, _statusBar]) {
        [content addSubview:v];
    }

    _incSearchBarHeightConstraint = [_incSearchBar.heightAnchor constraintEqualToConstant:0];
    _findPanelHeightConstraint = [_findPanel.heightAnchor constraintEqualToConstant:0];

    // Tahoe: inset the editor/panel area from the window edges so the rounded
    // cards float on the window background (macOS-26 inset content look). Gated —
    // Classic stays edge-to-edge (insets 0). The find panel / status bar below
    // keep their full-width pins.
    BOOL _tahoeGlass = [NppThemeManager shared].usesGlassMaterials;
    CGFloat edgeInset = _tahoeGlass ? 8.0 : 0.0;
    CGFloat topInset  = _tahoeGlass ? 6.0 : 0.0;

    [NSLayoutConstraint activateConstraints:@[
        // Search split view fills from top to incremental search bar. In Tahoe the
        // content view spans the whole window (FullSizeContentView), so pin the top
        // to contentLayoutGuide (below the titlebar+toolbar) instead of content.top.
        [_searchSplitView.topAnchor constraintEqualToAnchor:(_tahoeGlass ? ((NSLayoutGuide *)self.window.contentLayoutGuide).topAnchor : content.topAnchor) constant:topInset],
        [_searchSplitView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:edgeInset],
        [_searchSplitView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-edgeInset],
        [_searchSplitView.bottomAnchor constraintEqualToAnchor:_incSearchBar.topAnchor constant:(_tahoeGlass ? -6.0 : 0.0)],

        // Incremental search bar (sits between editor and find panel)
        [_incSearchBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_incSearchBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        _incSearchBarHeightConstraint,
        [_incSearchBar.bottomAnchor constraintEqualToAnchor:_findPanel.topAnchor],

        // Find panel
        [_findPanel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_findPanel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        _findPanelHeightConstraint,

        // Status bar at bottom
        [_statusBar.topAnchor constraintEqualToAnchor:_findPanel.bottomAnchor],
        [_statusBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_statusBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_statusBar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [_statusBar.heightAnchor constraintEqualToConstant:22],
    ]];

    // Collapse secondary views and side panel initially, then restore saved panel state
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_vSplitView   setPosition:MAX(NSWidth(self->_vSplitView.frame),   9999) ofDividerAtIndex:0];
        [self->_hSplitView   setPosition:MAX(NSHeight(self->_hSplitView.frame),  9999) ofDividerAtIndex:0];
        BOOL dockLeft = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefDockPanelsOnLeft];
        [self->_editorSplitView setPosition:(dockLeft ? 0 : MAX(NSWidth(self->_editorSplitView.frame), 9999)) ofDividerAtIndex:0];
        // Collapse search results panel initially
        [self->_searchSplitView setPosition:NSHeight(self->_searchSplitView.frame) ofDividerAtIndex:0];
        [self _refreshToolbarStates];
        self->_isWindowReadyForResizeEvents = YES;
    });

    // Session restore is handled by AppDelegate (which checks CLI flags like -nosession).
    // AppDelegate calls restoreLastSession or addNewTab as needed.
    [self rebuildMacroMenu];
    [self rebuildRunMenu];
    [self updateStatusBar];

    // Accept file drag-and-drop onto the primary editor area
    __weak typeof(self) weakSelf = self;
    ((NppDropView *)_tabManager.contentView).dropHandler = ^(NSArray<NSString *> *paths) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        for (NSString *path in paths) {
            [strongSelf->_tabManager openFileAtPath:path];
            [strongSelf addToRecentFiles:path];
        }
        [strongSelf updateTitle];
    };
}

- (NSTextField *)makeStatusLabel:(NSTextAlignment)align {
    NSTextField *f = [[NSTextField alloc] init];
    f.translatesAutoresizingMaskIntoConstraints = NO;
    f.editable = NO; f.bordered = NO; f.drawsBackground = NO;
    f.textColor = [NSColor secondaryLabelColor];
    f.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    f.alignment = align;
    return f;
}

#pragma mark - Session

- (NSArray<TabManager *> *)sessionTabManagers {
    NSMutableArray<TabManager *> *mgrs = [NSMutableArray array];
    if (_tabManager)     [mgrs addObject:_tabManager];
    if (_subTabManagerH) [mgrs addObject:_subTabManagerH];
    if (_subTabManagerV) [mgrs addObject:_subTabManagerV];
    return mgrs;
}

/// The controllers whose tabs belong in the session: every window that is still
/// live, plus the receiver. The receiver is included unconditionally because the
/// usual caller is a window in the middle of closing — its tabs are being closed
/// as the app goes away, which is exactly the case that has always persisted.
/// Windows the user closed earlier are excluded; those documents are gone.
- (NSArray<MainWindowController *> *)_sessionContributingControllers {
    NSMutableArray<MainWindowController *> *result = [NSMutableArray arrayWithObject:self];
    id appDel = NSApp.delegate;
    if (![appDel isKindOfClass:[AppDelegate class]]) return result;  // unit hosts

    for (MainWindowController *mwc in [(AppDelegate *)appDel windowControllers])
        if (mwc != self && !mwc.windowHasClosed) [result addObject:mwc];
    return result;
}

- (void)saveSessionForAllWindows {
    NSMutableArray<TabManager *> *mgrs = [NSMutableArray array];
    for (MainWindowController *mwc in [self _sessionContributingControllers])
        for (TabManager *mgr in [mwc sessionTabManagers])
            if (![mgrs containsObject:mgr]) [mgrs addObject:mgr];

    // Prefer the front window's active tab for selectedIndex — the save is often
    // driven by the primary controller even when a secondary window has focus.
    MainWindowController *key = nil;
    for (MainWindowController *mwc in [self _sessionContributingControllers])
        if (mwc.window.isKeyWindow) { key = mwc; break; }

    [self saveSessionWithTabManagers:mgrs
                       activeEditor:[(key ?: self) currentEditor]];
}

/// Save session to ~/Library/Application Support/Nextpad++/session.plist.
/// Untitled modified tabs are written to ~/Library/Application Support/Nextpad++/backup/ automatically.
///
/// `sessionManagers` must cover every tab whose backup should survive the
/// stale-backup prune at the end — the prune deletes any backup file not claimed
/// by one of these managers' editors. Callers therefore go through
/// -saveSessionForAllWindows rather than passing one window's managers.
/// `activeEditor` is the tab to reopen selected; ignored if it produced no entry.
- (void)saveSessionWithTabManagers:(NSArray<TabManager *> *)sessionManagers
                      activeEditor:(nullable EditorView *)activeEditor {
    ensureNppDirs();
    NSString *backupDir = nppBackupDir();

    // Persist ALL open tabs so they reopen on next launch.
    // Modified text files: back up content to ~/Library/Application Support/Nextpad++/backup/ so unsaved
    // changes survive quit.  On next launch they reload from backup and show
    // as modified (Windows NPP behaviour — no save prompt on exit).
    // Binary / large-file tabs: record path only, no backup.
    // Clean up stale backups after saving.
    NSMutableSet *activeBackups = [NSMutableSet set];

    // Issue #162: enumerate editors across ALL views (primary + both split
    // views), not just the primary. A tab moved via "Move to Other …View" lives
    // in a different TabManager; iterating only _tabManager omitted it from the
    // session AND (because its backup wasn't added to activeBackups) deleted its
    // backup in the prune below — silent loss of unsaved content. Restored tabs
    // all reopen in the primary view (split layout is intentionally not kept).
    // The same reasoning extends across windows, which is why the manager list
    // is supplied by the caller (see -saveSessionForAllWindows).
    NSMutableArray<EditorView *> *sessionEditors = [NSMutableArray array];
    NSMapTable<EditorView *, TabManager *> *ownerManager =
        [NSMapTable strongToStrongObjectsMapTable];
    for (TabManager *mgr in sessionManagers) {
        if (!mgr) continue;
        for (EditorView *ed in mgr.allEditors) {
            if ([sessionEditors containsObject:ed]) continue;  // defensive: never dup
            [sessionEditors addObject:ed];
            [ownerManager setObject:mgr forKey:ed];
        }
    }

    NSMutableArray *tabs = [NSMutableArray array];
    // Parallel to `tabs`: which editor produced each entry. `tabs` skips
    // untouched untitled tabs, so a tab-bar index is not an index into it —
    // selectedIndex has to be resolved against this list.
    NSMutableArray<EditorView *> *tabEditors = [NSMutableArray array];
    for (EditorView *ed in sessionEditors) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];

        if (ed.filePath) info[@"filePath"] = ed.filePath;

        if (!ed.filePath) {
            // Untitled tab — restore if it has content OR was renamed (#177), so a
            // renamed organizational tab survives relaunch even when empty.
            if (!ed.isModified && !ed.customTabName.length) continue;
            NSString *backup = [ed saveBackupToDirectory:backupDir];
            if (backup) { info[@"backupFilePath"] = backup; [activeBackups addObject:backup]; }
            info[@"untitledIndex"] = @(ed.untitledIndex);
            if (ed.customTabName.length) info[@"customTabName"] = ed.customTabName;
        } else if (ed.isModified && !ed.largeFileMode) {
            // Named file with unsaved changes — back up content
            NSString *backup = [ed saveBackupToDirectory:backupDir];
            if (backup) { info[@"backupFilePath"] = backup; [activeBackups addObject:backup]; }
        }

        if (ed.currentLanguage.length) info[@"language"] = ed.currentLanguage;

        // ── Cursor, selection, scroll state (matches Windows NPP session format) ──
        ScintillaView *sci = ed.scintillaView;
        info[@"startPos"]         = @([sci message:SCI_GETANCHOR]);
        info[@"endPos"]           = @([sci message:SCI_GETCURRENTPOS]);
        info[@"selMode"]          = @([sci message:SCI_GETSELECTIONMODE]);
        info[@"firstVisibleLine"] = @([sci message:SCI_GETFIRSTVISIBLELINE]);
        info[@"xOffset"]          = @([sci message:SCI_GETXOFFSET]);
        info[@"scrollWidth"]      = @([sci message:SCI_GETSCROLLWIDTH]);

        // ── Encoding ──
        info[@"encodingName"] = ed.encodingName ?: @"UTF-8";
        info[@"hasBOM"]       = @(ed.hasBOM);

        // ── Read-only & RTL ──
        if ([sci message:SCI_GETREADONLY])
            info[@"userReadOnly"] = @YES;
        sptr_t bidi = [sci message:2708]; // SCI_GETBIDIRECTIONAL
        if (bidi == 2) // R2L
            info[@"RTL"] = @YES;

        // ── Per-tab color and pin state (looked up within the OWNING view) ──
        TabManager *ownerMgr = [ownerManager objectForKey:ed] ?: _tabManager;
        NSInteger edIdx = [ownerMgr.allEditors indexOfObject:ed];
        if (edIdx != NSNotFound) {
            NSInteger cid = [ownerMgr.tabBar tabColorAtIndex:edIdx];
            if (cid >= 0) info[@"tabColorId"] = @(cid);
            if ([ownerMgr.tabBar isTabPinnedAtIndex:edIdx])
                info[@"pinned"] = @YES;
        }

        // ── Bookmarks (line numbers with bookmark marker) ──
        {
            NSMutableArray *marks = [NSMutableArray array];
            sptr_t line = 0;
            while ((line = [sci message:SCI_MARKERNEXT wParam:(uptr_t)line lParam:(1 << 20)]) >= 0) {
                [marks addObject:@(line)];
                line++; // advance past this line
            }
            if (marks.count) info[@"bookmarks"] = marks;
        }

        // ── Fold state (contracted fold header lines) ──
        {
            NSMutableArray *folds = [NSMutableArray array];
            sptr_t line = 0;
            sptr_t lineCount = [sci message:SCI_GETLINECOUNT];
            while (line < lineCount) {
                line = [sci message:SCI_CONTRACTEDFOLDNEXT wParam:(uptr_t)line];
                if (line < 0) break;
                [folds addObject:@(line)];
                line++;
            }
            if (folds.count) info[@"folds"] = folds;
        }

        [tabs addObject:info];
        [tabEditors addObject:ed];
    }

    // Issue #87 (refined) — empty-session preserve guard.
    // Original case: user toggles "Remember session" OFF, quits (save skipped),
    // relaunches (1 default empty tab), toggles back ON, quits. Without a guard
    // the empty-on-quit would wipe the prior session.plist.
    // Refinement: if THIS launch actually restored a session, an empty
    // tabs array at quit means the user explicitly closed everything they
    // had open — they want the session cleared, not preserved.
    //   _didRestoreSession    | tabs.count == 0 ? action
    //   ──────────────────────┼──────────────────────────
    //   YES (restored at boot)| write empty session  → user's close persists
    //   NO  (didn't restore)  | preserve prior plist → original Issue #87 fix
    if (tabs.count == 0 && !_didRestoreSession) return;

    // Resolve the active tab against `tabs`, not against a tab-bar index: with
    // several windows (or a split view) the tab bars each start at 0, so a raw
    // tab-bar index restores an unrelated document.
    NSUInteger selIdx = activeEditor ? [tabEditors indexOfObject:activeEditor] : NSNotFound;
    NSDictionary *session = @{
        @"tabs":          tabs,
        @"selectedIndex": @(selIdx == NSNotFound ? 0 : (NSInteger)selIdx)
    };
    [session writeToFile:nppSessionPath() atomically:YES];

    // Prune stale backup files no longer referenced by any open editor
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *backupFiles = [fm contentsOfDirectoryAtPath:backupDir error:nil];
    for (NSString *name in backupFiles) {
        NSString *full = [backupDir stringByAppendingPathComponent:name];
        if (![activeBackups containsObject:full])
            [fm removeItemAtPath:full error:nil];
    }
}

/// Restore session from ~/Library/Application Support/Nextpad++/session.plist.
/// Returns YES if at least one tab was restored.
- (BOOL)restoreLastSession {
    NSDictionary *session = [NSDictionary dictionaryWithContentsOfFile:nppSessionPath()];
    NSArray<NSDictionary *> *tabs = session[@"tabs"];
    if (!tabs.count) return NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger opened = 0;

    for (NSDictionary *info in tabs) {
        NSString *filePath   = info[@"filePath"];
        NSString *backupPath = info[@"backupFilePath"];
        NSString *lang       = info[@"language"];

        // Prefer backup (more recent snapshot) if it exists
        NSString *loadPath   = nil;
        BOOL      fromBackup = NO;
        if (backupPath && [fm fileExistsAtPath:backupPath]) {
            loadPath = backupPath; fromBackup = YES;
        } else if (filePath && [fm fileExistsAtPath:filePath]) {
            loadPath = filePath;
        }
        if (!loadPath) continue;

        // Use addNewTab so we can configure the editor directly
        EditorView *ed = [_tabManager addNewTab];
        NSError *err;
        if (![ed loadFileAtPath:loadPath error:&err]) { [_tabManager closeEditor:ed]; continue; }

        if (fromBackup) {
            // Restore untitled index so tab name and future backup filename match
            NSInteger savedIndex = [info[@"untitledIndex"] integerValue];
            if (savedIndex > 0) [ed restoreUntitledIndex:savedIndex];
            // Point filePath back to original (nil for untitled) and mark modified
            ed.filePath = filePath; // nil for untitled — custom setter handles presenter
            ed.backupFilePath = backupPath;
            NSString *customName = info[@"customTabName"];   // #177 — restore renamed tab
            if (customName.length) ed.customTabName = customName;
            [ed markAsModified];
        }
        if (lang.length) [ed setLanguage:lang];
        [_tabManager refreshCurrentTabTitle];

        ScintillaView *sci = ed.scintillaView;

        // ── Restore encoding ──
        // (encoding is set during loadFileAtPath: based on BOM detection;
        //  encodingName is informational — no override needed here)

        // ── Restore read-only & RTL ──
        if ([info[@"userReadOnly"] boolValue])
            [sci message:SCI_SETREADONLY wParam:1];
        if ([info[@"RTL"] boolValue])
            [ed setTextDirectionRTL:nil]; // Full RTL setup: bidi + keys + wrap + layout

        // ── Restore per-tab color and pin state ──
        NSInteger tabIdx = (NSInteger)_tabManager.allEditors.count - 1;
        NSNumber *colorNum = info[@"tabColorId"];
        if (colorNum)
            [_tabManager.tabBar setTabColorAtIndex:tabIdx colorId:colorNum.integerValue];
        if ([info[@"pinned"] boolValue])
            [_tabManager.tabBar pinTabAtIndex:tabIdx toggle:YES];

        // ── Restore bookmarks ──
        NSArray *bookmarks = info[@"bookmarks"];
        for (NSNumber *bkLine in bookmarks)
            [sci message:SCI_MARKERADD wParam:(uptr_t)bkLine.longLongValue lParam:20]; // kBookmarkMarker=20

        // ── Restore fold state (BEFORE caret so a saved caret on a header
        // line lands consistently with the display, and any later
        // ENSUREVISIBLE call has the right fold context to expand). ──
        NSArray *folds = info[@"folds"];
        if (folds.count) {
            // Ensure fold levels are computed before applying fold state
            [sci message:SCI_COLOURISE wParam:0 lParam:-1];
            for (NSNumber *foldLine in folds) {
                sptr_t line = foldLine.longLongValue;
                BOOL isHeader = ([sci message:SCI_GETFOLDLEVEL wParam:(uptr_t)line] & SC_FOLDLEVELHEADERFLAG) != 0;
                BOOL isExpanded = [sci message:SCI_GETFOLDEXPANDED wParam:(uptr_t)line];
                if (isHeader && isExpanded)
                    [sci message:SCI_TOGGLEFOLD wParam:(uptr_t)line];
            }
        }

        // ── Restore cursor & selection ──
        // SCI_SETSEL takes wParam=anchor, lParam=caret, atomically. Earlier
        // code mistakenly used SCI_SETANCHOR/SCI_SETCURRENTPOS with the
        // position in lParam (those take wParam=pos), so the saved offset
        // never actually applied — every relaunch parked the caret at 0.
        // Clamp against current document length in case the file shrank
        // since the session was saved.
        NSNumber *startPos = info[@"startPos"];
        NSNumber *endPos   = info[@"endPos"];
        if (startPos && endPos) {
            sptr_t docLen = [sci message:SCI_GETLENGTH];
            sptr_t anchor = MAX((sptr_t)0, MIN((sptr_t)startPos.longLongValue, docLen));
            sptr_t caret  = MAX((sptr_t)0, MIN((sptr_t)endPos.longLongValue,   docLen));
            NSInteger selMode = [info[@"selMode"] integerValue];
            if (selMode > 0)
                [sci message:SCI_SETSELECTIONMODE wParam:(uptr_t)selMode];
            [sci message:SCI_SETSEL wParam:(uptr_t)anchor lParam:(sptr_t)caret];
            // If the caret line sits inside a still-collapsed fold,
            // expand the enclosing folds so the caret is reachable.
            sptr_t caretLine = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)caret];
            [sci message:SCI_ENSUREVISIBLEENFORCEPOLICY wParam:(uptr_t)caretLine];
        }

        // ── Restore scroll position (last, so saved firstVisibleLine wins
        // over the implicit scroll caused by ENSUREVISIBLE above). ──
        NSNumber *scrollWidth = info[@"scrollWidth"];
        if (scrollWidth && scrollWidth.longLongValue > 1)
            [sci message:SCI_SETSCROLLWIDTH wParam:(uptr_t)scrollWidth.longLongValue];
        NSNumber *xOffset = info[@"xOffset"];
        if (xOffset)
            [sci message:SCI_SETXOFFSET wParam:(uptr_t)xOffset.longLongValue];
        NSNumber *firstVisLine = info[@"firstVisibleLine"];
        if (firstVisLine)
            [sci message:SCI_SETFIRSTVISIBLELINE wParam:(uptr_t)firstVisLine.longLongValue];

        opened++;
    }

    if (opened == 0) return NO;

    NSInteger sel = [session[@"selectedIndex"] integerValue];
    if (sel < (NSInteger)_tabManager.allEditors.count)
        [_tabManager selectTabAtIndex:sel];

    // Mark this launch as session-restored. The session save uses this to allow
    // writing an empty session.plist if the user explicitly closed all the
    // restored tabs before quitting (otherwise the empty-guard would keep
    // the stale session.plist around and the same tabs would reappear next
    // launch).
    _didRestoreSession = YES;
    return YES;
}

#pragma mark - Session Load/Save (user-triggered)

static NSString *nppShortcutsPath(void) {
    return [nppConfigDir() stringByAppendingPathComponent:@"shortcuts.xml"];
}

// ── shortcuts.xml macro read/write (Windows-compatible format) ────────────────

/// Load macros from shortcuts.xml. Returns array of @{@"name":..., @"actions":...}
NSArray<NSDictionary *> *loadMacrosFromShortcutsXML(void) {
    NSString *path = nppShortcutsPath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return @[];

    NSError *err = nil;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:&err];
    if (!doc) return @[];

    NSArray *macroNodes = [doc nodesForXPath:@"//Macros/Macro" error:nil];
    NSMutableArray *result = [NSMutableArray array];
    for (NSXMLElement *macroEl in macroNodes) {
        NSString *name = [[macroEl attributeForName:@"name"] stringValue] ?: @"Untitled";
        NSMutableArray *actions = [NSMutableArray array];
        for (NSXMLElement *actionEl in [macroEl elementsForName:@"Action"]) {
            NSMutableDictionary *act = [NSMutableDictionary dictionary];
            act[@"type"]    = @([[[actionEl attributeForName:@"type"] stringValue] intValue]);
            act[@"message"] = @([[[actionEl attributeForName:@"message"] stringValue] intValue]);
            act[@"wParam"]  = @([[[actionEl attributeForName:@"wParam"] stringValue] longLongValue]);
            act[@"lParam"]  = @([[[actionEl attributeForName:@"lParam"] stringValue] longLongValue]);
            act[@"sParam"]  = [[actionEl attributeForName:@"sParam"] stringValue] ?: @"";
            [actions addObject:act];
        }
        NSString *ctrlVal  = [[macroEl attributeForName:@"Ctrl"]  stringValue] ?: @"no";
        NSString *altVal   = [[macroEl attributeForName:@"Alt"]   stringValue] ?: @"no";
        NSString *shiftVal = [[macroEl attributeForName:@"Shift"] stringValue] ?: @"no";
        NSString *cmdVal   = [[macroEl attributeForName:@"Cmd"]   stringValue] ?: @"no";
        NSString *keyVal   = [[macroEl attributeForName:@"Key"]   stringValue] ?: @"0";
        [result addObject:@{@"name": name, @"actions": actions,
                            @"Ctrl": ctrlVal, @"Alt": altVal, @"Shift": shiftVal,
                            @"Cmd": cmdVal, @"Key": keyVal}];
    }
    return result;
}

/// Save macros to shortcuts.xml in Windows-compatible format.
/// Add a single macro to shortcuts.xml <Macros> section (in-place, preserves rest of file).
static void addMacroToShortcutsXML(NSString *name, NSArray<NSDictionary *> *actions,
                                   BOOL ctrl, BOOL alt, BOOL shift, BOOL cmd, NSUInteger keyCode) {
    NSString *path = nppShortcutsPath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:NSXMLNodePreserveAll error:nil];
    if (!doc) return;

    NSXMLElement *root = doc.rootElement;

    // Find or create the <Macros> element
    NSArray *macrosNodes = [root elementsForName:@"Macros"];
    NSXMLElement *macrosEl = macrosNodes.firstObject;
    if (!macrosEl) {
        macrosEl = [NSXMLElement elementWithName:@"Macros"];
        [root addChild:macrosEl];
    }

    // Build the new <Macro> element
    NSXMLElement *macroEl = [NSXMLElement elementWithName:@"Macro"];
    [macroEl addAttribute:[NSXMLNode attributeWithName:@"name" stringValue:name]];
    [macroEl addAttribute:[NSXMLNode attributeWithName:@"Ctrl" stringValue:ctrl ? @"yes" : @"no"]];
    [macroEl addAttribute:[NSXMLNode attributeWithName:@"Alt" stringValue:alt ? @"yes" : @"no"]];
    [macroEl addAttribute:[NSXMLNode attributeWithName:@"Shift" stringValue:shift ? @"yes" : @"no"]];
    [macroEl addAttribute:[NSXMLNode attributeWithName:@"Cmd" stringValue:cmd ? @"yes" : @"no"]];
    [macroEl addAttribute:[NSXMLNode attributeWithName:@"Key"
                                          stringValue:[NSString stringWithFormat:@"%lu", (unsigned long)keyCode]]];

    for (NSDictionary *act in actions) {
        NSXMLElement *actionEl = [NSXMLElement elementWithName:@"Action"];
        [actionEl addAttribute:[NSXMLNode attributeWithName:@"type"
                                                stringValue:[NSString stringWithFormat:@"%d", [act[@"type"] intValue]]]];
        [actionEl addAttribute:[NSXMLNode attributeWithName:@"message"
                                                stringValue:[NSString stringWithFormat:@"%d", [act[@"message"] intValue]]]];
        [actionEl addAttribute:[NSXMLNode attributeWithName:@"wParam"
                                                stringValue:[NSString stringWithFormat:@"%lld", [act[@"wParam"] longLongValue]]]];
        [actionEl addAttribute:[NSXMLNode attributeWithName:@"lParam"
                                                stringValue:[NSString stringWithFormat:@"%lld", [act[@"lParam"] longLongValue]]]];
        [actionEl addAttribute:[NSXMLNode attributeWithName:@"sParam"
                                                stringValue:act[@"sParam"] ?: @""]];
        [macroEl addChild:actionEl];
    }
    [macrosEl addChild:macroEl];

    // Write back — preserves all other sections
    NSData *xmlData = [doc XMLDataWithOptions:NSXMLNodePrettyPrint | NSXMLNodePreserveAll];
    [xmlData writeToFile:path options:NSDataWritingAtomic error:nil];
}

/// Remove a macro by name from shortcuts.xml <Macros> section (in-place).
static void removeMacroFromShortcutsXML(NSString *name) {
    NSString *path = nppShortcutsPath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:NSXMLNodePreserveAll error:nil];
    if (!doc) return;

    for (NSXMLElement *el in [doc nodesForXPath:@"//Macros/Macro" error:nil]) {
        if ([[[el attributeForName:@"name"] stringValue] isEqualToString:name]) {
            [el detach];
            break;
        }
    }
    NSData *xmlData = [doc XMLDataWithOptions:NSXMLNodePrettyPrint | NSXMLNodePreserveAll];
    [xmlData writeToFile:path options:NSDataWritingAtomic error:nil];
}

- (void)loadSessionFromPath:(NSString *)path {
    NSDictionary *session = [NSDictionary dictionaryWithContentsOfFile:path];
    NSArray<NSDictionary *> *tabs = session[@"tabs"];
    if (!tabs.count) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = [[NppLocalizer shared] translate:@"Empty Session"];
        a.informativeText = [[NppLocalizer shared] translate:@"The selected session file contains no tabs."];
        [a runModal];
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSDictionary *info in tabs) {
        NSString *filePath = info[@"filePath"];
        if (filePath && [fm fileExistsAtPath:filePath])
            [self openFileAtPath:filePath];
    }
}

- (void)saveSessionToPath:(NSString *)path {
    NSMutableArray *tabs = [NSMutableArray array];
    for (EditorView *ed in _tabManager.allEditors) {
        if (!ed.filePath) continue;
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[@"filePath"] = ed.filePath;
        if (ed.currentLanguage.length) info[@"language"] = ed.currentLanguage;
        info[@"cursorLine"] = @(ed.cursorLine);
        [tabs addObject:info];
    }
    NSDictionary *session = @{
        @"tabs": tabs,
        @"selectedIndex": @(_tabManager.tabBar.selectedIndex)
    };
    [session writeToFile:path atomically:YES];
}

- (void)loadSession:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.title = [[NppLocalizer shared] translate:@"Load Session"];
    p.allowedFileTypes = @[@"plist"];
    if ([p runModal] != NSModalResponseOK) return;
    [self loadSessionFromPath:p.URL.path];
}

- (void)saveSessionAs:(id)sender {
    NSSavePanel *p = [NSSavePanel savePanel];
    p.title = [[NppLocalizer shared] translate:@"Save Session"];
    p.nameFieldStringValue = @"session.plist";
    p.allowedFileTypes = @[@"plist"];
    if ([p runModal] != NSModalResponseOK) return;
    [self saveSessionToPath:p.URL.path];
}

#pragma mark - Auto-save

/// Periodically write all modified editors to ~/Library/Application Support/Nextpad++/backup/ — never to the original file.
/// Backs up both named and untitled files so unsaved changes survive a crash.
- (void)autoSaveTick:(NSTimer *)t {
    ensureNppDirs();
    NSString *backupDir = nppBackupDir();
    NSArray *managers = @[_tabManager, _subTabManagerH, _subTabManagerV];
    for (TabManager *mgr in managers)
        for (EditorView *ed in mgr.allEditors)
            if (ed.isModified && !ed.largeFileMode) [ed saveBackupToDirectory:backupDir];
}

#pragma mark - Public

- (void)openFileAtPath:(NSString *)path {
    [_tabManager openFileAtPath:path];
    [self addToRecentFiles:path];
    [self updateTitle];
}

// Issue #63: macOS routes Finder "Open With…" / drag-drop / double-click
// events to NSApplicationDelegate's openFile(s) handlers regardless of
// window state. Without an explicit deminiaturize + activate the file is
// silently added to a tab inside a window that stays in the Dock — users
// see no feedback and have to hunt for the Dock icon. This helper is the
// single canonical "give the user back their window" sequence:
//
//   • activateIgnoringOtherApps:YES — pulls focus away from Finder.
//   • deminiaturize: if currently minimized — pops the window out of the
//     Dock with the standard genie animation.
//   • makeKeyAndOrderFront: — covers the secondary cases too: window
//     hidden via NSApplication's hide: (Cmd-H), or app simply
//     backgrounded but visible. Idempotent for already-front windows.
//
// We deliberately do NOT call orderedIndex/orderFront chains; those add
// nothing here and risk reordering documents when multiple windows are
// open in a future multi-window setup.
- (void)bringWindowForward {
    [NSApp activateIgnoringOtherApps:YES];
    if (self.window.miniaturized) [self.window deminiaturize:nil];
    [self.window makeKeyAndOrderFront:nil];
}

#pragma mark - Recent Files

- (void)addToRecentFiles:(NSString *)path {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableArray *recents = [([ud stringArrayForKey:@"RecentFiles"] ?: @[]) mutableCopy];
    [recents removeObject:path];
    [recents insertObject:path atIndex:0];
    if (recents.count > 15) [recents removeLastObject];
    [ud setObject:recents forKey:@"RecentFiles"];
    [self rebuildRecentFilesMenu];
}

- (void)rebuildRecentFilesMenu {
    NSMenu *fileMenu = [[NSApp mainMenu].itemArray[1] submenu];
    NSMenuItem *recentItem = [fileMenu itemWithTag:1001];
    if (!recentItem) return;
    NSMenu *recentMenu = recentItem.submenu;
    [recentMenu removeAllItems];
    NSArray<NSString *> *recents = [[NSUserDefaults standardUserDefaults]
                                     stringArrayForKey:@"RecentFiles"] ?: @[];
    for (NSString *path in recents) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:path.lastPathComponent
                                                    action:@selector(openRecentFile:)
                                             keyEquivalent:@""];
        it.representedObject = path;
        it.toolTip = path;
        [recentMenu addItem:it];
    }
    if (recents.count) {
        [recentMenu addItem:[NSMenuItem separatorItem]];
        [recentMenu addItem:[[NSMenuItem alloc] initWithTitle:[[NppLocalizer shared] translate:@"Clear Recent Files"]
                                                       action:@selector(clearRecentFiles:)
                                                keyEquivalent:@""]];
    }
}

- (void)openRecentFile:(id)sender {
    NSString *path = [sender representedObject];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = [[NppLocalizer shared] translate:@"File not found"];
        a.informativeText = path;
        [a runModal];
        return;
    }
    [_tabManager openFileAtPath:path];
    [self addToRecentFiles:path]; // move to top
    [self updateTitle];
}

- (void)clearRecentFiles:(id)sender {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"RecentFiles"];
    [self rebuildRecentFilesMenu];
}

#pragma mark - File menu actions

- (void)newDocument:(id)sender {
    [_tabManager addNewTab];
    [self updateTitle];
}

- (void)openDocument:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    [panel beginWithCompletionHandler:^(NSModalResponse r) {
        if (r == NSModalResponseOK)
            for (NSURL *u in panel.URLs) {
                [self->_tabManager openFileAtPath:u.path];
                [self addToRecentFiles:u.path];
            }
        [self updateTitle];
    }];
}

- (void)saveDocument:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    if (!ed.filePath) { [self saveDocumentAs:sender]; return; }
    NSError *err;
    if (![ed saveError:&err]) [[NSAlert alertWithError:err] runModal];
    [self refreshTabsForEditor:ed];
}

- (void)saveDocumentAs:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = ed.displayName;
    [panel beginWithCompletionHandler:^(NSModalResponse r) {
        if (r == NSModalResponseOK) {
            NSError *err;
            if (![ed saveToPath:panel.URL.path error:&err])
                [[NSAlert alertWithError:err] runModal];
            // ed, not -currentEditor: the panel is modeless, so the active pane
            // can change while it is open, and the tab that needs repainting is
            // the one holding the editor this save actually wrote.
            [self refreshTabsForEditor:ed];
        }
    }];
}

- (void)saveAllDocuments:(id)sender {
    // Save all modified files silently. Named files save to disk;
    // untitled files prompt Save As for each one.
    NSArray<TabManager *> *managers = @[_tabManager, _subTabManagerH, _subTabManagerV];
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    for (TabManager *mgr in managers) {
        for (EditorView *ed in mgr.allEditors.copy) {
            if (!ed.isModified) continue;
            if (ed.filePath) {
                NSError *err;
                // Don't silently swallow a failed write: the tab stays dirty but
                // the user is told "Save All" succeeded. Collect failures and
                // surface them, matching saveDocument:'s alert-on-failure.
                if (![ed saveError:&err])
                    [failures addObject:[NSString stringWithFormat:@"%@ — %@",
                        ed.displayName, err.localizedDescription ?: @"save failed"]];
            } else {
                // runSavePanelForEditor: surfaces its own error on failure.
                [mgr runSavePanelForEditor:ed completion:nil];
            }
        }
        [mgr refreshAllTabTitles];
    }
    [self updateTitle];
    if (_docListPanel && [_sidePanelHost hasPanel:_docListPanel])
        [_docListPanel refreshModifiedStates];
    if (failures.count) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [[NppLocalizer shared] translate:@"Some documents could not be saved"];
        alert.informativeText = [failures componentsJoinedByString:@"\n"];
        [alert runModal];
    }
}

- (void)closeCurrentTab:(id)sender {
    NSInteger sel = _activeTabManager.tabBar.selectedIndex;
    if (sel >= 0 && [_activeTabManager.tabBar isTabPinnedAtIndex:sel]) return;
    [_activeTabManager closeCurrentTab];
    [self updateTitle];
}

- (void)closeAllTabs:(id)sender {
    [self _closeEditors:_tabManager.allEditors.copy inManager:_tabManager];
}

- (void)printDocument:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    NSPrintOperation *op = [NSPrintOperation printOperationWithView:ed.scintillaView];
    [op runOperation];
}

#pragma mark - Edit / clipboard actions

// Edit menu / toolbar / Cmd-key forwarders. We send the Scintilla message
// directly to the current editor instead of bouncing through the responder
// chain. The earlier `[firstResponder tryToPerform:]` recursed back into
// these methods (NSWindow.tryToPerform: walks its chain back to the window
// controller, which IS self), and with no editor focus the loop ran out
// the thread-0 stack — manifest as a crash inside objc_loadWeakRetained.
//
// When `currentEditor` is nil (no tab open, fresh launch, all tabs closed),
// `[nil scintillaView]` returns nil and the message is a silent no-op,
// matching the expected "do nothing" behaviour. When focus is on a text
// field (Find dialog, side-panel filter, etc.), AppKit's responder routing
// delivers Cmd+V to the field directly and these methods are never invoked,
// so those paths are unaffected.
- (void)cut:(id)sender   { [[[self currentEditor] scintillaView] message:SCI_CUT];   }
- (void)copy:(id)sender  { [[[self currentEditor] scintillaView] message:SCI_COPY];  }
- (void)paste:(id)sender { [[[self currentEditor] scintillaView] message:SCI_PASTE]; }
- (void)undo:(id)sender  { [[[self currentEditor] scintillaView] message:SCI_UNDO];  }
- (void)redo:(id)sender  { [[[self currentEditor] scintillaView] message:SCI_REDO];  }

- (void)indentSelection:(id)sender {
    [[[self currentEditor] scintillaView] message:SCI_TAB];
}
- (void)unindentSelection:(id)sender {
    [[[self currentEditor] scintillaView] message:SCI_BACKTAB];
}
- (void)toggleLineComment:(id)sender   { [[self currentEditor] toggleLineComment:sender]; }
- (void)toggleBlockComment:(id)sender  { [[self currentEditor] toggleBlockComment:sender]; }

#pragma mark - Line operation actions

- (void)duplicateLine:(id)sender  { [[self currentEditor] duplicateLine:sender]; }
- (void)deleteLine:(id)sender     { [[self currentEditor] deleteLine:sender]; }
- (void)moveLineUp:(id)sender     { [[self currentEditor] moveLineUp:sender]; }
- (void)moveLineDown:(id)sender   { [[self currentEditor] moveLineDown:sender]; }
- (void)toggleOverwriteMode:(id)sender {
    [[self currentEditor] toggleOverwriteMode];
    [self updateStatusBar];
}

#pragma mark - Folding actions

- (void)foldAll:(id)sender          { [[self currentEditor] foldAll:sender]; }
- (void)unfoldAll:(id)sender        { [[self currentEditor] unfoldAll:sender]; }
- (void)foldCurrentLevel:(id)sender { [[self currentEditor] foldCurrentLevel:sender]; }

#pragma mark - Bookmark actions

- (void)toggleBookmark:(id)sender    { [[self currentEditor] toggleBookmark:sender]; }
- (void)nextBookmark:(id)sender      { [[self currentEditor] nextBookmark:sender]; }
- (void)previousBookmark:(id)sender  { [[self currentEditor] previousBookmark:sender]; }
- (void)clearAllBookmarks:(id)sender { [[self currentEditor] clearAllBookmarks:sender]; }

#pragma mark - Macro actions

- (void)toggleMacroRecording:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    if (ed.isRecordingMacro) [ed stopMacroRecording];
    else                     [ed startMacroRecording];
}

- (void)startMacroRecording:(id)sender {
    [[self currentEditor] startMacroRecording];
    [self _refreshToolbarStates];
}

- (void)stopMacroRecording:(id)sender {
    [[self currentEditor] stopMacroRecording];
    [self _refreshToolbarStates];
}

- (void)runMacro:(id)sender {
    [[self currentEditor] runMacro];
}

// No-op target for the two radio buttons inside the "Run a Macro Multiple
// Times" dialog. AppKit auto-groups sibling radio buttons that share the
// same (non-nil) target+action selector — without an actual selector to
// share, the mutual-exclusion behavior never engages.
- (void)_macroDialogRadioClicked:(id)sender { (void)sender; }

// "Run Macro on Files…" — open the batch dialog with no preselected folder.
// User picks via Browse. See NPPBatchDialog / NPPBatchRunner / RFC_BATCH_MACRO_ON_FILES.md.
- (void)showBatchRunDialog:(id)sender {
    [NPPBatchDialog presentForWindow:self preselectedFolder:nil];
}

// Variant invoked from the Folder-as-Workspace right-click on a directory.
// sender is the NSMenuItem whose representedObject is the absolute folder path.
- (void)showBatchRunDialogForFolder:(id)sender {
    NSString *folder = nil;
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        id rep = ((NSMenuItem *)sender).representedObject;
        if ([rep isKindOfClass:[NSString class]]) folder = rep;
    }
    [NPPBatchDialog presentForWindow:self preselectedFolder:folder];
}

- (void)runMacroMultipleTimes:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;

    // Load saved macros for the dropdown
    NSArray<NSDictionary *> *savedMacros = loadMacrosFromShortcutsXML();

    // Build macro name list: "Current recorded macro" + saved macros
    NSMutableArray<NSString *> *macroNames = [NSMutableArray array];
    [macroNames addObject:[[NppLocalizer shared] translate:@"Current recorded macro"]];
    for (NSDictionary *m in savedMacros)
        [macroNames addObject:m[@"name"]];

    // Build dialog
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 340, 180)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered defer:NO];
    panel.title = [[NppLocalizer shared] translate:@"Run a Macro Multiple Times"];
    [panel center];
    NSView *cv = panel.contentView;

    // "Macro to run" label
    NSTextField *lbl = [NSTextField labelWithString:[[NppLocalizer shared] translate:@"Macro to run"]];
    lbl.frame = NSMakeRect(110, 148, 120, 16);
    lbl.alignment = NSTextAlignmentCenter;
    [cv addSubview:lbl];

    // Macro dropdown
    NSPopUpButton *macroPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 120, 300, 25) pullsDown:NO];
    [macroPopup addItemsWithTitles:macroNames];
    // Default to "Trim Trailing Space and Save" if it exists, else current recorded macro
    for (NSUInteger i = 0; i < macroNames.count; i++) {
        if ([macroNames[i] isEqualToString:@"Trim Trailing Space and Save"]) {
            [macroPopup selectItemAtIndex:i];
            break;
        }
    }
    [cv addSubview:macroPopup];

    // "Run N times" / "Run until end of file" radios.
    // AppKit auto-groups sibling radio buttons that share BOTH target and
    // action — clicking one then turns the other off automatically. The
    // earlier hand-rolled wiring nulled both out, so the group degenerated
    // into two independent toggles.
    NSButton *radioN = [NSButton radioButtonWithTitle:[[NppLocalizer shared] translate:@"Run"]
                                               target:self action:@selector(_macroDialogRadioClicked:)];
    radioN.frame = NSMakeRect(20, 85, 60, 20);
    radioN.state = NSControlStateValueOn;
    [cv addSubview:radioN];

    NSTextField *timesField = [[NSTextField alloc] initWithFrame:NSMakeRect(85, 85, 50, 22)];
    timesField.integerValue = 1;
    [cv addSubview:timesField];

    NSTextField *timesLabel = [NSTextField labelWithString:[[NppLocalizer shared] translate:@"times"]];
    timesLabel.frame = NSMakeRect(140, 87, 40, 16);
    [cv addSubview:timesLabel];

    NSButton *radioEOF = [NSButton radioButtonWithTitle:[[NppLocalizer shared] translate:@"Run until the end of file"]
                                                 target:self action:@selector(_macroDialogRadioClicked:)];
    radioEOF.frame = NSMakeRect(20, 58, 250, 20);
    radioEOF.state = NSControlStateValueOff;
    [cv addSubview:radioEOF];

    // Run / Cancel buttons
    NSButton *btnRun = [[NSButton alloc] initWithFrame:NSMakeRect(130, 12, 85, 28)];
    btnRun.title = [[NppLocalizer shared] translate:@"Run"];
    btnRun.bezelStyle = NSBezelStyleRounded;
    btnRun.keyEquivalent = @"\r";
    btnRun.target = NSApp;
    btnRun.action = @selector(stopModal);
    [cv addSubview:btnRun];

    NSButton *btnCancel = [[NSButton alloc] initWithFrame:NSMakeRect(223, 12, 85, 28)];
    btnCancel.title = [[NppLocalizer shared] translate:@"Cancel"];
    btnCancel.bezelStyle = NSBezelStyleRounded;
    btnCancel.keyEquivalent = @"\033";
    btnCancel.target = NSApp;
    btnCancel.action = @selector(abortModal);
    [cv addSubview:btnCancel];

    // clicking the red x doesn't call stopModal/abortModal on its own — the
    // window vanishes but the modal loop keeps running, swallowing every click.
    // basically the app looks frozen. lets catch that close and treat it as cancel.
    id closeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowWillCloseNotification
                    object:panel
                     queue:nil
                usingBlock:^(NSNotification *note) { [NSApp abortModal]; }];

    NSModalResponse resp = [NSApp runModalForWindow:panel];
    [[NSNotificationCenter defaultCenter] removeObserver:closeObserver];
    [panel orderOut:nil];
    if (resp != NSModalResponseStop) return;

    // Determine which macro to run
    NSInteger selectedIdx = macroPopup.indexOfSelectedItem;
    NSArray<NSDictionary *> *actionsToRun = nil;
    if (selectedIdx == 0) {
        // Current recorded macro
        actionsToRun = ed.macroActions;
    } else {
        actionsToRun = savedMacros[selectedIdx - 1][@"actions"];
    }
    if (!actionsToRun.count) {
        NSBeep(); return;
    }

    // Run N times or until EOF
    BOOL runUntilEOF = (radioEOF.state == NSControlStateValueOn);

    // Esc-to-cancel — drain at most one KeyDown event per iteration. Pumping
    // the full run loop would also deliver mouse events to the editor and
    // fight the macro's own actions, so we filter to KeyDown only via
    // -nextEventMatchingMask:untilDate:inMode:dequeue: with distantPast.
    __block BOOL cancelled = NO;
    BOOL (^checkCancel)(void) = ^BOOL {
        NSEvent *evt = [NSApp nextEventMatchingMask:NSEventMaskKeyDown
                                          untilDate:[NSDate distantPast]
                                             inMode:NSDefaultRunLoopMode
                                            dequeue:YES];
        if (evt && evt.keyCode == 53) {  // Esc
            cancelled = YES;
            return YES;
        }
        return NO;
    };

    ScintillaView *sci = ed.scintillaView;

    if (runUntilEOF) {
        // Faithful port of Windows NppBigSwitch.cpp:1487-1556 — line-delta
        // termination. The macro keeps running while it makes *line-level*
        // forward (or, with a shrinking file, backward) progress. Random-
        // Values-style "insert at cursor without a newline" macros terminate
        // after one iteration because deltaCurrLine==0 && deltaLastLine>=0.
        //
        // "lastLine" tracks the ORIGINAL last line at loop entry, and is
        // only advanced when the file is shrinking faster than the cursor
        // is moving — so a growing file does NOT extend its own runway.
        sptr_t lastLine = [sci message:SCI_GETLINECOUNT] - 1;
        sptr_t currPos  = [sci message:SCI_GETCURRENTPOS];
        sptr_t currLine = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)currPos];
        sptr_t deltaLastLine = 0;
        sptr_t deltaCurrLine = 0;
        BOOL cursorMovedUp = NO;
        NSInteger counter = 0;
        // Hard cap — the algorithm above should terminate naturally, but a
        // pathological recorded macro shouldn't be able to freeze the app.
        NSInteger const kHardCap = 100000;
        while (counter < kHardCap) {
            [ed runMacroActions:actionsToRun];
            counter++;

            // Direction-flip guard (Windows: counter > 2). The cursor's
            // line index must be monotonically advancing in one direction,
            // unless the file is shrinking. Otherwise we can't prove the
            // loop terminates.
            if (counter > 2 && cursorMovedUp != (deltaCurrLine < 0) && deltaLastLine >= 0)
                break;

            cursorMovedUp = (deltaCurrLine < 0);
            sptr_t newLast = [sci message:SCI_GETLINECOUNT] - 1;
            sptr_t newPos  = [sci message:SCI_GETCURRENTPOS];
            sptr_t newLine = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)newPos];
            deltaLastLine = newLast - lastLine;
            deltaCurrLine = newLine - currLine;

            // No line-level progress AND no lines removed → done.
            if (deltaCurrLine == 0 && deltaLastLine >= 0)
                break;

            // Only track lastLine when the file is shrinking faster than
            // the cursor is advancing — keeps the EOF goalpost honest.
            if (deltaLastLine < deltaCurrLine)
                lastLine += deltaLastLine;
            currLine += deltaCurrLine;

            // EOF / BOF / wedged-at-zero special case.
            if (currLine > lastLine || currLine < 0 ||
                (deltaCurrLine == 0 && currLine == 0 &&
                 (deltaLastLine >= 0 || cursorMovedUp)))
                break;

            if (checkCancel()) break;
        }
    } else {
        NSInteger times = MAX(1, timesField.integerValue);
        for (NSInteger i = 0; i < times; i++) {
            [ed runMacroActions:actionsToRun];
            if (checkCancel()) break;
        }
    }
}

/// Convert recorded macro actions (msg/wp/lp/text keys) to shortcuts.xml format (type/message/wParam/lParam/sParam)
static NSArray<NSDictionary *> *convertRecordedToXmlFormat(NSArray<NSDictionary *> *recorded) {
    NSMutableArray *xmlActions = [NSMutableArray array];
    for (NSDictionary *act in recorded) {
        NSMutableDictionary *xmlAct = [NSMutableDictionary dictionary];

        // Type 2: menu command by selector name
        NSString *menuCmd = act[@"menuCommand"];
        if (menuCmd) {
            // Plugin commands (pluginMenuAction:) carry a cmdID; store it in
            // wParam so playback can dispatch the exact command. Mirrors the
            // <PluginCommand internalID=…> handle used by shortcuts.xml.
            NSNumber *pluginCmdID = act[@"pluginCmdID"];
            xmlAct[@"type"]    = @2;   // mtMenuCommand
            xmlAct[@"message"] = @0;
            xmlAct[@"wParam"]  = pluginCmdID ?: @0;
            xmlAct[@"lParam"]  = @0;
            xmlAct[@"sParam"]  = menuCmd;  // store selector name in sParam
            [xmlActions addObject:xmlAct];
            continue;
        }

        // Type 0/1: Scintilla message
        int msg = [act[@"msg"] intValue];
        long long wp = [act[@"wp"] longLongValue];
        long long lp = [act[@"lp"] longLongValue];
        NSString *text = act[@"text"];

        xmlAct[@"message"] = @(msg);
        xmlAct[@"wParam"]  = @(wp);
        xmlAct[@"lParam"]  = @(lp);

        if (text.length) {
            xmlAct[@"type"]   = @1;  // mtUseSParameter
            xmlAct[@"sParam"] = text;
        } else {
            xmlAct[@"type"]   = @0;  // mtUseLParameter
            xmlAct[@"sParam"] = @"";
        }
        [xmlActions addObject:xmlAct];
    }
    return xmlActions;
}

- (void)saveCurrentMacro:(id)sender {
    EditorView *ed = [self currentEditor];
    NSArray *actions = ed.macroActions;
    if (!actions.count) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = [[NppLocalizer shared] translate:@"No Macro Recorded"];
        a.informativeText = [[NppLocalizer shared] translate:@"Record a macro first using Start Recording."];
        a.icon = [[NSImage alloc] initWithContentsOfFile:
            NppConfigSubpath(@"plugins/Config/logo100px.png")];
        [a runModal];
        return;
    }

    // Build Shortcut dialog with conflict detection
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 400, 240)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered defer:NO];
    panel.title = [[NppLocalizer shared] translate:@"Shortcut"];
    [panel center];
    NSView *cv = panel.contentView;

    // Name field
    NSTextField *nameLbl = [NSTextField labelWithString:[[NppLocalizer shared] translate:@"Name:"]];
    nameLbl.frame = NSMakeRect(20, 205, 50, 16);
    [cv addSubview:nameLbl];

    NSTextField *nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(75, 201, 305, 24)];
    nameField.placeholderString = [[NppLocalizer shared] translate:@"Macro name"];
    [cv addSubview:nameField];

    // Modifier checkboxes
    NSButton *chkCmd = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"\u2318 Command"] target:nil action:nil];
    chkCmd.frame = NSMakeRect(20, 170, 140, 20);
    [cv addSubview:chkCmd];

    NSButton *chkCtrl = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"\u2303 Control"] target:nil action:nil];
    chkCtrl.frame = NSMakeRect(170, 170, 140, 20);
    [cv addSubview:chkCtrl];

    NSButton *chkOpt = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"\u2325 Option"] target:nil action:nil];
    chkOpt.frame = NSMakeRect(20, 143, 140, 20);
    [cv addSubview:chkOpt];

    NSButton *chkShift = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"\u21E7 Shift"] target:nil action:nil];
    chkShift.frame = NSMakeRect(170, 143, 100, 20);
    [cv addSubview:chkShift];

    NSTextField *plusKey = [NSTextField labelWithString:@"+"];
    plusKey.frame = NSMakeRect(270, 145, 15, 16);
    [cv addSubview:plusKey];

    // Key dropdown — A-Z, 0-9, F1-F12, special keys, punctuation
    NSPopUpButton *keyPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(288, 141, 95, 25) pullsDown:NO];
    {
        NSMutableArray *keys = [NSMutableArray arrayWithObject:@"None"];
        for (unichar c = 'A'; c <= 'Z'; c++) [keys addObject:[NSString stringWithFormat:@"%c", c]];
        for (unichar c = '0'; c <= '9'; c++) [keys addObject:[NSString stringWithFormat:@"%c", c]];
        for (int i = 1; i <= 12; i++) [keys addObject:[NSString stringWithFormat:@"F%d", i]];
        [keys addObjectsFromArray:@[@"Backspace", @"Tab", @"Enter", @"Escape", @"Space",
            @"Page Up", @"Page Down", @"End", @"Home", @"Left", @"Up", @"Right", @"Down",
            @"Insert", @"Delete", @";", @"=", @",", @"-", @".", @"/", @"`", @"[", @"\\", @"]", @"'"]];
        [keyPopup addItemsWithTitles:keys];
    }
    [cv addSubview:keyPopup];

    // Conflict warning label (red text)
    NSTextField *conflictLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 100, 360, 32)];
    conflictLabel.editable = NO;
    conflictLabel.bordered = NO;
    conflictLabel.drawsBackground = NO;
    conflictLabel.font = [NSFont systemFontOfSize:11];
    conflictLabel.textColor = [NSColor secondaryLabelColor];
    conflictLabel.stringValue = @"";
    conflictLabel.lineBreakMode = NSLineBreakByWordWrapping;
    conflictLabel.maximumNumberOfLines = 2;
    [cv addSubview:conflictLabel];

    // OK / Cancel — created before the checkConflict block so the block
    // can hold a strong reference and toggle btnOK.enabled live as the
    // user changes modifiers / key. This pairs with the conflict label
    // to make collisions impossible to silently bypass: warning text +
    // disabled OK = the user must clear or pick a non-conflicting
    // shortcut before they can save the macro.
    NSButton *btnOK = [[NSButton alloc] initWithFrame:NSMakeRect(195, 12, 90, 28)];
    btnOK.title = [[NppLocalizer shared] translate:@"OK"];
    btnOK.bezelStyle = NSBezelStyleRounded;
    btnOK.keyEquivalent = @"\r";
    btnOK.target = NSApp;
    btnOK.action = @selector(stopModal);
    [cv addSubview:btnOK];

    NSButton *btnCancel = [[NSButton alloc] initWithFrame:NSMakeRect(293, 12, 90, 28)];
    btnCancel.title = [[NppLocalizer shared] translate:@"Cancel"];
    btnCancel.bezelStyle = NSBezelStyleRounded;
    btnCancel.keyEquivalent = @"\033";
    btnCancel.target = NSApp;
    btnCancel.action = @selector(abortModal);
    [cv addSubview:btnCancel];

    // Live conflict check — walks every top-level menu (including the
    // App menu so ⌘H / ⌘Q / ⌘, are caught) and flags items that share
    // the candidate modifier+key combo.
    void (^checkConflict)(void) = ^{
        NSString *keyName = keyPopup.titleOfSelectedItem;
        if ([keyName isEqualToString:@"None"]) {
            conflictLabel.stringValue = @"";
            btnOK.enabled = YES;          // no key → no possible conflict
            return;
        }
        NSUInteger keyCode = 0;
        if (keyName.length == 1) keyCode = [keyName characterAtIndex:0];
        else if ([keyName hasPrefix:@"F"]) keyCode = 111 + [keyName substringFromIndex:1].intValue;
        if (keyCode == 0) {
            conflictLabel.stringValue = @"";
            btnOK.enabled = YES;
            return;
        }

        // Walk all menus checking for conflicts
        NSMutableString *msg = [NSMutableString string];
        __block void (^checkMenuBlock)(NSMenu *, NSString *);
        checkMenuBlock = ^(NSMenu *menu, NSString *cat) {
            for (NSMenuItem *mi in menu.itemArray) {
                if (mi.submenu) { checkMenuBlock(mi.submenu, cat); continue; }
                if (!mi.action || !mi.keyEquivalent.length) continue;
                NSEventModifierFlags m = mi.keyEquivalentModifierMask;
                BOOL mCmd = (m & NSEventModifierFlagCommand) != 0;
                BOOL mCtrl = (m & NSEventModifierFlagControl) != 0;
                BOOL mAlt = (m & NSEventModifierFlagOption) != 0;
                BOOL mShift = (m & NSEventModifierFlagShift) != 0;
                unichar mKey = [mi.keyEquivalent.uppercaseString characterAtIndex:0];
                if (mKey >= 0xF704 && mKey <= 0xF70F) mKey = 112 + (mKey - 0xF704);
                if (mKey == keyCode &&
                    mCmd == (chkCmd.state == NSControlStateValueOn) &&
                    mCtrl == (chkCtrl.state == NSControlStateValueOn) &&
                    mAlt == (chkOpt.state == NSControlStateValueOn) &&
                    mShift == (chkShift.state == NSControlStateValueOn)) {
                    [msg appendFormat:@"Conflict: %@ (%@)", mi.title, cat];
                }
            }
        };
        NSMenu *mainMenu = [NSApp mainMenu];
        for (NSMenuItem *topItem in mainMenu.itemArray) {
            if (!topItem.submenu) continue;
            checkMenuBlock(topItem.submenu, topItem.submenu.title ?: topItem.title);
        }
        if (msg.length) {
            conflictLabel.textColor = [NSColor systemRedColor];
            conflictLabel.stringValue = msg;
            btnOK.enabled = NO;          // collision → block save
        } else {
            conflictLabel.textColor = [NSColor secondaryLabelColor];
            conflictLabel.stringValue = [[NppLocalizer shared] translate:@"No shortcut conflicts."];
            btnOK.enabled = YES;
        }
    };

    // Strong references keep the NSBlockOperations alive through the modal
    // run loop (NSControl.target is zeroing-weak under ARC; see the
    // detailed comment in ShortcutMapperWindowController._modifyShortcut:).
    NSMutableArray *targetOps = [NSMutableArray array];
    for (NSButton *chk in @[chkCmd, chkCtrl, chkOpt, chkShift]) {
        NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:checkConflict];
        chk.target = op;
        chk.action = @selector(main);
        [targetOps addObject:op];
    }
    NSBlockOperation *keyOp = [NSBlockOperation blockOperationWithBlock:checkConflict];
    keyPopup.target = keyOp;
    keyPopup.action = @selector(main);
    [targetOps addObject:keyOp];

    // Initial check (also sets btnOK.enabled to its starting state)
    checkConflict();

    // same deal as the run-macro dialog — red x needs to end the modal session
    // or the app goes into a ghost-modal state where nothing is clickable (#283)
    id closeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowWillCloseNotification
                    object:panel
                     queue:nil
                usingBlock:^(NSNotification *note) { [NSApp abortModal]; }];

    NSModalResponse resp = [NSApp runModalForWindow:panel];
    [[NSNotificationCenter defaultCenter] removeObserver:closeObserver];
    [panel orderOut:nil];
    if (resp != NSModalResponseStop) return;

    NSString *name = [nameField.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) return;

    // Convert recorded actions to shortcuts.xml format
    NSArray *xmlActions = convertRecordedToXmlFormat(actions);

    // Read shortcut from dialog controls
    BOOL macroCmd   = (chkCmd.state == NSControlStateValueOn);
    BOOL macroCtrl  = (chkCtrl.state == NSControlStateValueOn);
    BOOL macroAlt   = (chkOpt.state == NSControlStateValueOn);
    BOOL macroShift = (chkShift.state == NSControlStateValueOn);
    NSUInteger macroKeyCode = 0;
    NSString *keyName = keyPopup.titleOfSelectedItem;
    if (keyName.length == 1) {
        macroKeyCode = [keyName characterAtIndex:0]; // 'A'-'Z' or '0'-'9'
    } else if ([keyName hasPrefix:@"F"]) {
        macroKeyCode = 111 + [keyName substringFromIndex:1].intValue; // F1=112..F12=123
    }

    ensureNppDirs();
    // Insert macro into shortcuts.xml in-place (preserves rest of file)
    addMacroToShortcutsXML(name, xmlActions, macroCtrl, macroAlt, macroShift, macroCmd, macroKeyCode);
    [self rebuildMacroMenu];

    // Clear the current recorded macro so Save button disables (Issue 1)
    EditorView *edAfterSave = [self currentEditor];
    if (edAfterSave) {
        // The macro has been saved — clear the "current" recording
        [edAfterSave startMacroRecording];
        [edAfterSave stopMacroRecording];
    }
    [self _refreshToolbarStates];
}

- (void)runSavedMacro:(NSMenuItem *)sender {
    NSArray<NSDictionary *> *actions = sender.representedObject;
    EditorView *ed = [self currentEditor];
    if (!ed || !actions.count) return;
    [ed runMacroActions:actions];
}

- (void)rebuildMacroMenu {
    // Find macro menu by tag (survives localization)
    NSMenuItem *macroItem = [[NSApp mainMenu] itemWithTag:9900];
    if (!macroItem) macroItem = [[NSApp mainMenu] itemWithTitle:@"Macro"];
    NSMenu *macroMenu = macroItem.submenu;
    if (!macroMenu) return;

    // Saved macros are inserted after "Trim Trailing Space and Save" (tagged 9901)
    NSMenuItem *marker = [macroMenu itemWithTag:9901];
    if (!marker) return;
    NSInteger markerIdx = [macroMenu indexOfItem:marker];

    // Remove old dynamically-added macro items (between marker and next separator)
    NSInteger removeFrom = markerIdx + 1;
    while (removeFrom < macroMenu.numberOfItems) {
        NSMenuItem *mi = [macroMenu itemAtIndex:removeFrom];
        if (mi.isSeparatorItem) break;
        [macroMenu removeItemAtIndex:removeFrom];
    }

    NSArray<NSDictionary *> *macros = loadMacrosFromShortcutsXML();
    NSMutableArray<NSDictionary *> *userMacros = [NSMutableArray array];
    for (NSDictionary *macro in macros) {
        if (![macro[@"name"] isEqualToString:@"Trim Trailing Space and Save"])
            [userMacros addObject:macro];
    }

    // Insert saved macros right after the marker
    NSInteger insertIdx = markerIdx + 1;
    for (NSDictionary *macro in userMacros) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:macro[@"name"]
                                                      action:@selector(runSavedMacro:)
                                               keyEquivalent:@""];
        item.representedObject = macro[@"actions"];

        // Apply shortcut from XML
        NSUInteger keyCode = [macro[@"Key"] integerValue];
        if (keyCode > 0) {
            BOOL hasCtrl  = [macro[@"Ctrl"]  isEqualToString:@"yes"];
            BOOL hasAlt   = [macro[@"Alt"]   isEqualToString:@"yes"];
            BOOL hasShift = [macro[@"Shift"] isEqualToString:@"yes"];
            BOOL hasCmd   = [macro[@"Cmd"]   isEqualToString:@"yes"];

            // Backward compat: old files without Cmd attribute treat Ctrl as Command
            if (!hasCmd && hasCtrl && !macro[@"Cmd"]) {
                hasCmd = YES; hasCtrl = NO;
            }

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

            item.keyEquivalent = key;
            item.keyEquivalentModifierMask = mods;
        }

        [macroMenu insertItem:item atIndex:insertIdx++];
    }
}

- (void)rebuildRunMenu {
    NSMenuItem *runItem = [[NSApp mainMenu] itemWithTag:9902];
    NSMenu *runMenu = runItem.submenu;
    if (!runMenu) return;

    // Remove previously inserted user commands (between last built-in item and final separator)
    // Built-in items: Run…, sep, PHP Help, Wiki Search, Open Selected…, sep, Modify Shortcut…
    // User commands go before the final separator (index = numberOfItems - 2)
    // We tag dynamic items with 9910 to identify them for cleanup.
    NSMutableArray<NSMenuItem *> *toRemove = [NSMutableArray array];
    for (NSMenuItem *mi in runMenu.itemArray)
        if (mi.tag == 9910) [toRemove addObject:mi];
    for (NSMenuItem *mi in toRemove)
        [runMenu removeItem:mi];

    // Load from shortcuts.xml
    NSString *path = nppShortcutsPath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:nil];
    if (!doc) return;

    NSArray *cmdNodes = [doc nodesForXPath:@"//UserDefinedCommands/Command" error:nil];
    if (!cmdNodes.count) return;

    NSInteger insertIdx = runMenu.numberOfItems - 2;
    if (insertIdx < 0) insertIdx = runMenu.numberOfItems;

    for (NSXMLElement *cmdEl in cmdNodes) {
        NSString *name = [[cmdEl attributeForName:@"name"] stringValue];
        NSString *cmdText = [cmdEl stringValue];
        if (!name.length || !cmdText.length) continue;

        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name
                                                      action:@selector(_runSavedCommand:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = cmdText;
        item.tag = 9910;

        NSUInteger keyCode = [[[cmdEl attributeForName:@"Key"] stringValue] integerValue];
        if (keyCode > 0) {
            BOOL hasCtrl  = [[[cmdEl attributeForName:@"Ctrl"]  stringValue] isEqualToString:@"yes"];
            BOOL hasAlt   = [[[cmdEl attributeForName:@"Alt"]   stringValue] isEqualToString:@"yes"];
            BOOL hasShift = [[[cmdEl attributeForName:@"Shift"] stringValue] isEqualToString:@"yes"];
            BOOL hasCmd   = [[[cmdEl attributeForName:@"Cmd"]   stringValue] isEqualToString:@"yes"];

            if (!hasCmd && hasCtrl && ![cmdEl attributeForName:@"Cmd"]) {
                hasCmd = YES; hasCtrl = NO;
            }

            NSEventModifierFlags mods = 0;
            if (hasCmd)   mods |= NSEventModifierFlagCommand;
            if (hasCtrl)  mods |= NSEventModifierFlagControl;
            if (hasAlt)   mods |= NSEventModifierFlagOption;
            if (hasShift) mods |= NSEventModifierFlagShift;

            unichar kc = 0;
            if (keyCode >= 112 && keyCode <= 123) kc = NSF1FunctionKey + (keyCode - 112);
            else if (keyCode >= 'A' && keyCode <= 'Z') kc = keyCode + 32;
            else if (keyCode >= '0' && keyCode <= '9') kc = keyCode;
            else kc = keyCode;
            if (kc) {
                item.keyEquivalent = [NSString stringWithCharacters:&kc length:1];
                item.keyEquivalentModifierMask = mods;
            }
        }

        [runMenu insertItem:item atIndex:insertIdx++];
    }
}

- (void)trimTrailingSpaceAndSave:(id)sender {
    for (EditorView *ed in _tabManager.allEditors) {
        [ed trimTrailingWhitespace:sender];
        if (ed.filePath && ed.isModified) {
            NSError *err;
            [ed saveError:&err];
        }
    }
}

#pragma mark - Panel placeholder actions

- (void)showDefineLanguage:(id)sender {
    [[UserDefineDialog sharedController] showWithLanguage:nil];
}

#pragma mark - Side panel show/hide

- (void)_setPanelVisible:(NSView *)panel title:(NSString *)title show:(BOOL)show {
    if (!panel) return;
    if (show) {
        // Remember the English key so NPPLocalizationChanged can refresh
        // the PanelFrame's label without each panel implementing its own
        // observer. `title` at call sites is the English string literal
        // (e.g., @"Document Map"); we translate once here, then re-apply
        // via -_refreshOpenPanelTitles on locale change.
        if (!_panelTitleKeys)
            _panelTitleKeys = [NSMapTable weakToStrongObjectsMapTable];
        NSString *key = title ?: @"";
        [_panelTitleKeys setObject:key forKey:panel];
        NSString *localized = [[NppLocalizer shared] translate:key];
        [_sidePanelHost showPanel:panel withTitle:localized];
        if ([_sidePanelHost hasVisiblePanels] && [_editorSplitView isSubviewCollapsed:_sidePanelHost]) {
            CGFloat w = NSWidth(_editorSplitView.frame);
            BOOL dockLeft = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefDockPanelsOnLeft];
            CGFloat targetWidth = [[NSUserDefaults standardUserDefaults] doubleForKey:kPrefSidePanelWidth];
            if (targetWidth < 150) targetWidth = 280;
            CGFloat position = dockLeft ? MIN(w - 200, targetWidth) : MAX(200, w - targetWidth);
            [_editorSplitView setPosition:position ofDividerAtIndex:0];
        }
    } else {
        // Informal selector: any panel that needs to flush state (e.g.
        // ProjectPanel saving dirty workspaces) implements -panelWillClose.
        // Fires once per hide regardless of trigger (PanelFrame X, tab
        // toggle-off, plugin NPPM_DMM_HIDEPANEL).
        if ([panel respondsToSelector:@selector(panelWillClose)])
            [(id)panel performSelector:@selector(panelWillClose)];
        [_sidePanelHost hidePanel:panel];
        [_panelTitleKeys removeObjectForKey:panel];
        if (!_sidePanelHost.hasVisiblePanels) {
            BOOL dockLeft = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefDockPanelsOnLeft];
            CGFloat position = dockLeft ? 0 : NSWidth(_editorSplitView.frame);
            [_editorSplitView setPosition:position ofDividerAtIndex:0];
        }
    }
    [self _refreshToolbarStates];
    [self _saveOpenSidePanels];
}

// Persist the set of open built-in side panels (issue #132). Called from
// _setPanelVisible: on every open/close so the stored set survives a
// crash, not just a clean quit. Plugin panels and the Git panel are
// filtered out via the _restorableSidePanels() whitelist.
- (void)_saveOpenSidePanels {
    if (!_panelTitleKeys) return;
    NSDictionary *whitelist = _restorableSidePanels();
    NSMutableArray *openPanels = [NSMutableArray array];
    for (NSView *panel in [[_panelTitleKeys keyEnumerator] allObjects]) {
        NSString *key = [_panelTitleKeys objectForKey:panel];
        if (key && whitelist[key]) {
            BOOL popped = [_sidePanelHost isPanelPopped:panel];
            [openPanels addObject:@{@"id": key, @"popped": @(popped)}];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:openPanels forKey:kOpenSidePanelsKey];
}

// Re-open the side panels that were open at last quit (issue #132).
// Gated on the "Remember panel visibility" preference; invoked once by
// AppDelegate after the primary window is shown, so secondary windows
// (Window > New Window) do not inherit the restore.
- (void)restoreSidePanels {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kPrefPanelKeepState]) return;
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kOpenSidePanelsKey];
    if (![saved isKindOfClass:[NSArray class]]) return;

    NSDictionary<NSString *, NSString *> *whitelist = _restorableSidePanels();
    for (id item in saved) {
        NSString *key = nil;
        BOOL popped = NO;
        if ([item isKindOfClass:[NSString class]]) {
            key = item;
        } else if ([item isKindOfClass:[NSDictionary class]]) {
            key = item[@"id"];
            popped = [item[@"popped"] boolValue];
        }
        if (![key isKindOfClass:[NSString class]]) continue;
        NSString *selName = whitelist[key];
        if (!selName) continue;                       // unknown / plugin / Git
        SEL sel = NSSelectorFromString(selName);
        if (![self respondsToSelector:sel]) continue;
        // The show selectors toggle; at launch the panel is closed, so a
        // single call opens it.
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:sel withObject:nil];
        #pragma clang diagnostic pop

        if (popped) {
            // Find the panel instance that was just opened (it will now be in _panelTitleKeys)
            NSView *openedPanel = nil;
            for (NSView *p in [[_panelTitleKeys keyEnumerator] allObjects]) {
                if ([[_panelTitleKeys objectForKey:p] isEqualToString:key]) {
                    openedPanel = p;
                    break;
                }
            }
            if (openedPanel) {
                [_sidePanelHost popOutPanel:openedPanel];
            }
        }
    }
}

// Re-apply localized titles to every currently-open panel. Called on
// NPPLocalizationChanged; iterates _panelTitleKeys and re-invokes
// SidePanelHost.showPanel:withTitle: so each PanelFrame's label refreshes.
- (void)_refreshOpenPanelTitles {
    if (!_panelTitleKeys) return;
    // Snapshot keys — we're not mutating the map here, but this keeps
    // the iteration stable if SidePanelHost's showPanel: synchronously
    // triggered any observer that did.
    NSArray<NSView *> *panels = [[_panelTitleKeys keyEnumerator] allObjects];
    for (NSView *p in panels) {
        NSString *key = [_panelTitleKeys objectForKey:p];
        if (!key) continue;
        NSString *localized = [[NppLocalizer shared] translate:key];
        [_sidePanelHost showPanel:p withTitle:localized];
    }
}

// ── Plugin-panel docking (public API) ─────────────────────────────────────
//
// These three methods are the public surface for the NPPM_DMM_* plugin
// messages. They forward to `_setPanelVisible:title:show:` so plugin panels
// share exactly the same split-view divider handling, toolbar refresh, and
// SidePanelHost bookkeeping as built-in panels. NppPluginManager owns the
// strong retain on plugin views; this class only manages hierarchy.

- (void)showPluginPanel:(NSView *)panel withTitle:(NSString *)title {
    if (!panel) return;
    [self _setPanelVisible:panel title:(title ?: @"") show:YES];
}

- (void)hidePluginPanel:(NSView *)panel {
    if (!panel) return;
    [self _setPanelVisible:panel title:@"" show:NO];
}

- (BOOL)isPluginPanelShown:(NSView *)panel {
    if (!panel || !_sidePanelHost) return NO;
    return [_sidePanelHost hasPanel:panel];
}

// ── SidePanelHostDelegate ─────────────────────────────────────────────────
//
// Called when the user clicks the close X in any PanelFrame's title bar.
// Single generic handler — no per-panel-class branching needed because
// `_setPanelVisible:title:show:NO` does the right thing for built-in and
// plugin panels alike.
- (void)sidePanelHost:(SidePanelHost *)host
    didRequestCloseForContentView:(NSView *)contentView {
    if (!contentView) return;
    [self _setPanelVisible:contentView title:@"" show:NO];
}

// Fired after a pop-out / dock-back finishes. The side-pane divider must
// track the number of DOCKED panels: collapse when the stack empties
// (everything is popped), re-expand when a dock-back brings a panel into
// an otherwise-empty pane.
- (void)sidePanelHostDidChangePanelLayout:(SidePanelHost *)host {
    BOOL dockLeft = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefDockPanelsOnLeft];
    if (!host.hasVisiblePanels) {
        CGFloat position = dockLeft ? 0 : NSWidth(_editorSplitView.frame);
        [_editorSplitView setPosition:position ofDividerAtIndex:0];
    } else if ([_editorSplitView isSubviewCollapsed:_sidePanelHost]) {
        CGFloat w = NSWidth(_editorSplitView.frame);
        CGFloat targetWidth = [[NSUserDefaults standardUserDefaults] doubleForKey:kPrefSidePanelWidth];
        if (targetWidth < 150) targetWidth = 280;
        CGFloat position = dockLeft ? MIN(w - 200, targetWidth) : MAX(200, w - targetWidth);
        [_editorSplitView setPosition:position ofDividerAtIndex:0];
    }
    [self _refreshToolbarStates];
}

- (void)showDocumentList:(id)sender {
    if (!_docListPanel) {
        _docListPanel = [[DocumentListPanel alloc] initWithTabManager:_tabManager];
        _docListPanel.delegate = self;
    }
    BOOL open = [_sidePanelHost hasPanel:_docListPanel];
    if (!open) [_docListPanel reloadData];
    [self _setPanelVisible:_docListPanel title:@"Document List" show:!open];
}

- (void)documentListPanelDidRequestClose:(DocumentListPanel *)panel {
    [self _setPanelVisible:panel title:@"Document List" show:NO];
}

// Document List sees ALL open editors across every view (primary + both split
// panes), so tabs moved via "Move to Other …View" still appear and remain
// reachable (important when the tab bar is hidden).
- (NSArray<EditorView *> *)documentListPanelEditors:(DocumentListPanel *)panel {
    NSMutableArray<EditorView *> *all = [NSMutableArray array];
    for (TabManager *mgr in @[_tabManager, _subTabManagerH, _subTabManagerV]) {
        if (mgr) [all addObjectsFromArray:mgr.allEditors];
    }
    return all;
}

// Activate a clicked editor in whichever view owns it. selectTabAtIndex: fires
// tabManager:didSelectEditor:, which already sets _activeTabManager and focuses
// the correct pane — so no extra bookkeeping here.
- (BOOL)documentListPanel:(DocumentListPanel *)panel activateEditor:(EditorView *)editor {
    for (TabManager *mgr in @[_tabManager, _subTabManagerH, _subTabManagerV]) {
        if (!mgr) continue;
        NSUInteger idx = [mgr.allEditors indexOfObject:editor];
        if (idx != NSNotFound) {
            [mgr selectTabAtIndex:(NSInteger)idx];
            return YES;
        }
    }
    return NO;
}

- (EditorView *)documentListPanelCurrentEditor:(DocumentListPanel *)panel {
    return [self currentEditor];
}

// The tab color for a document (matching the colored tab), found in whichever
// view owns the editor. nil when the tab has no custom color.
- (NSColor *)documentListPanel:(DocumentListPanel *)panel backgroundColorForEditor:(EditorView *)editor {
    for (TabManager *mgr in @[_tabManager, _subTabManagerH, _subTabManagerV]) {
        if (!mgr) continue;
        NSUInteger idx = [mgr.allEditors indexOfObject:editor];
        if (idx != NSNotFound)
            return [NppTabBar tabFillColorForId:[mgr.tabBar tabColorAtIndex:(NSInteger)idx]];
    }
    return nil;
}

- (void)showClipboardHistory:(id)sender {
    if (!_clipboardPanel) {
        _clipboardPanel = [[ClipboardHistoryPanel alloc] init];
        _clipboardPanel.delegate = self;
    }
    BOOL open = [_sidePanelHost hasPanel:_clipboardPanel];
    if (!open) [_clipboardPanel startMonitoring];
    else       [_clipboardPanel stopMonitoring];
    [self _setPanelVisible:_clipboardPanel title:@"Clipboard History" show:!open];
}

- (void)clipboardHistoryPanelDidRequestClose:(ClipboardHistoryPanel *)panel {
    [_clipboardPanel stopMonitoring];
    [self _setPanelVisible:_clipboardPanel title:@"Clipboard History" show:NO];
}

- (void)showCommandPalette:(id)sender {
    if (!_commandPalette) _commandPalette = [[CommandPalettePanel alloc] init];
    if (_commandPalette.isVisible) {
        [_commandPalette orderOut:nil];
    } else {
        [_commandPalette showOverWindow:self.window];
    }
}

- (void)showDocumentMap:(id)sender {
    if (!_docMapPanel) {
        _docMapPanel = [[DocumentMapPanel alloc] init];
        _docMapPanel.delegate = self;
    }
    BOOL open = [_sidePanelHost hasPanel:_docMapPanel];
    if (!open) [_docMapPanel setTrackedEditor:[self currentEditor]];
    [self _setPanelVisible:_docMapPanel title:@"Document Map" show:!open];
}

- (void)documentMapPanelDidRequestClose:(DocumentMapPanel *)panel {
    [self _setPanelVisible:_docMapPanel title:@"Document Map" show:NO];
}

- (void)showFunctionList:(id)sender {
    if (!_funcListPanel) {
        _funcListPanel = [[FunctionListPanel alloc] init];
        _funcListPanel.delegate = (id<FunctionListPanelDelegate>)self;
    }
    BOOL open = [_sidePanelHost hasPanel:_funcListPanel];
    if (!open) [_funcListPanel loadEditor:[self currentEditor]];
    [self _setPanelVisible:_funcListPanel title:@"Function List" show:!open];
}

- (void)functionListPanelDidRequestClose:(FunctionListPanel *)panel {
    [self _setPanelVisible:panel title:@"Function List" show:NO];
}

- (void)showFolderAsWorkspace:(id)sender {
    // Phase 2 stub — superseded by showFolderTreePanel:
    [self showFolderTreePanel:sender];
}

- (void)showFolderTreePanel:(id)sender {
    if (!_folderTreePanel) {
        FolderTreePanel *ftp = [[FolderTreePanel alloc] init];
        ftp.delegate = self;
        _folderTreePanel = ftp;
    }
    BOOL open = [_sidePanelHost hasPanel:_folderTreePanel];
    if (!open) {
        NSString *path = [self currentEditor].filePath;
        [(FolderTreePanel *)_folderTreePanel setActiveFileURL:
            path ? [NSURL fileURLWithPath:path] : [NSURL fileURLWithPath:NSHomeDirectory()]];
    }
    [self _setPanelVisible:_folderTreePanel title:@"Folder as Workspace" show:!open];
    [[NSUserDefaults standardUserDefaults] setBool:!open forKey:@"FolderTreePanelVisible"];
}

- (void)showGitPanel:(id)sender {
    if (!_gitPanel) {
        GitPanel *gp = [[GitPanel alloc] init];
        gp.delegate = self;
        _gitPanel = gp;
    }
    BOOL open = [_sidePanelHost hasPanel:_gitPanel];
    if (!open) [self _updateGitPanelForPath:[self currentEditor].filePath];
    [self _setPanelVisible:_gitPanel title:@"Source Control" show:!open];
}

- (void)_updateGitPanelForPath:(NSString *)filePath {
    if (!_gitPanel) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // Try file path first, fall back to working directory
        NSString *root = nil;
        if (filePath.length) root = [GitHelper gitRootForPath:filePath];
        if (!root) root = [GitHelper gitRootForPath:
                           [NSFileManager defaultManager].currentDirectoryPath];
        dispatch_async(dispatch_get_main_queue(), ^{
            [(GitPanel *)self->_gitPanel setRepoRoot:root];
            [(GitPanel *)self->_gitPanel refresh];
        });
    });
}

- (void)toggleSpellCheck:(id)sender {
    EditorView *ed = [self currentEditor];
    ed.spellCheckEnabled = !ed.spellCheckEnabled;
}

- (void)_updateGitBranch:(NSString *)filePath {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *root   = filePath ? [GitHelper gitRootForPath:filePath] : nil;
        NSString *branch = root ? [GitHelper currentBranchAtRoot:root] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_gitBranchLabel.stringValue =
                branch ? [@"\u2387 " stringByAppendingString:branch] : @"";
        });
    });
}

// Issue #76 \u2014 refresh the git diff gutter when an editor is saved, but only
// when the GitPanel is open AND the saved editor belongs to this window.
// The notification post is in EditorView.saveFileToPath:; without this
// indirection the editor would have to spawn /usr/bin/git on every save,
// which on a Mac without Xcode CLT triggers the install prompt.
- (void)_editorDidSave:(NSNotification *)note {
    EditorView *editor = note.object;
    if (![editor isKindOfClass:[EditorView class]]) return;
    // Multi-window safety: only react to editors that belong to this window.
    if (editor.window != self.window) return;

    // Refresh the Document List panel's floppy indicators on save.
    if (_docListPanel && [_sidePanelHost hasPanel:_docListPanel])
        [_docListPanel refreshModifiedStates];

    if (!_gitPanel || ![_sidePanelHost hasPanel:_gitPanel]) return;
    [editor updateGitDiffMarkers];
    [self _updateGitBranch:editor.filePath];
}

// The Shortcut Mapper saved changes — re-push Scintilla-command overrides into every
// open editor's keymap so edits take effect immediately (no restart). Each editor's
// applyScintillaKeyOverrides is a no-op when there are no overrides to apply, so this
// is harmless for non-Scintilla shortcut changes and for non-customising users.
- (void)_shortcutsChanged:(NSNotification *)note {
    for (TabManager *mgr in @[_tabManager, _subTabManagerH, _subTabManagerV])
        for (EditorView *ed in mgr.allEditors.copy)
            [ed applyScintillaKeyOverrides];
}

- (void)_showProjectPanelTab:(NSInteger)tab {
    if (!_projectPanel) {
        _projectPanel = [[ProjectPanel alloc] init];
        _projectPanel.delegate = self;
    }
    BOOL wasOpen = [_sidePanelHost hasPanel:_projectPanel];
    if (wasOpen && _projectPanel.activeTab == tab) {
        // Toggle off if same tab clicked again
        [self _setPanelVisible:_projectPanel title:@"Project Panel" show:NO];
    } else {
        [_projectPanel activateTab:tab];
        if (!wasOpen)
            [self _setPanelVisible:_projectPanel title:@"Project Panel" show:YES];
    }
}

- (void)showProjectPanel1:(id)sender { [self _showProjectPanelTab:0]; }
- (void)showProjectPanel2:(id)sender { [self _showProjectPanelTab:1]; }
- (void)showProjectPanel3:(id)sender { [self _showProjectPanelTab:2]; }

- (void)_ensureHorizontalViewVisible {
    if ([_hSplitView isSubviewCollapsed:_subEditorContainerH]) {
        CGFloat h = NSHeight(_hSplitView.frame);
        [_hSplitView setPosition:MAX(100, h / 2.0) ofDividerAtIndex:0];
    }
}

- (void)_ensureVerticalViewVisible {
    if ([_vSplitView isSubviewCollapsed:_subEditorContainerV]) {
        CGFloat w = NSWidth(_vSplitView.frame);
        [_vSplitView setPosition:MAX(100, w / 2.0) ofDividerAtIndex:0];
    }
}

// Move the same EditorView object (no content copy, no save prompt).
// If the editor is already in the secondary pane, move it back to primary.
- (void)_moveEditor:(EditorView *)ed toVertical:(BOOL)vertical {
    if (!ed) return;
    TabManager *sub = vertical ? _subTabManagerV : _subTabManagerH;

    // Find which tab manager currently owns this editor (don't rely on
    // _activeTabManager — it can mutate during evict/adopt callbacks).
    TabManager *source = nil;
    for (TabManager *mgr in @[_tabManager, _subTabManagerH, _subTabManagerV])
        if ([mgr.allEditors containsObject:ed]) { source = mgr; break; }
    if (!source) return;

    if (source == sub) {
        // Editor is in the secondary pane — move back to primary
        [sub evictEditor:ed];
        [_tabManager adoptEditor:ed];
        // Only collapse when the secondary pane has no remaining tabs
        if (sub.allEditors.count == 0) {
            if (vertical)
                [_vSplitView setPosition:MAX(NSWidth(_vSplitView.frame),   9999) ofDividerAtIndex:0];
            else
                [_hSplitView setPosition:MAX(NSHeight(_hSplitView.frame),  9999) ofDividerAtIndex:0];
        }
    } else {
        // Move from current pane to secondary
        [source evictEditor:ed];
        if (source == _tabManager && _tabManager.allEditors.count == 0)
            [_tabManager addNewTab];
        [sub adoptEditor:ed];
        if (vertical) [self _ensureVerticalViewVisible];
        else          [self _ensureHorizontalViewVisible];
    }
    [self updateTitle];
}

// Clone: share the same Scintilla document in the other view.
// Both views stay in sync — edits in one appear in the other.
- (void)_cloneEditor:(EditorView *)ed toVertical:(BOOL)vertical {
    if (!ed) return;
    TabManager *sub = vertical ? _subTabManagerV : _subTabManagerH;
    EditorView *clone = [sub addNewTab];
    [clone shareDocumentFrom:ed];
    [sub refreshCurrentTabTitle];
    if (vertical) [self _ensureVerticalViewVisible];
    else          [self _ensureHorizontalViewVisible];
    [self updateTitle];
}

- (void)moveToOtherVerticalView:(id)sender {
    [self _moveEditor:[self currentEditor] toVertical:YES];
}

- (void)cloneToOtherVerticalView:(id)sender {
    [self _cloneEditor:[self currentEditor] toVertical:YES];
}

- (void)moveToOtherHorizontalView:(id)sender {
    [self _moveEditor:[self currentEditor] toVertical:NO];
}

- (void)cloneToOtherHorizontalView:(id)sender {
    [self _cloneEditor:[self currentEditor] toVertical:NO];
}

- (void)resetView:(id)sender {
    // Move every editor from V secondary back to primary
    for (EditorView *e in [_subTabManagerV.allEditors copy]) {
        [_subTabManagerV evictEditor:e];
        [_tabManager adoptEditor:e];
    }
    // Move every editor from H secondary back to primary
    for (EditorView *e in [_subTabManagerH.allEditors copy]) {
        [_subTabManagerH evictEditor:e];
        [_tabManager adoptEditor:e];
    }
    // Collapse both secondary panes
    [_vSplitView setPosition:MAX(NSWidth(_vSplitView.frame),   9999) ofDividerAtIndex:0];
    [_hSplitView setPosition:MAX(NSHeight(_hSplitView.frame),  9999) ofDividerAtIndex:0];

    // Turn off scroll sync — no split view to sync with
    if (_syncVerticalScrolling || _syncHorizontalScrolling) {
        _syncVerticalScrolling = NO;
        _syncHorizontalScrolling = NO;
        [self _updateScrollSyncTimer];
        [self _refreshToolbarStates];
    }

    [self updateTitle];
}

#pragma mark - Pin / Lock Tab

- (void)pinCurrentTab:(id)sender {
    NSInteger sel = _activeTabManager.tabBar.selectedIndex;
    if (sel < 0) return;
    BOOL currently = [_activeTabManager.tabBar isTabPinnedAtIndex:sel];
    [_activeTabManager.tabBar pinTabAtIndex:sel toggle:!currently];

    // Auto-move pinned tab to start (after other pinned tabs)
    if (!currently) {
        // Find insertion point: after the last already-pinned tab
        NSInteger insertAt = 0;
        for (NSInteger i = 0; i < _activeTabManager.tabBar.tabCount; i++) {
            if (i == sel) continue; // skip the tab being pinned
            if ([_activeTabManager.tabBar isTabPinnedAtIndex:i])
                insertAt = i + 1;
        }
        // Move tab from sel to insertAt by repeated swaps
        while (sel > insertAt) {
            [_activeTabManager swapEditorAtIndex:sel withIndex:sel - 1];
            sel--;
        }
    }
}

// "Lock Tab" in View > Tab is an alias for pin.
- (void)lockCurrentTab:(id)sender { [self pinCurrentTab:sender]; }

#pragma mark - Tab Bar Wrap

- (void)toggleTabBarWrap:(id)sender {
    BOOL newWrap = !_tabManager.tabBar.wrapMode;
    _tabManager.tabBar.wrapMode     = newWrap;
    _subTabManagerH.tabBar.wrapMode = newWrap;
    _subTabManagerV.tabBar.wrapMode = newWrap;
    [[NSUserDefaults standardUserDefaults] setBool:newWrap forKey:kPrefTabBarWrap];
}

#pragma mark - Sort Tabs

- (void)_sortTabsBy:(NSInteger)key ascending:(BOOL)asc {
    NSArray<EditorView *> *sorted = [_activeTabManager.allEditors
        sortedArrayUsingComparator:^NSComparisonResult(EditorView *a, EditorView *b) {
            NSString *ka, *kb;
            if (key == 0) {          // name
                ka = a.displayName;
                kb = b.displayName;
            } else if (key == 1) {   // extension / type
                ka = a.filePath.pathExtension ?: @"";
                kb = b.filePath.pathExtension ?: @"";
            } else {                 // full path
                ka = a.filePath ?: a.displayName;
                kb = b.filePath ?: b.displayName;
            }
            NSComparisonResult r = [ka compare:kb options:NSCaseInsensitiveSearch];
            return asc ? r : (NSComparisonResult)(-(NSInteger)r);
        }];
    [_activeTabManager reorderEditors:sorted];
}

- (void)sortTabsByFileNameAsc:(id)sender  { [self _sortTabsBy:0 ascending:YES];  }
- (void)sortTabsByFileNameDesc:(id)sender { [self _sortTabsBy:0 ascending:NO];   }
- (void)sortTabsByFileTypeAsc:(id)sender  { [self _sortTabsBy:1 ascending:YES];  }
- (void)sortTabsByFileTypeDesc:(id)sender { [self _sortTabsBy:1 ascending:NO];   }
- (void)sortTabsByFullPathAsc:(id)sender  { [self _sortTabsBy:2 ascending:YES];  }
- (void)sortTabsByFullPathDesc:(id)sender { [self _sortTabsBy:2 ascending:NO];   }

#pragma mark - Windows… dialog

- (void)showWindowsList:(id)sender {
    // Collect all editors from primary + both secondary tab managers.
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    NSArray<TabManager *> *managers = @[_tabManager, _subTabManagerH, _subTabManagerV];
    for (NSInteger mi = 0; mi < 3; mi++) {
        NSArray<EditorView *> *eds = managers[mi].allEditors;
        for (NSInteger ei = 0; ei < (NSInteger)eds.count; ei++) {
            EditorView *ed = eds[ei];
            [rows addObject:@{
                @"name":     ed.displayName,
                @"path":     ed.filePath ?: @"",
                @"modified": @(ed.isModified),
                @"mgr":      @(mi),
                @"idx":      @(ei),
            }];
        }
    }
    if (!rows.count) return;

    // Build a modal panel with a table.
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,540,300)
                                                styleMask:NSWindowStyleMaskTitled |
                                                          NSWindowStyleMaskClosable |
                                                          NSWindowStyleMaskResizable
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    panel.title = [[NppLocalizer shared] translate:@"Windows"];
    [panel center];

    NSView *content = panel.contentView;

    // Table
    NSTableView *tv = [[NSTableView alloc] init];
    tv.allowsMultipleSelection = YES;
    tv.usesAlternatingRowBackgroundColors = YES;
    tv.focusRingType = NSFocusRingTypeNone;
    tv.rowHeight = 17;

    NSTableColumn *col1 = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    col1.title = [[NppLocalizer shared] translate:@"File Name"];  col1.width = 160; col1.resizingMask = NSTableColumnUserResizingMask;
    NSTableColumn *col2 = [[NSTableColumn alloc] initWithIdentifier:@"ext"];
    col2.title = [[NppLocalizer shared] translate:@"Type"];       col2.width = 60;  col2.resizingMask = NSTableColumnUserResizingMask;
    NSTableColumn *col3 = [[NSTableColumn alloc] initWithIdentifier:@"path"];
    col3.title = [[NppLocalizer shared] translate:@"Path"];       col3.width = 260; col3.resizingMask = NSTableColumnUserResizingMask;
    [tv addTableColumn:col1]; [tv addTableColumn:col2]; [tv addTableColumn:col3];

    // Use a simple block-based datasource object.
    NSScrollView *sv = [[NSScrollView alloc] init];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.hasVerticalScroller = YES;
    sv.documentView = tv;
    [content addSubview:sv];

    NSButton *activateBtn = [NSButton buttonWithTitle:[[NppLocalizer shared] translate:@"Activate"] target:nil action:nil];
    activateBtn.translatesAutoresizingMaskIntoConstraints = NO;
    activateBtn.keyEquivalent = @"\r";
    NSButton *closeBtn = [NSButton buttonWithTitle:[[NppLocalizer shared] translate:@"Close"] target:nil action:nil];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    closeBtn.keyEquivalent = @"\033";
    [content addSubview:activateBtn];
    [content addSubview:closeBtn];

    [NSLayoutConstraint activateConstraints:@[
        [sv.topAnchor    constraintEqualToAnchor:content.topAnchor    constant:8],
        [sv.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:8],
        [sv.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-8],
        [sv.bottomAnchor  constraintEqualToAnchor:activateBtn.topAnchor constant:-8],

        [activateBtn.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-8],
        [activateBtn.bottomAnchor   constraintEqualToAnchor:content.bottomAnchor   constant:-12],
        [closeBtn.trailingAnchor    constraintEqualToAnchor:activateBtn.leadingAnchor constant:-8],
        [closeBtn.bottomAnchor      constraintEqualToAnchor:activateBtn.bottomAnchor],
    ]];

    // Datasource/delegate via a local helper block-object stored in associated objects.
    _NPPWindowsListHelper *helper = [[_NPPWindowsListHelper alloc] initWithRows:rows];
    helper.tableView = tv;
    tv.dataSource = helper;
    tv.delegate   = helper;
    [tv reloadData];
    if (rows.count) [tv selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    objc_setAssociatedObject(panel, "helper", helper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Activate button
    __weak typeof(self) wSelf = self;
    __weak NSPanel *wPanel = panel;
    __weak _NPPWindowsListHelper *wHelper = helper;
    activateBtn.target = helper;
    activateBtn.action = @selector(activatePressed:);
    helper.activateHandler = ^{
        NSInteger row = wHelper.tableView.selectedRow;
        if (row < 0 || row >= (NSInteger)rows.count) return;
        NSDictionary *entry = rows[row];
        NSInteger mi = [entry[@"mgr"] integerValue];
        NSInteger ei = [entry[@"idx"] integerValue];
        typeof(self) sSelf = wSelf;
        if (!sSelf) return;
        NSArray<TabManager *> *mgrs = @[sSelf->_tabManager, sSelf->_subTabManagerH, sSelf->_subTabManagerV];
        TabManager *tm = mgrs[mi];
        [tm selectTabAtIndex:ei];
        [NSApp stopModal];
        [wPanel orderOut:nil];
    };
    closeBtn.target = helper;
    closeBtn.action = @selector(closePressed:);
    helper.closeHandler = ^{
        [NSApp stopModal];
        [wPanel orderOut:nil];
    };

    // Double-click = activate
    tv.doubleAction = @selector(activatePressed:);
    tv.target = helper;

    // without this the close button (red x) leaves us stuck in modal limbo
    id closeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowWillCloseNotification
                    object:panel
                     queue:nil
                usingBlock:^(NSNotification *note) { [NSApp stopModal]; }];

    [NSApp runModalForWindow:panel];
    [[NSNotificationCenter defaultCenter] removeObserver:closeObserver];
}

#pragma mark - UI Validation

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    SEL action = item.action;
    // Only NSMenuItem supports -setState: (checkmarks). NSToolbarItem — including
    // the per-button subitems of the Tahoe NSToolbarItemGroups, which AppKit
    // auto-validates through this same method — does NOT, and sending setState:
    // to one aborts the app. Resolve to a menu item or nil so the state-setting
    // calls below are a safe no-op for toolbar (and other non-menu) items.
    NSMenuItem *mi = [(NSObject *)item isKindOfClass:[NSMenuItem class]]
        ? (NSMenuItem *)item : nil;
    EditorView *ed = [self currentEditor];
    BOOL recording = ed && ed.isRecordingMacro;

    // Dynamic menu title for toggle item
    if (action == @selector(toggleMacroRecording:)) {
        if ([(NSObject *)item respondsToSelector:@selector(setTitle:)])
            [(NSMenuItem *)item setTitle:recording ? @"Stop Recording" : @"Start Recording"];
        return ed != nil;
    }

    if (action == @selector(startMacroRecording:)) return ed && !recording;
    if (action == @selector(stopMacroRecording:))  return ed && recording;
    if (action == @selector(runMacro:))             return ed && !recording && ed.macroActions.count > 0;
    if (action == @selector(runMacroMultipleTimes:)) return ed && !recording;  // can run saved macros
    // "Run Macro on Files…" — works with no open tabs (it'll open them as needed).
    // Disabled only during active per-buffer recording, to avoid the user
    // starting a batch that races with their own keystroke recording.
    if (action == @selector(showBatchRunDialog:))   return !recording;
    if (action == @selector(saveCurrentMacro:))     return ed && !recording && ed.macroActions.count > 0;
    if (action == @selector(runSavedMacro:))        return ed && !recording;
    if (action == @selector(trimTrailingSpaceAndSave:)) return _tabManager.allEditors.count > 0;

    // Scroll sync — disabled when no split view is active
    BOOL hasSplitView = (_subTabManagerV.allEditors.count > 0 || _subTabManagerH.allEditors.count > 0);
    if (action == @selector(toggleSyncVerticalScrolling:)) {
        [mi setState:_syncVerticalScrolling ? NSControlStateValueOn : NSControlStateValueOff];
        return hasSplitView;
    }
    if (action == @selector(toggleSyncHorizontalScrolling:)) {
        [mi setState:_syncHorizontalScrolling ? NSControlStateValueOn : NSControlStateValueOff];
        return hasSplitView;
    }

    // Split-view mutual exclusion: V and H secondary views can't both be active
    BOOL vHasTabs = (_subTabManagerV.allEditors.count > 0);
    BOOL hHasTabs = (_subTabManagerH.allEditors.count > 0);

    if (action == @selector(moveToOtherVerticalView:)   ||
        action == @selector(cloneToOtherVerticalView:))
        return !hHasTabs;

    if (action == @selector(moveToOtherHorizontalView:)  ||
        action == @selector(cloneToOtherHorizontalView:))
        return !vHasTabs;

    if (action == @selector(resetView:))
        return vHasTabs || hHasTabs;

    // Always on Top checkmark
    if (action == @selector(toggleAlwaysOnTop:)) {
        [mi setState:(self.window.level == NSFloatingWindowLevel) ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }
    // Post-It checkmark
    if (action == @selector(togglePostItMode:)) {
        [mi setState:_postItMode ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }
    // Distraction Free checkmark
    if (action == @selector(toggleDistractionFreeMode:)) {
        [mi setState:_distractionFreeMode ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }
    // Monitoring checkmark — only enabled for tabs with a real file
    if (action == @selector(toggleMonitoring:)) {
        BOOL hasFile = ed && ed.filePath.length > 0;
        [mi setState:(hasFile && ed.monitoringMode) ? NSControlStateValueOn : NSControlStateValueOff];
        return hasFile;
    }
    if (action == @selector(showSummary:))       return ed != nil;
    if (action == @selector(focusOnAnotherView:)) return (vHasTabs || hHasTabs);
    if (action == @selector(setTextDirectionRTL:)) {
        [mi setState:ed.isTextDirectionRTL ? NSControlStateValueOn : NSControlStateValueOff];
        return ed != nil;
    }
    if (action == @selector(setTextDirectionLTR:)) {
        [mi setState:!ed.isTextDirectionRTL ? NSControlStateValueOn : NSControlStateValueOff];
        return ed != nil;
    }

    // Pin / Lock Tab checkmark
    if (action == @selector(pinCurrentTab:) || action == @selector(lockCurrentTab:)) {
        NSInteger sel = _activeTabManager.tabBar.selectedIndex;
        BOOL pinned = (sel >= 0 && [_activeTabManager.tabBar isTabPinnedAtIndex:sel]);
        [mi setState:pinned ? NSControlStateValueOn : NSControlStateValueOff];
        return sel >= 0;
    }

    // Tab Wrap checkmark
    if (action == @selector(toggleTabBarWrap:)) {
        [mi setState:[[NSUserDefaults standardUserDefaults] boolForKey:kPrefTabBarWrap]
            ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }

    // Sort/Windows enabled whenever there are tabs
    if (action == @selector(sortTabsByFileNameAsc:)  ||
        action == @selector(sortTabsByFileNameDesc:) ||
        action == @selector(sortTabsByFileTypeAsc:)  ||
        action == @selector(sortTabsByFileTypeDesc:) ||
        action == @selector(sortTabsByFullPathAsc:)  ||
        action == @selector(sortTabsByFullPathDesc:))
        return _activeTabManager.allEditors.count > 1;

    if (action == @selector(showWindowsList:))
        return _tabManager.allEditors.count > 0;

    if (action == @selector(closeAllButPinned:))
        return _activeTabManager.allEditors.count > 0;

    // Spell check checkmark
    if (action == @selector(toggleSpellCheck:)) {
        [mi setState:ed.spellCheckEnabled ? NSControlStateValueOn : NSControlStateValueOff];
        return ed != nil;
    }

    // Begin/End Select: checkmark when active; disable the other mode while one is active
    if (action == @selector(beginEndSelect:)) {
        BOOL active = ed.beginSelectActive;
        [mi setState:active ? NSControlStateValueOn : NSControlStateValueOff];
        return ed != nil;
    }
    if (action == @selector(beginEndSelectColumnMode:)) {
        BOOL active = ed.beginSelectActive;
        [mi setState:active ? NSControlStateValueOn : NSControlStateValueOff];
        return ed != nil;
    }

    // EOL Conversion: checkmark on active mode; disable (dim) the currently-active mode
    if (action == @selector(setEOLCRLF:)) {
        sptr_t mode = ed ? [ed.scintillaView message:SCI_GETEOLMODE] : -1;
        [mi setState:mode == SC_EOL_CRLF ? NSControlStateValueOn : NSControlStateValueOff];
        return ed != nil && mode != SC_EOL_CRLF;
    }
    if (action == @selector(setEOLLF:)) {
        sptr_t mode = ed ? [ed.scintillaView message:SCI_GETEOLMODE] : -1;
        [mi setState:mode == SC_EOL_LF ? NSControlStateValueOn : NSControlStateValueOff];
        return ed != nil && mode != SC_EOL_LF;
    }
    if (action == @selector(setEOLCR:)) {
        sptr_t mode = ed ? [ed.scintillaView message:SCI_GETEOLMODE] : -1;
        [mi setState:mode == SC_EOL_CR ? NSControlStateValueOn : NSControlStateValueOff];
        return ed != nil && mode != SC_EOL_CR;
    }

    // View > Show White Space / EOL: checkmark reflecting current state
    if (action == @selector(showWhiteSpaceAndTab:)) {
        BOOL shown = ed && ([ed.scintillaView message:SCI_GETVIEWWS] == SCWS_VISIBLEALWAYS);
        [mi setState:shown ? NSControlStateValueOn : NSControlStateValueOff];
        return ed != nil;
    }
    if (action == @selector(showEndOfLine:)) {
        BOOL shown = ed && ([ed.scintillaView message:SCI_GETVIEWEOL] != 0);
        [mi setState:shown ? NSControlStateValueOn : NSControlStateValueOff];
        return ed != nil;
    }
    if (action == @selector(toggleShowAllChars:)) {
        BOOL wsOn  = ed && ([ed.scintillaView message:SCI_GETVIEWWS] == SCWS_VISIBLEALWAYS);
        BOOL eolOn = ed && ([ed.scintillaView message:SCI_GETVIEWEOL] != 0);
        [mi setState:(wsOn && eolOn) ? NSControlStateValueOn : NSControlStateValueOff];
        return ed != nil;
    }
    if (action == @selector(toggleIndentGuides:)) {
        [mi setState:_showIndentGuides ? NSControlStateValueOn : NSControlStateValueOff];
        return ed != nil;
    }
    if (action == @selector(toggleLineNumbers:)) {
        [mi setState:_showLineNumbers ? NSControlStateValueOn : NSControlStateValueOff];
        return ed != nil;
    }
    if (action == @selector(toggleWrapSymbol:)) {
        BOOL on = ed && ([ed.scintillaView message:SCI_GETWRAPVISUALFLAGS] != 0);
        [mi setState:on ? NSControlStateValueOn : NSControlStateValueOff];
        return ed != nil;
    }
    if (action == @selector(toggleHideLineMarks:)) {
        BOOL hidden = ed && ([ed.scintillaView message:SCI_GETMARGINWIDTHN wParam:1] == 0);
        [mi setState:hidden ? NSControlStateValueOn : NSControlStateValueOff];
        return ed != nil;
    }
    if (action == @selector(toggleWordWrap:)) {
        [mi setState:(ed && ed.wordWrapEnabled) ? NSControlStateValueOn : NSControlStateValueOff];
        return ed != nil;
    }

    // Encoding menu: checkmark on the active encoding (radio-style)
    {
        NSString *encName = ed.encodingName ?: @"";
        NSDictionary *encMap = @{
            NSStringFromSelector(@selector(setEncodingANSI:)):        @"Windows-1252",
            NSStringFromSelector(@selector(setEncodingUTF8:)):        @"UTF-8",
            NSStringFromSelector(@selector(setEncodingUTF8BOM:)):     @"UTF-8 BOM",
            NSStringFromSelector(@selector(setEncodingUTF16BEBOM:)):  @"UTF-16 BE BOM",
            NSStringFromSelector(@selector(setEncodingUTF16LEBOM:)):  @"UTF-16 LE BOM",
            NSStringFromSelector(@selector(setEncodingLatin1:)):      @"Latin-1",
            NSStringFromSelector(@selector(setEncodingLatin9:)):      @"Latin-9",
            NSStringFromSelector(@selector(setEncodingWindows1252:)): @"Windows-1252",
            NSStringFromSelector(@selector(setEncodingWindows1250:)): @"Windows-1250",
            NSStringFromSelector(@selector(setEncodingWindows1251:)): @"Windows-1251",
            NSStringFromSelector(@selector(setEncodingWindows1253:)): @"Windows-1253",
            NSStringFromSelector(@selector(setEncodingWindows1257:)): @"Windows-1257",
            NSStringFromSelector(@selector(setEncodingWindows1254:)): @"Windows-1254",
            NSStringFromSelector(@selector(setEncodingBig5:)):        @"Big5",
            NSStringFromSelector(@selector(setEncodingGB2312:)):      @"GB2312",
            NSStringFromSelector(@selector(setEncodingShiftJIS:)):    @"Shift-JIS",
            NSStringFromSelector(@selector(setEncodingEUCKR:)):       @"EUC-KR",
        };
        NSString *match = encMap[NSStringFromSelector(action)];
        if (match) {
            [mi setState:[encName isEqualToString:match] ? NSControlStateValueOn : NSControlStateValueOff];
            return ed != nil;
        }
    }

    // ── Language menu checkmark (leaves only) ──
    // Leaf items (individual language entries) get their checkmark here
    // reactively — if the active editor's language changes while the menu
    // is still open, the next validation pass reflects it.
    //
    // Parent letter-submenu header state (the "J" / "P" etc. checkmark in
    // the top-level Languages menu) is managed in one place by
    // -_refreshLanguagesMenuParentHeaders, invoked from the Languages-menu
    // delegate's -menuWillOpen:. Doing it there rather than piggybacked on
    // per-item validation avoids the stale-state bugs the old per-item
    // approach suffered from (tab switch, UDL apply, Save-As re-detect,
    // and top-level XML/YAML/KIXtart items walking up to the menu bar).
    if (action == @selector(setLanguageFromMenu:)) {
        NSString *langCode = [(NSMenuItem *)item representedObject];
        NSString *current  = ed.currentLanguage ?: @"";
        [mi setState:[current isEqualToString:langCode]
            ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }
    if (action == @selector(setUDLLanguageFromMenu:)) {
        NSString *udlName = [(NSMenuItem *)item representedObject];
        NSString *current = ed.currentLanguage ?: @"";
        [mi setState:[current isEqualToString:udlName]
            ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }

    return YES;
}

#pragma mark - Search menu actions

- (void)showFindPanel:(id)sender {
    [self _ensureFindWindow];
    [self _fillFindFieldWithSelectionIfEnabled];
    [[FindWindow sharedWindow] showTab:FindWindowTabFind];
}

- (void)showReplacePanel:(id)sender {
    [self _ensureFindWindow];
    [self _fillFindFieldWithSelectionIfEnabled];
    [[FindWindow sharedWindow] showTab:FindWindowTabReplace];
}

- (void)_ensureFindWindow {
    FindWindow *fw = [FindWindow sharedWindow];
    if (!fw.delegate) fw.delegate = self;
}

- (void)_fillFindFieldWithSelectionIfEnabled {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kPrefFillFindWithSelection]) return;
    EditorView *ed = [self currentEditor];
    NSString *sel = [ed selectedText];
    if (sel.length > 0 && sel.length < 1000) {
        [[FindWindow sharedWindow] setSearchText:sel];
    }
}

- (void)findNext:(id)sender {
    FindWindow *fw = [FindWindow sharedWindow];
    NSString *text = fw.searchText;
    if (!text.length) { [self showFindPanel:sender]; return; }
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    NPPFindOptions *opts = [fw currentOptions];
    if (![SearchEngine findInView:ed.scintillaView options:opts forward:YES]) NSBeep();
}

- (void)findPrevious:(id)sender {
    FindWindow *fw = [FindWindow sharedWindow];
    NSString *text = fw.searchText;
    if (!text.length) { [self showFindPanel:sender]; return; }
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    NPPFindOptions *opts = [fw currentOptions];
    if (![SearchEngine findInView:ed.scintillaView options:opts forward:NO]) NSBeep();
}

// Find Volatile: same as Find Next/Prev but never wraps
- (void)findVolatileNext:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    NSString *text = [ed selectedText];
    if (!text.length) return;

    NPPFindOptions *opts = [[NPPFindOptions alloc] init];
    opts.searchText = text;
    opts.matchCase = NO;
    opts.wholeWord = NO;
    opts.wrapAround = YES;
    opts.searchType = NPPSearchNormal;
    opts.direction = NPPSearchDown;
    if (![SearchEngine findInView:ed.scintillaView options:opts forward:YES]) NSBeep();
}

- (void)findVolatilePrevious:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    NSString *text = [ed selectedText];
    if (!text.length) return;

    NPPFindOptions *opts = [[NPPFindOptions alloc] init];
    opts.searchText = text;
    opts.matchCase = NO;
    opts.wholeWord = NO;
    opts.wrapAround = YES;
    opts.searchType = NPPSearchNormal;
    opts.direction = NPPSearchUp;
    if (![SearchEngine findInView:ed.scintillaView options:opts forward:NO]) NSBeep();
}

// ── Incremental Search ────────────────────────────────────────────────────────

- (void)showIncrementalSearch:(id)sender {
    if (_incSearchBar.hidden) {
        _incSearchBar.hidden = NO;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.12;
            self->_incSearchBarHeightConstraint.animator.constant = _incSearchBar.preferredHeight;
        } completionHandler:^{
            [self->_incSearchBar activate];
        }];
    } else {
        [_incSearchBar activate];
    }
}

// ── IncrementalSearchBarDelegate ──────────────────────────────────────────────

- (void)incrementalSearchBar:(id)bar findText:(NSString *)text
                   matchCase:(BOOL)mc forward:(BOOL)fwd {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    if (!text.length) {
        [ed clearIncrementalSearchHighlights];
        [_incSearchBar setStatus:@"" found:YES];
        return;
    }
    [ed highlightAllMatches:text matchCase:mc];
    BOOL found = fwd
        ? [ed findNext:text matchCase:mc wholeWord:NO wrap:YES]
        : [ed findPrev:text matchCase:mc wholeWord:NO wrap:YES];
    NSString *status = found ? @"" : @"Not found";
    [_incSearchBar setStatus:status found:found];
}

- (void)incrementalSearchBarDidClose:(id)bar {
    EditorView *ed = [self currentEditor];
    [ed clearIncrementalSearchHighlights];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.12;
        self->_incSearchBarHeightConstraint.animator.constant = 0;
    } completionHandler:^{
        self->_incSearchBar.hidden = YES;
    }];
    [self.window makeFirstResponder:ed.scintillaView.content];
}

// ── Change History ────────────────────────────────────────────────────────────

- (void)goToNextChange:(id)sender     { [[self currentEditor] goToNextChange:sender]; }
- (void)goToPreviousChange:(id)sender { [[self currentEditor] goToPreviousChange:sender]; }
- (void)clearAllChanges:(id)sender    { [[self currentEditor] clearAllChanges:sender]; }

- (void)goToLine:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [[NppLocalizer shared] translate:@"Go to Line"];
    [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Go"]];
    [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Cancel"]];
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,160,22)];
    input.placeholderString = [NSString stringWithFormat:@"1 – %ld", (long)ed.lineCount];
    alert.accessoryView = input;
    [alert.window makeFirstResponder:input];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSInteger line = input.integerValue;
        if (line > 0) [ed goToLineNumber:line];
    }
}

#pragma mark - Edit: Case conversion

- (void)convertToUppercase:(id)sender         { [[self currentEditor] convertToUppercase:sender]; }
- (void)convertToLowercase:(id)sender         { [[self currentEditor] convertToLowercase:sender]; }
- (void)convertToProperCase:(id)sender        { [[self currentEditor] convertToProperCase:sender]; }
- (void)convertToProperCaseBlend:(id)sender   { [[self currentEditor] convertToProperCaseBlend:sender]; }
- (void)convertToSentenceCase:(id)sender      { [[self currentEditor] convertToSentenceCase:sender]; }
- (void)convertToSentenceCaseBlend:(id)sender { [[self currentEditor] convertToSentenceCaseBlend:sender]; }
- (void)convertToInvertedCase:(id)sender      { [[self currentEditor] convertToInvertedCase:sender]; }
- (void)convertToRandomCase:(id)sender        { [[self currentEditor] convertToRandomCase:sender]; }

#pragma mark - Edit: Sort / cleanup

- (void)sortLinesAscending:(id)sender          { [[self currentEditor] sortLinesAscending:sender]; }
- (void)sortLinesDescending:(id)sender         { [[self currentEditor] sortLinesDescending:sender]; }
- (void)sortLinesAscendingCI:(id)sender        { [[self currentEditor] sortLinesAscendingCI:sender]; }
- (void)sortLinesByLengthAsc:(id)sender        { [[self currentEditor] sortLinesByLengthAsc:sender]; }
- (void)sortLinesByLengthDesc:(id)sender       { [[self currentEditor] sortLinesByLengthDesc:sender]; }
- (void)sortLinesRandomly:(id)sender           { [[self currentEditor] sortLinesRandomly:sender]; }
- (void)sortLinesReverse:(id)sender            { [[self currentEditor] sortLinesReverse:sender]; }
- (void)sortLinesIntAsc:(id)sender             { [[self currentEditor] sortLinesIntAsc:sender]; }
- (void)sortLinesIntDesc:(id)sender            { [[self currentEditor] sortLinesIntDesc:sender]; }
- (void)sortLinesDecimalDotAsc:(id)sender      { [[self currentEditor] sortLinesDecimalDotAsc:sender]; }
- (void)sortLinesDecimalDotDesc:(id)sender     { [[self currentEditor] sortLinesDecimalDotDesc:sender]; }
- (void)sortLinesDecimalCommaAsc:(id)sender    { [[self currentEditor] sortLinesDecimalCommaAsc:sender]; }
- (void)sortLinesDecimalCommaDesc:(id)sender   { [[self currentEditor] sortLinesDecimalCommaDesc:sender]; }
- (void)removeDuplicateLines:(id)sender        { [[self currentEditor] removeDuplicateLines:sender]; }
- (void)removeConsecutiveDuplicateLines:(id)sender { [[self currentEditor] removeConsecutiveDuplicateLines:sender]; }
- (void)trimTrailingWhitespace:(id)sender      { [[self currentEditor] trimTrailingWhitespace:sender]; }
- (void)trimLeadingSpaces:(id)sender           { [[self currentEditor] trimLeadingSpaces:sender]; }
- (void)trimLeadingAndTrailingSpaces:(id)sender{ [[self currentEditor] trimLeadingAndTrailingSpaces:sender]; }
- (void)eolToSpace:(id)sender                  { [[self currentEditor] eolToSpace:sender]; }
- (void)trimBothAndEOLToSpace:(id)sender       { [[self currentEditor] trimBothAndEOLToSpace:sender]; }
- (void)removeBlankLines:(id)sender            { [[self currentEditor] removeBlankLines:sender]; }
- (void)mergeBlankLines:(id)sender             { [[self currentEditor] mergeBlankLines:sender]; }
- (void)spacesToTabsLeading:(id)sender         { [[self currentEditor] spacesToTabsLeading:sender]; }
- (void)spacesToTabsAll:(id)sender             { [[self currentEditor] spacesToTabsAll:sender]; }
- (void)tabsToSpaces:(id)sender                { [[self currentEditor] tabsToSpaces:sender]; }
- (void)joinLines:(id)sender                   { [[self currentEditor] joinLines:sender]; }

#pragma mark - Edit: Insert

- (void)insertBlankLineAbove:(id)sender { [[self currentEditor] insertBlankLineAbove:sender]; }
- (void)insertBlankLineBelow:(id)sender { [[self currentEditor] insertBlankLineBelow:sender]; }
- (void)insertDateTimeShort:(id)sender  { [[self currentEditor] insertDateTimeShort:sender]; }
- (void)insertDateTimeLong:(id)sender   { [[self currentEditor] insertDateTimeLong:sender]; }

#pragma mark - Edit: Copy to Clipboard

- (void)copyFullFilePath:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed.filePath) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:ed.filePath forType:NSPasteboardTypeString];
}

- (void)copyFileName:(id)sender {
    EditorView *ed = [self currentEditor];
    NSString *path = ed.filePath;
    if (!path) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:path.lastPathComponent forType:NSPasteboardTypeString];
}

- (void)copyCurrentDirectoryPath:(id)sender {
    EditorView *ed = [self currentEditor];
    NSString *path = ed.filePath;
    if (!path) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:path.stringByDeletingLastPathComponent forType:NSPasteboardTypeString];
}

- (void)copyAllFileNames:(id)sender {
    NSMutableArray *names = [NSMutableArray array];
    for (EditorView *ed in _tabManager.allEditors)
        [names addObject:ed.filePath ? ed.filePath.lastPathComponent : @"new"];
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:[names componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
}

- (void)copyAllFilePaths:(id)sender {
    NSMutableArray *paths = [NSMutableArray array];
    for (EditorView *ed in _tabManager.allEditors)
        if (ed.filePath) [paths addObject:ed.filePath];
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:[paths componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
}

#pragma mark - Edit: Read-Only / Selection

- (void)toggleReadOnly:(id)sender          { [[self currentEditor] toggleReadOnly:sender]; }
- (void)clearReadOnlyFlag:(id)sender       { [[self currentEditor] clearReadOnlyFlag:sender]; }
- (void)goToMatchingBrace:(id)sender       { [[self currentEditor] goToMatchingBrace:sender]; }
- (void)selectAndFindNext:(id)sender       { [[self currentEditor] selectAndFindNext:sender]; }
- (void)selectAndFindPrevious:(id)sender   { [[self currentEditor] selectAndFindPrevious:sender]; }

- (void)lockFileAttribute:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed || !ed.filePath) return;
    [[NSFileManager defaultManager] setAttributes:@{NSFileImmutable: @YES}
                                     ofItemAtPath:ed.filePath error:nil];
}

- (void)unlockFileAttribute:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed || !ed.filePath) return;
    [[NSFileManager defaultManager] setAttributes:@{NSFileImmutable: @NO}
                                     ofItemAtPath:ed.filePath error:nil];
}

// ── Multi-select (forwarded to current editor) ────────────────────────────────

- (void)beginEndSelect:(id)sender         { [[self currentEditor] beginEndSelect:sender]; }
- (void)beginEndSelectColumnMode:(id)sender { [[self currentEditor] beginEndSelectColumnMode:sender]; }
// Multi-Select All (4 variants)
- (void)multiSelectAllIgnoreCaseIgnoreWord:(id)sender { [[self currentEditor] multiSelectAllIgnoreCaseIgnoreWord:sender]; }
- (void)multiSelectAllMatchCaseOnly:(id)sender        { [[self currentEditor] multiSelectAllMatchCaseOnly:sender]; }
- (void)multiSelectAllWholeWordOnly:(id)sender        { [[self currentEditor] multiSelectAllWholeWordOnly:sender]; }
- (void)multiSelectAllMatchCaseWholeWord:(id)sender   { [[self currentEditor] multiSelectAllMatchCaseWholeWord:sender]; }
// Multi-Select Next (4 variants)
- (void)multiSelectNextIgnoreCaseIgnoreWord:(id)sender { [[self currentEditor] multiSelectNextIgnoreCaseIgnoreWord:sender]; }
- (void)multiSelectNextMatchCaseOnly:(id)sender        { [[self currentEditor] multiSelectNextMatchCaseOnly:sender]; }
- (void)multiSelectNextWholeWordOnly:(id)sender        { [[self currentEditor] multiSelectNextWholeWordOnly:sender]; }
- (void)multiSelectNextMatchCaseWholeWord:(id)sender   { [[self currentEditor] multiSelectNextMatchCaseWholeWord:sender]; }

- (void)undoLatestMultiSelect:(id)sender             { [[self currentEditor] undoLatestMultiSelect:sender]; }
- (void)skipCurrentAndGoToNextMultiSelect:(id)sender { [[self currentEditor] skipCurrentAndGoToNextMultiSelect:sender]; }

// ── Split Lines ───────────────────────────────────────────────────────────────

- (void)splitLines:(id)sender { [[self currentEditor] splitLines:sender]; }

// ── Block Comment explicit add/remove ────────────────────────────────────────

- (void)addBlockComment:(id)sender    { [[self currentEditor] addBlockComment:sender]; }
- (void)removeBlockComment:(id)sender { [[self currentEditor] removeBlockComment:sender]; }

// ── Remove Unnecessary Blank and EOL ─────────────────────────────────────────

- (void)removeUnnecessaryBlankAndEOL:(id)sender { [[self currentEditor] removeUnnecessaryBlankAndEOL:sender]; }

// ── Paste Special ─────────────────────────────────────────────────────────────

- (void)copyBinaryContent:(id)sender  { [NSApp sendAction:@selector(copy:)  to:nil from:sender]; }
- (void)pasteBinaryContent:(id)sender { [NSApp sendAction:@selector(paste:) to:nil from:sender]; }

- (void)pasteHTMLContent:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];

    // Get content — prefer plain text (the actual visible text the user copied),
    // fall back to HTML clipboard type. This matches Windows NPP behavior where
    // CF_HTML contains what the user sees, not the browser's internal wrapper.
    NSString *html = [pb stringForType:NSPasteboardTypeString];
    if (!html.length) {
        html = [pb stringForType:NSPasteboardTypeHTML];
    }
    if (!html.length) { NSBeep(); return; }

    // Try to get source URL (Chrome uses a custom type)
    NSString *sourceURL = @"";
    NSString *urlStr = [pb stringForType:@"org.chromium.source-url"];
    if (!urlStr) urlStr = [pb stringForType:@"public.url"];
    if (!urlStr) urlStr = [pb stringForType:NSPasteboardTypeURL];
    if (urlStr.length) sourceURL = urlStr;

    // Build CF_HTML / "HTML Format" header (matches Windows clipboard format)
    NSString *headerTemplate = @"Version:0.9\r\n"
        @"StartHTML:%010lu\r\n"
        @"EndHTML:%010lu\r\n"
        @"StartFragment:%010lu\r\n"
        @"EndFragment:%010lu\r\n";

    NSString *sourceURLLine = sourceURL.length
        ? [NSString stringWithFormat:@"SourceURL:%@\r\n", sourceURL]
        : @"";

    // Measure header byte length with dummy offsets
    NSString *dummyHeader = [NSString stringWithFormat:headerTemplate,
                             (unsigned long)0, (unsigned long)0, (unsigned long)0, (unsigned long)0];
    dummyHeader = [dummyHeader stringByAppendingString:sourceURLLine];

    NSUInteger headerLen = [dummyHeader dataUsingEncoding:NSUTF8StringEncoding].length;
    NSUInteger htmlLen = [html dataUsingEncoding:NSUTF8StringEncoding].length;

    unsigned long startHTML = headerLen;
    unsigned long endHTML = headerLen + htmlLen;

    // Rebuild header with real offsets
    NSString *header = [NSString stringWithFormat:headerTemplate,
                        startHTML, endHTML, startHTML, endHTML];
    header = [header stringByAppendingString:sourceURLLine];

    NSString *result = [header stringByAppendingString:html];
    [ed.scintillaView message:SCI_REPLACESEL wParam:0 lParam:(sptr_t)result.UTF8String];
}

- (void)pasteRTFContent:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSData *rtfData = [pb dataForType:NSPasteboardTypeRTF];
    if (!rtfData.length) { NSBeep(); return; }
    NSAttributedString *attr = [[NSAttributedString alloc] initWithRTF:rtfData
                                                    documentAttributes:nil];
    NSString *plain = attr.string;
    if (!plain.length) { NSBeep(); return; }
    [ed.scintillaView message:SCI_REPLACESEL wParam:0 lParam:(sptr_t)plain.UTF8String];
}

// ── Insert Date/Time (Custom Format) ─────────────────────────────────────────

- (void)insertDateTimeCustom:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [[NppLocalizer shared] translate:@"Insert Date/Time"];
    alert.informativeText = [[NppLocalizer shared] translate:@"Enter an NSDateFormatter format string:"];
    [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Insert"]];
    [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Cancel"]];
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 22)];
    input.stringValue = @"yyyy-MM-dd HH:mm:ss";
    alert.accessoryView = input;
    [alert.window makeFirstResponder:input];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSString *fmt = input.stringValue;
    if (!fmt.length) return;
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = fmt;
    NSString *dateStr = [df stringFromDate:[NSDate date]];
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    [ed.scintillaView message:SCI_REPLACESEL wParam:0 lParam:(sptr_t)dateStr.UTF8String];
}

#pragma mark - Edit: Bookmark line operations

- (void)cutBookmarkedLines:(id)sender      { [[self currentEditor] cutBookmarkedLines:sender]; }
- (void)copyBookmarkedLines:(id)sender     { [[self currentEditor] copyBookmarkedLines:sender]; }
- (void)removeBookmarkedLines:(id)sender   { [[self currentEditor] removeBookmarkedLines:sender]; }
- (void)removeNonBookmarkedLines:(id)sender{ [[self currentEditor] removeNonBookmarkedLines:sender]; }
- (void)inverseBookmark:(id)sender         { [[self currentEditor] inverseBookmark:sender]; }

#pragma mark - View: Whitespace / EOL symbols

- (void)showWhiteSpaceAndTab:(id)sender    {
    [[self currentEditor] showWhiteSpaceAndTab:sender];
    [self _refreshToolbarStates];  // AllChars hover-group toggle-on tracks SCI_GETVIEWWS+EOL
}
- (void)showEndOfLine:(id)sender           {
    [[self currentEditor] showEndOfLine:sender];
    [self _refreshToolbarStates];
}

#pragma mark - View: Fold levels

- (void)foldLevel1:(id)s   { [[self currentEditor] foldLevel1:s]; }
- (void)foldLevel2:(id)s   { [[self currentEditor] foldLevel2:s]; }
- (void)foldLevel3:(id)s   { [[self currentEditor] foldLevel3:s]; }
- (void)foldLevel4:(id)s   { [[self currentEditor] foldLevel4:s]; }
- (void)foldLevel5:(id)s   { [[self currentEditor] foldLevel5:s]; }
- (void)foldLevel6:(id)s   { [[self currentEditor] foldLevel6:s]; }
- (void)foldLevel7:(id)s   { [[self currentEditor] foldLevel7:s]; }
- (void)foldLevel8:(id)s   { [[self currentEditor] foldLevel8:s]; }
- (void)unfoldLevel1:(id)s { [[self currentEditor] unfoldLevel1:s]; }
- (void)unfoldLevel2:(id)s { [[self currentEditor] unfoldLevel2:s]; }
- (void)unfoldLevel3:(id)s { [[self currentEditor] unfoldLevel3:s]; }
- (void)unfoldLevel4:(id)s { [[self currentEditor] unfoldLevel4:s]; }
- (void)unfoldLevel5:(id)s { [[self currentEditor] unfoldLevel5:s]; }
- (void)unfoldLevel6:(id)s { [[self currentEditor] unfoldLevel6:s]; }
- (void)unfoldLevel7:(id)s { [[self currentEditor] unfoldLevel7:s]; }
- (void)unfoldLevel8:(id)s { [[self currentEditor] unfoldLevel8:s]; }
- (void)unfoldCurrentLevel:(id)sender { [[self currentEditor] unfoldCurrentLevel:sender]; }

#pragma mark - Window: Always on Top

- (void)toggleAlwaysOnTop:(id)sender {
    NSWindow *w = self.window;
    w.level = (w.level == NSFloatingWindowLevel) ? NSNormalWindowLevel : NSFloatingWindowLevel;
}

// ── Post-It mode ──────────────────────────────────────────────────────────────
// Borderless, always-on-top, movable by background — like a sticky note.

- (void)togglePostItMode:(id)sender {
    NSWindow *w = self.window;
    _postItMode = !_postItMode;

    if (_postItMode) {
        _savedStyleMask = w.styleMask;
        _savedBgColor = w.backgroundColor;
        _postItSavedToolbarVisible = w.toolbar.isVisible;

        // Fully remove toolbar, tab bar, status bar
        w.toolbar = nil;
        _tabManager.tabBar.hidden = YES;
        _statusBar.hidden = YES;

        // Go borderless, resize to content rect
        NSRect contentRect = [w contentRectForFrameRect:w.frame];
        w.styleMask = NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable;
        [w setFrame:contentRect display:YES];

        // Yellow border around the window to indicate Post-It mode
        w.contentView.wantsLayer = YES;
        w.contentView.layer.borderWidth = 3.0;
        w.contentView.layer.borderColor = [NSColor colorWithRed:1.0 green:0.85 blue:0.3 alpha:1.0].CGColor;

        w.level = NSFloatingWindowLevel;
        w.movableByWindowBackground = YES;
        w.hasShadow = YES;
    } else {
        // Remove yellow border
        w.contentView.layer.borderWidth = 0;
        w.contentView.layer.borderColor = nil;

        // Restore titled style, grow window for title bar
        NSRect contentRect = w.frame;
        w.styleMask = _savedStyleMask;
        [self buildToolbar];
        [w.toolbar setVisible:_postItSavedToolbarVisible];
        NSRect newFrame = [w frameRectForContentRect:contentRect];
        [w setFrame:newFrame display:YES];

        w.level = NSNormalWindowLevel;
        w.backgroundColor = _savedBgColor ?: [NSColor windowBackgroundColor];
        w.movableByWindowBackground = NO;

        [self _applyTabBarVisibility:[[NSUserDefaults standardUserDefaults] boolForKey:kPrefHideTabBar]];  // #183: restore pref, don't force-show
        _statusBar.hidden = NO;
    }
}

// ── Distraction Free mode ─────────────────────────────────────────────────────
// Full screen + hide toolbar, status bar, tab bar.

- (void)toggleDistractionFreeMode:(id)sender {
    _distractionFreeMode = !_distractionFreeMode;
    NSWindow *w = self.window;
    BOOL isFullScreen = (w.styleMask & NSWindowStyleMaskFullScreen) != 0;

    if (_distractionFreeMode) {
        _savedToolbarVisible = w.toolbar.isVisible;
        [w.toolbar setVisible:NO];
        _statusBar.hidden = YES;
        _tabManager.tabBar.hidden = YES;
        if (!isFullScreen) [w toggleFullScreen:nil];
    } else {
        [w.toolbar setVisible:_savedToolbarVisible];
        _statusBar.hidden = NO;
        [self _applyTabBarVisibility:[[NSUserDefaults standardUserDefaults] boolForKey:kPrefHideTabBar]];  // #183: restore pref, don't force-show
        if (isFullScreen) [w toggleFullScreen:nil];
    }
}

// ── Summary ───────────────────────────────────────────────────────────────────

- (void)showSummary:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    NSString *text = ed.scintillaView.string ?: @"";

    NSInteger lines = ed.lineCount;
    NSInteger totalChars = (NSInteger)text.length;

    // Count chars without whitespace
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSInteger charsNoSpace = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        if (![ws characterIsMember:[text characterAtIndex:i]]) charsNoSpace++;
    }

    // Count words
    NSArray *tokens = [text componentsSeparatedByCharactersInSet:ws];
    NSInteger words = 0;
    for (NSString *t in tokens) if (t.length > 0) words++;

    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:@"Summary — %@", ed.displayName];
    a.informativeText = [NSString stringWithFormat:
        @"Lines:                %ld\n"
         "Words:               %ld\n"
         "Characters (total):  %ld\n"
         "Characters (no spc): %ld",
        (long)lines, (long)words, (long)totalChars, (long)charsNoSpace];
    [a runModal];
}

// ── Focus on Another View ────────────────────────────────────────────────────

- (void)focusOnAnotherView:(id)sender {
    TabManager *candidates[] = { _subTabManagerV, _subTabManagerH, _tabManager };
    for (int i = 0; i < 3; i++) {
        TabManager *tm = candidates[i];
        if (tm != _activeTabManager && tm.allEditors.count > 0) {
            [self.window makeFirstResponder:tm.currentEditor.scintillaView.content];
            _activeTabManager = tm;
            return;
        }
    }
}

// ── Text Direction ────────────────────────────────────────────────────────────

- (void)setTextDirectionRTL:(id)sender { [[self currentEditor] setTextDirectionRTL:sender]; }
- (void)setTextDirectionLTR:(id)sender { [[self currentEditor] setTextDirectionLTR:sender]; }

// ── Monitoring (tail -f) ──────────────────────────────────────────────────────

- (void)toggleMonitoring:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed || !ed.filePath) return;
    ed.monitoringMode = !ed.monitoringMode;
    [self _refreshToolbarStates];
}

// ── Hex View ─────────────────────────────────────────────────────────────────

#pragma mark - Not Yet Implemented

/// Hide the primary tab bar (for -notabbar CLI flag).
- (void)_hideTabBarForCLI {
    _tabManager.tabBar.hidden = YES;
}

- (void)notYetImplemented:(id)sender {
    NSString *title = [(NSMenuItem *)sender title];
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [[NppLocalizer shared] translate:@"Not Yet Implemented"];
    a.informativeText = [NSString stringWithFormat:[[NppLocalizer shared] translate:@"'%@' is not yet implemented in this version."], title];
    [a runModal];
}

#pragma mark - Import Plugin / Style Theme

- (void)importPlugin:(id)sender {
    NppLocalizer *loc = [NppLocalizer shared];

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = [loc translate:@"Import Plugin"];
    panel.allowedFileTypes = @[@"zip"];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = NO;
    if ([panel runModal] != NSModalResponseOK) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *pluginsDir = NppConfigSubpath(@"plugins");
    [fm createDirectoryAtPath:pluginsDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSInteger imported = 0;
    for (NSURL *url in panel.URLs) {
        NSString *zipPath = url.path;

        // Extract to a temp directory first to verify contents
        NSString *tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [[NSUUID UUID] UUIDString]];
        [fm createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];

        // Extract ZIP using /usr/bin/ditto
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/usr/bin/ditto";
        task.arguments = @[@"-xk", zipPath, tmpDir];
        task.standardOutput = [NSPipe pipe];
        task.standardError  = [NSPipe pipe];
        @try {
            [task launch];
            [task waitUntilExit];
        } @catch (NSException *e) {
            [fm removeItemAtPath:tmpDir error:nil];
            continue;
        }

        if (task.terminationStatus != 0) {
            [fm removeItemAtPath:tmpDir error:nil];
            continue;
        }

        // Find the plugin subdirectory containing a .dylib
        NSArray *extracted = [fm contentsOfDirectoryAtPath:tmpDir error:nil];
        BOOL found = NO;
        for (NSString *item in extracted) {
            NSString *itemPath = [tmpDir stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            [fm fileExistsAtPath:itemPath isDirectory:&isDir];
            if (isDir) {
                // Check if this directory contains a .dylib
                NSArray *contents = [fm contentsOfDirectoryAtPath:itemPath error:nil];
                for (NSString *file in contents) {
                    if ([file.pathExtension isEqualToString:@"dylib"]) {
                        // Valid plugin folder — copy to plugins directory
                        NSString *destPath = [pluginsDir stringByAppendingPathComponent:item];
                        [fm removeItemAtPath:destPath error:nil]; // overwrite existing
                        if ([fm copyItemAtPath:itemPath toPath:destPath error:nil]) {
                            imported++;
                            found = YES;
                        }
                        break;
                    }
                }
            }
            if (found) break;
        }

        [fm removeItemAtPath:tmpDir error:nil];
    }

    if (imported > 0) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = [loc translate:@"Restart Required"];
        a.informativeText = [loc translate:@"Restart the application to load the installed plugins."];
        [a addButtonWithTitle:[loc translate:@"OK"]];
        [a runModal];
    }
}

#pragma mark - Edit: Column editor

- (void)showColumnEditor:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    [ColumnEditorPanel showForEditor:ed parentWindow:self.window];
}

#pragma mark - Find in Files

- (void)showFindInFiles:(id)sender {
    [self _ensureFindWindow];
    [self _fillFindFieldWithSelectionIfEnabled];
    [[FindWindow sharedWindow] showTab:FindWindowTabFindInFiles];
}

// FindInFilesPanel delegate removed — search results use SearchResultsPanel

#pragma mark - FolderTreePanelDelegate

- (void)folderTreePanel:(FolderTreePanel *)panel openFileAtURL:(NSURL *)url {
    [self openFileAtPath:url.path];
}

- (void)folderTreePanelDidRequestClose:(FolderTreePanel *)panel {
    [self _setPanelVisible:_folderTreePanel title:@"Folder as Workspace" show:NO];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"FolderTreePanelVisible"];
}

- (void)folderTreePanel:(FolderTreePanel *)panel findInFilesAtPath:(NSString *)path {
    [self _ensureFindWindow];
    FindWindow *fw = [FindWindow sharedWindow];
    [fw setDirectory:path];
    [fw showTab:FindWindowTabFindInFiles];
}

#pragma mark - FindWindowDelegate

- (void)_dockPanelsLeftChanged {
    // Reorder subviews of _editorSplitView
    [_sidePanelHost removeFromSuperview];
    [_hSplitView removeFromSuperview];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kPrefDockPanelsOnLeft]) {
        [_editorSplitView addSubview:_sidePanelHost];
        [_editorSplitView addSubview:_hSplitView];
    } else {
        [_editorSplitView addSubview:_hSplitView];
        [_editorSplitView addSubview:_sidePanelHost];
    }
}

- (EditorView *)currentEditorForFindWindow { return [self currentEditor]; }

// FindWindowDelegate
- (NSArray<EditorView *> *)allOpenEditors {
    NSMutableArray *all = [NSMutableArray array];
    for (EditorView *ed in _tabManager.allEditors) [all addObject:ed];
    if (_subTabManagerV)
        for (EditorView *ed in _subTabManagerV.allEditors) [all addObject:ed];
    if (_subTabManagerH)
        for (EditorView *ed in _subTabManagerH.allEditors) [all addObject:ed];
    return all;
}

- (void)findWindow:(FindWindow *)fw navigateToFile:(NSString *)path atLine:(NSInteger)line {
    [self openFileAtPath:path];
    EditorView *ed = [self currentEditor];
    if (ed && line > 0) [ed goToLineNumber:line];
}

- (void)findWindow:(FindWindow *)fw showResults:(NSArray *)results
     forSearchText:(NSString *)text options:(NPPFindOptions *)opts
      filesSearched:(NSInteger)filesSearched {
    [self _showSearchResultsPanelIfHidden];
    [_searchResultsPanel addResults:results forSearchText:text options:opts filesSearched:filesSearched];
}

- (void)findWindowShowSearchResultsPanel:(FindWindow *)fw {
    [self _showSearchResultsPanelIfHidden];
}

- (SearchResultsPanel *)searchResultsPanel { return _searchResultsPanel; }

- (ProjectPanel *)projectPanel {
    if (_projectPanel && [_sidePanelHost hasPanel:_projectPanel]) return _projectPanel;
    return nil;
}

#pragma mark - SearchResultsPanelDelegate

- (void)searchResultsPanel:(SearchResultsPanel *)panel
          navigateToFile:(NSString *)path atLine:(NSInteger)line
               matchText:(NSString *)text matchCase:(BOOL)mc {
    if (!path.length || line <= 0) return;
    [self openFileAtPath:path];
    EditorView *ed = [self currentEditor];
    if (ed && line > 0) {
        [ed goToLineNumber:line];
        // Highlight the line
        ScintillaView *sci = ed.scintillaView;
        sptr_t lineIdx = line - 1;
        sptr_t lineStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)lineIdx];
        sptr_t lineEnd   = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)lineIdx];
        [sci message:SCI_SETSEL wParam:(uptr_t)lineStart lParam:lineEnd];
        [sci message:SCI_SCROLLCARET];
    }
}

- (void)searchResultsPanelDidRequestClose:(SearchResultsPanel *)panel {
    if (_searchSplitView) {
        [_searchSplitView setPosition:NSHeight(_searchSplitView.frame) ofDividerAtIndex:0];
    }
}

#pragma mark - ProjectPanelDelegate

- (void)projectPanel:(ProjectPanel *)panel openFileAtPath:(NSString *)path {
    [self openFileAtPath:path];
}

- (void)projectPanel:(ProjectPanel *)panel findInFilesAtPath:(NSString *)path {
    [self _ensureFindWindow];
    FindWindow *fw = [FindWindow sharedWindow];
    [fw selectProjectPanel:panel.activeTab];
    [fw showTab:FindWindowTabFindInProjects];
}

- (void)projectPanel:(ProjectPanel *)panel runMacroOnFiles:(NSArray<NSString *> *)files
                                            sourceDescription:(NSString *)description {
    if (!files.count) {
        NSAlert *a = [NSAlert new];
        a.messageText = [[NppLocalizer shared] translate:@"No files to process"];
        a.informativeText = [[NppLocalizer shared] translate:@"This project node contains no files."];
        [a runModal];
        return;
    }
    [NPPBatchDialog presentForWindow:self files:files source:description];
}

#pragma mark - GitPanelDelegate

- (void)gitPanel:(GitPanel *)panel openFileAtPath:(NSString *)path {
    [self openFileAtPath:path];
}

- (void)gitPanel:(GitPanel *)panel diffFileAtPath:(NSString *)path {
    [self openFileAtPath:path];
    [[self currentEditor] applyGitDiffHighlights];
}

- (void)gitPanelDidRequestClose:(GitPanel *)panel {
    [self _setPanelVisible:_gitPanel title:@"Source Control" show:NO];
}

#pragma mark - View menu actions

// Universal-in-session word wrap. The toggle:
//
//   1. Computes new state from focused editor.
//   2. Writes kPrefWordWrap so newly-opened tabs (Cmd+N, drag-drop,
//      session restore) inherit the same state via
//      EditorView.applyPreferencesFromDefaults.
//   3. Propagates to every editor in this window's three tab managers.
//   4. Posts NPPWordWrapSessionChanged with object:self so other open
//      windows propagate to their own editors. The receiver filters out
//      its own broadcasts via the object check (see
//      _wordWrapSessionChanged:).
//
// kPrefWordWrap is reset to NO at the top of
// applicationDidFinishLaunching: so the pref is a transient broadcast
// channel only — there is no persistence across launches.
//
// RTL editors (those that have Text Direction = RTL) are SKIPPED when
// turning wrap OFF: RTL forces wrap on for layout reasons (see
// EditorView.setTextDirectionRTL:), and turning it off would leave them
// with wrong line lengths. The existing _savedWrapBeforeRTL machinery
// in EditorView handles wrap-state restore on RTL→LTR switch.
- (void)toggleWordWrap:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    BOOL newState = !ed.wordWrapEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:newState forKey:kPrefWordWrap];
    [self _propagateWordWrap:newState];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"NPPWordWrapSessionChanged" object:self];
    [self _refreshToolbarStates];
}

- (void)_propagateWordWrap:(BOOL)enabled {
    for (TabManager *mgr in @[_tabManager, _subTabManagerH, _subTabManagerV]) {
        for (EditorView *ed in mgr.allEditors) {
            // RTL needs wrap on for proper layout — skip the OFF case.
            if (ed.isTextDirectionRTL && !enabled) continue;
            ed.wordWrapEnabled = enabled;
        }
    }
}

// Fired when ANOTHER MainWindowController toggles wrap. We filter out our
// own broadcasts via note.object (toggleWordWrap: posts with object:self)
// so we don't double-apply / re-broadcast.
- (void)_wordWrapSessionChanged:(NSNotification *)note {
    if (note.object == self) return;
    BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefWordWrap];
    [self _propagateWordWrap:enabled];
    [self _refreshToolbarStates];
}

/// Walk the first responder's superview chain looking for a zoomable panel.
/// Returns the panel NSView if found, nil otherwise.
- (NSView *)_focusedZoomablePanel {
    NSView *v = [self.window.firstResponder isKindOfClass:[NSView class]]
                ? (NSView *)self.window.firstResponder : nil;
    while (v) {
        if ([v respondsToSelector:@selector(panelZoomIn)] &&
            ![v isKindOfClass:[EditorView class]]) return v;
        v = v.superview;
    }
    return nil;
}

/// Issue #72 — universal-in-window zoom. After the focused editor's zoom
/// changes, force every other editor in this window to the same zoom so
/// switching tabs (and split-view editors) doesn't surprise the user with
/// a different size. Matches Nextpad++ Windows behaviour.
///
/// Scoped to ONE window: separate MainWindowController instances each
/// fan-out within their own three tab managers only. That keeps a "small
/// reference window + large editing window" workflow possible.
///
/// Targeted on purpose — we don't post NPPPreferencesChanged because that
/// would re-apply *every* preference (line numbers, caret style, theme
/// colours, autocomplete, …) on every zoom, which is wasteful. We only
/// need SCI_SETZOOM. Plugin / Document Map / Function-List / etc. panels
/// are excluded because they're not in the editor tab managers; they
/// keep their own independent zoom state via panelZoomIn / kPrefPanelZoom_*.
- (void)_propagateEditorZoom:(NSInteger)zoom {
    for (TabManager *mgr in @[_tabManager, _subTabManagerH, _subTabManagerV]) {
        for (EditorView *ed in mgr.allEditors) {
            [ed.scintillaView message:SCI_SETZOOM wParam:(uptr_t)zoom];
        }
    }
}

- (void)zoomIn:(id)sender {
    NSView *panel = [self _focusedZoomablePanel];
    if (panel) { [panel performSelector:@selector(panelZoomIn)]; return; }
    EditorView *ed = [self focusedEditor];
    if (!ed) return;
    [ed.scintillaView message:SCI_ZOOMIN];
    NSInteger zoom = [ed.scintillaView message:SCI_GETZOOM];
    [[NSUserDefaults standardUserDefaults] setInteger:zoom forKey:kPrefZoomLevel];
    [self _propagateEditorZoom:zoom];
    [self updateStatusBar];
}

- (void)zoomOut:(id)sender {
    NSView *panel = [self _focusedZoomablePanel];
    if (panel) { [panel performSelector:@selector(panelZoomOut)]; return; }
    EditorView *ed = [self focusedEditor];
    if (!ed) return;
    [ed.scintillaView message:SCI_ZOOMOUT];
    NSInteger zoom = [ed.scintillaView message:SCI_GETZOOM];
    [[NSUserDefaults standardUserDefaults] setInteger:zoom forKey:kPrefZoomLevel];
    [self _propagateEditorZoom:zoom];
    [self updateStatusBar];
}

- (void)resetZoom:(id)sender {
    NSView *panel = [self _focusedZoomablePanel];
    if (panel) { [panel performSelector:@selector(panelZoomReset)]; return; }
    EditorView *ed = [self focusedEditor];
    if (!ed) return;
    [ed.scintillaView message:SCI_SETZOOM wParam:0];
    [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:kPrefZoomLevel];
    [self _propagateEditorZoom:0];
    [self updateStatusBar];
}

- (void)toggleShowAllChars:(id)sender {
    ScintillaView *sci = [self currentEditor].scintillaView;
    if (!sci) return;
    // Derive current state from Scintilla (not a stale BOOL ivar) so it works correctly on tab switch.
    BOOL wsOn  = ([sci message:SCI_GETVIEWWS] == SCWS_VISIBLEALWAYS);
    BOOL eolOn = ([sci message:SCI_GETVIEWEOL] != 0);
    BOOL allOn = wsOn && eolOn;
    [sci message:SCI_SETVIEWWS  wParam:(allOn ? SCWS_INVISIBLE : SCWS_VISIBLEALWAYS)];
    [sci message:SCI_SETVIEWEOL wParam:(allOn ? 0 : 1)];
    _showAllChars = !allOn;
    [self _refreshToolbarStates];
}

// Shows the dropdown menu for the All-Characters toolbar button (▾ arrow).
- (void)_showAllCharsDropdown:(NSButton *)btn {
    NSMenu *menu = [self _buildAllCharsMenu];
    [menu popUpMenuPositioningItem:nil
                       atLocation:NSMakePoint(0, btn.frame.size.height)
                           inView:btn];
}

- (NSMenu *)_buildAllCharsMenu {
    EditorView *ed = [self currentEditor];
    BOOL wsOn  = ed && ([ed.scintillaView message:SCI_GETVIEWWS] == SCWS_VISIBLEALWAYS);
    BOOL eolOn = ed && ([ed.scintillaView message:SCI_GETVIEWEOL] != 0);
    BOOL allOn = wsOn && eolOn;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    auto addIt = ^(NSString *title, SEL sel, BOOL on) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:sel keyEquivalent:@""];
        it.target = nil;  // first responder chain
        it.state  = on ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:it];
    };
    addIt(@"Show Space and Tab",                   @selector(showWhiteSpaceAndTab:), wsOn);
    addIt(@"Show End of Line",                     @selector(showEndOfLine:),        eolOn);
    addIt(@"Show Non-Printing Characters",         @selector(showWhiteSpaceAndTab:), wsOn);
    addIt(@"Show Control Characters & Unicode EOL",@selector(showEndOfLine:),        eolOn);
    addIt(@"Show All Characters",                  @selector(toggleShowAllChars:),   allOn);
    return menu;
}

- (void)toggleIndentGuides:(id)sender {
    _showIndentGuides = !_showIndentGuides;
    [[NSUserDefaults standardUserDefaults] setBool:_showIndentGuides forKey:kPrefShowIndentGuides];
    // Apply to every open editor (all panes / windows) — applyPreferencesFromDefaults
    // re-reads kPrefShowIndentGuides and updates Scintilla.
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NPPPreferencesChanged" object:nil];
    [self _refreshToolbarStates];
}

- (void)toggleLineNumbers:(id)sender {
    _showLineNumbers = !_showLineNumbers;
    [[NSUserDefaults standardUserDefaults] setBool:_showLineNumbers forKey:kPrefShowLineNumbers];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NPPPreferencesChanged" object:nil];
}

#pragma mark - View: Scroll Synchronization

- (void)toggleSyncVerticalScrolling:(id)sender {
    _syncVerticalScrolling = !_syncVerticalScrolling;
    [self _updateScrollSyncTimer];
    [self _refreshToolbarStates];
}

- (void)toggleSyncHorizontalScrolling:(id)sender {
    _syncHorizontalScrolling = !_syncHorizontalScrolling;
    [self _updateScrollSyncTimer];
    [self _refreshToolbarStates];
}

/// Explicit enable/disable for plugins that need deterministic state (not toggle).
- (void)enableSyncScrolling:(id)sender {
    _syncVerticalScrolling = YES;
    _syncHorizontalScrolling = YES;
    [self _updateScrollSyncTimer];
    [self _refreshToolbarStates];
}

- (void)disableSyncScrolling:(id)sender {
    _syncVerticalScrolling = NO;
    _syncHorizontalScrolling = NO;
    [self _updateScrollSyncTimer];
    [self _refreshToolbarStates];
}

- (void)_updateScrollSyncTimer {
    BOOL needsTimer = _syncVerticalScrolling || _syncHorizontalScrolling;

    if (needsTimer && !_scrollSyncTimer) {
        // Capture current deltas between views
        EditorView *primary = _tabManager.currentEditor;
        EditorView *secondary = nil;
        if (_subTabManagerV.allEditors.count > 0)
            secondary = _subTabManagerV.currentEditor;
        else if (_subTabManagerH.allEditors.count > 0)
            secondary = _subTabManagerH.currentEditor;

        if (primary && secondary) {
            _lastPrimaryLine   = [primary.scintillaView message:SCI_GETFIRSTVISIBLELINE];
            _lastSecondaryLine = [secondary.scintillaView message:SCI_GETFIRSTVISIBLELINE];
            _syncLineDelta = _lastPrimaryLine - _lastSecondaryLine;

            sptr_t charW = [primary.scintillaView message:SCI_TEXTWIDTH wParam:STYLE_DEFAULT lParam:(sptr_t)"P"];
            if (charW < 1) charW = 1;
            _lastPrimaryXOffset  = [primary.scintillaView message:SCI_GETXOFFSET];
            _lastSecondaryXOffset = [secondary.scintillaView message:SCI_GETXOFFSET];
            _syncColumnDelta = (_lastPrimaryXOffset / charW) - (_lastSecondaryXOffset / charW);
        }

        _scrollSyncTimer = [NSTimer timerWithTimeInterval:1.0/60.0
                                                       target:self
                                                     selector:@selector(_pollScrollSync:)
                                                     userInfo:nil
                                                      repeats:YES];
        // Schedule in CommonModes so it fires during scrollbar thumb dragging
        [[NSRunLoop currentRunLoop] addTimer:_scrollSyncTimer forMode:NSRunLoopCommonModes];
    } else if (!needsTimer && _scrollSyncTimer) {
        [_scrollSyncTimer invalidate];
        _scrollSyncTimer = nil;
    }
}

- (void)_pollScrollSync:(NSTimer *)t {
    EditorView *primary = _tabManager.currentEditor;
    EditorView *secondary = nil;
    if (_subTabManagerV.allEditors.count > 0)
        secondary = _subTabManagerV.currentEditor;
    else if (_subTabManagerH.allEditors.count > 0)
        secondary = _subTabManagerH.currentEditor;
    if (!primary || !secondary) return;

    ScintillaView *priSci = primary.scintillaView;
    ScintillaView *secSci = secondary.scintillaView;

    sptr_t priLine = [priSci message:SCI_GETFIRSTVISIBLELINE];
    sptr_t secLine = [secSci message:SCI_GETFIRSTVISIBLELINE];
    sptr_t priX    = [priSci message:SCI_GETXOFFSET];
    sptr_t secX    = [secSci message:SCI_GETXOFFSET];

    // Detect which view the user scrolled by comparing to last known values
    BOOL priLineChanged = (priLine != _lastPrimaryLine);
    BOOL secLineChanged = (secLine != _lastSecondaryLine);
    BOOL priXChanged    = (priX != _lastPrimaryXOffset);
    BOOL secXChanged    = (secX != _lastSecondaryXOffset);

    // Determine source: whichever view changed. If both changed, prefer primary.
    BOOL primaryIsSource = NO, secondaryIsSource = NO;
    if (priLineChanged || priXChanged) primaryIsSource = YES;
    if (secLineChanged || secXChanged) secondaryIsSource = YES;
    // If both changed (from the last sync propagation), neither is the user source — skip
    if (primaryIsSource && secondaryIsSource) {
        _lastPrimaryLine = priLine; _lastSecondaryLine = secLine;
        _lastPrimaryXOffset = priX; _lastSecondaryXOffset = secX;
        return;
    }
    if (!primaryIsSource && !secondaryIsSource) return;

    ScintillaView *src = primaryIsSource ? priSci : secSci;
    ScintillaView *dst = primaryIsSource ? secSci : priSci;

    intptr_t scrollLines = 0, scrollCols = 0;

    if (_syncVerticalScrolling) {
        sptr_t srcLine = [src message:SCI_GETFIRSTVISIBLELINE];
        sptr_t dstLine = [dst message:SCI_GETFIRSTVISIBLELINE];
        if (primaryIsSource)
            scrollLines = srcLine - _syncLineDelta - dstLine;
        else
            scrollLines = srcLine + _syncLineDelta - dstLine;
    }

    if (_syncHorizontalScrolling) {
        sptr_t charW = [src message:SCI_TEXTWIDTH wParam:STYLE_DEFAULT lParam:(sptr_t)"P"];
        if (charW < 1) charW = 1;
        sptr_t srcCol = [src message:SCI_GETXOFFSET] / charW;
        sptr_t dstCol = [dst message:SCI_GETXOFFSET] / charW;
        if (primaryIsSource)
            scrollCols = srcCol - _syncColumnDelta - dstCol;
        else
            scrollCols = srcCol + _syncColumnDelta - dstCol;
    }

    if (scrollLines != 0 || scrollCols != 0)
        [dst message:SCI_LINESCROLL wParam:(uptr_t)scrollCols lParam:scrollLines];

    // Update all last-known values AFTER scrolling the target
    _lastPrimaryLine      = [priSci message:SCI_GETFIRSTVISIBLELINE];
    _lastSecondaryLine    = [secSci message:SCI_GETFIRSTVISIBLELINE];
    _lastPrimaryXOffset   = [priSci message:SCI_GETXOFFSET];
    _lastSecondaryXOffset = [secSci message:SCI_GETXOFFSET];
}

// Scroll sync is handled entirely by _pollScrollSync: timer — no notification-based propagation needed.

#pragma mark - Edit: Auto-Completion forwarders

- (void)triggerWordCompletion:(id)sender          { [[self currentEditor] triggerWordCompletion:sender]; }
- (void)triggerFunctionParametersHint:(id)sender  { [[self currentEditor] triggerFunctionParametersHint:sender]; }
- (void)finishOrSelectAutocompleteItem:(id)sender { [[self currentEditor] finishOrSelectAutocompleteItem:sender]; }

#pragma mark - Plugins: Converter forwarders

- (void)asciiToHex:(id)sender { [[self currentEditor] asciiToHex:sender]; }
- (void)hexToAscii:(id)sender { [[self currentEditor] hexToAscii:sender]; }

#pragma mark - Encoding menu actions

// Set Encoding: reload file from disk re-interpreting with new encoding (like Windows NPP)
- (void)_setCurrentEditorEncoding:(NSStringEncoding)enc hasBOM:(BOOL)bom {
    EditorView *ed = [self currentEditor];
    if (!ed) return;

    if (ed.filePath) {
        // Warn about losing undo history
        if (ed.isModified) {
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = [[NppLocalizer shared] translate:@"Encoding Change"];
            a.informativeText = [[NppLocalizer shared] translate:@"The file has unsaved changes. Reloading with the new encoding will discard them. Continue?"];
            [a addButtonWithTitle:[[NppLocalizer shared] translate:@"Reload"]];
            [a addButtonWithTitle:[[NppLocalizer shared] translate:@"Cancel"]];
            a.alertStyle = NSAlertStyleWarning;
            if ([a runModal] != NSAlertFirstButtonReturn) return;
        }
        NSError *err = nil;
        if (![ed reloadWithEncoding:enc hasBOM:bom error:&err] && err)
            [[NSAlert alertWithError:err] runModal];
    } else {
        // No file on disk — just change metadata
        [ed setFileEncoding:enc hasBOM:bom];
    }
    [self updateStatusBar];
}

// Convert To: re-encode content in memory (user saves manually)
- (void)_convertCurrentEditorToEncoding:(NSStringEncoding)enc hasBOM:(BOOL)bom {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    [ed convertContentToEncoding:enc hasBOM:bom];
    [self updateStatusBar];
}

// ── Set Encoding (change metadata only; user must save) ──────────────────────
- (void)setEncodingANSI:(id)sender {
    [self _setCurrentEditorEncoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingWindowsLatin1) hasBOM:NO];
}
- (void)setEncodingUTF8:(id)sender {
    [self _setCurrentEditorEncoding:NSUTF8StringEncoding hasBOM:NO];
}
- (void)setEncodingUTF8BOM:(id)sender {
    [self _setCurrentEditorEncoding:NSUTF8StringEncoding hasBOM:YES];
}
- (void)setEncodingUTF16BEBOM:(id)sender {
    [self _setCurrentEditorEncoding:NSUTF16BigEndianStringEncoding hasBOM:YES];
}
- (void)setEncodingUTF16LEBOM:(id)sender {
    [self _setCurrentEditorEncoding:NSUTF16LittleEndianStringEncoding hasBOM:YES];
}
- (void)setEncodingLatin1:(id)sender {
    [self _setCurrentEditorEncoding:NSISOLatin1StringEncoding hasBOM:NO];
}
- (void)setEncodingLatin9:(id)sender {
    [self _setCurrentEditorEncoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingISOLatin9) hasBOM:NO];
}
- (void)setEncodingWindows1252:(id)sender {
    [self _setCurrentEditorEncoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingWindowsLatin1) hasBOM:NO];
}
- (void)setEncodingWindows1250:(id)sender {
    [self _setCurrentEditorEncoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingWindowsLatin2) hasBOM:NO];
}
- (void)setEncodingWindows1251:(id)sender {
    [self _setCurrentEditorEncoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingWindowsCyrillic) hasBOM:NO];
}
- (void)setEncodingWindows1253:(id)sender {
    [self _setCurrentEditorEncoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingWindowsGreek) hasBOM:NO];
}
- (void)setEncodingWindows1257:(id)sender {
    [self _setCurrentEditorEncoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingWindowsBalticRim) hasBOM:NO];
}
- (void)setEncodingWindows1254:(id)sender {
    [self _setCurrentEditorEncoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingWindowsLatin5) hasBOM:NO];
}
- (void)setEncodingBig5:(id)sender {
    [self _setCurrentEditorEncoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingBig5) hasBOM:NO];
}
- (void)setEncodingGB2312:(id)sender {
    // macOS recognises kCFStringEncodingGB_2312_80 as a constant but has NO working
    // converter for it — dataUsingEncoding:/initWithData: return nil ("Unknown
    // encoding"), so saving/reloading as GB2312 fails. Use GBK (Windows codepage
    // 936), which is the de-facto "GB2312" superset, round-trips on macOS, and
    // matches Notepad++ on Windows. See nppEncForMenu in EditorView for the
    // reverse (status-bar) mapping.
    [self _setCurrentEditorEncoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGBK_95) hasBOM:NO];
}
- (void)setEncodingShiftJIS:(id)sender {
    [self _setCurrentEditorEncoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingShiftJIS) hasBOM:NO];
}
- (void)setEncodingEUCKR:(id)sender {
    [self _setCurrentEditorEncoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingEUC_KR) hasBOM:NO];
}

// ── Convert To (change encoding and immediately re-save) ──────────────────────
- (void)convertToEncodingANSI:(id)sender {
    [self _convertCurrentEditorToEncoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingWindowsLatin1) hasBOM:NO];
}
- (void)convertToEncodingUTF8:(id)sender {
    [self _convertCurrentEditorToEncoding:NSUTF8StringEncoding hasBOM:NO];
}
- (void)convertToEncodingUTF8BOM:(id)sender {
    [self _convertCurrentEditorToEncoding:NSUTF8StringEncoding hasBOM:YES];
}
- (void)convertToEncodingUTF16BEBOM:(id)sender {
    [self _convertCurrentEditorToEncoding:NSUTF16BigEndianStringEncoding hasBOM:YES];
}
- (void)convertToEncodingUTF16LEBOM:(id)sender {
    [self _convertCurrentEditorToEncoding:NSUTF16LittleEndianStringEncoding hasBOM:YES];
}

- (void)setEOLCRLF:(id)sender {
    [[[self currentEditor] scintillaView] message:SCI_SETEOLMODE wParam:SC_EOL_CRLF];
    [[[self currentEditor] scintillaView] message:SCI_CONVERTEOLS wParam:SC_EOL_CRLF];
    [self updateStatusBar];
}

- (void)setEOLLF:(id)sender {
    [[[self currentEditor] scintillaView] message:SCI_SETEOLMODE wParam:SC_EOL_LF];
    [[[self currentEditor] scintillaView] message:SCI_CONVERTEOLS wParam:SC_EOL_LF];
    [self updateStatusBar];
}

- (void)setEOLCR:(id)sender {
    [[[self currentEditor] scintillaView] message:SCI_SETEOLMODE wParam:SC_EOL_CR];
    [[[self currentEditor] scintillaView] message:SCI_CONVERTEOLS wParam:SC_EOL_CR];
    [self updateStatusBar];
}

#pragma mark - Language menu action

- (void)setLanguageFromMenu:(id)sender {
    NSString *lang = [sender representedObject] ?: @"";
    [[self currentEditor] setLanguage:lang];
    [self updateStatusBar];
    // Refresh Function List if it's open
    if (_funcListPanel && [_sidePanelHost hasPanel:_funcListPanel])
        [_funcListPanel loadEditor:[self currentEditor]];
}

/// Apply a User Defined Language from the Language menu.
- (void)setUDLLanguageFromMenu:(id)sender {
    NSString *udlName = [sender representedObject];
    if (!udlName) return;
    UserDefinedLang *udl = [[UserDefineLangManager shared] languageNamed:udlName];
    if (!udl) return;
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    [[UserDefineLangManager shared] applyLanguage:udl toScintillaView:ed.scintillaView];
    // Keep the editor's currentLanguage in sync with what's actually lexing
    // the buffer. Without this, validateUserInterfaceItem: for UDL items
    // compares against a stale language name and the UDL checkmark never
    // appears, and the Languages-menu parent-header refresh can't see that
    // a UDL is now active.
    ed.currentLanguage = udlName;
    [self updateStatusBar];
}

/// Populate the Language menu with all loaded UDL names.
/// Inserts them after the last separator in the Language menu
/// (below the static Markdown preinstalled entries).
- (void)rebuildUDLLanguageMenu {
    // Look up the Language top-level menu by tag, not by its English title:
    // when the active UI language is non-English the title is translated
    // (e.g. "Синтаксисы" / "Мова" / "Langage"), and an
    // isEqualToString:@"Language" check would silently miss and skip the
    // entire UDL insertion — losing every ~/Library/Application Support/Nextpad++/userDefineLangs/
    // entry from the menu.
    NSMenuItem *langTop = [[NSApp mainMenu] itemWithTag:kMenuTagLanguage];
    NSMenu *langMenu = langTop.submenu;
    if (!langMenu) return;

    // Remove any previously-added UDL items (tagged with 8800)
    NSMutableArray *toRemove = [NSMutableArray array];
    for (NSMenuItem *mi in langMenu.itemArray) {
        if (mi.tag == 8800) [toRemove addObject:mi];
    }
    for (NSMenuItem *mi in toRemove) [langMenu removeItem:mi];

    // Get all loaded UDLs, skip pre-installed ones (already static in menu)
    NSArray<UserDefinedLang *> *udls = [UserDefineLangManager shared].allLanguages;

    // Find insertion point: after the last separator
    NSInteger insertIdx = -1;
    for (NSInteger i = langMenu.itemArray.count - 1; i >= 0; i--) {
        if (langMenu.itemArray[i].isSeparatorItem) {
            insertIdx = i + 1;
            break;
        }
    }
    if (insertIdx < 0) insertIdx = langMenu.itemArray.count;

    // Insert ALL UDL items (including preinstalled Markdown variants — they
    // used to be static entries in the hardcoded Language menu, but the menu
    // is now generated from the Windows-authoritative built-in table, which
    // excludes markdown. The preinstalled UDLs land here like any other UDL.)
    for (UserDefinedLang *udl in udls) {
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:udl.name
                                                    action:@selector(setUDLLanguageFromMenu:)
                                             keyEquivalent:@""];
        mi.target = self;
        mi.representedObject = udl.name;
        mi.tag = 8800;
        [langMenu insertItem:mi atIndex:insertIdx];
        insertIdx++;
    }
}

#pragma mark - Tab navigation

- (void)selectNextTab:(id)sender {
    NSInteger next = (_activeTabManager.tabBar.selectedIndex + 1) % _activeTabManager.tabBar.tabCount;
    [_activeTabManager selectTabAtIndex:next];
}

- (void)selectPreviousTab:(id)sender {
    NSInteger count = _activeTabManager.tabBar.tabCount;
    NSInteger prev  = (_activeTabManager.tabBar.selectedIndex - 1 + count) % count;
    [_activeTabManager selectTabAtIndex:prev];
}

- (void)_selectTabN:(NSInteger)n {
    // Select Nth tab (0-based). If beyond count, select last tab (matches Windows NPP).
    NSInteger count = _activeTabManager.tabBar.tabCount;
    if (count == 0) return;
    NSInteger idx = (n < count) ? n : (count - 1);
    [_activeTabManager selectTabAtIndex:idx];
}

- (void)selectTab1:(id)sender { [self _selectTabN:0]; }
- (void)selectTab2:(id)sender { [self _selectTabN:1]; }
- (void)selectTab3:(id)sender { [self _selectTabN:2]; }
- (void)selectTab4:(id)sender { [self _selectTabN:3]; }
- (void)selectTab5:(id)sender { [self _selectTabN:4]; }
- (void)selectTab6:(id)sender { [self _selectTabN:5]; }
- (void)selectTab7:(id)sender { [self _selectTabN:6]; }
- (void)selectTab8:(id)sender { [self _selectTabN:7]; }
- (void)selectTab9:(id)sender { [self _selectTabN:8]; }

- (void)selectFirstTab:(id)sender {
    if (_activeTabManager.tabBar.tabCount > 0)
        [_activeTabManager selectTabAtIndex:0];
}

- (void)selectLastTab:(id)sender {
    NSInteger count = _activeTabManager.tabBar.tabCount;
    if (count > 0)
        [_activeTabManager selectTabAtIndex:count - 1];
}

#pragma mark - Tab movement

- (void)moveTabForward:(id)sender {
    NSInteger idx = _activeTabManager.tabBar.selectedIndex;
    NSInteger count = _activeTabManager.tabBar.tabCount;
    if (idx < 0 || idx >= count - 1) return; // already at end
    [_activeTabManager swapEditorAtIndex:idx withIndex:idx + 1];
}

- (void)moveTabBackward:(id)sender {
    NSInteger idx = _activeTabManager.tabBar.selectedIndex;
    if (idx <= 0) return; // already at start
    [_activeTabManager swapEditorAtIndex:idx withIndex:idx - 1];
}

- (void)moveTabToStart:(id)sender {
    NSInteger idx = _activeTabManager.tabBar.selectedIndex;
    while (idx > 0) {
        [_activeTabManager swapEditorAtIndex:idx withIndex:idx - 1];
        idx--;
    }
}

- (void)moveTabToEnd:(id)sender {
    NSInteger idx = _activeTabManager.tabBar.selectedIndex;
    NSInteger count = _activeTabManager.tabBar.tabCount;
    while (idx < count - 1) {
        [_activeTabManager swapEditorAtIndex:idx withIndex:idx + 1];
        idx++;
    }
}

#pragma mark - Tab coloring

- (void)_applyTabColor:(NSInteger)colorId {
    NSInteger idx = _activeTabManager.tabBar.selectedIndex;
    if (idx < 0) return;
    [_activeTabManager.tabBar setTabColorAtIndex:idx colorId:colorId];
    // Re-tint the Document List row to match the colored tab right away.
    if (_docListPanel) [_docListPanel reloadData];
}

- (void)applyTabColor1:(id)sender { [self _applyTabColor:0]; }
- (void)applyTabColor2:(id)sender { [self _applyTabColor:1]; }
- (void)applyTabColor3:(id)sender { [self _applyTabColor:2]; }
- (void)applyTabColor4:(id)sender { [self _applyTabColor:3]; }
- (void)applyTabColor5:(id)sender { [self _applyTabColor:4]; }
- (void)removeTabColor:(id)sender  { [self _applyTabColor:-1]; }

#pragma mark - Find panel animation

- (void)animateFindPanel {
    CGFloat h = _findPanel.preferredHeight;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.15;
        self->_findPanelHeightConstraint.animator.constant = h;
    }];
}

#pragma mark - FindReplacePanelDelegate

- (void)findPanel:(FindReplacePanel *)panel findNext:(NSString *)text
        matchCase:(BOOL)mc wholeWord:(BOOL)ww wrap:(BOOL)wrap {
    if (![[self currentEditor] findNext:text matchCase:mc wholeWord:ww wrap:wrap]) NSBeep();
}

- (void)findPanel:(FindReplacePanel *)panel findPrev:(NSString *)text
        matchCase:(BOOL)mc wholeWord:(BOOL)ww wrap:(BOOL)wrap {
    if (![[self currentEditor] findPrev:text matchCase:mc wholeWord:ww wrap:wrap]) NSBeep();
}

- (void)findPanel:(FindReplacePanel *)panel replace:(NSString *)text
             with:(NSString *)replacement matchCase:(BOOL)mc wholeWord:(BOOL)ww {
    if (![[self currentEditor] replace:text with:replacement matchCase:mc wholeWord:ww]) NSBeep();
}

- (void)findPanel:(FindReplacePanel *)panel replaceAll:(NSString *)text
             with:(NSString *)replacement matchCase:(BOOL)mc wholeWord:(BOOL)ww {
    NSInteger n = [[self currentEditor] replaceAll:text with:replacement matchCase:mc wholeWord:ww];
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = n > 0 ? [NSString stringWithFormat:@"%ld replacement(s) made.", (long)n]
                           : @"No occurrences found.";
    [a runModal];
}

- (void)findPanelDidClose:(FindReplacePanel *)panel {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.12;
        self->_findPanelHeightConstraint.animator.constant = 0;
    } completionHandler:^{ self->_findPanel.hidden = YES; }];
    [self.window makeFirstResponder:[self currentEditor].scintillaView.content];
}

#pragma mark - NSSplitViewDelegate

- (void)splitViewDidResizeSubviews:(NSNotification *)notification {
    if (!_isWindowReadyForResizeEvents) return;
    NSSplitView *sv = notification.object;
    if (sv == _editorSplitView) {
        if (![_editorSplitView isSubviewCollapsed:_sidePanelHost]) {
            CGFloat width = NSWidth(_sidePanelHost.frame);
            if (width >= 150) {
                [[NSUserDefaults standardUserDefaults] setDouble:width forKey:kPrefSidePanelWidth];
            }
        }
    }
}

- (BOOL)splitView:(NSSplitView *)sv canCollapseSubview:(NSView *)sub {
    if (sv == _editorSplitView) return sub == _sidePanelHost;
    if (sv == _hSplitView)      return sub == _subEditorContainerH;
    if (sv == _vSplitView)      return sub == _subEditorContainerV;
    if (sv == _searchSplitView) return sub == _searchResultsPanel;
    return NO;
}

// Hide (and disable) the divider whenever the adjacent collapsible pane is
// fully collapsed — prevents the user from accidentally grabbing the invisible
// NSSplitView divider when trying to resize the window from its right edge.
- (BOOL)splitView:(NSSplitView *)sv shouldHideDividerAtIndex:(NSInteger)idx {
    if (sv == _editorSplitView && idx == 0)
        return [sv isSubviewCollapsed:_sidePanelHost];
    if (sv == _hSplitView && idx == 0)
        return [sv isSubviewCollapsed:_subEditorContainerH];
    if (sv == _vSplitView && idx == 0)
        return [sv isSubviewCollapsed:_subEditorContainerV];
    return NO;
}

- (CGFloat)splitView:(NSSplitView *)sv constrainMinCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i {
    if (sv == _hSplitView || sv == _vSplitView) return p + 100;
    if (sv == _editorSplitView) return p + 200;
    return p + 200;
}

- (CGFloat)splitView:(NSSplitView *)sv constrainMaxCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i {
    if (sv == _hSplitView || sv == _vSplitView) return p - 100;
    return p - 150;   // panel at least 150pt when visible
}

#pragma mark - Editor context menu

- (void)_buildEditorContextMenu {
    // Try user-customized contextMenu.xml first, fall back to bundled default
    NSString *userPath = [nppConfigDir() stringByAppendingPathComponent:@"contextMenu.xml"];
    _editorContextMenu = _buildEditorContextMenuFromXML(userPath);
    if (!_editorContextMenu) {
        NSString *bundledPath = [[NSBundle mainBundle] pathForResource:@"contextMenu" ofType:@"xml"];
        _editorContextMenu = _buildEditorContextMenuFromXML(bundledPath);
    }
    if (!_editorContextMenu) {
        // Ultimate fallback: minimal menu
        _editorContextMenu = [[NSMenu alloc] initWithTitle:@""];
        [_editorContextMenu addItemWithTitle:[[NppLocalizer shared] translate:@"Cut"] action:@selector(cut:) keyEquivalent:@""];
        [_editorContextMenu addItemWithTitle:[[NppLocalizer shared] translate:@"Copy"] action:@selector(copy:) keyEquivalent:@""];
        [_editorContextMenu addItemWithTitle:[[NppLocalizer shared] translate:@"Paste"] action:@selector(paste:) keyEquivalent:@""];
    }
    // Prevent macOS from injecting AutoFill, Services, and other system items
    _editorContextMenu.allowsContextMenuPlugIns = NO;
    _editorContextMenu.delegate = self;
}

/// Strip system-injected items (AutoFill, etc.) before the context menu opens.
/// Belt-and-suspenders: allowsContextMenuPlugIns handles most cases, but
/// macOS may still inject AutoFill on newer versions via a different path.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != _editorContextMenu) return;
    for (NSInteger i = menu.numberOfItems - 1; i >= 0; i--) {
        NSMenuItem *mi = [menu itemAtIndex:i];
        if (mi.isSeparatorItem) continue;
        if (mi.tag == 0) [menu removeItemAtIndex:i];
    }
}

#pragma mark - Languages menu delegate

/// Locate the top-level Languages menu built by MenuBuilder and make us
/// its delegate, so menuWillOpen: can refresh parent letter-header
/// checkmarks in one deterministic pass.
///
/// Detected by content, not title, because NppLocalizer may have already
/// translated the submenu's title by the time this runs (startup order:
/// buildMainMenu → autoLoad/applyToMainMenu → MainWindowController init).
/// Any top-level menu whose submenu directly contains an item that acts
/// on setLanguageFromMenu: or setUDLLanguageFromMenu: is the one.
- (void)_installLanguagesMenuDelegate {
    for (NSMenuItem *topItem in [NSApp mainMenu].itemArray) {
        NSMenu *sub = topItem.submenu;
        if (!sub) continue;
        for (NSMenuItem *child in sub.itemArray) {
            SEL a = child.action;
            if (a == @selector(setLanguageFromMenu:) ||
                a == @selector(setUDLLanguageFromMenu:)) {
                _languagesMenu = sub;
                _languagesMenu.delegate = self;
                return;
            }
        }
    }
}

/// Set letter-submenu header checkmarks (A, B, C, …) so the user can see
/// at a glance which letter contains the active language. Runs once per
/// open of the Languages menu. Leaf items still get their own checkmarks
/// from validateUserInterfaceItem:.
///
/// Only items that wrap a submenu of setLanguageFromMenu: entries are
/// treated as letter headers — the "User Defined Language" utility
/// submenu is left alone.
- (void)_refreshLanguagesMenuParentHeaders {
    if (!_languagesMenu) return;

    EditorView *ed = [self currentEditor];
    NSString *current = ed.currentLanguage ?: @"";

    for (NSMenuItem *topItem in _languagesMenu.itemArray) {
        NSMenu *sub = topItem.submenu;
        if (!sub) continue;

        BOOL isLetterSubmenu = NO;
        BOOL anyMatch = NO;
        for (NSMenuItem *child in sub.itemArray) {
            if (child.action == @selector(setLanguageFromMenu:)) {
                isLetterSubmenu = YES;
                NSString *code = (NSString *)child.representedObject ?: @"";
                if (code.length && [current isEqualToString:code]) {
                    anyMatch = YES;
                    break;
                }
            }
        }
        if (isLetterSubmenu) {
            topItem.state = anyMatch ? NSControlStateValueOn
                                     : NSControlStateValueOff;
        }
    }
}

- (void)menuWillOpen:(NSMenu *)menu {
    if (menu == _languagesMenu) {
        [self _refreshLanguagesMenuParentHeaders];
    }
}

- (void)_applyEditorContextMenu:(EditorView *)editor {
    if (!_editorContextMenu) [self _buildEditorContextMenu];
    [editor.scintillaView setMenu:_editorContextMenu];
}

/// Apply context menu to ALL editors in all tab managers.
- (void)applyEditorContextMenuToAll {
    // Issue #144 — force a fresh rebuild. This is invoked right after plugins
    // finish loading (see AppDelegate), but the menu was first built lazily
    // during early window setup — before any plugin submenus existed in the
    // Plugins menu. That stale cache contained only built-in submenus (e.g.
    // MIME Tools) and silently dropped every external plugin command. Discard
    // and rebuild now so plugin submenus are resolvable.
    _editorContextMenu = nil;
    [self _buildEditorContextMenu];
    for (TabManager *tm in @[_tabManager, _subTabManagerH, _subTabManagerV]) {
        if (!tm) continue;
        for (EditorView *ed in [tm allEditors]) {
            [ed.scintillaView setMenu:_editorContextMenu];
        }
    }
}

#pragma mark - TabManagerDelegate

- (void)tabManager:(id)tabManager didSelectEditor:(EditorView *)editor {
    _activeTabManager = tabManager;
    // Give the editor keyboard focus so the old pane's caret stops blinking
    // and SCN_FOCUSIN fires on the correct editor. Target the SCIContentView
    // (`.content`), not the outer ScintillaView NSView wrapper — only the
    // content view is in Scintilla's keyDown: chain, so making the wrapper
    // first responder leaves typing dead until the user clicks in the editor.
    [self.window makeFirstResponder:editor.scintillaView.content];

    // Notify plugins that a different buffer is now active
    [[NppPluginManager shared] notifyPluginsWithCode:NPPN_BUFFERACTIVATED
                                            bufferID:(intptr_t)(__bridge void *)editor];
    [self _applyEditorContextMenu:editor];
    [self updateTitle];
    [self updateStatusBar];
    if (_docListPanel) [_docListPanel reloadData];
    if (_funcListPanel && [_sidePanelHost hasPanel:_funcListPanel])
        [_funcListPanel loadEditor:editor];
    if (_docMapPanel && [_sidePanelHost hasPanel:_docMapPanel])
        [_docMapPanel setTrackedEditor:editor];
    if (_folderTreePanel && [_sidePanelHost hasPanel:_folderTreePanel]) {
        NSString *path = editor.filePath;
        [(FolderTreePanel *)_folderTreePanel setActiveFileURL:
            path ? [NSURL fileURLWithPath:path] : [NSURL fileURLWithPath:NSHomeDirectory()]];
    }
    if (_gitPanel && [_sidePanelHost hasPanel:_gitPanel]) {
        [self _updateGitPanelForPath:editor.filePath];
    }
    // Git branch label and diff markers are only updated when the Git panel
    // is open — avoids triggering the Xcode Command Line Tools install dialog
    // on Macs without git installed.
    if (_gitPanel && [_sidePanelHost hasPanel:_gitPanel]) {
        NSString *gitPath = editor.filePath;
        __weak typeof(self) weakSelf = self;
        __weak EditorView *weakEd = editor;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf _updateGitBranch:gitPath];
            [weakEd updateGitDiffMarkers];
        });
    }
    [self _refreshToolbarStates];
}

- (void)tabManager:(id)tabManager didCloseEditor:(EditorView *)editor {
    [self updateTitle];
    if (_docListPanel) [_docListPanel reloadData];
}

#pragma mark - Cursor notification

- (void)editorCursorMoved:(NSNotification *)note {
    EditorView *ed = note.object;
    if (ed == [self currentEditor]) {
        [self updateStatusBar];
        [self refreshCurrentTab];
    }
}

- (void)_editorZoomDidChange:(NSNotification *)note {
    EditorView *ed = note.object;
    if (ed == [self currentEditor]) {
        NSInteger zoom = ed.zoomLevel;
        [[NSUserDefaults standardUserDefaults] setInteger:zoom forKey:kPrefZoomLevel];
        [self updateStatusBar];
    }
}

/// Update _activeTabManager when a Scintilla editor gains keyboard focus.
/// This ensures commands like Language switch target the correct pane in split view.
- (void)editorDidGainFocus:(NSNotification *)note {
    EditorView *ed = note.object;
    if (!ed) return;
    // Find which tab manager owns this editor
    for (TabManager *mgr in @[_tabManager, _subTabManagerH, _subTabManagerV]) {
        if ([mgr.allEditors containsObject:ed]) {
            if (_activeTabManager != mgr) {
                _activeTabManager = mgr;
                [self updateTitle];
                [self updateStatusBar];
            }
            return;
        }
    }
}

#pragma mark - File: Reload / Reveal / Copy / Rename / Trash

- (void)reloadFromDisk:(id)sender {
    EditorView *ed = [self currentEditor];
    NSString *path = ed.filePath;
    if (!path) return;
    if (ed.isModified) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [[NppLocalizer shared] translate:@"Reload from Disk"];
        alert.informativeText = [NSString stringWithFormat:[[NppLocalizer shared] translate:@"'%@' has unsaved changes.\nReload and discard changes?"],
                                 path.lastPathComponent];
        [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Reload"]];
        [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Cancel"]];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }
    NSError *err;
    if (![ed loadFileAtPath:path error:&err])
        [[NSAlert alertWithError:err] runModal];
    [self updateTitle];
    [self updateStatusBar];
}

- (void)revealInFinder:(id)sender {
    NSString *path = [self currentEditor].filePath;
    if (path)
        [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:@""];
}

- (void)openInTerminal:(id)sender {
    NSString *path = [self currentEditor].filePath;
    if (!path) return;
    NSString *dir = path.stringByDeletingLastPathComponent;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    task.arguments = @[@"-a", @"Terminal", dir];
    [task launch];
}

- (void)saveDocumentCopyAs:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = [[NppLocalizer shared] translate:@"Save a Copy As"];
    if (ed.filePath)
        panel.directoryURL = [NSURL fileURLWithPath:ed.filePath.stringByDeletingLastPathComponent];
    panel.nameFieldStringValue = ed.displayName;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        NSError *err;
        // "Save a Copy As" writes a snapshot but must NOT repoint the live
        // document at the copy — otherwise future saves/edits would go to the
        // copy and the original would be stranded.
        if (![ed writeCopyToPath:panel.URL.path error:&err])
            [[NSAlert alertWithError:err] beginSheetModalForWindow:self.window completionHandler:nil];
    }];
}

- (void)renameDocument:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    if (ed.filePath) [self _renameSavedFile:ed];
    else             [self _renameUntitledTab:ed];   // issue #177 — rename unsaved tab
}

// Saved file → rename the file on disk (in place) and retitle the tab.
- (void)_renameSavedFile:(EditorView *)ed {
    NSString *path = ed.filePath;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [[NppLocalizer shared] translate:@"Rename"];
    alert.informativeText = [[NppLocalizer shared] translate:@"Enter a new filename:"];
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 22)];
    tf.stringValue = path.lastPathComponent;
    alert.accessoryView = tf;
    [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Rename"]];
    [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Cancel"]];
    alert.window.initialFirstResponder = tf;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSString *newName = tf.stringValue;
    if (!newName.length || [newName isEqualToString:path.lastPathComponent]) return;
    NSString *newPath = [path.stringByDeletingLastPathComponent
                         stringByAppendingPathComponent:newName];
    NSError *err;
    if ([[NSFileManager defaultManager] moveItemAtPath:path toPath:newPath error:&err]) {
        ed.filePath = newPath;
        [_activeTabManager refreshCurrentTabTitle];
        [self updateTitle];
        if (_docListPanel) [_docListPanel reloadData];
        [self addToRecentFiles:newPath];
    } else {
        [[NSAlert alertWithError:err] runModal];
    }
}

// Untitled tab (issue #177) → rename the TAB only (no file on disk). Renames the
// backup file too, if one exists, so the backup folder stays in sync with the
// new name. The name is persisted in the session so it survives relaunch.
- (void)_renameUntitledTab:(EditorView *)ed {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [[NppLocalizer shared] translate:@"Rename Current Tab"];
    alert.informativeText = [[NppLocalizer shared] translate:@"New name:"];
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 22)];
    tf.stringValue = ed.displayName;
    alert.accessoryView = tf;
    [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Rename"]];
    [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Cancel"]];
    alert.window.initialFirstResponder = tf;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSString *newName = [tf.stringValue stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]];
    if (!newName.length || [newName isEqualToString:ed.displayName]) return;
    // The name becomes part of the backup filename — disallow path separators.
    if ([newName containsString:@"/"] || [newName containsString:@":"]) {
        NSAlert *e = [[NSAlert alloc] init];
        e.messageText = [[NppLocalizer shared] translate:@"Rename failed"];
        e.informativeText = [[NppLocalizer shared] translate:@"The name cannot contain “/” or “:”."];
        [e runModal];
        return;
    }

    // Rename the existing backup file (if any) to reflect the new name, keeping
    // its "@<timestamp>" suffix; update the editor's backup path.
    NSString *oldBackup = ed.backupFilePath;
    if (oldBackup.length) {
        NSString *dir     = oldBackup.stringByDeletingLastPathComponent;
        NSString *oldFile = oldBackup.lastPathComponent;
        NSString *suffix  = @"";
        NSRange at = [oldFile rangeOfString:@"@" options:NSBackwardsSearch];
        if (at.location != NSNotFound) suffix = [oldFile substringFromIndex:at.location];
        // Claim the new name through the uniquifier instead of deleting whatever
        // sits there: renaming a tab to a name another buffer already backed up
        // in the same second would otherwise destroy that buffer's only copy of
        // its unsaved text.
        NSString *newBackup = [EditorView uniqueBackupPathInDirectory:dir
                                                            filename:[newName stringByAppendingString:suffix]];
        if (![newBackup isEqualToString:oldBackup]) {
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm moveItemAtPath:oldBackup toPath:newBackup error:nil])
                ed.backupFilePath = newBackup;
        }
    }

    ed.customTabName = newName;
    [_activeTabManager refreshCurrentTabTitle];
    [self updateTitle];
    if (_docListPanel) [_docListPanel reloadData];
}

- (void)moveToTrash:(id)sender {
    EditorView *ed = [self currentEditor];
    NSString *path = ed.filePath;
    if (!path) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [[NppLocalizer shared] translate:@"Move to Trash"];
    alert.informativeText = [NSString stringWithFormat:[[NppLocalizer shared] translate:@"Move '%@' to the Trash?"],
                             path.lastPathComponent];
    [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Move to Trash"]];
    [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Cancel"]];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSError *err;
    if ([[NSFileManager defaultManager] trashItemAtURL:[NSURL fileURLWithPath:path]
                                     resultingItemURL:nil error:&err]) {
        [_tabManager closeEditor:ed];
        [self updateTitle];
    } else {
        [[NSAlert alertWithError:err] runModal];
    }
}

- (void)printNow:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    NSPrintOperation *op = [NSPrintOperation printOperationWithView:ed.scintillaView
                                                          printInfo:[NSPrintInfo sharedPrintInfo]];
    op.showsPrintPanel = NO;
    op.showsProgressPanel = YES;
    [op runOperation];
}

#pragma mark - File: Close Multiple Documents

/// Outcome of prompting whether to save one modified editor while closing a
/// batch of tabs (Close All, Close All But This, …).
typedef NS_ENUM(NSInteger, NppBatchCloseDecision) {
    NppBatchCloseSaveAttempted, ///< User chose Save; editor is clean iff the save succeeded.
    NppBatchCloseDiscard,       ///< Discard this document's changes.
    NppBatchCloseDiscardAll,    ///< Discard this and every remaining modified document.
    NppBatchCloseCancel,        ///< Abort the whole batch close; leave remaining tabs open.
};

/// Prompt to save one modified editor. When `allowAll` is YES the alert offers
/// an extra "Don't Save All" button so the user can discard every remaining
/// unsaved document in the batch with a single click (issue #214).
- (NppBatchCloseDecision)_promptBatchSaveBeforeClose:(EditorView *)ed allowAll:(BOOL)allowAll {
    NppLocalizer *loc = [NppLocalizer shared];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:[loc translate:@"Save '%@' before closing?"], ed.displayName];
    [alert addButtonWithTitle:[loc translate:@"Save"]];        // NSAlertFirstButtonReturn
    [alert addButtonWithTitle:[loc translate:@"Don't Save"]];  // NSAlertSecondButtonReturn
    if (allowAll)
        [alert addButtonWithTitle:[loc translate:@"Don't Save All"]]; // NSAlertThirdButtonReturn
    [alert addButtonWithTitle:[loc translate:@"Cancel"]];      // Third (or fourth) button

    NSModalResponse r = [alert runModal];
    if (r == NSAlertFirstButtonReturn) {            // Save
        if (ed.filePath) {
            NSError *err;
            [ed saveError:&err];                    // on failure the editor stays modified
        } else {
            // Untitled — run modal save panel. Backing out leaves it modified.
            NSSavePanel *sp = [NSSavePanel savePanel];
            sp.nameFieldStringValue = ed.displayName;
            if ([sp runModal] == NSModalResponseOK) {
                NSError *err;
                [ed saveToPath:sp.URL.path error:&err];
            }
        }
        return NppBatchCloseSaveAttempted;
    }
    if (r == NSAlertSecondButtonReturn) return NppBatchCloseDiscard;                   // Don't Save
    if (allowAll && r == NSAlertThirdButtonReturn) return NppBatchCloseDiscardAll;     // Don't Save All
    return NppBatchCloseCancel;                                                        // Cancel
}

/// Close every editor in `editors` (all belonging to `mgr`), prompting once per
/// modified document. "Don't Save All" suppresses the prompt for the remaining
/// modified documents; Cancel aborts the batch and leaves the unprocessed tabs
/// open. A modified document whose save failed or was declined is kept open and
/// the batch continues with the next tab.
- (void)_closeEditors:(NSArray<EditorView *> *)editors inManager:(TabManager *)mgr {
    NSUInteger dirtyCount = 0;
    for (EditorView *ed in editors)
        if (ed.isModified && !ed.cloneSibling) dirtyCount++;
    BOOL allowAll = dirtyCount > 1;

    BOOL discardAll = NO;
    for (EditorView *ed in editors) {
        if (ed.isModified && !ed.cloneSibling && !discardAll) {
            switch ([self _promptBatchSaveBeforeClose:ed allowAll:allowAll]) {
                case NppBatchCloseCancel:     return;            // abort the whole batch
                case NppBatchCloseDiscardAll: discardAll = YES; break;
                case NppBatchCloseSaveAttempted:
                    if (ed.isModified) continue;                 // save failed/declined — keep this tab
                    break;
                case NppBatchCloseDiscard:    break;
            }
        }
        [mgr removeEditor:ed];
    }
    [self updateTitle];
}

- (void)closeAllButCurrent:(id)sender {
    EditorView *current = [self currentEditor];
    NSArray *all = _activeTabManager.allEditors.copy;
    NSMutableArray<EditorView *> *toClose = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)all.count; i++) {
        EditorView *ed = all[i];
        if (ed == current) continue;
        if ([_activeTabManager.tabBar isTabPinnedAtIndex:i]) continue;
        [toClose addObject:ed];
    }
    [self _closeEditors:toClose inManager:_activeTabManager];
}

- (void)closeAllToLeft:(id)sender {
    EditorView *current = [self currentEditor];
    NSArray *all = _activeTabManager.allEditors;
    NSInteger idx = [all indexOfObject:current];
    if (idx == NSNotFound) return;
    NSMutableArray<EditorView *> *toClose = [NSMutableArray array];
    for (NSInteger i = 0; i < idx; i++) {
        if ([_activeTabManager.tabBar isTabPinnedAtIndex:i]) continue;
        [toClose addObject:all[i]];
    }
    [self _closeEditors:toClose inManager:_activeTabManager];
}

- (void)closeAllToRight:(id)sender {
    EditorView *current = [self currentEditor];
    NSArray *all = _activeTabManager.allEditors;
    NSInteger idx = [all indexOfObject:current];
    if (idx == NSNotFound) return;
    NSMutableArray<EditorView *> *toClose = [NSMutableArray array];
    for (NSInteger i = idx + 1; i < (NSInteger)all.count; i++) {
        if ([_activeTabManager.tabBar isTabPinnedAtIndex:i]) continue;
        [toClose addObject:all[i]];
    }
    [self _closeEditors:toClose inManager:_activeTabManager];
}

- (void)closeAllUnchanged:(id)sender {
    // Collect against the stable snapshot first: removing tabs mid-loop would
    // shift the live tab-bar indices out from under isTabPinnedAtIndex:.
    NSArray *all = _activeTabManager.allEditors.copy;
    NSMutableArray<EditorView *> *toClose = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)all.count; i++) {
        EditorView *ed = all[i];
        if (ed.isModified) continue;
        if ([_activeTabManager.tabBar isTabPinnedAtIndex:i]) continue;
        [toClose addObject:ed];
    }
    for (EditorView *ed in toClose)
        [_activeTabManager removeEditor:ed];  // unmodified — no prompt needed
    [self updateTitle];
}

- (void)closeAllButPinned:(id)sender {
    NSArray *all = _activeTabManager.allEditors.copy;
    NSMutableArray<EditorView *> *toClose = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)all.count; i++) {
        if ([_activeTabManager.tabBar isTabPinnedAtIndex:i]) continue;
        [toClose addObject:all[i]];
    }
    [self _closeEditors:toClose inManager:_activeTabManager];
}

#pragma mark - Edit: Column Mode / Character Panel / Brace Select

- (void)columnMode:(id)sender {
    // Show the informational tip dialog (same as Windows NPP "Column Mode…" menu item)
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [[NppLocalizer shared] translate:@"Column Mode Tip"];
    alert.informativeText = [[NppLocalizer shared] translate:
        @"There are 3 ways to switch to column-select mode:\n\n"
         "1. (Keyboard and Mouse)  Hold Option while left-click dragging\n\n"
         "2. (Keyboard only)  Hold Option+Shift while using arrow keys\n\n"
         "3. (Keyboard or Mouse)\n"
         "   Put caret at desired start of column block position, then\n"
         "   execute \u201cBegin/End Select in Column Mode\u201d command;\n"
         "   Move caret to desired end of column block position, then\n"
         "   execute \u201cBegin/End Select in Column Mode\u201d command again"];
    [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"OK"]];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}
- (void)selectAllInBraces:(id)sender   { [[self currentEditor] selectAllInBraces:sender]; }
- (void)characterPanel:(id)sender {
    if (!_charPanel) {
        _charPanel = [[CharacterPanel alloc] init];
        _charPanel.delegate = self;
    }
    BOOL open = [_sidePanelHost hasPanel:_charPanel];
    [self _setPanelVisible:_charPanel title:@"ASCII Codes Insertion Panel" show:!open];
}

#pragma mark - CharacterPanelDelegate

- (void)characterPanel:(CharacterPanel *)panel insertString:(NSString *)str {
    [[self currentEditor] insertCharacterString:str];
}

- (void)characterPanelDidRequestClose:(CharacterPanel *)panel {
    [self _setPanelVisible:_charPanel title:@"ASCII Codes Insertion Panel" show:NO];
}

#pragma mark - Edit: On Selection

/// Resolve selected text to a file path — tries absolute, then relative to current file's directory.
- (nullable NSString *)_resolveSelectedPath {
    NSString *sel = [[[self currentEditor] selectedText]
                     stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!sel.length) return nil;

    // Strip surrounding quotes if present (common in #include "file.h")
    if ((sel.length >= 2) &&
        (([sel hasPrefix:@"\""] && [sel hasSuffix:@"\""]) ||
         ([sel hasPrefix:@"'"]  && [sel hasSuffix:@"'"])  ||
         ([sel hasPrefix:@"<"]  && [sel hasSuffix:@">"]))) {
        sel = [sel substringWithRange:NSMakeRange(1, sel.length - 2)];
    }

    NSFileManager *fm = [NSFileManager defaultManager];

    // Try as absolute path
    if ([sel isAbsolutePath] && [fm fileExistsAtPath:sel])
        return sel;

    // Try relative to the current file's directory
    EditorView *ed = [self currentEditor];
    if (ed.filePath) {
        NSString *dir = [ed.filePath stringByDeletingLastPathComponent];
        NSString *resolved = [dir stringByAppendingPathComponent:sel];
        resolved = [resolved stringByStandardizingPath];
        if ([fm fileExistsAtPath:resolved])
            return resolved;
    }

    // Try home directory expansion (~/...)
    NSString *expanded = [sel stringByExpandingTildeInPath];
    if (![expanded isEqualToString:sel] && [fm fileExistsAtPath:expanded])
        return expanded;

    // Last resort: try as-is (handles relative to cwd)
    if ([fm fileExistsAtPath:sel])
        return sel;

    return nil;
}

- (void)openSelectionAsFile:(id)sender {
    NSString *path = [self _resolveSelectedPath];
    if (path) {
        BOOL isDir = NO;
        [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
        if (!isDir)
            [self openFileAtPath:path];
        else
            NSBeep();
    } else {
        NSBeep();
    }
}

- (void)openSelectionInDefaultViewer:(id)sender {
    NSString *path = [self _resolveSelectedPath];
    if (!path) { NSBeep(); return; }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
}

- (void)openContainingFolderInFinder:(id)sender {
    NSString *path = [self _resolveSelectedPath];
    if (!path) { NSBeep(); return; }

    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
    if (isDir) {
        // Selected text is a directory — open the folder containing it in Finder
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:
            @[[NSURL fileURLWithPath:path]]];
    } else {
        // Selected text is a file — open its containing folder and select it
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:
            @[[NSURL fileURLWithPath:path]]];
    }
}

- (void)redactSelection:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    NSString *sel = [ed selectedText];
    if (!sel.length) { NSBeep(); return; }
    NSEventModifierFlags mods = [NSEvent modifierFlags];
    unichar replChar = (mods & NSEventModifierFlagShift) ? 0x2022 : 0x25A0;  // • or ■
    NSMutableString *replacement = [NSMutableString stringWithCapacity:sel.length];
    for (NSUInteger i = 0; i < sel.length; i++) {
        unichar c = [sel characterAtIndex:i];
        if (c == '\n' || c == '\r') [replacement appendFormat:@"%C", c];
        else [replacement appendFormat:@"%C", replChar];
    }
    [ed.scintillaView message:SCI_REPLACESEL wParam:0 lParam:(sptr_t)replacement.UTF8String];
}

- (void)searchSelectionOnInternet:(id)sender {
    NSString *sel = [[self currentEditor] selectedText];
    if (!sel) return;
    NSString *encoded = [sel stringByAddingPercentEncodingWithAllowedCharacters:
                         [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *baseURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"kPrefSearchEngineURL"]
                        ?: @"https://www.google.com/search?q=";
    NSURL *url = [NSURL URLWithString:[baseURL stringByAppendingString:encoded]];
    if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)changeSearchEngine:(id)sender {
    NSString *current = [[NSUserDefaults standardUserDefaults] stringForKey:@"kPrefSearchEngineURL"]
                        ?: @"https://www.google.com/search?q=";
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText     = [[NppLocalizer shared] translate:@"Change Search Engine"];
    alert.informativeText = [[NppLocalizer shared] translate:@"Enter the search URL. Use %s as the query placeholder (or append the query at the end):"];
    [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"OK"]];
    [alert addButtonWithTitle:[[NppLocalizer shared] translate:@"Cancel"]];
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 380, 22)];
    tf.stringValue = current;
    alert.accessoryView = tf;
    [alert layout];
    [tf selectText:nil];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString *url = [tf stringValue];
        if (url.length > 0)
            [[NSUserDefaults standardUserDefaults] setObject:url forKey:@"kPrefSearchEngineURL"];
    }
}

#pragma mark - Tools: Hash

- (void)hashMD5Generate:(id)sender      { [[self currentEditor] generateHashForAlgorithm:@"MD5"]; }
- (void)hashMD5ToClipboard:(id)sender   { [[self currentEditor] copyHashForAlgorithm:@"MD5"]; }
- (void)hashSHA1Generate:(id)sender     { [[self currentEditor] generateHashForAlgorithm:@"SHA-1"]; }
- (void)hashSHA1ToClipboard:(id)sender  { [[self currentEditor] copyHashForAlgorithm:@"SHA-1"]; }
- (void)hashSHA256Generate:(id)sender   { [[self currentEditor] generateHashForAlgorithm:@"SHA-256"]; }
- (void)hashSHA256ToClipboard:(id)sender{ [[self currentEditor] copyHashForAlgorithm:@"SHA-256"]; }
- (void)hashSHA512Generate:(id)sender   { [[self currentEditor] generateHashForAlgorithm:@"SHA-512"]; }
- (void)hashSHA512ToClipboard:(id)sender{ [[self currentEditor] copyHashForAlgorithm:@"SHA-512"]; }

#pragma mark - Plugins: Base64 (all variants)

- (void)base64Encode:(id)sender              { [[self currentEditor] base64Encode:sender]; }
- (void)base64Decode:(id)sender              { [[self currentEditor] base64Decode:sender]; }
- (void)base64EncodeWithPadding:(id)sender   { [[self currentEditor] base64EncodeWithPadding:sender]; }
- (void)base64DecodeStrict:(id)sender        { [[self currentEditor] base64DecodeStrict:sender]; }
- (void)base64URLSafeEncode:(id)sender       { [[self currentEditor] base64URLSafeEncode:sender]; }
- (void)base64URLSafeDecode:(id)sender       { [[self currentEditor] base64URLSafeDecode:sender]; }

#pragma mark - Tools: Hash from Files

- (void)_hashFilesForAlgorithm:(NSString *)algo {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles    = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    panel.title = [NSString stringWithFormat:@"Choose files for %@ hash", algo];
    if ([panel runModal] != NSModalResponseOK) return;

    NSMutableString *results = [NSMutableString string];
    for (NSURL *url in panel.URLs) {
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (!data) { [results appendFormat:@"Error reading %@\n", url.path]; continue; }
        NSString *hash = [EditorView hexHashForAlgorithm:algo data:data];
        [results appendFormat:@"%@  %@\n", hash ?: @"(error)", url.path];
    }
    if (!results.length) return;
    EditorView *ed = [self currentEditor];
    if (ed) {
        const char *u = results.UTF8String;
        [ed.scintillaView message:SCI_APPENDTEXT wParam:(uptr_t)strlen(u) lParam:(sptr_t)u];
    }
}

- (void)hashMD5FromFiles:(id)sender    { [self _hashFilesForAlgorithm:@"MD5"]; }
- (void)hashSHA1FromFiles:(id)sender   { [self _hashFilesForAlgorithm:@"SHA-1"]; }
- (void)hashSHA256FromFiles:(id)sender { [self _hashFilesForAlgorithm:@"SHA-256"]; }
- (void)hashSHA512FromFiles:(id)sender { [self _hashFilesForAlgorithm:@"SHA-512"]; }

#pragma mark - View symbol toggles / Hide Lines

- (void)toggleWrapSymbol:(id)sender     { [[self currentEditor] toggleWrapSymbol:sender]; }
- (void)toggleHideLineMarks:(id)sender  { [[self currentEditor] toggleHideLineMarks:sender]; }
- (void)hideLinesInSelection:(id)sender { [[self currentEditor] hideLinesInSelection:sender]; }

#pragma mark - View in Browser

- (void)_viewCurrentFileInBrowserWithBundleID:(NSString *)bundleID {
    EditorView *ed = [self currentEditor];
    NSString *path = ed.filePath;
    if (!path.length) return;
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    if (bundleID.length)
        [[NSWorkspace sharedWorkspace] openURLs:@[fileURL]
                        withAppBundleIdentifier:bundleID
                                        options:0
                 additionalEventParamDescriptor:nil
                              launchIdentifiers:nil];
    else
        [[NSWorkspace sharedWorkspace] openURL:fileURL];
}

- (void)viewInFirefox:(id)sender       { [self _viewCurrentFileInBrowserWithBundleID:@"org.mozilla.firefox"]; }
- (void)viewInChrome:(id)sender        { [self _viewCurrentFileInBrowserWithBundleID:@"com.google.Chrome"]; }
- (void)viewInSafari:(id)sender        { [self _viewCurrentFileInBrowserWithBundleID:@"com.apple.Safari"]; }
- (void)viewInCustomBrowser:(id)sender { [self _viewCurrentFileInBrowserWithBundleID:nil]; }

#pragma mark - File Actions

- (void)openInDefaultViewer:(id)sender {
    NSString *path = [self currentEditor].filePath;
    if (path.length) [[NSWorkspace sharedWorkspace] openFile:path];
}

- (void)openFolderAsWorkspace:(id)sender {
    // Ensure panel exists
    if (!_folderTreePanel) {
        FolderTreePanel *ftp = [[FolderTreePanel alloc] init];
        ftp.delegate = self;
        _folderTreePanel = ftp;
    }
    // Show the panel, then let user pick the root folder
    if (![_sidePanelHost hasPanel:_folderTreePanel])
        [self _setPanelVisible:_folderTreePanel title:@"Folder as Workspace" show:YES];
    [(FolderTreePanel *)_folderTreePanel chooseRootFolder];
}

- (void)openSelectedFileInNewInstance:(id)sender {
    NSString *sel = [[self currentEditor] selectedText];
    if (!sel.length) return;
    sel = [sel stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([[NSFileManager defaultManager] fileExistsAtPath:sel])
        [_activeTabManager openFileAtPath:sel];
}

#pragma mark - Run Menu

- (void)getPHPHelp:(id)sender {
    NSString *sel = [[self currentEditor] selectedText] ?: @"";
    NSString *q = [sel stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:
        [NSString stringWithFormat:@"https://www.php.net/manual-lookup.php?pattern=%@", q]]];
}

- (void)wikiSearch:(id)sender {
    NSString *sel = [[self currentEditor] selectedText] ?: @"";
    NSString *q = [sel stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:
        [NSString stringWithFormat:@"https://en.wikipedia.org/wiki/Special:Search?search=%@", q]]];
}

/// Substitute $(VARIABLE) placeholders in a Run command string.
- (NSString *)_expandRunVariables:(NSString *)cmd {
    EditorView *ed = [self currentEditor];
    ScintillaView *sci = ed.scintillaView;
    NSMutableString *result = [cmd mutableCopy];

    // Helper: replace all occurrences of a variable
    void (^sub)(NSString *var, NSString *val) = ^(NSString *var, NSString *val) {
        [result replaceOccurrencesOfString:[NSString stringWithFormat:@"$(%@)", var]
                                withString:val ?: @""
                                   options:0 range:NSMakeRange(0, result.length)];
    };

    NSString *filePath = ed.filePath ?: @"";
    sub(@"FULL_CURRENT_PATH", filePath);
    sub(@"CURRENT_DIRECTORY", filePath.length ? filePath.stringByDeletingLastPathComponent : @"");
    sub(@"FILE_NAME", filePath.length ? filePath.lastPathComponent : @"");
    sub(@"NAME_PART", filePath.length ? filePath.lastPathComponent.stringByDeletingPathExtension : @"");
    NSString *ext = filePath.pathExtension;
    sub(@"EXT_PART", ext.length ? [@"." stringByAppendingString:ext] : @"");
    sub(@"CURRENT_WORD", ed.selectedText ?: @"");
    sub(@"NPP_DIRECTORY", [NSBundle mainBundle].bundlePath);
    sub(@"NPP_FULL_FILE_PATH", [NSBundle mainBundle].executablePath);

    if (sci) {
        sptr_t pos = [sci message:SCI_GETCURRENTPOS];
        sptr_t line = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)pos];
        sptr_t col  = [sci message:SCI_GETCOLUMN wParam:(uptr_t)pos];
        sub(@"CURRENT_LINE", [@(line + 1) stringValue]);
        sub(@"CURRENT_COLUMN", [@(col + 1) stringValue]);

        // Get current line text
        sptr_t lineLen = [sci message:SCI_LINELENGTH wParam:(uptr_t)line];
        if (lineLen > 0) {
            char *buf = (char *)malloc((size_t)lineLen + 1);
            [sci message:SCI_GETLINE wParam:(uptr_t)line lParam:(sptr_t)buf];
            buf[lineLen] = '\0';
            NSString *lineStr = [NSString stringWithUTF8String:buf] ?: @"";
            // Trim trailing newline
            lineStr = [lineStr stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            sub(@"CURRENT_LINESTR", lineStr);
            free(buf);
        } else {
            sub(@"CURRENT_LINESTR", @"");
        }
    }
    return result;
}

- (void)showRunDialog:(id)sender {
    static NSPanel *panel = nil;
    static NSComboBox *cmdCombo = nil;

    if (!panel) {
        panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 560, 150)
                                           styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
        panel.title = [[NppLocalizer shared] translate:@"Run..."];
        // Identifier is NOT translated, so _runDlgVariableSelected: can
        // find this window again across language switches. The title
        // alone would break the lookup in any non-English locale.
        panel.identifier = @"NPPRunDialog";
        panel.releasedWhenClosed = NO;
        panel.hidesOnDeactivate = NO;
        NSView *v = panel.contentView;

        // Title label
        NSTextField *titleLabel = [NSTextField labelWithString:[[NppLocalizer shared] translate:@"The Program to Run"]];
        titleLabel.frame = NSMakeRect(0, 118, 560, 18);
        titleLabel.alignment = NSTextAlignmentCenter;
        titleLabel.font = [NSFont systemFontOfSize:13];
        [v addSubview:titleLabel];

        // Command combo box (editable, remembers history)
        cmdCombo = [[NSComboBox alloc] initWithFrame:NSMakeRect(20, 82, 440, 24)];
        cmdCombo.editable = YES;
        cmdCombo.completes = NO;
        cmdCombo.placeholderString = [[NppLocalizer shared] translate:@"Enter command or URL..."];
        cmdCombo.numberOfVisibleItems = 10;
        [v addSubview:cmdCombo];

        // "..." button (file browser)
        NSButton *browseBtn = [[NSButton alloc] initWithFrame:NSMakeRect(468, 82, 36, 24)];
        browseBtn.title = @"...";
        browseBtn.bezelStyle = NSBezelStyleRounded;
        browseBtn.target = self;
        browseBtn.action = @selector(_runDlgBrowse:);
        [v addSubview:browseBtn];

        // "+" button (variables menu)
        NSButton *plusBtn = [[NSButton alloc] initWithFrame:NSMakeRect(498, 82, 36, 24)];
        plusBtn.title = @"+";
        plusBtn.bezelStyle = NSBezelStyleRounded;
        plusBtn.target = self;
        plusBtn.action = @selector(_runDlgInsertVariable:);
        [v addSubview:plusBtn];

        // Separator line
        NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(20, 56, 520, 1)];
        sep.boxType = NSBoxSeparator;
        [v addSubview:sep];

        // Bottom buttons: Run, Save..., Cancel
        NSButton *runBtn = [[NSButton alloc] initWithFrame:NSMakeRect(165, 16, 80, 28)];
        runBtn.title = [[NppLocalizer shared] translate:@"Run"];
        runBtn.bezelStyle = NSBezelStyleRounded;
        runBtn.keyEquivalent = @"\r";
        runBtn.target = self;
        runBtn.action = @selector(_runDlgRun:);
        [v addSubview:runBtn];

        NSButton *saveBtn = [[NSButton alloc] initWithFrame:NSMakeRect(255, 16, 80, 28)];
        saveBtn.title = [[NppLocalizer shared] translate:@"Save..."];
        saveBtn.bezelStyle = NSBezelStyleRounded;
        saveBtn.target = self;
        saveBtn.action = @selector(_runDlgSave:);
        [v addSubview:saveBtn];

        NSButton *cancelBtn = [[NSButton alloc] initWithFrame:NSMakeRect(345, 16, 80, 28)];
        cancelBtn.title = [[NppLocalizer shared] translate:@"Cancel"];
        cancelBtn.bezelStyle = NSBezelStyleRounded;
        cancelBtn.keyEquivalent = @"\033";
        cancelBtn.target = panel;
        cancelBtn.action = @selector(close);
        [v addSubview:cancelBtn];
    }

    [panel makeKeyAndOrderFront:nil];
    [panel center];
    [panel makeFirstResponder:cmdCombo];
}

/// "..." button — browse for executable
- (void)_runDlgBrowse:(id)sender {
    NSOpenPanel *op = [NSOpenPanel openPanel];
    op.canChooseFiles = YES;
    op.canChooseDirectories = NO;
    op.allowsMultipleSelection = NO;
    NSWindow *runPanel = [sender window];
    [op beginSheetModalForWindow:runPanel completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSComboBox *combo = nil;
            for (NSView *sub in runPanel.contentView.subviews)
                if ([sub isKindOfClass:[NSComboBox class]]) { combo = (NSComboBox *)sub; break; }
            if (combo) {
                NSString *path = op.URL.path;
                if ([path containsString:@" "]) path = [NSString stringWithFormat:@"\"%@\"", path];
                combo.stringValue = path;
            }
        }
    }];
}

/// "+" button — popup menu of variables
- (void)_runDlgInsertVariable:(NSButton *)sender {
    NSMenu *menu = [[NSMenu alloc] init];
    struct { NSString *var; NSString *desc; } vars[] = {
        { @"FULL_CURRENT_PATH",  @"Full path to active file" },
        { @"CURRENT_DIRECTORY",  @"Active file's directory" },
        { @"FILE_NAME",          @"Active file's name" },
        { @"NAME_PART",          @"File name without extension" },
        { @"EXT_PART",           @"File extension (with .)" },
        { @"CURRENT_WORD",       @"Selected word or word under caret" },
        { @"NPP_DIRECTORY",      @"Nextpad++.app directory" },
        { @"NPP_FULL_FILE_PATH", @"Full path of Nextpad++.app" },
        { @"CURRENT_LINE",       @"Line number of caret" },
        { @"CURRENT_COLUMN",     @"Column number of caret" },
        { @"CURRENT_LINESTR",    @"Current line text" },
    };
    for (int i = 0; i < 11; i++) {
        NSString *title = [NSString stringWithFormat:@"%@\t%@", vars[i].var, vars[i].desc];
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:title
                                                    action:@selector(_runDlgVariableSelected:)
                                             keyEquivalent:@""];
        mi.target = self;
        mi.representedObject = vars[i].var;
        [menu addItem:mi];
    }
    NSPoint pt = NSMakePoint(NSMaxX(sender.frame), NSMinY(sender.frame));
    [menu popUpMenuPositioningItem:nil atLocation:pt inView:sender.superview];
}

/// Variable menu item selected — insert into combo box
- (void)_runDlgVariableSelected:(NSMenuItem *)mi {
    NSString *var = [NSString stringWithFormat:@"$(%@)", mi.representedObject];
    // Look the Run dialog up by identifier rather than title — the title
    // is translated to the active UI language ("Запустить...", "Exécuter…",
    // …) and would silently fail to match the English literal.
    NSComboBox *combo = nil;
    for (NSWindow *w in [NSApp windows])
        if ([w.identifier isEqualToString:@"NPPRunDialog"]) {
            for (NSView *sub in w.contentView.subviews)
                if ([sub isKindOfClass:[NSComboBox class]]) { combo = (NSComboBox *)sub; break; }
            break;
        }
    if (!combo) return;
    // Insert at current cursor position in the field editor
    NSText *fieldEditor = [combo.window fieldEditor:YES forObject:combo];
    if (fieldEditor) {
        [fieldEditor replaceCharactersInRange:fieldEditor.selectedRange withString:var];
    } else {
        combo.stringValue = [combo.stringValue stringByAppendingString:var];
    }
}

/// Run button — execute the command
- (void)_runDlgRun:(id)sender {
    NSComboBox *combo = nil;
    NSPanel *panel = (NSPanel *)[sender window];
    for (NSView *sub in panel.contentView.subviews)
        if ([sub isKindOfClass:[NSComboBox class]]) { combo = (NSComboBox *)sub; break; }
    if (!combo) return;

    NSString *rawCmd = combo.stringValue;
    if (!rawCmd.length) return;

    // Add to combo history
    if (![combo.objectValues containsObject:rawCmd])
        [combo addItemWithObjectValue:rawCmd];

    // Expand variables
    NSString *cmd = [self _expandRunVariables:rawCmd];

    // Execute: URLs open in browser, .app bundles via open, everything else via /bin/sh -c
    if ([cmd hasPrefix:@"http://"] || [cmd hasPrefix:@"https://"]) {
        NSURL *url = [NSURL URLWithString:cmd];
        if (url) [[NSWorkspace sharedWorkspace] openURL:url];
    } else {
        // Strip quotes for path detection
        NSString *trimmed = [cmd stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *unquoted = trimmed;
        if ([unquoted hasPrefix:@"\""] && [unquoted hasSuffix:@"\""])
            unquoted = [unquoted substringWithRange:NSMakeRange(1, unquoted.length - 2)];
        // .app bundles need "open" to launch
        if ([unquoted hasSuffix:@".app"] || [cmd containsString:@".app "]) {
            NSString *openCmd = [NSString stringWithFormat:@"open %@", cmd];
            @try {
                [NSTask launchedTaskWithLaunchPath:@"/bin/sh" arguments:@[@"-c", openCmd]];
            } @catch (NSException *e) {
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = [[NppLocalizer shared] translate:@"Run Error"];
                alert.informativeText = [NSString stringWithFormat:[[NppLocalizer shared] translate:@"Failed to execute:\n%@\n\n%@"], openCmd, e.reason];
                [alert runModal];
            }
        } else {
            @try {
                [NSTask launchedTaskWithLaunchPath:@"/bin/sh" arguments:@[@"-c", cmd]];
            } @catch (NSException *e) {
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = [[NppLocalizer shared] translate:@"Run Error"];
                alert.informativeText = [NSString stringWithFormat:[[NppLocalizer shared] translate:@"Failed to execute:\n%@\n\n%@"], cmd, e.reason];
                [alert runModal];
            }
        }
    }
}

/// Save button — open shortcut assignment dialog (matches Shortcut Mapper style)
/// and save to shortcuts.xml under <UserDefinedCommands>
- (void)_runDlgSave:(id)sender {
    NSComboBox *combo = nil;
    NSPanel *runPanel = (NSPanel *)[sender window];
    for (NSView *sub in runPanel.contentView.subviews)
        if ([sub isKindOfClass:[NSComboBox class]]) { combo = (NSComboBox *)sub; break; }
    if (!combo || !combo.stringValue.length) return;

    NSString *rawCmd = combo.stringValue;

    // Build Shortcut dialog — same layout as Shortcut Mapper's Modify dialog
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 400, 240)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered defer:NO];
    panel.title = [[NppLocalizer shared] translate:@"Shortcut"];
    [panel center];
    NSView *cv = panel.contentView;

    // Name field
    NSTextField *nameLbl = [NSTextField labelWithString:[[NppLocalizer shared] translate:@"Name:"]];
    nameLbl.frame = NSMakeRect(20, 205, 50, 16);
    [cv addSubview:nameLbl];

    NSTextField *nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(75, 201, 305, 24)];
    nameField.placeholderString = [[NppLocalizer shared] translate:@"Command name for Run menu"];
    [cv addSubview:nameField];

    // Modifier checkboxes — same layout as Shortcut Mapper
    NSButton *chkCmd = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"\u2318 Command"] target:nil action:nil];
    chkCmd.frame = NSMakeRect(20, 170, 140, 20);
    [cv addSubview:chkCmd];

    NSButton *chkCtrl = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"\u2303 Control"] target:nil action:nil];
    chkCtrl.frame = NSMakeRect(170, 170, 140, 20);
    [cv addSubview:chkCtrl];

    NSButton *chkOpt = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"\u2325 Option"] target:nil action:nil];
    chkOpt.frame = NSMakeRect(20, 143, 140, 20);
    [cv addSubview:chkOpt];

    NSButton *chkShift = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"\u21E7 Shift"] target:nil action:nil];
    chkShift.frame = NSMakeRect(170, 143, 100, 20);
    [cv addSubview:chkShift];

    NSTextField *plusKey = [NSTextField labelWithString:@"+"];
    plusKey.frame = NSMakeRect(270, 145, 15, 16);
    [cv addSubview:plusKey];

    // Key dropdown
    NSPopUpButton *keyPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(288, 141, 95, 25) pullsDown:NO];
    [keyPopup addItemWithTitle:@"None"];
    for (unichar c = 'A'; c <= 'Z'; c++)
        [keyPopup addItemWithTitle:[NSString stringWithFormat:@"%c", c]];
    for (unichar c = '0'; c <= '9'; c++)
        [keyPopup addItemWithTitle:[NSString stringWithFormat:@"%c", c]];
    for (int i = 1; i <= 12; i++)
        [keyPopup addItemWithTitle:[NSString stringWithFormat:@"F%d", i]];
    [cv addSubview:keyPopup];

    // Conflict warning label
    NSTextField *conflictLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 100, 360, 32)];
    conflictLabel.editable = NO;
    conflictLabel.bordered = NO;
    conflictLabel.drawsBackground = NO;
    conflictLabel.font = [NSFont systemFontOfSize:11];
    conflictLabel.textColor = [NSColor secondaryLabelColor];
    conflictLabel.stringValue = @"";
    conflictLabel.lineBreakMode = NSLineBreakByWordWrapping;
    conflictLabel.maximumNumberOfLines = 2;
    [cv addSubview:conflictLabel];

    // OK / Cancel — created early so the conflict-check block can hold a
    // strong reference and toggle btnOK.enabled live (same gating pattern
    // as the macro Save and Shortcut Mapper Modify dialogs).
    NSButton *btnOK = [[NSButton alloc] initWithFrame:NSMakeRect(195, 12, 90, 28)];
    btnOK.title = [[NppLocalizer shared] translate:@"OK"];
    btnOK.bezelStyle = NSBezelStyleRounded;
    btnOK.keyEquivalent = @"\r";
    btnOK.target = NSApp;
    btnOK.action = @selector(stopModal);
    [cv addSubview:btnOK];

    NSButton *btnCancel = [[NSButton alloc] initWithFrame:NSMakeRect(293, 12, 90, 28)];
    btnCancel.title = [[NppLocalizer shared] translate:@"Cancel"];
    btnCancel.bezelStyle = NSBezelStyleRounded;
    btnCancel.keyEquivalent = @"\033";
    btnCancel.target = NSApp;
    btnCancel.action = @selector(abortModal);
    [cv addSubview:btnCancel];

    // Live conflict check
    void (^checkConflict)(void) = ^{
        NSString *keyName = keyPopup.titleOfSelectedItem;
        if ([keyName isEqualToString:@"None"]) {
            conflictLabel.textColor = [NSColor secondaryLabelColor];
            conflictLabel.stringValue = @"";
            btnOK.enabled = YES;
            return;
        }
        NSUInteger keyCode = 0;
        if (keyName.length == 1) keyCode = [keyName characterAtIndex:0];
        else if ([keyName hasPrefix:@"F"]) keyCode = 111 + [keyName substringFromIndex:1].intValue;
        if (keyCode == 0) {
            conflictLabel.stringValue = @"";
            btnOK.enabled = YES;
            return;
        }

        NSMutableString *msg = [NSMutableString string];
        __block void (^checkMenuBlock)(NSMenu *, NSString *);
        checkMenuBlock = ^(NSMenu *menu, NSString *cat) {
            for (NSMenuItem *mi in menu.itemArray) {
                if (mi.submenu) { checkMenuBlock(mi.submenu, cat); continue; }
                if (!mi.action || !mi.keyEquivalent.length) continue;
                NSEventModifierFlags m = mi.keyEquivalentModifierMask;
                BOOL mCmd = (m & NSEventModifierFlagCommand) != 0;
                BOOL mCtrl = (m & NSEventModifierFlagControl) != 0;
                BOOL mAlt = (m & NSEventModifierFlagOption) != 0;
                BOOL mShift = (m & NSEventModifierFlagShift) != 0;
                unichar mKey = [mi.keyEquivalent.uppercaseString characterAtIndex:0];
                if (mKey >= 0xF704 && mKey <= 0xF70F) mKey = 112 + (mKey - 0xF704);
                if (mKey == keyCode &&
                    mCmd == (chkCmd.state == NSControlStateValueOn) &&
                    mCtrl == (chkCtrl.state == NSControlStateValueOn) &&
                    mAlt == (chkOpt.state == NSControlStateValueOn) &&
                    mShift == (chkShift.state == NSControlStateValueOn)) {
                    [msg appendFormat:@"Conflict: %@ (%@)", mi.title, cat];
                }
            }
        };
        for (NSMenuItem *topItem in [NSApp mainMenu].itemArray) {
            if (!topItem.submenu) continue;
            checkMenuBlock(topItem.submenu, topItem.submenu.title ?: topItem.title);
        }
        if (msg.length) {
            conflictLabel.textColor = [NSColor systemRedColor];
            conflictLabel.stringValue = msg;
            btnOK.enabled = NO;          // collision → block save
        } else {
            conflictLabel.textColor = [NSColor secondaryLabelColor];
            conflictLabel.stringValue = [[NppLocalizer shared] translate:@"No shortcut conflicts."];
            btnOK.enabled = YES;
        }
    };

    // Strong references keep the NSBlockOperations alive through the modal
    // run loop (NSControl.target is zeroing-weak under ARC; see the
    // detailed comment in ShortcutMapperWindowController._modifyShortcut:).
    NSMutableArray *targetOps = [NSMutableArray array];
    for (NSButton *chk in @[chkCmd, chkCtrl, chkOpt, chkShift]) {
        NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:checkConflict];
        chk.target = op;
        chk.action = @selector(main);
        [targetOps addObject:op];
    }
    NSBlockOperation *keyOp = [NSBlockOperation blockOperationWithBlock:checkConflict];
    keyPopup.target = keyOp;
    keyPopup.action = @selector(main);
    [targetOps addObject:keyOp];

    // Initial check (also sets btnOK.enabled to its starting state)
    checkConflict();

    // red x = cancel, not "leave the app in purgatory"
    id closeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowWillCloseNotification
                    object:panel
                     queue:nil
                usingBlock:^(NSNotification *note) { [NSApp abortModal]; }];

    NSModalResponse resp = [NSApp runModalForWindow:panel];
    [[NSNotificationCenter defaultCenter] removeObserver:closeObserver];
    [panel orderOut:nil];
    if (resp != NSModalResponseStop || !nameField.stringValue.length) return;

    // Collect shortcut info
    NSString *name = nameField.stringValue;
    BOOL hasCmd   = (chkCmd.state == NSControlStateValueOn);
    BOOL hasCtrl  = (chkCtrl.state == NSControlStateValueOn);
    BOOL hasOpt   = (chkOpt.state == NSControlStateValueOn);
    BOOL hasShift = (chkShift.state == NSControlStateValueOn);
    NSString *keyTitle = keyPopup.titleOfSelectedItem;
    int keyCode = 0;
    if ([keyTitle isEqualToString:@"None"]) keyCode = 0;
    else if (keyTitle.length == 1) keyCode = [keyTitle characterAtIndex:0];
    else if ([keyTitle hasPrefix:@"F"] && keyTitle.length <= 3) keyCode = 111 + [keyTitle substringFromIndex:1].intValue;
    else if ([keyTitle isEqualToString:@"Backspace"]) keyCode = 8;
    else if ([keyTitle isEqualToString:@"Tab"]) keyCode = 9;
    else if ([keyTitle isEqualToString:@"Enter"]) keyCode = 13;
    else if ([keyTitle isEqualToString:@"Escape"]) keyCode = 27;
    else if ([keyTitle isEqualToString:@"Space"]) keyCode = 32;
    else if ([keyTitle isEqualToString:@"Page Up"]) keyCode = 33;
    else if ([keyTitle isEqualToString:@"Page Down"]) keyCode = 34;
    else if ([keyTitle isEqualToString:@"End"]) keyCode = 35;
    else if ([keyTitle isEqualToString:@"Home"]) keyCode = 36;
    else if ([keyTitle isEqualToString:@"Left"]) keyCode = 37;
    else if ([keyTitle isEqualToString:@"Up"]) keyCode = 38;
    else if ([keyTitle isEqualToString:@"Right"]) keyCode = 39;
    else if ([keyTitle isEqualToString:@"Down"]) keyCode = 40;
    else if ([keyTitle isEqualToString:@"Insert"]) keyCode = 45;
    else if ([keyTitle isEqualToString:@"Delete"]) keyCode = 46;

    // Insert into shortcuts.xml using raw text manipulation (preserves file structure)
    NSString *shortcutsPath = NppConfigSubpath(@"shortcuts.xml");
    NSMutableString *xml = [[NSString stringWithContentsOfFile:shortcutsPath
                                                     encoding:NSUTF8StringEncoding error:nil] mutableCopy];
    if (!xml) return;

    // Build the <Command> element
    // XML-escape the command text
    NSMutableString *escapedCmd = [rawCmd mutableCopy];
    [escapedCmd replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escapedCmd.length)];
    [escapedCmd replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escapedCmd.length)];
    [escapedCmd replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escapedCmd.length)];
    [escapedCmd replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, escapedCmd.length)];

    NSString *cmdXML = [NSString stringWithFormat:
        @"        <Command name=\"%@\" Ctrl=\"%@\" Alt=\"%@\" Shift=\"%@\" Cmd=\"%@\" Key=\"%d\">%@</Command>",
        name,
        hasCtrl ? @"yes" : @"no",
        hasOpt ? @"yes" : @"no",
        hasShift ? @"yes" : @"no",
        hasCmd ? @"yes" : @"no",
        keyCode,
        escapedCmd];

    // Find </UserDefinedCommands> and insert before it
    NSRange closeTag = [xml rangeOfString:@"</UserDefinedCommands>"];
    if (closeTag.location != NSNotFound) {
        [xml insertString:[cmdXML stringByAppendingString:@"\n"] atIndex:closeTag.location];
    }

    [xml writeToFile:shortcutsPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    [self rebuildRunMenu];
}

/// Execute a saved Run command from the menu
- (void)_runSavedCommand:(NSMenuItem *)mi {
    NSString *rawCmd = mi.representedObject;
    if (!rawCmd.length) return;
    NSString *cmd = [self _expandRunVariables:rawCmd];
    if ([cmd hasPrefix:@"http://"] || [cmd hasPrefix:@"https://"]) {
        NSURL *url = [NSURL URLWithString:cmd];
        if (url) [[NSWorkspace sharedWorkspace] openURL:url];
    } else {
        // .app bundles need "open" to launch
        NSString *execCmd = cmd;
        NSString *trimmed = [cmd stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *unquoted = trimmed;
        if ([unquoted hasPrefix:@"\""] && [unquoted hasSuffix:@"\""])
            unquoted = [unquoted substringWithRange:NSMakeRange(1, unquoted.length - 2)];
        if ([unquoted hasSuffix:@".app"] || [cmd containsString:@".app "])
            execCmd = [NSString stringWithFormat:@"open %@", cmd];
        @try {
            [NSTask launchedTaskWithLaunchPath:@"/bin/sh" arguments:@[@"-c", execCmd]];
        } @catch (NSException *e) {
            NSLog(@"Run command error: %@", e.reason);
        }
    }
}

#pragma mark - Search: Mark Text

// Forwarded to current editor — style is encoded in sender.tag (1-5).
- (void)styleAllOccurrences:(id)sender {
    NSInteger st = [(NSMenuItem *)sender tag];
    EditorView *ed = [self currentEditor]; if (!ed) return;
    NSString *sel = [ed selectedText];
    if (!sel.length) {
        // Try word at caret via find current word
        sel = [ed.scintillaView string]; // fallback; use selected word if any
        return;
    }
    [ed markStyle:st allOccurrencesOf:sel matchCase:YES wholeWord:NO];
}

- (void)styleOneToken:(id)sender {
    NSInteger st = [(NSMenuItem *)sender tag];
    [[self currentEditor] markStyleSelection:st];
}

- (void)clearMarkStyleN:(id)sender {
    NSInteger st = [(NSMenuItem *)sender tag];
    [[self currentEditor] clearMarkStyle:st];
}

- (void)clearAllMarkStyles:(id)sender {
    [[self currentEditor] clearAllMarkStyles];
}

- (void)jumpToNextStyledTokenBelow:(id)sender { [[self currentEditor] jumpToNextMark:1];  }
- (void)jumpToNextStyledTokenAbove:(id)sender { [[self currentEditor] jumpToNextMark:-1]; }
- (void)jumpToNextBookmarkBelow:(id)sender    { [[self currentEditor] nextBookmark:sender]; }
- (void)jumpToNextBookmarkAbove:(id)sender    { [[self currentEditor] previousBookmark:sender]; }

- (void)copyStyledText:(id)sender {
    NSInteger st = [(NSMenuItem *)sender tag];
    [[self currentEditor] copyTextWithMarkStyle:st];
}

- (void)showMarkDialog:(id)sender {
    [self _ensureFindWindow];
    [self _fillFindFieldWithSelectionIfEnabled];
    [[FindWindow sharedWindow] showTab:FindWindowTabMark];
}

- (void)pasteToBookmarkedLines:(id)sender { [[self currentEditor] pasteToBookmarkedLines:sender]; }

#pragma mark - Find Characters in Range

- (void)showFindCharsInRange:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;

    // Create panel if not already showing
    static NSPanel *panel = nil;
    static NSButton *radioNonASCII, *radioASCII, *radioCustom;
    static NSTextField *rangeStartField, *rangeEndField;
    static NSButton *radioDirDown, *radioDirUp, *wrapCheck;

    if (!panel) {
        panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 400, 230)
                                           styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
        panel.title = [[NppLocalizer shared] translate:@"Find Characters in Range..."];
        panel.releasedWhenClosed = NO;
        panel.hidesOnDeactivate = NO;
        NSView *v = panel.contentView;
        CGFloat y = 200;

        // Mutual exclusion handler for range radio buttons
        void (^rangeRadioAction)(NSButton *) = ^(NSButton *clicked) {
            for (NSButton *r in @[radioNonASCII, radioASCII, radioCustom])
                r.state = (r == clicked) ? NSControlStateValueOn : NSControlStateValueOff;
        };

        // Radio buttons — range selection
        radioNonASCII = [NSButton radioButtonWithTitle:[[NppLocalizer shared] translate:@"Non-ASCII characters (128\u2013255)"]
                                                target:self action:@selector(_findCharRangeRadio:)];
        radioNonASCII.frame = NSMakeRect(20, y, 300, 20);
        radioNonASCII.tag = 1;
        radioNonASCII.state = NSControlStateValueOn;
        [v addSubview:radioNonASCII];
        y -= 24;

        radioASCII = [NSButton radioButtonWithTitle:[[NppLocalizer shared] translate:@"ASCII characters (0\u2013127)"]
                                             target:self action:@selector(_findCharRangeRadio:)];
        radioASCII.frame = NSMakeRect(20, y, 300, 20);
        radioASCII.tag = 2;
        [v addSubview:radioASCII];
        y -= 24;

        radioCustom = [NSButton radioButtonWithTitle:[[NppLocalizer shared] translate:@"Custom range (0\u2013255):"]
                                              target:self action:@selector(_findCharRangeRadio:)];
        radioCustom.frame = NSMakeRect(20, y, 190, 20);
        radioCustom.tag = 3;
        [v addSubview:radioCustom];

        rangeStartField = [[NSTextField alloc] initWithFrame:NSMakeRect(215, y, 40, 22)];
        rangeStartField.stringValue = @"0";
        rangeStartField.alignment = NSTextAlignmentCenter;
        rangeStartField.enabled = NO;  // disabled until Custom range selected
        rangeStartField.tag = 5;       // looked up by tag in _findCharInRange:
        [v addSubview:rangeStartField];

        NSTextField *dash = [NSTextField labelWithString:@"\u2013"];
        dash.frame = NSMakeRect(258, y, 12, 20);
        [v addSubview:dash];

        rangeEndField = [[NSTextField alloc] initWithFrame:NSMakeRect(273, y, 40, 22)];
        rangeEndField.stringValue = @"255";
        rangeEndField.alignment = NSTextAlignmentCenter;
        rangeEndField.enabled = NO;  // disabled until Custom range selected
        rangeEndField.tag = 6;
        [v addSubview:rangeEndField];

        // Direction group
        y -= 34;
        NSBox *dirBox = [[NSBox alloc] initWithFrame:NSMakeRect(20, y - 30, 150, 55)];
        dirBox.title = [[NppLocalizer shared] translate:@"Direction"];
        dirBox.titlePosition = NSAtTop;

        radioDirUp = [NSButton radioButtonWithTitle:[[NppLocalizer shared] translate:@"Up"] target:self action:@selector(_findCharDirRadio:)];
        radioDirUp.frame = NSMakeRect(10, 5, 50, 18);
        radioDirUp.tag = 10;
        [dirBox addSubview:radioDirUp];

        radioDirDown = [NSButton radioButtonWithTitle:[[NppLocalizer shared] translate:@"Down"] target:self action:@selector(_findCharDirRadio:)];
        radioDirDown.frame = NSMakeRect(65, 5, 60, 18);
        radioDirDown.tag = 11;
        radioDirDown.state = NSControlStateValueOn;
        [dirBox addSubview:radioDirDown];
        [v addSubview:dirBox];

        // Wrap around
        wrapCheck = [NSButton checkboxWithTitle:[[NppLocalizer shared] translate:@"Wrap around"] target:nil action:nil];
        wrapCheck.frame = NSMakeRect(185, y - 15, 120, 20);
        wrapCheck.tag = 4;             // looked up by tag in _findCharInRange:
        [v addSubview:wrapCheck];

        // Find and Close buttons — horizontal at the bottom
        NSButton *findBtn = [[NSButton alloc] initWithFrame:NSMakeRect(200, 12, 85, 28)];
        findBtn.title = [[NppLocalizer shared] translate:@"Find"];
        findBtn.bezelStyle = NSBezelStyleRounded;
        findBtn.keyEquivalent = @"\r";
        findBtn.target = self;
        findBtn.action = @selector(_findCharInRange:);
        [v addSubview:findBtn];

        NSButton *closeBtn = [[NSButton alloc] initWithFrame:NSMakeRect(295, 12, 85, 28)];
        closeBtn.title = [[NppLocalizer shared] translate:@"Close"];
        closeBtn.bezelStyle = NSBezelStyleRounded;
        closeBtn.target = panel;
        closeBtn.action = @selector(close);
        [v addSubview:closeBtn];
    }

    [panel makeKeyAndOrderFront:nil];
    [panel center];
}

/// Mutual exclusion for range radio buttons (Non-ASCII / ASCII / Custom).
/// Tags 1-3 identify the range radio group. Enables/disables custom range fields.
- (void)_findCharRangeRadio:(NSButton *)clicked {
    NSView *v = clicked.superview;
    BOOL customSelected = (clicked.tag == 3);
    for (NSView *sub in v.subviews) {
        if ([sub isKindOfClass:[NSButton class]]) {
            NSInteger tag = [(NSButton *)sub tag];
            if (tag >= 1 && tag <= 3)
                [(NSButton *)sub setState:(sub == clicked) ? NSControlStateValueOn : NSControlStateValueOff];
        }
        // Enable/disable the custom range text fields
        if ([sub isKindOfClass:[NSTextField class]] && [(NSTextField *)sub isEditable])
            [(NSTextField *)sub setEnabled:customSelected];
    }
}

/// Mutual exclusion for direction radio buttons (Up / Down).
- (void)_findCharDirRadio:(NSButton *)clicked {
    NSView *box = clicked.superview; // NSBox content view
    for (NSView *sub in box.subviews) {
        if ([sub isKindOfClass:[NSButton class]])
            [(NSButton *)sub setState:(sub == clicked) ? NSControlStateValueOn : NSControlStateValueOff];
    }
}

- (void)_findCharInRange:(id)sender {
    EditorView *ed = [self currentEditor];
    if (!ed) return;
    ScintillaView *sci = ed.scintillaView;

    // Look every control up by the tag we assigned at construction. The
    // previous implementation scanned subviews by `title containsString:`
    // / frame X-coordinate, which silently failed in any non-English UI
    // language: every radio button title gets translated by NppLocalizer
    // before this handler runs, so the comparisons returned all-nil and
    // the dialog ran with default 0-255 + forward direction regardless
    // of what the user actually picked.
    //
    // viewWithTag: walks the subview tree (including inside the
    // NSBox direction group), so the flat lookup covers radio buttons,
    // checkboxes, and text fields uniformly. Tags are assigned in
    // showFindCharsInRange: above.
    NSPanel *panel = (NSPanel *)[sender window];
    NSView *v = panel.contentView;

    NSButton    *radioNonASCII   = (NSButton *)   [v viewWithTag:1];
    NSButton    *radioASCII      = (NSButton *)   [v viewWithTag:2];
    // tag 3 is "Custom range" — its selection state is implicit (the
    // fallback branch fires when neither NonASCII nor ASCII is on), so we
    // don't need a reference to it here.
    NSButton    *wrapCheck       = (NSButton *)   [v viewWithTag:4];
    NSTextField *rangeStartField = (NSTextField *)[v viewWithTag:5];
    NSTextField *rangeEndField   = (NSTextField *)[v viewWithTag:6];
    NSButton    *radioDirUp      = (NSButton *)   [v viewWithTag:10];

    // Determine byte range
    unsigned char beginRange, endRange;
    if (radioNonASCII && radioNonASCII.state == NSControlStateValueOn) {
        beginRange = 128; endRange = 255;
    } else if (radioASCII && radioASCII.state == NSControlStateValueOn) {
        beginRange = 0; endRange = 127;
    } else {
        int s = rangeStartField ? rangeStartField.intValue : 0;
        int e = rangeEndField ? rangeEndField.intValue : 255;
        if (s < 0 || s > 255 || e < 0 || e > 255 || s > e) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = [[NppLocalizer shared] translate:@"Invalid Range"];
            alert.informativeText = [[NppLocalizer shared] translate:@"Range values must be 0-255 and start must be <= end."];
            [alert runModal];
            return;
        }
        beginRange = (unsigned char)s;
        endRange = (unsigned char)e;
    }

    BOOL dirUp = (radioDirUp && radioDirUp.state == NSControlStateValueOn);
    BOOL wrap = (wrapCheck && wrapCheck.state == NSControlStateValueOn);

    // Get document content as raw UTF-8 bytes
    intptr_t totalSize = [sci message:SCI_GETLENGTH];
    intptr_t startPos = [sci message:SCI_GETCURRENTPOS];
    if (startPos > totalSize) startPos = totalSize;
    if (totalSize == 0) return;

    const char *content = (const char *)[sci message:SCI_GETCHARACTERPOINTER];
    if (!content) return;

    // Decode a UTF-8 character at byte position, return its codepoint and byte length.
    intptr_t (^utf8Decode)(intptr_t pos, int *outLen) = ^intptr_t(intptr_t pos, int *outLen) {
        unsigned char b = (unsigned char)content[pos];
        if (b < 0x80)       { *outLen = 1; return b; }
        if (b < 0xC0)       { *outLen = 1; return b; } // continuation byte (shouldn't start here)
        if (b < 0xE0 && pos+1 < totalSize) {
            *outLen = 2;
            return ((b & 0x1F) << 6) | (content[pos+1] & 0x3F);
        }
        if (b < 0xF0 && pos+2 < totalSize) {
            *outLen = 3;
            return ((b & 0x0F) << 12) | ((content[pos+1] & 0x3F) << 6) | (content[pos+2] & 0x3F);
        }
        if (pos+3 < totalSize) {
            *outLen = 4;
            return ((b & 0x07) << 18) | ((content[pos+1] & 0x3F) << 12)
                 | ((content[pos+2] & 0x3F) << 6) | (content[pos+3] & 0x3F);
        }
        *outLen = 1; return b;
    };

    // Step backward to the start of the previous UTF-8 character.
    intptr_t (^utf8PrevPos)(intptr_t pos) = ^intptr_t(intptr_t pos) {
        if (pos <= 0) return -1;
        pos--;
        while (pos > 0 && ((unsigned char)content[pos] & 0xC0) == 0x80) pos--;
        return pos;
    };

    // Search by Unicode codepoint, comparing against the 0-255 range.
    intptr_t foundPos = -1;
    int foundLen = 0;

    if (!dirUp) {
        // Search DOWN (forward)
        for (intptr_t i = startPos; i < totalSize; ) {
            int charLen;
            intptr_t cp = utf8Decode(i, &charLen);
            if (cp >= beginRange && cp <= endRange) { foundPos = i; foundLen = charLen; break; }
            i += charLen;
        }
        if (foundPos < 0 && wrap) {
            for (intptr_t i = 0; i < startPos; ) {
                int charLen;
                intptr_t cp = utf8Decode(i, &charLen);
                if (cp >= beginRange && cp <= endRange) { foundPos = i; foundLen = charLen; break; }
                i += charLen;
            }
        }
    } else {
        // Search UP (backward)
        for (intptr_t i = utf8PrevPos(startPos); i >= 0; i = utf8PrevPos(i)) {
            int charLen;
            intptr_t cp = utf8Decode(i, &charLen);
            if (cp >= beginRange && cp <= endRange) { foundPos = i; foundLen = charLen; break; }
        }
        if (foundPos < 0 && wrap) {
            for (intptr_t i = utf8PrevPos(totalSize); i >= startPos; i = utf8PrevPos(i)) {
                int charLen;
                intptr_t cp = utf8Decode(i, &charLen);
                if (cp >= beginRange && cp <= endRange) { foundPos = i; foundLen = charLen; break; }
            }
        }
    }

    if (foundPos >= 0) {
        intptr_t line = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)foundPos];
        [sci message:SCI_ENSUREVISIBLE wParam:(uptr_t)line];
        if (!dirUp) {
            [sci message:SCI_SETSEL wParam:(uptr_t)foundPos lParam:(sptr_t)(foundPos + foundLen)];
        } else {
            [sci message:SCI_SETSEL wParam:(uptr_t)(foundPos + foundLen) lParam:(sptr_t)foundPos];
        }
    } else {
        NSBeep();
    }
}

#pragma mark - Search Results Window (reuses Find in Files)

- (void)showSearchResultsWindow:(id)sender {
    [self _toggleSearchResultsPanel];
}

- (void)nextSearchResult:(id)sender {
    if (!_searchResultsPanel) return;
    [self _showSearchResultsPanelIfHidden];
    [_searchResultsPanel navigateToNextResult];
}

- (void)previousSearchResult:(id)sender {
    if (!_searchResultsPanel) return;
    [self _showSearchResultsPanelIfHidden];
    [_searchResultsPanel navigateToPreviousResult];
}

- (void)_toggleSearchResultsPanel {
    if (!_searchResultsPanel) {
        _searchResultsPanel = [[SearchResultsPanel alloc] init];
        _searchResultsPanel.delegate = self;
    }
    if (!_searchSplitView) return;

    BOOL isCollapsed = [_searchSplitView isSubviewCollapsed:_searchResultsPanel];
    if (isCollapsed) {
        CGFloat h = NSHeight(_searchSplitView.frame);
        [_searchSplitView setPosition:h * 0.7 ofDividerAtIndex:0];
    } else {
        [_searchSplitView setPosition:NSHeight(_searchSplitView.frame) ofDividerAtIndex:0];
    }
}

- (void)_showSearchResultsPanelIfHidden {
    if (!_searchResultsPanel) {
        _searchResultsPanel = [[SearchResultsPanel alloc] init];
        _searchResultsPanel.delegate = self;
    }
    if (!_searchSplitView) return;

    BOOL isCollapsed = [_searchSplitView isSubviewCollapsed:_searchResultsPanel];
    if (isCollapsed) {
        CGFloat h = NSHeight(_searchSplitView.frame);
        [_searchSplitView setPosition:h * 0.7 ofDividerAtIndex:0];
    }
}

#pragma mark - Multi-select in all opened documents

#pragma mark - Plugins: Stubs

- (void)showPluginsAdmin:(id)sender {
    [[PluginsAdminWindowController sharedController] showWindow:nil];
}

- (void)openPluginsFolder:(id)sender {
    NSString *dir = [nppConfigDir() stringByAppendingPathComponent:@"plugins"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSWorkspace sharedWorkspace] openFile:dir];
}

- (void)showShortcutMapper:(id)sender {
    // Retain the controller so it doesn't get deallocated while the window is open
    static ShortcutMapperWindowController *mapper = nil;
    mapper = [[ShortcutMapperWindowController alloc] init];
    [mapper showWithTab:ShortcutMapperTabMainMenu];
}

- (void)showShortcutMapperMacros:(id)sender {
    static ShortcutMapperWindowController *mapper = nil;
    mapper = [[ShortcutMapperWindowController alloc] init];
    [mapper showWithTab:ShortcutMapperTabMacros];
}

- (void)showShortcutMapperRunCmds:(id)sender {
    static ShortcutMapperWindowController *mapper = nil;
    mapper = [[ShortcutMapperWindowController alloc] init];
    [mapper showWithTab:ShortcutMapperTabRunCommands];
}

- (void)editPopupContextMenu:(id)sender {
    NppLocalizer *loc = [NppLocalizer shared];
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [loc translate:@"Editing contextMenu"];
    a.informativeText = [loc translate:@"Editing contextMenu.xml allows you to modify your Nextpad++ popup context menu on edit zone.\nYou have to restart your Nextpad++ to take effect after modifying contextMenu.xml."];
    [a addButtonWithTitle:[loc translate:@"OK"]];
    [a runModal];

    // Open ~/Library/Application Support/Nextpad++/contextMenu.xml for editing in Nextpad++ itself
    NSString *ctxPath = [nppConfigDir() stringByAppendingPathComponent:@"contextMenu.xml"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:ctxPath]) {
        [self openFileAtPath:ctxPath];
    }
}

- (void)openUDLFolder:(id)sender {
    NSString *dir = [nppConfigDir() stringByAppendingPathComponent:@"userDefineLangs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSWorkspace sharedWorkspace] openFile:dir];
}

- (void)openUDLCollection:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL URLWithString:@"https://github.com/notepad-plus-plus/userDefinedLanguages"]];
}

- (void)showCLIHelp:(id)sender {
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 620, 520)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title = [[NppLocalizer shared] translate:@"Command Line Arguments"];
    [panel center];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(15, 45, 590, 460)];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;

    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 570, 460)];
    tv.editable = NO;
    tv.font = [NSFont fontWithName:@"Menlo" size:11];
    tv.string =
        @"Usage:\n\n"
        @"nextpad++ [--help] [-multiInst] [-noPlugin] [-lLanguage] [-udl=\"My UDL Name\"]\n"
        @"[-LlangCode] [-nLineNumber] [-cColumnNumber] [-pPosition] [-xLeftPos] [-yTopPos]\n"
        @"[-monitor] [-nosession] [-notabbar] [-loadingTime] [-alwaysOnTop]\n"
        @"[-ro] [-fullReadOnly] [-fullReadOnlySavingForbidden] [-openSession] [-r]\n"
        @"[-qn=\"Easter egg name\" | -qt=\"a text to display.\" | -qf=\"/path/quote.txt\"]\n"
        @"[-qSpeed1|2|3] [-quickPrint] [-settingsDir=\"/your settings dir/\"]\n"
        @"[-openFoldersAsWorkspace] [-titleAdd=\"additional title bar text\"]\n"
        @"[filePath]\n\n"
        @"--help: This help message\n"
        @"-multiInst: Launch another Nextpad++ instance\n"
        @"-noPlugin: Launch Nextpad++ without loading any plugin\n"
        @"-l: Open file or Ghost type with syntax highlighting of choice\n"
        @"-udl=\"My UDL Name\": Open file by applying User Defined Language\n"
        @"-L: Apply indicated localization, langCode is browser language code\n"
        @"-n: Scroll to indicated line on filePath\n"
        @"-c: Scroll to indicated column on filePath\n"
        @"-p: Scroll to indicated position on filePath\n"
        @"-x: Move Nextpad++ to indicated left side position on the screen\n"
        @"-y: Move Nextpad++ to indicated top position on the screen\n"
        @"-monitor: Open file with file monitoring enabled\n"
        @"-nosession: Launch Nextpad++ without previous session\n"
        @"-notabbar: Launch Nextpad++ without tab bar\n"
        @"-ro: Make the filePath read-only\n"
        @"-fullReadOnly: Open all files read-only by default, toggling the R/O off\n"
        @"  and saving is allowed\n"
        @"-fullReadOnlySavingForbidden: Open all files read-only by default,\n"
        @"  toggling the R/O off and saving is disabled\n"
        @"-loadingTime: Display Nextpad++ loading time\n"
        @"-alwaysOnTop: Make Nextpad++ always on top\n"
        @"-openSession: Open a session. filePath must be a session file\n"
        @"-r: Open files recursively. This argument will be ignored if filePath\n"
        @"  contains no wildcard character\n"
        @"-qn=\"Easter egg name\": Ghost type easter egg via its name\n"
        @"-qt=\"text to display.\": Ghost type the given text\n"
        @"-qf=\"/path/quote.txt\": Ghost type a file content via the file path\n"
        @"-qSpeed: Ghost typing speed. Value from 1 to 3 for slow, fast and fastest\n"
        @"-quickPrint: Print the file given as argument then quit Nextpad++\n"
        @"-settingsDir=\"/your settings dir/\": Override the default settings dir\n"
        @"-openFoldersAsWorkspace: Open filePath of folder(s) as workspace\n"
        @"-titleAdd=\"string\": Add string to Nextpad++ title bar\n"
        @"filePath: File or folder name to open (absolute or relative path name).\n"
        @"  Passing a folder opens every file directly inside it (top level "
        @"only — subfolders and hidden files are skipped). Use -r to recurse "
        @"into subfolders, or -openFoldersAsWorkspace to open it as a "
        @"workspace instead.\n\n"
        @"Note (macOS): most flags above work as documented. Not yet "
        @"implemented: -L, -settingsDir, and the Ghost-typing flags "
        @"(-qn / -qt / -qf / -qSpeed). The -fullReadOnly and "
        @"-fullReadOnlySavingForbidden flags currently behave like -ro.\n\n"
        @"To use the 'nextpad++' command shown above, run "
        @"App menu > 'Install nextpad++ Command Line Tool…'.\n\n"
        @"Same-instance behaviour:\n"
        @"• Passing files only — e.g. 'nextpad++ a.txt b.txt' — opens them "
        @"as new tabs in the Nextpad++ window that is already running.\n"
        @"• Passing a folder — e.g. 'nextpad++ myfolder' — opens that "
        @"folder's top-level files as tabs in the running window. Opening "
        @"more than 20 files at once asks for confirmation first.\n"
        @"• Passing any option flag (-n42, -lcpp, …) starts a fresh "
        @"Nextpad++ instance: flags are only applied at launch and cannot "
        @"be delivered to an already-running window.\n\n"
        @"Without the installed command you can still launch via:\n"
        @"  open -a Nextpad++ file.txt          (opens in running instance)\n"
        @"  open -a Nextpad++ --args -n42 file.txt   (flags — fresh launch)\n"
        @"or invoke the binary directly:\n"
        @"  /Applications/Nextpad++.app/Contents/MacOS/Nextpad++ file.txt";

    scroll.documentView = tv;
    [panel.contentView addSubview:scroll];

    NSButton *btnOK = [[NSButton alloc] initWithFrame:NSMakeRect(265, 8, 90, 28)];
    btnOK.title = [[NppLocalizer shared] translate:@"OK"];
    btnOK.bezelStyle = NSBezelStyleRounded;
    btnOK.keyEquivalent = @"\r";
    btnOK.target = NSApp;
    btnOK.action = @selector(stopModal);
    [panel.contentView addSubview:btnOK];

    // The X (close) button doesn't call -stopModal, so closing the panel
    // that way would leave the modal session running with no visible
    // window — every subsequent click then beeps. Observe the close and
    // end the modal session ourselves.
    id closeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowWillCloseNotification
                    object:panel
                     queue:nil
                usingBlock:^(NSNotification *note) { [NSApp stopModal]; }];

    [NSApp runModalForWindow:panel];
    [[NSNotificationCenter defaultCenter] removeObserver:closeObserver];
    [panel orderOut:nil];
}

// ── Install command line tool ─────────────────────────────────────────────────
// Quote a path for safe inclusion in a shell command run by AppleScript.
// AppleScript already wraps the script in double-quotes so the inner shell
// sees it as a normal POSIX command. We single-quote and escape any embedded
// single quotes (`'` → `'\''`) to handle paths with arbitrary characters
// including spaces, $, &, etc.
static NSString *_shellQuote(NSString *path) {
    NSString *escaped = [path stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    return [NSString stringWithFormat:@"'%@'", escaped];
}

// Build the bash wrapper script that gets installed as `nextpad++`. Routes
// through `open -a` (LaunchServices) so the existing app instance is reused
// and the terminal returns immediately — direct exec of the Mach-O binary
// would attach NSLog to the user's terminal and leave it stuck. Relative
// file paths are converted to absolute against the *terminal's* PWD before
// being passed to `open --args`, since `open` runs the launched app from
// `/` which would otherwise resolve `./file.txt` against the wrong cwd.
static NSString *_makeCLIScriptForApp(NSString *appPath) {
    return [NSString stringWithFormat:
        @"#!/bin/bash\n"
         "# nextpad++ — CLI wrapper for Nextpad++ macOS\n"
         "# Auto-generated by Nextpad++.app — re-run the\n"
         "# 'Install nextpad++ Command Line Tool…' menu item to update.\n"
         "APP=%@\n"
         "\n"
         "# Split arguments into option flags (-…) and file/folder paths.\n"
         "# Relative paths are made absolute against the terminal's PWD\n"
         "# because `open` launches the app from /.\n"
         "flags=()\n"
         "files=()\n"
         "for arg in \"$@\"; do\n"
         "    case \"$arg\" in\n"
         "        -*) flags+=(\"$arg\") ;;\n"
         "        /*) files+=(\"$arg\") ;;\n"
         "        *)  files+=(\"$PWD/$arg\") ;;\n"
         "    esac\n"
         "done\n"
         "\n"
         "if [ ${#flags[@]} -gt 0 ]; then\n"
         "    # Option flags can only reach a freshly launched process —\n"
         "    # `open --args` is silently dropped when the app is already\n"
         "    # running. Files ride behind --args so a fresh instance gets\n"
         "    # them too.\n"
         "    open -a \"$APP\" --args \"${flags[@]}\" \"${files[@]}\"\n"
         "elif [ ${#files[@]} -gt 0 ]; then\n"
         "    # Files only: pass them as `open` document arguments so an\n"
         "    # already-running instance opens them via application:openFiles:.\n"
         "    open -a \"$APP\" \"${files[@]}\"\n"
         "else\n"
         "    open -a \"$APP\"\n"
         "fi\n",
        _shellQuote(appPath)];
}

// Write `script` to `path` and chmod 0755. Removes any existing file/symlink
// first so this works as both an upgrade (over the old direct-binary symlink)
// and a fresh install.
static BOOL _writeCLIScript(NSString *script, NSString *path, NSError **outErr) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:path error:nil];
    if (![script writeToFile:path
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:outErr])
        return NO;
    return [fm setAttributes:@{NSFilePosixPermissions: @0755}
                ofItemAtPath:path
                       error:outErr];
}

// Creates /usr/local/bin/nextpad++ as a wrapper script that dispatches to the
// running app via `open -a`. Earlier versions installed a direct symlink to
// the Mach-O binary, which inherited the terminal's stdio (NSLog flooded the
// terminal, prompt didn't return, didn't reuse the running app instance).
// /usr/local/bin is on macOS's default PATH; falls back to ~/.local/bin if
// the user declines admin auth.
- (void)installCommandLineTool:(id)sender {
    NSString *appPath = [NSBundle mainBundle].bundlePath;
    if (!appPath.length) return;

    NSString *systemTarget = @"/usr/local/bin/nextpad++";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *script = _makeCLIScriptForApp(appPath);

    // Idempotency: existing file is byte-identical to what we'd write?
    // Comparing the whole script (not just the APP= line) means an
    // upgrade that changes the wrapper logic still reinstalls.
    NSString *existing = [NSString stringWithContentsOfFile:systemTarget
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    if (existing && [existing isEqualToString:script]) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = [[NppLocalizer shared] translate:@"Already installed"];
        a.informativeText = [NSString stringWithFormat:@"nextpad++ is already installed at %@\n\nUsage:\n  nextpad++ file.txt\n  nextpad++ -n42 main.cpp", systemTarget];
        [a runModal];
        return;
    }

    // Try /usr/local/bin without elevation (works if user owns the dir,
    // typically Homebrew Intel installs).
    NSError *err = nil;
    BOOL ok = _writeCLIScript(script, systemTarget, &err);

    if (!ok) {
        // Need admin. Offer two paths.
        NSAlert *prompt = [[NSAlert alloc] init];
        prompt.messageText = [[NppLocalizer shared] translate:@"Install nextpad++ Command Line Tool"];
        prompt.informativeText = [NSString stringWithFormat:
            @"Where would you like to install the 'nextpad++' command?\n\n"
             "• /usr/local/bin (in default PATH — requires administrator password)\n"
             "• ~/.local/bin (no password — you may need to add it to your PATH)"];
        [prompt addButtonWithTitle:@"/usr/local/bin"];
        [prompt addButtonWithTitle:@"~/.local/bin"];
        [prompt addButtonWithTitle:[[NppLocalizer shared] translate:@"Cancel"]];
        NSModalResponse resp = [prompt runModal];

        if (resp == NSAlertThirdButtonReturn) return; // Cancel

        if (resp == NSAlertFirstButtonReturn) {
            // Admin install: write the script to /tmp (no auth) and then
            // privilege-escalate just the move + chmod. Avoids embedding
            // multi-line script content inside a single AppleScript shell
            // command, which would need fragile heredoc/escape gymnastics.
            NSString *tmpPath = [NSString stringWithFormat:@"/tmp/nextpad++.cli.%d",
                                 (int)getpid()];
            NSError *werr = nil;
            if (![script writeToFile:tmpPath atomically:YES
                            encoding:NSUTF8StringEncoding error:&werr]) {
                NSAlert *a = [[NSAlert alloc] init];
                a.messageText = [[NppLocalizer shared] translate:@"Installation failed"];
                a.informativeText = werr.localizedDescription ?: @"Could not stage temp file.";
                [a runModal];
                return;
            }

            NSString *aplScript = [NSString stringWithFormat:
                @"do shell script \"mkdir -p /usr/local/bin && mv %@ %@ && chmod 755 %@\" with administrator privileges",
                _shellQuote(tmpPath), _shellQuote(systemTarget), _shellQuote(systemTarget)];
            NSDictionary *errInfo = nil;
            [[[NSAppleScript alloc] initWithSource:aplScript] executeAndReturnError:&errInfo];
            [fm removeItemAtPath:tmpPath error:nil]; // cleanup if mv didn't run

            NSAlert *a = [[NSAlert alloc] init];
            if (errInfo) {
                a.messageText = [[NppLocalizer shared] translate:@"Installation failed"];
                a.informativeText = errInfo[NSAppleScriptErrorMessage] ?: @"Unknown error.";
            } else {
                a.messageText = [[NppLocalizer shared] translate:@"Installed"];
                a.informativeText = [NSString stringWithFormat:@"nextpad++ command installed at %@\n\nUsage:\n  nextpad++ file.txt\n  nextpad++ -n42 main.cpp", systemTarget];
            }
            [a runModal];
            return;
        }

        // resp == NSAlertSecondButtonReturn — fallback to ~/.local/bin
        NSString *userBinDir = [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin"];
        [fm createDirectoryAtPath:userBinDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *userTarget = [userBinDir stringByAppendingPathComponent:@"nextpad++"];
        err = nil;
        ok = _writeCLIScript(script, userTarget, &err);

        if (!ok) {
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = [[NppLocalizer shared] translate:@"Installation failed"];
            a.informativeText = err.localizedDescription ?: @"Unknown error.";
            [a runModal];
            return;
        }

        // Symlink succeeded. Decide PATH-status messaging.
        NSString *pathEnv = NSProcessInfo.processInfo.environment[@"PATH"] ?: @"";
        BOOL onPath = [[pathEnv componentsSeparatedByString:@":"] containsObject:userBinDir];

        if (onPath) {
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = [[NppLocalizer shared] translate:@"Installed"];
            a.informativeText = [NSString stringWithFormat:@"nextpad++ command installed at %@\n\nUsage:\n  nextpad++ file.txt\n  nextpad++ -n42 main.cpp", userTarget];
            [a runModal];
            return;
        }

        // Not on PATH — make this prominent and offer one-click fixes.
        // Detect the user's shell from $SHELL and pick the right rc file.
        NSString *shellPath = NSProcessInfo.processInfo.environment[@"SHELL"] ?: @"/bin/zsh";
        NSString *shellName = shellPath.lastPathComponent;
        NSString *configPath, *exportLine;
        if ([shellName isEqualToString:@"bash"]) {
            configPath = [NSHomeDirectory() stringByAppendingPathComponent:@".bash_profile"];
            exportLine = @"export PATH=\"$HOME/.local/bin:$PATH\"";
        } else if ([shellName isEqualToString:@"fish"]) {
            configPath = [NSHomeDirectory() stringByAppendingPathComponent:@".config/fish/config.fish"];
            exportLine = @"fish_add_path -U $HOME/.local/bin";
        } else {
            // zsh is macOS default since Catalina; everything else falls back here
            configPath = [NSHomeDirectory() stringByAppendingPathComponent:@".zshrc"];
            exportLine = @"export PATH=\"$HOME/.local/bin:$PATH\"";
        }
        NSString *configDisplay = [configPath stringByReplacingOccurrencesOfString:NSHomeDirectory() withString:@"~"];

        NSAlert *a = [[NSAlert alloc] init];
        a.alertStyle = NSAlertStyleWarning;
        a.messageText = [[NppLocalizer shared] translate:
            @"Installed — but ~/.local/bin is not on your PATH"];
        a.informativeText = [NSString stringWithFormat:
            @"nextpad++ is installed at %@, but typing 'nextpad++' in a "
             "terminal will give 'command not found' until ~/.local/bin is "
             "on your $PATH.\n\n"
             "Add this line to %@:\n\n"
             "    %@\n\n"
             "Then open a new Terminal window. The buttons below can do "
             "this for you.",
            userTarget, configDisplay, exportLine];
        [a addButtonWithTitle:[NSString stringWithFormat:@"Add to %@", configDisplay.lastPathComponent]];
        [a addButtonWithTitle:@"Copy command"];
        [a addButtonWithTitle:@"OK"];
        NSModalResponse pathResp = [a runModal];

        if (pathResp == NSAlertFirstButtonReturn) {
            // Append the export line to the shell config file (idempotent).
            NSString *current = [NSString stringWithContentsOfFile:configPath
                                                          encoding:NSUTF8StringEncoding
                                                             error:nil] ?: @"";
            NSAlert *follow = [[NSAlert alloc] init];
            if ([current rangeOfString:exportLine].location != NSNotFound) {
                follow.messageText = [[NppLocalizer shared] translate:@"Already in your config"];
                follow.informativeText = [NSString stringWithFormat:
                    @"%@ already contains the export line. Open a new "
                     "Terminal window for it to take effect.", configDisplay];
            } else {
                NSString *prefix = current.length && ![current hasSuffix:@"\n"] ? @"\n" : @"";
                NSString *appended = [current stringByAppendingFormat:
                    @"%@\n# Added by Nextpad++ — nextpad++ CLI\n%@\n",
                    prefix, exportLine];
                NSError *werr = nil;
                BOOL wrote = [appended writeToFile:configPath
                                        atomically:YES
                                          encoding:NSUTF8StringEncoding
                                             error:&werr];
                if (wrote) {
                    follow.messageText = [[NppLocalizer shared] translate:@"Added to PATH"];
                    follow.informativeText = [NSString stringWithFormat:
                        @"Added the export line to %@. Open a new Terminal "
                         "window for it to take effect — then 'nextpad++' "
                         "will work.", configDisplay];
                } else {
                    follow.alertStyle = NSAlertStyleCritical;
                    follow.messageText = [[NppLocalizer shared] translate:@"Could not write"];
                    follow.informativeText = werr.localizedDescription ?: @"Unknown error.";
                }
            }
            [follow runModal];
        } else if (pathResp == NSAlertSecondButtonReturn) {
            // Copy the export line to the clipboard.
            NSPasteboard *pb = [NSPasteboard generalPasteboard];
            [pb clearContents];
            [pb setString:exportLine forType:NSPasteboardTypeString];
            NSAlert *follow = [[NSAlert alloc] init];
            follow.messageText = [[NppLocalizer shared] translate:@"Copied"];
            follow.informativeText = [NSString stringWithFormat:
                @"Paste this into %@ (or your shell config) and open a "
                 "new Terminal window.", configDisplay];
            [follow runModal];
        }
        return;
    }

    // Plain (non-elevated) install succeeded — user owns /usr/local/bin.
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [[NppLocalizer shared] translate:@"Installed"];
    a.informativeText = [NSString stringWithFormat:@"nextpad++ command installed at %@\n\nUsage:\n  nextpad++ file.txt\n  nextpad++ -n42 main.cpp", systemTarget];
    [a runModal];
}

// ── Dark mode ────────────────────────────────────────────────────────────────

// Issue #183: show/hide the primary tab bar and reclaim its space. Swaps the
// height constraint (min-height <-> zero-height) so the editor fills the strip
// when hidden, and toggles .hidden so it stops drawing. Primary tab bar only —
// the secondary split tab bars are out of scope (they appear only in split mode).
// #183: collapse or restore ONE tab bar — swap its height constraint (min <-> zero)
// and toggle .hidden so the editor reclaims the strip; under the glass profile,
// round the now-exposed top-left corner of its editor card (top-right-only when
// shown). Guards on nil constraints so it's safe before that bar is built.
- (void)_setTabBarHidden:(BOOL)hide
                  tabBar:(NppTabBar *)tabBar
               minHeight:(NSLayoutConstraint *)minC
              zeroHeight:(NSLayoutConstraint *)zeroC
             contentView:(NSView *)contentView {
    if (!minC || !zeroC) return;
    if (hide) { minC.active = NO; zeroC.active = YES; }   // deactivate conflicting one first
    else      { zeroC.active = NO; minC.active = YES; }
    tabBar.hidden = hide;
    if ([NppThemeManager shared].usesGlassMaterials) {
        CALayer *cl = contentView.layer;
        if (cl)
            cl.maskedCorners = hide
                ? (kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner)   // top-left + top-right
                : kCALayerMaxXMaxYCorner;                            // top-right only
    }
    [tabBar.superview layoutSubtreeIfNeeded];
}

// #183: apply the "Hide tab bar" state to the primary AND both secondary (split)
// tab bars, so a hidden bar stays hidden in split view too.
- (void)_applyTabBarVisibility:(BOOL)hide {
    [self _setTabBarHidden:hide tabBar:_tabManager.tabBar
                 minHeight:_primaryTabBarMinHeight zeroHeight:_primaryTabBarZeroHeight
               contentView:_tabManager.contentView];
    [self _setTabBarHidden:hide tabBar:_subTabManagerH.tabBar
                 minHeight:_subTabBarHMinHeight zeroHeight:_subTabBarHZeroHeight
               contentView:_subTabManagerH.contentView];
    [self _setTabBarHidden:hide tabBar:_subTabManagerV.tabBar
                 minHeight:_subTabBarVMinHeight zeroHeight:_subTabBarVZeroHeight
               contentView:_subTabManagerV.contentView];
}

- (void)_prefsChanged:(NSNotification *)n {
    // Status bar visibility
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL showStatus = [ud boolForKey:kPrefShowStatusBar];
    _statusBar.hidden = !showStatus;

    BOOL wrapTabs = [ud boolForKey:kPrefTabBarWrap];
    _tabManager.tabBar.wrapMode     = wrapTabs;
    _subTabManagerH.tabBar.wrapMode = wrapTabs;
    _subTabManagerV.tabBar.wrapMode = wrapTabs;

    for (NppTabBar *bar in @[_tabManager.tabBar, _subTabManagerH.tabBar, _subTabManagerV.tabBar])
        [bar relayout];

    // Issue #183: apply the "Hide tab bar" pref live.
    [self _applyTabBarVisibility:[ud boolForKey:kPrefHideTabBar]];

    // Title bar (full path vs filename only)
    [self updateTitle];

    // Toolbar toggle states (Word wrap, etc.) follow prefs — keep them
    // in sync after a Preferences-pane change.
    [self _refreshToolbarStates];
}

- (void)_darkModeChanged:(NSNotification *)n {
    // Re-assign CGColor on status bar (snapshot needs refresh). Skipped under the
    // Tahoe profile, where the status bar is backed by a translucent
    // NSVisualEffectView and the layer color is intentionally left clear.
    if (![NppThemeManager shared].usesGlassMaterials)
        _statusBar.layer.backgroundColor = [NppThemeManager shared].statusBarBackground.CGColor;

    // Auto mode: switch editor theme to match system appearance
    if ([NppThemeManager shared].mode == NppDarkModeAuto) {
        BOOL isDark = [NppThemeManager shared].isDark;
        NSString *targetTheme = isDark ? @"DarkModeDefault" : @"Default (stylers.xml)";
        NPPStyleStore *store = [NPPStyleStore sharedStore];
        if (![store.activeThemeName isEqualToString:targetTheme]) {
            NSArray *lexers = [store lexersForTheme:targetTheme];
            [store commitLexers:lexers themeName:targetTheme];
        }
    }

    // Re-skin the toolbar (light/dark icon set + colorization).
    [self _reskinToolbarIcons];
}

// Reloads every toolbar button's image via nppToolbarIcon() (which applies the
// current light/dark icon set AND the colorization prefs), the three inline
// view-toggle buttons, and the plugin icons. Shared by the dark-mode switch and
// the toolbar-colorization preference change so both re-skin identically.
- (void)_reskinToolbarIcons {
    NSToolbar *toolbar = self.window.toolbar;
    for (NSToolbarItem *item in toolbar.items) {
        NSView *groupView = item.view;
        if (!groupView) continue;
        for (NSView *sub in groupView.subviews) {
            if ([sub isKindOfClass:[NSButton class]]) {
                NSButton *btn = (NSButton *)sub;
                if (btn.identifier.length) {
                    NSImage *newImg = nppToolbarIcon(btn.identifier);
                    if (newImg) btn.image = newImg;
                }
            }
        }
    }

    // The view-toggles group (Word Wrap, Show All Characters, Indent Guide)
    // is built inline without setting NSButton.identifier, and Show All
    // Characters is additionally nested inside _AllCharsHoverGroup — neither
    // condition the identifier-driven loop above can satisfy. Refresh those
    // three buttons explicitly via the cached ivars.
    if (_tbWrap)        _tbWrap.image        = nppToolbarIcon(@"wrap");
    if (_tbAllChars)    _tbAllChars.image    = nppToolbarIcon(@"allChars");
    if (_tbIndentGuide) _tbIndentGuide.image = nppToolbarIcon(@"indentGuide");

    // Plugin-supplied toolbar icons (Path A: `toolbar_dark.png` convention
    // alongside `toolbar.png`, or `<hint>_dark.<ext>` next to `<hint>`).
    [self _refreshPluginToolbarIcons];
}

- (void)_toolbarColorChanged:(NSNotification *)n {
    [self _reskinToolbarIcons];
}

// The Tahoe toolbar group layout was edited in Preferences ▸ Toolbar. Reload the
// model from the file and rebuild the toolbar (Tahoe profile only — Classic is
// unaffected, its toolbar is a separate construction).
- (void)_tahoeToolbarConfigChanged:(NSNotification *)n {
    if (![self _toolbarUsesTahoe]) return;
    [self _loadTahoeToolbarModel];   // pick up the editor's saved file
    [self buildToolbar];             // rebuild capsules from the new model
}

// checkForUpdates: moved to AppDelegate
// showUpdaterProxyStub: removed

- (void)showMacroManager:(id)sender {
    // Build a list of saved macros and allow deletion.
    NSArray<NSDictionary *> *macroList = loadMacrosFromShortcutsXML();
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *m in macroList) [names addObject:m[@"name"]];
    if (!names.count) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = [[NppLocalizer shared] translate:@"No Saved Macros"];
        a.informativeText = [[NppLocalizer shared] translate:@"Record and save a macro first."];
        [a runModal];
        return;
    }

    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,320,240)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    panel.title = [[NppLocalizer shared] translate:@"Macro Manager"];
    [panel center];
    NSView *cv = panel.contentView;

    NSTableView *tv = [[NSTableView alloc] init];
    tv.allowsMultipleSelection = NO;
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    col.title = [[NppLocalizer shared] translate:@"Macro Name"]; col.resizingMask = NSTableColumnAutoresizingMask;
    [tv addTableColumn:col];
    NSScrollView *sv = [[NSScrollView alloc] init];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.hasVerticalScroller = YES;
    sv.documentView = tv;
    [cv addSubview:sv];

    NSButton *delBtn  = [NSButton buttonWithTitle:[[NppLocalizer shared] translate:@"Delete"] target:nil action:nil];
    delBtn.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *doneBtn = [NSButton buttonWithTitle:[[NppLocalizer shared] translate:@"Done"] target:nil action:nil];
    doneBtn.translatesAutoresizingMaskIntoConstraints = NO;
    doneBtn.keyEquivalent = @"\r";
    [cv addSubview:delBtn]; [cv addSubview:doneBtn];
    [NSLayoutConstraint activateConstraints:@[
        [sv.topAnchor constraintEqualToAnchor:cv.topAnchor constant:8],
        [sv.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:8],
        [sv.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-8],
        [sv.bottomAnchor constraintEqualToAnchor:delBtn.topAnchor constant:-8],
        [doneBtn.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-8],
        [doneBtn.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor constant:-12],
        [delBtn.trailingAnchor constraintEqualToAnchor:doneBtn.leadingAnchor constant:-8],
        [delBtn.bottomAnchor constraintEqualToAnchor:doneBtn.bottomAnchor],
    ]];

    // Simple datasource
    NSMutableArray<NSString *> *mutableNames = [names mutableCopy];
    _NPPWindowsListHelper *helper = [[_NPPWindowsListHelper alloc] initWithRows:nil];
    __block NSMutableArray<NSString *> *macroNames = [names mutableCopy];
    __block NSMutableArray<NSDictionary *> *mutableMacroList = [macroList mutableCopy];

    helper.activateHandler = ^{
        NSInteger row = tv.selectedRow;
        if (row < 0 || row >= (NSInteger)macroNames.count) return;
        NSString *nameToDelete = macroNames[row];
        [macroNames removeObjectAtIndex:row];
        [mutableMacroList removeObjectAtIndex:row];
        removeMacroFromShortcutsXML(nameToDelete);
        [tv reloadData];
    };

    // Reuse _NPPWindowsListHelper for simple string list
    tv.dataSource = (id<NSTableViewDataSource>)[NSObject new]; // placeholder
    tv.delegate   = (id<NSTableViewDelegate>)[NSObject new];

    // Use a block-based datasource
    _NPPWindowsListHelper *ds = [[_NPPWindowsListHelper alloc] initWithRows:nil];
    ds.rows = nil;
    objc_setAssociatedObject(panel, "ds",     ds,     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(panel, "names",  macroNames, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(panel, "macros", mutableMacroList, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak NSPanel *wPanel = panel;
    __weak typeof(self) wSelf = self;
    // Strong locals keep the NSBlockOperations alive through the modal run
    // loop (NSControl.target is zeroing-weak under ARC).
    NSBlockOperation *delOp = [NSBlockOperation blockOperationWithBlock:^{
        NSInteger row = tv.selectedRow;
        if (row < 0 || row >= (NSInteger)macroNames.count) return;
        NSString *nameToDelete = macroNames[row];
        [macroNames removeObjectAtIndex:row];
        [mutableMacroList removeObjectAtIndex:row];
        removeMacroFromShortcutsXML(nameToDelete);
        [tv reloadData];
        [wSelf rebuildMacroMenu];
    }];
    delBtn.target = delOp;
    delBtn.action = @selector(main);
    NSBlockOperation *doneOp = [NSBlockOperation blockOperationWithBlock:^{
        [NSApp stopModal]; [wPanel orderOut:nil];
    }];
    doneBtn.target = doneOp;
    doneBtn.action = @selector(main);

    // Minimal tableview without subclassing — use raw datasource object
    // Since we can't easily set a block datasource, use a simple NSArray datasource
    // backed by the _NPPWindowsListHelper but with string rows
    NSMutableArray<NSDictionary *> *rowDicts = [NSMutableArray array];
    for (NSString *n in macroNames) [rowDicts addObject:@{@"name":n, @"path":@"", @"modified":@NO, @"mgr":@0, @"idx":@0}];
    _NPPWindowsListHelper *realDS = [[_NPPWindowsListHelper alloc] initWithRows:rowDicts];
    realDS.tableView = tv;
    tv.dataSource = realDS;
    tv.delegate = realDS;
    objc_setAssociatedObject(panel, "realDS", realDS, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [tv reloadData];

    // the x button doesn't end the modal on its own, so we do it ourselves
    id closeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowWillCloseNotification
                    object:panel
                     queue:nil
                usingBlock:^(NSNotification *note) { [NSApp stopModal]; }];

    [NSApp runModalForWindow:panel];
    [[NSNotificationCenter defaultCenter] removeObserver:closeObserver];
}

#pragma mark - Help / Debug

- (void)openNppHome:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://nextpad.org"]];
}
- (void)openNppProjectPage:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/nextpad-plus-plus"]];
}
- (void)openNppManual:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://npp-user-manual.org"]];
}
- (void)openNppForum:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://community.notepad-plus-plus.org"]];
}

/// Helper: query sysctl string value
static NSString *_sysctlString(const char *name) {
    char buf[256] = {}; size_t sz = sizeof(buf);
    if (sysctlbyname(name, buf, &sz, NULL, 0) == 0) return [NSString stringWithUTF8String:buf];
    return @"unknown";
}
/// Helper: query sysctl integer value
static int64_t _sysctlInt(const char *name) {
    int64_t val = 0; size_t sz = sizeof(val);
    sysctlbyname(name, &val, &sz, NULL, 0);
    return val;
}

/// Build the debug info string (also used by Copy button).
- (NSString *)_buildDebugInfoString {
    NSMutableString *info = [NSMutableString string];
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0.0";
    NSString *buildNum = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"1";

#if defined(__arm64__)
    NSString *archStr = @"ARM 64-bit";
#elif defined(__x86_64__)
    NSString *archStr = @"64-bit";
#else
    NSString *archStr = @"unknown";
#endif

    // ── App Info ─────────────────────────────────────────────────────────
    [info appendFormat:@"Nextpad++ macOS v%@ (build %@)   (%@)\n", version, buildNum, archStr];
    [info appendFormat:@"Build time: %s - %s\n", __DATE__, __TIME__];
    [info appendFormat:@"Built with: Apple Clang %d.%d.%d\n",
        __clang_major__, __clang_minor__, __clang_patchlevel__];
    [info appendFormat:@"C++ Standard: %ld\n", (long)__cplusplus];
    [info appendFormat:@"macOS Deployment Target: %s\n",
        [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"LSMinimumSystemVersion"] UTF8String] ?: "11.0"];
    [info appendString:@"Scintilla/Lexilla included: 5.6.0/5.4.7\n"];
    [info appendFormat:@"Bundle ID: %@\n", [[NSBundle mainBundle] bundleIdentifier] ?: @"n/a"];
    [info appendFormat:@"Path: %@\n", [[NSBundle mainBundle] executablePath]];
    [info appendFormat:@"Bundle Path: %@\n", [[NSBundle mainBundle] bundlePath]];
    [info appendFormat:@"Config Dir: %@\n", nppConfigDir()];

    // ── Runtime ──────────────────────────────────────────────────────────
    int translated = 0; size_t tsz = sizeof(translated);
    BOOL rosetta = (sysctlbyname("sysctl.proc_translated", &translated, &tsz, NULL, 0) == 0 && translated == 1);
    if (rosetta) [info appendString:@"Running under: Rosetta 2\n"];

    [info appendFormat:@"Process ID: %d\n", getpid()];
    [info appendFormat:@"Admin mode: %@\n", (geteuid() == 0) ? @"ON" : @"OFF"];
    [info appendFormat:@"Sandbox: %@\n",
        [[NSProcessInfo processInfo].environment objectForKey:@"APP_SANDBOX_CONTAINER_ID"] ? @"ON" : @"OFF"];

    // ── User Settings ────────────────────────────────────────────────────
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [info appendString:@"\n── Settings ──\n"];
    [info appendFormat:@"Periodic Backup: %@\n", [ud boolForKey:@"kPrefAutoBackup"] ? @"ON" : @"OFF"];
    [info appendFormat:@"Auto-Indent: %@\n", [ud boolForKey:@"kPrefAutoIndent"] ? @"ON" : @"OFF"];
    [info appendFormat:@"Show Line Numbers: %@\n", [ud boolForKey:@"kPrefShowLineNumbers"] ? @"ON" : @"OFF"];
    [info appendFormat:@"Tab Width: %ld\n", (long)[ud integerForKey:@"kPrefTabWidth"]];
    [info appendFormat:@"Use Tabs: %@\n", [ud boolForKey:@"kPrefUseTabs"] ? @"ON" : @"OFF"];
    [info appendFormat:@"Highlight Current Line: %@\n", [ud boolForKey:@"kPrefHighlightCurrentLine"] ? @"ON" : @"OFF"];
    [info appendFormat:@"Zoom Level: %ld\n", (long)[ud integerForKey:@"kPrefZoomLevel"]];
    [info appendFormat:@"EOL Type: %@\n", [ud stringForKey:@"kPrefEOLType"] ?: @"default"];
    [info appendFormat:@"Encoding: %@\n", [ud stringForKey:@"kPrefEncoding"] ?: @"UTF-8"];
    [info appendFormat:@"Theme Preset: %@\n", [ud stringForKey:@"kPrefThemePreset"] ?: @"default"];
    [info appendFormat:@"Auto-Complete Enabled: %@\n", [ud boolForKey:@"kPrefAutoCompleteEnable"] ? @"ON" : @"OFF"];
    [info appendFormat:@"Auto-Complete Min Chars: %ld\n", (long)[ud integerForKey:@"kPrefAutoCompleteMinChars"]];

    // Session info
    NSString *sessionPath = NppConfigSubpath(@"session.plist");
    BOOL hasSession = [[NSFileManager defaultManager] fileExistsAtPath:sessionPath];
    [info appendFormat:@"Session file: %@\n", hasSession ? @"exists" : @"none"];
    if (hasSession) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:sessionPath error:nil];
        NSDate *modDate = attrs[NSFileModificationDate];
        if (modDate) [info appendFormat:@"Session last saved: %@\n", modDate];
    }

    // ── Appearance ───────────────────────────────────────────────────────
    [info appendString:@"\n── Appearance ──\n"];
    BOOL darkMode = NO;
    if (@available(macOS 10.14, *)) {
        NSAppearanceName name = [NSApp.effectiveAppearance
            bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        darkMode = [name isEqualToString:NSAppearanceNameDarkAqua];
    }
    [info appendFormat:@"Dark Mode: %@\n", darkMode ? @"ON" : @"OFF"];
    [info appendFormat:@"Appearance: %@\n", NSApp.effectiveAppearance.name];

    // ── Display Info ─────────────────────────────────────────────────────
    [info appendString:@"\n── Display Info ──\n"];
    [info appendFormat:@"Visible monitors count: %ld\n", (long)[NSScreen screens].count];
    for (NSUInteger i = 0; i < [NSScreen screens].count; i++) {
        NSScreen *scr = [NSScreen screens][i];
        CGFloat s = scr.backingScaleFactor;
        NSRect f = scr.frame;
        NSRect v = scr.visibleFrame;
        [info appendFormat:@"    monitor %lu%@:\n", (unsigned long)i,
            (scr == [NSScreen mainScreen]) ? @" (primary)" : @""];
        [info appendFormat:@"        resolution: %.0fx%.0f (%.0fx%.0f logical)\n",
            f.size.width * s, f.size.height * s, f.size.width, f.size.height];
        [info appendFormat:@"        scaling: %.0f%% (%.1fx)\n", s * 100, s];
        [info appendFormat:@"        visible area: %.0fx%.0f at (%.0f, %.0f)\n",
            v.size.width, v.size.height, v.origin.x, v.origin.y];
        [info appendFormat:@"        color space: %@\n", scr.colorSpace.localizedName ?: @"unknown"];
    }

    // ── Window Info ──────────────────────────────────────────────────────
    [info appendString:@"\n── Window Info ──\n"];
    NSWindow *w = self.window;
    NSRect wf = w.frame;
    [info appendFormat:@"Window frame: %.0f x %.0f at (%.0f, %.0f)\n",
        wf.size.width, wf.size.height, wf.origin.x, wf.origin.y];
    [info appendFormat:@"Window level: %ld%@\n", (long)w.level,
        w.level == NSFloatingWindowLevel ? @" (always on top)" : @""];
    [info appendFormat:@"Toolbar visible: %@\n", w.toolbar.isVisible ? @"YES" : @"NO"];
    [info appendFormat:@"Tab bar visible: %@\n", _tabManager.tabBar.isHidden ? @"NO" : @"YES"];
    [info appendFormat:@"Open tabs: %ld\n", (long)_tabManager.allEditors.count];

    // Current editor info
    EditorView *ed = [self currentEditor];
    if (ed) {
        [info appendString:@"\n── Current Editor ──\n"];
        [info appendFormat:@"File: %@\n", ed.filePath ?: @"(untitled)"];
        [info appendFormat:@"Language: %@\n", ed.currentLanguage.length ? ed.currentLanguage : @"Plain Text"];
        [info appendFormat:@"Encoding: %@\n", ed.encodingName];
        [info appendFormat:@"EOL: %@\n", ed.eolName];
        [info appendFormat:@"Modified: %@\n", ed.isModified ? @"YES" : @"NO"];
        [info appendFormat:@"Read-Only: %@\n",
            [ed.scintillaView message:SCI_GETREADONLY] ? @"YES" : @"NO"];
        [info appendFormat:@"Word Wrap: %@\n", ed.wordWrapEnabled ? @"ON" : @"OFF"];
        [info appendFormat:@"Monitoring: %@\n", ed.monitoringMode ? @"ON" : @"OFF"];
        sptr_t docLen = [ed.scintillaView message:SCI_GETLENGTH];
        [info appendFormat:@"Document length: %ld bytes\n", (long)docLen];
        [info appendFormat:@"Line count: %ld\n", (long)ed.lineCount];
        [info appendFormat:@"Cursor: Ln %ld, Col %ld\n", (long)ed.cursorLine, (long)ed.cursorColumn];
        [info appendFormat:@"Zoom: %ld\n", (long)[ed.scintillaView message:SCI_GETZOOM]];
        sptr_t lexer = [ed.scintillaView message:SCI_GETLEXER];
        [info appendFormat:@"Scintilla Lexer ID: %ld\n", (long)lexer];
        [info appendFormat:@"Undo actions: %@\n",
            [ed.scintillaView message:SCI_CANUNDO] ? @"available" : @"none"];
    }

    // ── OS & Hardware ────────────────────────────────────────────────────
    [info appendString:@"\n── OS & Hardware ──\n"];
    NSOperatingSystemVersion osVer = [[NSProcessInfo processInfo] operatingSystemVersion];
    [info appendFormat:@"OS: macOS %ld.%ld.%ld\n",
        (long)osVer.majorVersion, (long)osVer.minorVersion, (long)osVer.patchVersion];
    [info appendFormat:@"OS Build: %@\n", [[NSProcessInfo processInfo] operatingSystemVersionString]];
    [info appendFormat:@"Kernel: %@\n", _sysctlString("kern.osrelease")];
    [info appendFormat:@"Hardware Model: %@\n", _sysctlString("hw.model")];
    [info appendFormat:@"CPU Brand: %@\n", _sysctlString("machdep.cpu.brand_string")];
    [info appendFormat:@"CPU Cores: %lld (physical), %lld (logical)\n",
        _sysctlInt("hw.physicalcpu"), _sysctlInt("hw.logicalcpu")];
    [info appendFormat:@"Memory: %.1f GB\n", _sysctlInt("hw.memsize") / (1024.0 * 1024.0 * 1024.0)];
    [info appendFormat:@"Page Size: %lld bytes\n", _sysctlInt("hw.pagesize")];

    // Process memory usage
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
        [info appendFormat:@"Process Max RSS: %.1f MB\n", usage.ru_maxrss / (1024.0 * 1024.0)];
    }

    // ── Locale & Encoding ────────────────────────────────────────────────
    [info appendString:@"\n── Locale & Encoding ──\n"];
    [info appendFormat:@"Locale: %@\n", [[NSLocale currentLocale] localeIdentifier]];
    [info appendFormat:@"Language: %@\n", [[NSLocale preferredLanguages] firstObject] ?: @"unknown"];
    [info appendFormat:@"System Encoding: %@ (%lu)\n",
        [NSString localizedNameOfStringEncoding:NSUTF8StringEncoding],
        (unsigned long)NSUTF8StringEncoding];

    // ── Plugins ──────────────────────────────────────────────────────────
    [info appendString:@"\n── Plugins ──\n"];
    NSString *pluginDir = NppConfigSubpath(@"plugins");
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *pluginDirs = [fm contentsOfDirectoryAtPath:pluginDir error:nil];
    NSInteger pluginCount = 0;
    if (pluginDirs.count > 0) {
        for (NSString *dirName in [pluginDirs sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
            if ([dirName isEqualToString:@"Config"] || [dirName hasPrefix:@"."]) continue;
            NSString *dylibPath = [NSString stringWithFormat:@"%@/%@/%@.dylib", pluginDir, dirName, dirName];
            BOOL exists = [fm fileExistsAtPath:dylibPath];
            if (exists) {
                NSDictionary *attrs = [fm attributesOfItemAtPath:dylibPath error:nil];
                NSNumber *fileSize = attrs[NSFileSize];
                NSDate *modDate = attrs[NSFileModificationDate];
                NSDateFormatter *df = [[NSDateFormatter alloc] init];
                df.dateFormat = @"yyyy-MM-dd HH:mm";
                [info appendFormat:@"    %@ (%@ KB, %@)\n", dirName,
                    @(fileSize.longLongValue / 1024),
                    modDate ? [df stringFromDate:modDate] : @"?"];
                pluginCount++;
            }
        }
    }
    if (pluginCount == 0) {
        [info appendString:@"    (none installed)\n"];
    }
    [info appendFormat:@"Total: %ld plugin(s)\n", (long)pluginCount];

    // ── Config Files ─────────────────────────────────────────────────────
    [info appendString:@"\n── Config Files ──\n"];
    NSString *nppDir = nppConfigDir();
    NSArray *configFiles = @[@"session.plist", @"macros.plist", @"plugins/Config/URLPlugin.json"];
    for (NSString *relPath in configFiles) {
        NSString *fullPath = [nppDir stringByAppendingPathComponent:relPath];
        BOOL exists = [fm fileExistsAtPath:fullPath];
        if (exists) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            [info appendFormat:@"    %@: %@ bytes\n", relPath, attrs[NSFileSize]];
        } else {
            [info appendFormat:@"    %@: (not found)\n", relPath];
        }
    }

    // Backup files
    NSString *backupDir = [nppDir stringByAppendingPathComponent:@"backup"];
    NSArray *backups = [fm contentsOfDirectoryAtPath:backupDir error:nil];
    [info appendFormat:@"    backup/ files: %ld\n", (long)(backups ? backups.count : 0)];

    // UDL files
    NSString *udlDir = [nppDir stringByAppendingPathComponent:@"userDefineLangs"];
    NSArray *udls = [fm contentsOfDirectoryAtPath:udlDir error:nil];
    [info appendFormat:@"    userDefineLangs/ files: %ld\n", (long)(udls ? udls.count : 0)];

    return info;
}

- (void)showDebugInfo:(id)sender {
    NSString *info = [self _buildDebugInfoString];

    // Use NSAlert instead of NSPanel — no modal locking issues
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [[NppLocalizer shared] translate:@"Debug Info"];
    a.icon = [[NSImage alloc] initWithContentsOfFile:
        NppConfigSubpath(@"plugins/Config/logo100px.png")];
    [a addButtonWithTitle:[[NppLocalizer shared] translate:@"Copy"]];
    [a addButtonWithTitle:[[NppLocalizer shared] translate:@"OK"]];

    // Scrollable text view as accessory
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 480, 320)];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 460, 320)];
    tv.editable = NO;
    tv.font = [NSFont fontWithName:@"Menlo" size:11];
    tv.string = info;
    scroll.documentView = tv;
    a.accessoryView = scroll;

    NSModalResponse resp = [a runModal];
    if (resp == NSAlertFirstButtonReturn) {
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:info forType:NSPasteboardTypeString];
    }
}

#pragma mark - NSWindowDelegate

- (void)windowWillClose:(NSNotification *)n {
    // The session save already ran in -windowShouldClose:, while this window was
    // still live. From here on the receiver must not contribute tabs to a later
    // save — its documents are closed.
    _windowHasClosed = YES;
    [_autoSaveTimer invalidate];
    _autoSaveTimer = nil;
    // The scroll-sync timer also targets self with repeats:YES; if a split with
    // sync scrolling is active it would otherwise retain this controller forever
    // (run-loop keeps the timer alive) and keep polling the closed window's
    // editors. Mirror the _autoSaveTimer teardown above.
    [_scrollSyncTimer invalidate];
    _scrollSyncTimer = nil;
    [self saveWindowFrame];
    // Note: session already saved in windowShouldClose:

    // Close all auxiliary windows so the app can terminate cleanly.
    // Without this, standalone windows (Plugins Admin, Find, Style Configurator, etc.)
    // keep the app alive after the main window closes.
    [[FindWindow sharedWindow].window orderOut:nil];
    [[PluginsAdminWindowController sharedController].window orderOut:nil];
    [[StyleConfiguratorWindowController sharedController].window orderOut:nil];
    // FindInFilesPanel removed
    [[UserDefineDialog sharedController].window orderOut:nil];
    [[PreferencesWindowController sharedController].window orderOut:nil];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    // Windows NPP behaviour: no save prompts on quit.
    // Back up all modified editors to ~/Library/Application Support/Nextpad++/backup/ and save session.
    // On next launch, modified files reload from backup and show as unsaved.
    //
    // Issue #87 — gate the session save on the new "Remember current session
    // for next launch" pref AND on -nosession CLI flag (matches Windows NPP
    // behaviour: both pref-off and -nosession suppress the per-launch save so
    // a stale session.plist isn't left behind to surprise the user later).
    // Auto-backup of unsaved files runs separately on its own timer and is
    // intentionally NOT coupled — losing unsaved work to a crash is a separate
    // concern from reopening tabs across launches.
    //
    // On quit, AppDelegate has already written one session covering every
    // window (see -applicationShouldTerminate:). Saving again here would be
    // actively harmful: by the time the second window is torn down the first is
    // gone from windowControllers, so this save would write a session missing
    // its tabs and prune away its backups.
    AppDelegate *appDel = (AppDelegate *)NSApp.delegate;
    BOOL terminating = [appDel isKindOfClass:[AppDelegate class]] ? appDel.isTerminating : NO;
    if (!terminating && [self sessionPersistenceEnabled]) {
        [self saveSessionForAllWindows];
    }
    writeConfigXML();
    return YES;
}

- (BOOL)sessionPersistenceEnabled {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (![ud boolForKey:kPrefRememberSession]) return NO;
    AppDelegate *appDel = (AppDelegate *)NSApp.delegate;
    if ([appDel isKindOfClass:[AppDelegate class]] && appDel.cliParams.noSession) return NO;
    return YES;
}

#pragma mark - Helpers

- (void)updateTitle {
    EditorView *ed = [self currentEditor];
    NSString *name;
    if (!ed) {
        name = @"Nextpad++";
    } else if ([[NSUserDefaults standardUserDefaults] boolForKey:kPrefShowFullPathInTitle] && ed.filePath) {
        name = ed.filePath;
    } else {
        name = ed.displayName;
    }
    self.window.title = ed.isModified ? [name stringByAppendingString:@" •"] : name;
}

/// Language display name mapping matching Windows NPP _langNameInfoArray._longName
static NSString *languageDisplayName(NSString *langCode) {
    if (!langCode.length) return @"Normal text file";
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"c"            : @"C source file",
            @"cpp"          : @"C++ source file",
            @"cs"           : @"C# source file",
            @"objc"         : @"Objective-C source file",
            @"java"         : @"Java source file",
            @"javascript"   : @"JavaScript file",
            @"javascript.js": @"JavaScript file",
            @"typescript"   : @"TypeScript file",
            @"swift"        : @"Swift file",
            @"go"           : @"Go source file",
            @"rust"         : @"Rust file",
            @"d"            : @"D programming language",
            @"rc"           : @"Windows Resource file",
            @"actionscript" : @"Flash ActionScript file",
            @"html"         : @"Hyper Text Markup Language file",
            @"asp"          : @"Active Server Pages script file",
            @"xml"          : @"eXtensible Markup Language file",
            @"css"          : @"Cascade Style Sheets File",
            @"json"         : @"JSON file",
            @"php"          : @"PHP Hypertext Preprocessor file",
            @"python"       : @"Python file",
            @"ruby"         : @"Ruby file",
            @"perl"         : @"Perl source file",
            @"lua"          : @"Lua source File",
            @"bash"         : @"Unix script file",
            @"powershell"   : @"Windows PowerShell",
            @"batch"        : @"Batch file",
            @"tcl"          : @"Tool Command Language file",
            @"r"            : @"R programming language",
            @"raku"         : @"Raku source file",
            @"coffeescript"  : @"CoffeeScript file",
            @"markdown"     : @"Markdown file",
            @"latex"        : @"LaTeX file",
            @"tex"          : @"TeX file",
            @"yaml"         : @"YAML Ain't Markup Language",
            @"toml"         : @"Tom's Obvious Minimal Language file",
            @"ini"          : @"MS ini file",
            @"props"        : @"Properties file",
            @"makefile"     : @"Makefile",
            @"cmake"        : @"CMake file",
            @"diff"         : @"Diff file",
            @"registry"     : @"Registry file",
            @"nsis"         : @"Nullsoft Scriptable Install System script file",
            @"inno"         : @"Inno Setup script",
            @"sql"          : @"Structured Query Language file",
            @"mssql"        : @"Microsoft Transact-SQL file",
            @"fortran"      : @"Fortran free form source file",
            @"fortran77"    : @"Fortran fixed form source file",
            @"pascal"       : @"Pascal source file",
            @"haskell"      : @"Haskell",
            @"caml"         : @"Categorical Abstract Machine Language",
            @"lisp"         : @"List Processing language file",
            @"scheme"       : @"Scheme file",
            @"erlang"       : @"Erlang file",
            @"nim"          : @"Nim file",
            @"gdscript"     : @"GDScript file",
            @"sas"          : @"SAS file",
            @"matlab"       : @"MATrix LABoratory",
            @"vhdl"         : @"VHSIC Hardware Description Language file",
            @"verilog"      : @"Verilog file",
            @"spice"        : @"Spice file",
            @"asm"          : @"Assembly language source file",
            @"ada"          : @"Ada file",
            @"cobol"        : @"COmmon Business Oriented Language",
            @"vb"           : @"Visual Basic file",
            @"autoit"       : @"AutoIt",
            @"postscript"   : @"PostScript file",
            @"smalltalk"    : @"Smalltalk file",
            @"forth"        : @"Forth file",
            @"oscript"      : @"OScript source file",
            @"avs"          : @"AviSynth scripts files",
            @"hollywood"    : @"Hollywood script",
            @"purebasic"    : @"PureBasic file",
            @"freebasic"    : @"FreeBasic file",
            @"blitzbasic"   : @"BlitzBasic file",
            @"kix"          : @"KiXtart file",
            @"visualprolog" : @"Visual Prolog file",
            @"baanc"        : @"BaanC File",
            @"nncrontab"    : @"Extended crontab file",
            @"csound"       : @"Csound file",
            @"escript"      : @"ESCRIPT file",
        };
    });
    // Try the descriptive long-name map first; if missing, fall back to the
    // Windows-derived short menu caption (asn1 → "ASN.1", mmixal → "MMIXAL",
    // ihex → "Intel HEX", etc.) so newly-restored built-in languages get a
    // human-readable status-bar name instead of the raw internal code.
    NSString *low = langCode.lowercaseString;
    NSString *hit = map[low];
    if (hit) return hit;
    NSString *caption = NppBuiltinLanguageCaptionForInternal(low);
    return caption ?: langCode;
}

- (void)updateStatusBar {
    EditorView *ed = [self currentEditor];
    if (!ed) { _statusLeft.stringValue = _statusRight.stringValue = @""; return; }
    sptr_t docLength = [ed.scintillaView message:SCI_GETLENGTH wParam:0 lParam:0];
    _statusLeft.stringValue  = [NSString stringWithFormat:@"Ln %ld, Col %ld  |  Length: %ld  |  Lines: %ld  |  Zoom: %ld%%",
                                 (long)ed.cursorLine, (long)ed.cursorColumn, (long)docLength, (long)ed.lineCount, (long)ed.zoomPercentage];
    NSString *lang = languageDisplayName(ed.currentLanguage);
    NSString *mode = ed.isOverwriteMode ? @"OVR" : @"INS";
    _statusRight.stringValue = [NSString stringWithFormat:@"%@  |  %@  |  %@  |  %@",
                                 lang, ed.encodingName, ed.eolName, mode];
}

// Issue #174: double-click on the language token (the leftmost segment of the
// right-aligned status string) opens the Language menu, like Notepad++ on
// Windows. Only the language token responds — the encoding/EOL/mode segments are
// ignored — and nothing about the status bar's appearance changes.
- (void)_statusBarDoubleClicked:(NSClickGestureRecognizer *)gr {
    EditorView *ed = [self currentEditor];
    if (!ed) return;

    const NSPoint p = [gr locationInView:_statusBar];
    const CGFloat pad = 6.0;                          // forgiving hit area

    // ── Zoom token double-click (Notepad++ parity) ──
    // Double-clicking the "Zoom: X%" segment on the left status bar resets the
    // editor zoom back to default 100% (SCI_SETZOOM 0), matching Notepad++ Windows.
    if (_statusLeft.stringValue.length) {
        NSString *leftFull = _statusLeft.stringValue;
        NSRange zoomRange = [leftFull rangeOfString:@"Zoom:"];
        if (zoomRange.location != NSNotFound) {
            NSDictionary *attrs = @{ NSFontAttributeName: _statusLeft.font };
            NSString *preZoom = [leftFull substringToIndex:zoomRange.location];
            CGFloat preW = [preZoom sizeWithAttributes:attrs].width;
            CGFloat zoomW = [[leftFull substringFromIndex:zoomRange.location] sizeWithAttributes:attrs].width;
            const NSRect leftFr = _statusLeft.frame;
            const CGFloat zoomLeft = NSMinX(leftFr) + preW;
            if (p.x >= zoomLeft - pad && p.x <= zoomLeft + zoomW + pad) {
                [self resetZoom:nil];
                return;
            }
        }
    }

    if (!_statusRight.stringValue.length) return;

    // Compute the language token's x-range inside the right-aligned label by
    // measuring text widths with the field's own font. The text hugs the field's
    // right edge, so the language token starts at (fieldRight - fullWidth).
    NSString *full = _statusRight.stringValue;
    NSString *lang = languageDisplayName(ed.currentLanguage);
    NSDictionary *attrs = @{ NSFontAttributeName: _statusRight.font };
    CGFloat wFull = [full sizeWithAttributes:attrs].width;
    CGFloat wLang = [lang sizeWithAttributes:attrs].width;
    const NSRect fr = _statusRight.frame;            // already in _statusBar coords
    const CGFloat textLeft = NSMaxX(fr) - wFull;

    if (p.x < textLeft - pad || p.x > textLeft + wLang + pad) return;

    // Pop up the LIVE menu-bar Language submenu (locale-stable tag) so its
    // delegate-driven parent-letter checkmark, the current-language leaf check,
    // and the dynamic User-Defined-Language list all come for free. Anchored at
    // the language token; AppKit flips it upward at the screen bottom so it sits
    // just above the status bar (matching the Windows placement).
    NSMenu *langMenu = nil;
    for (NSMenuItem *it in [NSApp mainMenu].itemArray)
        if (it.tag == kMenuTagLanguage && it.submenu) { langMenu = it.submenu; break; }
    if (!langMenu) return;
    [langMenu popUpMenuPositioningItem:nil
                            atLocation:NSMakePoint(textLeft, NSMaxY(_statusBar.bounds))
                                inView:_statusBar];
}

/// Repaint every tab that shows `editor`, in whichever pane owns it.
///
/// Addressing the tab by editor rather than by "the current tab of the primary
/// manager" matters in split view for two reasons. An editor moved into a pane
/// is owned by _subTabManagerH/V, so refreshing _tabManager repainted an
/// unrelated primary tab, if any, and left the pane's own tab stale — the
/// tab kept reading "new N" after Save As, and kept its modified dot after
/// Save, while -updateTitle (which goes through -currentEditor) showed the new
/// name. A *cloned* editor additionally has a sibling in the other pane sharing
/// its document, and -[EditorView saveToPath:] propagates filePath and modified
/// state to that sibling, so its tab goes stale at the same moment and has to
/// be repainted too.
///
/// Note cloneSibling holds a single peer, so a buffer cloned into both panes is
/// only partly reached here. That is the existing clone model, not a limit of
/// this method.
- (void)refreshTabsForEditor:(EditorView *)editor {
    if (!editor) return;
    EditorView *sibling = editor.cloneSibling;
    for (TabManager *mgr in @[_tabManager, _subTabManagerH, _subTabManagerV]) {
        [mgr refreshTitleForEditor:editor];
        if (sibling) [mgr refreshTitleForEditor:sibling];
    }
    [self updateTitle];
    if (_docListPanel && [_sidePanelHost hasPanel:_docListPanel])
        [_docListPanel refreshModifiedStates];
}

- (void)refreshCurrentTab {
    [self refreshTabsForEditor:[self currentEditor]];
}

- (void)saveWindowFrame {
    [[NSUserDefaults standardUserDefaults]
        setObject:NSStringFromRect(self.window.frame) forKey:kWindowFrameKey];
    [[NSUserDefaults standardUserDefaults] setBool:self.window.toolbar.visible forKey:kPrefToolbarVisible];
}

- (void)restoreWindowFrame {
    NSString *s = [[NSUserDefaults standardUserDefaults] stringForKey:kWindowFrameKey];
    if (s) [self.window setFrame:NSRectFromString(s) display:NO];
}

@end
