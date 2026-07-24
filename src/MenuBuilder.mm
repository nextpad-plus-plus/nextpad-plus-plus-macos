#import "MenuBuilder.h"
#import "NppBuiltinLanguages.h"

// Top-level menu-item tags. See MenuBuilder.h for rationale.
const NSInteger kMenuTagMacro    = 9900;
const NSInteger kMenuTagRun      = 9902;
const NSInteger kMenuTagLanguage = 9904;
const NSInteger kMenuTagPlugins  = 9905;

// ── Helpers ───────────────────────────────────────────────────────────────────

static NSMenuItem *item(NSString *title, SEL sel, NSString *key) {
    return [[NSMenuItem alloc] initWithTitle:title action:sel keyEquivalent:key];
}

static NSMenuItem *itemMod(NSString *title, SEL sel, NSString *key, NSEventModifierFlags mod) {
    NSMenuItem *i = item(title, sel, key);
    i.keyEquivalentModifierMask = mod;
    return i;
}

static NSMenu *submenu(NSString *title) {
    return [[NSMenu alloc] initWithTitle:title];
}

static NSMenuItem *withSubmenu(NSString *title, NSMenu *sub) {
    NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    i.submenu = sub;
    return i;
}

static void addSep(NSMenu *m) { [m addItem:[NSMenuItem separatorItem]]; }

// Helper for function-key / arrow-key shortcuts (keyEquivalent must be the Unicode char).
static NSMenuItem *itemFn(NSString *title, SEL sel, unichar fnKey, NSEventModifierFlags mod) {
    NSString *key = [NSString stringWithFormat:@"%C", fnKey];
    NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:title action:sel keyEquivalent:key];
    i.keyEquivalentModifierMask = mod;
    return i;
}

static NSMenuItem *itemTag(NSString *title, SEL sel, NSInteger tag) {
    NSMenuItem *i = item(title, sel, @"");
    i.tag = tag;
    return i;
}

// Not-yet-implemented items: enabled, shows an informational alert when clicked.
static NSMenuItem *nyi(NSString *title) {
    return item(title, @selector(notYetImplemented:), @"");
}

// Language item carries the internal language name in representedObject.
static NSMenuItem *langItem(NSString *display, NSString *langName) {
    NSMenuItem *i = item(display, @selector(setLanguageFromMenu:), @"");
    i.representedObject = langName;
    return i;
}

// ── Language menu ─────────────────────────────────────────────────────────────

static NSMenu *buildLanguageMenu() {
    NSMenu *m = submenu(@"Language");

    // Generate from the Windows-authoritative built-in language table (issue
    // #144 follow-up). The table is sorted alphabetically by caption with
    // "None (Normal Text)" pinned at index 0.
    NSUInteger count = 0;
    const NppBuiltinLang *langs = NppBuiltinLanguagesAll(&count);

    // ── Pinned top: "None (Normal Text)" ────────────────────────────────────
    // Empty representedObject → setLanguageFromMenu: routes through
    // setLanguage:@"" → plain branch in EditorView.
    [m addItem:langItem(@(langs[0].caption), @"")];
    addSep(m);

    // ── Letter-grouped submenus (entries 1..count-1) ────────────────────────
    // Walk the pre-sorted table in one pass; flush each letter's submenu
    // when we hit a new first-letter.
    NSMenu *letterMenu = nil;
    NSString *letterTitle = nil;
    unichar currentLetter = 0;
    for (NSUInteger i = 1; i < count; i++) {
        NSString *cap      = @(langs[i].caption);
        NSString *internal = @(langs[i].internalName);
        unichar firstChar  = (unichar)toupper((int)[cap characterAtIndex:0]);
        if (firstChar != currentLetter) {
            if (letterMenu) [m addItem:withSubmenu(letterTitle, letterMenu)];
            currentLetter = firstChar;
            letterTitle   = [NSString stringWithCharacters:&firstChar length:1];
            letterMenu    = submenu(letterTitle);
        }
        [letterMenu addItem:langItem(cap, internal)];
    }
    if (letterMenu) [m addItem:withSubmenu(letterTitle, letterMenu)];

    // ── UDL section ────────────────────────────────────────────────────────
    addSep(m);
    NSMenu *udlMenu = submenu(@"User Defined Language");
    [udlMenu addItem:item(@"Define your language…", @selector(showDefineLanguage:), @"")];
    [udlMenu addItem:item(@"Open User Defined Language Folder…", @selector(openUDLFolder:), @"")];
    [udlMenu addItem:item(@"Nextpad++ User Defined Languages Collection", @selector(openUDLCollection:), @"")];
    [m addItem:withSubmenu(@"User Defined Language", udlMenu)];

    // Trailing separator anchors the dynamic UDL-insertion zone. ALL loaded
    // UDLs (including the preinstalled Markdown variants) are inserted by
    // MainWindowController.rebuildUDLLanguageMenu after this separator —
    // there are no static preinstalled entries here anymore (the previous
    // hardcoded menu had them; the generated table doesn't include markdown
    // since Windows doesn't ship it as a built-in lexer).
    addSep(m);
    m.title = @"Language";

    return m;
}

// ─────────────────────────────────────────────────────────────────────────────

@implementation MenuBuilder

