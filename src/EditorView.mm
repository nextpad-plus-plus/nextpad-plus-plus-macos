#import "EditorView.h"
#import "NppPaths.h"
#import "NppApplication.h"
#import "NppLangsManager.h"
#import "UserDefineLangManager.h"
#import "NppBuiltinLanguages.h"
#import "NppPluginManager.h"
#import "PreferencesWindowController.h"
#import "SearchEngine.h"   // #166 Phase 1: replay Windows Find/Replace (type-3) macros

// NPPN_* constants (from NppPluginInterfaceMac.h — not included directly
// to avoid SendMessage macro conflicts in host code)
#ifndef NPPN_FILESAVED
#define NPPN_FILESAVED      1008
#define NPPN_LANGCHANGED    1011
#endif
#import "StyleConfiguratorWindowController.h"
#import "GitHelper.h"
#import "Scintilla.h"
#import "ScintillaMessages.h"
#include "SciLexer.h"
#include <CommonCrypto/CommonDigest.h>
#include <vector>

NSNotificationName const EditorViewCursorDidMoveNotification = @"EditorViewCursorDidMoveNotification";
NSNotificationName const EditorViewDidGainFocusNotification  = @"EditorViewDidGainFocusNotification";
NSNotificationName const EditorViewDidSaveNotification        = @"EditorViewDidSaveNotification";
NSNotificationName const EditorViewDidScrollNotification = @"EditorViewDidScrollNotification";

// Forward-declare Lexilla's CreateLexer (statically linked)
namespace Scintilla { struct ILexer5; }
extern "C" Scintilla::ILexer5 *CreateLexer(const char *name);

/// Returns YES if the named theme belongs to the explicit "dark fold margin" list.
/// These themes get fold-margin bg = Default Style background; all others get #f2f2f2.
static BOOL foldMarginUsesEditorBg(NSString *themeName) {
    static NSSet<NSString *> *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"Bespin", @"Black board", @"Choco", @"DansLeRuSH-Dark",
            @"DarkModeDefault", @"Deep Black", @"HotFudgeSundae", @"Mono Industrial",
            @"Monokai", @"MossyLawn", @"Obsidian", @"Plastic Code Wrap",
            @"Ruby Blue", @"Solarized", @"Twilight", @"Vibrant Ink",
            @"vim Dark Blue", @"Zenburn"
        ]];
    });
    return themeName && [s containsObject:themeName];
}

/// Read the Default Style bgColor hex directly from the theme XML and return as a
/// Scintilla BGR integer.  Bypasses NSColor entirely to avoid color-space shifts.
/// Returns -1 if the theme XML or bgColor attribute is not found.
static sptr_t foldMarginBGRForTheme(NSString *themeName) {
    static NSString *const kDefault = @"Default (stylers.xml)";
    NSURL *url;
    if (!themeName || [themeName isEqualToString:kDefault]) {
        url = [[NSBundle mainBundle] URLForResource:@"stylers.model" withExtension:@"xml"];
    } else {
        url = [[NSBundle mainBundle] URLForResource:themeName
                                     withExtension:@"xml"
                                      subdirectory:@"themes"];
    }
    if (!url) return -1;
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return -1;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:nil];
    if (!doc) return -1;
    NSArray<NSXMLElement *> *nodes =
        [doc nodesForXPath:@"//GlobalStyles/WidgetStyle[@name='Default Style']" error:nil];
    NSString *bgHex = [[nodes.firstObject attributeForName:@"bgColor"] stringValue];
    if (bgHex.length < 6) return -1;
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:bgHex] scanHexInt:&rgb];
    uint8_t r = (rgb >> 16) & 0xFF;
    uint8_t g = (rgb >>  8) & 0xFF;
    uint8_t b =  rgb        & 0xFF;
    return ((sptr_t)b << 16) | ((sptr_t)g << 8) | r;  // BGR for Scintilla
}

// Language name → Lexilla lexer name
static NSDictionary<NSString *, NSString *> *languageLexerNameMap() {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Single source of truth: derive every entry from the Windows-derived
        // built-in language table (NppBuiltinLanguages.mm). Guarantees the menu,
        // the open-by-extension path, and session-restore all resolve to the
        // same lexer for every built-in language. Issue #144 follow-up.
        NSUInteger count = 0;
        const NppBuiltinLang *langs = NppBuiltinLanguagesAll(&count);
        NSMutableDictionary *m = [NSMutableDictionary dictionaryWithCapacity:count + 1];
        for (NSUInteger i = 0; i < count; i++) {
            m[@(langs[i].internalName)] = @(langs[i].lexerID);
        }
        // Backwards-compat alias: pre-overhaul sessions / extension map may
        // have stored "javascript" (Windows' L_JS_EMBEDDED internal name) as a
        // tab's language. Route it to the same lexer as L_JAVASCRIPT so old
        // sessions still highlight; the canonical name going forward is
        // "javascript.js" (matches the Windows Language menu entry).
        m[@"javascript"] = @"cpp";
        map = [m copy];
    });
    return map;
}

// File extension → language name.
// Merges langs.xml data on top of hardcoded defaults.
static NSDictionary<NSString *, NSString *> *extensionLanguageMap() {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [@{
            // C-family
            @"c"    : @"c",       @"h"    : @"c",
            @"cpp"  : @"cpp",     @"cxx"  : @"cpp",
            @"cc"   : @"cpp",     @"hpp"  : @"cpp",  @"hxx" : @"cpp",
            @"m"    : @"objc",    @"mm"   : @"objc",
            @"cs"   : @"cs",
            @"java" : @"java",
            // Use "javascript.js" (Windows L_JAVASCRIPT internal name) so the
            // open-by-extension result matches the Language menu's "JavaScript"
            // entry — keeps the active-language checkmark correct. The lexer
            // map keeps "javascript" as a backwards-compat alias.
            @"js"   : @"javascript.js", @"mjs"  : @"javascript.js", @"jsx" : @"javascript.js",
            @"ts"   : @"typescript", @"tsx" : @"typescript",
            @"swift": @"swift",
            @"rc"   : @"rc",
            @"as"   : @"actionscript",
            // Web
            @"html" : @"html",    @"htm"  : @"html",
            @"asp"  : @"asp",     @"aspx" : @"asp",
            @"xml"  : @"xml",     @"xsl"  : @"xml",  @"xslt": @"xml",
            @"svg"  : @"xml",     @"plist": @"xml",
            @"css"  : @"css",     @"scss" : @"css",   @"less": @"css",
            @"json" : @"json",
            @"php"  : @"php",
            // Scripting
            @"py"   : @"python",  @"pyw"  : @"python",
            @"rb"   : @"ruby",    @"rake" : @"ruby",  @"gemspec": @"ruby",
            @"pl"   : @"perl",    @"pm"   : @"perl",
            @"lua"  : @"lua",
            @"sh"   : @"bash",    @"bash" : @"bash",  @"zsh" : @"bash",
            @"ps1"  : @"powershell", @"psm1": @"powershell",
            @"bat"  : @"batch",   @"cmd"  : @"batch",
            @"tcl"  : @"tcl",
            @"r"    : @"r",       @"R"    : @"r",
            @"coffee": @"coffeescript",
            // Systems
            @"rs"   : @"rust",
            @"go"   : @"go",
            @"d"    : @"d",
            // Markup / Config
            // .md/.markdown intentionally NOT mapped here — markdown is no
            // longer a built-in language; the preinstalled Markdown UDL
            // (~/Library/Application Support/Nextpad++/userDefineLangs/markdown._preinstalled.udl.xml)
            // claims these extensions and is resolved via the UDL fallback
            // in loadFileAtPath:. Mapping them to "markdown" here would
            // shadow that fallback and leave the file plain (issue #130
            // follow-up to the Windows-table menu overhaul).
            @"tex"  : @"latex",   @"latex": @"latex",
            @"yml"  : @"yaml",    @"yaml" : @"yaml",
            @"toml" : @"toml",
            @"ini"  : @"ini",     @"cfg"  : @"ini",   @"conf": @"ini",
            @"properties": @"props",
            @"makefile": @"makefile", @"mk": @"makefile",
            @"cmake": @"cmake",
            @"diff" : @"diff",    @"patch": @"diff",
            @"reg"  : @"registry",
            @"nsi"  : @"nsis",    @"nsh"  : @"nsis",
            @"iss"  : @"inno",
            // Database
            @"sql"  : @"sql",
            // Scientific
            @"f"    : @"fortran", @"f90"  : @"fortran", @"f95": @"fortran",
            @"f77"  : @"fortran77",
            @"pas"  : @"pascal",  @"pp"   : @"pascal",
            @"hs"   : @"haskell", @"lhs"  : @"haskell",
            @"ml"   : @"caml",    @"mli"  : @"caml",
            @"erl"  : @"erlang",
            @"nim"  : @"nim",
            @"gd"   : @"gdscript",
            @"sas"  : @"sas",
            // Hardware
            @"vhd"  : @"vhdl",    @"vhdl" : @"vhdl",
            @"v"    : @"verilog", @"sv"   : @"verilog",
            @"asm"  : @"asm",     @"s"    : @"asm",
            // Other
            @"ada"  : @"ada",     @"adb"  : @"ada",   @"ads": @"ada",
            @"cob"  : @"cobol",   @"cbl"  : @"cobol",
            @"vb"   : @"vb",      @"vbs"  : @"vb",    @"bas": @"vb",
            @"au3"  : @"autoit",
            @"ps"   : @"postscript", @"eps": @"postscript",
            @"mat"  : @"matlab",
        } mutableCopy];

        // Merge extensions from langs.xml (overrides hardcoded on conflict)
        NSDictionary *langsMap = [[NppLangsManager shared] extensionMap];
        [m addEntriesFromDictionary:langsMap];

        map = [m copy];
    });
    return map;
}

// Mirrors NPP's per-buffer ID — gives each untitled tab a unique number ("new 1", "new 2" …)
static NSInteger _untitledCounter = 0;

// Map a CFStringBuiltInEncoding to NSStringEncoding (short alias for CFStringConvertEncodingToNSStringEncoding)
static inline NSStringEncoding nppEnc(CFStringEncoding cf) {
    return CFStringConvertEncodingToNSStringEncoding(cf);
}

// Normalize an encoding returned by +[NSString stringEncodingForData:] to the
// constant our Encoding menu uses, so the auto-detected status-bar label and the
// menu's check state stay consistent (the reverse name-map already covers these
// canonical constants — no extra map entries needed). The detector returns CJK
// *variants* (GB18030, cp950/DOSChineseTrad, cp932/DOSJapanese, …) that aren't the
// same NSStringEncoding values as the menu items. Returns 0 when there's no mapping
// (caller then keeps the detected encoding as-is). Note: the decoded *content* is
// always taken from the detector's own decode, so normalizing here never corrupts
// what is loaded — it only affects the label and the encoding used for a re-save.
static NSStringEncoding canonicalCJKEncoding(NSStringEncoding ns) {
    switch (CFStringConvertNSStringEncodingToEncoding(ns)) {
        // Simplified Chinese family → GBK (shown as "GB2312", matching Windows CP936)
        case kCFStringEncodingGB_18030_2000:
        case kCFStringEncodingGBK_95:
        case kCFStringEncodingGB_2312_80:
        case kCFStringEncodingEUC_CN:
        case kCFStringEncodingHZ_GB_2312:
            return nppEnc(kCFStringEncodingGBK_95);
        // Traditional Chinese family → Big5
        case kCFStringEncodingBig5:
        case kCFStringEncodingBig5_HKSCS_1999:
        case kCFStringEncodingBig5_E:
        case kCFStringEncodingDOSChineseTrad:
            return nppEnc(kCFStringEncodingBig5);
        // Japanese family → Shift-JIS
        case kCFStringEncodingShiftJIS:
        case kCFStringEncodingShiftJIS_X0213:
        case kCFStringEncodingDOSJapanese:
            return nppEnc(kCFStringEncodingShiftJIS);
        // Korean family → EUC-KR
        case kCFStringEncodingEUC_KR:
        case kCFStringEncodingDOSKorean:
        case kCFStringEncodingKSC_5601_87:
            return nppEnc(kCFStringEncodingEUC_KR);
        default:
            return 0;
    }
}

// Files larger than the threshold get a warning + large-file mode (no syntax,
// no undo, plus per-feature gates from Performance prefs). When the user has
// disabled "Enable Large File Restriction" entirely, returns SIZE_MAX so no
// file ever crosses the threshold.
static NSUInteger nppLargeFileThreshold(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (![ud boolForKey:kPrefLargeFileEnabled]) return NSUIntegerMax;
    NSInteger mb = [ud integerForKey:kPrefLargeFileSizeMB];
    if (mb < 1)    mb = 1;
    if (mb > 2046) mb = 2046;
    return (NSUInteger)mb * 1024UL * 1024UL;
}

@implementation EditorView {
    BOOL    _isModified;
    NSStringEncoding _fileEncoding;
    BOOL    _hasBOM;
    BOOL    _largeFileMode;
    BOOL    _wordWrapEnabled;
    BOOL    _savedWrapBeforeRTL;  // word wrap state before RTL was enabled
    BOOL    _scintillaOverridesApplied;  // YES once Scintilla-command overrides were pushed to this editor's keymap
    BOOL    _isRecordingMacro;
    NSMutableArray<NSDictionary *> *_macroActions;
    NSInteger _untitledIndex;   // unique number for untitled tabs (1-based)
    sptr_t    _lastBracePos;    // cached: last brace position highlighted (-1 = none)
    sptr_t    _lastMatchPos;    // cached: last matching brace position (-1 = none)

    // Begin/End Select state (per-editor)
    sptr_t _beginSelectPos;
    BOOL   _beginSelectActive;

    // External file-change monitoring (polling — avoids FSEvents timing issues)
    NSTimer           *_fileMonitorTimer;
    NSDate            *_lastKnownModDate; // mtime recorded after each load/save
    BOOL               _externalChangePending;
    BOOL               _monitoringMode;   // tail -f: auto-reload silently

    // Spell check
    BOOL               _spellCheckEnabled;
    NSTimer           *_spellTimer;
    NSInteger          _spellTag;

    // Git gutter state
    BOOL               _gitGutterEnabled;

    // Hex view
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _fileEncoding = NSUTF8StringEncoding;
        _currentLanguage = @"";
        _untitledIndex = ++_untitledCounter;
        _lastBracePos = INVALID_POSITION;
        _lastMatchPos = INVALID_POSITION;
        _spellTag = [NSSpellChecker uniqueSpellDocumentTag];
        [self setup];
    }
    return self;
}

- (void)setup {
    _scintillaView = [[ScintillaView alloc] initWithFrame:self.bounds];
    _scintillaView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scintillaView.delegate = self;
    [self addSubview:_scintillaView];

    // Use legacy-style scrollers (shows arrows) and auto-hide when content fits.
    [self _applyLegacyScrollerStyle];

    // Re-apply if the system scroller-style preference changes.
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(_scrollerStyleChanged:)
               name:NSPreferredScrollerStyleDidChangeNotification object:nil];

    // The drag registration is on SCIContentView (the inner view), not ScintillaView itself.
    // Strip NSPasteboardTypeFileURL and NSFilenamesPboardType from it so file drops
    // bubble up to the NppDropView container which handles opening the files.
    NSView *contentView = [_scintillaView content];
    NSMutableArray *dragTypes = [contentView.registeredDraggedTypes mutableCopy];
    [dragTypes removeObject:NSPasteboardTypeFileURL];
    [dragTypes removeObject:NSFilenamesPboardType];
    [contentView unregisterDraggedTypes];
    if (dragTypes.count) [contentView registerForDraggedTypes:dragTypes];

    [self applyDefaultTheme];

    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(_preferencesChanged:)
               name:@"NPPPreferencesChanged" object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_fileMonitorTimer invalidate];
}

- (void)prepareForClose {
    [_fileMonitorTimer invalidate];
    _fileMonitorTimer = nil;
    [_spellTimer invalidate];
    _spellTimer = nil;

    // If this is a clone, release the shared document reference and unlink sibling.
    if (_cloneSibling) {
        sptr_t docPtr = [_scintillaView message:SCI_GETDOCPOINTER];
        // Set this view to a fresh empty document before releasing the shared one,
        // so that SCI_RELEASEDOCUMENT doesn't free a document we're still pointing at.
        [_scintillaView message:SCI_SETDOCPOINTER wParam:0 lParam:0];
        [_scintillaView message:SCI_RELEASEDOCUMENT wParam:0 lParam:docPtr];
        _cloneSibling.cloneSibling = nil;
        _cloneSibling = nil;
    }
}


#pragma mark - Content copy

- (void)loadContentFromEditor:(EditorView *)source {
    intptr_t len = [source.scintillaView message:SCI_GETLENGTH];
    char *buf = (char *)malloc((size_t)len + 1);
    if (!buf) return;
    [source.scintillaView message:SCI_GETTEXT wParam:(uptr_t)(len + 1) lParam:(sptr_t)buf];
    [_scintillaView message:SCI_SETTEXT wParam:0 lParam:(sptr_t)buf];
    free(buf);
}

- (void)shareDocumentFrom:(EditorView *)source {
    // Get the source's document pointer and add a reference so it stays alive.
    sptr_t docPtr = [source.scintillaView message:SCI_GETDOCPOINTER];
    [_scintillaView message:SCI_ADDREFDOCUMENT wParam:0 lParam:docPtr];
    // Point this view at the shared document (releases the old default document).
    [_scintillaView message:SCI_SETDOCPOINTER wParam:0 lParam:docPtr];

    // Copy editor metadata so the clone looks and behaves like the source.
    _filePath = [source.filePath copy];
    _fileEncoding = source->_fileEncoding;
    _hasBOM = source->_hasBOM;
    _isModified = source->_isModified;
    _largeFileMode = source->_largeFileMode;
    if (source.currentLanguage.length)
        [self setLanguage:source.currentLanguage];

    // Establish bidirectional sibling link.
    self.cloneSibling = source;
    source.cloneSibling = self;
}

#pragma mark - File I/O

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error {
    // ── Stat once — used for large-file guard AND mtime recording ─────────────
    NSDictionary *attrs = [[NSFileManager defaultManager]
                           attributesOfItemAtPath:path error:nil];
    NSUInteger fileSize = 0;
    if (attrs) fileSize = (NSUInteger)[attrs[NSFileSize] unsignedLongLongValue];

    BOOL large = (fileSize > nppLargeFileThreshold());
    if (large) {
        // The 2 GB suppress-warning toggle silences the dialog ONLY for files
        // ≥2 GB — smaller large files still prompt the user, since the prompt
        // there is more about "you're about to lose syntax/undo" than
        // "this might hang the app." Matches Windows NPP behavior.
        BOOL suppress2GB = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefLargeFileSuppress2GBWarning]
                           && fileSize >= (2ULL * 1024 * 1024 * 1024);
        if (!suppress2GB) {
            NSString *sizeMB = [NSString stringWithFormat:@"%.0f MB",
                                fileSize / (1024.0 * 1024.0)];
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Large File Warning";
            alert.informativeText = [NSString stringWithFormat:
                @"This file is %@. Opening it will disable syntax highlighting "
                @"and undo history to keep the app responsive.\n\n"
                @"Do you want to continue?", sizeMB];
            [alert addButtonWithTitle:@"Open Anyway"];
            [alert addButtonWithTitle:@"Cancel"];
            alert.alertStyle = NSAlertStyleWarning;
            if ([alert runModal] != NSAlertFirstButtonReturn) {
                if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                                        code:NSUserCancelledError
                                                    userInfo:nil];
                return NO;
            }
        }
    }

    // Use memory-mapped I/O for large files — OS pages in only what's needed.
    NSDataReadingOptions readOpts = large ? NSDataReadingMappedIfSafe : 0;
    NSData *rawData = [NSData dataWithContentsOfFile:path
                                             options:readOpts
                                               error:error];
    if (!rawData) return NO;

    NSStringEncoding enc = NSUTF8StringEncoding;
    BOOL hasBOM = NO;
    NSData *textData = rawData;
    const uint8_t *b = (const uint8_t *)rawData.bytes;
    NSUInteger len = rawData.length;

    // BOM detection (matches NPP Utf8_16.cpp k_Boms)
    if (len >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
        enc = NSUTF8StringEncoding;
        hasBOM = YES;
        textData = [rawData subdataWithRange:NSMakeRange(3, len - 3)];
    } else if (len >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
        enc = NSUTF16LittleEndianStringEncoding;
        hasBOM = YES;
        textData = [rawData subdataWithRange:NSMakeRange(2, len - 2)];
    } else if (len >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
        enc = NSUTF16BigEndianStringEncoding;
        hasBOM = YES;
        textData = [rawData subdataWithRange:NSMakeRange(2, len - 2)];
    }

    // ── Convert to UTF-8 bytes for Scintilla (Phase 2 optimised) ─────────────
    // We must avoid [ScintillaView setString:] because it calls SCI_SETTEXT
    // which uses strlen() and truncates at the first null byte. Instead pass
    // a UTF-8 NSData payload to SCI_ADDTEXT with explicit length.
    //
    // Phase 2 rules:
    //   • Small files: full UTF-8 validation pass + Win-1252 / Latin-1
    //     fallbacks (cheap on small inputs, matches NPP-Win behaviour).
    //   • Large files (>=threshold): head/tail UTF-8 probe instead of a
    //     full-file walk. If both 1 MB ends decode as UTF-8 we treat the
    //     whole thing as UTF-8 and pass mmap'd bytes straight to Scintilla.
    //     Probe boundaries are slid off any UTF-8 continuation byte.
    //   • Huge non-UTF-8 file: byte-pass-through as Latin-1 (no full-file
    //     conversion). Bytes >= 0x80 may render as U+FFFD; user already
    //     accepted "no syntax highlighting" for this file.
    NSData *utf8Data = nil;

    if (hasBOM && enc != NSUTF8StringEncoding) {
        // BOM-detected UTF-16: convert to UTF-8 via NSString. UTF-16-BOM'd
        // multi-GB files exist but are vanishingly rare; we accept the cost.
        NSString *content = [[NSString alloc] initWithData:textData encoding:enc];
        if (content)
            utf8Data = [content dataUsingEncoding:NSUTF8StringEncoding];
    }

    if (!utf8Data) {
        BOOL isUTF8 = NO;
        if (large) {
            // ── Head/tail UTF-8 probe (Phase 2 #3) ─────────────────────────
            // Walking a 3 GB buffer just to validate UTF-8 wasted ~10 s in the
            // baseline. Probing the first/last 1 MB and accepting on success
            // is correct for any file that's UTF-8 throughout, and the
            // boundary-slide ensures we never split a multi-byte sequence.
            const NSUInteger kProbeBytes = (NSUInteger)1 * 1024 * 1024;
            NSUInteger probeLen = MIN(kProbeBytes, len);
            // Slide the head probe end backwards off any UTF-8 continuation
            // byte (10xxxxxx) so we never falsely fail on a sliced sequence.
            NSUInteger headEnd = probeLen;
            while (headEnd > 0 && (b[headEnd] & 0xC0) == 0x80) headEnd--;
            NSData *headProbe = [rawData subdataWithRange:NSMakeRange(0, headEnd)];
            BOOL headValid = ([[NSString alloc] initWithData:headProbe
                                                    encoding:NSUTF8StringEncoding] != nil);
            BOOL tailValid = YES;
            if (len > probeLen) {
                NSUInteger tailStart = len - probeLen;
                while (tailStart < len && (b[tailStart] & 0xC0) == 0x80) tailStart++;
                NSData *tailProbe = [rawData subdataWithRange:
                                     NSMakeRange(tailStart, len - tailStart)];
                tailValid = ([[NSString alloc] initWithData:tailProbe
                                                   encoding:NSUTF8StringEncoding] != nil);
            }
            isUTF8 = headValid && tailValid;
        } else {
            // Small file — full validation (same path as before).
            isUTF8 = ([[NSString alloc] initWithData:rawData
                                            encoding:NSUTF8StringEncoding] != nil);
        }

        if (isUTF8) {
            // Phase 2 #4: when payload is UTF-8 already, pass mmap'd bytes
            // directly to SCI_ADDTEXT — no NSString round-trip, no extra copy.
            enc = NSUTF8StringEncoding;
            utf8Data = hasBOM ? textData : rawData;
        } else if (large) {
            // Huge non-UTF-8: byte-as-Latin-1 (no full-file walk).
            enc = NSISOLatin1StringEncoding;
            utf8Data = rawData;
        } else {
            // Small non-UTF-8: first ask macOS's heuristic charset detector — it
            // covers the CJK encodings the old Win-1252/Latin-1 fallback turned into
            // mojibake (GBK/GB18030, Big5, Shift-JIS, EUC, …). We only trust a result
            // that decoded *without* lossy substitution; anything else falls through
            // to the unchanged Win-1252/Latin-1 path, so Western files never regress.
            NSString *detected = nil;
            BOOL detLossy = NO;
            NSStringEncoding guess = [NSString stringEncodingForData:rawData
                                                    encodingOptions:nil
                                                    convertedString:&detected
                                                usedLossyConversion:&detLossy];
            if (detected && guess != 0 && !detLossy && guess != NSUTF8StringEncoding) {
                NSStringEncoding canon = canonicalCJKEncoding(guess);
                enc = canon ?: guess;
                utf8Data = [detected dataUsingEncoding:NSUTF8StringEncoding];
            }

            if (!utf8Data) {
                // Fallback: try Win-1252, then Latin-1 (cheap walk on small files).
                NSStringEncoding win1252 = nppEnc(kCFStringEncodingWindowsLatin1);
                NSString *content = [[NSString alloc] initWithData:rawData encoding:win1252];
                if (content) {
                    enc = win1252;
                    utf8Data = [content dataUsingEncoding:NSUTF8StringEncoding];
                } else {
                    content = [[NSString alloc] initWithData:rawData
                                                    encoding:NSISOLatin1StringEncoding];
                    if (content) {
                        enc = NSISOLatin1StringEncoding;
                        utf8Data = [content dataUsingEncoding:NSUTF8StringEncoding];
                    }
                }
            }
        }
    }

    if (!utf8Data) {
        // Final fallback — load raw bytes as-is.
        enc = NSISOLatin1StringEncoding;
        utf8Data = rawData;
    }

    // Phase 2 #1+#2: every load swaps to a fresh Scintilla document so the
    // options match the file state. Large files get TEXT_LARGE (64-bit
    // Position type → no silent >2 GB wraparound) + STYLES_NONE (skip the
    // per-byte styles array — we already disable syntax highlighting in
    // large mode, so this is a free ~50% RAM cut). Small files get DEFAULT
    // options. Always swapping handles the reload-after-shrink edge case
    // (tab previously held a 3 GB file gets STYLES_NONE; if that tab is then
    // reloaded with a tiny file, we want syntax highlighting back).
    int docOptions = large ? (SC_DOCUMENTOPTION_TEXT_LARGE | SC_DOCUMENTOPTION_STYLES_NONE)
                           : SC_DOCUMENTOPTION_DEFAULT;
    sptr_t newDoc = [_scintillaView message:SCI_CREATEDOCUMENT
                                     wParam:(uptr_t)utf8Data.length
                                     lParam:docOptions];
    if (newDoc) {
        [_scintillaView message:SCI_SETDOCPOINTER wParam:0 lParam:newDoc];
        [_scintillaView message:SCI_RELEASEDOCUMENT wParam:0 lParam:newDoc];
    }

    // ── Pre-insert undo gate for large files (Phase 2.6) ─────────────────────
    // Disabling SCI_SETUNDOCOLLECTION BEFORE SCI_ADDTEXT prevents Scintilla's
    // UndoHistory from copying the full insert payload into its scrap buffer.
    // The scrap buffer is a std::string whose capacity is never released by
    // SCI_EMPTYUNDOBUFFER (which calls .clear() — std::string::clear retains
    // capacity). Without this gate, opening a 2.78 GB file holds ~2.78 GB of
    // scrap capacity in RAM forever, on top of the document's own buffer.
    // Small files keep the existing behavior (undo on during load, then
    // SCI_EMPTYUNDOBUFFER below); the per-tab waste is bounded by file size.
    if (large) {
        [_scintillaView message:SCI_SETUNDOCOLLECTION wParam:0 lParam:0];
    }

    // Load into Scintilla using SCI_ADDTEXT with explicit length — binary safe.
    [_scintillaView message:SCI_CLEARALL wParam:0 lParam:0];
    [_scintillaView message:SCI_ADDTEXT
                     wParam:(uptr_t)utf8Data.length
                     lParam:(sptr_t)utf8Data.bytes];
    _filePath = [path copy];
    _fileEncoding = enc;
    _hasBOM = hasBOM;
    _isModified = NO;
    _backupFilePath = nil; // buffer loaded from disk — no backup needed

    _largeFileMode = large;

    NSString *ext = path.pathExtension.lowercaseString;
    NSString *lang = extensionLanguageMap()[ext] ?: @"";
    // Issue #130 — built-in extensions take precedence; if none matches, fall
    // back to a User Defined Language whose ext= list claims this extension.
    if (!lang.length) {
        UserDefinedLang *udl = [[UserDefineLangManager shared] languageForExtension:ext];
        if (udl) lang = udl.name;
    }
    if (large) {
        // Syntax highlighting off (undo was already disabled before SCI_ADDTEXT
        // above — see "Pre-insert undo gate" comment).
        [self setLanguage:@""];
        // Performance pref — turn off word wrap for large files. Word-wrap on
        // a multi-million-line buffer is dominated by wrap-recompute time, so
        // even users who normally wrap usually want it off for huge files.
        if ([[NSUserDefaults standardUserDefaults] boolForKey:kPrefLargeFileNoWrap]) {
            _wordWrapEnabled = NO;
            [_scintillaView message:SCI_SETWRAPMODE wParam:SC_WRAP_NONE];
        }
    } else {
        [self setLanguage:lang];
        // Re-enable undo in case this tab was previously in large-file mode.
        [_scintillaView message:SCI_SETUNDOCOLLECTION wParam:1 lParam:0];
    }

    [_scintillaView message:SCI_GOTOPOS wParam:0];
    [_scintillaView message:SCI_EMPTYUNDOBUFFER];
    // Tell change history that the just-loaded content IS the save baseline —
    // without this every line would show as orange immediately after file open.
    [_scintillaView message:SCI_SETSAVEPOINT];

    // Issue #111 — the full-file SCI_ADDTEXT above was recorded into the
    // change-history object while it was live, and SCI_EMPTYUNDOBUFFER then
    // emptied the undo history without resetting that object, leaving it
    // inconsistent so later edits no longer register as modifications (no
    // orange marker). Disable + re-enable frees the stale object and
    // rebuilds a fresh one on the loaded content as the clean baseline —
    // the undo buffer is already empty here, which ChangeHistorySet requires.
    // Marker styles set in applyDefaultTheme live in the ViewStyle and are
    // unaffected by toggling change history.
    [_scintillaView message:SCI_SETCHANGEHISTORY wParam:SC_CHANGE_HISTORY_DISABLED];
    [_scintillaView message:SCI_SETCHANGEHISTORY
                     wParam:SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS];

    // SCI_SETWORDCHARS is per-document; Phase 2 always swaps to a fresh doc
    // on each load, so re-apply the user's word-char preference here (issue #42).
    [self applyWordCharsFromDefaults];

    // Record mtime from the stat we already performed at the top of this method.
    _lastKnownModDate = attrs[NSFileModificationDate];

    // Start (or restart) polling for external changes.
    // First tick deferred 3s so it coalesces with the TCC grant from the file read above.
    [_fileMonitorTimer invalidate];
    _fileMonitorTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                         target:self
                                                       selector:@selector(_pollExternalChange:)
                                                       userInfo:nil
                                                        repeats:YES];
    _fileMonitorTimer.fireDate = [NSDate dateWithTimeIntervalSinceNow:3.0];

    // After file load, clear stale fold highlight delimiter by triggering
    // InvalidateStyleRedraw (DropGraphics + full margin invalidation).
    // SCI_SETMARGINRIGHT with the current value is a lightweight trigger.
    // Deferred so the view has its final layout and correct LinesOnScreen.
    dispatch_async(dispatch_get_main_queue(), ^{
        sptr_t curRight = [_scintillaView message:SCI_GETMARGINRIGHT];
        [_scintillaView message:SCI_SETMARGINRIGHT wParam:0 lParam:curRight];
    });

    return YES;
}

- (BOOL)saveError:(NSError **)error {
    if (!_filePath) return NO;
    return [self saveToPath:_filePath error:error];
}

/// Encode the current document (honouring its encoding/BOM) and write the bytes
/// to `path`. Pure I/O: does NOT change the editor's identity (file path,
/// modified state, save point, backup, clone links, language). Returns NO and
/// sets *error on failure.
- (BOOL)_writeContentsToPath:(NSString *)path error:(NSError **)error {
    BOOL ok = NO;

    if (_fileEncoding == NSUTF8StringEncoding) {
        // ── Zero-copy UTF-8 fast path (Phase 2.5) ─────────────────────────
        // SCI_GETCHARACTERPOINTER asks Scintilla to compact its gap buffer
        // so the document is one contiguous span, then returns a const char*
        // into Scintilla's internal storage. We hand that pointer to NSData
        // (no-copy wrapper) and write directly. No NSString allocation, no
        // re-encoding pass. The pointer is invalidated by ANY subsequent
        // edit — we only hold it for the synchronous writeToFile: call,
        // and we're on the main thread, so no concurrent edits can occur.
        ScintillaView *sci = _scintillaView;
        intptr_t len = [sci message:SCI_GETLENGTH];
        const char *bytes = (const char *)[sci message:SCI_GETCHARACTERPOINTER];

        if (_hasBOM) {
            // BOM-prefixed UTF-8: build a small buffer with the 3-byte BOM
            // followed by the body. The body is one memcpy from Scintilla's
            // pointer (no NSString round-trip — still ~50% RAM savings vs
            // the previous path on huge files).
            NSMutableData *out = [NSMutableData dataWithCapacity:(NSUInteger)len + 3];
            const uint8_t bom[] = {0xEF, 0xBB, 0xBF};
            [out appendBytes:bom length:3];
            if (len > 0 && bytes != NULL) [out appendBytes:bytes length:(NSUInteger)len];
            ok = [out writeToFile:path atomically:YES];
        } else {
            // No BOM: full zero-copy path. NSData wraps Scintilla's pointer
            // without copying; writeToFile streams it straight to disk.
            NSData *body = (len > 0 && bytes != NULL)
                ? [NSData dataWithBytesNoCopy:(void *)bytes
                                       length:(NSUInteger)len
                                 freeWhenDone:NO]
                : [NSData data];
            ok = [body writeToFile:path atomically:YES];
        }
    } else {
        // ── Non-UTF-8 path (unchanged from pre-Phase-2.5) ──────────────────
        // BOM-detected UTF-16 LE/BE, or files explicitly converted to
        // Win-1252 / Latin-1 via the Encoding menu. Scintilla stores the
        // document as UTF-8 internally, so we must round-trip through
        // NSString to re-encode. Acceptable cost on these formats — they're
        // rare for huge files (no one keeps a 3 GB UTF-16-BOM CSV).
        NSString *content = _scintillaView.string;
        NSMutableData *out = [NSMutableData data];
        if (_hasBOM) {
            if (_fileEncoding == NSUTF16BigEndianStringEncoding) {
                const uint8_t bom[] = {0xFE, 0xFF};
                [out appendBytes:bom length:2];
            } else if (_fileEncoding == NSUTF16LittleEndianStringEncoding) {
                const uint8_t bom[] = {0xFF, 0xFE};
                [out appendBytes:bom length:2];
            }
        }
        NSData *body = [content dataUsingEncoding:_fileEncoding allowLossyConversion:YES];
        if (!body) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                                   code:NSFileWriteInapplicableStringEncodingError
                                               userInfo:nil];
            return NO;
        }
        [out appendData:body];
        ok = [out writeToFile:path atomically:YES];
    }

    if (!ok) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                               code:NSFileWriteUnknownError userInfo:nil];
        return NO;
    }
    return YES;
}

/// Write a snapshot of the current contents to `path` WITHOUT repointing the
/// editor at it. Used by "Save a Copy As": the live document keeps its original
/// file, modified state, save point and backup, so subsequent saves still go to
/// the original. Returns NO and sets *error on failure.
- (BOOL)writeCopyToPath:(NSString *)path error:(NSError **)error {
    return [self _writeContentsToPath:path error:error];
}

- (BOOL)saveToPath:(NSString *)path error:(NSError **)error {
    if (![self _writeContentsToPath:path error:error]) return NO;

    NSString *oldPath = _filePath;
    _filePath = [path copy];
    _isModified = NO;
    [_scintillaView message:SCI_SETSAVEPOINT];
    if (_backupFilePath) {
        [[NSFileManager defaultManager] removeItemAtPath:_backupFilePath error:nil];
        _backupFilePath = nil;
    }
    // Sync clone sibling's filePath so both point to the saved file.
    if (_cloneSibling) {
        _cloneSibling.filePath = [path copy];
        if (_cloneSibling.backupFilePath) {
            [[NSFileManager defaultManager] removeItemAtPath:_cloneSibling.backupFilePath error:nil];
            _cloneSibling.backupFilePath = nil;
        }
    }
    // Record the mtime we just wrote so the polling timer won't mistake our own
    // write for an external change (this is what the old _savingSuppressed flag tried
    // to do, but FSEvents notification timing made it unreliable).
    _lastKnownModDate = [[NSFileManager defaultManager]
                         attributesOfItemAtPath:path error:nil][NSFileModificationDate];

    // Re-detect language if the file extension changed (e.g. Save As with new name)
    NSString *oldExt = oldPath.pathExtension.lowercaseString ?: @"";
    NSString *newExt = path.pathExtension.lowercaseString ?: @"";
    if (![oldExt isEqualToString:newExt]) {
        NSString *lang = extensionLanguageMap()[newExt] ?: @"";
        if (!lang.length) {  // issue #130 — UDL extension fallback
            UserDefinedLang *udl = [[UserDefineLangManager shared] languageForExtension:newExt];
            if (udl) lang = udl.name;
        }
        [self setLanguage:lang];
    }

    // Issue #76 — DO NOT call updateGitDiffMarkers here unconditionally.
    // It spawns /usr/bin/git, which on a Mac without Xcode CLT triggers the
    // "Install Command Line Tools" prompt on every save. Instead post a
    // notification; MainWindowController's handler gates the git work on
    // GitPanel visibility (matches the existing pattern at MWC:6385).
    [[NSNotificationCenter defaultCenter]
        postNotificationName:EditorViewDidSaveNotification object:self];

    [[NppPluginManager shared] notifyPluginsWithCode:NPPN_FILESAVED
                                            bufferID:(intptr_t)(__bridge void *)self];
    return YES;
}

- (void)setFilePath:(NSString *)filePath {
    if ([_filePath isEqualToString:filePath]) return;
    _filePath = [filePath copy];
}

- (NSInteger)untitledIndex { return _untitledIndex; }

/// Restore the untitled index from a saved session so the tab name is preserved.
- (void)restoreUntitledIndex:(NSInteger)index {
    if (index > 0) {
        _untitledIndex = index;
        // Keep the global counter ahead of any restored index to avoid future collisions
        if (index >= _untitledCounter) _untitledCounter = index;
    }
}

- (void)markAsModified {
    _isModified = YES;
}

/// Write content to the backup directory using raw Scintilla bytes.
/// Same byte-level approach as saveToPath: — no NSString intermediate,
/// no encoding roundtrip, preserves null bytes and BOM.
/// Mirrors NPP Buffer.cpp: creates ONE timestamped file per buffer on first backup,
/// then overwrites that same file in-place on every subsequent backup cycle.
- (nullable NSString *)saveBackupToDirectory:(NSString *)dir {
    NSString *dest = _backupFilePath;

    if (!dest) {
        // First backup for this buffer — create with timestamp (created once, reused forever)
        NSString *base = _filePath ? _filePath.lastPathComponent
                       : (_customTabName.length ? _customTabName
                          : [NSString stringWithFormat:@"new %ld", (long)_untitledIndex]);
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd_HHmmss";
        NSString *name = [NSString stringWithFormat:@"%@@%@", base,
                          [fmt stringFromDate:[NSDate date]]];
        dest = [dir stringByAppendingPathComponent:name];
    }

    // Get raw UTF-8 bytes directly from Scintilla (no NSString conversion)
    intptr_t len = [_scintillaView message:SCI_GETLENGTH];
    NSMutableData *out = [NSMutableData dataWithCapacity:(NSUInteger)len + 4];

    // Add BOM if the original file had one
    if (_hasBOM) {
        if (_fileEncoding == NSUTF8StringEncoding) {
            const uint8_t bom[] = {0xEF, 0xBB, 0xBF};
            [out appendBytes:bom length:3];
        } else if (_fileEncoding == NSUTF16BigEndianStringEncoding) {
            const uint8_t bom[] = {0xFE, 0xFF};
            [out appendBytes:bom length:2];
        } else if (_fileEncoding == NSUTF16LittleEndianStringEncoding) {
            const uint8_t bom[] = {0xFF, 0xFE};
            [out appendBytes:bom length:2];
        }
    }

    // Scintilla stores content as UTF-8 bytes internally.
    // Phase 2.5 — for UTF-8 files use SCI_GETCHARACTERPOINTER to read straight
    // out of Scintilla's gap buffer (no malloc, no SCI_GETTEXT copy). One
    // memcpy via appendBytes (only when BOM is present and we're already
    // building a NSMutableData; otherwise we wrap zero-copy below).
    if (_fileEncoding == NSUTF8StringEncoding) {
        const char *bytes = (const char *)[_scintillaView message:SCI_GETCHARACTERPOINTER];
        if (_hasBOM) {
            // BOM already appended above — just append body bytes (one memcpy).
            if (len > 0 && bytes != NULL) [out appendBytes:bytes length:(NSUInteger)len];
        } else {
            // No BOM: skip building NSMutableData entirely, write zero-copy.
            // (The `out` we built above is empty in this branch.)
            NSData *body = (len > 0 && bytes != NULL)
                ? [NSData dataWithBytesNoCopy:(void *)bytes
                                       length:(NSUInteger)len
                                 freeWhenDone:NO]
                : [NSData data];
            if ([body writeToFile:dest atomically:YES]) {
                _backupFilePath = [dest copy];
                return dest;
            }
            return nil;
        }
    } else {
        NSString *content = _scintillaView.string;
        NSData *body = [content dataUsingEncoding:_fileEncoding allowLossyConversion:YES];
        if (!body) return nil;
        [out appendData:body];
    }

    if ([out writeToFile:dest atomically:YES]) {
        _backupFilePath = [dest copy];
        return dest;
    }
    // Backup file write failed — reset path if it was a first-time attempt
    if (!_backupFilePath) return nil;
    _backupFilePath = nil;
    return nil;
}

#pragma mark - Menu validation (checkmarks for toggle items)

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    SEL action = item.action;

    if (action == @selector(showWhiteSpaceAndTab:)) {
        BOOL on = ([_scintillaView message:SCI_GETVIEWWS] == SCWS_VISIBLEALWAYS);
        [(NSMenuItem *)item setState:on ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }
    if (action == @selector(showEndOfLine:)) {
        BOOL on = ([_scintillaView message:SCI_GETVIEWEOL] != 0);
        [(NSMenuItem *)item setState:on ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }
    if (action == @selector(toggleWrapSymbol:)) {
        BOOL on = ([_scintillaView message:SCI_GETWRAPVISUALFLAGS] != 0);
        [(NSMenuItem *)item setState:on ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }
    if (action == @selector(toggleHideLineMarks:)) {
        BOOL on = ([_scintillaView message:SCI_GETMARGINWIDTHN wParam:1] == 0);
        [(NSMenuItem *)item setState:on ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }
    if (action == @selector(setTextDirectionRTL:)) {
        [(NSMenuItem *)item setState:self.isTextDirectionRTL ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }
    if (action == @selector(setTextDirectionLTR:)) {
        [(NSMenuItem *)item setState:!self.isTextDirectionRTL ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }

    return YES;
}

#pragma mark - External file-change monitoring (polling)

- (BOOL)monitoringMode { return _monitoringMode; }
- (void)setMonitoringMode:(BOOL)v { _monitoringMode = v; }



/// Called every second by _fileMonitorTimer.
/// Compares the file's current mtime against _lastKnownModDate.
/// Because we update _lastKnownModDate immediately after every load and save,
/// our own writes never appear as "external" changes — no FSEvents timing issues.
- (void)_pollExternalChange:(NSTimer *)timer {
    if (!_filePath || _externalChangePending) return;

    NSDate *mtime = [[NSFileManager defaultManager]
                     attributesOfItemAtPath:_filePath error:nil][NSFileModificationDate];
    if (!mtime) return;

    // No change if mtime matches what we last recorded.
    if (_lastKnownModDate && [mtime compare:_lastKnownModDate] != NSOrderedDescending) return;

    // File Status Auto-Detection (Preferences > MISC, PR #116). When off, ignore
    // external on-disk changes — but never override an explicit tail -f
    // monitoring tab, which is a per-tab opt-in independent of this global setting.
    NSUserDefaults *ud  = [NSUserDefaults standardUserDefaults];
    BOOL autoDetect     = [ud boolForKey:kPrefFileStatusAutoDetection];
    BOOL updateSilently = [ud boolForKey:kPrefFileStatusUpdateSilently];
    if (!autoDetect && !_monitoringMode) return;

    _lastKnownModDate = mtime;
    _externalChangePending = YES;

    // Reload without prompting when this tab is monitoring (tail -f), or when
    // "Update silently" is on and the buffer has no unsaved edits. Dirty buffers
    // always fall through to the prompt so unsaved changes are never discarded
    // silently. Both silent paths preserve the caret (line + column) and scroll
    // position; loadFileAtPath: otherwise resets the caret to 0, which would
    // snap the view back to the top on every external change.
    if (_monitoringMode || (updateSilently && !_isModified)) {
        ScintillaView *sci = _scintillaView;
        sptr_t savedPos          = [sci message:SCI_GETCURRENTPOS];
        sptr_t savedLine         = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)savedPos];
        sptr_t savedColumn       = [sci message:SCI_GETCOLUMN wParam:(uptr_t)savedPos];
        sptr_t savedFirstVisible = [sci message:SCI_GETFIRSTVISIBLELINE];

        NSError *err;
        [self loadFileAtPath:_filePath error:&err];

        // Clamp to the reloaded file's bounds — guards the case where the
        // file shrank and the old caret line no longer exists. SCI_FINDCOLUMN
        // clamps the column to the target line's length on its own.
        sptr_t lineCount  = [sci message:SCI_GETLINECOUNT];
        sptr_t targetLine = MIN(savedLine, lineCount - 1);
        sptr_t targetPos  = [sci message:SCI_FINDCOLUMN
                                   wParam:(uptr_t)targetLine
                                   lParam:(sptr_t)savedColumn];
        [sci message:SCI_GOTOPOS wParam:(uptr_t)targetPos];
        // Restore the viewport last so it wins over GOTOPOS's scroll-to-caret.
        [sci message:SCI_SETFIRSTVISIBLELINE
                wParam:(uptr_t)MIN(savedFirstVisible, lineCount - 1)];

        _externalChangePending = NO;
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"\"%@\" changed on disk",
                         _filePath.lastPathComponent];
    if (!_isModified) {
        alert.informativeText = @"This file was modified by another program.";
        [alert addButtonWithTitle:@"Reload"];
        [alert addButtonWithTitle:@"Ignore"];
    } else {
        alert.informativeText = @"This file was modified by another program. "
                                @"Reloading will discard your unsaved changes.";
        [alert addButtonWithTitle:@"Reload"];
        [alert addButtonWithTitle:@"Keep My Version"];
    }

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSError *err;
        [self loadFileAtPath:_filePath error:&err];
    }
    _externalChangePending = NO;
}

#pragma mark - Language / Lexer

- (void)setLanguage:(NSString *)languageName {
    _currentLanguage = [languageName copy];

    // Reset all styles to STYLE_DEFAULT before switching language.
    // This prevents stale styles from a previous language from bleeding through.
    // Matches Windows NPP's defineDocType() which calls SCI_STYLECLEARALL first.
    [_scintillaView message:SCI_STYLECLEARALL];

    // SCI_STYLECLEARALL resets ALL style IDs (including STYLE_LINENUMBER=33,
    // STYLE_BRACELIGHT=34, etc.) to STYLE_DEFAULT. Re-apply Global Styles.
    [self applyGlobalStyleColors];

    if (!languageName.length) {
        // Plain text — null lexer, all text rendered in STYLE_DEFAULT
        [_scintillaView message:(unsigned int)Scintilla::Message::SetILexer wParam:0 lParam:0];
        [self applyPreferencesFromDefaults];
        sptr_t docLen = [_scintillaView message:SCI_GETLENGTH];
        if (docLen > 0) [_scintillaView message:SCI_COLOURISE wParam:0 lParam:docLen];
        [[NppPluginManager shared] notifyPluginsWithCode:NPPN_LANGCHANGED
                                                bufferID:(intptr_t)(__bridge void *)self];
        return;
    }

    NSString *lexerName = languageLexerNameMap()[languageName.lowercaseString];
    if (!lexerName) {
        // Not a built-in language. Try a User Defined Language of this exact
        // name (issue #130). Routing UDLs through setLanguage: makes them work
        // for every name-based path — file open by extension, rename, session
        // restore, and the Language menu — not just the manual menu selection.
        // STYLECLEARALL above already reset styles; applyLanguage: then installs
        // the user lexer and the UDL's WordsStyle colors on top.
        UserDefinedLang *udl = [[UserDefineLangManager shared] languageNamed:languageName];
        if (udl) {
            [[UserDefineLangManager shared] applyLanguage:udl toScintillaView:_scintillaView];
        } else {
            [self applyPreferencesFromDefaults];
        }
        [[NppPluginManager shared] notifyPluginsWithCode:NPPN_LANGCHANGED
                                                bufferID:(intptr_t)(__bridge void *)self];
        return;
    }

    Scintilla::ILexer5 *lexer = CreateLexer(lexerName.UTF8String);
    if (lexer) {
        [_scintillaView message:(unsigned int)Scintilla::Message::SetILexer
                         wParam:0
                         lParam:(sptr_t)lexer];
    }

    // ── Folding — must be set AFTER the lexer is installed ───────────────────
    // The "fold" property is per-lexer; setting it before SetILexer has no effect.
    ScintillaView *sci = _scintillaView;
    [sci message:SCI_SETPROPERTY wParam:(uptr_t)"fold"         lParam:(sptr_t)"1"];
    [sci message:SCI_SETPROPERTY wParam:(uptr_t)"fold.compact" lParam:(sptr_t)"0"];

    NSString *lang = languageName.lowercaseString;
    // C-family languages (brace-based folding)
    NSSet *cFamily = [NSSet setWithArray:@[@"c", @"cpp", @"objc", @"cs", @"java",
        @"javascript", @"javascript.js", @"typescript", @"swift", @"go", @"rust",
        @"d", @"actionscript", @"rc"]];
    if ([cFamily containsObject:lang]) {
        [sci message:SCI_SETPROPERTY wParam:(uptr_t)"fold.comment"      lParam:(sptr_t)"1"];
        [sci message:SCI_SETPROPERTY wParam:(uptr_t)"fold.preprocessor" lParam:(sptr_t)"1"];
    } else if ([lang isEqualToString:@"html"] || [lang isEqualToString:@"xml"] ||
               [lang isEqualToString:@"asp"]  || [lang isEqualToString:@"php"]) {
        // LexHTML.cxx gates ALL of its fold-level emission on `fold.html` AND
        // the generic `fold` flag — see `const bool fold = foldHTML &&
        // options.fold;` at LexHTML:1262. Without `fold.html=1` the lexer
        // never calls SetLevel, even for { } braces inside <?php ... ?> or
        // <% ... %> preprocessor regions. PHP files were missing this
        // branch before, so folding was silently dead in any file mapped to
        // the `phpscript` (or `hypertext`-with-PHP) lexer.
        [sci message:SCI_SETPROPERTY wParam:(uptr_t)"fold.html"                lParam:(sptr_t)"1"];
        [sci message:SCI_SETPROPERTY wParam:(uptr_t)"fold.html.preprocessor"   lParam:(sptr_t)"1"];
        // Additional fold surfaces LexHTML supports (default off): block
        // comments and heredoc/nowdoc strings. Both are common in PHP/HTML
        // and obviously foldable; turning them on costs one property each.
        [sci message:SCI_SETPROPERTY wParam:(uptr_t)"fold.hypertext.comment"   lParam:(sptr_t)"1"];
        [sci message:SCI_SETPROPERTY wParam:(uptr_t)"fold.hypertext.heredoc"   lParam:(sptr_t)"1"];
    } else if ([lang isEqualToString:@"python"]) {
        [sci message:SCI_SETPROPERTY wParam:(uptr_t)"fold.quotes.python" lParam:(sptr_t)"1"];
    } else if ([lang isEqualToString:@"lua"]) {
        [sci message:SCI_SETPROPERTY wParam:(uptr_t)"fold.comment.lua" lParam:(sptr_t)"1"];
    } else if ([lang isEqualToString:@"sql"] || [lang isEqualToString:@"mssql"]) {
        [sci message:SCI_SETPROPERTY wParam:(uptr_t)"fold.comment" lParam:(sptr_t)"1"];
        [sci message:SCI_SETPROPERTY wParam:(uptr_t)"fold.sql.only.begin" lParam:(sptr_t)"1"];
    }

    [self applyKeywords:languageName];
    [self applyLexerColors:languageName];

    // Re-apply indent settings for the new language (per-language overrides)
    [self applyPreferencesFromDefaults];

    // Force re-lex so fold markers appear immediately on already-loaded content
    sptr_t docLen = [sci message:SCI_GETLENGTH];
    if (docLen > 0) [sci message:SCI_COLOURISE wParam:0 lParam:docLen];

    [[NppPluginManager shared] notifyPluginsWithCode:NPPN_LANGCHANGED
                                            bufferID:(intptr_t)(__bridge void *)self];
}

- (BOOL)largeFileMode { return _largeFileMode; }

- (NSString *)displayName {
    if (_filePath) return _filePath.lastPathComponent;
    if (_customTabName.length) return _customTabName;   // #177: renamed untitled tab
    // Mirror NPP: "new 1", "new 2", … (unique per buffer, like NPP's buffer IDs)
    return [NSString stringWithFormat:@"new %ld", (long)_untitledIndex];
}

#pragma mark - Cursor Info

- (NSInteger)cursorLine {
    sptr_t pos = [_scintillaView message:SCI_GETCURRENTPOS];
    return [_scintillaView message:SCI_LINEFROMPOSITION wParam:(uptr_t)pos] + 1;
}

- (NSInteger)cursorColumn {
    sptr_t pos = [_scintillaView message:SCI_GETCURRENTPOS];
    return [_scintillaView message:SCI_GETCOLUMN wParam:(uptr_t)pos] + 1;
}

- (NSInteger)lineCount {
    return [_scintillaView message:SCI_GETLINECOUNT];
}

- (BOOL)hasBOM { return _hasBOM; }

- (NSString *)encodingName {
    // Base name lookup by NSStringEncoding value
    static NSDictionary<NSNumber *, NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{
            @(NSUTF8StringEncoding):                                                   @"UTF-8",
            @(NSISOLatin1StringEncoding):                                              @"Latin-1",
            @(NSUTF16BigEndianStringEncoding):                                         @"UTF-16 BE",
            @(NSUTF16LittleEndianStringEncoding):                                      @"UTF-16 LE",
            @(NSUTF16StringEncoding):                                                  @"UTF-16",
            @(nppEnc(kCFStringEncodingWindowsLatin1)):                                 @"Windows-1252",
            @(nppEnc(kCFStringEncodingISOLatin9)):                                     @"Latin-9",
            @(nppEnc(kCFStringEncodingWindowsLatin2)):                          @"Windows-1250",
            @(nppEnc(kCFStringEncodingWindowsCyrillic)):                               @"Windows-1251",
            @(nppEnc(kCFStringEncodingWindowsGreek)):                                  @"Windows-1253",
            @(nppEnc(kCFStringEncodingWindowsBalticRim)):                              @"Windows-1257",
            @(nppEnc(kCFStringEncodingWindowsLatin5)):                                 @"Windows-1254",
            @(nppEnc(kCFStringEncodingBig5)):                                          @"Big5",
            @(nppEnc(kCFStringEncodingGBK_95)):                                        @"GB2312",  // GBK (CP936); GB_2312_80 has no macOS converter
            @(nppEnc(kCFStringEncodingShiftJIS)):                                      @"Shift-JIS",
            @(nppEnc(kCFStringEncodingEUC_KR)):                                        @"EUC-KR",
        };
    });
    NSString *base = names[@(_fileEncoding)] ?: @"UTF-8";
    if (_hasBOM) base = [base stringByAppendingString:@" BOM"];
    return base;
}

- (void)setFileEncoding:(NSStringEncoding)enc hasBOM:(BOOL)bom {
    _fileEncoding = enc;
    _hasBOM = bom;
    _isModified = YES;
}

- (BOOL)reloadWithEncoding:(NSStringEncoding)enc hasBOM:(BOOL)bom error:(NSError **)error {
    if (!_filePath) return NO;

    NSData *rawData = [NSData dataWithContentsOfFile:_filePath options:0 error:error];
    if (!rawData) return NO;

    NSData *textData = rawData;
    // Strip BOM bytes if present
    const uint8_t *b = (const uint8_t *)rawData.bytes;
    NSUInteger len = rawData.length;
    if (bom) {
        if (enc == NSUTF8StringEncoding && len >= 3 && b[0]==0xEF && b[1]==0xBB && b[2]==0xBF)
            textData = [rawData subdataWithRange:NSMakeRange(3, len - 3)];
        else if (enc == NSUTF16LittleEndianStringEncoding && len >= 2 && b[0]==0xFF && b[1]==0xFE)
            textData = [rawData subdataWithRange:NSMakeRange(2, len - 2)];
        else if (enc == NSUTF16BigEndianStringEncoding && len >= 2 && b[0]==0xFE && b[1]==0xFF)
            textData = [rawData subdataWithRange:NSMakeRange(2, len - 2)];
    }

    // Convert to UTF-8 for Scintilla
    NSData *utf8Data = nil;
    if (enc == NSUTF8StringEncoding) {
        utf8Data = textData;
    } else {
        NSString *content = [[NSString alloc] initWithData:textData encoding:enc];
        if (content)
            utf8Data = [content dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (!utf8Data) {
        // Encoding failed — try raw
        utf8Data = textData;
    }

    // Load into Scintilla
    [_scintillaView message:SCI_SETREADONLY wParam:0 lParam:0];
    [_scintillaView message:SCI_CLEARALL wParam:0 lParam:0];
    [_scintillaView message:SCI_ADDTEXT wParam:(uptr_t)utf8Data.length lParam:(sptr_t)utf8Data.bytes];
    [_scintillaView message:SCI_GOTOPOS wParam:0 lParam:0];
    [_scintillaView message:SCI_EMPTYUNDOBUFFER];
    [_scintillaView message:SCI_SETSAVEPOINT];

    _fileEncoding = enc;
    _hasBOM = bom;
    _isModified = NO;
    return YES;
}

- (void)convertContentToEncoding:(NSStringEncoding)enc hasBOM:(BOOL)bom {
    // Get current text from Scintilla
    NSString *content = _scintillaView.string;
    if (!content) return;

    // Re-encode: convert current text to the target encoding, then back to UTF-8
    // This simulates what Windows NPP does (cut → change encoding → paste)
    NSData *encoded = [content dataUsingEncoding:enc allowLossyConversion:YES];
    if (!encoded) return;

    // Convert back to UTF-8 for Scintilla display
    NSString *reencoded = [[NSString alloc] initWithData:encoded encoding:enc];
    if (!reencoded) reencoded = content; // fallback

    NSData *utf8Data = [reencoded dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8Data) return;

    [_scintillaView message:SCI_SETREADONLY wParam:0 lParam:0];
    [_scintillaView message:SCI_CLEARALL wParam:0 lParam:0];
    [_scintillaView message:SCI_ADDTEXT wParam:(uptr_t)utf8Data.length lParam:(sptr_t)utf8Data.bytes];
    [_scintillaView message:SCI_GOTOPOS wParam:0 lParam:0];

    _fileEncoding = enc;
    _hasBOM = bom;
    _isModified = YES;
}

- (NSString *)eolName {
    sptr_t mode = [_scintillaView message:SCI_GETEOLMODE];
    switch (mode) {
        case SC_EOL_CRLF: return @"CRLF";
        case SC_EOL_CR:   return @"CR";
        default:          return @"LF";
    }
}

#pragma mark - Find / Replace

- (BOOL)findNext:(NSString *)text matchCase:(BOOL)mc wholeWord:(BOOL)ww wrap:(BOOL)wrap {
    return [_scintillaView findAndHighlightText:text
                                      matchCase:mc
                                      wholeWord:ww
                                       scrollTo:YES
                                           wrap:wrap];
}

- (BOOL)findPrev:(NSString *)text matchCase:(BOOL)mc wholeWord:(BOOL)ww wrap:(BOOL)wrap {
    return [_scintillaView findAndHighlightText:text
                                      matchCase:mc
                                      wholeWord:ww
                                       scrollTo:YES
                                           wrap:wrap
                                      backwards:YES];
}

- (BOOL)replace:(NSString *)text with:(NSString *)replacement
      matchCase:(BOOL)mc wholeWord:(BOOL)ww {
    // If current selection already matches, replace it, then find next.
    NSString *sel = _scintillaView.selectedString;
    BOOL selMatches = mc ? [sel isEqualToString:text]
                         : [sel caseInsensitiveCompare:text] == NSOrderedSame;
    if (selMatches) {
        [_scintillaView message:SCI_REPLACESEL wParam:0 lParam:(sptr_t)replacement.UTF8String];
    }
    // Find the next occurrence
    return [_scintillaView findAndHighlightText:text
                                      matchCase:mc
                                      wholeWord:ww
                                       scrollTo:YES
                                           wrap:YES];
}

- (NSInteger)replaceAll:(NSString *)text with:(NSString *)replacement
             matchCase:(BOOL)mc wholeWord:(BOOL)ww {
    return (NSInteger)[_scintillaView findAndReplaceText:text
                                                  byText:replacement
                                               matchCase:mc
                                               wholeWord:ww
                                                   doAll:YES];
}

#pragma mark - Theme

// Convert NSColor to Scintilla's BGR integer format (r | g<<8 | b<<16)
static sptr_t sciColor(NSColor *c) {
    c = [c colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
    if (!c) return 0;
    long r = (long)([c redComponent]   * 255);
    long g = (long)([c greenComponent] * 255);
    long b = (long)([c blueComponent]  * 255);
    return (b << 16) | (g << 8) | r;
}

// Helper: parse "#RRGGBB" hex string to NSColor
static NSColor *nppColorFromHex(NSString *hex) {
    if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:hex] scanHexInt:&rgb];
    return [NSColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >>  8) & 0xFF) / 255.0
                            blue:( rgb        & 0xFF) / 255.0
                           alpha:1.0];
}

- (void)applyThemeColors {
    NPPStyleStore *store = [NPPStyleStore sharedStore];
    NSString *fontName = store.globalFontName;
    NSInteger fontSize = store.globalFontSize;

    ScintillaView *sci = _scintillaView;
    NSColor *fg = store.globalFg;
    NSColor *bg = store.globalBg;

    // Global override (issue #149) — applies to STYLE_DEFAULT too, mirroring
    // Windows ScintillaEditView.cpp:912/928 where setStyle() substitutes
    // from the "Global override" row even when styleID == STYLE_DEFAULT
    // (with the transparent-override carve-out that keeps Default Style's
    // own value).
    NPPStyleEntry *gov = [store globalStyleNamed:@"Global override"];
    NPPStyleEntry *gsDefault = [store globalStyleNamed:@"Default Style"];
    NSUserDefaults *_ud = [NSUserDefaults standardUserDefaults];
    if (gov && [_ud boolForKey:kPrefGlobalOverrideEnableFg]       && gov.fgColor)        fg       = gov.fgColor;
    if (gov && [_ud boolForKey:kPrefGlobalOverrideEnableBg]       && gov.bgColor)        bg       = gov.bgColor;
    if (gov && [_ud boolForKey:kPrefGlobalOverrideEnableFont]     && gov.fontName.length>0) fontName = gov.fontName;
    if (gov && [_ud boolForKey:kPrefGlobalOverrideEnableFontSize] && gov.fontSize > 0)   fontSize = gov.fontSize;
    BOOL defBold      = gsDefault.bold;
    BOOL defItalic    = gsDefault.italic;
    BOOL defUnderline = gsDefault.underline;
    if (gov && [_ud boolForKey:kPrefGlobalOverrideEnableBold])      defBold      = gov.bold;
    if (gov && [_ud boolForKey:kPrefGlobalOverrideEnableItalic])    defItalic    = gov.italic;
    if (gov && [_ud boolForKey:kPrefGlobalOverrideEnableUnderline]) defUnderline = gov.underline;

    const char *fontNameUTF8 = fontName.UTF8String;
    [sci message:SCI_STYLESETFONT wParam:STYLE_DEFAULT lParam:(sptr_t)fontNameUTF8];
    [sci message:SCI_STYLESETSIZEFRACTIONAL wParam:STYLE_DEFAULT lParam:(sptr_t)(fontSize * 100)];
    [sci setColorProperty:SCI_STYLESETFORE parameter:STYLE_DEFAULT value:fg];
    [sci setColorProperty:SCI_STYLESETBACK parameter:STYLE_DEFAULT value:bg];

    // Apply effective Default Style bold/italic/underline (with override
    // substitution if enabled) BEFORE the STYLECLEARALL below, so the
    // propagation carries these attributes to every other style in one pass.
    [sci message:SCI_STYLESETBOLD      wParam:STYLE_DEFAULT lParam:(defBold      ? 1 : 0)];
    [sci message:SCI_STYLESETITALIC    wParam:STYLE_DEFAULT lParam:(defItalic    ? 1 : 0)];
    [sci message:SCI_STYLESETUNDERLINE wParam:STYLE_DEFAULT lParam:(defUnderline ? 1 : 0)];

    // Propagate defaults to all styles, then re-apply language-specific colors
    [sci message:SCI_STYLECLEARALL];

    CGFloat bgBrightness = bg.brightnessComponent;

    // ── Global Styles from stylers.xml / theme XML ──────────────────────────
    // Line number margin
    NPPStyleEntry *gsLineNum = [store globalStyleNamed:@"Line number margin"];
    NSColor *lnFg = gsLineNum.fgColor ?: (bgBrightness > 0.5 ? [NSColor colorWithWhite:0.5 alpha:1.0]
                                                               : [NSColor colorWithWhite:0.6 alpha:1.0]);
    NSColor *lnBg = gsLineNum.bgColor ?: (bgBrightness > 0.5 ? [NSColor colorWithWhite:0.95 alpha:1.0] : bg);
    [sci setColorProperty:SCI_STYLESETFORE parameter:STYLE_LINENUMBER value:lnFg];
    [sci setColorProperty:SCI_STYLESETBACK parameter:STYLE_LINENUMBER value:lnBg];

    // Caret
    NPPStyleEntry *gsCaret = [store globalStyleNamed:@"Caret colour"];
    [sci message:SCI_SETCARETFORE wParam:sciColor(gsCaret.fgColor ?: fg)];

    // Caret-line highlight
    NPPStyleEntry *gsCaretLine = [store globalStyleNamed:@"Current line background colour"];
    NSColor *caretLineBg = gsCaretLine.bgColor
        ?: (bgBrightness > 0.5
            ? [NSColor colorWithRed:0.97 green:0.97 blue:1.0 alpha:1.0]
            : [NSColor colorWithWhite:bgBrightness + 0.08 alpha:1.0]);
    [sci message:SCI_SETCARETLINEBACK wParam:sciColor(caretLineBg)];

    // Selected text
    NPPStyleEntry *gsSelected = [store globalStyleNamed:@"Selected text colour"];
    if (gsSelected.bgColor)
        [sci message:SCI_SETSELBACK wParam:1 lParam:sciColor(gsSelected.bgColor)];

    // Fold margin background from "Fold margin" global style
    NPPStyleEntry *gsFoldMargin = [store globalStyleNamed:@"Fold margin"];
    sptr_t foldMarginBGR2;
    if (gsFoldMargin && gsFoldMargin.bgColor) {
        foldMarginBGR2 = sciColor(gsFoldMargin.bgColor);
    } else {
        NSString *activeThem = [store activeThemeName];
        BOOL darkFold = foldMarginUsesEditorBg(activeThem);
        sptr_t fbgr = darkFold ? foldMarginBGRForTheme(activeThem) : -1;
        foldMarginBGR2 = (fbgr >= 0) ? fbgr : 0xF2F2F2;
    }
    [sci message:SCI_SETFOLDMARGINCOLOUR   wParam:1 lParam:foldMarginBGR2];
    [sci message:SCI_SETFOLDMARGINHICOLOUR wParam:1 lParam:foldMarginBGR2];
    // Fold marker colours from "Fold" and "Fold active" global styles
    NPPStyleEntry *gsFold = [store globalStyleNamed:@"Fold"];
    NSColor *foldFore2 = gsFold.fgColor ?: (bgBrightness > 0.5 ? [NSColor blackColor]
                                                                 : [NSColor colorWithWhite:0.80 alpha:1.0]);
    NSColor *foldBack2 = gsFold.bgColor ?: (bgBrightness > 0.5 ? [NSColor colorWithWhite:0.82 alpha:1.0]
                                                                 : [NSColor colorWithWhite:bgBrightness + 0.22 alpha:1.0]);
    NPPStyleEntry *gsFoldActive2 = [store globalStyleNamed:@"Fold active"];
    NSColor *foldRed2 = gsFoldActive2.fgColor ?: [NSColor colorWithRed:0.80 green:0.0 blue:0.0 alpha:1.0];
    for (int mn = SC_MARKNUM_FOLDEREND; mn <= SC_MARKNUM_FOLDEROPEN; mn++) {
        [sci setColorProperty:SCI_MARKERSETFORE          parameter:mn value:foldFore2];
        [sci setColorProperty:SCI_MARKERSETBACK          parameter:mn value:foldBack2];
        [sci setColorProperty:SCI_MARKERSETBACKSELECTED  parameter:mn value:foldRed2];
    }
    [sci message:SCI_MARKERENABLEHIGHLIGHT wParam:1];

    // Whitespace symbols
    NPPStyleEntry *gsWS = [store globalStyleNamed:@"White space symbol"];
    [sci message:SCI_SETWHITESPACEFORE wParam:1 lParam:sciColor(gsWS.fgColor ?: [NSColor orangeColor])];

    // Re-apply language colors with the new theme palette. For UDL languages
    // applyLexerColors is a no-op (NPPStyleStore only knows built-in lexers),
    // so SCI_STYLECLEARALL above would otherwise leave UDL-styled tabs as
    // plain text after every theme toggle. Re-route UDLs through the UDL
    // apply path, and re-resolve by file extension so a multi-variant UDL
    // (the markdown light/dark preinstalled pair) picks the variant matching
    // the new dark-mode state.
    if (_currentLanguage.length) {
        UserDefineLangManager *udlMgr = [UserDefineLangManager shared];
        UserDefinedLang *udl = [udlMgr languageNamed:_currentLanguage];
        if (udl) {
            // Default: re-apply the same UDL. Only re-resolve by extension
            // (which picks the theme-matching variant for multi-variant UDLs
            // like the markdown light/dark pair) when the *current* UDL
            // actually claims this file's extension. Otherwise the user
            // manually picked a UDL whose ext list doesn't include this
            // file (an override) — respect that choice.
            UserDefinedLang *target = udl;
            NSString *ext = _filePath.pathExtension.lowercaseString;
            if (ext.length) {
                BOOL currentClaimsExt = NO;
                for (NSString *e in [udl.extensions componentsSeparatedByString:@" "]) {
                    if ([e.lowercaseString isEqualToString:ext]) {
                        currentClaimsExt = YES;
                        break;
                    }
                }
                if (currentClaimsExt) {
                    UserDefinedLang *resolved = [udlMgr languageForExtension:ext];
                    if (resolved) target = resolved;
                }
            }
            [udlMgr applyLanguage:target toScintillaView:_scintillaView];
            _currentLanguage = [target.name copy];
        } else {
            [self applyLexerColors:_currentLanguage];
        }
    }

    // Issue #149 — line spacing depends on SCI_TEXTHEIGHT, which depends on
    // the font we just (re-)set. Recompute the extra ascent/descent here so
    // a font/theme change resizes the line padding proportionally.
    [self applyLineSpacingFromDefaults];
}

/// Issue #149 — apply the user's "Line spacing" multiplier (1.0/1.2/1.3/1.4/1.5)
/// as extra ascent + descent in pixels, proportional to the current line height.
/// Idempotent: resets extras to 0 before measuring so SCI_TEXTHEIGHT returns
/// the *unmodified* base height (otherwise repeated calls would compound).
/// Splits the total extra half-above / half-below so the caret stays visually
/// centered between lines.
- (void)applyLineSpacingFromDefaults {
    ScintillaView *sci = _scintillaView;
    if (!sci) return;
    // Clear any prior extras first — guarantees SCI_TEXTHEIGHT returns the
    // base (font-only) height, not a previously-inflated value.
    [sci message:SCI_SETEXTRAASCENT  wParam:0 lParam:0];
    [sci message:SCI_SETEXTRADESCENT wParam:0 lParam:0];

    double mult = [[NSUserDefaults standardUserDefaults] doubleForKey:kPrefLineHeightMultiplier];
    if (mult <= 1.0) return;  // 1.0 (or zero/missing pref) = no extras, no work

    sptr_t baseH = [sci message:SCI_TEXTHEIGHT wParam:0 lParam:0];
    if (baseH <= 0) return;   // pre-setup view; nothing to scale
    sptr_t total = (sptr_t)llround((double)baseH * (mult - 1.0));
    if (total <= 0) return;
    sptr_t ascent  = total / 2;
    sptr_t descent = total - ascent;
    [sci message:SCI_SETEXTRAASCENT  wParam:(uptr_t)ascent  lParam:0];
    [sci message:SCI_SETEXTRADESCENT wParam:(uptr_t)descent lParam:0];
}

/// Re-apply Global Styles that use Scintilla style IDs (STYLE_LINENUMBER=33,
/// STYLE_BRACELIGHT=34, STYLE_BRACEBAD=35, indent guide=37).
/// Called after SCI_STYLECLEARALL which resets these to STYLE_DEFAULT.
- (void)applyGlobalStyleColors {
    ScintillaView *sci = _scintillaView;
    NPPStyleStore *store = [NPPStyleStore sharedStore];
    NSColor *bg = store.globalBg;
    CGFloat bgBrightness = bg.brightnessComponent;

    // Line number margin (styleID=33)
    NPPStyleEntry *gsLineNum = [store globalStyleNamed:@"Line number margin"];
    NSColor *lnFg = gsLineNum.fgColor ?: (bgBrightness > 0.5 ? [NSColor colorWithWhite:0.5 alpha:1.0]
                                                               : [NSColor colorWithWhite:0.6 alpha:1.0]);
    NSColor *lnBg = gsLineNum.bgColor ?: (bgBrightness > 0.5 ? [NSColor colorWithWhite:0.95 alpha:1.0] : bg);
    [sci setColorProperty:SCI_STYLESETFORE parameter:STYLE_LINENUMBER value:lnFg];
    [sci setColorProperty:SCI_STYLESETBACK parameter:STYLE_LINENUMBER value:lnBg];

    // Indent guideline style (styleID=37)
    NPPStyleEntry *gsIndent = [store globalStyleNamed:@"Indent guideline style"];
    if (gsIndent.fgColor) [sci setColorProperty:SCI_STYLESETFORE parameter:37 value:gsIndent.fgColor];
    if (gsIndent.bgColor) [sci setColorProperty:SCI_STYLESETBACK parameter:37 value:gsIndent.bgColor];

    // Brace highlight (styleID=34)
    NPPStyleEntry *gsBrace = [store globalStyleNamed:@"Brace highlight style"];
    [sci setColorProperty:SCI_STYLESETFORE parameter:STYLE_BRACELIGHT
                    value:gsBrace.fgColor ?: [NSColor colorWithRed:0.80 green:0.0 blue:0.0 alpha:1.0]];
    [sci setColorProperty:SCI_STYLESETBACK parameter:STYLE_BRACELIGHT
                    value:gsBrace.bgColor ?: [NSColor colorWithRed:1.0 green:0.87 blue:0.87 alpha:1.0]];
    [sci message:SCI_STYLESETBOLD wParam:STYLE_BRACELIGHT lParam:(gsBrace ? gsBrace.bold : YES)];

    // Bad brace (styleID=35)
    NPPStyleEntry *gsBadBrace = [store globalStyleNamed:@"Bad brace colour"];
    [sci setColorProperty:SCI_STYLESETFORE parameter:STYLE_BRACEBAD
                    value:gsBadBrace.fgColor ?: [NSColor colorWithRed:0.75 green:0.0 blue:0.0 alpha:1.0]];
}

- (void)applyDefaultTheme {
    ScintillaView *sci = _scintillaView;

    // 1. Set ALL STYLE_DEFAULT properties first (reads from style store)
    NPPStyleStore *storeD = [NPPStyleStore sharedStore];
    NSString *fontName = storeD.globalFontName;
    NSInteger fontSize = storeD.globalFontSize;
    NSColor *fg = storeD.globalFg;
    NSColor *bg = storeD.globalBg;
    NPPStyleEntry *gsDefault = [storeD globalStyleNamed:@"Default Style"];
    BOOL defBold      = gsDefault.bold;
    BOOL defItalic    = gsDefault.italic;
    BOOL defUnderline = gsDefault.underline;

    // Global override (issue #149) substitution for STYLE_DEFAULT — see
    // -applyThemeColors for the rationale (Windows setStyle() applies the
    // override to STYLE_DEFAULT too).
    NPPStyleEntry *gov = [storeD globalStyleNamed:@"Global override"];
    NSUserDefaults *_ud = [NSUserDefaults standardUserDefaults];
    if (gov && [_ud boolForKey:kPrefGlobalOverrideEnableFg]       && gov.fgColor)         fg       = gov.fgColor;
    if (gov && [_ud boolForKey:kPrefGlobalOverrideEnableBg]       && gov.bgColor)         bg       = gov.bgColor;
    if (gov && [_ud boolForKey:kPrefGlobalOverrideEnableFont]     && gov.fontName.length>0) fontName = gov.fontName;
    if (gov && [_ud boolForKey:kPrefGlobalOverrideEnableFontSize] && gov.fontSize > 0)    fontSize = gov.fontSize;
    if (gov && [_ud boolForKey:kPrefGlobalOverrideEnableBold])      defBold      = gov.bold;
    if (gov && [_ud boolForKey:kPrefGlobalOverrideEnableItalic])    defItalic    = gov.italic;
    if (gov && [_ud boolForKey:kPrefGlobalOverrideEnableUnderline]) defUnderline = gov.underline;

    [sci message:SCI_STYLESETFONT wParam:STYLE_DEFAULT lParam:(sptr_t)fontName.UTF8String];
    [sci message:SCI_STYLESETSIZEFRACTIONAL wParam:STYLE_DEFAULT lParam:(sptr_t)(fontSize * 100)];
    [sci setColorProperty:SCI_STYLESETFORE parameter:STYLE_DEFAULT value:fg];
    [sci setColorProperty:SCI_STYLESETBACK parameter:STYLE_DEFAULT value:bg];
    [sci message:SCI_STYLESETBOLD      wParam:STYLE_DEFAULT lParam:(defBold      ? 1 : 0)];
    [sci message:SCI_STYLESETITALIC    wParam:STYLE_DEFAULT lParam:(defItalic    ? 1 : 0)];
    [sci message:SCI_STYLESETUNDERLINE wParam:STYLE_DEFAULT lParam:(defUnderline ? 1 : 0)];

    // 2. Propagate STYLE_DEFAULT to ALL lexer styles (must come AFTER colors are set)
    [sci message:SCI_STYLECLEARALL];

    // ── Apply Global Styles from stylers.xml / theme XML ──────────────────────
    NPPStyleStore *store = [NPPStyleStore sharedStore];
    CGFloat bgBrightness = bg.brightnessComponent;

    // Line numbers margin
    [sci message:SCI_SETMARGINTYPEN wParam:0 lParam:SC_MARGIN_NUMBER];
    NPPStyleEntry *gsLineNum = [store globalStyleNamed:@"Line number margin"];
    NSColor *lnFg = gsLineNum.fgColor ?: (bgBrightness > 0.5 ? [NSColor colorWithWhite:0.5 alpha:1.0]
                                                               : [NSColor colorWithWhite:0.6 alpha:1.0]);
    NSColor *lnBg = gsLineNum.bgColor ?: (bgBrightness > 0.5 ? [NSColor colorWithWhite:0.95 alpha:1.0] : bg);
    [sci setColorProperty:SCI_STYLESETFORE parameter:STYLE_LINENUMBER value:lnFg];
    [sci setColorProperty:SCI_STYLESETBACK parameter:STYLE_LINENUMBER value:lnBg];

    // Caret color
    NPPStyleEntry *gsCaret = [store globalStyleNamed:@"Caret colour"];
    [sci message:SCI_SETCARETFORE wParam:sciColor(gsCaret.fgColor ?: fg)];

    // Current-line highlight background
    NPPStyleEntry *gsCaretLine = [store globalStyleNamed:@"Current line background colour"];
    NSColor *caretLineBg = gsCaretLine.bgColor
        ?: (bgBrightness > 0.5
            ? [NSColor colorWithRed:0.97 green:0.97 blue:1.0 alpha:1.0]
            : [NSColor colorWithWhite:bgBrightness + 0.08 alpha:1.0]);
    [sci message:SCI_SETCARETLINEBACK wParam:sciColor(caretLineBg)];

    // Selected text colour
    NPPStyleEntry *gsSelected = [store globalStyleNamed:@"Selected text colour"];
    if (gsSelected.bgColor)
        [sci message:SCI_SETSELBACK wParam:1 lParam:sciColor(gsSelected.bgColor)];

    // White space symbol colour
    NPPStyleEntry *gsWhiteSpace = [store globalStyleNamed:@"White space symbol"];
    if (gsWhiteSpace.fgColor)
        [sci message:SCI_SETWHITESPACEFORE wParam:1 lParam:sciColor(gsWhiteSpace.fgColor)];

    // Indentation guides — honour the persisted kPrefShowIndentGuides toggle.
    BOOL showGuides = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefShowIndentGuides];
    [sci message:SCI_SETINDENTATIONGUIDES wParam:(showGuides ? SC_IV_LOOKBOTH : SC_IV_NONE)];
    [sci message:SCI_SETEOLMODE wParam:SC_EOL_LF];
    NPPStyleEntry *gsIndent = [store globalStyleNamed:@"Indent guideline style"];
    if (gsIndent.fgColor) [sci setColorProperty:SCI_STYLESETFORE parameter:37 value:gsIndent.fgColor];
    if (gsIndent.bgColor) [sci setColorProperty:SCI_STYLESETBACK parameter:37 value:gsIndent.bgColor];

    // Brace matching
    NPPStyleEntry *gsBrace = [store globalStyleNamed:@"Brace highlight style"];
    [sci setColorProperty:SCI_STYLESETFORE parameter:STYLE_BRACELIGHT
                    value:gsBrace.fgColor ?: [NSColor colorWithRed:0.80 green:0.0 blue:0.0 alpha:1.0]];
    [sci setColorProperty:SCI_STYLESETBACK parameter:STYLE_BRACELIGHT
                    value:gsBrace.bgColor ?: [NSColor colorWithRed:1.0 green:0.87 blue:0.87 alpha:1.0]];
    [sci message:SCI_STYLESETBOLD wParam:STYLE_BRACELIGHT lParam:(gsBrace ? gsBrace.bold : YES)];
    NPPStyleEntry *gsBadBrace = [store globalStyleNamed:@"Bad brace colour"];
    [sci setColorProperty:SCI_STYLESETFORE parameter:STYLE_BRACEBAD
                    value:gsBadBrace.fgColor ?: [NSColor colorWithRed:0.75 green:0.0 blue:0.0 alpha:1.0]];

    // ── Multiple selections & column/rectangular mode ────────────────────────
    // Ctrl+click adds a caret; Alt+drag creates a column (rectangular) selection.
    [sci message:SCI_SETMULTIPLESELECTION         wParam:1];
    [sci message:SCI_SETADDITIONALSELECTIONTYPING wParam:1];
    [sci message:SCI_SETMULTIPASTE                wParam:SC_MULTIPASTE_EACH];
    [sci message:SCI_SETRECTANGULARSELECTIONMODIFIER wParam:SCMOD_ALT];

    // ── Autocomplete settings ────────────────────────────────────────────────
    [sci message:SCI_AUTOCSETIGNORECASE    wParam:1]; // case-insensitive match
    [sci message:SCI_AUTOCSETDROPRESTOFWORD wParam:0];
    [sci message:SCI_AUTOCSETMAXHEIGHT     wParam:10];
    [sci message:SCI_AUTOCSETMAXWIDTH      wParam:40];

    // Issue #111 — track the widest displayed line so the horizontal
    // scrollbar can reach the end of long lines. Without tracking the
    // scroll width only grows where the caret has been, so a freshly
    // loaded file's long lines (caret never visited) stay partly
    // unreachable.
    [sci message:SCI_SETSCROLLWIDTHTRACKING wParam:1];

    // ── Change-history bar (margin 2, 2 px) ──────────────────────────────────
    // When SC_CHANGE_HISTORY_MARKERS is enabled Scintilla auto-assigns default
    // marker styles to markers 21-24.  The default for HISTORY_SAVED (22) is
    // SC_MARK_BACKGROUND which paints the ENTIRE LINE green — not what we want.
    // Override ALL four history markers first: three → SC_MARK_EMPTY (invisible),
    // one (MODIFIED, 23) → SC_MARK_LEFTRECT in orange.
    [sci message:SCI_SETCHANGEHISTORY
           wParam:SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS];
    [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN   lParam:SC_MARK_EMPTY];
    [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_HISTORY_SAVED                lParam:SC_MARK_EMPTY];
    [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED lParam:SC_MARK_EMPTY];
    [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_HISTORY_MODIFIED             lParam:SC_MARK_LEFTRECT];
    [sci setColorProperty:SCI_MARKERSETBACK parameter:SC_MARKNUM_HISTORY_MODIFIED
                    value:[NSColor colorWithRed:1.0 green:0.50 blue:0.0 alpha:1.0]];
    [sci message:SCI_SETMARGINTYPEN      wParam:2 lParam:SC_MARGIN_SYMBOL];
    [sci message:SCI_SETMARGINMASKN      wParam:2 lParam:(1 << SC_MARKNUM_HISTORY_MODIFIED)];
    [sci message:SCI_SETMARGINWIDTHN     wParam:2 lParam:2];
    [sci message:SCI_SETMARGINSENSITIVEN wParam:2 lParam:0];

    // ── Code folding (margin 3) ───────────────────────────────────────────────
    [sci message:SCI_SETMARGINTYPEN      wParam:3 lParam:SC_MARGIN_SYMBOL];
    [sci message:SCI_SETMARGINMASKN      wParam:3 lParam:(sptr_t)SC_MASK_FOLDERS];
    [sci message:SCI_SETMARGINWIDTHN     wParam:3 lParam:12];
    [sci message:SCI_SETMARGINSENSITIVEN wParam:3 lParam:1];
    // Box-tree style (NPP default): ⊟ / ⊞ with connecting lines
    [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDER        lParam:SC_MARK_BOXPLUS];
    [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEROPEN    lParam:SC_MARK_BOXMINUS];
    [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEREND     lParam:SC_MARK_BOXPLUSCONNECTED];
    [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEROPENMID lParam:SC_MARK_BOXMINUSCONNECTED];
    [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERMIDTAIL lParam:SC_MARK_TCORNERCURVE];
    [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERTAIL    lParam:SC_MARK_LCORNERCURVE];
    [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERSUB     lParam:SC_MARK_VLINE];
    // Fold margin background from "Fold margin" global style
    NPPStyleEntry *gsFoldMargin = [store globalStyleNamed:@"Fold margin"];
    sptr_t foldMarginBGR;
    if (gsFoldMargin && gsFoldMargin.bgColor) {
        foldMarginBGR = sciColor(gsFoldMargin.bgColor);
    } else {
        NSString *activeThm = [store activeThemeName];
        BOOL darkFold = foldMarginUsesEditorBg(activeThm);
        sptr_t fbgr = darkFold ? foldMarginBGRForTheme(activeThm) : -1;
        foldMarginBGR = (fbgr >= 0) ? fbgr : 0xF2F2F2;
    }
    [sci message:SCI_SETFOLDMARGINCOLOUR   wParam:1 lParam:foldMarginBGR];
    [sci message:SCI_SETFOLDMARGINHICOLOUR wParam:1 lParam:foldMarginBGR];
    // Fold marker colours from "Fold" and "Fold active" global styles
    NPPStyleEntry *gsFold = [store globalStyleNamed:@"Fold"];
    NSColor *foldFore = gsFold.fgColor ?: (bgBrightness > 0.5 ? [NSColor blackColor]
                                                                : [NSColor colorWithWhite:0.80 alpha:1.0]);
    NSColor *foldBack = gsFold.bgColor ?: (bgBrightness > 0.5 ? [NSColor colorWithWhite:0.82 alpha:1.0]
                                                                : [NSColor colorWithWhite:bgBrightness + 0.22 alpha:1.0]);
    NPPStyleEntry *gsFoldActive = [store globalStyleNamed:@"Fold active"];
    NSColor *foldRed = gsFoldActive.fgColor ?: [NSColor colorWithRed:0.80 green:0.0 blue:0.0 alpha:1.0];
    for (int mn = SC_MARKNUM_FOLDEREND; mn <= SC_MARKNUM_FOLDEROPEN; mn++) {
        [sci setColorProperty:SCI_MARKERSETFORE          parameter:mn value:foldFore];
        [sci setColorProperty:SCI_MARKERSETBACK          parameter:mn value:foldBack];
        [sci setColorProperty:SCI_MARKERSETBACKSELECTED  parameter:mn value:foldRed];
    }
    // Enable fold-block highlighting: fold markers in the enclosing block turn red.
    [sci message:SCI_MARKERENABLEHIGHLIGHT wParam:1];
    [sci message:SCI_SETAUTOMATICFOLD
           wParam:SC_AUTOMATICFOLD_SHOW|SC_AUTOMATICFOLD_CLICK|SC_AUTOMATICFOLD_CHANGE];

    // ── Bookmark margin (margin 1) ───────────────────────────────────────────
    [sci message:SCI_SETMARGINTYPEN      wParam:1 lParam:SC_MARGIN_SYMBOL];
    [sci message:SCI_SETMARGINMASKN      wParam:1
           lParam:(1 << kBookmarkMarker) | (1 << kHideLinesBeginMarker) | (1 << kHideLinesEndMarker)];
    [sci message:SCI_SETMARGINWIDTHN     wParam:1 lParam:14];
    [sci message:SCI_SETMARGINSENSITIVEN wParam:1 lParam:1];

    // Bookmark marker — identical RGBA pixel data from Windows NPP (rgba_icons.h)
    {
        static const unsigned char bookmark14[784] = {
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x58,0x73,0xD0,0x17, 0x5A,0x74,0xD0,0x87, 0x58,0x73,0xD0,0xD3,
            0x54,0x70,0xCF,0xFB, 0x4E,0x6C,0xCD,0xFB, 0x45,0x64,0xCB,0xD3,
            0x3C,0x5C,0xC8,0x87, 0x32,0x56,0xC6,0x17, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x5F,0x78,0xD2,0x5B, 0x64,0x7D,0xD3,0xEC,
            0x6E,0x86,0xDB,0xFF, 0x6C,0x85,0xDB,0xFF, 0x67,0x80,0xDA,0xFF,
            0x5F,0x7B,0xD7,0xFF, 0x56,0x74,0xD5,0xFF, 0x4B,0x6B,0xD2,0xFF,
            0x38,0x5B,0xC7,0xEC, 0x2D,0x52,0xC4,0x5B, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x5F,0x78,0xD2,0x5B,
            0x70,0x88,0xDC,0xFF, 0x78,0x8E,0xDE,0xFF, 0x7B,0x91,0xDF,0xFF,
            0x78,0x8E,0xDE,0xFF, 0x70,0x88,0xDC,0xFF, 0x67,0x80,0xDA,0xFF,
            0x5C,0x78,0xD7,0xFF, 0x51,0x6F,0xD4,0xFF, 0x45,0x67,0xD0,0xFF,
            0x39,0x5D,0xCD,0xFF, 0x25,0x4C,0xC2,0x5B, 0x00,0x00,0x00,0x00,
            0x58,0x73,0xD0,0x17, 0x64,0x7D,0xD3,0xEC, 0x78,0x8E,0xDE,0xFF,
            0x82,0x96,0xE1,0xFF, 0x87,0x99,0xE2,0xFF, 0x82,0x96,0xE1,0xFF,
            0x78,0x8E,0xDE,0xFF, 0x6C,0x85,0xDB,0xFF, 0x60,0x7B,0xD8,0xFF,
            0x54,0x73,0xD4,0xFF, 0x48,0x69,0xD1,0xFF, 0x3C,0x5F,0xCE,0xFF,
            0x28,0x4D,0xC3,0xEC, 0x1B,0x43,0xBF,0x17, 0x5A,0x74,0xD0,0x87,
            0x6E,0x86,0xDB,0xFF, 0x7B,0x91,0xDF,0xFF, 0x87,0x99,0xE2,0xFF,
            0x8D,0x9F,0xE2,0xFF, 0x87,0x99,0xE2,0xFF, 0x7B,0x91,0xDF,0xFF,
            0x6E,0x86,0xDB,0xFF, 0x62,0x7E,0xD8,0xFF, 0x56,0x74,0xD5,0xFF,
            0x49,0x69,0xD2,0xFF, 0x3D,0x60,0xCE,0xFF, 0x30,0x55,0xCB,0xFF,
            0x1C,0x44,0xBF,0x87, 0x58,0x73,0xD0,0xD3, 0x6C,0x85,0xDB,0xFF,
            0x78,0x8E,0xDE,0xFF, 0x82,0x96,0xE1,0xFF, 0x87,0x99,0xE2,0xFF,
            0x82,0x96,0xE1,0xFF, 0x78,0x8E,0xDE,0xFF, 0x6C,0x85,0xDB,0xFF,
            0x60,0x7B,0xD8,0xFF, 0x54,0x73,0xD4,0xFF, 0x48,0x69,0xD1,0xFF,
            0x3C,0x5F,0xCE,0xFF, 0x30,0x55,0xCB,0xFF, 0x1B,0x43,0xBF,0xD3,
            0x54,0x70,0xCF,0xFB, 0x67,0x80,0xDA,0xFF, 0x70,0x88,0xDC,0xFF,
            0x78,0x8E,0xDE,0xFF, 0x7B,0x91,0xDF,0xFF, 0x78,0x8E,0xDE,0xFF,
            0x70,0x88,0xDC,0xFF, 0x67,0x80,0xDA,0xFF, 0x5C,0x78,0xD7,0xFF,
            0x51,0x6F,0xD4,0xFF, 0x45,0x67,0xD0,0xFF, 0x39,0x5D,0xCD,0xFF,
            0x2D,0x54,0xCA,0xFF, 0x19,0x42,0xBF,0xFB, 0x4E,0x6C,0xCD,0xFB,
            0x5F,0x7B,0xD7,0xFF, 0x67,0x80,0xDA,0xFF, 0x6C,0x85,0xDB,0xFF,
            0x6E,0x86,0xDB,0xFF, 0x6C,0x85,0xDB,0xFF, 0x67,0x80,0xDA,0xFF,
            0x5F,0x7B,0xD7,0xFF, 0x56,0x74,0xD5,0xFF, 0x4B,0x6B,0xD2,0xFF,
            0x40,0x63,0xCF,0xFF, 0x35,0x59,0xCC,0xFF, 0x29,0x51,0xC9,0xFF,
            0x16,0x40,0xBE,0xFB, 0x45,0x64,0xCB,0xD3, 0x56,0x74,0xD5,0xFF,
            0x5C,0x78,0xD7,0xFF, 0x60,0x7B,0xD8,0xFF, 0x62,0x7E,0xD8,0xFF,
            0x60,0x7B,0xD8,0xFF, 0x5C,0x78,0xD7,0xFF, 0x56,0x74,0xD5,0xFF,
            0x4D,0x6C,0xD3,0xFF, 0x44,0x65,0xD0,0xFF, 0x3A,0x5E,0xCE,0xFF,
            0x30,0x55,0xCB,0xFF, 0x25,0x4C,0xC8,0xFF, 0x11,0x3B,0xBD,0xD3,
            0x3C,0x5C,0xC8,0x87, 0x4B,0x6B,0xD2,0xFF, 0x51,0x6F,0xD4,0xFF,
            0x54,0x73,0xD4,0xFF, 0x56,0x74,0xD5,0xFF, 0x54,0x73,0xD4,0xFF,
            0x51,0x6F,0xD4,0xFF, 0x4B,0x6B,0xD2,0xFF, 0x44,0x65,0xD0,0xFF,
            0x3C,0x5F,0xCE,0xFF, 0x32,0x58,0xCB,0xFF, 0x29,0x50,0xC9,0xFF,
            0x1E,0x48,0xC6,0xFF, 0x11,0x3B,0xBD,0x87, 0x32,0x56,0xC6,0x17,
            0x38,0x5B,0xC7,0xEC, 0x45,0x67,0xD0,0xFF, 0x48,0x69,0xD1,0xFF,
            0x49,0x69,0xD2,0xFF, 0x48,0x69,0xD1,0xFF, 0x45,0x67,0xD0,0xFF,
            0x40,0x63,0xCF,0xFF, 0x3A,0x5E,0xCE,0xFF, 0x32,0x58,0xCB,0xFF,
            0x2A,0x51,0xC9,0xFF, 0x21,0x4A,0xC7,0xFF, 0x11,0x3B,0xBD,0xEC,
            0x11,0x3B,0xBD,0x17, 0x00,0x00,0x00,0x00, 0x2D,0x52,0xC4,0x5B,
            0x39,0x5D,0xCD,0xFF, 0x3C,0x5F,0xCE,0xFF, 0x3D,0x60,0xCE,0xFF,
            0x3C,0x5F,0xCE,0xFF, 0x39,0x5D,0xCD,0xFF, 0x35,0x59,0xCC,0xFF,
            0x30,0x55,0xCB,0xFF, 0x29,0x50,0xC9,0xFF, 0x21,0x4A,0xC7,0xFF,
            0x19,0x43,0xC5,0xFF, 0x11,0x3B,0xBD,0x5B, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x25,0x4C,0xC2,0x5B,
            0x28,0x4D,0xC3,0xEC, 0x30,0x55,0xCB,0xFF, 0x30,0x55,0xCB,0xFF,
            0x2D,0x54,0xCA,0xFF, 0x29,0x51,0xC9,0xFF, 0x25,0x4C,0xC8,0xFF,
            0x1E,0x48,0xC6,0xFF, 0x11,0x3B,0xBD,0xEC, 0x11,0x3B,0xBD,0x5B,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x1B,0x43,0xBF,0x17,
            0x1C,0x44,0xBF,0x87, 0x1B,0x43,0xBF,0xD3, 0x19,0x42,0xBF,0xFB,
            0x16,0x40,0xBE,0xFB, 0x11,0x3B,0xBD,0xD3, 0x11,0x3B,0xBD,0x87,
            0x11,0x3B,0xBD,0x17, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00
        };
        [sci message:SCI_RGBAIMAGESETWIDTH  wParam:14 lParam:0];
        [sci message:SCI_RGBAIMAGESETHEIGHT wParam:14 lParam:0];
        [sci message:SCI_RGBAIMAGESETSCALE  wParam:190 lParam:0];
        [sci message:SCI_MARKERDEFINERGBAIMAGE wParam:kBookmarkMarker lParam:(sptr_t)bookmark14];
    }

    // ── Hide-lines markers (markers 18 & 19) — green arrows from Windows NPP ─
    {
        // 14×14 RGBA icons from Windows NPP rgba_icons.h (hidelines_begin14, hidelines_end14)
        static const unsigned char hidelines_begin14[784] = {
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x49,0xA6,0x72,0xFF, 0x4A,0xA7,0x73,0xFF,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x47,0xA4,0x70,0xFF, 0x68,0xB6,0x8B,0xFF, 0x48,0xA5,0x71,0xFF,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x45,0xA2,0x6E,0xFF,
            0x8E,0xCA,0xA8,0xFF, 0x64,0xB3,0x87,0xFF, 0x46,0xA3,0x6F,0xFF,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x43,0xA0,0x6C,0xFF, 0x86,0xC5,0xA2,0xFF,
            0x86,0xC6,0xA2,0xFF, 0x60,0xB0,0x83,0xFF, 0x44,0xA1,0x6D,0xFF,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x41,0x9E,0x6A,0xFF, 0x7D,0xC1,0x9B,0xFF, 0x7E,0xC1,0x9C,0xFF,
            0x80,0xC2,0x9D,0xFF, 0x5D,0xAE,0x81,0xFF, 0x43,0xA0,0x6C,0xFF,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x3F,0x9C,0x68,0xFF,
            0x75,0xBC,0x95,0xFF, 0x76,0xBD,0x95,0xFF, 0x78,0xBE,0x97,0xFF,
            0x7B,0xBF,0x99,0xFF, 0x5B,0xAD,0x7F,0xFF, 0x41,0x9E,0x6A,0xFF,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x3D,0x9A,0x66,0xFF, 0x6D,0xB8,0x8E,0xFF,
            0x6E,0xB8,0x8F,0xFF, 0x70,0xB9,0x90,0xFF, 0x74,0xBB,0x93,0xFF,
            0x79,0xBE,0x97,0xFF, 0x59,0xAB,0x7D,0xFF, 0x3F,0x9C,0x68,0xFF,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x3C,0x99,0x65,0xFF, 0x64,0xB3,0x87,0xFF, 0x66,0xB4,0x88,0xFF,
            0x68,0xB5,0x8A,0xFF, 0x6D,0xB8,0x8E,0xFF, 0x72,0xBA,0x92,0xFF,
            0x51,0xA6,0x76,0xFF, 0x3D,0x9A,0x66,0xFF, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x3A,0x97,0x63,0xFF,
            0x5C,0xAE,0x80,0xFF, 0x5E,0xAF,0x82,0xFF, 0x61,0xB1,0x84,0xFF,
            0x67,0xB4,0x89,0xFF, 0x4C,0xA3,0x72,0xFF, 0x3B,0x98,0x64,0xFF,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x38,0x95,0x61,0xFF, 0x54,0xAA,0x7A,0xFF,
            0x56,0xAB,0x7C,0xFF, 0x5B,0xAE,0x80,0xFF, 0x46,0x9F,0x6D,0xFF,
            0x39,0x96,0x62,0xFF, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x36,0x93,0x5F,0xFF, 0x4C,0xA5,0x73,0xFF, 0x4F,0xA7,0x76,0xFF,
            0x41,0x9B,0x68,0xFF, 0x37,0x94,0x60,0xFF, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x34,0x91,0x5D,0xFF,
            0x44,0xA1,0x6D,0xFF, 0x3C,0x97,0x64,0xFF, 0x35,0x92,0x5E,0xFF,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x32,0x8F,0x5B,0xFF, 0x3A,0x96,0x63,0xFF,
            0x32,0x8F,0x5B,0xFF, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x30,0x8D,0x59,0xFF, 0x30,0x8D,0x59,0xFF, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00
        };
        static const unsigned char hidelines_end14[784] = {
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x4A,0xA7,0x73,0xFF, 0x49,0xA6,0x72,0xFF,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x48,0xA5,0x71,0xFF,
            0x68,0xB6,0x8B,0xFF, 0x47,0xA4,0x70,0xFF, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x46,0xA3,0x6F,0xFF, 0x64,0xB3,0x87,0xFF, 0x8E,0xCA,0xA8,0xFF,
            0x45,0xA2,0x6E,0xFF, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x44,0xA1,0x6D,0xFF, 0x60,0xB0,0x83,0xFF,
            0x86,0xC6,0xA2,0xFF, 0x86,0xC5,0xA2,0xFF, 0x43,0xA0,0x6C,0xFF,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x43,0xA0,0x6C,0xFF,
            0x5D,0xAE,0x81,0xFF, 0x80,0xC2,0x9D,0xFF, 0x7E,0xC1,0x9C,0xFF,
            0x7D,0xC1,0x9B,0xFF, 0x41,0x9E,0x6A,0xFF, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x41,0x9E,0x6A,0xFF, 0x5B,0xAD,0x7F,0xFF, 0x7B,0xBF,0x99,0xFF,
            0x78,0xBE,0x97,0xFF, 0x76,0xBD,0x95,0xFF, 0x75,0xBC,0x95,0xFF,
            0x3F,0x9C,0x68,0xFF, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x3F,0x9C,0x68,0xFF, 0x59,0xAB,0x7D,0xFF,
            0x79,0xBE,0x97,0xFF, 0x74,0xBB,0x93,0xFF, 0x70,0xB9,0x90,0xFF,
            0x6E,0xB8,0x8F,0xFF, 0x6D,0xB8,0x8E,0xFF, 0x3D,0x9A,0x66,0xFF,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x3D,0x9A,0x66,0xFF, 0x51,0xA6,0x76,0xFF, 0x72,0xBA,0x92,0xFF,
            0x6D,0xB8,0x8E,0xFF, 0x68,0xB5,0x8A,0xFF, 0x66,0xB4,0x88,0xFF,
            0x64,0xB3,0x87,0xFF, 0x3C,0x99,0x65,0xFF, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x3B,0x98,0x64,0xFF, 0x4C,0xA3,0x72,0xFF, 0x67,0xB4,0x89,0xFF,
            0x61,0xB1,0x84,0xFF, 0x5E,0xAF,0x82,0xFF, 0x5C,0xAE,0x80,0xFF,
            0x3A,0x97,0x63,0xFF, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x39,0x96,0x62,0xFF, 0x46,0x9F,0x6D,0xFF, 0x5B,0xAE,0x80,0xFF,
            0x56,0xAB,0x7C,0xFF, 0x54,0xAA,0x7A,0xFF, 0x38,0x95,0x61,0xFF,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x37,0x94,0x60,0xFF, 0x41,0x9B,0x68,0xFF, 0x4F,0xA7,0x76,0xFF,
            0x4C,0xA5,0x73,0xFF, 0x36,0x93,0x5F,0xFF, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x35,0x92,0x5E,0xFF, 0x3C,0x97,0x64,0xFF, 0x44,0xA1,0x6D,0xFF,
            0x34,0x91,0x5D,0xFF, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x32,0x8F,0x5B,0xFF, 0x3A,0x96,0x63,0xFF, 0x32,0x8F,0x5B,0xFF,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
            0x30,0x8D,0x59,0xFF, 0x30,0x8D,0x59,0xFF, 0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00
        };
        [sci message:SCI_RGBAIMAGESETWIDTH  wParam:14 lParam:0];
        [sci message:SCI_RGBAIMAGESETHEIGHT wParam:14 lParam:0];
        [sci message:SCI_RGBAIMAGESETSCALE  wParam:190 lParam:0];
        [sci message:SCI_MARKERDEFINERGBAIMAGE wParam:kHideLinesBeginMarker lParam:(sptr_t)hidelines_begin14];
        [sci message:SCI_MARKERDEFINERGBAIMAGE wParam:kHideLinesEndMarker   lParam:(sptr_t)hidelines_end14];
    }

    // ── Hidden line green underline (Scintilla native element) ───────────────
    // RGB(0x77, 0xCC, 0x77) with full alpha, matching Windows NPP
    [sci message:SCI_SETELEMENTCOLOUR wParam:81 lParam:(sptr_t)(0xFF77CC77)]; // SC_ELEMENT_HIDDEN_LINE=81

    // ── Smart highlight indicator (indicator 8) ──────────────────────────────
    [sci message:SCI_INDICSETSTYLE wParam:kHighlightIndicator lParam:INDIC_ROUNDBOX];
    [sci message:SCI_INDICSETFORE  wParam:kHighlightIndicator
           lParam:sciColor([NSColor colorWithRed:1.0 green:0.85 blue:0.0 alpha:1])];
    [sci message:SCI_INDICSETALPHA wParam:kHighlightIndicator lParam:80];

    // ── Mark-style indicators (indicators 9-13, styles 1-5) ──────────────────
    for (int i = 0; i < 5; i++) {
        [sci message:SCI_INDICSETSTYLE wParam:(uptr_t)kMarkInds[i] lParam:INDIC_ROUNDBOX];
        [sci message:SCI_INDICSETFORE  wParam:(uptr_t)kMarkInds[i] lParam:kMarkColors[i]];
        [sci message:SCI_INDICSETALPHA wParam:(uptr_t)kMarkInds[i] lParam:90];
        [sci message:SCI_INDICSETUNDER wParam:(uptr_t)kMarkInds[i] lParam:1]; // draw under text
    }

    // ── Spell-check indicator (slot 17, INDIC_SQUIGGLE, red) ─────────────────
    [sci message:SCI_INDICSETSTYLE wParam:kSpellIndicator lParam:INDIC_SQUIGGLE];
    [sci message:SCI_INDICSETFORE  wParam:kSpellIndicator lParam:0x0000FF]; // red (BGR)

    // ── Git diff line-highlight indicator (slot 18, INDIC_FULLBOX, pink) ─────
    [sci message:SCI_INDICSETSTYLE       wParam:kGitDiffIndicator lParam:INDIC_FULLBOX];
    [sci message:SCI_INDICSETFORE        wParam:kGitDiffIndicator lParam:0xB469FF]; // hot pink BGR (#FF69B4)
    [sci message:SCI_INDICSETALPHA       wParam:kGitDiffIndicator lParam:55];
    [sci message:SCI_INDICSETOUTLINEALPHA wParam:kGitDiffIndicator lParam:55];
    [sci message:SCI_INDICSETUNDER       wParam:kGitDiffIndicator lParam:1]; // draw under text

    // ── Git gutter markers (margin 4, 4px, slots 6-8) ────────────────────────
    [sci message:SCI_MARKERDEFINE  wParam:kGitMarkerAdded    lParam:SC_MARK_LEFTRECT];
    [sci message:SCI_MARKERSETBACK wParam:kGitMarkerAdded    lParam:0x44CC2E]; // green BGR
    [sci message:SCI_MARKERDEFINE  wParam:kGitMarkerModified lParam:SC_MARK_LEFTRECT];
    [sci message:SCI_MARKERSETBACK wParam:kGitMarkerModified lParam:0x12C3F3]; // orange BGR
    [sci message:SCI_MARKERDEFINE  wParam:kGitMarkerDeleted  lParam:SC_MARK_ARROWDOWN];
    [sci message:SCI_MARKERSETBACK wParam:kGitMarkerDeleted  lParam:0x3C74E7]; // red BGR
    [sci message:SCI_SETMARGINTYPEN  wParam:kGitGutterMargin lParam:SC_MARGIN_SYMBOL];
    [sci message:SCI_SETMARGINMASKN  wParam:kGitGutterMargin
           lParam:(1 << kGitMarkerAdded) | (1 << kGitMarkerModified) | (1 << kGitMarkerDeleted)];
    [sci message:SCI_SETMARGINWIDTHN wParam:kGitGutterMargin lParam:4];
    [sci message:SCI_SETMARGINSENSITIVEN wParam:kGitGutterMargin lParam:0];

    // Whitespace symbols (spaces/tabs) always rendered in red when made visible.
    // Setting this once here makes it persist for the lifetime of the editor,
    // including for newly typed characters — matching Windows NPP behavior.
    [sci message:SCI_SETWHITESPACEFORE wParam:1 lParam:0x0000FF]; // red (BGR)

    // Cache layout of the visible page for better performance on long lines.
    [sci message:SCI_SETLAYOUTCACHE wParam:SC_CACHE_PAGE];

    // Apply user preferences (tab width, line numbers, wrap, etc.)
    [self applyPreferencesFromDefaults];

    // Apply any ScintillaKeys overrides from shortcuts.xml
    [self applyScintillaKeyOverrides];

    // Force scroll view re-layout so the ruler view (margins) frame covers
    // the full visible area — prevents half-visible fold connecting lines.
    SCIScrollView *sv = (SCIScrollView *)_scintillaView.scrollView;
    [sv tile];
    [sv.verticalRulerView setNeedsDisplay:YES];
}

// ── Scintilla key overrides ──────────────────────────────────────────────────

/// Convert a Windows virtual key code (used in shortcuts.xml) to the key code
/// that Scintilla Cocoa uses internally (from event.charactersIgnoringModifiers).
static int vkToScintillaKey(int vk) {
    // Navigation keys → SCK_* constants (match Scintilla's KeyTranslate output)
    switch (vk) {
        case 8:   return 8;    // SCK_BACK (Backspace)
        case 9:   return 9;    // SCK_TAB
        case 13:  return 13;   // SCK_RETURN
        case 27:  return 7;    // SCK_ESCAPE
        case 33:  return 306;  // SCK_PRIOR (Page Up)
        case 34:  return 307;  // SCK_NEXT (Page Down)
        case 35:  return 305;  // SCK_END
        case 36:  return 304;  // SCK_HOME
        case 37:  return 302;  // SCK_LEFT
        case 38:  return 301;  // SCK_UP
        case 39:  return 303;  // SCK_RIGHT
        case 40:  return 300;  // SCK_DOWN
        case 45:  return 309;  // SCK_INSERT
        case 46:  return 308;  // SCK_DELETE
        default:  break;
    }
    // Function keys: VK F1-F12 (112-123) → NSF*FunctionKey (0xF704-0xF70F)
    // Scintilla Cocoa receives these Unicode values from charactersIgnoringModifiers
    if (vk >= 112 && vk <= 123)
        return 0xF704 + (vk - 112);
    // OEM special characters: VK codes → actual ASCII from charactersIgnoringModifiers
    switch (vk) {
        case 186: return ';';   // VK_OEM_1
        case 187: return '=';   // VK_OEM_PLUS
        case 188: return ',';   // VK_OEM_COMMA
        case 189: return '-';   // VK_OEM_MINUS
        case 190: return '.';   // VK_OEM_PERIOD
        case 191: return '/';   // VK_OEM_2
        case 192: return '`';   // VK_OEM_3
        case 219: return '[';   // VK_OEM_4
        case 220: return '\\';  // VK_OEM_5
        case 221: return ']';   // VK_OEM_6
        case 222: return '\'';  // VK_OEM_7
        default:  break;
    }
    // Uppercase letters → lowercase (Scintilla uses lowercase from charactersIgnoringModifiers)
    if (vk >= 'A' && vk <= 'Z')
        return vk + 32;
    // Digits and others pass through
    return vk;
}

// Accurate macOS default keymap for the Shortcut-Mapper commands — GENERATED from
// the real Scintilla tables (scintilla/src/KeyMap.cxx MapDefault +
// scintilla/cocoa/ScintillaCocoa.mm macMapDefault) by tools/gen_keymap.py. Maps each
// command's sciID to the REAL key combo(s) that trigger it by default (keyDef =
// sckKey | (mod<<16)), so an override can (a) clear the right keys — including
// multi-bound commands like ⌘Up AND ⌘Home → DocumentStart — and (b) restore them on
// reset. Built from the same source the editor's keymap is, so re-asserting these is
// a byte-for-byte no-op at construction. Regenerate if the Scintilla tables change.
static const struct SciDefaultKeys { int sciID; int n; sptr_t combos[4]; } kSciDefaultKeys[] = {
    { 2013, 2, { 0x20041, 0x20061, 0, 0 } },  // SCI_SELECTALL
    { 2180, 1, { 0x134, 0, 0, 0 } },  // SCI_CLEAR
    { 2176, 2, { 0x2005A, 0x2007A, 0, 0 } },  // SCI_UNDO
    { 2011, 2, { 0x20059, 0x3007A, 0, 0 } },  // SCI_REDO
    { 2329, 2, { 0xD, 0x1000D, 0, 0 } },  // SCI_NEWLINE
    { 2327, 1, { 0x9, 0, 0, 0 } },  // SCI_TAB
    { 2328, 1, { 0x10009, 0, 0, 0 } },  // SCI_BACKTAB
    { 2333, 1, { 0x20136, 0, 0, 0 } },  // SCI_ZOOMIN
    { 2334, 1, { 0x20137, 0, 0, 0 } },  // SCI_ZOOMOUT
    { 2373, 1, { 0x20138, 0, 0, 0 } },  // SCI_SETZOOM
    { 2469, 2, { 0x20044, 0x20064, 0, 0 } },  // SCI_SELECTIONDUPLICATE
    { 2324, 1, { 0x135, 0, 0, 0 } },  // SCI_EDITTOGGLEOVERTYPE
    { 2300, 1, { 0x12C, 0, 0, 0 } },  // SCI_LINEDOWN
    { 2301, 1, { 0x1012C, 0, 0, 0 } },  // SCI_LINEDOWNEXTEND
    { 2426, 1, { 0x5012C, 0, 0, 0 } },  // SCI_LINEDOWNRECTEXTEND
    { 2342, 1, { 0x10012C, 0, 0, 0 } },  // SCI_LINESCROLLDOWN
    { 2302, 1, { 0x12D, 0, 0, 0 } },  // SCI_LINEUP
    { 2303, 1, { 0x1012D, 0, 0, 0 } },  // SCI_LINEUPEXTEND
    { 2427, 1, { 0x5012D, 0, 0, 0 } },  // SCI_LINEUPRECTEXTEND
    { 2343, 1, { 0x10012D, 0, 0, 0 } },  // SCI_LINESCROLLUP
    { 2413, 1, { 0x2005D, 0, 0, 0 } },  // SCI_PARADOWN
    { 2414, 1, { 0x3005D, 0, 0, 0 } },  // SCI_PARADOWNEXTEND
    { 2415, 1, { 0x2005B, 0, 0, 0 } },  // SCI_PARAUP
    { 2416, 1, { 0x3005B, 0, 0, 0 } },  // SCI_PARAUPEXTEND
    { 2304, 1, { 0x12E, 0, 0, 0 } },  // SCI_CHARLEFT
    { 2305, 1, { 0x1012E, 0, 0, 0 } },  // SCI_CHARLEFTEXTEND
    { 2428, 1, { 0x5012E, 0, 0, 0 } },  // SCI_CHARLEFTRECTEXTEND
    { 2306, 1, { 0x12F, 0, 0, 0 } },  // SCI_CHARRIGHT
    { 2307, 1, { 0x1012F, 0, 0, 0 } },  // SCI_CHARRIGHTEXTEND
    { 2429, 1, { 0x5012F, 0, 0, 0 } },  // SCI_CHARRIGHTRECTEXTEND
    { 2308, 2, { 0x4012E, 0x10012E, 0, 0 } },  // SCI_WORDLEFT
    { 2309, 1, { 0x11012E, 0, 0, 0 } },  // SCI_WORDLEFTEXTEND
    { 2310, 2, { 0x4012F, 0x10012F, 0, 0 } },  // SCI_WORDRIGHT
    { 2311, 1, { 0x11012F, 0, 0, 0 } },  // SCI_WORDRIGHTEXTEND
    { 2390, 1, { 0x2002F, 0, 0, 0 } },  // SCI_WORDPARTLEFT
    { 2391, 1, { 0x3002F, 0, 0, 0 } },  // SCI_WORDPARTLEFTEXTEND
    { 2392, 1, { 0x2005C, 0, 0, 0 } },  // SCI_WORDPARTRIGHT
    { 2393, 1, { 0x3005C, 0, 0, 0 } },  // SCI_WORDPARTRIGHTEXTEND
    { 2345, 1, { 0x40130, 0, 0, 0 } },  // SCI_HOMEDISPLAY
    { 2331, 2, { 0x130, 0x2012E, 0, 0 } },  // SCI_VCHOME
    { 2332, 2, { 0x10130, 0x3012E, 0, 0 } },  // SCI_VCHOMEEXTEND
    { 2431, 1, { 0x50130, 0, 0, 0 } },  // SCI_VCHOMERECTEXTEND
    { 2314, 2, { 0x131, 0x2012F, 0, 0 } },  // SCI_LINEEND
    { 2315, 2, { 0x10131, 0x3012F, 0, 0 } },  // SCI_LINEENDEXTEND
    { 2432, 1, { 0x50131, 0, 0, 0 } },  // SCI_LINEENDRECTEXTEND
    { 2347, 1, { 0x40131, 0, 0, 0 } },  // SCI_LINEENDDISPLAY
    { 2316, 2, { 0x2012D, 0x20130, 0, 0 } },  // SCI_DOCUMENTSTART
    { 2317, 2, { 0x3012D, 0x30130, 0, 0 } },  // SCI_DOCUMENTSTARTEXTEND
    { 2318, 2, { 0x2012C, 0x20131, 0, 0 } },  // SCI_DOCUMENTEND
    { 2319, 2, { 0x3012C, 0x30131, 0, 0 } },  // SCI_DOCUMENTENDEXTEND
    { 2320, 1, { 0x132, 0, 0, 0 } },  // SCI_PAGEUP
    { 2321, 1, { 0x10132, 0, 0, 0 } },  // SCI_PAGEUPEXTEND
    { 2433, 1, { 0x50132, 0, 0, 0 } },  // SCI_PAGEUPRECTEXTEND
    { 2322, 1, { 0x133, 0, 0, 0 } },  // SCI_PAGEDOWN
    { 2323, 1, { 0x10133, 0, 0, 0 } },  // SCI_PAGEDOWNEXTEND
    { 2434, 1, { 0x50133, 0, 0, 0 } },  // SCI_PAGEDOWNRECTEXTEND
    { 2326, 2, { 0x8, 0x10008, 0, 0 } },  // SCI_DELETEBACK
    { 2335, 2, { 0x20008, 0x40008, 0, 0 } },  // SCI_DELWORDLEFT
    { 2395, 1, { 0x30008, 0, 0, 0 } },  // SCI_DELLINELEFT
    { 2396, 2, { 0x20134, 0x30134, 0, 0 } },  // SCI_DELLINERIGHT
    { 2338, 2, { 0x3004C, 0x3006C, 0, 0 } },  // SCI_LINEDELETE
    { 2337, 2, { 0x2004C, 0x2006C, 0, 0 } },  // SCI_LINECUT
    { 2455, 2, { 0x30054, 0x30074, 0, 0 } },  // SCI_LINECOPY
    { 2339, 2, { 0x20054, 0x20074, 0, 0 } },  // SCI_LINETRANSPOSE
    { 2177, 3, { 0x10134, 0x20058, 0x20078, 0 } },  // SCI_CUT
    { 2178, 3, { 0x20043, 0x20063, 0x20135, 0 } },  // SCI_COPY
    { 2179, 3, { 0x10135, 0x20056, 0x20076, 0 } },  // SCI_PASTE
    { 2325, 1, { 0x7, 0, 0, 0 } },  // SCI_CANCEL
};

static const struct SciDefaultKeys *sciDefaultKeysFor(int sciID) {
    for (size_t i = 0; i < sizeof(kSciDefaultKeys)/sizeof(kSciDefaultKeys[0]); i++)
        if (kSciDefaultKeys[i].sciID == sciID) return &kSciDefaultKeys[i];
    return NULL;
}

// Push the user's Scintilla-command shortcut overrides (from ~/Library/Application Support/Nextpad++/shortcuts.xml)
// into this editor's Scintilla keymap. Called once at construction and live on every
// NPPShortcutsChangedNotification (via MainWindowController). Authoritative-per-command:
// an overridden command's REAL default key(s) are cleared so the original stops firing,
// then the user's key is bound — fixing both the "both work" and "no effect" bugs. With
// no overrides (and none ever applied) it returns immediately, leaving the stock keymap
// untouched, so non-customising users see zero change.
- (void)applyScintillaKeyOverrides {
    NSString *path = NppConfigSubpath(@"shortcuts.xml");
    NSData *data = [NSData dataWithContentsOfFile:path];

    // Parse the overrides into a flat list first (sciID, keyCode, keyDef).
    NSMutableArray<NSDictionary *> *overrides = [NSMutableArray array];
    if (data) {
        NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:nil];
        NSArray *scintKeys = doc ? [doc nodesForXPath:@"//ScintillaKeys/ScintKey" error:nil] : nil;
        for (NSXMLElement *sk in scintKeys) {
            int sciID   = [[[sk attributeForName:@"ScintID"] stringValue] intValue];
            int keyCode = [[[sk attributeForName:@"Key"]     stringValue] intValue];
            BOOL hasCtrl  = [[[sk attributeForName:@"Ctrl"]  stringValue] isEqualToString:@"yes"];
            BOOL hasAlt   = [[[sk attributeForName:@"Alt"]   stringValue] isEqualToString:@"yes"];
            BOOL hasShift = [[[sk attributeForName:@"Shift"] stringValue] isEqualToString:@"yes"];
            BOOL hasCmd   = [[[sk attributeForName:@"Cmd"]   stringValue] isEqualToString:@"yes"];
            // Backward compat: old files without Cmd attribute treat Ctrl as Command
            if (!hasCmd && hasCtrl && ![sk attributeForName:@"Cmd"]) { hasCmd = YES; hasCtrl = NO; }
            // On macOS Scintilla: Command → SCMOD_CTRL(2), Control → SCMOD_META(16)
            int mods = 0;
            if (hasCmd)   mods |= 2;
            if (hasCtrl)  mods |= 16;
            if (hasAlt)   mods |= 4;
            if (hasShift) mods |= 1;
            sptr_t keyDef = (sptr_t)vkToScintillaKey(keyCode) | (mods << 16);
            [overrides addObject:@{ @"sciID": @(sciID), @"keyCode": @(keyCode), @"keyDef": @(keyDef) }];
        }
    }

    BOOL hasOverrides = overrides.count > 0;
    // Zero-impact guard: with no overrides and none ever applied to this editor, leave
    // Scintilla's stock keymap exactly as constructed (identical to pre-Phase-2 behaviour).
    if (!hasOverrides && !_scintillaOverridesApplied) return;

    ScintillaView *sci = _scintillaView;

    // Step A — restore every mapper command's REAL default key combo(s). Identity at
    // construction (the keymap already holds them); on a live re-apply this undoes any
    // default a prior override had cleared, so removing/resetting an override restores it.
    for (size_t i = 0; i < sizeof(kSciDefaultKeys)/sizeof(kSciDefaultKeys[0]); i++) {
        const struct SciDefaultKeys *d = &kSciDefaultKeys[i];
        for (int j = 0; j < d->n; j++)
            [sci message:2070 wParam:(uptr_t)d->combos[j] lParam:d->sciID]; // SCI_ASSIGNCMDKEY
    }

    // Step B — apply each override authoritatively: clear the command's default combo(s)
    // so the original key stops firing (fixes "both work", incl. multi-bound commands),
    // then bind the user's chosen key (or leave the command unbound if the user cleared it).
    for (NSDictionary *o in overrides) {
        int sciID   = [o[@"sciID"]   intValue];
        int keyCode = [o[@"keyCode"] intValue];
        const struct SciDefaultKeys *d = sciDefaultKeysFor(sciID);
        if (d) for (int j = 0; j < d->n; j++)
            [sci message:2071 wParam:(uptr_t)d->combos[j] lParam:0]; // SCI_CLEARCMDKEY
        if (keyCode != 0)
            [sci message:2070 wParam:(uptr_t)[o[@"keyDef"] longLongValue] lParam:sciID]; // SCI_ASSIGNCMDKEY
    }

    _scintillaOverridesApplied = hasOverrides;

    // The RTL caret-key swap sits on top of the keymap; re-assert it if this editor is
    // currently RTL, since Step A/B may have rewritten the Left/Right caret bindings.
    if (self.isTextDirectionRTL) [self _applyRTLKeyBindings:YES];

    NSLog(@"[EditorView] Scintilla key overrides: %lu applied%@",
          (unsigned long)overrides.count, hasOverrides ? @"" : @" (none — defaults restored)");
}

#pragma mark - Preferences

/// Resize the line-number margin (margin 0) to fit the current line count
/// at the current zoom level. No-op when line numbers are hidden or when
/// kPrefLineNumDynWidth is OFF (in that case the fixed 44 px set by
/// applyPreferencesFromDefaults remains in effect). Called from:
///   • applyPreferencesFromDefaults  (theme / pref change, font change)
///   • SCN_ZOOM                      (every zoom step — Scintilla raises
///     this after the new zoom is committed, so SCI_TEXTWIDTH returns
///     post-zoom pixels)
/// SCI_TEXTWIDTH measures a ~10-char string (~µs) and SCI_SETMARGINWIDTHN
/// short-circuits on unchanged width, so the helper is cheap to call on
/// every zoom step even for very large files.
- (void)recomputeLineNumberMargin {
    ScintillaView *sci = _scintillaView;
    if (!sci) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (![ud boolForKey:kPrefShowLineNumbers]) return;
    if (![ud boolForKey:kPrefLineNumDynWidth]) return;

    sptr_t lineCount = [sci message:SCI_GETLINECOUNT];
    NSString *measure = [NSString stringWithFormat:@"_%ld", (long)lineCount];
    sptr_t width = [sci message:SCI_TEXTWIDTH wParam:STYLE_LINENUMBER
                          lParam:(sptr_t)measure.UTF8String];
    if (width < 30) width = 30;
    [sci message:SCI_SETMARGINWIDTHN wParam:0 lParam:width];
}

- (void)applyPreferencesFromDefaults {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    ScintillaView *sci = _scintillaView;

    // ── Per-language indent settings ──
    // Priority: user override → langs.xml tabSettings → global default
    NSInteger tabWidth = [ud integerForKey:kPrefTabWidth];
    if (tabWidth < 1) tabWidth = 4;
    BOOL useTabs = [ud boolForKey:kPrefUseTabs];

    NSString *lang = _currentLanguage.lowercaseString;
    if (lang.length) {
        NSDictionary *overrides = [ud dictionaryForKey:kPrefTabOverrides];
        NSDictionary *langOverride = overrides[lang];
        if (langOverride) {
            // User has explicit override for this language
            tabWidth = [langOverride[@"tabSize"] integerValue];
            if (tabWidth < 1) tabWidth = 4;
            useTabs = [langOverride[@"useTabs"] boolValue];
        } else {
            // Check langs.xml built-in tabSettings (e.g. Python=132 → 4 spaces)
            NppLangDef *def = [[NppLangsManager shared] langDefForName:lang];
            if (def && def.tabSettings >= 0) {
                NSInteger ts = def.tabSettings;
                NSInteger xmlTabSize = ts & 0x7F;
                BOOL xmlUseSpaces = (ts & 0x80) != 0;
                if (xmlTabSize > 0) {
                    tabWidth = xmlTabSize;
                    useTabs = !xmlUseSpaces;
                }
            }
        }
    }

    [sci message:SCI_SETTABWIDTH wParam:(uptr_t)tabWidth];
    [sci message:SCI_SETUSETABS wParam:useTabs ? 1 : 0];

    BOOL bsUnindent = [ud boolForKey:kPrefBackspaceUnindent];
    [sci message:SCI_SETBACKSPACEUNINDENTS wParam:bsUnindent ? 1 : 0];
    [sci message:SCI_SETTABINDENTS wParam:bsUnindent ? 1 : 0];

    // Notepad++ "column selection to multi-editing": on Backspace/arrows a
    // column (rectangular) selection is first converted to a stream
    // multi-selection so the key acts per caret (e.g. Backspace at column 0
    // joins lines). Handled in SCIContentView keyDown:.
    sci.columnSelToMultiEdit = [ud boolForKey:kPrefColumnSel2MultiEdit];

    BOOL showLineNumbers = [ud boolForKey:kPrefShowLineNumbers];
    [sci message:SCI_SETMARGINWIDTHN wParam:0 lParam:showLineNumbers ? 44 : 0];

    BOOL hlLine = [ud boolForKey:kPrefHighlightCurrentLine];
    [sci message:SCI_SETCARETLINEVISIBLE wParam:hlLine ? 1 : 0];

    // Indentation guides — persisted toggle; the NPPPreferencesChanged
    // path re-runs this method on every editor when the toggle flips.
    BOOL showGuides = [ud boolForKey:kPrefShowIndentGuides];
    [sci message:SCI_SETINDENTATIONGUIDES wParam:(showGuides ? SC_IV_LOOKBOTH : SC_IV_NONE)];

    // Word wrap — persistent across launches. Read kPrefWordWrap so new
    // tabs inherit the saved state on creation. Toggling via toolbar/menu
    // writes here + propagates to all open editors via the
    // NPPWordWrapSessionChanged broadcast (universal-in-window-and-cross-window).
    // The Preferences > Editor checkbox writes here too and the standard
    // NPPPreferencesChanged path re-runs this method on every editor.
    BOOL wordWrap = [ud boolForKey:kPrefWordWrap];
    _wordWrapEnabled = wordWrap;
    [sci message:SCI_SETWRAPMODE wParam:wordWrap ? SC_WRAP_WORD : SC_WRAP_NONE];

    NSInteger zoomLevel = [ud integerForKey:kPrefZoomLevel];
    [sci message:SCI_SETZOOM wParam:(uptr_t)zoomLevel];

    // ── Caret width (1-3 pixels) ──
    {
        NSInteger caretW = [ud integerForKey:kPrefCaretWidth];
        if (caretW < 1) caretW = 1;
        if (caretW > 3) caretW = 3;
        [sci message:SCI_SETCARETWIDTH wParam:(uptr_t)caretW];
    }

    // ── Virtual space ──
    // SCVS_RECTANGULARSELECTION (1) is always on so Option+drag column selection
    // extends cleanly past line ends (matching Windows NPP behavior).
    // SCVS_USERACCESSIBLE (2) is controlled by user preference.
    {
        int vsOpts = SCVS_RECTANGULARSELECTION;
        if ([ud boolForKey:kPrefVirtualSpace]) vsOpts |= SCVS_USERACCESSIBLE;
        [sci message:SCI_SETVIRTUALSPACEOPTIONS wParam:vsOpts];
    }

    // ── Scroll beyond last line ──
    [sci message:SCI_SETENDATLASTLINE wParam:[ud boolForKey:kPrefScrollBeyondLastLine] ? 0 : 1];

    // ── Caret blink rate ──
    {
        NSInteger rate = [ud integerForKey:kPrefCaretBlinkRate];
        if (rate < 0) rate = 0; // 0 = no blink
        [sci message:SCI_SETCARETPERIOD wParam:(uptr_t)rate];
    }

    // ── Font quality ──
    [sci message:SCI_SETFONTQUALITY wParam:(uptr_t)[ud integerForKey:kPrefFontQuality]];

    // ── Show EOL markers ──
    [sci message:SCI_SETVIEWEOL wParam:[ud boolForKey:kPrefShowEOL] ? 1 : 0];

    // ── Show whitespace ──
    [sci message:SCI_SETVIEWWS wParam:[ud boolForKey:kPrefShowWhitespace] ? 1 : 0]; // 1=SCWS_VISIBLEALWAYS

    // ── Bookmark margin ──
    [sci message:SCI_SETMARGINWIDTHN wParam:1 lParam:[ud boolForKey:kPrefShowBookmarkMargin] ? 14 : 0];

    // ── Edge column indicator ──
    {
        NSInteger edgeMode = [ud integerForKey:kPrefEdgeMode];
        NSInteger edgeCol  = [ud integerForKey:kPrefEdgeColumn];
        [sci message:SCI_SETEDGEMODE   wParam:(uptr_t)edgeMode];
        [sci message:SCI_SETEDGECOLUMN wParam:(uptr_t)edgeCol];
        [sci message:SCI_SETEDGECOLOUR wParam:0xCCCCCC]; // light gray edge line
    }

    // ── Padding ──
    [sci message:SCI_SETMARGINLEFT  wParam:0 lParam:[ud integerForKey:kPrefPaddingLeft]];
    [sci message:SCI_SETMARGINRIGHT wParam:0 lParam:[ud integerForKey:kPrefPaddingRight]];

    // ── Line number dynamic width ──
    // Falls back to the fixed 44 px just set above when dyn-width is OFF.
    [self recomputeLineNumberMargin];

    // ── Fold margin style ──
    {
        NSInteger foldStyle = [ud integerForKey:kPrefFoldStyle];
        if (foldStyle == 4) {
            // None — hide fold margin
            [sci message:SCI_SETMARGINWIDTHN wParam:3 lParam:0];
        } else {
            [sci message:SCI_SETMARGINWIDTHN wParam:3 lParam:12];
            int plus, minus, plusC, minusC, mid, tail, sub;
            switch (foldStyle) {
                case 1: // Circle
                    plus=SC_MARK_CIRCLEPLUS; minus=SC_MARK_CIRCLEMINUS;
                    plusC=SC_MARK_CIRCLEPLUSCONNECTED; minusC=SC_MARK_CIRCLEMINUSCONNECTED;
                    mid=SC_MARK_TCORNERCURVE; tail=SC_MARK_LCORNERCURVE; sub=SC_MARK_VLINE;
                    break;
                case 2: // Arrow
                    plus=SC_MARK_ARROWDOWN; minus=SC_MARK_ARROW;
                    plusC=SC_MARK_ARROWDOWN; minusC=SC_MARK_ARROW;
                    mid=SC_MARK_EMPTY; tail=SC_MARK_EMPTY; sub=SC_MARK_EMPTY;
                    break;
                case 3: // Simple +/-
                    plus=SC_MARK_PLUS; minus=SC_MARK_MINUS;
                    plusC=SC_MARK_PLUS; minusC=SC_MARK_MINUS;
                    mid=SC_MARK_EMPTY; tail=SC_MARK_EMPTY; sub=SC_MARK_EMPTY;
                    break;
                default: // 0 = Box (default)
                    plus=SC_MARK_BOXPLUS; minus=SC_MARK_BOXMINUS;
                    plusC=SC_MARK_BOXPLUSCONNECTED; minusC=SC_MARK_BOXMINUSCONNECTED;
                    mid=SC_MARK_TCORNERCURVE; tail=SC_MARK_LCORNERCURVE; sub=SC_MARK_VLINE;
                    break;
            }
            [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDER        lParam:plus];
            [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEROPEN    lParam:minus];
            [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEREND     lParam:plusC];
            [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEROPENMID lParam:minusC];
            [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERMIDTAIL lParam:mid];
            [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERTAIL    lParam:tail];
            [sci message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERSUB     lParam:sub];
        }
    }

    // ── Disable text drag-drop ──
    // Note: SCI_SETMOUSEDWELLTIME can disable drag; we use a simpler approach
    // by not processing drag events when disabled (handled in Scintilla Cocoa)

    // ── Delimiter pane / word-char list (issue #42) ──
    // SCI_SETWORDCHARS is per-document; we also re-apply at the end of
    // loadFileAtPath: so the new doc (post-Phase-2 always-swap) inherits the
    // user's setting.
    [self applyWordCharsFromDefaults];

    // ── Clickable links (issue #133) ──
    // Full-clear the whole document indicator then re-mark the visible range.
    // This runs on pref changes (enable/style) and reloads — not on scroll —
    // so a live toggle-off wipes stale links everywhere, not just on-screen.
    {
        ScintillaView *s = _scintillaView;
        [s message:SCI_SETINDICATORCURRENT wParam:kClickableLinkIndicator];
        [s message:SCI_INDICATORCLEARRANGE wParam:0 lParam:[s message:SCI_GETLENGTH]];
        [self updateClickableLinks];
    }

    // Issue #149 — apply line-spacing multiplier here too (idempotent with the
    // applyThemeColors call). Covers pref changes that don't change the theme.
    [self applyLineSpacingFromDefaults];
}

// Cached at first read so subsequent loads don't have to round-trip through
// Scintilla. Reads SCI_GETWORDCHARS from a fresh view (Scintilla's stock
// default per-class table). Falls back to a known-good ASCII set if Scintilla
// returns nothing — should never trigger but keeps us defensive.
static NSString *nppDefaultWordChars(ScintillaView *sci) {
    static NSString *cached = nil;
    if (cached) return cached;
    sptr_t len = [sci message:SCI_GETWORDCHARS wParam:0 lParam:0];
    if (len > 0) {
        char *buf = (char *)malloc((size_t)len + 1);
        if (buf) {
            [sci message:SCI_GETWORDCHARS wParam:0 lParam:(sptr_t)buf];
            buf[len] = '\0';
            cached = [[NSString alloc] initWithUTF8String:buf] ?:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";
            free(buf);
            return cached;
        }
    }
    cached = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";
    return cached;
}

// Apply the effective word-char set to Scintilla, derived from kPrefWordChars*.
// Use-default → restore Scintilla's stock list. Custom → stock + user chars not
// already present (matches Windows addCustomWordChars de-duplication). Only
// printable ASCII from kPrefWordCharsAdded is honored; SCI_SETWORDCHARS treats
// the payload as a byte set, so non-ASCII bytes would be meaningless.
- (void)applyWordCharsFromDefaults {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    ScintillaView *sci = _scintillaView;
    NSString *defaultList = nppDefaultWordChars(sci);

    if ([ud boolForKey:kPrefWordCharsUseDefault]) {
        [sci message:SCI_SETWORDCHARS wParam:0 lParam:(sptr_t)defaultList.UTF8String];
        return;
    }

    NSString *added = [ud stringForKey:kPrefWordCharsAdded] ?: @"";
    if (added.length == 0) {
        [sci message:SCI_SETWORDCHARS wParam:0 lParam:(sptr_t)defaultList.UTF8String];
        return;
    }

    NSMutableString *combined = [defaultList mutableCopy];
    for (NSUInteger i = 0; i < added.length; i++) {
        unichar c = [added characterAtIndex:i];
        if (c < 0x20 || c > 0x7E) continue;  // printable ASCII only
        NSString *one = [NSString stringWithCharacters:&c length:1];
        if ([defaultList rangeOfString:one].location == NSNotFound)
            [combined appendString:one];
    }
    [sci message:SCI_SETWORDCHARS wParam:0 lParam:(sptr_t)combined.UTF8String];
}

- (void)_preferencesChanged:(NSNotification *)note {
    [self applyPreferencesFromDefaults];
    // Re-apply theme colors if the notification carries a theme-change flag
    NSNumber *themeChanged = note.userInfo[@"themeChanged"];
    if (themeChanged.boolValue) [self applyThemeColors];
}

#pragma mark - Keywords

- (void)applyKeywords:(NSString *)lang {
    ScintillaView *sci = _scintillaView;
    lang = lang.lowercaseString;

    // Some languages share lexers — map to the canonical language for keyword lookup.
    // c, objc, swift all use the cpp lexer; javascript.js uses javascript.
    NSString *kwLang = lang;
    if ([@[@"c", @"objc"] containsObject:lang]) kwLang = @"cpp";
    if ([lang isEqualToString:@"javascript.js"]) kwLang = @"javascript";

    NppLangsManager *lm = [NppLangsManager shared];
    BOOL fed = NO;

    // Keyword class names → Scintilla SCI_SETKEYWORDS index.
    // The mapping follows the most common pattern used by Scintilla lexers:
    // instre1→0, type1→1, instre2→2, type2→3, type3→4, type4→5, type5→6, type6→7, type7→8
    static NSDictionary<NSString *, NSNumber *> *kwClassToIndex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kwClassToIndex = @{
            @"instre1": @0, @"type1": @1, @"instre2": @2,
            @"type2": @3, @"type3": @4, @"type4": @5,
            @"type5": @6, @"type6": @7, @"type7": @8,
        };
    });

    // Issue #28 — LexHTML's WordListSet uses bespoke slot semantics that
    // diverge from the universal `instre1=0` convention. The slot layout
    // (htmlWordListDesc[] in lexilla/lexers/LexHTML.cxx) is:
    //   0 = HTML elements & attributes (lowercased)
    //   1 = JavaScript keywords
    //   2 = VBScript keywords
    //   3 = Python keywords
    //   4 = PHP keywords
    //   5 = SGML/DTD keywords
    // langs.xml exposes each language's keywords under `instre1` (and HTML
    // also under `instre2` for DTD), so without an override:
    //   • PHP keywords land in slot 0 → never matched as SCE_HPHP_WORD
    //   • ASP/VB keywords land in slot 0 → never matched as SCE_HB_WORD
    //   • HTML's instre2 (DTD) lands in slot 2 (VBScript) → never matched
    //   • XML's instre1 (DTD) lands in slot 0 → never matched
    // All other 127 Lexilla lexers follow `slot 0 = primary keywords`, so the
    // generic mapping is correct for them. The override only triggers for
    // LexHTML-family languages.
    NSDictionary<NSString *, NSNumber *> *idxOverride = nil;
    if ([kwLang isEqualToString:@"php"]) {
        idxOverride = @{ @"instre1": @4 };               // PHP keywords
    } else if ([kwLang isEqualToString:@"asp"]) {
        idxOverride = @{ @"instre1": @2 };               // VBScript keywords
    } else if ([kwLang isEqualToString:@"html"]) {
        idxOverride = @{ @"instre2": @5 };               // SGML/DTD; instre1 already correct (HTML tags → slot 0)
    } else if ([kwLang isEqualToString:@"xml"]) {
        idxOverride = @{ @"instre1": @5 };               // SGML/DTD
    }

    // Feed keywords from langs.xml for all keyword classes
    for (NSString *kwClass in kwClassToIndex) {
        NSString *kw = [lm keywordsForLanguage:kwLang keywordClass:kwClass];
        if (!kw.length) continue;
        NSNumber *ov = idxOverride[kwClass];
        NSInteger idx = ov ? ov.integerValue : kwClassToIndex[kwClass].integerValue;
        const char *utf8 = kw.UTF8String;
        [sci message:SCI_SETKEYWORDS wParam:(uptr_t)idx lParam:(sptr_t)utf8];
        fed = YES;
    }

    if (fed) return;

    // Hardcoded fallback for the 4 languages that had keywords before langs.xml
    if ([kwLang isEqualToString:@"cpp"]) {
        const char *kw = "alignas alignof and and_eq asm auto bitand bitor bool break case catch char "
            "char8_t char16_t char32_t class compl concept const consteval constexpr constinit "
            "const_cast continue co_await co_return co_yield decltype default delete do double "
            "dynamic_cast else enum explicit export extern false float for friend goto if inline "
            "int long mutable namespace new noexcept not not_eq nullptr operator or or_eq private "
            "protected public register reinterpret_cast requires return short signed sizeof static "
            "static_assert static_cast struct switch template this thread_local throw true try "
            "typedef typeid typename union unsigned using virtual void volatile wchar_t while "
            "xor xor_eq";
        [sci message:SCI_SETKEYWORDS wParam:0 lParam:(sptr_t)kw];
    } else if ([kwLang isEqualToString:@"python"]) {
        const char *kw = "False None True and as assert async await break class continue def del "
            "elif else except finally for from global if import in is lambda nonlocal not or "
            "pass raise return try while with yield";
        [sci message:SCI_SETKEYWORDS wParam:0 lParam:(sptr_t)kw];
    } else if ([kwLang isEqualToString:@"javascript"]) {
        const char *kw = "async await break case catch class const continue debugger default "
            "delete do else export extends false finally for from function if import in "
            "instanceof let new null of return static super switch this throw true try typeof "
            "undefined var void while with yield";
        [sci message:SCI_SETKEYWORDS wParam:0 lParam:(sptr_t)kw];
    } else if ([kwLang isEqualToString:@"sql"]) {
        const char *kw = "add all alter and any as asc authorization backup begin between by "
            "cascade case check close clustered coalesce column commit compute constraint "
            "contains containstable continue convert create cross current current_date "
            "current_time cursor database dbcc deallocate declare default delete deny desc "
            "distinct distributed double drop dump else end errlvl escape except exec execute "
            "exists exit external fetch file fillfactor for foreign freetext freetexttable "
            "from full function goto grant group having holdlock identity identitycol "
            "identity_insert if in index inner insert intersect into is join key kill left "
            "like lineno load merge national nocheck nonclustered not null nullif of off "
            "offsets on open opendatasource openquery openrowset openxml option or order outer "
            "over percent pivot plan precision primary print proc procedure public raiserror "
            "read readtext reconfigure references replication restore restrict return revert "
            "revoke right rollback rowcount rowguidcol rule save schema securityaudit select "
            "semantickeyphrasetable semanticsimilaritydetailstable semanticsimilaritytable "
            "session_user set setuser shutdown some statistics system_user table tablesample "
            "textsize then to top tran transaction trigger truncate try_convert tsequal "
            "union unique unpivot update updatetext use user values varying view waitfor when "
            "where while with within group writetext";
        [sci message:SCI_SETKEYWORDS wParam:0 lParam:(sptr_t)kw];
    }
}

static const int kBookmarkMarker       = 20;
static const int kHideLinesBeginMarker = 19; // green ▶ arrow on line BEFORE hidden range
static const int kHideLinesEndMarker   = 18; // green ◀ arrow on line AFTER hidden range
static const int kHighlightIndicator   =  8; // INDICATOR_CONTAINER = 8, avoids lexer indicators 0-7

// 5 mark-style indicators (9-13): Scintilla BGR colors (b<<16|g<<8|r)
static const int     kMarkInds[5]    = { 9, 10, 11, 12, 13 };
static const sptr_t  kMarkColors[5]  = {
    0xFFFF00, // style 1: cyan   (R=0,   G=255, B=255)
    0x00FFFF, // style 2: yellow (R=255, G=255, B=0  )
    0x00C800, // style 3: green  (R=0,   G=200, B=0  )
    0x0078FF, // style 4: orange (R=255, G=120, B=0  )
    0xFF64C8, // style 5: violet (R=200, G=100, B=255)
};

// Spell-check indicator (slot 17, INDIC_SQUIGGLE red)
static const int kSpellIndicator = 17;

// Git diff line-highlight indicator (slot 18, INDIC_FULLBOX, pink)
static const int kGitDiffIndicator = 18;

// Clickable-link indicator (slot 19, issue #133). Style derived from prefs
// (underline vs colored text; fullbox hover).
static const int kClickableLinkIndicator = 19;

// Git gutter marker slots — must be 0-19 (0-24 are user-definable, but 21-24
// are used by change-history and 25-31 are reserved for fold markers).
static const int kGitMarkerAdded    = 6;
static const int kGitMarkerModified = 7;
static const int kGitMarkerDeleted  = 8;
static const int kGitGutterMargin   = 4;  // margin index for git gutter

#pragma mark - Lexer Colors

- (void)applyLexerColors:(NSString *)lang {
    if (!lang.length) return;
    ScintillaView *sci = _scintillaView;

    // Map EditorView language names to NPP style-store lexer IDs
    NSString *lid = lang.lowercaseString;
    if ([lid isEqualToString:@"c"] || [lid isEqualToString:@"objc"]) lid = @"cpp";
    else if ([lid isEqualToString:@"javascript"] || [lid isEqualToString:@"typescript"])
                                                                      lid = @"cpp";

    NPPStyleStore *store = [NPPStyleStore sharedStore];
    NSArray<NPPStyleEntry *> *styles = [store stylesForLexer:lid];
    if (!styles.count) return;

    // Global override (issue #149 — Windows parity). The source of the
    // substituted values is the dedicated "Global override" row inside
    // GlobalStyles — NOT "Default Style". Mirrors ScintillaEditView.cpp:900
    // (findByName(L"Global override")). When an attribute is "transparent"
    // on the override row (nil fg/bg, empty fontName, fontSize=0), the
    // corresponding per-style attribute is left to fall back to STYLE_DEFAULT
    // (we skip the SCI_STYLESET* call). Caller has just run STYLECLEARALL.
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL ovFg        = [d boolForKey:kPrefGlobalOverrideEnableFg];
    BOOL ovBg        = [d boolForKey:kPrefGlobalOverrideEnableBg];
    BOOL ovFont      = [d boolForKey:kPrefGlobalOverrideEnableFont];
    BOOL ovFontSize  = [d boolForKey:kPrefGlobalOverrideEnableFontSize];
    BOOL ovBold      = [d boolForKey:kPrefGlobalOverrideEnableBold];
    BOOL ovItalic    = [d boolForKey:kPrefGlobalOverrideEnableItalic];
    BOOL ovUnderline = [d boolForKey:kPrefGlobalOverrideEnableUnderline];
    NPPStyleEntry *gov = (ovFg || ovBg || ovFont || ovFontSize ||
                          ovBold || ovItalic || ovUnderline)
                       ? [store globalStyleNamed:@"Global override"] : nil;

    for (NPPStyleEntry *e in styles) {
        int sid = e.styleID;

        // fg
        if (ovFg && gov) {
            if (gov.fgColor)
                [sci setColorProperty:SCI_STYLESETFORE parameter:sid value:gov.fgColor];
            // else: leave at STYLE_DEFAULT (transparent override → inherit)
        } else if (e.fgColor) {
            [sci setColorProperty:SCI_STYLESETFORE parameter:sid value:e.fgColor];
        }

        // bg
        if (ovBg && gov) {
            if (gov.bgColor)
                [sci setColorProperty:SCI_STYLESETBACK parameter:sid value:gov.bgColor];
        } else if (e.bgColor) {
            [sci setColorProperty:SCI_STYLESETBACK parameter:sid value:e.bgColor];
        }

        // font name
        if (ovFont && gov) {
            if (gov.fontName.length > 0)
                [sci message:SCI_STYLESETFONT wParam:sid lParam:(sptr_t)gov.fontName.UTF8String];
        } else if (e.fontName.length > 0) {
            [sci message:SCI_STYLESETFONT wParam:sid lParam:(sptr_t)e.fontName.UTF8String];
        }

        // font size
        if (ovFontSize && gov) {
            if (gov.fontSize > 0)
                [sci message:SCI_STYLESETSIZEFRACTIONAL wParam:sid lParam:(sptr_t)(gov.fontSize * 100)];
        } else if (e.fontSize > 0) {
            [sci message:SCI_STYLESETSIZEFRACTIONAL wParam:sid lParam:(sptr_t)(e.fontSize * 100)];
        }

        // bold / italic / underline — the override row's value substitutes
        // directly. Caller already pushed STYLE_DEFAULT's font-style bits,
        // so absent flags fall through to the default via STYLECLEARALL.
        BOOL bold      = (ovBold      && gov) ? gov.bold      : e.bold;
        BOOL italic    = (ovItalic    && gov) ? gov.italic    : e.italic;
        BOOL underline = (ovUnderline && gov) ? gov.underline : e.underline;
        [sci message:SCI_STYLESETBOLD      wParam:sid lParam:bold      ? 1 : 0];
        [sci message:SCI_STYLESETITALIC    wParam:sid lParam:italic    ? 1 : 0];
        [sci message:SCI_STYLESETUNDERLINE wParam:sid lParam:underline ? 1 : 0];
    }
}

#pragma mark - Word Wrap

- (BOOL)wordWrapEnabled { return _wordWrapEnabled; }
- (void)setWordWrapEnabled:(BOOL)enabled {
    _wordWrapEnabled = enabled;
    [_scintillaView message:SCI_SETWRAPMODE wParam:enabled ? SC_WRAP_WORD : SC_WRAP_NONE];
}

#pragma mark - Overwrite Mode

- (BOOL)isOverwriteMode { return [_scintillaView message:SCI_GETOVERTYPE] != 0; }

- (void)toggleOverwriteMode {
    BOOL ov = [_scintillaView message:SCI_GETOVERTYPE];
    [_scintillaView message:SCI_SETOVERTYPE wParam:!ov];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:EditorViewCursorDidMoveNotification object:self];
}

#pragma mark - Line Operations

- (void)duplicateLine:(id)sender { [_scintillaView message:SCI_LINEDUPLICATE]; }
- (void)deleteLine:(id)sender    { [_scintillaView message:SCI_LINEDELETE]; }
- (void)moveLineUp:(id)sender    { [_scintillaView message:SCI_MOVESELECTEDLINESUP]; }
- (void)moveLineDown:(id)sender  { [_scintillaView message:SCI_MOVESELECTEDLINESDOWN]; }

- (void)splitLines:(id)sender {
    // SCI_LINESSPLIT(pixelWidth=0) uses the current wrap width
    [_scintillaView message:SCI_LINESSPLIT wParam:0];
}

- (void)toggleLineComment:(id)sender {
    // Issue #85 — use the same XML-aware lookup as ^K / ^⇧K so languages
    // whose commentLine is declared in langs.xml (Fortran, VB, Lisp, Ada,
    // Erlang, PowerShell, Tcl, INI, LaTeX, PostScript, …) toggle with the
    // correct prefix instead of always falling back to "//".
    NSString *prefix = [self _lineCommentPrefix];
    if (!prefix.length) return;

    ScintillaView *sci = _scintillaView;
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];
    NSInteger firstLine = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selStart];
    NSInteger lastLine  = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selEnd];
    if (selEnd > selStart &&
        [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)lastLine] == selEnd) lastLine--;

    // Determine if all non-empty lines already start with the comment prefix
    BOOL allCommented = YES;
    for (NSInteger ln = firstLine; ln <= lastLine && allCommented; ln++) {
        sptr_t len = [sci message:SCI_LINELENGTH wParam:(uptr_t)ln];
        if (len <= 0) continue;
        char *buf = (char *)malloc((size_t)len + 1);
        if (!buf) continue;
        [sci message:SCI_GETLINE wParam:(uptr_t)ln lParam:(sptr_t)buf];
        buf[len] = '\0';
        NSInteger i = 0;
        while (i < len && (buf[i]==' ' || buf[i]=='\t')) i++;
        // skip empty/whitespace-only lines
        if (i >= len || buf[i]=='\r' || buf[i]=='\n') { free(buf); continue; }
        if (strncmp(buf + i, prefix.UTF8String, prefix.length) != 0) allCommented = NO;
        free(buf);
    }

    [sci message:SCI_BEGINUNDOACTION];
    for (NSInteger ln = firstLine; ln <= lastLine; ln++) {
        sptr_t len = [sci message:SCI_LINELENGTH wParam:(uptr_t)ln];
        if (len <= 0) continue;
        char *buf = (char *)malloc((size_t)len + 1);
        if (!buf) continue;
        [sci message:SCI_GETLINE wParam:(uptr_t)ln lParam:(sptr_t)buf];
        buf[len] = '\0';
        NSInteger i = 0;
        while (i < len && (buf[i]==' ' || buf[i]=='\t')) i++;
        if (i >= len || buf[i]=='\r' || buf[i]=='\n') { free(buf); continue; }
        sptr_t lineStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)ln];
        sptr_t insertPos = lineStart + i;
        if (allCommented) {
            // Remove prefix (and one trailing space if present)
            NSInteger removeLen = (NSInteger)prefix.length;
            if (i + removeLen < len && buf[i + removeLen] == ' ') removeLen++;
            [sci message:SCI_DELETERANGE wParam:(uptr_t)insertPos lParam:removeLen];
        } else {
            NSString *ins = [prefix stringByAppendingString:@" "];
            [sci message:SCI_INSERTTEXT wParam:(uptr_t)insertPos lParam:(sptr_t)ins.UTF8String];
        }
        free(buf);
    }
    [sci message:SCI_ENDUNDOACTION];
}

// Returns the single-line comment prefix for the current language.
- (NSString *)_lineCommentPrefix {
    // Try langs.xml first
    NSString *fromXML = [[NppLangsManager shared] commentLineForLanguage:_currentLanguage];
    if (fromXML) return fromXML;

    // Hardcoded fallback
    NSDictionary *commentMap = @{
        @"python":@"#", @"bash":@"#", @"ruby":@"#", @"perl":@"#",
        @"r":@"#", @"yaml":@"#", @"makefile":@"#", @"cmake":@"#", @"toml":@"#",
        @"sql":@"--", @"lua":@"--", @"haskell":@"--",
    };
    NSString *mapped = commentMap[_currentLanguage.lowercaseString];
    return mapped ?: @"//";
}

- (void)addSingleLineComment:(id)sender {
    NSString *prefix = [self _lineCommentPrefix];
    ScintillaView *sci = _scintillaView;
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];
    NSInteger firstLine = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selStart];
    NSInteger lastLine  = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selEnd];
    if (selEnd > selStart &&
        [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)lastLine] == selEnd) lastLine--;

    [sci message:SCI_BEGINUNDOACTION];
    for (NSInteger ln = firstLine; ln <= lastLine; ln++) {
        sptr_t len = [sci message:SCI_LINELENGTH wParam:(uptr_t)ln];
        if (len <= 0) continue;
        char *buf = (char *)malloc((size_t)len + 1);
        if (!buf) continue;
        [sci message:SCI_GETLINE wParam:(uptr_t)ln lParam:(sptr_t)buf];
        buf[len] = '\0';
        NSInteger i = 0;
        while (i < len && (buf[i]==' ' || buf[i]=='\t')) i++;
        if (i >= len || buf[i]=='\r' || buf[i]=='\n') { free(buf); continue; }
        sptr_t lineStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)ln];
        sptr_t insertPos = lineStart + i;
        NSString *ins = [prefix stringByAppendingString:@" "];
        [sci message:SCI_INSERTTEXT wParam:(uptr_t)insertPos lParam:(sptr_t)ins.UTF8String];
        free(buf);
    }
    [sci message:SCI_ENDUNDOACTION];
}

- (void)removeSingleLineComment:(id)sender {
    NSString *prefix = [self _lineCommentPrefix];
    ScintillaView *sci = _scintillaView;
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];
    NSInteger firstLine = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selStart];
    NSInteger lastLine  = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selEnd];
    if (selEnd > selStart &&
        [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)lastLine] == selEnd) lastLine--;

    [sci message:SCI_BEGINUNDOACTION];
    for (NSInteger ln = firstLine; ln <= lastLine; ln++) {
        sptr_t len = [sci message:SCI_LINELENGTH wParam:(uptr_t)ln];
        if (len <= 0) continue;
        char *buf = (char *)malloc((size_t)len + 1);
        if (!buf) continue;
        [sci message:SCI_GETLINE wParam:(uptr_t)ln lParam:(sptr_t)buf];
        buf[len] = '\0';
        NSInteger i = 0;
        while (i < len && (buf[i]==' ' || buf[i]=='\t')) i++;
        if (i >= len || buf[i]=='\r' || buf[i]=='\n') { free(buf); continue; }
        if (strncmp(buf + i, prefix.UTF8String, prefix.length) == 0) {
            sptr_t lineStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)ln];
            sptr_t removeStart = lineStart + i;
            NSInteger removeLen = (NSInteger)prefix.length;
            if (i + removeLen < len && buf[i + removeLen] == ' ') removeLen++;
            [sci message:SCI_DELETERANGE wParam:(uptr_t)removeStart lParam:removeLen];
        }
        free(buf);
    }
    [sci message:SCI_ENDUNDOACTION];
}

#pragma mark - Block Comment

/// Returns @[openDelimiter, closeDelimiter] for the current language, or nil.
- (nullable NSArray<NSString *> *)_blockCommentDelimiters {
    // Try langs.xml first
    NSString *start = [[NppLangsManager shared] commentStartForLanguage:_currentLanguage];
    NSString *end = [[NppLangsManager shared] commentEndForLanguage:_currentLanguage];
    if (start.length && end.length) return @[start, end];

    // Hardcoded fallback
    static NSDictionary<NSString *, NSArray<NSString *> *> *fallback;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fallback = @{
            @"c":@[@"/*",@"*/"], @"cpp":@[@"/*",@"*/"], @"objc":@[@"/*",@"*/"],
            @"javascript":@[@"/*",@"*/"], @"typescript":@[@"/*",@"*/"],
            @"swift":@[@"/*",@"*/"], @"css":@[@"/*",@"*/"], @"sql":@[@"/*",@"*/"],
            @"lua":@[@"--[[",@"]]"], @"html":@[@"<!--",@"-->"], @"xml":@[@"<!--",@"-->"],
        };
    });
    return fallback[_currentLanguage.lowercaseString];
}

- (void)toggleBlockComment:(id)sender {
    NSArray<NSString *> *pair = [self _blockCommentDelimiters];
    if (!pair) return;

    NSString *open  = pair[0];
    NSString *close = pair[1];
    ScintillaView *sci = _scintillaView;
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];

    // Check whether selection is already wrapped — if so, remove delimiters
    NSString *docText = sci.string;
    if ((sptr_t)docText.length >= selStart + (sptr_t)open.length + (sptr_t)close.length) {
        NSString *before = [docText substringWithRange:NSMakeRange((NSUInteger)selStart,
                                                                    (NSUInteger)open.length)];
        NSString *after  = selEnd >= (sptr_t)close.length
            ? [docText substringWithRange:NSMakeRange((NSUInteger)(selEnd - close.length),
                                                      (NSUInteger)close.length)]
            : @"";
        if ([before isEqualToString:open] && [after isEqualToString:close]) {
            [sci message:SCI_BEGINUNDOACTION];
            [sci message:SCI_DELETERANGE wParam:(uptr_t)(selEnd - close.length) lParam:(sptr_t)close.length];
            [sci message:SCI_DELETERANGE wParam:(uptr_t)selStart lParam:(sptr_t)open.length];
            [sci message:SCI_ENDUNDOACTION];
            return;
        }
    }

    // Wrap selection with open/close
    [sci message:SCI_BEGINUNDOACTION];
    [sci message:SCI_INSERTTEXT wParam:(uptr_t)selEnd   lParam:(sptr_t)close.UTF8String];
    [sci message:SCI_INSERTTEXT wParam:(uptr_t)selStart lParam:(sptr_t)open.UTF8String];
    [sci message:SCI_SETSEL
          wParam:(uptr_t)selStart
           lParam:selEnd + (sptr_t)(open.length + close.length)];
    [sci message:SCI_ENDUNDOACTION];
}

- (void)addBlockComment:(id)sender {
    NSArray<NSString *> *pair = [self _blockCommentDelimiters];
    if (!pair) { NSBeep(); return; }
    NSString *open = pair[0], *close = pair[1];
    ScintillaView *sci = _scintillaView;
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];
    [sci message:SCI_BEGINUNDOACTION];
    [sci message:SCI_INSERTTEXT wParam:(uptr_t)selEnd   lParam:(sptr_t)close.UTF8String];
    [sci message:SCI_INSERTTEXT wParam:(uptr_t)selStart lParam:(sptr_t)open.UTF8String];
    [sci message:SCI_ENDUNDOACTION];
}

- (void)removeBlockComment:(id)sender {
    NSArray<NSString *> *pair = [self _blockCommentDelimiters];
    if (!pair) { NSBeep(); return; }
    ScintillaView *sci = _scintillaView;
    NSString *docText = sci.string;
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];

    // Search backward from selStart for opening delimiter
    NSString *open = pair[0], *openTrim = [pair[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *close = pair[1], *closeTrim = [pair[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSUInteger searchStart = (NSUInteger)MAX(0LL, selStart - (sptr_t)open.length);
    NSRange openRange = [docText rangeOfString:open  options:NSBackwardsSearch
                                         range:NSMakeRange(0, (NSUInteger)selStart + open.length)];
    if (openRange.location == NSNotFound)
        openRange = [docText rangeOfString:openTrim options:NSBackwardsSearch
                                     range:NSMakeRange(0, (NSUInteger)selStart + openTrim.length)];
    (void)searchStart;

    NSUInteger closeSearchStart = (NSUInteger)MAX(0LL, selEnd - (sptr_t)close.length);
    NSRange closeRange = [docText rangeOfString:close options:0
                                          range:NSMakeRange(closeSearchStart, docText.length - closeSearchStart)];
    if (closeRange.location == NSNotFound) {
        NSUInteger cs2 = (NSUInteger)MAX(0LL, selEnd - (sptr_t)closeTrim.length);
        closeRange = [docText rangeOfString:closeTrim options:0
                                      range:NSMakeRange(cs2, docText.length - cs2)];
    }

    if (openRange.location == NSNotFound || closeRange.location == NSNotFound) { NSBeep(); return; }

    [sci message:SCI_BEGINUNDOACTION];
    // Remove close first (higher position) so start positions stay valid
    [sci message:SCI_DELETERANGE wParam:(uptr_t)closeRange.location lParam:(sptr_t)closeRange.length];
    [sci message:SCI_DELETERANGE wParam:(uptr_t)openRange.location  lParam:(sptr_t)openRange.length];
    [sci message:SCI_ENDUNDOACTION];
}

#pragma mark - Multi-Select

// Scintilla multi-selection message numbers
static const unsigned int kSCI_SetMultipleSelection     = 2563;
static const unsigned int kSCI_SetAdditionalSelTyping   = 2565;
static const unsigned int kSCI_GetSelections             = 2570;
static const unsigned int kSCI_AddSelection              = 2573;
static const unsigned int kSCI_SetMainSelection          = 2574;
static const unsigned int kSCI_GetSelectionNCaret        = 2577;
static const unsigned int kSCI_DropSelectionN            = 2671;
static const unsigned int kSCI_SetRectSelCaret           = 2588;
static const unsigned int kSCI_SetRectSelAnchor          = 2590;

- (BOOL)beginSelectActive { return _beginSelectActive; }

- (void)beginEndSelect:(id)sender {
    ScintillaView *sci = _scintillaView;
    if (!_beginSelectActive) {
        _beginSelectPos   = [sci message:SCI_GETCURRENTPOS];
        _beginSelectActive = YES;
    } else {
        sptr_t current = [sci message:SCI_GETCURRENTPOS];
        [sci message:SCI_SETSEL
              wParam:(uptr_t)MIN(_beginSelectPos, current)
               lParam:MAX(_beginSelectPos, current)];
        _beginSelectActive = NO;
    }
}

- (void)beginEndSelectColumnMode:(id)sender {
    ScintillaView *sci = _scintillaView;
    if (!_beginSelectActive) {
        _beginSelectPos   = [sci message:SCI_GETCURRENTPOS];
        _beginSelectActive = YES;
    } else {
        sptr_t current = [sci message:SCI_GETCURRENTPOS];
        [sci message:kSCI_SetRectSelAnchor wParam:(uptr_t)_beginSelectPos];
        [sci message:kSCI_SetRectSelCaret  wParam:(uptr_t)current];
        _beginSelectActive = NO;
    }
}

- (void)_enableMultiSelect {
    [_scintillaView message:kSCI_SetMultipleSelection   wParam:1];
    [_scintillaView message:kSCI_SetAdditionalSelTyping wParam:1];
}

- (NSString *)_currentSelectionOrWord {
    ScintillaView *sci = _scintillaView;
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];
    if (selStart == selEnd) {
        selStart = [sci message:SCI_WORDSTARTPOSITION wParam:(uptr_t)selStart lParam:1];
        selEnd   = [sci message:SCI_WORDENDPOSITION   wParam:(uptr_t)selEnd   lParam:1];
    }
    if (selStart >= selEnd) return nil;
    NSString *text = sci.string;
    NSUInteger len = (NSUInteger)(selEnd - selStart);
    if ((NSUInteger)selStart + len > text.length) return nil;
    return [text substringWithRange:NSMakeRange((NSUInteger)selStart, len)];
}

// ── Multi-Select helpers ─────────────────────────────────────────────────────

/// Check if character at pos is a word character (alphanumeric or underscore)
- (BOOL)_isWordCharAtPos:(sptr_t)pos inText:(NSString *)text {
    if (pos < 0 || (NSUInteger)pos >= text.length) return NO;
    unichar c = [text characterAtIndex:(NSUInteger)pos];
    return [[NSCharacterSet alphanumericCharacterSet] characterIsMember:c] || c == '_';
}

/// Check if match at range is a whole word (not part of a larger word)
- (BOOL)_isWholeWord:(NSRange)range inText:(NSString *)text {
    if (range.location > 0 && [self _isWordCharAtPos:(sptr_t)(range.location - 1) inText:text])
        return NO;
    NSUInteger end = range.location + range.length;
    if (end < text.length && [self _isWordCharAtPos:(sptr_t)end inText:text])
        return NO;
    return YES;
}

- (void)_multiSelectAll_matchCase:(BOOL)matchCase wholeWord:(BOOL)wholeWord {
    NSString *word = [self _currentSelectionOrWord];
    if (!word.length) return;
    ScintillaView *sci = _scintillaView;
    NSString *text = sci.string;
    [self _enableMultiSelect];

    NSStringCompareOptions opts = matchCase ? NSLiteralSearch : NSCaseInsensitiveSearch;
    BOOL first = YES;
    NSRange search = NSMakeRange(0, text.length);
    NSRange found;
    while ((found = [text rangeOfString:word options:opts range:search]).location != NSNotFound) {
        if (!wholeWord || [self _isWholeWord:found inText:text]) {
            uptr_t caret  = (uptr_t)(found.location + found.length);
            sptr_t anchor = (sptr_t)found.location;
            if (first) {
                [sci message:SCI_SETSEL wParam:caret lParam:anchor];
                first = NO;
            } else {
                [sci message:kSCI_AddSelection wParam:caret lParam:anchor];
            }
        }
        NSUInteger next = found.location + 1;
        if (next >= text.length) break;
        search = NSMakeRange(next, text.length - next);
    }
}

- (void)_multiSelectNext_matchCase:(BOOL)matchCase wholeWord:(BOOL)wholeWord {
    ScintillaView *sci = _scintillaView;
    NSString *word = [self _currentSelectionOrWord];
    if (!word.length) return;

    // If nothing was selected, select the word under caret first
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];
    if (selStart == selEnd) {
        selStart = [sci message:SCI_WORDSTARTPOSITION wParam:(uptr_t)selStart lParam:1];
        selEnd   = [sci message:SCI_WORDENDPOSITION   wParam:(uptr_t)selEnd   lParam:1];
        [sci message:SCI_SETSEL wParam:(uptr_t)selEnd lParam:selStart];
    }

    NSString *text = sci.string;
    NSStringCompareOptions opts = matchCase ? NSLiteralSearch : NSCaseInsensitiveSearch;

    // Find the furthest caret position across all current selections
    NSInteger n = [sci message:kSCI_GetSelections];
    sptr_t searchFrom = selEnd;
    for (NSInteger i = 0; i < n; i++) {
        sptr_t c = [sci message:kSCI_GetSelectionNCaret wParam:(uptr_t)i];
        if (c > searchFrom) searchFrom = c;
    }

    // Search forward from last selection, then wrap
    NSRange search = NSMakeRange((NSUInteger)searchFrom, text.length - (NSUInteger)searchFrom);
    BOOL wrapped = NO;
    while (YES) {
        NSRange found = [text rangeOfString:word options:opts range:search];
        if (found.location == NSNotFound) {
            if (wrapped) return;
            wrapped = YES;
            search = NSMakeRange(0, text.length);
            continue;
        }
        if (!wholeWord || [self _isWholeWord:found inText:text]) {
            [self _enableMultiSelect];
            [sci message:kSCI_AddSelection
                  wParam:(uptr_t)(found.location + found.length)
                   lParam:(sptr_t)found.location];
            return;
        }
        NSUInteger next = found.location + 1;
        if (next >= text.length) {
            if (wrapped) return;
            wrapped = YES;
            search = NSMakeRange(0, text.length);
        } else {
            search = NSMakeRange(next, text.length - next);
        }
    }
}

// Multi-Select All — 4 variants
- (void)multiSelectAllIgnoreCaseIgnoreWord:(id)sender  { [self _multiSelectAll_matchCase:NO  wholeWord:NO];  }
- (void)multiSelectAllMatchCaseOnly:(id)sender         { [self _multiSelectAll_matchCase:YES wholeWord:NO];  }
- (void)multiSelectAllWholeWordOnly:(id)sender         { [self _multiSelectAll_matchCase:NO  wholeWord:YES]; }
- (void)multiSelectAllMatchCaseWholeWord:(id)sender    { [self _multiSelectAll_matchCase:YES wholeWord:YES]; }

// Multi-Select Next — 4 variants
- (void)multiSelectNextIgnoreCaseIgnoreWord:(id)sender { [self _multiSelectNext_matchCase:NO  wholeWord:NO];  }
- (void)multiSelectNextMatchCaseOnly:(id)sender        { [self _multiSelectNext_matchCase:YES wholeWord:NO];  }
- (void)multiSelectNextWholeWordOnly:(id)sender        { [self _multiSelectNext_matchCase:NO  wholeWord:YES]; }
- (void)multiSelectNextMatchCaseWholeWord:(id)sender   { [self _multiSelectNext_matchCase:YES wholeWord:YES]; }

- (void)undoLatestMultiSelect:(id)sender {
    ScintillaView *sci = _scintillaView;
    NSInteger n = [sci message:kSCI_GetSelections];
    if (n <= 1) return;
    [sci message:kSCI_DropSelectionN wParam:(uptr_t)(n - 1)];
}

- (void)skipCurrentAndGoToNextMultiSelect:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t mainStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t mainEnd   = [sci message:SCI_GETSELECTIONEND];
    if (mainStart == mainEnd) return;
    NSString *text = sci.string;
    NSUInteger wordLen = (NSUInteger)(mainEnd - mainStart);
    if ((NSUInteger)mainStart + wordLen > text.length) return;
    NSString *word = [text substringWithRange:NSMakeRange((NSUInteger)mainStart, wordLen)];

    // Drop the main selection (index 0)
    NSInteger n = [sci message:kSCI_GetSelections];
    if (n > 1) {
        [sci message:kSCI_DropSelectionN wParam:0];
        [sci message:kSCI_SetMainSelection wParam:0];
    }

    // Find next occurrence after old mainEnd (case-sensitive, no whole-word)
    NSRange search = NSMakeRange((NSUInteger)mainEnd, text.length - (NSUInteger)mainEnd);
    NSRange found = [text rangeOfString:word options:NSLiteralSearch range:search];
    if (found.location == NSNotFound)
        found = [text rangeOfString:word options:NSLiteralSearch];
    if (found.location == NSNotFound) return;

    [self _enableMultiSelect];
    [sci message:kSCI_AddSelection
          wParam:(uptr_t)(found.location + found.length)
           lParam:(sptr_t)found.location];
}

#pragma mark - Blank / EOL Cleanup

/// Returns the first and last line numbers to process.
/// When text is selected, returns only lines in the selection; otherwise returns the whole document.
- (void)_selectionLineRange:(sptr_t *)outFirst last:(sptr_t *)outLast {
    ScintillaView *sci = _scintillaView;
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];
    if (selStart == selEnd) {
        *outFirst = 0;
        *outLast  = [sci message:SCI_GETLINECOUNT] - 1;
    } else {
        *outFirst = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selStart];
        *outLast  = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selEnd];
        // Don't include a line that is only selected by the anchor sitting at its start
        if ([sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)*outLast] == selEnd)
            (*outLast)--;
    }
}

- (void)removeUnnecessaryBlankAndEOL:(id)sender {
    [self trimTrailingWhitespace:sender];
    // Remove trailing blank lines at end of document
    ScintillaView *sci = _scintillaView;
    [sci message:SCI_BEGINUNDOACTION];
    sptr_t docLen = [sci message:SCI_GETLENGTH];
    sptr_t pos = docLen;
    while (pos > 0) {
        sptr_t ch = [sci message:SCI_GETCHARAT wParam:(uptr_t)(pos - 1)];
        if (ch == '\n' || ch == '\r') pos--;
        else break;
    }
    if (pos < docLen) {
        [sci message:SCI_SETTARGETRANGE wParam:(uptr_t)pos lParam:docLen];
        const char empty[] = "";
        [sci message:SCI_REPLACETARGET wParam:(uptr_t)-1 lParam:(sptr_t)empty];
    }
    [sci message:SCI_ENDUNDOACTION];
}

#pragma mark - Read-Only (internal clear)

- (void)clearReadOnlyFlag:(id)sender {
    // Force Scintilla read-only OFF (even if already off)
    [_scintillaView message:SCI_SETREADONLY wParam:0];
}

#pragma mark - Code Folding

// Issue #89 — Collapse All / Unfold All must include SC_FOLDACTION_CONTRACT_EVERY_LEVEL.
// Without this flag, Scintilla's Editor::FoldAll only sets SetFoldExpanded(false)
// on top-level (FoldLevel::Base) headers and skips past nested ranges via
// `line = lineMaxSubord;`. Nested headers stay internally marked as expanded —
// they're only hidden under their collapsed parent. When the user expands
// the parent, the nested ones reappear expanded. Setting the
// CONTRACT_EVERY_LEVEL flag drives the `else if (contractAll)` branch and
// explicitly contracts every nested header. Mirrors Windows NPP's
// ScintillaEditView::foldAll which OR's the same flag in for both directions.
- (void)foldAll:(id)sender    { [_scintillaView message:SCI_FOLDALL wParam:(SC_FOLDACTION_CONTRACT | SC_FOLDACTION_CONTRACT_EVERY_LEVEL)]; }
- (void)unfoldAll:(id)sender  { [_scintillaView message:SCI_FOLDALL wParam:(SC_FOLDACTION_EXPAND   | SC_FOLDACTION_CONTRACT_EVERY_LEVEL)]; }

- (void)foldCurrentLevel:(id)sender {
    sptr_t line = [_scintillaView message:SCI_LINEFROMPOSITION
                                   wParam:[_scintillaView message:SCI_GETCURRENTPOS]];
    sptr_t level = [_scintillaView message:SCI_GETFOLDLEVEL wParam:(uptr_t)line];
    if (level & SC_FOLDLEVELHEADERFLAG) {
        BOOL expanded = [_scintillaView message:SCI_GETFOLDEXPANDED wParam:(uptr_t)line];
        [_scintillaView message:SCI_FOLDLINE wParam:(uptr_t)line
                         lParam:expanded ? SC_FOLDACTION_CONTRACT : SC_FOLDACTION_EXPAND];
    }
}

#pragma mark - Bookmarks

- (void)toggleBookmark:(id)sender {
    sptr_t line = [_scintillaView message:SCI_LINEFROMPOSITION
                                   wParam:[_scintillaView message:SCI_GETCURRENTPOS]];
    sptr_t mask = [_scintillaView message:SCI_MARKERGET wParam:(uptr_t)line];
    if (mask & (1 << kBookmarkMarker))
        [_scintillaView message:SCI_MARKERDELETE wParam:(uptr_t)line lParam:kBookmarkMarker];
    else
        [_scintillaView message:SCI_MARKERADD wParam:(uptr_t)line lParam:kBookmarkMarker];
}

- (void)nextBookmark:(id)sender {
    sptr_t cur = [_scintillaView message:SCI_LINEFROMPOSITION
                                  wParam:[_scintillaView message:SCI_GETCURRENTPOS]];
    sptr_t found = [_scintillaView message:SCI_MARKERNEXT
                                    wParam:(uptr_t)(cur + 1) lParam:(1 << kBookmarkMarker)];
    if (found < 0) // wrap
        found = [_scintillaView message:SCI_MARKERNEXT wParam:0 lParam:(1 << kBookmarkMarker)];
    if (found >= 0) {
        [_scintillaView message:SCI_GOTOLINE wParam:(uptr_t)found];
        [_scintillaView message:SCI_SCROLLCARET];
    }
}

- (void)previousBookmark:(id)sender {
    sptr_t cur = [_scintillaView message:SCI_LINEFROMPOSITION
                                  wParam:[_scintillaView message:SCI_GETCURRENTPOS]];
    sptr_t found = [_scintillaView message:SCI_MARKERPREVIOUS
                                    wParam:(uptr_t)(cur - 1) lParam:(1 << kBookmarkMarker)];
    if (found < 0) { // wrap to end
        sptr_t last = [_scintillaView message:SCI_GETLINECOUNT] - 1;
        found = [_scintillaView message:SCI_MARKERPREVIOUS
                                 wParam:(uptr_t)last lParam:(1 << kBookmarkMarker)];
    }
    if (found >= 0) {
        [_scintillaView message:SCI_GOTOLINE wParam:(uptr_t)found];
        [_scintillaView message:SCI_SCROLLCARET];
    }
}

- (void)clearAllBookmarks:(id)sender {
    [_scintillaView message:SCI_MARKERDELETEALL wParam:kBookmarkMarker];
}

#pragma mark - Navigation

- (void)goToLineNumber:(NSInteger)lineNumber {
    ScintillaView *sci = _scintillaView;
    NSInteger total = [sci message:SCI_GETLINECOUNT];
    lineNumber = MAX(1, MIN(lineNumber, total));
    sptr_t line0 = lineNumber - 1;

    // Center the target line vertically on screen
    sptr_t linesOnScreen = [sci message:SCI_LINESONSCREEN];
    sptr_t topLine = line0 - linesOnScreen / 2;
    if (topLine < 0) topLine = 0;
    [sci message:SCI_SETFIRSTVISIBLELINE wParam:(uptr_t)topLine];

    // Select the entire line (highlight it)
    sptr_t lineStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)line0];
    sptr_t lineEnd   = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)line0];
    [sci message:SCI_SETSEL wParam:(uptr_t)lineStart lParam:lineEnd];
    [sci message:SCI_SCROLLCARET];
}

#pragma mark - Change History Navigation

// Only jump to unsaved modifications (not saved/reverted-to-origin lines)
static const int kHistoryMask = (1 << SC_MARKNUM_HISTORY_MODIFIED);

- (void)goToNextChange:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t cur = [sci message:SCI_LINEFROMPOSITION
                       wParam:(uptr_t)[sci message:SCI_GETCURRENTPOS]];
    sptr_t count = [sci message:SCI_GETLINECOUNT];

    // Skip past the current block of modified lines
    sptr_t ln = cur + 1;
    while (ln < count && ([sci message:SCI_MARKERGET wParam:(uptr_t)ln] & kHistoryMask))
        ln++;
    // Now find the start of the next modified block
    while (ln < count) {
        if ([sci message:SCI_MARKERGET wParam:(uptr_t)ln] & kHistoryMask) {
            [sci message:SCI_GOTOLINE wParam:(uptr_t)ln];
            [sci message:SCI_SCROLLCARET];
            return;
        }
        ln++;
    }
    // Wrap: search from top
    for (ln = 0; ln < cur; ln++) {
        if ([sci message:SCI_MARKERGET wParam:(uptr_t)ln] & kHistoryMask) {
            [sci message:SCI_GOTOLINE wParam:(uptr_t)ln];
            [sci message:SCI_SCROLLCARET];
            return;
        }
    }
    NSBeep();
}

- (void)goToPreviousChange:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t cur = [sci message:SCI_LINEFROMPOSITION
                       wParam:(uptr_t)[sci message:SCI_GETCURRENTPOS]];
    sptr_t count = [sci message:SCI_GETLINECOUNT];

    // Skip past the current block of modified lines going backward
    sptr_t ln = cur - 1;
    while (ln >= 0 && ([sci message:SCI_MARKERGET wParam:(uptr_t)ln] & kHistoryMask))
        ln--;
    // Now find the end of the previous modified block, then jump to its start
    while (ln >= 0) {
        if ([sci message:SCI_MARKERGET wParam:(uptr_t)ln] & kHistoryMask) {
            // Found the end of a block — walk back to its start
            sptr_t blockStart = ln;
            while (blockStart > 0 && ([sci message:SCI_MARKERGET wParam:(uptr_t)(blockStart - 1)] & kHistoryMask))
                blockStart--;
            [sci message:SCI_GOTOLINE wParam:(uptr_t)blockStart];
            [sci message:SCI_SCROLLCARET];
            return;
        }
        ln--;
    }
    // Wrap: search from bottom
    for (ln = count - 1; ln > cur; ln--) {
        if ([sci message:SCI_MARKERGET wParam:(uptr_t)ln] & kHistoryMask) {
            sptr_t blockStart = ln;
            while (blockStart > 0 && ([sci message:SCI_MARKERGET wParam:(uptr_t)(blockStart - 1)] & kHistoryMask))
                blockStart--;
            [sci message:SCI_GOTOLINE wParam:(uptr_t)blockStart];
            [sci message:SCI_SCROLLCARET];
            return;
        }
    }
    NSBeep();
}

- (void)clearAllChanges:(id)sender {
    ScintillaView *sci = _scintillaView;
    // Disable then re-enable to reset all history markers
    [sci message:SCI_SETCHANGEHISTORY wParam:SC_CHANGE_HISTORY_DISABLED];
    [sci message:SCI_SETCHANGEHISTORY wParam:SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS];
}

#pragma mark - Incremental Search (highlight all matches)

static const int kIndicatorIncSearch = 28; // Scintilla indicator slot for incremental search

- (void)highlightAllMatches:(NSString *)text matchCase:(BOOL)mc {
    ScintillaView *sci = _scintillaView;
    // Clear previous incremental search highlights
    [sci message:SCI_SETINDICATORCURRENT wParam:kIndicatorIncSearch];
    [sci message:SCI_INDICATORCLEARRANGE wParam:0 lParam:[sci message:SCI_GETLENGTH]];
    if (!text.length) return;

    // Configure indicator style: semi-transparent rounded box
    [sci message:SCI_INDICSETSTYLE  wParam:kIndicatorIncSearch lParam:INDIC_ROUNDBOX];
    [sci message:SCI_INDICSETFORE   wParam:kIndicatorIncSearch lParam:0x00AA44]; // green
    [sci message:SCI_INDICSETALPHA  wParam:kIndicatorIncSearch lParam:80];

    // Search flags
    int flags = 0;
    if (mc) flags |= SCFIND_MATCHCASE;

    sptr_t docLen = [sci message:SCI_GETLENGTH];
    const char *needle = text.UTF8String;
    [sci message:SCI_SETTARGETRANGE wParam:0 lParam:docLen];
    [sci message:SCI_SETSEARCHFLAGS wParam:(uptr_t)flags];

    sptr_t pos = 0;
    while (pos < docLen) {
        [sci message:SCI_SETTARGETRANGE wParam:(uptr_t)pos lParam:docLen];
        sptr_t found = [sci message:SCI_SEARCHINTARGET wParam:strlen(needle) lParam:(sptr_t)needle];
        if (found < 0) break;
        sptr_t end = [sci message:SCI_GETTARGETEND];
        [sci message:SCI_INDICATORFILLRANGE wParam:(uptr_t)found lParam:end - found];
        pos = end > found ? end : found + 1;
    }
}

- (void)clearIncrementalSearchHighlights {
    ScintillaView *sci = _scintillaView;
    [sci message:SCI_SETINDICATORCURRENT wParam:kIndicatorIncSearch];
    [sci message:SCI_INDICATORCLEARRANGE wParam:0 lParam:[sci message:SCI_GETLENGTH]];
}

#pragma mark - Brace Highlight

// Mirrors NPP's ScintillaEditView::braceMatch().
// When the caret is adjacent to ()[]{}:
//   - Highlights the matched pair via STYLE_BRACELIGHT (red bold)
// Fold block highlighting (red ⊞/⊟ symbols and connecting lines for the enclosing block)
// is handled automatically by SCI_MARKERENABLEHIGHLIGHT — no manual marker work needed.
- (void)updateBraceHighlight {
    // Performance pref — skip brace match for large files unless explicitly allowed.
    if (_largeFileMode &&
        ![[NSUserDefaults standardUserDefaults] boolForKey:kPrefLargeFileAllowBraceMatch]) return;

    ScintillaView *sci = _scintillaView;
    sptr_t caretPos = [sci message:SCI_GETCURRENTPOS];
    sptr_t docLen   = [sci message:SCI_GETLENGTH];

    const char *braces = "()[]{}";
    sptr_t bracePos = INVALID_POSITION;

    // Check character after caret first, then before (NPP order)
    if (caretPos < docLen) {
        int ch = (int)[sci message:SCI_GETCHARAT wParam:(uptr_t)caretPos];
        if (strchr(braces, ch)) bracePos = caretPos;
    }
    if (bracePos == INVALID_POSITION && caretPos > 0) {
        int ch = (int)[sci message:SCI_GETCHARAT wParam:(uptr_t)(caretPos - 1)];
        if (strchr(braces, ch)) bracePos = caretPos - 1;
    }

    sptr_t matchPos = INVALID_POSITION;
    if (bracePos != INVALID_POSITION)
        matchPos = [sci message:SCI_BRACEMATCH wParam:(uptr_t)bracePos lParam:0];

    // Nothing changed — skip redundant updates
    if (bracePos == _lastBracePos && matchPos == _lastMatchPos) return;
    _lastBracePos = bracePos;
    _lastMatchPos = matchPos;

    if (bracePos == INVALID_POSITION) {
        [sci message:SCI_BRACEHIGHLIGHT wParam:(uptr_t)INVALID_POSITION lParam:INVALID_POSITION];
        return;
    }

    if (matchPos != INVALID_POSITION) {
        [sci message:SCI_BRACEHIGHLIGHT wParam:(uptr_t)bracePos lParam:matchPos];
    } else {
        [sci message:SCI_BRACEBADLIGHT wParam:(uptr_t)bracePos lParam:0];
    }
}

#pragma mark - Smart Highlight

- (void)updateSmartHighlight {
    ScintillaView *sci = _scintillaView;

    // Always clear first
    [sci message:SCI_SETINDICATORCURRENT wParam:kHighlightIndicator];
    [sci message:SCI_INDICATORCLEARRANGE wParam:0 lParam:[sci message:SCI_GETLENGTH]];

    // Bail if smart highlighting is disabled
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kPrefSmartHighlight]) return;

    // Performance pref — skip smart highlight for large files unless explicitly allowed.
    // Walking a multi-million-line buffer for selection-text matches dominates wall time.
    if (_largeFileMode &&
        ![[NSUserDefaults standardUserDefaults] boolForKey:kPrefLargeFileAllowSmartHilite]) return;

    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];

    NSInteger selLen = selEnd - selStart;
    if (selLen < 2) return;

    // Only highlight single-word selections (no newlines)
    NSString *selText = sci.selectedString;
    if (!selText.length ||
        [selText rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound)
        return;

    const char *needle = selText.UTF8String;
    NSInteger needleLen = (NSInteger)strlen(needle);
    {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        int flags = 0;
        if ([ud boolForKey:kPrefSmartHiliteCase]) flags |= SCFIND_MATCHCASE;
        if ([ud boolForKey:kPrefSmartHiliteWord]) flags |= SCFIND_WHOLEWORD;
        // Issue #64 — both options OFF should mean substring + case-insensitive
        // (Windows NPP parity). The fallback below forced WHOLEWORD|MATCHCASE
        // and made the four toggle states non-orthogonal vs the labels.
        // Keeping commented out in case we want to revert.
        // if (!flags) flags = SCFIND_WHOLEWORD | SCFIND_MATCHCASE; // default behavior
        [sci message:SCI_SETSEARCHFLAGS wParam:(uptr_t)flags];
    }

    sptr_t docLen = [sci message:SCI_GETLENGTH];
    sptr_t pos = 0;
    while (pos < docLen) {
        [sci message:SCI_SETTARGETSTART wParam:(uptr_t)pos];
        [sci message:SCI_SETTARGETEND   wParam:(uptr_t)docLen];
        sptr_t found = [sci message:SCI_SEARCHINTARGET wParam:(uptr_t)needleLen lParam:(sptr_t)needle];
        if (found < 0) break;
        sptr_t foundEnd = [sci message:SCI_GETTARGETEND];
        if (found != selStart) // skip the current selection itself
            [sci message:SCI_INDICATORFILLRANGE wParam:(uptr_t)found lParam:foundEnd - found];
        pos = foundEnd;
    }
}

#pragma mark - Clickable Links (issue #133)

// Compiles a regex matching any of the user's custom URI schemes followed by a
// run of URL characters. Cached on the schemes string (a global pref) so we
// don't recompile on every scroll. Main-thread only (all callers are UI).
static NSRegularExpression *nppClickableSchemeRegex(NSString *schemes) {
    static NSString *cachedSrc = nil;
    static NSRegularExpression *cachedRegex = nil;
    if (cachedSrc && [schemes isEqualToString:cachedSrc]) return cachedRegex;
    cachedSrc = [schemes copy];
    cachedRegex = nil;
    NSArray *tokens = [schemes componentsSeparatedByCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *escaped = [NSMutableArray array];
    for (NSString *t in tokens)
        if (t.length) [escaped addObject:[NSRegularExpression escapedPatternForString:t]];
    if (escaped.count) {
        // Scheme alternation followed by one+ non-space, non-markup chars.
        NSString *pattern = [NSString stringWithFormat:@"(?:%@)[^\\s<>\"'`]+",
                             [escaped componentsJoinedByString:@"|"]];
        cachedRegex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                               options:NSRegularExpressionCaseInsensitive
                                                                 error:nil];
    }
    return cachedRegex;
}

// Sets the slot-19 indicator appearance from the current prefs. INDIC_TEXTFORE
// colors the link text without an underline ("No underline" mode); INDIC_PLAIN
// draws an underline. Fullbox mode draws a filled box on hover.
- (void)_configureClickableLinkIndicator {
    ScintillaView *sci = _scintillaView;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL noUnderline = [ud boolForKey:kPrefClickableLinkNoUnderline];
    BOOL fullbox     = [ud boolForKey:kPrefClickableLinkFullBox];
    int baseStyle  = noUnderline ? INDIC_TEXTFORE : INDIC_PLAIN;
    int hoverStyle = fullbox ? INDIC_FULLBOX : baseStyle;
    [sci message:SCI_INDICSETSTYLE        wParam:kClickableLinkIndicator lParam:baseStyle];
    [sci message:SCI_INDICSETHOVERSTYLE   wParam:kClickableLinkIndicator lParam:hoverStyle];
    [sci message:SCI_INDICSETFORE         wParam:kClickableLinkIndicator lParam:0xCC6600]; // #0066CC (BGR)
    [sci message:SCI_INDICSETALPHA        wParam:kClickableLinkIndicator lParam:60];
    [sci message:SCI_INDICSETOUTLINEALPHA wParam:kClickableLinkIndicator lParam:120];
}

// Re-mark clickable-link ranges within the currently visible viewport. Cheap:
// only the on-screen byte range is scanned (mirrors Windows NPP addHotSpot).
- (void)updateClickableLinks {
    ScintillaView *sci = _scintillaView;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    [self _configureClickableLinkIndicator];

    // Visible byte range — fold/wrap-aware via SCI_DOCLINEFROMVISIBLE.
    sptr_t firstVisible  = [sci message:SCI_GETFIRSTVISIBLELINE];
    sptr_t linesOnScreen = [sci message:SCI_LINESONSCREEN];
    sptr_t lineCount     = [sci message:SCI_GETLINECOUNT];
    sptr_t docFirst = [sci message:SCI_DOCLINEFROMVISIBLE wParam:(uptr_t)firstVisible];
    sptr_t docLast  = [sci message:SCI_DOCLINEFROMVISIBLE
                                 wParam:(uptr_t)(firstVisible + linesOnScreen + 1)];
    if (docFirst < 0) docFirst = 0;
    if (docLast >= lineCount) docLast = lineCount - 1;
    if (docLast < docFirst) return;

    sptr_t startPos = [sci message:SCI_POSITIONFROMLINE   wParam:(uptr_t)docFirst];
    sptr_t endPos   = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)docLast];
    if (endPos <= startPos) return;

    // Bound the scan on pathologically long lines (minified bundles,
    // single-line JSON/CSV, long log rows): the visible range is bounded by
    // line *count*, but one line can be arbitrarily long, so a viewport filled
    // by a single huge line would otherwise extract+scan megabytes on every
    // keystroke/scroll. Cap to a fixed byte budget, backed off to a UTF-8 char
    // boundary (skip continuation bytes 0x80–0xBF) so the buffer decodes
    // cleanly. Links past the cap on such a line simply aren't marked.
    static const sptr_t kMaxScanBytes = 128 * 1024;
    if (endPos - startPos > kMaxScanBytes) {
        endPos = startPos + kMaxScanBytes;
        while (endPos > startPos &&
               ((unsigned char)[sci message:SCI_GETCHARAT wParam:(uptr_t)endPos] & 0xC0) == 0x80)
            endPos--;
        if (endPos <= startPos) return;
    }

    // Clear the indicator across the visible range first.
    [sci message:SCI_SETINDICATORCURRENT wParam:kClickableLinkIndicator];
    [sci message:SCI_INDICATORCLEARRANGE wParam:(uptr_t)startPos lParam:(sptr_t)(endPos - startPos)];

    if (![ud boolForKey:kPrefClickableLinkEnable]) return;
    if (_largeFileMode && ![ud boolForKey:kPrefLargeFileAllowURLClick]) return;

    // Extract visible text. Line boundaries are valid UTF-8 char boundaries,
    // so the byte range decodes cleanly.
    sptr_t len = endPos - startPos;
    char *buf = (char *)malloc((size_t)len + 1);
    if (!buf) return;
    Sci_TextRangeFull tr;
    tr.chrg.cpMin = (Sci_Position)startPos;
    tr.chrg.cpMax = (Sci_Position)endPos;
    tr.lpstrText  = buf;
    [sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&tr];
    NSString *text = [[NSString alloc] initWithBytes:buf length:(NSUInteger)len
                                            encoding:NSUTF8StringEncoding];
    free(buf);
    if (!text.length) return;

    // Map an NSString (UTF-16) sub-range to absolute document byte offsets and
    // fill the indicator there.
    void (^fillRange)(NSRange) = ^(NSRange r) {
        if (r.length == 0) return;
        NSUInteger byteStart = [[text substringToIndex:r.location]
                                lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSUInteger byteLen = [[text substringWithRange:r]
                              lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (byteLen == 0) return;
        [sci message:SCI_INDICATORFILLRANGE
                wParam:(uptr_t)(startPos + byteStart) lParam:(sptr_t)byteLen];
    };

    NSRange whole = NSMakeRange(0, text.length);

    // 1) Standard web/mail links (http, https, ftp, mailto, bare www, …).
    static NSDataDetector *detector = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
    });
    [detector enumerateMatchesInString:text options:0 range:whole
                            usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
        if (m.resultType == NSTextCheckingTypeLink && m.URL) fillRange(m.range);
    }];

    // 2) Custom URI schemes from prefs (svn://, git://, …) the detector misses.
    NSRegularExpression *schemeRegex =
        nppClickableSchemeRegex([ud stringForKey:kPrefClickableLinkSchemes] ?: @"");
    if (schemeRegex) {
        static NSCharacterSet *trailTrim = nil;
        static dispatch_once_t trimOnce;
        dispatch_once(&trimOnce, ^{
            trailTrim = [NSCharacterSet characterSetWithCharactersInString:@".,;:!?)]}>'\""];
        });
        [schemeRegex enumerateMatchesInString:text options:0 range:whole
                                   usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
            NSRange r = m.range;
            // Trim trailing sentence/markup punctuation that isn't part of the URL.
            while (r.length > 0 &&
                   [trailTrim characterIsMember:[text characterAtIndex:r.location + r.length - 1]])
                r.length--;
            fillRange(r);
        }];
    }
}

// Opens the clicked link if the double-click landed on a clickable-link
// indicator. Returns YES if it handled the click (so the caller skips the
// delimiter/word handlers). Only plain double-clicks (no modifiers) qualify —
// ⌘ is reserved for delimiter selection.
- (BOOL)_handleClickableLinkDoubleClick:(SCNotification *)notification {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (![ud boolForKey:kPrefClickableLinkEnable]) return NO;
    if (_largeFileMode && ![ud boolForKey:kPrefLargeFileAllowURLClick]) return NO;
    if (notification->modifiers != 0) return NO;  // ⌘ etc. handled elsewhere

    ScintillaView *sci = _scintillaView;
    sptr_t pos = notification->position;
    if (pos < 0) return NO;

    sptr_t onMask = [sci message:SCI_INDICATORALLONFOR wParam:(uptr_t)pos];
    if (!(onMask & (1 << kClickableLinkIndicator))) return NO;

    sptr_t start = [sci message:SCI_INDICATORSTART wParam:kClickableLinkIndicator lParam:pos];
    sptr_t end   = [sci message:SCI_INDICATOREND   wParam:kClickableLinkIndicator lParam:pos];
    if (end <= start || pos < start || pos > end) return NO;

    sptr_t len = end - start;
    // Defensive: a real URL is never this long. A huge indicator run can only
    // arise from a pathological no-whitespace line; don't extract megabytes.
    if (len > 64 * 1024) return NO;
    char *buf = (char *)malloc((size_t)len + 1);
    if (!buf) return NO;
    Sci_TextRangeFull tr;
    tr.chrg.cpMin = (Sci_Position)start;
    tr.chrg.cpMax = (Sci_Position)end;
    tr.lpstrText  = buf;
    [sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&tr];
    NSString *urlText = [[NSString alloc] initWithBytes:buf length:(NSUInteger)len
                                               encoding:NSUTF8StringEncoding];
    free(buf);
    if (!urlText.length) return NO;

    // Collapse the word selection Scintilla made on double-click before we
    // hand off to the browser (matches Windows NPP).
    [sci message:SCI_SETSEL wParam:(uptr_t)pos lParam:pos];

    NSURL *url = [self _urlFromLinkText:urlText];
    if (url) [[NSWorkspace sharedWorkspace] openURL:url];
    return YES;
}

// Builds an openable NSURL from highlighted link text. NSDataDetector
// normalizes bare hosts (www.x.com → http://www.x.com); custom schemes fall
// back to direct/percent-encoded construction.
- (NSURL *)_urlFromLinkText:(NSString *)text {
    static NSDataDetector *det = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        det = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
    });
    NSTextCheckingResult *m = [det firstMatchInString:text options:0
                                                range:NSMakeRange(0, text.length)];
    if (m.URL && m.range.location == 0 && m.range.length == text.length)
        return m.URL;

    NSURL *u = [NSURL URLWithString:text];
    if (u && u.scheme.length) return u;

    NSString *enc = [text stringByAddingPercentEncodingWithAllowedCharacters:
                     [NSCharacterSet URLFragmentAllowedCharacterSet]];
    u = enc ? [NSURL URLWithString:enc] : nil;
    return (u && u.scheme.length) ? u : nil;
}

#pragma mark - Macro Recording

- (BOOL)isRecordingMacro { return _isRecordingMacro; }

- (NSArray<NSDictionary *> *)macroActions { return [_macroActions copy]; }

#pragma mark - Windows menu-command macro map (#166 Phase 2 — type 2)

// Maps a Windows menu command id (IDM_*, from menuCmdID.h) to the equivalent
// macOS action selector. Used when a type-2 macro action has an empty sParam
// (Windows-recorded: the IDM_* is in wParam; macOS-recorded macros instead carry
// the selector string in sParam). Only the common, macro-relevant commands are
// mapped; unmapped ids are logged and skipped. Each selector below is verified
// against MenuBuilder.mm.
static NSString *_winMacroCmdSelector(long long idm) {
    static NSDictionary<NSNumber *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            // ── File (IDM_FILE = 41000) ──
            @41001: @"newDocument:",          // IDM_FILE_NEW
            @41002: @"openDocument:",         // IDM_FILE_OPEN
            @41003: @"closeCurrentTab:",      // IDM_FILE_CLOSE
            @41004: @"closeAllTabs:",         // IDM_FILE_CLOSEALL
            @41006: @"saveDocument:",         // IDM_FILE_SAVE
            @41007: @"saveAllDocuments:",     // IDM_FILE_SAVEALL
            @41008: @"saveDocumentAs:",       // IDM_FILE_SAVEAS
            @41010: @"printDocument:",        // IDM_FILE_PRINT
            @41014: @"reloadFromDisk:",       // IDM_FILE_RELOAD
            // ── Edit (IDM_EDIT = 42000) ──
            @42001: @"cut:",                  // IDM_EDIT_CUT
            @42002: @"copy:",                 // IDM_EDIT_COPY
            @42003: @"undo:",                 // IDM_EDIT_UNDO
            @42004: @"redo:",                 // IDM_EDIT_REDO
            @42005: @"paste:",                // IDM_EDIT_PASTE
            @42006: @"delete:",               // IDM_EDIT_DELETE
            @42007: @"selectAll:",            // IDM_EDIT_SELECTALL
            @42010: @"duplicateLine:",        // IDM_EDIT_DUP_LINE
            @42014: @"moveLineUp:",           // IDM_EDIT_LINE_UP
            @42015: @"moveLineDown:",         // IDM_EDIT_LINE_DOWN
            @42016: @"convertToUppercase:",   // IDM_EDIT_UPPERCASE
            @42017: @"convertToLowercase:",   // IDM_EDIT_LOWERCASE
            @42022: @"toggleLineComment:",    // IDM_EDIT_BLOCK_COMMENT (Ctrl+Q line toggle)
            @42023: @"addBlockComment:",      // IDM_EDIT_STREAM_COMMENT (Ctrl+Shift+Q)
            @42024: @"trimTrailingWhitespace:",// IDM_EDIT_TRIMTRAILING
            @42047: @"removeBlockComment:",   // IDM_EDIT_STREAM_UNCOMMENT
            // ── Search (IDM_SEARCH = 43000) ──
            @43002: @"findNext:",             // IDM_SEARCH_FINDNEXT
            @43010: @"findPrevious:",         // IDM_SEARCH_FINDPREV
            // ── Format / EOL (IDM_FORMAT = 45000) ──
            @45001: @"setEOLCRLF:",           // IDM_FORMAT_TODOS
            @45002: @"setEOLLF:",             // IDM_FORMAT_TOUNIX
            @45003: @"setEOLCR:",             // IDM_FORMAT_TOMAC
        };
    });
    return map[@(idm)];
}

#pragma mark - Find/Replace macro replay (#166 — Windows mtSavedSnR / type 3)

// Decode the 1702 booleans bitmask (Windows IDF_* control bits) into the options.
- (void)_applySnRBooleans:(int)b toOptions:(NPPFindOptions *)o {
    o.wholeWord         = (b & 1)    != 0;   // IDF_WHOLEWORD
    o.matchCase         = (b & 2)    != 0;   // IDF_MATCHCASE
    o.doPurge           = (b & 4)    != 0;   // IDF_PURGE_CHECK
    o.doBookmarkLine    = (b & 16)   != 0;   // IDF_MARKLINE_CHECK
    o.inSelection       = (b & 128)  != 0;   // IDF_IN_SELECTION_CHECK
    o.wrapAround        = (b & 256)  != 0;   // IDF_WRAP
    o.dotMatchesNewline = (b & 1024) != 0;   // IDF_REDOTMATCHNL
    o.direction         = (b & 512) ? NPPSearchDown : NPPSearchUp;  // IDF_WHICH_DIRECTION (set=down)
}

// Run the accumulated Find/Replace operation for an EXEC (1701) command. The
// macOS SearchEngine handles regex/extended modes and the #151 empty-match loop
// semantics internally, so we just hand it the options.
- (void)_execSnRCommand:(int)cmd options:(NPPFindOptions *)o {
    if (!o) { NSLog(@"[Macro] Find/Replace EXEC with no pending options (skipped)"); return; }
    if (!o.searchText.length) return;   // nothing to search for
    ScintillaView *sci = _scintillaView;
    // Replace All / Mark All operate on the WHOLE document (or the selection) by
    // definition — Windows macros don't record a wrap bit for them. SearchEngine
    // only covers the whole doc when wrapAround is set, so force it (unless the
    // op is scoped to the selection), otherwise it would search only cursor→end.
    if (!o.inSelection && (cmd == 1609 || cmd == 1615)) o.wrapAround = YES;
    switch (cmd) {
        case 1609: [SearchEngine replaceAllInView:sci options:o]; break;  // IDREPLACEALL
        case 1608: [SearchEngine replaceInView:sci options:o];    break;  // IDREPLACE
        case 1:    [SearchEngine findInView:sci options:o forward:(o.direction == NPPSearchDown)]; break; // IDOK (Find Next)
        case 1615: [SearchEngine markAllInView:sci options:o];    break;  // IDCMARKALL
        default:
            // Find All / Count / Find-in-Files EXECs are not supported in v1.
            NSLog(@"[Macro] unsupported Find/Replace command=%d (skipped)", cmd);
    }
}

// Process one type-3 step. INIT(1700) starts a fresh op; field/option messages
// fill it in; EXEC(1701) runs it and returns nil so the next op starts clean.
// Returns the (possibly new) pending options to carry across loop iterations.
- (NPPFindOptions *)_snrMacroStep:(int)msg lParam:(long long)lp
                           sParam:(NSString *)sParam pending:(NPPFindOptions *)opts {
    switch (msg) {
        case 1700:  // IDC_FRCOMMAND_INIT
            return [[NPPFindOptions alloc] init];
        case 1601:  // IDFINDWHAT
            if (!opts) opts = [[NPPFindOptions alloc] init];
            opts.searchText = sParam ?: @"";
            return opts;
        case 1602:  // IDREPLACEWITH
            if (!opts) opts = [[NPPFindOptions alloc] init];
            opts.replaceText = sParam ?: @"";
            return opts;
        case 1625:  // IDNORMAL — search mode (0 Normal / 1 Extended / 2 Regex)
            if (!opts) opts = [[NPPFindOptions alloc] init];
            if (lp >= NPPSearchNormal && lp <= NPPSearchRegex) opts.searchType = (NPPSearchType)lp;
            return opts;
        case 1702:  // IDC_FRCOMMAND_BOOLEANS
            if (!opts) opts = [[NPPFindOptions alloc] init];
            [self _applySnRBooleans:(int)lp toOptions:opts];
            return opts;
        case 1701:  // IDC_FRCOMMAND_EXEC
            [self _execSnRCommand:(int)lp options:opts];
            return nil;
        default:
            // Find-in-Files dir/filters combos or unknown — not handled in v1;
            // keep the pending op so a later EXEC still runs.
            NSLog(@"[Macro] unsupported Find/Replace step message=%d (ignored)", msg);
            return opts;
    }
}

- (void)runMacroActions:(NSArray<NSDictionary *> *)actions {
    if (!actions.count) { NSBeep(); return; }
    ScintillaView *sci = _scintillaView;
    [(NppApplication *)NSApp setPlayingBackMacro:YES];

    // Deactivate the macOS text input context during macro playback.
    // ScintillaView conforms to NSTextInputClient — every selection or
    // text change notifies macOS's TextInputUI system, which hosts its
    // cursor/selection overlay via an out-of-process ViewBridge.  Rapid
    // batch changes (selectAll: + replaceSelection in a loop) can
    // overwhelm the ViewBridge, causing it to disconnect and leave a
    // stale view in the window hierarchy.  The next time AppKit walks
    // the view tree (e.g. _handleDeactivateEvent:), it hits the freed
    // view → use-after-free crash.  Deactivating the input context
    // cleanly disconnects TextInputUI before the batch starts;
    // reactivating after restores it.
    NSTextInputContext *tic = [NSTextInputContext currentInputContext];
    [tic discardMarkedText];
    [tic deactivate];

    [sci message:SCI_BEGINUNDOACTION];
    // #166 Phase 1: a type-3 (mtSavedSnR) Find/Replace operation spans several
    // actions — INIT → set fields/options → EXEC. Accumulate them here; the
    // helper builds/updates this and clears it on EXEC.
    NPPFindOptions *snr = nil;
    for (NSDictionary *action in actions) {
        // ── Recorded format: menu command by selector name ──
        NSString *menuCmd = action[@"menuCommand"];
        if (menuCmd) {
            NSNumber *pluginCmdID = action[@"pluginCmdID"];
            if (pluginCmdID && [menuCmd isEqualToString:@"pluginMenuAction:"]) {
                // Plugin commands share one selector (pluginMenuAction:); the
                // responder-chain sendAction: can't pick the right one, so
                // dispatch the recorded cmdID directly.
                [[NppPluginManager shared] runPluginCommandWithID:(int)pluginCmdID.integerValue];
            } else {
                SEL sel = NSSelectorFromString(menuCmd);
                [NSApp sendAction:sel to:nil from:self];
            }
            continue;
        }

        // ── XML format (from shortcuts.xml) ──
        BOOL isXmlFormat = (action[@"type"] != nil);
        if (isXmlFormat) {
            int type       = [action[@"type"] intValue];
            int msg        = [action[@"message"] intValue];
            long long wp   = [action[@"wParam"] longLongValue];
            long long lp   = [action[@"lParam"] longLongValue];
            NSString *sParam = action[@"sParam"];

            if (type == 3) {
                // #166: Find/Replace step (mtSavedSnR) — Windows encodes a
                // search/replace as a sequence of pseudo-messages routed to the
                // Find dialog. Decode them into an NPPFindOptions and run the
                // macOS SearchEngine on EXEC.
                snr = [self _snrMacroStep:msg lParam:lp sParam:sParam pending:snr];
            } else if (type == 2) {
                // Menu command. macOS-recorded macros put the selector in sParam;
                // Windows macros leave sParam empty and put the IDM_* in wParam.
                if (sParam.length) {
                    if (wp != 0 && [sParam isEqualToString:@"pluginMenuAction:"]) {
                        // Plugin command: cmdID stored in wParam (see
                        // convertRecordedToXmlFormat). Dispatch it directly.
                        [[NppPluginManager shared] runPluginCommandWithID:(int)wp];
                    } else {
                        SEL menuAction = NSSelectorFromString(sParam);
                        [NSApp sendAction:menuAction to:nil from:self];
                    }
                } else {
                    // Windows menu command (IDM_* in wParam, no selector) — resolve
                    // via the IDM→selector map (#166 Phase 2); unmapped ids are logged.
                    NSString *winSel = _winMacroCmdSelector(wp);
                    if (winSel.length) {
                        [NSApp sendAction:NSSelectorFromString(winSel) to:nil from:self];
                    } else {
                        NSLog(@"[Macro] Windows menu command IDM %lld not mapped — skipped", wp);
                    }
                }
            } else if (type == 1 && sParam.length > 0) {
                [sci message:(uint32_t)msg wParam:(uptr_t)wp lParam:(sptr_t)sParam.UTF8String];
            } else {
                [sci message:(uint32_t)msg wParam:(uptr_t)wp lParam:(sptr_t)lp];
            }
        } else {
            // ── Recorded format: Scintilla message ──
            unsigned int msg = [action[@"msg"] unsignedIntValue];
            uptr_t       wp  = (uptr_t)[action[@"wp"] unsignedLongLongValue];
            NSString    *text = action[@"text"];
            if (text) {
                [sci message:msg wParam:wp lParam:(sptr_t)text.UTF8String];
            } else {
                sptr_t lp = (sptr_t)[action[@"lp"] longLongValue];
                [sci message:msg wParam:wp lParam:lp];
            }
        }
    }
    [sci message:SCI_ENDUNDOACTION];

    // Reactivate the text input context now that the batch is done.
    [tic activate];

    [(NppApplication *)NSApp setPlayingBackMacro:NO];
}

- (void)startMacroRecording {
    _macroActions = [NSMutableArray array];
    _isRecordingMacro = YES;
    [_scintillaView message:SCI_STARTRECORD];
}

- (void)stopMacroRecording {
    [_scintillaView message:SCI_STOPRECORD];
    _isRecordingMacro = NO;
}

- (void)recordMenuCommand:(NSString *)selectorName {
    [self recordMenuCommand:selectorName pluginCmdID:0];
}

- (void)recordMenuCommand:(NSString *)selectorName pluginCmdID:(NSInteger)cmdID {
    if (!_isRecordingMacro || !selectorName.length) return;
    NSMutableDictionary *step = [NSMutableDictionary dictionaryWithObject:selectorName
                                                                  forKey:@"menuCommand"];
    // Plugin command IDs start at 22000 (see NppPluginManager); 0 means "not a
    // plugin command". Stored so playback can dispatch the exact command rather
    // than the broken shared-selector sendAction: path.
    if (cmdID != 0) step[@"pluginCmdID"] = @(cmdID);
    [_macroActions addObject:step];
    NSLog(@"[Macro] Recorded menu command: %@%@", selectorName,
          cmdID != 0 ? [NSString stringWithFormat:@" (plugin cmdID %ld)", (long)cmdID] : @"");
}

- (void)runMacro {
    if (!_macroActions.count) { NSBeep(); return; }
    ScintillaView *sci = _scintillaView;
    [(NppApplication *)NSApp setPlayingBackMacro:YES];
    [sci message:SCI_BEGINUNDOACTION];
    for (NSDictionary *action in _macroActions) {
        // Type 2: menu command by selector name
        NSString *menuCmd = action[@"menuCommand"];
        if (menuCmd) {
            NSNumber *pluginCmdID = action[@"pluginCmdID"];
            if (pluginCmdID && [menuCmd isEqualToString:@"pluginMenuAction:"]) {
                [[NppPluginManager shared] runPluginCommandWithID:(int)pluginCmdID.integerValue];
            } else {
                SEL sel = NSSelectorFromString(menuCmd);
                [NSApp sendAction:sel to:nil from:self];
            }
            continue;
        }
        // Type 0/1: Scintilla message
        unsigned int msg = [action[@"msg"] unsignedIntValue];
        uptr_t       wp  = (uptr_t)[action[@"wp"] unsignedLongLongValue];
        NSString    *text = action[@"text"];
        if (text) {
            [sci message:msg wParam:wp lParam:(sptr_t)text.UTF8String];
        } else {
            sptr_t lp = (sptr_t)[action[@"lp"] longLongValue];
            [sci message:msg wParam:wp lParam:lp];
        }
    }
    [sci message:SCI_ENDUNDOACTION];
    [(NppApplication *)NSApp setPlayingBackMacro:NO];
}

#pragma mark - Auto-indent

// Languages that use brace-based auto-indent (matching Windows NPP maintainIndentation)
static NSSet<NSString *> *_cLikeLanguages() {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"c", @"cpp", @"objc", @"cs", @"java",
            @"javascript", @"javascript.js", @"typescript", @"swift", @"go", @"rust",
            @"php", @"jsp", @"css", @"perl", @"powershell",
            @"json", @"json5", @"d", @"actionscript", @"rc"
        ]];
    });
    return s;
}

// Detect braceless control structures: if(...) / for(...) / while(...) / else
// Uses Scintilla's regex search on the given line.
- (BOOL)_isConditionExprLine:(sptr_t)line {
    ScintillaView *sci = _scintillaView;
    if (line < 0 || line >= [sci message:SCI_GETLINECOUNT])
        return NO;

    sptr_t startPos = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)line];
    sptr_t endPos   = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)line];
    if (startPos >= endPos) return NO;

    // Use std::regex (CXX11REGEX) so the `|` alternations in `expr` actually
    // work — Scintilla's POSIX RESearch treats `|` as a literal pipe.
    [sci message:SCI_SETSEARCHFLAGS wParam:SCFIND_REGEXP | SCFIND_CXX11REGEX];
    [sci message:SCI_SETTARGETRANGE wParam:(uptr_t)startPos lParam:endPos];

    const char expr[] = "((else[ \t]+)?if|for|while)[ \t]*[(].*[)][ \t]*|else[ \t]*";
    sptr_t found = [sci message:SCI_SEARCHINTARGET wParam:strlen(expr) lParam:(sptr_t)expr];
    if (found >= 0) {
        sptr_t end = [sci message:SCI_GETTARGETEND];
        if (end == endPos)
            return YES;
    }
    return NO;
}

// Find matching opening brace by scanning backward with balance counting.
- (sptr_t)_findMatchedBraceFrom:(sptr_t)startPos to:(sptr_t)endPos
                         target:(char)target matched:(char)matched {
    if (startPos == endPos) return -1;
    ScintillaView *sci = _scintillaView;
    int balance = 0;
    for (sptr_t i = startPos; i >= endPos; --i) {
        char c = (char)[sci message:SCI_GETCHARAT wParam:(uptr_t)i];
        if (c == target) {
            if (balance == 0) return i;
            --balance;
        } else if (c == matched) {
            ++balance;
        }
    }
    return -1;
}

- (void)_maintainIndentation:(int)ch {
    // Skip during macro recording/playback (matches Windows NPP behavior)
    if (_isRecordingMacro || [(NppApplication *)NSApp playingBackMacro])
        return;

    // kPrefAutoIndent: 0=None, 1=Advanced, 2=Basic
    NSInteger autoIndentMode = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefAutoIndent];
    if (autoIndentMode == 0)
        return;

    ScintillaView *sci = _scintillaView;
    sptr_t eolMode = [sci message:SCI_GETEOLMODE];

    sptr_t curPos  = [sci message:SCI_GETCURRENTPOS];
    sptr_t curLine = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)curPos];
    sptr_t tabWidth = [sci message:SCI_GETTABWIDTH];
    NSString *lang = _currentLanguage.lowercaseString;

    BOOL isNewline = ((eolMode == SC_EOL_CRLF || eolMode == SC_EOL_LF) && ch == '\n') ||
                     (eolMode == SC_EOL_CR && ch == '\r');

    // ── C-like: handle } typed on its own line (advanced mode only) ──
    if (!isNewline && autoIndentMode == 1 && [_cLikeLanguages() containsObject:lang]) {
        if (ch == '}') {
            // Only re-align if } is the first non-whitespace on the line
            sptr_t lineStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)curLine];
            BOOL onlyWhitespaceBefore = YES;
            for (sptr_t i = curPos - 2; i >= lineStart; --i) {
                char c = (char)[sci message:SCI_GETCHARAT wParam:(uptr_t)i];
                if (c != ' ' && c != '\t') { onlyWhitespaceBefore = NO; break; }
            }
            if (!onlyWhitespaceBefore) return;

            // Find matching { by scanning backward
            sptr_t searchStart = (curPos >= 2) ? curPos - 2 : 0;
            sptr_t matchPos = [self _findMatchedBraceFrom:searchStart to:0
                                                   target:'{' matched:'}'];
            if (matchPos < 0) return;
            sptr_t matchLine = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)matchPos];
            if (matchLine == curLine) return;
            sptr_t matchIndent = [sci message:SCI_GETLINEINDENTATION wParam:(uptr_t)matchLine];
            [sci message:SCI_SETLINEINDENTATION wParam:(uptr_t)curLine lParam:matchIndent];
            sptr_t newPos = [sci message:SCI_GETLINEINDENTPOSITION wParam:(uptr_t)curLine];
            // Place cursor after the }
            [sci message:SCI_GOTOPOS wParam:(uptr_t)(newPos + 1)];
        }
        return;
    }

    if (!isNewline)
        return;

    sptr_t prevLine = curLine - 1;

    // If we were at the beginning of an empty line and pressed Enter, don't indent
    if (prevLine >= 0 && ([sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)prevLine] - [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)prevLine]) == 0)
        return;

    // Find previous non-empty line
    while (prevLine >= 0 && ([sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)prevLine] - [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)prevLine]) == 0)
        prevLine--;

    sptr_t indentPrev = 0;
    if (prevLine >= 0)
        indentPrev = [sci message:SCI_GETLINEINDENTATION wParam:(uptr_t)prevLine];

    // ── Advanced mode: language-specific indent ──
    if (autoIndentMode == 1) {
        // C-like languages: brace/condition-aware indent
        if ([_cLikeLanguages() containsObject:lang]) {
            [self _maintainIndentCLike:ch curLine:curLine prevLine:prevLine
                            indentPrev:indentPrev tabWidth:tabWidth eolMode:eolMode];
            return;
        }

        // Python: colon detection
        if ([lang isEqualToString:@"python"]) {
            [self _maintainIndentPython:curLine prevLine:prevLine
                             indentPrev:indentPrev tabWidth:tabWidth];
            return;
        }
    }

    // ── Basic indent (copy previous line) — used by basic mode and as advanced fallback ──
    if (indentPrev > 0) {
        [sci message:SCI_SETLINEINDENTATION wParam:(uptr_t)curLine lParam:indentPrev];
        sptr_t newPos = [sci message:SCI_GETLINEINDENTPOSITION wParam:(uptr_t)curLine];
        [sci message:SCI_GOTOPOS wParam:(uptr_t)newPos];
    }
}

- (void)_maintainIndentCLike:(int)ch curLine:(sptr_t)curLine prevLine:(sptr_t)prevLine
                  indentPrev:(sptr_t)indentPrev tabWidth:(sptr_t)tabWidth
                     eolMode:(sptr_t)eolMode {
    ScintillaView *sci = _scintillaView;

    // Determine prevChar (character before the newline) and nextChar (after cursor)
    sptr_t curPos = [sci message:SCI_GETCURRENTPOS];
    sptr_t prevPos = curPos - (eolMode == SC_EOL_CRLF ? 3 : 2);
    char prevChar = (prevPos >= 0) ? (char)[sci message:SCI_GETCHARAT wParam:(uptr_t)prevPos] : 0;
    char nextChar = (char)[sci message:SCI_GETCHARAT wParam:(uptr_t)curPos];

    if (prevChar == '{') {
        if (nextChar == '}') {
            // Enter between { and } — insert extra line, indent middle, align closing brace
            const char *eolStr = (eolMode == SC_EOL_CRLF) ? "\r\n" :
                                 (eolMode == SC_EOL_LF)   ? "\n" : "\r";
            [sci message:SCI_INSERTTEXT wParam:(uptr_t)curPos lParam:(sptr_t)eolStr];
            [sci message:SCI_SETLINEINDENTATION wParam:(uptr_t)(curLine + 1) lParam:indentPrev];
        }
        // Indent current line by tabWidth more than parent
        [sci message:SCI_SETLINEINDENTATION wParam:(uptr_t)curLine lParam:indentPrev + tabWidth];
    } else if (nextChar == '{') {
        // Next char is opening brace — align with previous indent
        [sci message:SCI_SETLINEINDENTATION wParam:(uptr_t)curLine lParam:indentPrev];
    } else if ([self _isConditionExprLine:prevLine]) {
        // Previous line is braceless if/for/while/else — indent one extra level
        [sci message:SCI_SETLINEINDENTATION wParam:(uptr_t)curLine lParam:indentPrev + tabWidth];
    } else {
        if (indentPrev > 0) {
            // Check if two lines up was a braceless condition — de-indent back
            if (prevLine > 0 && [self _isConditionExprLine:prevLine - 1])
                [sci message:SCI_SETLINEINDENTATION wParam:(uptr_t)curLine
                                                    lParam:MAX(0, indentPrev - tabWidth)];
            else
                [sci message:SCI_SETLINEINDENTATION wParam:(uptr_t)curLine lParam:indentPrev];
        }
    }

    // Position cursor at end of indentation
    sptr_t newPos = [sci message:SCI_GETLINEINDENTPOSITION wParam:(uptr_t)curLine];
    [sci message:SCI_GOTOPOS wParam:(uptr_t)newPos];
}

- (void)_maintainIndentPython:(sptr_t)curLine prevLine:(sptr_t)prevLine
                   indentPrev:(sptr_t)indentPrev tabWidth:(sptr_t)tabWidth {
    ScintillaView *sci = _scintillaView;

    if (prevLine >= 0) {
        // Search for trailing colon pattern: : followed by optional whitespace/comment
        sptr_t startPos = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)prevLine];
        sptr_t endPos   = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)prevLine];

        if (startPos < endPos) {
            // Use std::regex (CXX11REGEX) so the `(#|$)` alternation works —
            // POSIX RESearch would match the parens/pipe literally.
            [sci message:SCI_SETSEARCHFLAGS wParam:SCFIND_REGEXP | SCFIND_CXX11REGEX];
            [sci message:SCI_SETTARGETRANGE wParam:(uptr_t)startPos lParam:endPos];

            const char colonExpr[] = ":[ \t]*(#|$)";
            sptr_t found = [sci message:SCI_SEARCHINTARGET wParam:strlen(colonExpr)
                                                            lParam:(sptr_t)colonExpr];
            if (found >= 0) {
                // Verify colon is an operator, not inside a string/comment
                sptr_t style = [sci message:SCI_GETSTYLEAT wParam:(uptr_t)found];
                // SCE_P_OPERATOR = 10 for the Python lexer
                if (style == 10) {
                    [sci message:SCI_SETLINEINDENTATION wParam:(uptr_t)curLine
                                                        lParam:indentPrev + tabWidth];
                    sptr_t newPos = [sci message:SCI_GETLINEINDENTPOSITION wParam:(uptr_t)curLine];
                    [sci message:SCI_GOTOPOS wParam:(uptr_t)newPos];
                    return;
                }
            }
        }
    }

    // Default: copy previous line's indentation
    if (indentPrev > 0) {
        [sci message:SCI_SETLINEINDENTATION wParam:(uptr_t)curLine lParam:indentPrev];
        sptr_t newPos = [sci message:SCI_GETLINEINDENTPOSITION wParam:(uptr_t)curLine];
        [sci message:SCI_GOTOPOS wParam:(uptr_t)newPos];
    }
}

#pragma mark - Auto-close & Word Completion

- (void)handleCharAdded:(int)ch {
    ScintillaView *sci = _scintillaView;

    // ── Auto-indent on newline ──
    [self _maintainIndentation:ch];

    // Auto-close bracket pairs — only when enabled and no existing selection
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kPrefAutoCloseBrackets] &&
        [sci message:SCI_GETSELECTIONSTART] == [sci message:SCI_GETSELECTIONEND]) {
        const char *closeStr = nullptr;
        if      (ch == '(') closeStr = ")";
        else if (ch == '[') closeStr = "]";
        else if (ch == '{') closeStr = "}";

        if (closeStr) {
            sptr_t pos = [sci message:SCI_GETCURRENTPOS];
            [sci message:SCI_INSERTTEXT wParam:(uptr_t)pos lParam:(sptr_t)closeStr];
            [sci message:SCI_GOTOPOS   wParam:(uptr_t)pos];
        }
    }

    // Function parameters hint: auto-trigger after typing '('
    if (ch == '(' && [[NSUserDefaults standardUserDefaults] boolForKey:kPrefFuncParamsHint]) {
        [self triggerFunctionParametersHint:nil];
    }

    // Word completion: trigger on word characters when auto-complete is enabled
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud boolForKey:kPrefAutoCompleteEnable]) {
        if (isalnum(ch) || ch == '_') {
            [self updateAutoComplete];
        } else {
            [sci message:SCI_AUTOCCANCEL];
        }
    }
}

- (void)updateAutoComplete {
    // Performance pref — skip word-completion suggestions for large files unless allowed.
    // The autocomplete word-list build walks the whole document.
    if (_largeFileMode &&
        ![[NSUserDefaults standardUserDefaults] boolForKey:kPrefLargeFileAllowAutoComplete]) return;

    // Honour configurable minimum-character threshold (default 1, matching NPP Windows)
    NSInteger minChars = [[NSUserDefaults standardUserDefaults]
                          integerForKey:kPrefAutoCompleteMinChars];
    if (minChars < 1) minChars = 1;
    [self _showWordCompletionWithMinPrefix:minChars beepOnEmpty:NO];
}

#pragma mark - ScintillaNotificationProtocol

- (void)notification:(SCNotification *)notification {
    // Forward safe Scintilla notifications to plugins BEFORE host processing
    // (matches Windows NPP where plugins see notifications first).
    //
    // SCN_UPDATEUI / SCN_PAINTED are forwarded — the host's scroll sync no
    // longer reacts to notifications (it uses a 60Hz timer-based poll in
    // MainWindowController._pollScrollSync:), so there's no view-to-view
    // feedback loop. Plugin-driven recursion is caught by the reentrancy
    // guard in NppPluginManager.forwardScintillaNotification:.
    //
    // Macro guard: suppress plugin notification forwarding entirely during
    // macro recording AND playback.
    //
    // During RECORDING: prevents plugin-initiated Scintilla messages
    // (SCI_GOTOPOS, SCI_REPLACESEL, SCI_SETLINEINDENTATION from DoxyIt,
    // indentbyfold, etc.) from leaking into the macro as phantom actions.
    // The user's actual keystrokes are already recorded BEFORE the
    // notification fires (Editor.cxx line 6271), so suppressing here
    // loses nothing.
    //
    // During PLAYBACK: prevents plugins from reacting to each individual
    // character in the batch. Plugins that create popup windows (e.g.
    // nppQuickText calling SCI_AUTOCSHOW) or update the view hierarchy
    // in response to SCN_MODIFIED/SCN_UPDATEUI can destabilize the macOS
    // ViewBridge (TextInputUI's out-of-process cursor overlay), leaving
    // stale views that crash AppKit when it next walks the view tree
    // (e.g. _handleDeactivateEvent: → _willMeasureMinSizeForFullscreen).
    // Suppressing forwarding during playback eliminates this entirely.
    {
        unsigned int code = notification->nmhdr.code;
        BOOL isMacroActive = _isRecordingMacro ||
                             [(NppApplication *)NSApp playingBackMacro];
        // SCN_DWELLSTART / SCN_DWELLEND let plugins show hover calltips.
        // Scintilla only raises them once a plugin arms the dwell timer
        // itself via SCI_SETMOUSEDWELLTIME — the host leaves it unset
        // (default TimeForever), so there is no cost for sessions with no
        // dwell-consuming plugin.
        if (code == SCN_CHARADDED || code == SCN_MODIFIED ||
            code == SCN_AUTOCSELECTION || code == SCN_AUTOCCANCELLED ||
            code == SCN_UPDATEUI || code == SCN_PAINTED ||
            code == SCN_DWELLSTART || code == SCN_DWELLEND) {
            if (!isMacroActive) {
                [[NppPluginManager shared] forwardScintillaNotification:notification];
            } else if (_isRecordingMacro) {
                // During recording only: still forward but with Scintilla's
                // recordingMacro paused so plugin SCI calls don't get captured.
                [_scintillaView message:SCI_STOPRECORD];
                [[NppPluginManager shared] forwardScintillaNotification:notification];
                [_scintillaView message:SCI_STARTRECORD];
            }
            // During playback: skip forwarding entirely.
        }
    }

    switch (notification->nmhdr.code) {
        case SCN_MODIFIED:
            if (notification->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT)) {
                _isModified = YES;
                // Sync clone sibling's modified state (shared document).
                if (_cloneSibling) _cloneSibling->_isModified = YES;
                // When whitespace display is active, newly inserted characters may not
                // get their whitespace symbols drawn by Scintilla's incremental update.
                // Queuing a full redraw ensures tab arrows / space dots appear immediately.
                if ([_scintillaView message:SCI_GETVIEWWS] != SCWS_INVISIBLE) {
                    [_scintillaView setNeedsDisplay:YES];
                }
            }
            break;
        case SCN_SAVEPOINTREACHED:
            _isModified = NO;
            if (_cloneSibling) _cloneSibling->_isModified = NO;
            break;
        case SCN_SAVEPOINTLEFT:
            _isModified = YES;
            if (_cloneSibling) _cloneSibling->_isModified = YES;
            break;
        case SCN_CHARADDED:
            [self handleCharAdded:notification->ch];
            break;
        case SCN_MACRORECORD:
            if (_isRecordingMacro) {
                unsigned int msg = (unsigned int)notification->message;
                uptr_t wp = notification->wParam;
                sptr_t lp = notification->lParam;

                // Normalize EOL: SCI_REPLACESEL with \n or \r → SCI_NEWLINE
                // (matches Windows NPP behavior for cross-platform macro compatibility)
                if (msg == SCI_REPLACESEL && lp) {
                    const char *ch = (const char *)lp;
                    if (ch[0] != '\0' && ch[1] == '\0' && (ch[0] == '\n' || ch[0] == '\r')) {
                        [_macroActions addObject:@{@"msg": @(SCI_NEWLINE), @"wp": @0, @"lp": @0}];
                        break;
                    }
                }

                NSMutableDictionary *action = [NSMutableDictionary dictionaryWithDictionary:@{
                    @"msg": @(msg),
                    @"wp":  @(wp),
                    @"lp":  @(lp),
                }];
                // SCI_REPLACESEL carries typed text in lParam (const char *)
                if ((msg == SCI_REPLACESEL || msg == SCI_ADDTEXT || msg == SCI_INSERTTEXT) && lp) {
                    action[@"text"] = [NSString stringWithUTF8String:(const char *)lp];
                }
                [_macroActions addObject:action];
            }
            break;
        case SCN_UPDATEUI:
            [self updateBraceHighlight];
            [self updateSmartHighlight];
            // Re-mark links only when content or the viewport changed — a
            // bare cursor move (selection-only) can't change link positions.
            if (notification->updated & (SC_UPDATE_CONTENT | SC_UPDATE_V_SCROLL | SC_UPDATE_H_SCROLL))
                [self updateClickableLinks];
            if (_spellCheckEnabled) [self _scheduleSpellCheck];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:EditorViewCursorDidMoveNotification
                              object:self];
            break;
        case SCN_FOCUSIN:
            [[NSNotificationCenter defaultCenter]
                postNotificationName:EditorViewDidGainFocusNotification
                              object:self];
            break;
        case SCN_MARGINCLICK:
            if (notification->margin == 1) { // bookmark / hide-lines margin
                NSInteger line = [_scintillaView message:SCI_LINEFROMPOSITION
                                                  wParam:(uptr_t)notification->position];
                // First check for hide-lines markers (click to unhide)
                if (![self _unhideMarkerAtLine:line]) {
                    // No hide marker — toggle bookmark instead
                    sptr_t mask = [_scintillaView message:SCI_MARKERGET wParam:(uptr_t)line];
                    if (mask & (1 << kBookmarkMarker))
                        [_scintillaView message:SCI_MARKERDELETE wParam:(uptr_t)line lParam:kBookmarkMarker];
                    else
                        [_scintillaView message:SCI_MARKERADD wParam:(uptr_t)line lParam:kBookmarkMarker];
                }
            }
            break;
        case SCN_DOUBLECLICK:
            // Plain double-click on a link opens it; otherwise fall through to
            // the ⌘+double-click delimiter handler (and native word select).
            if (![self _handleClickableLinkDoubleClick:notification])
                [self _handleDelimiterDoubleClick:notification];
            break;
        case SCN_ZOOM:
            // Re-fit the line-number margin to the new zoom level so digits
            // don't get clipped at higher zoom. Scintilla raises SCN_ZOOM
            // from inside SCI_SETZOOM / SCI_ZOOMIN / SCI_ZOOMOUT, covering
            // every zoom path (menu, Ctrl+scroll, plugin SCI_SETZOOM).
            [self recomputeLineNumberMargin];
            break;
        default:
            break;
    }
}

// ⌘+double-click selection between configured Open / Close delimiters (issue
// #42, "Delimiter selection settings"). Ported from Windows NppNotification.cpp
// lines 218-369 with the following macOS adaptations:
//   • Modifier check uses SCMOD_CTRL which ScintillaCocoa already maps from
//     macOS Cmd (see ScintillaCocoa.mm TranslateModifierFlags). Plain
//     double-click falls through and Scintilla performs native word select.
//   • Entire-document mode uses SCI_GETCHARACTERPOINTER (zero-copy, matches
//     Phase 2.5 save path). For multi-GB files this is essential — we cannot
//     afford to SCI_GETTEXT a 2.78 GB buffer like the Windows code does.
//     The pointer is invalidated by edits; we hold it only for the
//     synchronous scan on the main thread, so no concurrency hazard.
//   • Single-line mode allocates a per-line copy via SCI_GETLINE; bounded
//     by line length, fine for typical source code.
- (void)_handleDelimiterDoubleClick:(SCNotification *)notification {
    if (notification->modifiers != SCMOD_CTRL) return;  // plain or other-mod double-click → Scintilla handles

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *openS  = [ud stringForKey:kPrefDelimOpen]  ?: @"(";
    NSString *closeS = [ud stringForKey:kPrefDelimClose] ?: @")";
    if (openS.length == 0 || closeS.length == 0) return;

    // Delimiter chars must be single-byte (ASCII). The prefs UI already clamps
    // to one Unicode char, but a non-ASCII unichar would be multi-byte UTF-8 —
    // matching it byte-by-byte against the doc would be wrong. Reject.
    unichar openU  = [openS  characterAtIndex:0];
    unichar closeU = [closeS characterAtIndex:0];
    if (openU > 0x7E || closeU > 0x7E) return;
    const char openCh  = (char)openU;
    const char closeCh = (char)closeU;

    BOOL entireDoc = [ud boolForKey:kPrefDelimEntireDoc];
    ScintillaView *sci = _scintillaView;

    // Click position. notification->position is -1 for empty-line click —
    // fall back to current caret position (matches Windows lines 229-234).
    sptr_t clickAbs = notification->position;
    if (clickAbs < 0) clickAbs = [sci message:SCI_GETCURRENTPOS];
    if (clickAbs < 0) return;

    const char *buf = NULL;
    sptr_t bufLen = 0;
    sptr_t lineStart = 0;     // absolute byte offset of buf[0] in the document
    sptr_t clickRel  = 0;     // click position relative to buf[0]
    NSData *lineCopy = nil;   // retains the malloc'd line buffer in single-line mode

    if (entireDoc) {
        bufLen = [sci message:SCI_GETLENGTH];
        if (bufLen <= 0) return;
        buf = (const char *)[sci message:SCI_GETCHARACTERPOINTER];
        if (!buf) return;
        clickRel = clickAbs;
    } else {
        sptr_t line = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)clickAbs];
        sptr_t lineLen = [sci message:SCI_LINELENGTH wParam:(uptr_t)line];
        if (lineLen <= 0) return;
        char *tmp = (char *)malloc((size_t)lineLen + 1);
        if (!tmp) return;
        [sci message:SCI_GETLINE wParam:(uptr_t)line lParam:(sptr_t)tmp];
        tmp[lineLen] = '\0';
        lineCopy = [NSData dataWithBytesNoCopy:tmp length:(NSUInteger)lineLen freeWhenDone:YES];
        buf = (const char *)lineCopy.bytes;
        bufLen = lineLen;
        lineStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)line];
        clickRel = clickAbs - lineStart;
    }

    if (clickRel < 0 || clickRel >= bufLen) return;

    sptr_t leftmost = -1;
    sptr_t rightmost = -1;

    if (openCh == closeCh) {
        // Same delimiter on both sides (e.g. "..."). Scan outward from the
        // click; if the delimiter is " also respect backslash escapes.
        for (sptr_t i = clickRel; i >= 0; --i) {
            if (buf[i] == openCh) {
                if (openCh == '"' && i > 0 && buf[i - 1] == '\\') continue;
                leftmost = i;
                break;
            }
        }
        if (leftmost < 0) return;
        for (sptr_t i = clickRel; i < bufLen; ++i) {
            if (buf[i] == closeCh) {
                if (closeCh == '"' && i > 0 && buf[i - 1] == '\\') continue;
                rightmost = i;
                break;
            }
        }
    } else {
        // Distinct pair like (). Stack-based matched-pair scan; pick the
        // innermost matched pair that brackets the click position. Uses
        // std::vector to avoid NSNumber boxing in deeply-nested files.
        std::vector<sptr_t> opens;
        opens.reserve(64);
        for (sptr_t i = 0; i < bufLen; ++i) {
            if (buf[i] == openCh) {
                opens.push_back(i);
            } else if (buf[i] == closeCh && !opens.empty()) {
                sptr_t opener = opens.back();
                opens.pop_back();
                if (opener <= clickRel && i >= clickRel &&
                    (leftmost < 0 || opener > leftmost)) {
                    leftmost  = opener;
                    rightmost = i;
                }
            }
        }
    }

    if (leftmost < 0 || rightmost < 0) return;

    // Selection covers content *between* the delimiters, exclusive of them
    // (matches Windows lines 358-366).
    //
    // CRITICAL: use SCI_SETSEL, not SCI_SETANCHOR + SCI_SETCURRENTPOS. With
    // Ctrl held (which on macOS = ⌘ after ScintillaCocoa's modifier swap),
    // Scintilla's Editor.cxx:4806 SKIPS the SetEmptySelection call, so the
    // word at the click position is ADDED as a second selection on top of
    // whatever was previously selected. SCI_SETANCHOR/SCI_SETCURRENTPOS only
    // mutate the main selection without clearing the others — Cmd+C would
    // then copy both and concatenate with newlines (selN=2, "X\nhello world").
    // SCI_SETSEL clears any multi-selection and sets a single stream range.
    sptr_t anchor  = lineStart + leftmost + 1;
    sptr_t current = lineStart + rightmost;
    [sci message:SCI_SETSEL wParam:(uptr_t)anchor lParam:(sptr_t)current];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Text helpers

/// Get selected text as NSString. Returns nil if no selection.
- (nullable NSString *)selectedText {
    // SCI_GETSELTEXT returns the selection length in bytes WITHOUT the NUL,
    // but writes a terminating NUL one byte past that length — so the buffer
    // must be len + 1 bytes (len == 1 is a real single-character selection).
    sptr_t len = [_scintillaView message:SCI_GETSELTEXT wParam:0 lParam:0];
    if (len <= 0) return nil; // no selection
    char *buf = (char *)malloc((size_t)len + 1);
    if (!buf) return nil;
    [_scintillaView message:SCI_GETSELTEXT wParam:0 lParam:(sptr_t)buf];
    NSString *s = [NSString stringWithUTF8String:buf] ?: @"";
    free(buf);
    return s.length ? s : nil;
}

/// Replace the current selection with str (wraps in undo group).
- (void)replaceSelectionWith:(NSString *)str {
    [_scintillaView message:SCI_BEGINUNDOACTION];
    [_scintillaView message:SCI_REPLACESEL wParam:0 lParam:(sptr_t)str.UTF8String];
    [_scintillaView message:SCI_ENDUNDOACTION];
}

// ── Character insertion (ASCII Codes Panel) ───────────────────────────────────

- (void)insertCharacterString:(NSString *)str {
    if (!str.length) return;
    ScintillaView *sci = _scintillaView;
    // Use NSData so null bytes and multi-byte UTF-8 sequences are handled correctly.
    NSData *data = [str dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    [sci message:SCI_REPLACESEL wParam:0 lParam:(sptr_t)""];  // clear selection
    [sci message:SCI_ADDTEXT wParam:(uptr_t)data.length lParam:(sptr_t)data.bytes];
    // Return keyboard focus to the editor so the user can keep typing.
    [sci.window makeFirstResponder:sci];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Case Conversion

- (void)convertToUppercase:(id)sender {
    NSString *sel = [self selectedText]; if (!sel) return;
    [self replaceSelectionWith:sel.uppercaseString];
}

- (void)convertToLowercase:(id)sender {
    NSString *sel = [self selectedText]; if (!sel) return;
    [self replaceSelectionWith:sel.lowercaseString];
}

- (void)convertToProperCase:(id)sender {
    NSString *sel = [self selectedText]; if (!sel) return;
    [self replaceSelectionWith:sel.capitalizedString];
}

- (void)convertToSentenceCase:(id)sender {
    NSString *sel = [self selectedText]; if (!sel) return;
    NSMutableString *result = [sel mutableCopy];
    BOOL nextUpper = YES;
    for (NSUInteger i = 0; i < result.length; i++) {
        unichar c = [result characterAtIndex:i];
        if (nextUpper && isalpha(c)) {
            [result replaceCharactersInRange:NSMakeRange(i, 1)
                                  withString:[[NSString stringWithCharacters:&c length:1] uppercaseString]];
            nextUpper = NO;
        } else if (c == '.' || c == '!' || c == '?') {
            nextUpper = YES;
        }
    }
    [self replaceSelectionWith:result];
}

- (void)convertToInvertedCase:(id)sender {
    NSString *sel = [self selectedText]; if (!sel) return;
    NSMutableString *result = [NSMutableString stringWithCapacity:sel.length];
    for (NSUInteger i = 0; i < sel.length; i++) {
        unichar c = [sel characterAtIndex:i];
        NSString *ch = [NSString stringWithCharacters:&c length:1];
        [result appendString:isupper(c) ? ch.lowercaseString : ch.uppercaseString];
    }
    [self replaceSelectionWith:result];
}

- (void)convertToRandomCase:(id)sender {
    NSString *sel = [self selectedText]; if (!sel) return;
    NSMutableString *result = [NSMutableString stringWithCapacity:sel.length];
    for (NSUInteger i = 0; i < sel.length; i++) {
        unichar c = [sel characterAtIndex:i];
        NSString *ch = [NSString stringWithCharacters:&c length:1];
        [result appendString:(arc4random_uniform(2) == 0) ? ch.uppercaseString : ch.lowercaseString];
    }
    [self replaceSelectionWith:result];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Line Sorting / Cleanup

/// Returns all lines in the current selection (or whole document if no selection).
/// Also sets *startPos and *endPos to the document range that was used.
- (NSMutableArray<NSString *> *)linesForSortingStartPos:(sptr_t *)startPos endPos:(sptr_t *)endPos {
    ScintillaView *sci = _scintillaView;
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];
    BOOL hasSelection = (selStart != selEnd);

    sptr_t lineStart, lineEnd;
    if (hasSelection) {
        lineStart = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selStart];
        lineEnd   = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selEnd];
        // If selection ends at col 0 of the next line, don't include that line
        if (selEnd == [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)lineEnd] && lineEnd > lineStart)
            lineEnd--;
    } else {
        lineStart = 0;
        lineEnd   = [sci message:SCI_GETLINECOUNT] - 1;
        // GETLINECOUNT includes the phantom empty line after a trailing EOL.
        // Excluding it keeps a whole-document sort from floating a blank line
        // to the top and from swallowing the file's final newline (the range
        // then stops at the end of the last content line, before that EOL).
        if (lineEnd > lineStart) {
            sptr_t lastStart = [sci message:SCI_POSITIONFROMLINE   wParam:(uptr_t)lineEnd];
            sptr_t lastEnd   = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)lineEnd];
            if (lastEnd == lastStart) lineEnd--;
        }
    }

    *startPos = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)lineStart];
    *endPos   = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)lineEnd];

    NSMutableArray *lines = [NSMutableArray array];
    for (sptr_t ln = lineStart; ln <= lineEnd; ln++) {
        sptr_t start = [sci message:SCI_POSITIONFROMLINE    wParam:(uptr_t)ln];
        sptr_t end   = [sci message:SCI_GETLINEENDPOSITION  wParam:(uptr_t)ln];
        sptr_t len   = end - start;
        char *buf = (char *)calloc((size_t)(len + 1), 1);
        Sci_TextRangeFull tr;
        tr.chrg.cpMin = (Sci_Position)start;
        tr.chrg.cpMax = (Sci_Position)end;
        tr.lpstrText  = buf;
        [sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&tr];
        NSString *line = [NSString stringWithUTF8String:buf] ?: @"";
        free(buf);
        [lines addObject:line];
    }
    return lines;
}

- (void)applySortedLines:(NSArray<NSString *> *)lines startPos:(sptr_t)start endPos:(sptr_t)end {
    NSString *eol = self.eolName;
    NSString *sep = [eol isEqualToString:@"CRLF"] ? @"\r\n" : [eol isEqualToString:@"CR"] ? @"\r" : @"\n";
    NSString *joined = [lines componentsJoinedByString:sep];
    [_scintillaView message:SCI_BEGINUNDOACTION];
    [_scintillaView message:SCI_SETTARGETSTART wParam:(uptr_t)start];
    [_scintillaView message:SCI_SETTARGETEND   wParam:(uptr_t)end];
    // SCI_REPLACETARGET wParam is a BYTE count — use the UTF-8 byte length, not
    // joined.length (UTF-16 units), or non-ASCII content gets truncated.
    const char *joinedUTF8 = joined.UTF8String;
    [_scintillaView message:SCI_REPLACETARGET  wParam:(uptr_t)strlen(joinedUTF8)
                                               lParam:(sptr_t)joinedUTF8];
    [_scintillaView message:SCI_ENDUNDOACTION];
}

- (void)sortLinesAscending:(id)sender {
    sptr_t s, e;
    NSMutableArray *lines = [self linesForSortingStartPos:&s endPos:&e];
    [lines sortUsingSelector:@selector(compare:)];
    [self applySortedLines:lines startPos:s endPos:e];
}

- (void)sortLinesDescending:(id)sender {
    sptr_t s, e;
    NSMutableArray *lines = [self linesForSortingStartPos:&s endPos:&e];
    [lines sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [b compare:a];
    }];
    [self applySortedLines:lines startPos:s endPos:e];
}

- (void)sortLinesAscendingCI:(id)sender {
    sptr_t s, e;
    NSMutableArray *lines = [self linesForSortingStartPos:&s endPos:&e];
    [lines sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a caseInsensitiveCompare:b];
    }];
    [self applySortedLines:lines startPos:s endPos:e];
}

- (void)sortLinesByLengthAsc:(id)sender {
    sptr_t s, e;
    NSMutableArray *lines = [self linesForSortingStartPos:&s endPos:&e];
    [lines sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        if (a.length < b.length) return NSOrderedAscending;
        if (a.length > b.length) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    [self applySortedLines:lines startPos:s endPos:e];
}

- (void)sortLinesByLengthDesc:(id)sender {
    sptr_t s, e;
    NSMutableArray *lines = [self linesForSortingStartPos:&s endPos:&e];
    [lines sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        if (a.length > b.length) return NSOrderedAscending;
        if (a.length < b.length) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    [self applySortedLines:lines startPos:s endPos:e];
}

- (void)removeDuplicateLines:(id)sender {
    sptr_t s, e;
    NSMutableArray *lines = [self linesForSortingStartPos:&s endPos:&e];
    NSMutableOrderedSet *seen = [NSMutableOrderedSet orderedSet];
    for (NSString *line in lines) [seen addObject:line];
    [self applySortedLines:seen.array startPos:s endPos:e];
}

- (void)trimTrailingWhitespace:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t firstLine, lastLine;
    [self _selectionLineRange:&firstLine last:&lastLine];
    [sci message:SCI_BEGINUNDOACTION];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    for (sptr_t ln = firstLine; ln <= lastLine; ln++) {
        sptr_t start = [sci message:SCI_POSITIONFROMLINE   wParam:(uptr_t)ln];
        sptr_t end   = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)ln];
        sptr_t len   = end - start;
        if (len <= 0) continue;
        char *buf = (char *)calloc((size_t)(len + 1), 1);
        Sci_TextRangeFull tr;
        tr.chrg.cpMin = (Sci_Position)start;
        tr.chrg.cpMax = (Sci_Position)end;
        tr.lpstrText  = buf;
        [sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&tr];
        NSString *lineStr = [NSString stringWithUTF8String:buf] ?: @"";
        free(buf);
        NSString *trimmed = [lineStr stringByReplacingOccurrencesOfString:@"\\s+$"
                                                               withString:@""
                                                                  options:NSRegularExpressionSearch
                                                                    range:NSMakeRange(0, lineStr.length)];
        if (![trimmed isEqualToString:lineStr]) {
            sptr_t trimLen = (sptr_t)[trimmed lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            sptr_t newEnd  = start + trimLen;
            [sci message:SCI_SETTARGETSTART wParam:(uptr_t)newEnd];
            [sci message:SCI_SETTARGETEND   wParam:(uptr_t)end];
            [sci message:SCI_REPLACETARGET  wParam:0 lParam:(sptr_t)""];
        }
    }
    [sci message:SCI_ENDUNDOACTION];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Text Direction

static const unsigned int kSCI_SetBidirectional = 2709; // Scintilla::Message::SetBidirectional
static const unsigned int kSCI_GetBidirectional = 2708;

- (void)setTextDirectionRTL:(id)sender {
    [_scintillaView message:kSCI_SetBidirectional wParam:2]; // Bidirectional::R2L
    [self _applyRTLKeyBindings:YES];
    [self _applyRTLLayout:YES];
    // Force word wrap in RTL to avoid horizontal scroll issues
    _savedWrapBeforeRTL = _wordWrapEnabled;
    if (!_wordWrapEnabled) {
        _wordWrapEnabled = YES;
        [_scintillaView message:SCI_SETWRAPMODE wParam:SC_WRAP_WORD];
    }
}

- (void)setTextDirectionLTR:(id)sender {
    [_scintillaView message:kSCI_SetBidirectional wParam:0]; // Bidirectional::Disabled
    [self _applyRTLKeyBindings:NO];
    [self _applyRTLLayout:NO];
    // Restore word wrap to its state before RTL was enabled
    if (!_savedWrapBeforeRTL && _wordWrapEnabled) {
        _wordWrapEnabled = NO;
        [_scintillaView message:SCI_SETWRAPMODE wParam:SC_WRAP_NONE];
    }
}

/// RTL layout: ruler (line numbers/bookmarks/fold) moves to the right side.
- (void)_applyRTLLayout:(BOOL)rtl {
    SCIScrollView *sv = (SCIScrollView *)_scintillaView.scrollView;
    sv.rtlMode = rtl;
    [sv tile];
    [sv setNeedsDisplay:YES];
    [sv.verticalRulerView setNeedsDisplay:YES];
}

- (BOOL)isTextDirectionRTL {
    return [_scintillaView message:kSCI_GetBidirectional] == 2;
}

/// Swap left/right arrow key bindings for RTL mode (same approach as Windows NPP).
- (void)_applyRTLKeyBindings:(BOOL)rtl {
    // Scintilla key codes: SCK_LEFT=300, SCK_RIGHT=301
    // Modifiers: SCMOD_NORM=0, SCMOD_SHIFT=1, SCMOD_CTRL=2, SCMOD_ALT=4
    // On macOS, Ctrl in Scintilla maps to Cmd key
    const int kLeft = 300, kRight = 301;
    struct { int key; int mod; int cmdL; int cmdR; } bindings[] = {
        { kLeft,  0, SCI_CHARLEFT,       SCI_CHARRIGHT },
        { kRight, 0, SCI_CHARRIGHT,      SCI_CHARLEFT },
        { kLeft,  1, SCI_CHARLEFTEXTEND, SCI_CHARRIGHTEXTEND },
        { kRight, 1, SCI_CHARRIGHTEXTEND, SCI_CHARLEFTEXTEND },
        { kLeft,  2, SCI_WORDLEFT,       SCI_WORDRIGHT },
        { kRight, 2, SCI_WORDRIGHT,      SCI_WORDLEFT },
        { kLeft,  3, SCI_WORDLEFTEXTEND, SCI_WORDRIGHTEXTEND },
        { kRight, 3, SCI_WORDRIGHTEXTEND, SCI_WORDLEFTEXTEND },
        { kLeft,  5, SCI_WORDLEFTEND,    SCI_WORDRIGHTEND },
        { kRight, 5, SCI_WORDRIGHTEND,   SCI_WORDLEFTEND },
    };
    for (size_t i = 0; i < sizeof(bindings)/sizeof(bindings[0]); i++) {
        int keyDef = bindings[i].key + (bindings[i].mod << 16);
        int cmd = rtl ? bindings[i].cmdR : bindings[i].cmdL;
        [_scintillaView message:SCI_ASSIGNCMDKEY wParam:(uptr_t)keyDef lParam:cmd];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Scroller style helpers

- (void)_applyLegacyScrollerStyle {
    _scintillaView.scrollView.scrollerStyle = NSScrollerStyleLegacy;
    _scintillaView.scrollView.autohidesScrollers = YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    // The system may reset scrollerStyle when the view enters a window.
    if (self.window) {
        [self _applyLegacyScrollerStyle];
        // After the view is added to a window and laid out, force a full
        // margin repaint so highlightDelimiter is computed with correct
        // LinesOnScreen (sizeClient is zero during init → stale fold highlight).
        dispatch_async(dispatch_get_main_queue(), ^{
            [_scintillaView.scrollView.verticalRulerView setNeedsDisplay:YES];
        });
    }
}

- (void)_scrollerStyleChanged:(NSNotification *)note {
    [self _applyLegacyScrollerStyle];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - View Toggles

- (void)showWhiteSpaceAndTab:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t current = [sci message:SCI_GETVIEWWS];
    // Color is already set persistently (red BGR) in applyDefaultTheme.
    [sci message:SCI_SETVIEWWS wParam:(current == SCWS_INVISIBLE ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE)];
}

- (void)showEndOfLine:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t current = [sci message:SCI_GETVIEWEOL];
    [sci message:SCI_SETVIEWEOL wParam:(!current ? 1 : 0)];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Fold Levels

/// Private helper — fold or unfold all headers at a specific fold level (0-based).
- (void)_setFoldLevel:(int)level collapsed:(BOOL)collapse {
    ScintillaView *sci = _scintillaView;
    sptr_t maxLine = [sci message:SCI_GETLINECOUNT];
    for (sptr_t ln = 0; ln < maxLine; ln++) {
        sptr_t lvl = [sci message:SCI_GETFOLDLEVEL wParam:(uptr_t)ln];
        if (!(lvl & SC_FOLDLEVELHEADERFLAG)) continue;
        sptr_t lvlNum = (lvl - SC_FOLDLEVELBASE) & SC_FOLDLEVELNUMBERMASK;
        if (lvlNum != level) continue;
        sptr_t expanded = [sci message:SCI_GETFOLDEXPANDED wParam:(uptr_t)ln];
        if (collapse && expanded)
            [sci message:SCI_FOLDCHILDREN wParam:(uptr_t)ln lParam:SC_FOLDACTION_CONTRACT];
        else if (!collapse && !expanded)
            [sci message:SCI_FOLDCHILDREN wParam:(uptr_t)ln lParam:SC_FOLDACTION_EXPAND];
    }
}

- (void)foldLevel1:(id)s   { [self _setFoldLevel:0 collapsed:YES]; }
- (void)foldLevel2:(id)s   { [self _setFoldLevel:1 collapsed:YES]; }
- (void)foldLevel3:(id)s   { [self _setFoldLevel:2 collapsed:YES]; }
- (void)foldLevel4:(id)s   { [self _setFoldLevel:3 collapsed:YES]; }
- (void)foldLevel5:(id)s   { [self _setFoldLevel:4 collapsed:YES]; }
- (void)foldLevel6:(id)s   { [self _setFoldLevel:5 collapsed:YES]; }
- (void)foldLevel7:(id)s   { [self _setFoldLevel:6 collapsed:YES]; }
- (void)foldLevel8:(id)s   { [self _setFoldLevel:7 collapsed:YES]; }

- (void)unfoldLevel1:(id)s { [self _setFoldLevel:0 collapsed:NO]; }
- (void)unfoldLevel2:(id)s { [self _setFoldLevel:1 collapsed:NO]; }
- (void)unfoldLevel3:(id)s { [self _setFoldLevel:2 collapsed:NO]; }
- (void)unfoldLevel4:(id)s { [self _setFoldLevel:3 collapsed:NO]; }
- (void)unfoldLevel5:(id)s { [self _setFoldLevel:4 collapsed:NO]; }
- (void)unfoldLevel6:(id)s { [self _setFoldLevel:5 collapsed:NO]; }
- (void)unfoldLevel7:(id)s { [self _setFoldLevel:6 collapsed:NO]; }
- (void)unfoldLevel8:(id)s { [self _setFoldLevel:7 collapsed:NO]; }

- (void)unfoldCurrentLevel:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t curLine = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)[sci message:SCI_GETCURRENTPOS]];
    [sci message:SCI_FOLDCHILDREN wParam:(uptr_t)curLine lParam:SC_FOLDACTION_EXPAND];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Insert Blank Lines / Date-Time

- (void)insertBlankLineAbove:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t curLine = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)[sci message:SCI_GETCURRENTPOS]];
    sptr_t linePos = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)curLine];
    NSString *eol = self.eolName;
    NSString *eolStr = [eol isEqualToString:@"CRLF"] ? @"\r\n" : [eol isEqualToString:@"CR"] ? @"\r" : @"\n";
    [sci message:SCI_BEGINUNDOACTION];
    [sci message:SCI_INSERTTEXT wParam:(uptr_t)linePos lParam:(sptr_t)eolStr.UTF8String];
    [sci message:SCI_SETEMPTYSELECTION wParam:(uptr_t)linePos];
    [sci message:SCI_ENDUNDOACTION];
}

- (void)insertBlankLineBelow:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t curLine = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)[sci message:SCI_GETCURRENTPOS]];
    sptr_t lineEnd = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)curLine];
    NSString *eol = self.eolName;
    NSString *eolStr = [eol isEqualToString:@"CRLF"] ? @"\r\n" : [eol isEqualToString:@"CR"] ? @"\r" : @"\n";
    [sci message:SCI_BEGINUNDOACTION];
    [sci message:SCI_INSERTTEXT wParam:(uptr_t)lineEnd lParam:(sptr_t)eolStr.UTF8String];
    [sci message:SCI_SETEMPTYSELECTION wParam:(uptr_t)(lineEnd + (sptr_t)eolStr.length)];
    [sci message:SCI_ENDUNDOACTION];
}

- (void)insertDateTimeShort:(id)sender {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateStyle = NSDateFormatterShortStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    NSString *s = [fmt stringFromDate:[NSDate date]];
    [self replaceSelectionWith:s];
}

- (void)insertDateTimeLong:(id)sender {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateStyle = NSDateFormatterLongStyle;
    fmt.timeStyle = NSDateFormatterLongStyle;
    NSString *s = [fmt stringFromDate:[NSDate date]];
    [self replaceSelectionWith:s];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Case Conversion (Blend variants)

/// Proper Case (Blend): uppercase first letter of each word, leave rest unchanged.
- (void)convertToProperCaseBlend:(id)sender {
    NSString *sel = [self selectedText]; if (!sel) return;
    NSMutableString *result = [sel mutableCopy];
    BOOL prevWasAlnum = NO;
    for (NSUInteger i = 0; i < result.length; i++) {
        unichar c = [result characterAtIndex:i];
        if ([[NSCharacterSet letterCharacterSet] characterIsMember:c]) {
            if (!prevWasAlnum) {
                unichar up = [[[NSString stringWithCharacters:&c length:1] uppercaseString] characterAtIndex:0];
                [result replaceCharactersInRange:NSMakeRange(i, 1)
                                     withString:[NSString stringWithCharacters:&up length:1]];
            }
            prevWasAlnum = YES;
        } else {
            prevWasAlnum = [[NSCharacterSet alphanumericCharacterSet] characterIsMember:c];
        }
    }
    [self replaceSelectionWith:result];
}

/// Sentence case (Blend): uppercase first letter of each sentence, leave rest unchanged.
- (void)convertToSentenceCaseBlend:(id)sender {
    NSString *sel = [self selectedText]; if (!sel) return;
    NSMutableString *result = [sel mutableCopy];
    BOOL nextUpper = YES;
    for (NSUInteger i = 0; i < result.length; i++) {
        unichar c = [result characterAtIndex:i];
        if ([[NSCharacterSet letterCharacterSet] characterIsMember:c]) {
            if (nextUpper) {
                unichar up = [[[NSString stringWithCharacters:&c length:1] uppercaseString] characterAtIndex:0];
                [result replaceCharactersInRange:NSMakeRange(i, 1)
                                     withString:[NSString stringWithCharacters:&up length:1]];
                nextUpper = NO;
            }
        } else if (c == '.' || c == '!' || c == '?') {
            nextUpper = YES;
        }
    }
    [self replaceSelectionWith:result];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Join Lines / Sort Extensions

- (void)joinLines:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];
    if (selStart == selEnd)
        [sci message:SCI_TARGETWHOLEDOCUMENT];
    else
        [sci message:SCI_TARGETFROMSELECTION];
    [sci message:SCI_LINESJOIN];
}

- (void)sortLinesRandomly:(id)sender {
    sptr_t s, e;
    NSMutableArray *lines = [self linesForSortingStartPos:&s endPos:&e];
    for (NSUInteger i = lines.count - 1; i > 0; i--) {
        NSUInteger j = arc4random_uniform((uint32_t)(i + 1));
        [lines exchangeObjectAtIndex:i withObjectAtIndex:j];
    }
    [self applySortedLines:lines startPos:s endPos:e];
}

- (void)sortLinesReverse:(id)sender {
    sptr_t s, e;
    NSMutableArray *lines = [self linesForSortingStartPos:&s endPos:&e];
    NSArray *reversed = lines.reverseObjectEnumerator.allObjects;
    [self applySortedLines:reversed startPos:s endPos:e];
}

- (void)sortLinesIntAsc:(id)sender {
    sptr_t s, e;
    NSMutableArray *lines = [self linesForSortingStartPos:&s endPos:&e];
    [lines sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        long long va = [a longLongValue];
        long long vb = [b longLongValue];
        return va < vb ? NSOrderedAscending : va > vb ? NSOrderedDescending : NSOrderedSame;
    }];
    [self applySortedLines:lines startPos:s endPos:e];
}

- (void)sortLinesIntDesc:(id)sender {
    sptr_t s, e;
    NSMutableArray *lines = [self linesForSortingStartPos:&s endPos:&e];
    [lines sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        long long va = [a longLongValue];
        long long vb = [b longLongValue];
        return va > vb ? NSOrderedAscending : va < vb ? NSOrderedDescending : NSOrderedSame;
    }];
    [self applySortedLines:lines startPos:s endPos:e];
}

- (void)sortLinesDecimalDotAsc:(id)sender {
    sptr_t s, e;
    NSMutableArray *lines = [self linesForSortingStartPos:&s endPos:&e];
    [lines sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        double va = a.doubleValue;
        double vb = b.doubleValue;
        return va < vb ? NSOrderedAscending : va > vb ? NSOrderedDescending : NSOrderedSame;
    }];
    [self applySortedLines:lines startPos:s endPos:e];
}

- (void)sortLinesDecimalDotDesc:(id)sender {
    sptr_t s, e;
    NSMutableArray *lines = [self linesForSortingStartPos:&s endPos:&e];
    [lines sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        double va = a.doubleValue;
        double vb = b.doubleValue;
        return va > vb ? NSOrderedAscending : va < vb ? NSOrderedDescending : NSOrderedSame;
    }];
    [self applySortedLines:lines startPos:s endPos:e];
}

- (void)sortLinesDecimalCommaAsc:(id)sender {
    sptr_t s, e;
    NSMutableArray *lines = [self linesForSortingStartPos:&s endPos:&e];
    NSLocale *commaLocale = [NSLocale localeWithLocaleIdentifier:@"fr_FR"]; // uses comma as decimal separator
    [lines sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        double va = [[NSDecimalNumber decimalNumberWithString:a locale:commaLocale] doubleValue];
        double vb = [[NSDecimalNumber decimalNumberWithString:b locale:commaLocale] doubleValue];
        return va < vb ? NSOrderedAscending : va > vb ? NSOrderedDescending : NSOrderedSame;
    }];
    [self applySortedLines:lines startPos:s endPos:e];
}

- (void)sortLinesDecimalCommaDesc:(id)sender {
    sptr_t s, e;
    NSMutableArray *lines = [self linesForSortingStartPos:&s endPos:&e];
    NSLocale *commaLocale = [NSLocale localeWithLocaleIdentifier:@"fr_FR"];
    [lines sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        double va = [[NSDecimalNumber decimalNumberWithString:a locale:commaLocale] doubleValue];
        double vb = [[NSDecimalNumber decimalNumberWithString:b locale:commaLocale] doubleValue];
        return va > vb ? NSOrderedAscending : va < vb ? NSOrderedDescending : NSOrderedSame;
    }];
    [self applySortedLines:lines startPos:s endPos:e];
}

- (void)removeConsecutiveDuplicateLines:(id)sender {
    sptr_t s, e;
    NSMutableArray *lines = [self linesForSortingStartPos:&s endPos:&e];
    NSMutableArray *result = [NSMutableArray array];
    NSString *prev = nil;
    for (NSString *line in lines) {
        if (![line isEqualToString:prev]) [result addObject:line];
        prev = line;
    }
    [self applySortedLines:result startPos:s endPos:e];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Blank Operations

/// Helper: read the text of line `ln` (without EOL) as NSString, or nil if empty.
- (NSString *)_lineTextAt:(sptr_t)ln {
    ScintillaView *sci = _scintillaView;
    sptr_t start = [sci message:SCI_POSITIONFROMLINE    wParam:(uptr_t)ln];
    sptr_t end   = [sci message:SCI_GETLINEENDPOSITION  wParam:(uptr_t)ln];
    sptr_t len   = end - start;
    if (len <= 0) return @"";
    char *buf = (char *)calloc((size_t)(len + 1), 1);
    Sci_TextRangeFull tr;
    tr.chrg.cpMin = (Sci_Position)start;
    tr.chrg.cpMax = (Sci_Position)end;
    tr.lpstrText  = buf;
    [sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&tr];
    NSString *s = [NSString stringWithUTF8String:buf] ?: @"";
    free(buf);
    return s;
}

/// Helper: replace the content of line `ln` (without EOL) with `newText`.
- (void)_setLineText:(NSString *)newText atLine:(sptr_t)ln {
    ScintillaView *sci = _scintillaView;
    sptr_t start = [sci message:SCI_POSITIONFROMLINE    wParam:(uptr_t)ln];
    sptr_t end   = [sci message:SCI_GETLINEENDPOSITION  wParam:(uptr_t)ln];
    const char *utf8 = newText.UTF8String;
    [sci message:SCI_SETTARGETSTART wParam:(uptr_t)start];
    [sci message:SCI_SETTARGETEND   wParam:(uptr_t)end];
    [sci message:SCI_REPLACETARGET  wParam:(uptr_t)strlen(utf8) lParam:(sptr_t)utf8];
}

- (void)trimLeadingSpaces:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t firstLine, lastLine;
    [self _selectionLineRange:&firstLine last:&lastLine];
    [sci message:SCI_BEGINUNDOACTION];
    for (sptr_t ln = lastLine; ln >= firstLine; ln--) {
        NSString *orig = [self _lineTextAt:ln];
        NSString *trimmed = [orig stringByReplacingOccurrencesOfString:@"^[\\t ]+"
                                                            withString:@""
                                                               options:NSRegularExpressionSearch
                                                                 range:NSMakeRange(0, orig.length)];
        if (![trimmed isEqualToString:orig]) [self _setLineText:trimmed atLine:ln];
    }
    [sci message:SCI_ENDUNDOACTION];
}

- (void)trimLeadingAndTrailingSpaces:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t firstLine, lastLine;
    [self _selectionLineRange:&firstLine last:&lastLine];
    [sci message:SCI_BEGINUNDOACTION];
    for (sptr_t ln = lastLine; ln >= firstLine; ln--) {
        NSString *orig = [self _lineTextAt:ln];
        NSString *trimmed = [orig stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (![trimmed isEqualToString:orig]) [self _setLineText:trimmed atLine:ln];
    }
    [sci message:SCI_ENDUNDOACTION];
}

- (void)eolToSpace:(id)sender {
    // Replace all line endings with a single space (same as NPP's "EOL to Space")
    ScintillaView *sci = _scintillaView;
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];
    if (selStart == selEnd) {
        [sci message:SCI_TARGETWHOLEDOCUMENT];
    } else {
        [sci message:SCI_SETTARGETSTART wParam:(uptr_t)selStart];
        [sci message:SCI_SETTARGETEND   wParam:(uptr_t)selEnd];
    }
    [sci message:SCI_LINESJOIN];
}

- (void)trimBothAndEOLToSpace:(id)sender {
    [self trimLeadingAndTrailingSpaces:sender];
    [self eolToSpace:sender];
}

- (void)removeBlankLines:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t firstLine, lastLine;
    [self _selectionLineRange:&firstLine last:&lastLine];
    [sci message:SCI_BEGINUNDOACTION];
    // Iterate bottom-up so deletions don't invalidate indices
    for (sptr_t ln = lastLine; ln >= firstLine; ln--) {
        NSString *text = [self _lineTextAt:ln];
        NSString *stripped = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (stripped.length == 0) {
            sptr_t lineStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)ln];
            sptr_t nextStart;
            if (ln + 1 < [sci message:SCI_GETLINECOUNT])
                nextStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)(ln + 1)];
            else
                nextStart = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)ln];
            [sci message:SCI_SETTARGETSTART wParam:(uptr_t)lineStart];
            [sci message:SCI_SETTARGETEND   wParam:(uptr_t)nextStart];
            [sci message:SCI_REPLACETARGET  wParam:0 lParam:(sptr_t)""];
        }
    }
    [sci message:SCI_ENDUNDOACTION];
}

- (void)mergeBlankLines:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t firstLine, lastLine;
    [self _selectionLineRange:&firstLine last:&lastLine];
    [sci message:SCI_BEGINUNDOACTION];
    // Go bottom-up; delete blank line if the previous line is also blank
    for (sptr_t ln = lastLine; ln >= MAX(firstLine, 1); ln--) {
        NSString *cur  = [self _lineTextAt:ln];
        NSString *prev = [self _lineTextAt:ln - 1];
        BOOL curBlank  = [[cur  stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] == 0;
        BOOL prevBlank = [[prev stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] == 0;
        if (curBlank && prevBlank) {
            sptr_t lineStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)ln];
            sptr_t nextStart;
            if (ln + 1 < [sci message:SCI_GETLINECOUNT])
                nextStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)(ln + 1)];
            else
                nextStart = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)ln];
            [sci message:SCI_SETTARGETSTART wParam:(uptr_t)lineStart];
            [sci message:SCI_SETTARGETEND   wParam:(uptr_t)nextStart];
            [sci message:SCI_REPLACETARGET  wParam:0 lParam:(sptr_t)""];
        }
    }
    [sci message:SCI_ENDUNDOACTION];
}

- (void)tabsToSpaces:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t tabWidth = [sci message:SCI_GETTABWIDTH];
    if (tabWidth <= 0) tabWidth = 4;
    sptr_t firstLine, lastLine;
    [self _selectionLineRange:&firstLine last:&lastLine];
    [sci message:SCI_BEGINUNDOACTION];
    for (sptr_t ln = lastLine; ln >= firstLine; ln--) {
        NSString *orig = [self _lineTextAt:ln];
        if (![orig containsString:@"\t"]) continue;
        // Column-aware expansion: each tab expands to reach the next tab stop.
        NSMutableString *result = [NSMutableString stringWithCapacity:orig.length * 2];
        NSInteger col = 0;
        for (NSUInteger i = 0; i < orig.length; i++) {
            unichar c = [orig characterAtIndex:i];
            if (c == '\t') {
                NSInteger spaces = tabWidth - (col % tabWidth);
                for (NSInteger s = 0; s < spaces; s++) [result appendString:@" "];
                col += spaces;
            } else {
                [result appendFormat:@"%C", c];
                col++;
            }
        }
        if (![result isEqualToString:orig]) [self _setLineText:result atLine:ln];
    }
    [sci message:SCI_ENDUNDOACTION];
}

- (void)spacesToTabsLeading:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t tabWidth = [sci message:SCI_GETTABWIDTH];
    if (tabWidth <= 0) tabWidth = 4;
    sptr_t firstLine, lastLine;
    [self _selectionLineRange:&firstLine last:&lastLine];
    [sci message:SCI_BEGINUNDOACTION];
    for (sptr_t ln = lastLine; ln >= firstLine; ln--) {
        NSString *orig = [self _lineTextAt:ln];
        // Count leading spaces
        NSUInteger i = 0;
        while (i < orig.length && [orig characterAtIndex:i] == ' ') i++;
        if (i < (NSUInteger)tabWidth) continue;
        NSUInteger tabs = i / (NSUInteger)tabWidth;
        NSUInteger rem  = i % (NSUInteger)tabWidth;
        NSMutableString *newLine = [NSMutableString string];
        for (NSUInteger t = 0; t < tabs; t++) [newLine appendString:@"\t"];
        for (NSUInteger r = 0; r < rem;  r++) [newLine appendString:@" "];
        [newLine appendString:[orig substringFromIndex:i]];
        if (![newLine isEqualToString:orig]) [self _setLineText:newLine atLine:ln];
    }
    [sci message:SCI_ENDUNDOACTION];
}

- (void)spacesToTabsAll:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t tabWidth = [sci message:SCI_GETTABWIDTH];
    if (tabWidth <= 0) tabWidth = 4;
    sptr_t firstLine, lastLine;
    [self _selectionLineRange:&firstLine last:&lastLine];
    NSString *tabStr = @"\t";
    NSString *spaceGroup = [@"" stringByPaddingToLength:(NSUInteger)tabWidth withString:@" " startingAtIndex:0];
    [sci message:SCI_BEGINUNDOACTION];
    for (sptr_t ln = lastLine; ln >= firstLine; ln--) {
        NSString *orig = [self _lineTextAt:ln];
        NSString *replaced = [orig stringByReplacingOccurrencesOfString:spaceGroup withString:tabStr];
        if (![replaced isEqualToString:orig]) [self _setLineText:replaced atLine:ln];
    }
    [sci message:SCI_ENDUNDOACTION];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Read-Only

- (void)toggleReadOnly:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t isRO = [sci message:SCI_GETREADONLY];
    [sci message:SCI_SETREADONLY wParam:(uptr_t)(!isRO)];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Go to Matching Brace / Select and Find

- (void)goToMatchingBrace:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t pos = [sci message:SCI_GETCURRENTPOS];
    // Try current position and one before for brace detection
    sptr_t match = [sci message:SCI_BRACEMATCH wParam:(uptr_t)pos lParam:0];
    if (match == INVALID_POSITION && pos > 0)
        match = [sci message:SCI_BRACEMATCH wParam:(uptr_t)(pos - 1) lParam:0];
    if (match != INVALID_POSITION)
        [sci message:SCI_SETEMPTYSELECTION wParam:(uptr_t)(match + 1)];
}

- (void)selectAndFindNext:(id)sender {
    ScintillaView *sci = _scintillaView;
    // If no selection, select the current word first
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];
    if (selStart == selEnd) {
        sptr_t pos   = [sci message:SCI_GETCURRENTPOS];
        sptr_t wStart = [sci message:SCI_WORDSTARTPOSITION wParam:(uptr_t)pos lParam:1];
        sptr_t wEnd   = [sci message:SCI_WORDENDPOSITION   wParam:(uptr_t)pos lParam:1];
        if (wEnd > wStart)
            [sci message:SCI_SETSEL wParam:(uptr_t)wStart lParam:wEnd];
    }
    NSString *word = [self selectedText];
    if (word.length)
        [self findNext:word matchCase:YES wholeWord:NO wrap:YES];
}

- (void)selectAndFindPrevious:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];
    if (selStart == selEnd) {
        sptr_t pos   = [sci message:SCI_GETCURRENTPOS];
        sptr_t wStart = [sci message:SCI_WORDSTARTPOSITION wParam:(uptr_t)pos lParam:1];
        sptr_t wEnd   = [sci message:SCI_WORDENDPOSITION   wParam:(uptr_t)pos lParam:1];
        if (wEnd > wStart)
            [sci message:SCI_SETSEL wParam:(uptr_t)wStart lParam:wEnd];
    }
    NSString *word = [self selectedText];
    if (word.length)
        [self findPrev:word matchCase:YES wholeWord:NO wrap:YES];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Bookmark Line Operations

/// Returns indices of all lines that have (or don't have) the bookmark marker.
- (NSArray<NSNumber *> *)_bookmarkedLines:(BOOL)bookmarked {
    ScintillaView *sci = _scintillaView;
    NSMutableArray *result = [NSMutableArray array];
    sptr_t lineCount = [sci message:SCI_GETLINECOUNT];
    sptr_t mask = (1 << kBookmarkMarker);
    for (sptr_t ln = 0; ln < lineCount; ln++) {
        sptr_t markers = [sci message:SCI_MARKERGET wParam:(uptr_t)ln];
        if (bookmarked ? (markers & mask) : !(markers & mask))
            [result addObject:@(ln)];
    }
    return result;
}

/// Collect text of a list of lines (by index) joined with the document EOL.
- (NSString *)_textOfLines:(NSArray<NSNumber *> *)lineIndices {
    NSString *eol = self.eolName;
    NSString *sep = [eol isEqualToString:@"CRLF"] ? @"\r\n" : [eol isEqualToString:@"CR"] ? @"\r" : @"\n";
    NSMutableArray *parts = [NSMutableArray array];
    for (NSNumber *n in lineIndices)
        [parts addObject:[self _lineTextAt:n.integerValue]];
    return [parts componentsJoinedByString:sep];
}

- (void)cutBookmarkedLines:(id)sender {
    [self copyBookmarkedLines:sender];
    [self removeBookmarkedLines:sender];
}

- (void)copyBookmarkedLines:(id)sender {
    NSArray *bLines = [self _bookmarkedLines:YES];
    if (!bLines.count) return;
    NSString *text = [self _textOfLines:bLines];
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
}

- (void)removeBookmarkedLines:(id)sender {
    ScintillaView *sci = _scintillaView;
    NSArray *bLines = [self _bookmarkedLines:YES];
    if (!bLines.count) return;
    [sci message:SCI_BEGINUNDOACTION];
    // Delete bottom-up so indices stay valid
    for (NSNumber *n in bLines.reverseObjectEnumerator) {
        sptr_t ln = n.integerValue;
        sptr_t lineStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)ln];
        sptr_t nextStart;
        if (ln + 1 < [sci message:SCI_GETLINECOUNT])
            nextStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)(ln + 1)];
        else
            nextStart = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)ln];
        [sci message:SCI_SETTARGETSTART wParam:(uptr_t)lineStart];
        [sci message:SCI_SETTARGETEND   wParam:(uptr_t)nextStart];
        [sci message:SCI_REPLACETARGET  wParam:0 lParam:(sptr_t)""];
    }
    [sci message:SCI_ENDUNDOACTION];
}

- (void)removeNonBookmarkedLines:(id)sender {
    ScintillaView *sci = _scintillaView;
    NSArray *bLines = [self _bookmarkedLines:NO];
    if (!bLines.count) return;
    [sci message:SCI_BEGINUNDOACTION];
    for (NSNumber *n in bLines.reverseObjectEnumerator) {
        sptr_t ln = n.integerValue;
        sptr_t lineStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)ln];
        sptr_t nextStart;
        if (ln + 1 < [sci message:SCI_GETLINECOUNT])
            nextStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)(ln + 1)];
        else
            nextStart = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)ln];
        [sci message:SCI_SETTARGETSTART wParam:(uptr_t)lineStart];
        [sci message:SCI_SETTARGETEND   wParam:(uptr_t)nextStart];
        [sci message:SCI_REPLACETARGET  wParam:0 lParam:(sptr_t)""];
    }
    [sci message:SCI_ENDUNDOACTION];
}

- (void)inverseBookmark:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t lineCount = [sci message:SCI_GETLINECOUNT];
    sptr_t mask = (1 << kBookmarkMarker);
    for (sptr_t ln = 0; ln < lineCount; ln++) {
        sptr_t markers = [sci message:SCI_MARKERGET wParam:(uptr_t)ln];
        if (markers & mask)
            [sci message:SCI_MARKERDELETE wParam:(uptr_t)ln lParam:kBookmarkMarker];
        else
            [sci message:SCI_MARKERADD    wParam:(uptr_t)ln lParam:kBookmarkMarker];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Column Mode / Select In Braces

/// Toggle rectangular (column) selection mode on/off.
- (void)columnMode:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t mode = [sci message:SCI_GETSELECTIONMODE];
    [sci message:SCI_SETSELECTIONMODE
          wParam:(mode == SC_SEL_RECTANGLE ? SC_SEL_STREAM : SC_SEL_RECTANGLE)];
}

/// Select all text between the brace/bracket/paren pair surrounding the cursor.
- (void)selectAllInBraces:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t pos = [sci message:SCI_GETCURRENTPOS];
    sptr_t match = INVALID_POSITION;
    sptr_t bracePos = INVALID_POSITION;
    // Try the character at pos and one before
    for (sptr_t tryPos = pos; tryPos >= MAX(0, pos - 1) && match == INVALID_POSITION; tryPos--) {
        sptr_t ch = [sci message:SCI_GETCHARAT wParam:(uptr_t)tryPos];
        if (ch == '(' || ch == '[' || ch == '{' || ch == ')' || ch == ']' || ch == '}') {
            match = [sci message:SCI_BRACEMATCH wParam:(uptr_t)tryPos lParam:0];
            if (match != INVALID_POSITION) bracePos = tryPos;
        }
    }
    if (match == INVALID_POSITION) return;
    sptr_t selStart = MIN(bracePos, match);
    sptr_t selEnd   = MAX(bracePos, match) + 1;
    [sci message:SCI_SETSEL wParam:(uptr_t)selStart lParam:selEnd];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Base64 Encode / Decode

- (void)base64Encode:(id)sender {
    NSString *sel = [self selectedText]; if (!sel) return;
    NSData   *data    = [sel dataUsingEncoding:NSUTF8StringEncoding];
    NSString *encoded = [data base64EncodedStringWithOptions:0];
    [self replaceSelectionWith:encoded];
}

- (void)base64Decode:(id)sender {
    NSString *sel = [self selectedText]; if (!sel) return;
    NSData   *data = [[NSData alloc] initWithBase64EncodedString:sel
                      options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!data) return;
    NSString *decoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!decoded) return;
    [self replaceSelectionWith:decoded];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - ASCII / Hex Conversion

- (void)asciiToHex:(id)sender {
    NSString *sel = [self selectedText]; if (!sel) return;
    NSData *data = [sel dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 3];
    for (NSUInteger i = 0; i < data.length; i++) {
        if (i > 0) [hex appendString:@" "];
        [hex appendFormat:@"%02X", bytes[i]];
    }
    [self replaceSelectionWith:hex];
}

- (void)hexToAscii:(id)sender {
    NSString *sel = [self selectedText]; if (!sel) return;
    // Split on whitespace / commas; parse each token as a hex byte
    NSArray<NSString *> *parts = [sel componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@" ,\t\r\n"]];
    NSMutableData *data = [NSMutableData data];
    for (NSString *part in parts) {
        if (!part.length) continue;
        unsigned int byte = 0;
        if ([[NSScanner scannerWithString:part] scanHexInt:&byte]) {
            unsigned char b = (unsigned char)(byte & 0xFF);
            [data appendBytes:&b length:1];
        }
    }
    if (!data.length) { NSBeep(); return; }
    NSString *ascii = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                   ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!ascii) { NSBeep(); return; }
    [self replaceSelectionWith:ascii];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Auto-Completion Actions

- (void)triggerWordCompletion:(id)sender {
    // Performance pref — manual completion still respects the large-file gate.
    // Window scan is bounded (500 KB ± caret) so it's not catastrophic, but the
    // user has explicitly opted out of completion for huge files.
    if (_largeFileMode &&
        ![[NSUserDefaults standardUserDefaults] boolForKey:kPrefLargeFileAllowAutoComplete]) {
        NSBeep();
        return;
    }
    // Manual Ctrl+Enter: force word completion even when auto-complete is off; min prefix = 1
    [self _showWordCompletionWithMinPrefix:1 beepOnEmpty:YES];
}

- (void)_showWordCompletionWithMinPrefix:(NSInteger)minPrefix beepOnEmpty:(BOOL)beep {
    ScintillaView *sci = _scintillaView;
    sptr_t pos       = [sci message:SCI_GETCURRENTPOS];
    sptr_t wordStart = [sci message:SCI_WORDSTARTPOSITION wParam:(uptr_t)pos lParam:1];
    NSInteger prefixLen = pos - wordStart;
    if (prefixLen < minPrefix) { if (beep) NSBeep(); [sci message:SCI_AUTOCCANCEL]; return; }

    static const NSInteger kScanWindow = 500000;
    sptr_t docLen    = [sci message:SCI_GETLENGTH];
    sptr_t scanStart = MAX(0, wordStart - kScanWindow);
    sptr_t scanEnd   = MIN(docLen, pos + kScanWindow);
    sptr_t scanLen   = scanEnd - scanStart;
    if (scanLen <= 0 || wordStart < scanStart) { if (beep) NSBeep(); return; }

    char *buf = (char *)malloc((size_t)scanLen + 1);
    if (!buf) { if (beep) NSBeep(); return; }
    Sci_TextRangeFull tr = { {(Sci_Position)scanStart, (Sci_Position)scanEnd}, buf };
    [sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&tr];
    buf[scanLen] = '\0';
    NSString *scanText = [[NSString alloc] initWithBytesNoCopy:buf
                                                        length:(NSUInteger)scanLen
                                                      encoding:NSUTF8StringEncoding
                                                  freeWhenDone:YES];
    if (!scanText) { free(buf); if (beep) NSBeep(); return; }

    NSUInteger prefixOffset = (NSUInteger)(wordStart - scanStart);
    if (prefixOffset + (NSUInteger)prefixLen > scanText.length) {
        if (beep) NSBeep(); return;
    }
    NSString *prefix = [scanText substringWithRange:NSMakeRange(prefixOffset,
                                                                (NSUInteger)prefixLen)];

    NSMutableCharacterSet *wordCS = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [wordCS addCharactersInString:@"_"];
    NSMutableSet<NSString *> *wordSet = [NSMutableSet set];
    for (NSString *word in [scanText componentsSeparatedByCharactersInSet:wordCS.invertedSet]) {
        if (word.length > (NSUInteger)prefixLen && [word hasPrefix:prefix])
            [wordSet addObject:word];
    }
    [wordSet removeObject:prefix];
    if (!wordSet.count) { if (beep) NSBeep(); return; }

    NSArray<NSString *> *sorted = [wordSet.allObjects
        sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    [sci message:SCI_AUTOCSETSEPARATOR wParam:' '];
    NSString *wordList = [sorted componentsJoinedByString:@" "];
    [sci message:SCI_AUTOCSHOW wParam:(uptr_t)prefixLen lParam:(sptr_t)wordList.UTF8String];
}

- (void)triggerFunctionParametersHint:(id)sender {
    // Show a calltip for the function name preceding the nearest open paren
    ScintillaView *sci = _scintillaView;
    sptr_t pos = [sci message:SCI_GETCURRENTPOS];
    // Scan back for the most recent '('
    sptr_t scan = pos - 1;
    while (scan >= 0 && (int)[sci message:SCI_GETCHARAT wParam:(uptr_t)scan] != '(') scan--;
    if (scan < 0) { NSBeep(); return; }
    sptr_t nameEnd   = scan;
    sptr_t nameStart = [sci message:SCI_WORDSTARTPOSITION wParam:(uptr_t)nameEnd lParam:1];
    if (nameStart >= nameEnd) { NSBeep(); return; }
    sptr_t nameLen = nameEnd - nameStart;
    char *buf = (char *)calloc((size_t)(nameLen + 1), 1);
    Sci_TextRangeFull tr = { {(Sci_Position)nameStart, (Sci_Position)nameEnd}, buf };
    [sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&tr];
    NSString *funcName = [NSString stringWithUTF8String:buf] ?: @"";
    free(buf);
    if (!funcName.length) { NSBeep(); return; }
    NSString *tip = [NSString stringWithFormat:@"%@( ... )", funcName];
    [sci message:SCI_CALLTIPSHOW wParam:(uptr_t)nameStart lParam:(sptr_t)tip.UTF8String];
}

- (void)triggerFunctionCompletion:(id)sender {
    // Show autocomplete using words already in the document (approximates function-name completion).
    // A full implementation would load per-language API files; this provides useful behaviour without them.
    [self triggerWordCompletion:sender];
}

- (void)showFunctionParametersPreviousHint:(id)sender {
    // Navigate to the previous enclosing function call and show its calltip.
    ScintillaView *sci = _scintillaView;
    if ([sci message:SCI_CALLTIPACTIVE]) [sci message:SCI_CALLTIPCANCEL];
    sptr_t pos = [sci message:SCI_GETCURRENTPOS];
    int depth = 0;
    sptr_t scan = pos - 1;
    while (scan > 0) {
        char ch = (char)[sci message:SCI_GETCHARAT wParam:(uptr_t)scan];
        if (ch == ')') { depth++; scan--; continue; }
        if (ch == '(' && depth > 0) { depth--; scan--; continue; }
        if (ch == '(') {
            // Found enclosing '(' — move cursor just inside and show calltip
            [sci message:SCI_GOTOPOS wParam:(uptr_t)(scan + 1)];
            [self triggerFunctionParametersHint:sender];
            return;
        }
        scan--;
    }
    NSBeep();
}

- (void)showFunctionParametersNextHint:(id)sender {
    // Navigate forward to the next function call '(' and show its calltip.
    ScintillaView *sci = _scintillaView;
    if ([sci message:SCI_CALLTIPACTIVE]) [sci message:SCI_CALLTIPCANCEL];
    sptr_t pos = [sci message:SCI_GETCURRENTPOS];
    sptr_t len = [sci message:SCI_GETLENGTH];
    sptr_t scan = pos;
    while (scan < len) {
        char ch = (char)[sci message:SCI_GETCHARAT wParam:(uptr_t)scan];
        if (ch == '(') {
            [sci message:SCI_GOTOPOS wParam:(uptr_t)(scan + 1)];
            [self triggerFunctionParametersHint:sender];
            return;
        }
        scan++;
    }
    NSBeep();
}

- (void)triggerPathCompletion:(id)sender {
    // Complete a filesystem path at the cursor using NSFileManager.
    ScintillaView *sci = _scintillaView;
    sptr_t pos = [sci message:SCI_GETCURRENTPOS];
    sptr_t lineNum   = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)pos];
    sptr_t lineStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)lineNum];
    sptr_t lineLen   = pos - lineStart;
    if (lineLen <= 0) { NSBeep(); return; }

    char *lineBuf = (char *)malloc((size_t)lineLen + 1);
    if (!lineBuf) { NSBeep(); return; }
    Sci_TextRangeFull tr = { {(Sci_Position)lineStart, (Sci_Position)pos}, lineBuf };
    [sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&tr];
    lineBuf[lineLen] = '\0';
    NSString *lineText = [NSString stringWithUTF8String:lineBuf] ?: @"";
    free(lineBuf);

    // Find start of path: last whitespace, quote, comma, equals, or open-paren
    NSCharacterSet *delimiters = [NSCharacterSet characterSetWithCharactersInString:@" \t\"'=,;("];
    NSRange delimRange = [lineText rangeOfCharacterFromSet:delimiters options:NSBackwardsSearch];
    NSString *pathPrefix = (delimRange.location == NSNotFound)
        ? lineText
        : [lineText substringFromIndex:delimRange.location + 1];
    if (!pathPrefix.length || pathPrefix.length > 4096) { NSBeep(); return; }

    NSString *dir, *filePrefix;
    if ([pathPrefix hasSuffix:@"/"]) {
        dir        = pathPrefix;
        filePrefix = @"";
    } else {
        dir        = [pathPrefix stringByDeletingLastPathComponent];
        filePrefix = [pathPrefix lastPathComponent];
        if (!dir.length) dir = @".";
    }

    // Expand tilde (~) — NSFileManager requires real paths, not shell shortcuts
    NSString *resolvedDir = [dir stringByExpandingTildeInPath];

    // For relative paths, resolve against the open file's directory (or home if untitled)
    if (![resolvedDir hasPrefix:@"/"]) {
        NSString *base = _filePath
            ? [_filePath stringByDeletingLastPathComponent]
            : NSHomeDirectory();
        resolvedDir = [base stringByAppendingPathComponent:resolvedDir];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *contents = [fm contentsOfDirectoryAtPath:resolvedDir error:nil];
    if (!contents.count) { NSBeep(); return; }

    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    NSString *lcPrefix = filePrefix.lowercaseString;
    for (NSString *name in contents) {
        if (filePrefix.length && ![name.lowercaseString hasPrefix:lcPrefix]) continue;
        BOOL isDir = NO;
        [fm fileExistsAtPath:[resolvedDir stringByAppendingPathComponent:name] isDirectory:&isDir];
        [matches addObject:isDir ? [name stringByAppendingString:@"/"] : name];
    }
    if (!matches.count) { NSBeep(); return; }
    [matches sortUsingSelector:@selector(caseInsensitiveCompare:)];

    // Use '\n' as separator so filenames containing spaces work correctly.
    // wParam = UTF-8 byte length of already-typed prefix (Scintilla positions are byte-based).
    [sci message:SCI_AUTOCSETSEPARATOR wParam:'\n'];
    NSString *wordList = [matches componentsJoinedByString:@"\n"];
    NSUInteger prefixBytes = [filePrefix lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    [sci message:SCI_AUTOCSHOW wParam:(uptr_t)prefixBytes lParam:(sptr_t)wordList.UTF8String];
}

- (void)finishOrSelectAutocompleteItem:(id)sender {
    ScintillaView *sci = _scintillaView;
    if ([sci message:SCI_AUTOCACTIVE])
        [sci message:SCI_AUTOCCOMPLETE];
    else if ([sci message:SCI_CALLTIPACTIVE])
        [sci message:SCI_CALLTIPCANCEL];
    else
        NSBeep();
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Cryptographic Hashes

/// Compute a hex-digest hash of `data` using the given algorithm name (MD5, SHA-1, SHA-256, SHA-512).
+ (nullable NSString *)hexHashForAlgorithm:(NSString *)algo data:(NSData *)data {
    const void *bytes = data.bytes;
    CC_LONG len = (CC_LONG)data.length;
    if ([algo isEqualToString:@"MD5"]) {
        unsigned char d[CC_MD5_DIGEST_LENGTH];
        CC_MD5(bytes, len, d);
        NSMutableString *s = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
        for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", d[i]];
        return s;
    } else if ([algo isEqualToString:@"SHA-1"]) {
        unsigned char d[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1(bytes, len, d);
        NSMutableString *s = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
        for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", d[i]];
        return s;
    } else if ([algo isEqualToString:@"SHA-256"]) {
        unsigned char d[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(bytes, len, d);
        NSMutableString *s = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", d[i]];
        return s;
    } else if ([algo isEqualToString:@"SHA-512"]) {
        unsigned char d[CC_SHA512_DIGEST_LENGTH];
        CC_SHA512(bytes, len, d);
        NSMutableString *s = [NSMutableString stringWithCapacity:CC_SHA512_DIGEST_LENGTH * 2];
        for (int i = 0; i < CC_SHA512_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", d[i]];
        return s;
    }
    return nil;
}

/// Insert hash of the selected text (or whole document if no selection) at the cursor.
- (void)generateHashForAlgorithm:(NSString *)algo {
    NSString *text = [self selectedText];
    BOOL hadSelection = (text != nil);
    if (!text) {
        // Hash entire document
        sptr_t docLen = [_scintillaView message:SCI_GETLENGTH];
        char *buf = (char *)calloc((size_t)docLen + 1, 1);
        [_scintillaView message:SCI_GETTEXT wParam:(uptr_t)(docLen + 1) lParam:(sptr_t)buf];
        text = [NSString stringWithUTF8String:buf] ?: @"";
        free(buf);
    }
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSString *hash = [EditorView hexHashForAlgorithm:algo data:data];
    if (!hash) return;
    if (hadSelection)
        [self replaceSelectionWith:hash];
    else
        [_scintillaView message:SCI_APPENDTEXT
                         wParam:(uptr_t)strlen(hash.UTF8String)
                         lParam:(sptr_t)hash.UTF8String];
}

/// Copy hash of the selected text (or whole document) to the clipboard.
- (void)copyHashForAlgorithm:(NSString *)algo {
    NSString *text = [self selectedText];
    if (!text) {
        sptr_t docLen = [_scintillaView message:SCI_GETLENGTH];
        char *buf = (char *)calloc((size_t)docLen + 1, 1);
        [_scintillaView message:SCI_GETTEXT wParam:(uptr_t)(docLen + 1) lParam:(sptr_t)buf];
        text = [NSString stringWithUTF8String:buf] ?: @"";
        free(buf);
    }
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSString *hash = [EditorView hexHashForAlgorithm:algo data:data];
    if (!hash) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:hash forType:NSPasteboardTypeString];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Column Editor

- (NSInteger)columnEditorLineCount {
    ScintillaView *sci = _scintillaView;
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];
    sptr_t line1 = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selStart];
    sptr_t line2 = (selStart == selEnd)
        ? [sci message:SCI_GETLINECOUNT] - 1
        : [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selEnd];
    return (NSInteger)MAX(1, line2 - line1 + 1);
}

- (void)columnInsertStrings:(NSArray<NSString *> *)strings {
    if (!strings.count) return;
    ScintillaView *sci = _scintillaView;
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];
    sptr_t line1    = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selStart];
    sptr_t line2    = (selStart == selEnd)
        ? [sci message:SCI_GETLINECOUNT] - 1
        : [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selEnd];
    sptr_t col      = [sci message:SCI_GETCOLUMN wParam:(uptr_t)selStart];

    [sci message:SCI_BEGINUNDOACTION];
    for (sptr_t ln = line2; ln >= line1; ln--) {
        NSInteger strIdx = (NSInteger)(ln - line1);
        if (strIdx >= (NSInteger)strings.count) strIdx = (NSInteger)strings.count - 1;
        NSString *text   = strings[strIdx];
        const char *utf8 = text.UTF8String;
        if (!utf8) continue;
        sptr_t pos       = [sci message:SCI_FINDCOLUMN    wParam:(uptr_t)ln lParam:col];
        sptr_t lineEnd   = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)ln];
        sptr_t actualCol = [sci message:SCI_GETCOLUMN wParam:(uptr_t)pos];
        if (actualCol < col && pos >= lineEnd) {
            NSMutableString *pad = [NSMutableString string];
            for (sptr_t sp = actualCol; sp < col; sp++) [pad appendString:@" "];
            [sci message:SCI_INSERTTEXT wParam:(uptr_t)pos lParam:(sptr_t)pad.UTF8String];
            pos += (sptr_t)pad.length;
        }
        [sci message:SCI_INSERTTEXT wParam:(uptr_t)pos lParam:(sptr_t)utf8];
    }
    [sci message:SCI_ENDUNDOACTION];
}

/// Column insert: insert `text` at the caret column on every line of the current
/// rectangular (or multi-line stream) selection (or to end of document if nothing selected).
- (void)columnInsertText:(NSString *)text {
    if (!text.length) return;
    ScintillaView *sci = _scintillaView;
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];
    sptr_t line1    = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selStart];
    // When nothing is selected, extend to end of document
    sptr_t line2    = (selStart == selEnd)
        ? [sci message:SCI_GETLINECOUNT] - 1
        : [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selEnd];
    // Column to insert at = column of the anchor (start of selection)
    sptr_t col = [sci message:SCI_GETCOLUMN wParam:(uptr_t)selStart];

    const char *utf8 = text.UTF8String;
    [sci message:SCI_BEGINUNDOACTION];
    // Insert from bottom to top so earlier positions aren't shifted
    for (sptr_t ln = line2; ln >= line1; ln--) {
        // SCI_FINDCOLUMN returns the closest position for this column (handles tabs)
        sptr_t pos = [sci message:SCI_FINDCOLUMN wParam:(uptr_t)ln lParam:col];
        sptr_t lineEnd = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)ln];
        // Pad with spaces if line is shorter than the target column
        sptr_t actualCol = [sci message:SCI_GETCOLUMN wParam:(uptr_t)pos];
        if (actualCol < col && pos >= lineEnd) {
            NSMutableString *pad = [NSMutableString string];
            for (sptr_t sp = actualCol; sp < col; sp++) [pad appendString:@" "];
            [sci message:SCI_INSERTTEXT wParam:(uptr_t)pos lParam:(sptr_t)pad.UTF8String];
            pos += (sptr_t)pad.length;
        }
        [sci message:SCI_INSERTTEXT wParam:(uptr_t)pos lParam:(sptr_t)utf8];
    }
    [sci message:SCI_ENDUNDOACTION];
}

- (void)columnInsertNumbersFrom:(long long)startVal step:(long long)step format:(NSString *)fmt {
    ScintillaView *sci = _scintillaView;
    sptr_t selStart = [sci message:SCI_GETSELECTIONSTART];
    sptr_t selEnd   = [sci message:SCI_GETSELECTIONEND];
    sptr_t line1    = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selStart];
    sptr_t line2    = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)selEnd];
    sptr_t col      = [sci message:SCI_GETCOLUMN wParam:(uptr_t)selStart];
    NSString *fmtStr = fmt.length ? fmt : @"%lld";

    [sci message:SCI_BEGINUNDOACTION];
    long long val = startVal + step * (line2 - line1); // insert bottom-up
    for (sptr_t ln = line2; ln >= line1; ln--, val -= step) {
        NSString *numStr = [NSString stringWithFormat:fmtStr, val];
        const char *utf8 = numStr.UTF8String;
        sptr_t pos     = [sci message:SCI_FINDCOLUMN    wParam:(uptr_t)ln lParam:col];
        sptr_t lineEnd = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)ln];
        sptr_t actualCol = [sci message:SCI_GETCOLUMN wParam:(uptr_t)pos];
        if (actualCol < col && pos >= lineEnd) {
            NSMutableString *pad = [NSMutableString string];
            for (sptr_t sp = actualCol; sp < col; sp++) [pad appendString:@" "];
            [sci message:SCI_INSERTTEXT wParam:(uptr_t)pos lParam:(sptr_t)pad.UTF8String];
            pos += (sptr_t)pad.length;
        }
        [sci message:SCI_INSERTTEXT wParam:(uptr_t)pos lParam:(sptr_t)utf8];
    }
    [sci message:SCI_ENDUNDOACTION];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Mark Text (styles 1-5)

- (void)markStyle:(NSInteger)style allOccurrencesOf:(NSString *)text matchCase:(BOOL)mc wholeWord:(BOOL)ww {
    if (style < 1 || style > 5 || !text.length) return;
    ScintillaView *sci = _scintillaView;
    int ind = kMarkInds[style - 1];
    sptr_t docLen = [sci message:SCI_GETLENGTH];

    [sci message:SCI_SETINDICATORCURRENT wParam:(uptr_t)ind];
    [sci message:SCI_INDICATORCLEARRANGE wParam:0 lParam:docLen];

    const char *needle = text.UTF8String;
    if (!needle || !*needle) return;
    int flags = 0;
    if (mc) flags |= SCFIND_MATCHCASE;
    if (ww) flags |= SCFIND_WHOLEWORD;
    [sci message:SCI_SETSEARCHFLAGS wParam:(uptr_t)flags];

    sptr_t pos = 0;
    while (pos < docLen) {
        [sci message:SCI_SETTARGETRANGE wParam:(uptr_t)pos lParam:docLen];
        sptr_t found = [sci message:SCI_SEARCHINTARGET wParam:strlen(needle) lParam:(sptr_t)needle];
        if (found < 0) break;
        sptr_t end = [sci message:SCI_GETTARGETEND];
        [sci message:SCI_INDICATORFILLRANGE wParam:(uptr_t)found lParam:end - found];
        pos = end > found ? end : found + 1;
    }
}

- (void)markStyleSelection:(NSInteger)style {
    if (style < 1 || style > 5) return;
    ScintillaView *sci = _scintillaView;
    sptr_t sel0 = [sci message:SCI_GETSELECTIONSTART];
    sptr_t sel1 = [sci message:SCI_GETSELECTIONEND];
    if (sel0 == sel1) return;
    [sci message:SCI_SETINDICATORCURRENT wParam:(uptr_t)kMarkInds[style - 1]];
    [sci message:SCI_INDICATORFILLRANGE  wParam:(uptr_t)sel0 lParam:sel1 - sel0];
}

- (void)clearMarkStyle:(NSInteger)style {
    if (style < 1 || style > 5) return;
    ScintillaView *sci = _scintillaView;
    [sci message:SCI_SETINDICATORCURRENT wParam:(uptr_t)kMarkInds[style - 1]];
    [sci message:SCI_INDICATORCLEARRANGE wParam:0 lParam:[sci message:SCI_GETLENGTH]];
}

- (void)clearAllMarkStyles {
    for (NSInteger i = 1; i <= 5; i++) [self clearMarkStyle:i];
}

/// Find the next indicator range start for any of the 5 mark styles, searching forward from pos.
/// Returns -1 if none found.
- (sptr_t)_findNextMarkFrom:(sptr_t)from limit:(sptr_t)limit {
    ScintillaView *sci = _scintillaView;
    sptr_t best = -1;
    for (int i = 0; i < 5; i++) {
        int ind = kMarkInds[i];
        [sci message:SCI_SETINDICATORCURRENT wParam:(uptr_t)ind];
        sptr_t pos = from;
        while (pos < limit) {
            sptr_t val = [sci message:SCI_INDICATORVALUEAT wParam:(uptr_t)ind lParam:pos];
            if (val != 0) {
                if (best < 0 || pos < best) best = pos;
                break;
            }
            sptr_t end = [sci message:SCI_INDICATOREND wParam:(uptr_t)ind lParam:pos];
            if (end <= pos) break;
            pos = end;
        }
    }
    return best;
}

/// Find the previous indicator range for any of the 5 mark styles, searching backward from pos.
/// Returns -1 if none found.
- (sptr_t)_findPrevMarkFrom:(sptr_t)from {
    ScintillaView *sci = _scintillaView;
    sptr_t best = -1;
    for (int i = 0; i < 5; i++) {
        int ind = kMarkInds[i];
        [sci message:SCI_SETINDICATORCURRENT wParam:(uptr_t)ind];
        sptr_t pos = from;
        while (pos > 0) {
            pos--;
            sptr_t val = [sci message:SCI_INDICATORVALUEAT wParam:(uptr_t)ind lParam:pos];
            if (val != 0) {
                // Found — get the start of this indicator range
                sptr_t start = [sci message:SCI_INDICATORSTART wParam:(uptr_t)ind lParam:pos];
                if (best < 0 || start > best) best = start;
                break;
            }
            sptr_t start = [sci message:SCI_INDICATORSTART wParam:(uptr_t)ind lParam:pos];
            if (start <= 0) break;
            pos = start;
        }
    }
    return best;
}

- (void)jumpToNextMark:(NSInteger)dir {
    ScintillaView *sci = _scintillaView;
    sptr_t caretPos = [sci message:SCI_GETCURRENTPOS];
    sptr_t docLen   = [sci message:SCI_GETLENGTH];
    sptr_t best = -1;

    if (dir > 0) {
        // If caret is inside a marked range, skip past its end first
        sptr_t searchFrom = caretPos + 1;
        for (int i = 0; i < 5; i++) {
            int ind = kMarkInds[i];
            if ([sci message:SCI_INDICATORVALUEAT wParam:(uptr_t)ind lParam:caretPos]) {
                sptr_t end = [sci message:SCI_INDICATOREND wParam:(uptr_t)ind lParam:caretPos];
                if (end > searchFrom) searchFrom = end;
            }
        }
        best = [self _findNextMarkFrom:searchFrom limit:docLen];
        if (best < 0) // wrap
            best = [self _findNextMarkFrom:0 limit:caretPos];
    } else {
        // If caret is inside a marked range, skip before its start first
        sptr_t searchFrom = caretPos;
        for (int i = 0; i < 5; i++) {
            int ind = kMarkInds[i];
            if ([sci message:SCI_INDICATORVALUEAT wParam:(uptr_t)ind lParam:caretPos]) {
                sptr_t start = [sci message:SCI_INDICATORSTART wParam:(uptr_t)ind lParam:caretPos];
                if (start >= 0 && start < searchFrom) searchFrom = start;
            }
        }
        best = [self _findPrevMarkFrom:searchFrom];
        if (best < 0) // wrap
            best = [self _findPrevMarkFrom:docLen];
    }
    if (best >= 0) {
        [sci message:SCI_GOTOPOS wParam:(uptr_t)best];
        [sci message:SCI_SCROLLCARET];
    }
}

- (void)copyTextWithMarkStyle:(NSInteger)style {
    if (style < 1 || style > 5) return;
    ScintillaView *sci = _scintillaView;
    int ind = kMarkInds[style - 1];
    sptr_t docLen = [sci message:SCI_GETLENGTH];

    NSMutableString *result = [NSMutableString string];
    sptr_t pos = 0;
    while (pos < docLen) {
        sptr_t val = [sci message:SCI_INDICATORVALUEAT wParam:(uptr_t)ind lParam:pos];
        if (val == 0) {
            // Not in an indicator range — skip to end of this non-indicator run
            sptr_t end = [sci message:SCI_INDICATOREND wParam:(uptr_t)ind lParam:pos];
            if (end <= pos) break;
            pos = end;
            continue;
        }
        // In an indicator range — get the end
        sptr_t end = [sci message:SCI_INDICATOREND wParam:(uptr_t)ind lParam:pos];
        if (end <= pos) break;

        sptr_t len = end - pos;
        char *buf = (char *)calloc((size_t)len + 1, 1);
        struct Sci_TextRangeFull tr = {};
        tr.chrg.cpMin = pos;
        tr.chrg.cpMax = end;
        tr.lpstrText = buf;
        [sci message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&tr];
        NSString *chunk = [NSString stringWithUTF8String:buf];
        free(buf);
        if (chunk) {
            if (result.length) [result appendString:@"\n"];
            [result appendString:chunk];
        }
        pos = end;
    }
    if (result.length) {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:result forType:NSPasteboardTypeString];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Paste to Bookmarked Lines

- (void)pasteToBookmarkedLines:(id)sender {
    NSString *clipText = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
    if (!clipText) return;
    ScintillaView *sci = _scintillaView;
    sptr_t lineCount = [sci message:SCI_GETLINECOUNT];

    NSMutableArray<NSNumber *> *lines = [NSMutableArray array];
    for (sptr_t ln = 0; ln < lineCount; ln++) {
        if ([sci message:SCI_MARKERGET wParam:(uptr_t)ln] & (1 << kBookmarkMarker))
            [lines addObject:@(ln)];
    }
    if (!lines.count) return;

    const char *repl = clipText.UTF8String;
    NSUInteger replLen = strlen(repl);
    [sci message:SCI_BEGINUNDOACTION];
    // Process from end to preserve earlier line positions.
    for (NSInteger i = (NSInteger)lines.count - 1; i >= 0; i--) {
        sptr_t ln        = (sptr_t)[lines[i] integerValue];
        sptr_t lineStart = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)ln];
        sptr_t lineEnd   = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)ln];
        [sci message:SCI_SETTARGETRANGE wParam:(uptr_t)lineStart lParam:lineEnd];
        [sci message:SCI_REPLACETARGET  wParam:(uptr_t)replLen lParam:(sptr_t)repl];
    }
    [sci message:SCI_ENDUNDOACTION];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - View Symbol Toggles

- (void)toggleWrapSymbol:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t flags = [sci message:SCI_GETWRAPVISUALFLAGS];
    [sci message:SCI_SETWRAPVISUALFLAGS wParam:(uptr_t)(flags ? SC_WRAPVISUALFLAG_NONE : SC_WRAPVISUALFLAG_END)];
}

- (void)toggleHideLineMarks:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t w = [sci message:SCI_GETMARGINWIDTHN wParam:1];
    [sci message:SCI_SETMARGINWIDTHN wParam:1 lParam:w > 0 ? 0 : 16];
}

- (void)hideLinesInSelection:(id)sender {
    ScintillaView *sci = _scintillaView;
    sptr_t startLine = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)[sci message:SCI_GETSELECTIONSTART]];
    sptr_t endLine   = [sci message:SCI_LINEFROMPOSITION wParam:(uptr_t)[sci message:SCI_GETSELECTIONEND]];
    sptr_t lineCount = [sci message:SCI_GETLINECOUNT];

    // Can't hide the very first or very last line (markers need a visible line outside)
    if (startLine <= 0) startLine = 1;
    if (endLine >= lineCount - 1) endLine = lineCount - 2;
    if (startLine > endLine) return;

    // Place BEGIN marker on the line BEFORE the hidden range
    sptr_t beginMarkerLine = startLine - 1;
    // Place END marker on the line AFTER the hidden range
    sptr_t endMarkerLine = endLine + 1;

    // Remove any conflicting existing markers in or near the range
    for (sptr_t i = beginMarkerLine; i <= endMarkerLine; i++) {
        [sci message:SCI_MARKERDELETE wParam:(uptr_t)i lParam:kHideLinesBeginMarker];
        [sci message:SCI_MARKERDELETE wParam:(uptr_t)i lParam:kHideLinesEndMarker];
    }

    // Add the boundary markers
    [sci message:SCI_MARKERADD wParam:(uptr_t)beginMarkerLine lParam:kHideLinesBeginMarker];
    [sci message:SCI_MARKERADD wParam:(uptr_t)endMarkerLine   lParam:kHideLinesEndMarker];

    // Hide the lines between the markers
    [sci message:SCI_HIDELINES wParam:(uptr_t)startLine lParam:endLine];
}

/// Unhide lines associated with a hide-lines marker at the given line.
/// Returns YES if a hide marker was found and lines were unhidden.
- (BOOL)_unhideMarkerAtLine:(sptr_t)line {
    ScintillaView *sci = _scintillaView;
    sptr_t mask = [sci message:SCI_MARKERGET wParam:(uptr_t)line];
    BOOL hasBegin = (mask & (1 << kHideLinesBeginMarker)) != 0;
    BOOL hasEnd   = (mask & (1 << kHideLinesEndMarker)) != 0;

    if (!hasBegin && !hasEnd) return NO;

    sptr_t beginLine = -1, endLine = -1;

    if (hasBegin) {
        beginLine = line;
        // Search forward for the matching END marker
        sptr_t lineCount = [sci message:SCI_GETLINECOUNT];
        for (sptr_t i = line + 1; i < lineCount; i++) {
            sptr_t m = [sci message:SCI_MARKERGET wParam:(uptr_t)i];
            if (m & (1 << kHideLinesEndMarker)) { endLine = i; break; }
        }
    } else {
        endLine = line;
        // Search backward for the matching BEGIN marker
        for (sptr_t i = line - 1; i >= 0; i--) {
            sptr_t m = [sci message:SCI_MARKERGET wParam:(uptr_t)i];
            if (m & (1 << kHideLinesBeginMarker)) { beginLine = i; break; }
        }
    }

    if (beginLine < 0 || endLine < 0 || endLine <= beginLine) return NO;

    // Show the hidden lines (between markers)
    [sci message:SCI_SHOWLINES wParam:(uptr_t)(beginLine + 1) lParam:(endLine - 1)];

    // Remove the markers
    [sci message:SCI_MARKERDELETE wParam:(uptr_t)beginLine lParam:kHideLinesBeginMarker];
    [sci message:SCI_MARKERDELETE wParam:(uptr_t)endLine   lParam:kHideLinesEndMarker];

    return YES;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Base64 URL-Safe + Padding Variants

- (void)base64EncodeWithPadding:(id)sender {
    // Standard base64 already includes padding; identical to base64Encode:.
    [self base64Encode:sender];
}

- (void)base64DecodeStrict:(id)sender {
    NSString *sel = [self selectedText]; if (!sel) return;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:sel options:0];
    if (!data) { NSBeep(); return; }
    NSString *decoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                     ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!decoded) { NSBeep(); return; }
    [self replaceSelectionWith:decoded];
}

- (void)base64URLSafeEncode:(id)sender {
    NSString *sel = [self selectedText]; if (!sel) return;
    NSData *data = [sel dataUsingEncoding:NSUTF8StringEncoding]; if (!data) return;
    NSString *enc = [data base64EncodedStringWithOptions:0];
    enc = [enc stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    enc = [enc stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    enc = [enc stringByReplacingOccurrencesOfString:@"=" withString:@""];
    [self replaceSelectionWith:enc];
}

- (void)base64URLSafeDecode:(id)sender {
    NSString *sel = [self selectedText]; if (!sel) return;
    NSString *b64 = [sel stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    b64 = [b64 stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    NSUInteger pad = (4 - b64.length % 4) % 4;
    if (pad) b64 = [b64 stringByPaddingToLength:b64.length + pad withString:@"=" startingAtIndex:0];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (!data) { NSBeep(); return; }
    NSString *decoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!decoded) { NSBeep(); return; }
    [self replaceSelectionWith:decoded];
}

#pragma mark - Spell Check

- (BOOL)spellCheckEnabled { return _spellCheckEnabled; }

- (void)setSpellCheckEnabled:(BOOL)enabled {
    _spellCheckEnabled = enabled;
    if (enabled) [self runSpellCheck];
    else         [self clearSpellCheck];
}

- (void)clearSpellCheck {
    [_spellTimer invalidate];
    _spellTimer = nil;
    ScintillaView *sci = _scintillaView;
    intptr_t len = [sci message:SCI_GETLENGTH];
    [sci message:SCI_SETINDICATORCURRENT wParam:kSpellIndicator];
    [sci message:SCI_INDICATORCLEARRANGE wParam:0 lParam:len];
}

- (void)runSpellCheck {
    if (!_spellCheckEnabled) return;
    ScintillaView *sci = _scintillaView;
    intptr_t docLen = [sci message:SCI_GETLENGTH];
    char *buf = (char *)calloc((size_t)docLen + 1, 1);
    if (!buf) return;
    [sci message:SCI_GETTEXT wParam:(uptr_t)(docLen + 1) lParam:(sptr_t)buf];
    NSString *text = [NSString stringWithUTF8String:buf] ?: @"";
    free(buf);

    // Clear existing spell marks
    [sci message:SCI_SETINDICATORCURRENT wParam:kSpellIndicator];
    [sci message:SCI_INDICATORCLEARRANGE wParam:0 lParam:docLen];

    if (!text.length) return;

    NSSpellChecker *checker = [NSSpellChecker sharedSpellChecker];
    NSArray<NSTextCheckingResult *> *results =
        [checker checkString:text
                       range:NSMakeRange(0, text.length)
                       types:NSTextCheckingTypeSpelling
                     options:nil
     inSpellDocumentWithTag:_spellTag
                 orthography:nil
                   wordCount:nil];

    for (NSTextCheckingResult *r in results) {
        // Convert NSString char range to UTF-8 byte range for Scintilla
        NSRange charRange = r.range;
        NSRange utf8BeforeRange = NSMakeRange(0, charRange.location);
        NSString *before = [text substringWithRange:utf8BeforeRange];
        NSString *word   = [text substringWithRange:charRange];
        NSUInteger byteStart = [before lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSUInteger byteLen   = [word   lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (byteLen == 0) continue;
        [sci message:SCI_INDICATORFILLRANGE wParam:byteStart lParam:(sptr_t)byteLen];
    }
}

- (void)_spellTimerFired:(NSTimer *)timer {
    _spellTimer = nil;
    [self runSpellCheck];
}

- (void)_scheduleSpellCheck {
    if (!_spellCheckEnabled) return;
    [_spellTimer invalidate];
    _spellTimer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                   target:self
                                                 selector:@selector(_spellTimerFired:)
                                                 userInfo:nil
                                                  repeats:NO];
}

#pragma mark - Git Gutter

- (void)clearGitDiffMarkers {
    ScintillaView *sci = _scintillaView;
    [sci message:SCI_MARKERDELETEALL wParam:(uptr_t)kGitMarkerAdded];
    [sci message:SCI_MARKERDELETEALL wParam:(uptr_t)kGitMarkerModified];
    [sci message:SCI_MARKERDELETEALL wParam:(uptr_t)kGitMarkerDeleted];
}

// ── Git diff line highlights (pink) ──────────────────────────────────────────

- (void)clearGitDiffHighlights {
    ScintillaView *sci = _scintillaView;
    intptr_t len = [sci message:SCI_GETLENGTH];
    [sci message:SCI_SETINDICATORCURRENT wParam:kGitDiffIndicator];
    [sci message:SCI_INDICATORCLEARRANGE wParam:0 lParam:len];
}

- (void)applyGitDiffHighlights {
    [self clearGitDiffHighlights];
    if (!_filePath) return;
    NSString *fp = [_filePath copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *root = [GitHelper gitRootForPath:fp];
        if (!root) return;
        NSString *diff = [GitHelper diffForFile:fp root:root];
        if (!diff.length) return;

        // Collect all new-file line numbers that have a '+' line (1-based)
        NSMutableArray<NSNumber *> *changedLines = [NSMutableArray array];
        NSArray<NSString *> *lines = [diff componentsSeparatedByString:@"\n"];
        NSInteger newLine = 0;
        for (NSString *line in lines) {
            if ([line hasPrefix:@"@@"]) {
                NSRegularExpression *re = [NSRegularExpression
                    regularExpressionWithPattern:@"\\+([0-9]+)" options:0 error:nil];
                NSTextCheckingResult *m = [re firstMatchInString:line options:0
                                                           range:NSMakeRange(0, line.length)];
                if (m) newLine = [[line substringWithRange:[m rangeAtIndex:1]] integerValue] - 1;
            } else if ([line hasPrefix:@"+++"]) {
                // skip file header
            } else if ([line hasPrefix:@"+"]) {
                newLine++;
                [changedLines addObject:@(newLine - 1)]; // convert to 0-based
            } else if (![line hasPrefix:@"-"] && ![line hasPrefix:@"\\"]) {
                if (newLine > 0) newLine++;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self clearGitDiffHighlights];
            ScintillaView *sci = self->_scintillaView;
            [sci message:SCI_SETINDICATORCURRENT wParam:kGitDiffIndicator];
            for (NSNumber *n in changedLines) {
                NSInteger line0 = n.integerValue;
                if (line0 < 0) continue;
                intptr_t start = [sci message:SCI_POSITIONFROMLINE wParam:(uptr_t)line0];
                intptr_t end   = [sci message:SCI_GETLINEENDPOSITION wParam:(uptr_t)line0];
                if (end > start)
                    [sci message:SCI_INDICATORFILLRANGE wParam:(uptr_t)start lParam:end - start];
            }
        });
    });
}

- (void)updateGitDiffMarkers {
    if (!_filePath) { [self clearGitDiffMarkers]; return; }
    NSString *fp = [_filePath copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *root = [GitHelper gitRootForPath:fp];
        if (!root) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf clearGitDiffMarkers]; });
            return;
        }
        NSString *diff = [GitHelper diffForFile:fp root:root];
        // Parse hunk headers: @@ -old,count +new,count @@
        // Build sets of new-file line numbers (1-based) for each marker type.
        NSMutableSet<NSNumber *> *addedLines    = [NSMutableSet set];
        NSMutableSet<NSNumber *> *modifiedLines = [NSMutableSet set];
        NSMutableSet<NSNumber *> *deletedLines  = [NSMutableSet set];
        if (diff.length) {
            NSArray<NSString *> *lines = [diff componentsSeparatedByString:@"\n"];
            NSInteger newLine = 0; // tracks current new-file line number
            NSInteger hunkNewStart = 0;
            NSInteger hunkOldStart = 0;
            for (NSString *line in lines) {
                if ([line hasPrefix:@"@@"]) {
                    // @@ -old_start,old_count +new_start,new_count @@
                    NSRegularExpression *re = [NSRegularExpression
                        regularExpressionWithPattern:@"\\+([0-9]+)"
                                             options:0 error:nil];
                    NSRegularExpression *reOld = [NSRegularExpression
                        regularExpressionWithPattern:@"-([0-9]+)"
                                             options:0 error:nil];
                    NSTextCheckingResult *mNew = [re firstMatchInString:line options:0
                                                                  range:NSMakeRange(0, line.length)];
                    NSTextCheckingResult *mOld = [reOld firstMatchInString:line options:0
                                                                     range:NSMakeRange(0, line.length)];
                    if (mNew) hunkNewStart = [[line substringWithRange:[mNew rangeAtIndex:1]] integerValue];
                    if (mOld) hunkOldStart = [[line substringWithRange:[mOld rangeAtIndex:1]] integerValue];
                    newLine = hunkNewStart - 1; // will be incremented on first context/add line
                    (void)hunkOldStart;
                } else if ([line hasPrefix:@"+"]) {
                    newLine++;
                    [addedLines addObject:@(newLine)];
                } else if ([line hasPrefix:@"-"]) {
                    // Deleted line: mark the line before it in the new file
                    NSInteger markLine = MAX(1, newLine);
                    [deletedLines addObject:@(markLine)];
                } else if (![line hasPrefix:@"\\"]) {
                    // Context line (not "\ No newline at end of file")
                    newLine++;
                }
            }
            // Lines that appear in both added and deleted sets are modifications
            NSMutableSet<NSNumber *> *both = [addedLines mutableCopy];
            [both intersectSet:deletedLines];
            for (NSNumber *n in both) {
                [addedLines removeObject:n];
                [deletedLines removeObject:n];
                [modifiedLines addObject:n];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self clearGitDiffMarkers];
            ScintillaView *sci = self->_scintillaView;
            for (NSNumber *n in addedLines) {
                NSInteger line0 = n.integerValue - 1; // Scintilla is 0-based
                [sci message:SCI_MARKERADD wParam:(uptr_t)line0 lParam:kGitMarkerAdded];
            }
            for (NSNumber *n in modifiedLines) {
                NSInteger line0 = n.integerValue - 1;
                [sci message:SCI_MARKERADD wParam:(uptr_t)line0 lParam:kGitMarkerModified];
            }
            for (NSNumber *n in deletedLines) {
                NSInteger line0 = MAX(0, n.integerValue - 1);
                [sci message:SCI_MARKERADD wParam:(uptr_t)line0 lParam:kGitMarkerDeleted];
            }
        });
    });
}

@end