+ (void)buildMainMenu {
    NSMenu *main = [[NSMenu alloc] init];
    [NSApp setMainMenu:main];

    // ── App (macOS-specific) ──────────────────────────────────────────────────
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [main addItem:appItem];
    NSMenu *appMenu = submenu(@"App");
    appItem.submenu = appMenu;
    [appMenu addItemWithTitle:@"About Nextpad++" action:@selector(showAboutPanel:) keyEquivalent:@""];
    [appMenu addItemWithTitle:@"Check for Updates…" action:@selector(checkForUpdates:) keyEquivalent:@""];
    [appMenu addItemWithTitle:@"Install nextpad++ Command Line Tool…" action:@selector(installCommandLineTool:) keyEquivalent:@""];
    addSep(appMenu);
    // Apple renamed "Preferences…" to "Settings…" starting in macOS Ventura (13).
    NSString *prefsTitle = ([NSProcessInfo processInfo].operatingSystemVersion.majorVersion >= 13)
        ? @"Settings…" : @"Preferences…";
    [appMenu addItem:item(prefsTitle, @selector(showPreferences:), @",")];
    addSep(appMenu);
    [appMenu addItemWithTitle:@"Hide Nextpad++" action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem *hideOthers = [appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    addSep(appMenu);
    [appMenu addItemWithTitle:@"Quit Nextpad++" action:@selector(terminate:) keyEquivalent:@"q"];

    // ── File ─────────────────────────────────────────────────────────────────
    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    [main addItem:fileItem];
    NSMenu *fileMenu = submenu(@"File");
    fileItem.submenu = fileMenu;

    [fileMenu addItem:item(@"New",        @selector(newDocument:),  @"n")];
    [fileMenu addItem:item(@"Open…",     @selector(openDocument:), @"o")];
    NSMenuItem *recentItem = withSubmenu(@"Open Recent", submenu(@"Open Recent"));
    recentItem.tag = 1001;
    [fileMenu addItem:recentItem];

    NSMenu *openContMenu = submenu(@"Open Containing Folder");
    [openContMenu addItem:item(@"Finder",   @selector(revealInFinder:),  @"")];
    [openContMenu addItem:item(@"Terminal", @selector(openInTerminal:),  @"")];
    [fileMenu addItem:withSubmenu(@"Open Containing Folder", openContMenu)];

    [fileMenu addItem:item(@"Open in Default Viewer",    @selector(openInDefaultViewer:),  @"")];
    [fileMenu addItem:item(@"Open Folder as Workspace…", @selector(openFolderAsWorkspace:), @"")];
    addSep(fileMenu);
    [fileMenu addItem:item(@"Reload from Disk", @selector(reloadFromDisk:), @"")];
    addSep(fileMenu);
    [fileMenu addItem:item(@"Save",          @selector(saveDocument:),    @"s")];
    [fileMenu addItem:itemMod(@"Save As…",   @selector(saveDocumentAs:),  @"s",
                              NSEventModifierFlagCommand | NSEventModifierFlagOption)];
    [fileMenu addItem:item(@"Save a Copy As…", @selector(saveDocumentCopyAs:), @"")];
    [fileMenu addItem:itemMod(@"Save All",   @selector(saveAllDocuments:),@"s",
                              NSEventModifierFlagCommand | NSEventModifierFlagShift)];
    [fileMenu addItem:item(@"Rename…", @selector(renameDocument:), @"")];
    addSep(fileMenu);
    [fileMenu addItem:item(@"Close",         @selector(closeCurrentTab:), @"w")];
    [fileMenu addItem:itemMod(@"Close All",  @selector(closeAllTabs:),    @"w",
                              NSEventModifierFlagCommand | NSEventModifierFlagShift)];

    NSMenu *closeMultMenu = submenu(@"Close Multiple Documents");
    [closeMultMenu addItem:item(@"Close All But Current",   @selector(closeAllButCurrent:), @"")];
    [closeMultMenu addItem:item(@"Close All to the Left",   @selector(closeAllToLeft:),     @"")];
    [closeMultMenu addItem:item(@"Close All to the Right",  @selector(closeAllToRight:),    @"")];
    [closeMultMenu addItem:item(@"Close All Unchanged",     @selector(closeAllUnchanged:),  @"")];
    [closeMultMenu addItem:item(@"Close All But Pinned", @selector(closeAllButPinned:), @"")];
    [fileMenu addItem:withSubmenu(@"Close Multiple Documents", closeMultMenu)];

    [fileMenu addItem:item(@"Move to Trash", @selector(moveToTrash:), @"")];
    addSep(fileMenu);
    [fileMenu addItem:item(@"Load Session…", @selector(loadSession:),    @"")];
    [fileMenu addItem:item(@"Save Session…", @selector(saveSessionAs:),  @"")];
    addSep(fileMenu);
    [fileMenu addItem:item(@"Print…", @selector(printDocument:), @"p")];
    [fileMenu addItem:item(@"Print Now", @selector(printNow:), @"")];

    // ── Edit ─────────────────────────────────────────────────────────────────
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [main addItem:editItem];
    NSMenu *editMenu = submenu(@"Edit");
    editItem.submenu = editMenu;

    [editMenu addItem:item(@"Undo",       @selector(undo:),      @"z")];
    [editMenu addItem:itemMod(@"Redo",    @selector(redo:),      @"z",
                              NSEventModifierFlagCommand | NSEventModifierFlagShift)];
    addSep(editMenu);
    [editMenu addItem:item(@"Cut",        @selector(cut:),       @"x")];
    [editMenu addItem:item(@"Copy",       @selector(copy:),      @"c")];
    [editMenu addItem:item(@"Paste",      @selector(paste:),     @"v")];
    [editMenu addItem:item(@"Delete",     @selector(delete:),    @"")];
    [editMenu addItem:item(@"Select All", @selector(selectAll:), @"a")];
    {
        NSMenuItem *it = item(@"Begin/End Select", @selector(beginEndSelect:), @"b");
        it.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
        [editMenu addItem:it];
    }
    {
        NSMenuItem *it = item(@"Begin/End Select in Column Mode", @selector(beginEndSelectColumnMode:), @"b");
        it.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagShift;
        [editMenu addItem:it];
    }
    addSep(editMenu);

    // Insert submenu
    NSMenu *insertMenu = submenu(@"Insert");
    [insertMenu addItem:item(@"Insert Date/Time (Short)",         @selector(insertDateTimeShort:),    @"")];
    [insertMenu addItem:item(@"Insert Date/Time (Long)",          @selector(insertDateTimeLong:),     @"")];
    [insertMenu addItem:item(@"Insert Date/Time (Custom Format…)", @selector(insertDateTimeCustom:), @"")];
    addSep(insertMenu);
    [insertMenu addItem:item(@"Insert Blank Line Above Current",  @selector(insertBlankLineAbove:),   @"")];
    [insertMenu addItem:item(@"Insert Blank Line Below Current",  @selector(insertBlankLineBelow:),   @"")];
    [editMenu addItem:withSubmenu(@"Insert", insertMenu)];

    // Copy to Clipboard submenu
    NSMenu *copyClipMenu = submenu(@"Copy to Clipboard");
    [copyClipMenu addItem:item(@"Copy Full File Path",         @selector(copyFullFilePath:),         @"")];
    [copyClipMenu addItem:item(@"Copy File Name",              @selector(copyFileName:),              @"")];
    [copyClipMenu addItem:item(@"Copy Current Directory Path", @selector(copyCurrentDirectoryPath:),  @"")];
    addSep(copyClipMenu);
    [copyClipMenu addItem:item(@"Copy All File Names",         @selector(copyAllFileNames:),          @"")];
    [copyClipMenu addItem:item(@"Copy All File Paths",         @selector(copyAllFilePaths:),          @"")];
    [editMenu addItem:withSubmenu(@"Copy to Clipboard", copyClipMenu)];

    // Indent submenu
    NSMenu *indentMenu = submenu(@"Indent");
    [indentMenu addItem:itemMod(@"Increase Line Indent", @selector(indentSelection:),  @"]",
                                NSEventModifierFlagCommand)];
    [indentMenu addItem:itemMod(@"Decrease Line Indent", @selector(unindentSelection:),@"[",
                                NSEventModifierFlagCommand)];
    [editMenu addItem:withSubmenu(@"Indent", indentMenu)];

    // Convert Case to submenu
    NSMenu *caseMenu = submenu(@"Convert Case to");
    [caseMenu addItem:item(@"UPPERCASE",                          @selector(convertToUppercase:),    @"")];
    [caseMenu addItem:item(@"lowercase",                          @selector(convertToLowercase:),    @"")];
    [caseMenu addItem:item(@"Proper Case (Force First Char)",     @selector(convertToProperCase:),        @"")];
    [caseMenu addItem:item(@"Proper Case (Blend)",               @selector(convertToProperCaseBlend:),   @"")];
    [caseMenu addItem:item(@"Sentence case (Force First Char)",   @selector(convertToSentenceCase:),     @"")];
    [caseMenu addItem:item(@"Sentence case (Blend)",             @selector(convertToSentenceCaseBlend:), @"")];
    [caseMenu addItem:item(@"iNVERT cASE",                        @selector(convertToInvertedCase:), @"")];
    [caseMenu addItem:item(@"rAnDoM cAsE",                        @selector(convertToRandomCase:),   @"")];
    [editMenu addItem:withSubmenu(@"Convert Case to", caseMenu)];

    // Line Operations submenu
    NSMenu *lineMenu = submenu(@"Line Operations");
    [lineMenu addItem:itemMod(@"Duplicate Line", @selector(duplicateLine:), @"d",
                              NSEventModifierFlagCommand)];
    [lineMenu addItem:itemMod(@"Delete Line",    @selector(deleteLine:),    @"k",
                              NSEventModifierFlagCommand | NSEventModifierFlagShift)];
    [lineMenu addItem:itemFn(@"Move Line Up",   @selector(moveLineUp:),   NSUpArrowFunctionKey,
                             NSEventModifierFlagControl | NSEventModifierFlagShift)];
    [lineMenu addItem:itemFn(@"Move Line Down", @selector(moveLineDown:), NSDownArrowFunctionKey,
                             NSEventModifierFlagControl | NSEventModifierFlagShift)];
    addSep(lineMenu);
    [lineMenu addItem:item(@"Split Lines", @selector(splitLines:), @"")];
    [lineMenu addItem:item(@"Join Lines", @selector(joinLines:), @"")];
    addSep(lineMenu);
    NSMenu *sortMenu = submenu(@"Sort Lines");
    [sortMenu addItem:item(@"Ascending",                    @selector(sortLinesAscending:),    @"")];
    [sortMenu addItem:item(@"Descending",                   @selector(sortLinesDescending:),   @"")];
    [sortMenu addItem:item(@"Ascending (case-insensitive)", @selector(sortLinesAscendingCI:),  @"")];
    addSep(sortMenu);
    [sortMenu addItem:item(@"By Length (Shortest First)",   @selector(sortLinesByLengthAsc:),  @"")];
    [sortMenu addItem:item(@"By Length (Longest First)",    @selector(sortLinesByLengthDesc:), @"")];
    addSep(sortMenu);
    [sortMenu addItem:item(@"Randomly",               @selector(sortLinesRandomly:),        @"")];
    [sortMenu addItem:item(@"Reverse Order",           @selector(sortLinesReverse:),          @"")];
    addSep(sortMenu);
    [sortMenu addItem:item(@"Integer Ascending",       @selector(sortLinesIntAsc:),           @"")];
    [sortMenu addItem:item(@"Integer Descending",      @selector(sortLinesIntDesc:),          @"")];
    [sortMenu addItem:item(@"Decimal Comma Ascending", @selector(sortLinesDecimalCommaAsc:),  @"")];
    [sortMenu addItem:item(@"Decimal Comma Descending",@selector(sortLinesDecimalCommaDesc:), @"")];
    [sortMenu addItem:item(@"Decimal Dot Ascending",   @selector(sortLinesDecimalDotAsc:),    @"")];
    [sortMenu addItem:item(@"Decimal Dot Descending",  @selector(sortLinesDecimalDotDesc:),   @"")];
    [lineMenu addItem:withSubmenu(@"Sort Lines", sortMenu)];
    addSep(lineMenu);
    [lineMenu addItem:item(@"Remove Duplicate Lines",             @selector(removeDuplicateLines:),            @"")];
    [lineMenu addItem:item(@"Remove Consecutive Duplicate Lines", @selector(removeConsecutiveDuplicateLines:), @"")];
    [editMenu addItem:withSubmenu(@"Line Operations", lineMenu)];

    // Comment/Uncomment submenu
    NSMenu *commentMenu = submenu(@"Comment/Uncomment");
    [commentMenu addItem:itemMod(@"Toggle Single Line Comment", @selector(toggleLineComment:),       @"q", NSEventModifierFlagControl)];
    [commentMenu addItem:itemMod(@"Single Line Comment",        @selector(addSingleLineComment:),    @"k", NSEventModifierFlagControl)];
    [commentMenu addItem:itemMod(@"Single Line Uncomment",      @selector(removeSingleLineComment:), @"k", NSEventModifierFlagControl | NSEventModifierFlagShift)];
    [commentMenu addItem:itemMod(@"Block Comment",              @selector(addBlockComment:),         @"q", NSEventModifierFlagControl | NSEventModifierFlagShift)];
    [commentMenu addItem:item(@"Block Uncomment",               @selector(removeBlockComment:),      @"")];
    [editMenu addItem:withSubmenu(@"Comment/Uncomment", commentMenu)];

    // Auto-Completion submenu
    NSMenu *acMenu = submenu(@"Auto-Completion");
    [acMenu addItem:itemMod(@"Function Completion",              @selector(triggerFunctionCompletion:),          @" ", NSEventModifierFlagControl)];
    [acMenu addItem:itemMod(@"Word Completion",                  @selector(triggerWordCompletion:),              @"\r", NSEventModifierFlagControl)];
    [acMenu addItem:itemMod(@"Function Parameters Hint",         @selector(triggerFunctionParametersHint:),      @" ", NSEventModifierFlagControl | NSEventModifierFlagShift)];
    [acMenu addItem:itemFn(@"Function Parameters Previous Hint", @selector(showFunctionParametersPreviousHint:), NSUpArrowFunctionKey,   NSEventModifierFlagOption)];
    [acMenu addItem:itemFn(@"Function Parameters Next Hint",     @selector(showFunctionParametersNextHint:),     NSDownArrowFunctionKey, NSEventModifierFlagOption)];
    [acMenu addItem:itemMod(@"Path Completion",                  @selector(triggerPathCompletion:),              @"p", NSEventModifierFlagControl | NSEventModifierFlagShift)];
    addSep(acMenu);
    [acMenu addItem:item(@"Finish or Select Autocomplete Item",  @selector(finishOrSelectAutocompleteItem:),     @"")];
    [editMenu addItem:withSubmenu(@"Auto-Completion", acMenu)];

    // EOL Conversion submenu
    NSMenu *eolMenu = submenu(@"EOL Conversion");
    [eolMenu addItem:item(@"Windows (CR LF)", @selector(setEOLCRLF:), @"")];
    [eolMenu addItem:item(@"Unix (LF)",       @selector(setEOLLF:),   @"")];
    [eolMenu addItem:item(@"Old Mac (CR)",    @selector(setEOLCR:),   @"")];
    [editMenu addItem:withSubmenu(@"EOL Conversion", eolMenu)];

    // Blank Operations submenu (operations scope to selection when text is selected)
    NSMenu *blankMenu = submenu(@"Blank Operations");
    [blankMenu addItem:item(@"Trim Trailing Space",              @selector(trimTrailingWhitespace:),       @"")];
    [blankMenu addItem:item(@"Trim Leading Space",               @selector(trimLeadingSpaces:),            @"")];
    [blankMenu addItem:item(@"Trim Leading and Trailing Space",  @selector(trimLeadingAndTrailingSpaces:), @"")];
    [blankMenu addItem:item(@"EOL to Space",                     @selector(eolToSpace:),                   @"")];
    [blankMenu addItem:item(@"Trim Both and EOL to Space",       @selector(trimBothAndEOLToSpace:),        @"")];
    addSep(blankMenu);
    [blankMenu addItem:item(@"TAB to Space",                     @selector(tabsToSpaces:),                 @"")];
    [blankMenu addItem:item(@"Space to TAB (All)",               @selector(spacesToTabsAll:),              @"")];
    [blankMenu addItem:item(@"Space to TAB (Leading)",           @selector(spacesToTabsLeading:),          @"")];
    addSep(blankMenu);
    [blankMenu addItem:item(@"Remove Unnecessary Blank and EOL", @selector(removeUnnecessaryBlankAndEOL:), @"")];
    [blankMenu addItem:item(@"Remove Blank Lines",               @selector(removeBlankLines:),             @"")];
    [blankMenu addItem:item(@"Merge Blank Lines",                @selector(mergeBlankLines:),              @"")];
    [editMenu addItem:withSubmenu(@"Blank Operations", blankMenu)];

    // Paste Special submenu
    NSMenu *pasteSpecMenu = submenu(@"Paste Special");
    [pasteSpecMenu addItem:item(@"Copy Binary Content",  @selector(copyBinaryContent:),  @"")];
    [pasteSpecMenu addItem:item(@"Paste Binary Content", @selector(pasteBinaryContent:), @"")];
    addSep(pasteSpecMenu);
    [pasteSpecMenu addItem:item(@"Paste HTML Content", @selector(pasteHTMLContent:), @"")];
    [pasteSpecMenu addItem:item(@"Paste RTF Content",  @selector(pasteRTFContent:),  @"")];
    [editMenu addItem:withSubmenu(@"Paste Special", pasteSpecMenu)];

    // On Selection submenu
    NSMenu *onSelMenu = submenu(@"On Selection");
    [onSelMenu addItem:item(@"Open File",                        @selector(openSelectionAsFile:),          @"")];
    [onSelMenu addItem:item(@"Open Containing Folder in Finder", @selector(openContainingFolderInFinder:), @"")];
    addSep(onSelMenu);
    [onSelMenu addItem:item(@"Redact Selection \u25A0 (Shift: \u2022)", @selector(redactSelection:), @"")];
    addSep(onSelMenu);
    [onSelMenu addItem:item(@"Search on Internet",               @selector(searchSelectionOnInternet:),   @"")];
    [onSelMenu addItem:item(@"Change Search Engine…",            @selector(changeSearchEngine:),          @"")];
    [editMenu addItem:withSubmenu(@"On Selection", onSelMenu)];
    addSep(editMenu);

    // Multi-select All
    NSMenu *msAllMenu = submenu(@"Multi-Select All");
    [msAllMenu addItem:item(@"Ignore Case & Whole Word",  @selector(multiSelectAllIgnoreCaseIgnoreWord:),  @"")];
    [msAllMenu addItem:item(@"Match Case Only",           @selector(multiSelectAllMatchCaseOnly:),         @"")];
    [msAllMenu addItem:item(@"Whole Word Only",           @selector(multiSelectAllWholeWordOnly:),         @"")];
    [msAllMenu addItem:item(@"Match Case & Whole Word",   @selector(multiSelectAllMatchCaseWholeWord:),   @"")];
    [editMenu addItem:withSubmenu(@"Multi-Select All", msAllMenu)];

    // Multi-select Next
    NSMenu *msNextMenu = submenu(@"Multi-Select Next");
    [msNextMenu addItem:item(@"Ignore Case & Whole Word", @selector(multiSelectNextIgnoreCaseIgnoreWord:), @"")];
    [msNextMenu addItem:item(@"Match Case Only",          @selector(multiSelectNextMatchCaseOnly:),        @"")];
    [msNextMenu addItem:item(@"Whole Word Only",          @selector(multiSelectNextWholeWordOnly:),        @"")];
    [msNextMenu addItem:item(@"Match Case & Whole Word",  @selector(multiSelectNextMatchCaseWholeWord:),  @"")];
    [editMenu addItem:withSubmenu(@"Multi-Select Next", msNextMenu)];

    [editMenu addItem:item(@"Undo the Latest Added Multi-Select",       @selector(undoLatestMultiSelect:),             @"")];
    [editMenu addItem:item(@"Skip Current & Go to Next Multi-select",   @selector(skipCurrentAndGoToNextMultiSelect:), @"")];
    addSep(editMenu);

    [editMenu addItem:item(@"Column Mode…",    @selector(columnMode:),      @"")];
    [editMenu addItem:item(@"Column Editor…",  @selector(showColumnEditor:), @"")];
    [editMenu addItem:item(@"Character Panel", @selector(characterPanel:),  @"")];
    [editMenu addItem:item(@"Clipboard History", @selector(showClipboardHistory:), @"")];
    addSep(editMenu);

    NSMenu *roMenu = submenu(@"Read-Only in Nextpad++");
    [roMenu addItem:item(@"Toggle Read-Only",        @selector(toggleReadOnly:),  @"")];
    [roMenu addItem:item(@"Clear Read-Only Flag", @selector(clearReadOnlyFlag:), @"")];
    [editMenu addItem:withSubmenu(@"Read-Only in Nextpad++", roMenu)];
    NSMenu *lockedMenu = submenu(@"Locked Attribute (macOS)");
    [lockedMenu addItem:item(@"Lock",   @selector(lockFileAttribute:),   @"")];
    [lockedMenu addItem:item(@"Unlock", @selector(unlockFileAttribute:), @"")];
    [editMenu addItem:withSubmenu(@"Locked Attribute (macOS)", lockedMenu)];

    addSep(editMenu);
    [editMenu addItem:item(@"Shortcut Mapper…",    @selector(showShortcutMapper:),   @"")];
    [editMenu addItem:item(@"Edit Popup ContextMenu", @selector(editPopupContextMenu:), @"")];

    // ── Edit ▸ Encoding (was top-level "Encoding" menu) — placed last ───────
    addSep(editMenu);
    NSMenu *encMenu = submenu(@"Encoding");
    [encMenu addItem:item(@"ANSI",        @selector(setEncodingANSI:),      @"")];
    [encMenu addItem:item(@"UTF-8",       @selector(setEncodingUTF8:),      @"")];
    [encMenu addItem:item(@"UTF-8-BOM",   @selector(setEncodingUTF8BOM:),   @"")];
    [encMenu addItem:item(@"UTF-16 BE BOM", @selector(setEncodingUTF16BEBOM:), @"")];
    [encMenu addItem:item(@"UTF-16 LE BOM", @selector(setEncodingUTF16LEBOM:), @"")];

    NSMenu *charSetMenu = submenu(@"Character sets");
    NSMenu *csWestern = submenu(@"Western European");
    [csWestern addItem:item(@"Latin-1 (ISO-8859-1)",  @selector(setEncodingLatin1:),    @"")];
    [csWestern addItem:item(@"Latin-9 (ISO-8859-15)", @selector(setEncodingLatin9:),    @"")];
    [csWestern addItem:item(@"Windows-1252",           @selector(setEncodingWindows1252:), @"")];
    [charSetMenu addItem:withSubmenu(@"Western European", csWestern)];
    [charSetMenu addItem:item(@"Central European (Windows-1250)", @selector(setEncodingWindows1250:), @"")];
    [charSetMenu addItem:item(@"Cyrillic (Windows-1251)",          @selector(setEncodingWindows1251:), @"")];
    [charSetMenu addItem:item(@"Greek (Windows-1253)",             @selector(setEncodingWindows1253:), @"")];
    [charSetMenu addItem:item(@"Baltic (Windows-1257)",            @selector(setEncodingWindows1257:), @"")];
    [charSetMenu addItem:item(@"Turkish (Windows-1254)",           @selector(setEncodingWindows1254:), @"")];
    [charSetMenu addItem:item(@"Chinese Traditional (Big5)",       @selector(setEncodingBig5:),        @"")];
    [charSetMenu addItem:item(@"Chinese Simplified (GB2312)",      @selector(setEncodingGB2312:),      @"")];
    [charSetMenu addItem:item(@"Japanese (Shift-JIS)",             @selector(setEncodingShiftJIS:),    @"")];
    [charSetMenu addItem:item(@"Korean (EUC-KR)",                  @selector(setEncodingEUCKR:),       @"")];
    [encMenu addItem:withSubmenu(@"Character sets", charSetMenu)];
    addSep(encMenu);

    [encMenu addItem:item(@"Convert to ANSI",          @selector(convertToEncodingANSI:),      @"")];
    [encMenu addItem:item(@"Convert to UTF-8",         @selector(convertToEncodingUTF8:),      @"")];
    [encMenu addItem:item(@"Convert to UTF-8-BOM",     @selector(convertToEncodingUTF8BOM:),   @"")];
    [encMenu addItem:item(@"Convert to UTF-16 BE BOM", @selector(convertToEncodingUTF16BEBOM:), @"")];
    [encMenu addItem:item(@"Convert to UTF-16 LE BOM", @selector(convertToEncodingUTF16LEBOM:), @"")];
    [editMenu addItem:withSubmenu(@"Encoding", encMenu)];

    // ── Search ────────────────────────────────────────────────────────────────
    NSMenuItem *searchItem = [[NSMenuItem alloc] init];
    [main addItem:searchItem];
    NSMenu *searchMenu = submenu(@"Search");
    searchItem.submenu = searchMenu;

    [searchMenu addItem:item(@"Find…",       @selector(showFindPanel:),    @"f")];
    [searchMenu addItem:itemMod(@"Find in Files…", @selector(showFindInFiles:), @"f",
                                NSEventModifierFlagCommand | NSEventModifierFlagShift)];
    addSep(searchMenu);
    [searchMenu addItem:itemMod(@"Find Next",     @selector(findNext:),     @"g",
                                NSEventModifierFlagCommand)];
    [searchMenu addItem:itemMod(@"Find Previous", @selector(findPrevious:), @"g",
                                NSEventModifierFlagCommand | NSEventModifierFlagShift)];
    [searchMenu addItem:item(@"Select and Find Next",     @selector(selectAndFindNext:),     @"")];
    [searchMenu addItem:item(@"Select and Find Previous", @selector(selectAndFindPrevious:), @"")];
    [searchMenu addItem:item(@"Find (Volatile) Next",     @selector(findVolatileNext:),     @"")];
    [searchMenu addItem:item(@"Find (Volatile) Previous", @selector(findVolatilePrevious:), @"")];
    addSep(searchMenu);
    // ⇧⌘H opens the Find window's Replace tab (issue #61). The previous
    // shortcut ⌥⌘H clashed with the macOS-standard "Hide Others"
    // (App-menu, MenuBuilder.mm:222-223), and macOS does not define a
    // winner when two app menu items share a shortcut — the result was
    // undefined dispatch. ⇧⌘H also forms a logical pair with ⌘F and
    // ⇧⌘F, so the Shift modifier consistently means "another Find
    // variant", and matches the natural Mac mapping for Nextpad++ on
    // Windows where Ctrl+H is Replace. Both ⇧⌘H itself and ⌥⌘H now
    // dispatch unambiguously to a single, expected target.
    [searchMenu addItem:itemMod(@"Replace…", @selector(showReplacePanel:), @"h",
                                NSEventModifierFlagCommand | NSEventModifierFlagShift)];
    [searchMenu addItem:item(@"Incremental Search", @selector(showIncrementalSearch:), @"i")];
    addSep(searchMenu);
    [searchMenu addItem:item(@"Search Results Window",  @selector(showSearchResultsWindow:), @"")];
    [searchMenu addItem:itemFn(@"Next Search Result",     @selector(nextSearchResult:),     NSF4FunctionKey, 0)];
    [searchMenu addItem:itemFn(@"Previous Search Result", @selector(previousSearchResult:), NSF4FunctionKey, NSEventModifierFlagShift)];
    addSep(searchMenu);
    [searchMenu addItem:itemMod(@"Go to…",           @selector(goToLine:),    @"g",
                                NSEventModifierFlagCommand | NSEventModifierFlagOption)];
    [searchMenu addItem:item(@"Go to Matching Brace", @selector(goToMatchingBrace:), @"")];
    [searchMenu addItem:item(@"Select All In-between {} [] or ()", @selector(selectAllInBraces:), @"")];
    [searchMenu addItem:item(@"Mark…", @selector(showMarkDialog:), @"")];
    addSep(searchMenu);

    NSMenu *chMenu = submenu(@"Change History");
    [chMenu addItem:item(@"Go to Next Change",     @selector(goToNextChange:),     @"")];
    [chMenu addItem:item(@"Go to Previous Change", @selector(goToPreviousChange:), @"")];
    [chMenu addItem:item(@"Clear All Changes",     @selector(clearAllChanges:),    @"")];
    [searchMenu addItem:withSubmenu(@"Change History", chMenu)];

    static NSString * const kOrd[5] = {@"st", @"nd", @"rd", @"th", @"th"};
    // Mark style colors (BGR from Scintilla, converted to NSColor RGB)
    NSArray *markSwatches = @[
        [NSColor colorWithRed:0/255.0 green:255/255.0 blue:255/255.0 alpha:1],   // 1: cyan
        [NSColor colorWithRed:255/255.0 green:255/255.0 blue:0/255.0 alpha:1],   // 2: yellow
        [NSColor colorWithRed:0/255.0 green:200/255.0 blue:0/255.0 alpha:1],     // 3: green
        [NSColor colorWithRed:255/255.0 green:120/255.0 blue:0/255.0 alpha:1],   // 4: orange
        [NSColor colorWithRed:200/255.0 green:100/255.0 blue:255/255.0 alpha:1], // 5: violet
    ];
    NSImage *(^markSwatch)(int) = ^NSImage *(int idx) {
        NSImage *sw = [[NSImage alloc] initWithSize:NSMakeSize(12, 12)];
        [sw lockFocus];
        [markSwatches[idx] setFill];
        NSRectFill(NSMakeRect(1, 1, 10, 10));
        [[NSColor grayColor] setStroke];
        [NSBezierPath strokeRect:NSMakeRect(0.5, 0.5, 11, 11)];
        [sw unlockFocus];
        return sw;
    };

    NSMenu *styleAllMenu = submenu(@"Style All Occurrences of Token");
    for (int i = 1; i <= 5; i++) {
        NSMenuItem *mi = itemTag([NSString stringWithFormat:@"Using %d%@ Style", i, kOrd[i-1]],
                                 @selector(styleAllOccurrences:), i);
        mi.image = markSwatch(i - 1);
        [styleAllMenu addItem:mi];
    }
    [searchMenu addItem:withSubmenu(@"Style All Occurrences of Token", styleAllMenu)];

    NSMenu *styleOneMenu = submenu(@"Style One Token");
    for (int i = 1; i <= 5; i++) {
        NSMenuItem *mi = itemTag([NSString stringWithFormat:@"Using %d%@ Style", i, kOrd[i-1]],
                                 @selector(styleOneToken:), i);
        mi.image = markSwatch(i - 1);
        [styleOneMenu addItem:mi];
    }
    [searchMenu addItem:withSubmenu(@"Style One Token", styleOneMenu)];

    NSMenu *clearStyleMenu = submenu(@"Clear Style");
    for (int i = 1; i <= 5; i++) {
        NSMenuItem *mi = itemTag([NSString stringWithFormat:@"Clear %d%@ Style", i, kOrd[i-1]],
                                 @selector(clearMarkStyleN:), i);
        mi.image = markSwatch(i - 1);
        [clearStyleMenu addItem:mi];
    }
    addSep(clearStyleMenu);
    [clearStyleMenu addItem:item(@"Clear All Styles", @selector(clearAllMarkStyles:), @"")];
    [searchMenu addItem:withSubmenu(@"Clear Style", clearStyleMenu)];

    NSMenu *jumpUpMenu = submenu(@"Jump Up");
    [jumpUpMenu addItem:item(@"Next Styled Token Above", @selector(jumpToNextStyledTokenAbove:), @"")];
    [jumpUpMenu addItem:item(@"Next Bookmark Above",     @selector(jumpToNextBookmarkAbove:),    @"")];
    [searchMenu addItem:withSubmenu(@"Jump Up", jumpUpMenu)];

    NSMenu *jumpDownMenu = submenu(@"Jump Down");
    [jumpDownMenu addItem:item(@"Next Styled Token Below", @selector(jumpToNextStyledTokenBelow:), @"")];
    [jumpDownMenu addItem:item(@"Next Bookmark Below",     @selector(jumpToNextBookmarkBelow:),    @"")];
    [searchMenu addItem:withSubmenu(@"Jump Down", jumpDownMenu)];

    NSMenu *copyStyledMenu = submenu(@"Copy Styled Text");
    for (int i = 1; i <= 5; i++) {
        NSMenuItem *mi = itemTag([NSString stringWithFormat:@"Copy %d%@ Style Text", i, kOrd[i-1]],
                                         @selector(copyStyledText:), i);
        mi.image = markSwatch(i - 1);
        [copyStyledMenu addItem:mi];
    }
    [searchMenu addItem:withSubmenu(@"Copy Styled Text", copyStyledMenu)];

    NSMenu *bmMenu = submenu(@"Bookmark");
    [bmMenu addItem:itemFn(@"Toggle Bookmark",   @selector(toggleBookmark:),   NSF2FunctionKey,
                            NSEventModifierFlagCommand)];
    [bmMenu addItem:itemFn(@"Next Bookmark",     @selector(nextBookmark:),     NSF2FunctionKey, 0)];
    [bmMenu addItem:itemFn(@"Previous Bookmark", @selector(previousBookmark:), NSF2FunctionKey,
                            NSEventModifierFlagShift)];
    [bmMenu addItem:item(@"Clear All Bookmarks",  @selector(clearAllBookmarks:), @"")];
    addSep(bmMenu);
    [bmMenu addItem:item(@"Cut Bookmarked Lines",                 @selector(cutBookmarkedLines:),      @"")];
    [bmMenu addItem:item(@"Copy Bookmarked Lines",                @selector(copyBookmarkedLines:),     @"")];
    [bmMenu addItem:item(@"Paste to (Replace) Bookmarked Lines", @selector(pasteToBookmarkedLines:), @"")];
    [bmMenu addItem:item(@"Remove Bookmarked Lines",              @selector(removeBookmarkedLines:),   @"")];
    [bmMenu addItem:item(@"Remove Non-Bookmarked Lines",          @selector(removeNonBookmarkedLines:),@"")];
    [bmMenu addItem:item(@"Inverse Bookmark",                     @selector(inverseBookmark:),         @"")];
    [searchMenu addItem:withSubmenu(@"Bookmark", bmMenu)];
    addSep(searchMenu);
    [searchMenu addItem:item(@"Find Characters in Range…", @selector(showFindCharsInRange:), @"")];

    // ── View ──────────────────────────────────────────────────────────────────
    NSMenuItem *viewItem = [[NSMenuItem alloc] init];
    [main addItem:viewItem];
    NSMenu *viewMenu = submenu(@"View");
    viewItem.submenu = viewMenu;

    [viewMenu addItem:itemMod(@"Command Palette…", @selector(showCommandPalette:), @"p",
                              NSEventModifierFlagCommand | NSEventModifierFlagShift)];
    addSep(viewMenu);
    [viewMenu addItem:item(@"Always on Top", @selector(toggleAlwaysOnTop:), @"")];
    [viewMenu addItem:itemMod(@"Toggle Full Screen Mode", @selector(toggleFullScreen:), @"f",
                              NSEventModifierFlagCommand | NSEventModifierFlagControl)];
    [viewMenu addItem:itemFn(@"Post-It",             @selector(togglePostItMode:),         NSF12FunctionKey, 0)];
    [viewMenu addItem:item(@"Distraction Free Mode", @selector(toggleDistractionFreeMode:), @"")];
    addSep(viewMenu);

    NSMenu *viewInMenu = submenu(@"View Current File in");
    [viewInMenu addItem:item(@"Firefox",        @selector(viewInFirefox:),       @"")];
    [viewInMenu addItem:item(@"Chrome",         @selector(viewInChrome:),        @"")];
    [viewInMenu addItem:item(@"Safari",         @selector(viewInSafari:),        @"")];
    [viewInMenu addItem:item(@"Custom Browser…",@selector(viewInCustomBrowser:), @"")];
    [viewMenu addItem:withSubmenu(@"View Current File in", viewInMenu)];
    addSep(viewMenu);

    NSMenu *appearanceMenu = submenu(@"Appearance");
    [appearanceMenu addItem:item(@"Style Configurator…",   @selector(showStyleConfigurator:), @"")];
    [appearanceMenu addItem:item(@"Import Style Theme(s)…", @selector(importStyleTheme:),      @"")];
    [viewMenu addItem:withSubmenu(@"Appearance", appearanceMenu)];

    NSMenu *showSymMenu = submenu(@"Show Symbol");
    [showSymMenu addItem:item(@"Show White Space and TAB", @selector(showWhiteSpaceAndTab:), @"")];
    [showSymMenu addItem:item(@"Show End of Line",        @selector(showEndOfLine:),        @"")];
    [showSymMenu addItem:item(@"Show All Characters",    @selector(toggleShowAllChars:),  @"")];
    [showSymMenu addItem:item(@"Show Indent Guide",      @selector(toggleIndentGuides:),  @"")];
    [showSymMenu addItem:item(@"Show Line Numbers",      @selector(toggleLineNumbers:),   @"")];
    [showSymMenu addItem:item(@"Show Wrap Symbol",        @selector(toggleWrapSymbol:),    @"")];
    addSep(showSymMenu);
    [showSymMenu addItem:item(@"Hide Line Marks (Bookmarks)", @selector(toggleHideLineMarks:), @"")];
    [viewMenu addItem:withSubmenu(@"Show Symbol", showSymMenu)];

    NSMenu *zoomMenu = submenu(@"Zoom");
    [zoomMenu addItem:item(@"Zoom In",              @selector(zoomIn:),    @"+")];
    [zoomMenu addItem:item(@"Zoom Out",             @selector(zoomOut:),   @"-")];
    [zoomMenu addItem:item(@"Restore Default Zoom", @selector(resetZoom:), @"0")];
    [viewMenu addItem:withSubmenu(@"Zoom", zoomMenu)];

    NSMenu *moveCloneMenu = submenu(@"Move/Clone Current Document");
    [moveCloneMenu addItem:item(@"Move to Other Vertical View",    @selector(moveToOtherVerticalView:),    @"")];
    [moveCloneMenu addItem:item(@"Clone to Other Vertical View",   @selector(cloneToOtherVerticalView:),   @"")];
    [moveCloneMenu addItem:[NSMenuItem separatorItem]];
    [moveCloneMenu addItem:item(@"Move to Other Horizontal View",  @selector(moveToOtherHorizontalView:),  @"")];
    [moveCloneMenu addItem:item(@"Clone to Other Horizontal View", @selector(cloneToOtherHorizontalView:), @"")];
    [moveCloneMenu addItem:[NSMenuItem separatorItem]];
    [moveCloneMenu addItem:item(@"Reset View",                     @selector(resetView:),                  @"")];
    [viewMenu addItem:withSubmenu(@"Move/Clone Current Document", moveCloneMenu)];

    NSMenu *tabViewMenu = submenu(@"Tab");
    // ── Tab switching (1st–9th) ──
    [tabViewMenu addItem:item(@"1st Tab", @selector(selectTab1:), @"1")];
    [tabViewMenu addItem:item(@"2nd Tab", @selector(selectTab2:), @"2")];
    [tabViewMenu addItem:item(@"3rd Tab", @selector(selectTab3:), @"3")];
    [tabViewMenu addItem:item(@"4th Tab", @selector(selectTab4:), @"4")];
    [tabViewMenu addItem:item(@"5th Tab", @selector(selectTab5:), @"5")];
    [tabViewMenu addItem:item(@"6th Tab", @selector(selectTab6:), @"6")];
    [tabViewMenu addItem:item(@"7th Tab", @selector(selectTab7:), @"7")];
    [tabViewMenu addItem:item(@"8th Tab", @selector(selectTab8:), @"8")];
    [tabViewMenu addItem:item(@"9th Tab", @selector(selectTab9:), @"9")];
    addSep(tabViewMenu);
    // ── Navigation ──
    [tabViewMenu addItem:item(@"First Tab",    @selector(selectFirstTab:),    @"")];
    [tabViewMenu addItem:item(@"Last Tab",     @selector(selectLastTab:),     @"")];
    // Match the Preferences > Tab Bar checkbox label so the existing
    // localization entry (id=90224) translates this menu item too.
    [tabViewMenu addItem:item(@"Wrap tabs to multiple lines", @selector(toggleTabBarWrap:), @"")];
    {
        unichar pgdn = NSPageDownFunctionKey;
        unichar pgup = NSPageUpFunctionKey;
        NSString *keyPgDn = [NSString stringWithCharacters:&pgdn length:1];
        NSString *keyPgUp = [NSString stringWithCharacters:&pgup length:1];
        [tabViewMenu addItem:itemMod(@"Next Tab",     @selector(selectNextTab:),     keyPgDn,
                                     NSEventModifierFlagControl)];
        [tabViewMenu addItem:itemMod(@"Previous Tab", @selector(selectPreviousTab:), keyPgUp,
                                     NSEventModifierFlagControl)];
        addSep(tabViewMenu);
        // ── Tab movement ──
        [tabViewMenu addItem:item(@"Move to Start",     @selector(moveTabToStart:),    @"")];
        [tabViewMenu addItem:item(@"Move to End",       @selector(moveTabToEnd:),      @"")];
        [tabViewMenu addItem:itemMod(@"Move Tab Forward",  @selector(moveTabForward:),  keyPgDn,
                                     NSEventModifierFlagControl | NSEventModifierFlagShift)];
        [tabViewMenu addItem:itemMod(@"Move Tab Backward", @selector(moveTabBackward:), keyPgUp,
                                     NSEventModifierFlagControl | NSEventModifierFlagShift)];
    }
    addSep(tabViewMenu);
    // ── Per-tab coloring ──
    {
        NSArray *colorNames = @[@"Apply Color 1", @"Apply Color 2", @"Apply Color 3",
                                @"Apply Color 4", @"Apply Color 5"];
        SEL colorSels[] = {@selector(applyTabColor1:), @selector(applyTabColor2:),
                           @selector(applyTabColor3:), @selector(applyTabColor4:),
                           @selector(applyTabColor5:)};
        // Color swatch RGB values matching the tab palette
        NSArray *swatchColors = @[
            [NSColor colorWithRed:0xFC/255.0 green:0xE3/255.0 blue:0x86/255.0 alpha:1], // Yellow
            [NSColor colorWithRed:0xA9/255.0 green:0xF0/255.0 blue:0x8C/255.0 alpha:1], // Green
            [NSColor colorWithRed:0x7A/255.0 green:0xC9/255.0 blue:0xF5/255.0 alpha:1], // Blue
            [NSColor colorWithRed:0xF5/255.0 green:0xB6/255.0 blue:0x7A/255.0 alpha:1], // Orange
            [NSColor colorWithRed:0xF0/255.0 green:0x8C/255.0 blue:0xF0/255.0 alpha:1], // Pink
        ];
        for (int i = 0; i < 5; i++) {
            NSMenuItem *ci = item(colorNames[i], colorSels[i], @"");
            // Create a small colored square image as the menu item icon
            NSImage *swatch = [[NSImage alloc] initWithSize:NSMakeSize(12, 12)];
            [swatch lockFocus];
            [swatchColors[i] setFill];
            NSRectFill(NSMakeRect(1, 1, 10, 10));
            [[NSColor grayColor] setStroke];
            [NSBezierPath strokeRect:NSMakeRect(0.5, 0.5, 11, 11)];
            [swatch unlockFocus];
            ci.image = swatch;
            [tabViewMenu addItem:ci];
        }
        [tabViewMenu addItem:item(@"Remove Color", @selector(removeTabColor:), @"")];
    }
    [viewMenu addItem:withSubmenu(@"Tab", tabViewMenu)];

    [viewMenu addItem:item(@"Word Wrap",           @selector(toggleWordWrap:), @"")];
    [viewMenu addItem:item(@"Focus on Another View", @selector(focusOnAnotherView:), @"")];
    [viewMenu addItem:item(@"Hide Lines", @selector(hideLinesInSelection:), @"")];
    addSep(viewMenu);

    [viewMenu addItem:item(@"Fold All",            @selector(foldAll:),          @"")];
    [viewMenu addItem:item(@"Unfold All",           @selector(unfoldAll:),        @"")];
    [viewMenu addItem:item(@"Fold Current Level",   @selector(foldCurrentLevel:), @"")];
    [viewMenu addItem:item(@"Unfold Current Level", @selector(unfoldCurrentLevel:), @"")];

    // Fold Level / Unfold Level 1-8
    SEL foldSels[8]   = { @selector(foldLevel1:),   @selector(foldLevel2:),   @selector(foldLevel3:),
                          @selector(foldLevel4:),   @selector(foldLevel5:),   @selector(foldLevel6:),
                          @selector(foldLevel7:),   @selector(foldLevel8:) };
    SEL unfoldSels[8] = { @selector(unfoldLevel1:), @selector(unfoldLevel2:), @selector(unfoldLevel3:),
                          @selector(unfoldLevel4:), @selector(unfoldLevel5:), @selector(unfoldLevel6:),
                          @selector(unfoldLevel7:), @selector(unfoldLevel8:) };
    NSMenu *foldLvlMenu = submenu(@"Fold Level");
    NSMenu *unfoldLvlMenu = submenu(@"Unfold Level");
    for (int i = 0; i < 8; i++) {
        [foldLvlMenu   addItem:item([NSString stringWithFormat:@"Fold Level %d",   i+1], foldSels[i],   @"")];
        [unfoldLvlMenu addItem:item([NSString stringWithFormat:@"Unfold Level %d", i+1], unfoldSels[i], @"")];
    }
    [viewMenu addItem:withSubmenu(@"Fold Level",   foldLvlMenu)];
    [viewMenu addItem:withSubmenu(@"Unfold Level", unfoldLvlMenu)];
    addSep(viewMenu);

    [viewMenu addItem:item(@"Summary…", @selector(showSummary:), @"")];
    addSep(viewMenu);

    [viewMenu addItem:item(@"Project Panels", @selector(showProjectPanel1:), @"")];

    // "Folder Tree" panel is now accessed via File > Open Folder as Workspace
    [viewMenu addItem:item(@"Document Map",         @selector(showDocumentMap:),        @"")];
    [viewMenu addItem:item(@"Document List",        @selector(showDocumentList:),       @"")];
    [viewMenu addItem:item(@"Function List",        @selector(showFunctionList:),       @"")];
    [viewMenu addItem:item(@"Git",                  @selector(showGitPanel:),           @"")];
    addSep(viewMenu);
    [viewMenu addItem:item(@"Spell Check",          @selector(toggleSpellCheck:),       @"")];
    addSep(viewMenu);

    [viewMenu addItem:item(@"Synchronize Vertical Scrolling",   @selector(toggleSyncVerticalScrolling:),   @"")];
    [viewMenu addItem:item(@"Synchronize Horizontal Scrolling", @selector(toggleSyncHorizontalScrolling:), @"")];
    addSep(viewMenu);
    [viewMenu addItem:item(@"Text Direction RTL",    @selector(setTextDirectionRTL:), @"")];
    [viewMenu addItem:item(@"Text Direction LTR",    @selector(setTextDirectionLTR:), @"")];
    addSep(viewMenu);
    [viewMenu addItem:item(@"Monitoring (tail -f)", @selector(toggleMonitoring:),    @"")];

    // ── Language ──────────────────────────────────────────────────────────────
    NSMenuItem *langMenuTop = [[NSMenuItem alloc] init];
    langMenuTop.tag = kMenuTagLanguage; // localization-stable lookup key
    [main addItem:langMenuTop];
    langMenuTop.submenu = buildLanguageMenu();
    langMenuTop.submenu.title = @"Language";

    // ── Macro ─────────────────────────────────────────────────────────────────
    NSMenuItem *macroItem = [[NSMenuItem alloc] init];
    macroItem.tag = kMenuTagMacro; // used by rebuildMacroMenu to find this menu
    [main addItem:macroItem];
    NSMenu *macroMenu = submenu(@"Macro");
    macroItem.submenu = macroMenu;

    [macroMenu addItem:itemMod(@"Start Recording", @selector(startMacroRecording:), @"r",
                               NSEventModifierFlagCommand | NSEventModifierFlagShift)];
    [macroMenu addItem:itemMod(@"Stop Recording",  @selector(stopMacroRecording:), @"r",
                               NSEventModifierFlagCommand | NSEventModifierFlagShift)];
    [macroMenu addItem:itemMod(@"Playback",        @selector(runMacro:), @"m",
                               NSEventModifierFlagCommand | NSEventModifierFlagShift)];
    [macroMenu addItem:item(@"Save Current Recorded Macro…", @selector(saveCurrentMacro:), @"")];
    addSep(macroMenu);
    [macroMenu addItem:item(@"Run a Macro Multiple Times…", @selector(runMacroMultipleTimes:), @"")];
    [macroMenu addItem:item(@"Run Macro on Files…", @selector(showBatchRunDialog:), @"")];
    addSep(macroMenu);
    {
        NSMenuItem *trimItem = item(@"Trim Trailing Space and Save", @selector(trimTrailingSpaceAndSave:), @"");
        trimItem.tag = 9901;  // marker: saved macros inserted after this item
        [macroMenu addItem:trimItem];
    }
    addSep(macroMenu);
    [macroMenu addItem:item(@"Modify Shortcut/Delete Macro…", @selector(showShortcutMapperMacros:), @"")];

    // ── Run ───────────────────────────────────────────────────────────────────
    NSMenuItem *runItem = [[NSMenuItem alloc] init];
    runItem.tag = kMenuTagRun; // used by rebuildRunMenu to find this menu
    [main addItem:runItem];
    NSMenu *runMenu = submenu(@"Run");
    runItem.submenu = runMenu;

    [runMenu addItem:item(@"Run…", @selector(showRunDialog:), @"")];
    addSep(runMenu);
    // User-defined commands inserted here by rebuildRunMenu
    addSep(runMenu);
    [runMenu addItem:item(@"Modify Shortcut/Delete Command…", @selector(showShortcutMapperRunCmds:), @"")];

    // ── Plugins ───────────────────────────────────────────────────────────────
    NSMenuItem *pluginsItem = [[NSMenuItem alloc] init];
    pluginsItem.tag = kMenuTagPlugins; // localization-stable lookup key
    [main addItem:pluginsItem];
    NSMenu *pluginsMenu = submenu(@"Plugins");
    pluginsItem.submenu = pluginsMenu;

    NSMenu *mimeMenu = submenu(@"MIME Tools");
    [mimeMenu addItem:item(@"Base64 Encode",            @selector(base64Encode:), @"")];
    [mimeMenu addItem:item(@"Base64 Decode",            @selector(base64Decode:), @"")];
    [mimeMenu addItem:item(@"Base64 Encode with Padding", @selector(base64EncodeWithPadding:), @"")];
    [mimeMenu addItem:item(@"Base64 Decode (Strict Mode)", @selector(base64DecodeStrict:),    @"")];
    addSep(mimeMenu);
    [mimeMenu addItem:item(@"Base64 URL-Safe Encode", @selector(base64URLSafeEncode:), @"")];
    [mimeMenu addItem:item(@"Base64 URL-Safe Decode", @selector(base64URLSafeDecode:), @"")];
    [pluginsMenu addItem:withSubmenu(@"MIME Tools", mimeMenu)];

    NSMenu *convMenu = submenu(@"Converter");
    [convMenu addItem:item(@"ASCII to Hex", @selector(asciiToHex:), @"")];
    [convMenu addItem:item(@"Hex to ASCII", @selector(hexToAscii:), @"")];
    [pluginsMenu addItem:withSubmenu(@"Converter", convMenu)];

    NSMenu *md5Menu = submenu(@"MD5");
    [md5Menu addItem:item(@"Generate",                             @selector(hashMD5Generate:),    @"")];
    [md5Menu addItem:item(@"Generate from Files…", @selector(hashMD5FromFiles:), @"")];
    [md5Menu addItem:item(@"Generate from Selection into Clipboard", @selector(hashMD5ToClipboard:), @"")];
    [pluginsMenu addItem:withSubmenu(@"MD5", md5Menu)];

    NSMenu *sha1Menu = submenu(@"SHA-1");
    [sha1Menu addItem:item(@"Generate",                              @selector(hashSHA1Generate:),    @"")];
    [sha1Menu addItem:item(@"Generate from Files…", @selector(hashSHA1FromFiles:), @"")];
    [sha1Menu addItem:item(@"Generate from Selection into Clipboard",  @selector(hashSHA1ToClipboard:), @"")];
    [pluginsMenu addItem:withSubmenu(@"SHA-1", sha1Menu)];

    NSMenu *sha256Menu = submenu(@"SHA-256");
    [sha256Menu addItem:item(@"Generate",                            @selector(hashSHA256Generate:),    @"")];
    [sha256Menu addItem:item(@"Generate from Files…", @selector(hashSHA256FromFiles:), @"")];
    [sha256Menu addItem:item(@"Generate from Selection into Clipboard", @selector(hashSHA256ToClipboard:), @"")];
    [pluginsMenu addItem:withSubmenu(@"SHA-256", sha256Menu)];

    NSMenu *sha512Menu = submenu(@"SHA-512");
    [sha512Menu addItem:item(@"Generate",                            @selector(hashSHA512Generate:),    @"")];
    [sha512Menu addItem:item(@"Generate from Files…", @selector(hashSHA512FromFiles:), @"")];
    [sha512Menu addItem:item(@"Generate from Selection into Clipboard", @selector(hashSHA512ToClipboard:), @"")];
    [pluginsMenu addItem:withSubmenu(@"SHA-512", sha512Menu)];

    addSep(pluginsMenu);
    [pluginsMenu addItem:item(@"Plugins Admin…",       @selector(showPluginsAdmin:),  @"")];
    [pluginsMenu addItem:item(@"Open Plugins Folder…", @selector(openPluginsFolder:), @"")];
    addSep(pluginsMenu);
    [pluginsMenu addItem:item(@"Import Plugin(s)…",    @selector(importPlugin:),      @"")];

    // ── Window ────────────────────────────────────────────────────────────────
    NSMenuItem *winItem = [[NSMenuItem alloc] init];
    [main addItem:winItem];
    NSMenu *winMenu = submenu(@"Window");
    winItem.submenu = winMenu;

    NSMenu *sortByMenu = submenu(@"Sort By");
    [sortByMenu addItem:item(@"File Name A to Z",  @selector(sortTabsByFileNameAsc:),  @"")];
    [sortByMenu addItem:item(@"File Name Z to A",  @selector(sortTabsByFileNameDesc:), @"")];
    [sortByMenu addItem:item(@"File Type A to Z",  @selector(sortTabsByFileTypeAsc:),  @"")];
    [sortByMenu addItem:item(@"File Type Z to A",  @selector(sortTabsByFileTypeDesc:), @"")];
    [sortByMenu addItem:item(@"Full Path A to Z",  @selector(sortTabsByFullPathAsc:),  @"")];
    [sortByMenu addItem:item(@"Full Path Z to A",  @selector(sortTabsByFullPathDesc:), @"")];
    [winMenu addItem:withSubmenu(@"Sort By", sortByMenu)];

    [winMenu addItem:item(@"Windows…", @selector(showWindowsList:), @"")];
    [winMenu addItem:item(@"New Window", @selector(openNewWindow:), @"N")];
    addSep(winMenu);
    [winMenu addItem:item(@"Minimize", @selector(performMiniaturize:), @"m")];
    [winMenu addItem:item(@"Zoom",     @selector(performZoom:),        @"")];
    addSep(winMenu);
    [winMenu addItem:itemMod(@"Select Next Tab",     @selector(selectNextTab:),     @"\t",
                             NSEventModifierFlagControl)];
    [winMenu addItem:itemMod(@"Select Previous Tab", @selector(selectPreviousTab:), @"\t",
                             NSEventModifierFlagControl | NSEventModifierFlagShift)];
    [NSApp setWindowsMenu:winMenu];

    // ── Help ──────────────────────────────────────────────────────────────────
    NSMenuItem *helpItem = [[NSMenuItem alloc] init];
    [main addItem:helpItem];
    NSMenu *helpMenu = submenu(@"Help");
    helpItem.submenu = helpMenu;
    [NSApp setHelpMenu:helpMenu];

    [helpMenu addItem:item(@"Command Line Arguments…", @selector(showCLIHelp:), @"")];
    addSep(helpMenu);
    [helpMenu addItem:item(@"Nextpad++ macOS Home",              @selector(openNppHome:),        @"")];
    [helpMenu addItem:item(@"Nextpad++ macOS Project Page",      @selector(openNppProjectPage:), @"")];
    [helpMenu addItem:item(@"Online User Manual",@selector(openNppManual:),      @"")];
    // Commented out — community forum URL not yet established for the
    // rebranded project. Re-enable once a forum is set up.
    // [helpMenu addItem:item(@"Nextpad++ Community (Forum)", @selector(openNppForum:),       @"")];
    addSep(helpMenu);
    [helpMenu addItem:item(@"Debug Info…", @selector(showDebugInfo:), @"")];
}

+ (void)insertPluginMenuItems:(NSArray<NSMenuItem *> *)items {
    if (items.count == 0) return;

    // Find the Plugins menu — search by the showPluginsAdmin: action since
    // the menu title may have been changed by the localizer.
    NSMenu *mainMenu = [NSApp mainMenu];
    NSMenu *pluginsMenu = nil;
    for (NSMenuItem *mi in mainMenu.itemArray) {
        if (!mi.hasSubmenu) continue;
        NSMenu *sub = mi.submenu;
        for (NSInteger j = 0; j < sub.numberOfItems; j++) {
            if ([sub itemAtIndex:j].action == @selector(showPluginsAdmin:)) {
                pluginsMenu = sub;
                break;
            }
        }
        if (pluginsMenu) break;
    }
    if (!pluginsMenu) {
        NSLog(@"[MenuBuilder] Could not find Plugins menu — plugin menu items not inserted");
        return;
    }

    // Find "Plugins Admin…" (or its localized equivalent) by action selector.
    // Insert before the separator that precedes it.
    NSInteger insertIndex = pluginsMenu.numberOfItems;
    for (NSInteger i = 0; i < pluginsMenu.numberOfItems; i++) {
        NSMenuItem *mi = [pluginsMenu itemAtIndex:i];
        if (mi.action == @selector(showPluginsAdmin:)) {
            // Step back past the separator that precedes "Plugins Admin…"
            insertIndex = (i > 0 && [pluginsMenu itemAtIndex:i - 1].isSeparatorItem) ? i - 1 : i;
            break;
        }
    }

    // Add a separator before the dynamically loaded plugin items
    [pluginsMenu insertItem:[NSMenuItem separatorItem] atIndex:insertIndex];
    insertIndex++;

    // Insert each plugin's submenu
    for (NSMenuItem *pi in items) {
        [pluginsMenu insertItem:pi atIndex:insertIndex];
        insertIndex++;
    }

    NSLog(@"[MenuBuilder] Inserted %lu plugin menu item(s)", (unsigned long)items.count);
}

@end
