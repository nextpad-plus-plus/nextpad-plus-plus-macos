#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"

NS_ASSUME_NONNULL_BEGIN

/// Posted when the cursor moves. Object is the EditorView.
extern NSNotificationName const EditorViewCursorDidMoveNotification;

/// Posted when a Scintilla editor gains keyboard focus (SCN_FOCUSIN).
extern NSNotificationName const EditorViewDidGainFocusNotification;

/// Posted when an editor's contents are written to disk via saveFileToPath:.
/// Object is the EditorView. MainWindowController listens and conditionally
/// refreshes the git diff gutter only when the GitPanel is open — keeps git
/// invocations gated to the panel-visible state (issue #76).
extern NSNotificationName const EditorViewDidSaveNotification;

/// Posted when an editor's zoom level changes (SCN_ZOOM). Object is the EditorView.
extern NSNotificationName const EditorViewZoomDidChangeNotification;

/// Wraps ScintillaView and provides Nextpad++-style editor functionality.
@interface EditorView : NSView <ScintillaNotificationProtocol>

@property (nonatomic, readonly) ScintillaView *scintillaView;
@property (nonatomic, copy, nullable) NSString *filePath;

/// Unique 1-based index for untitled tabs — mirrors NPP's per-buffer ID.
@property (nonatomic, readonly) NSInteger untitledIndex;

/// Custom display name for an UNTITLED tab, set via Rename (issue #177). When
/// non-nil it overrides the "new N" name; ignored once the buffer has a filePath.
@property (nonatomic, copy, nullable) NSString *customTabName;

/// Path to the auto-backup copy in ~/Library/Application Support/Nextpad++/backup/ (nil if never backed up).
@property (nonatomic, copy, nullable) NSString *backupFilePath;

/// Restore the untitled index from a saved session (keeps tab name consistent).
- (void)restoreUntitledIndex:(NSInteger)index;

/// Force the modified flag to YES (used after session restore from backup).
- (void)markAsModified;

/// Write current content to dir using NPP-style timestamped filename.
/// Updates backupFilePath on success. Returns the backup path or nil.
- (nullable NSString *)saveBackupToDirectory:(NSString *)dir;

/// `dir`/`filename`, made unique by appending "-2", "-3", … while a file already
/// exists there. Backup names are "<display name>@<timestamp>" at one-second
/// resolution, and neither part is unique across buffers: two tabs for
/// same-named files in different directories, or an untitled "new 1" in each
/// window, produce the same name when first backed up in the same second. Every
/// caller that materialises a backup file must claim its name through here,
/// because an unsaved buffer's backup is the only copy of its text.
+ (NSString *)uniqueBackupPathInDirectory:(NSString *)dir filename:(NSString *)filename;
@property (nonatomic, readonly) BOOL isModified;
@property (nonatomic, readonly) NSString *displayName;

// Cursor / document info (updated on every SCN_UPDATEUI)
@property (nonatomic, readonly) NSInteger cursorLine;    // 1-based
@property (nonatomic, readonly) NSInteger cursorColumn;  // 1-based
@property (nonatomic, readonly) NSInteger lineCount;
@property (nonatomic, readonly) NSString *encodingName;  // "UTF-8", "UTF-8 BOM", etc.
@property (nonatomic, readonly) NSString *eolName;       // "LF" / "CR" / "CRLF"
@property (nonatomic, readonly) BOOL hasBOM;             // YES if file has/should have BOM

// Current language name (e.g. "python"). Empty string = plain text.
@property (nonatomic, copy) NSString *currentLanguage;

// YES when in overwrite (OVR) mode, NO for normal insert (INS) mode.
@property (nonatomic, readonly) BOOL isOverwriteMode;

/// Live zoom points from Scintilla (SCI_GETZOOM). 0 is default 100%.
@property (nonatomic, readonly) NSInteger zoomLevel;

/// Live zoom percentage (e.g. 100 for 100%, 110 for 110%, etc.).
@property (nonatomic, readonly) NSInteger zoomPercentage;

// Word wrap — stored per-editor tab.
@property (nonatomic) BOOL wordWrapEnabled;

// YES while macro recording is active.
@property (nonatomic, readonly) BOOL isRecordingMacro;

// YES when monitoring mode (tail -f) is active — file changes silently auto-reload.
@property (nonatomic) BOOL monitoringMode;

// YES when the file was opened in large-file (binary) mode — no backup on quit.
@property (nonatomic, readonly) BOOL largeFileMode;

/// Must be called when a tab is permanently closed (not evicted to another split).
/// Unregisters the file presenter so the EditorView can be deallocated.
- (void)prepareForClose;

/// Copy all text content from another editor (for untitled tab cloning).
- (void)loadContentFromEditor:(EditorView *)source;

/// Share the Scintilla document from another editor (for clone-to-view).
/// Both views point to the same document — edits in one appear in the other.
- (void)shareDocumentFrom:(EditorView *)source;

/// The clone sibling (the other view sharing the same Scintilla document), or nil.
@property (nonatomic, weak, nullable) EditorView *cloneSibling;

/// Open a file from disk into this editor.
- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error;

/// Save current content to filePath. Returns YES on success.
- (BOOL)saveError:(NSError **)error;

/// Save to a specific path.
- (BOOL)saveToPath:(NSString *)path error:(NSError **)error;

/// Write a snapshot of the current content to a path WITHOUT changing which
/// file this editor is bound to ("Save a Copy As"). Returns YES on success.
- (BOOL)writeCopyToPath:(NSString *)path error:(NSError **)error;

/// Set the syntax language by name (e.g. "cpp", "python"). Pass "" for plain text.
- (void)setLanguage:(NSString *)languageName;

/// Change the save encoding without reloading content; marks buffer as modified.
- (void)setFileEncoding:(NSStringEncoding)enc hasBOM:(BOOL)bom;

/// Reload the file from disk, re-interpreting bytes with the given encoding.
/// For files on disk only. Returns NO if reload fails.
- (BOOL)reloadWithEncoding:(NSStringEncoding)enc hasBOM:(BOOL)bom error:(NSError **)error;

/// Re-encode the current in-memory content to a new encoding (Convert To).
/// Does NOT save to disk — user must save manually.
- (void)convertContentToEncoding:(NSStringEncoding)enc hasBOM:(BOOL)bom;

/// Apply current theme colors (fg/bg/token colors) from NSUserDefaults to this editor.
/// Call after changing kPrefStyle* keys to refresh a live editor.
- (void)applyThemeColors;

/// Apply the default editor appearance (font, colors, line numbers).
- (void)applyDefaultTheme;

// Find / Replace — all return YES if a match was found/replaced.
- (BOOL)findNext:(NSString *)text matchCase:(BOOL)mc wholeWord:(BOOL)ww wrap:(BOOL)wrap;
- (BOOL)findPrev:(NSString *)text matchCase:(BOOL)mc wholeWord:(BOOL)ww wrap:(BOOL)wrap;

/// Replaces the current selection if it matches text, then finds the next occurrence.
- (BOOL)replace:(NSString *)text with:(NSString *)replacement
      matchCase:(BOOL)mc wholeWord:(BOOL)ww;

/// Replaces all occurrences. Returns number of replacements made.
- (NSInteger)replaceAll:(NSString *)text with:(NSString *)replacement
             matchCase:(BOOL)mc wholeWord:(BOOL)ww;

// ── Overwrite mode ────────────────────────────────────────────────────────────
- (void)toggleOverwriteMode;

// ── Comment / Uncomment ───────────────────────────────────────────────────────
- (void)toggleBlockComment:(id)sender;

// ── Macro recording ───────────────────────────────────────────────────────────
- (void)startMacroRecording;
- (void)stopMacroRecording;
- (void)runMacro;
/// Run a macro from a saved actions array (same format as the recorded macro).
- (void)runMacroActions:(NSArray<NSDictionary *> *)actions;
/// Record a menu command action (type 2) by selector name during macro recording.
- (void)recordMenuCommand:(NSString *)selectorName;
/// Record a menu command together with a plugin command ID. For plugin
/// commands (selector pluginMenuAction:), cmdID is the FuncItem _cmdID so
/// playback can dispatch the exact command; pass 0 for ordinary menu items.
- (void)recordMenuCommand:(NSString *)selectorName pluginCmdID:(NSInteger)cmdID;
/// The currently recorded macro actions (nil / empty if nothing recorded).
@property (nonatomic, readonly, nullable) NSArray<NSDictionary *> *macroActions;

// ── Line operations (action methods) ─────────────────────────────────────────
- (void)duplicateLine:(id)sender;
- (void)deleteLine:(id)sender;
- (void)moveLineUp:(id)sender;
- (void)moveLineDown:(id)sender;
- (void)toggleLineComment:(id)sender;
- (void)splitLines:(id)sender;

// ── Comment/Uncomment ─────────────────────────────────────────────────────────
- (void)addSingleLineComment:(id)sender;
- (void)removeSingleLineComment:(id)sender;
- (void)addBlockComment:(id)sender;
- (void)removeBlockComment:(id)sender;

// ── Multi-select ──────────────────────────────────────────────────────────────
- (void)beginEndSelect:(id)sender;
- (void)beginEndSelectColumnMode:(id)sender;
/// YES when the first click of Begin/End Select has been pressed (awaiting second click).
@property (nonatomic, readonly) BOOL beginSelectActive;
// Multi-Select All (4 variants)
- (void)multiSelectAllIgnoreCaseIgnoreWord:(id)sender;
- (void)multiSelectAllMatchCaseOnly:(id)sender;
- (void)multiSelectAllWholeWordOnly:(id)sender;
- (void)multiSelectAllMatchCaseWholeWord:(id)sender;

// Multi-Select Next (4 variants)
- (void)multiSelectNextIgnoreCaseIgnoreWord:(id)sender;
- (void)multiSelectNextMatchCaseOnly:(id)sender;
- (void)multiSelectNextWholeWordOnly:(id)sender;
- (void)multiSelectNextMatchCaseWholeWord:(id)sender;

- (void)undoLatestMultiSelect:(id)sender;
- (void)skipCurrentAndGoToNextMultiSelect:(id)sender;

// ── Blank/EOL cleanup ─────────────────────────────────────────────────────────
- (void)removeUnnecessaryBlankAndEOL:(id)sender;

// ── Read-only ─────────────────────────────────────────────────────────────────
- (void)clearReadOnlyFlag:(id)sender;

// ── Text direction ────────────────────────────────────────────────────────────
- (void)setTextDirectionRTL:(id)sender;
- (void)setTextDirectionLTR:(id)sender;
@property (nonatomic, readonly) BOOL isTextDirectionRTL;

// ── View toggles ─────────────────────────────────────────────────────────────
- (void)showWhiteSpaceAndTab:(id)sender;
- (void)showEndOfLine:(id)sender;

// ── Code folding (action methods) ────────────────────────────────────────────
- (void)foldAll:(id)sender;
- (void)unfoldAll:(id)sender;
- (void)foldCurrentLevel:(id)sender;
- (void)unfoldCurrentLevel:(id)sender;
- (void)foldLevel1:(id)sender;   - (void)foldLevel2:(id)sender;   - (void)foldLevel3:(id)sender;
- (void)foldLevel4:(id)sender;   - (void)foldLevel5:(id)sender;   - (void)foldLevel6:(id)sender;
- (void)foldLevel7:(id)sender;   - (void)foldLevel8:(id)sender;
- (void)unfoldLevel1:(id)sender; - (void)unfoldLevel2:(id)sender; - (void)unfoldLevel3:(id)sender;
- (void)unfoldLevel4:(id)sender; - (void)unfoldLevel5:(id)sender; - (void)unfoldLevel6:(id)sender;
- (void)unfoldLevel7:(id)sender; - (void)unfoldLevel8:(id)sender;

// ── Change History navigation ─────────────────────────────────────────────────
- (void)goToNextChange:(id)sender;
- (void)goToPreviousChange:(id)sender;
- (void)clearAllChanges:(id)sender;

// ── Incremental search helpers ────────────────────────────────────────────────
/// Highlight all occurrences of text using Scintilla indicator 28.
- (void)highlightAllMatches:(NSString *)text matchCase:(BOOL)mc;
/// Remove all incremental search highlights.
- (void)clearIncrementalSearchHighlights;

// ── Bookmarks (action methods) ───────────────────────────────────────────────
- (void)toggleBookmark:(id)sender;
- (void)nextBookmark:(id)sender;
- (void)previousBookmark:(id)sender;
- (void)clearAllBookmarks:(id)sender;
- (void)cutBookmarkedLines:(id)sender;
- (void)copyBookmarkedLines:(id)sender;
- (void)removeBookmarkedLines:(id)sender;
- (void)removeNonBookmarkedLines:(id)sender;
- (void)inverseBookmark:(id)sender;

// ── Navigation ───────────────────────────────────────────────────────────────
- (void)goToLineNumber:(NSInteger)lineNumber;
- (void)goToMatchingBrace:(id)sender;
- (void)selectAndFindNext:(id)sender;
- (void)selectAndFindPrevious:(id)sender;

// ── Case conversion (action methods) ─────────────────────────────────────────
- (void)convertToUppercase:(id)sender;
- (void)convertToLowercase:(id)sender;
- (void)convertToProperCase:(id)sender;
- (void)convertToProperCaseBlend:(id)sender;
- (void)convertToSentenceCase:(id)sender;
- (void)convertToSentenceCaseBlend:(id)sender;
- (void)convertToInvertedCase:(id)sender;
- (void)convertToRandomCase:(id)sender;

// ── Line operations ───────────────────────────────────────────────────────────
- (void)insertBlankLineAbove:(id)sender;
- (void)insertBlankLineBelow:(id)sender;
- (void)insertDateTimeShort:(id)sender;
- (void)insertDateTimeLong:(id)sender;
- (void)joinLines:(id)sender;

// ── Line sorting / cleanup (action methods) ───────────────────────────────────
- (void)sortLinesAscending:(id)sender;
- (void)sortLinesDescending:(id)sender;
- (void)sortLinesAscendingCI:(id)sender;
- (void)sortLinesByLengthAsc:(id)sender;
- (void)sortLinesByLengthDesc:(id)sender;
- (void)sortLinesRandomly:(id)sender;
- (void)sortLinesReverse:(id)sender;
- (void)sortLinesIntAsc:(id)sender;
- (void)sortLinesIntDesc:(id)sender;
- (void)sortLinesDecimalDotAsc:(id)sender;
- (void)sortLinesDecimalDotDesc:(id)sender;
- (void)sortLinesDecimalCommaAsc:(id)sender;
- (void)sortLinesDecimalCommaDesc:(id)sender;
- (void)removeDuplicateLines:(id)sender;
- (void)removeConsecutiveDuplicateLines:(id)sender;
- (void)trimTrailingWhitespace:(id)sender;
- (void)trimLeadingSpaces:(id)sender;
- (void)trimLeadingAndTrailingSpaces:(id)sender;
- (void)eolToSpace:(id)sender;
- (void)trimBothAndEOLToSpace:(id)sender;
- (void)removeBlankLines:(id)sender;
- (void)mergeBlankLines:(id)sender;
- (void)spacesToTabsLeading:(id)sender;
- (void)spacesToTabsAll:(id)sender;
- (void)tabsToSpaces:(id)sender;

// ── Read-Only ─────────────────────────────────────────────────────────────────
- (void)toggleReadOnly:(id)sender;

// ── Selection text ────────────────────────────────────────────────────────────
/// Returns the currently selected text, or nil if nothing is selected.
- (nullable NSString *)selectedText;

// ── Column mode / brace selection ─────────────────────────────────────────────
- (void)columnMode:(id)sender;
- (void)selectAllInBraces:(id)sender;

// ── Base64 ────────────────────────────────────────────────────────────────────
- (void)base64Encode:(id)sender;
- (void)base64Decode:(id)sender;

// ── ASCII / Hex conversion ────────────────────────────────────────────────────
- (void)asciiToHex:(id)sender;
- (void)hexToAscii:(id)sender;

// ── Auto-Completion (explicit menu triggers) ─────────────────────────────────
- (void)triggerFunctionCompletion:(id)sender;
- (void)triggerWordCompletion:(id)sender;
- (void)triggerFunctionParametersHint:(id)sender;
- (void)showFunctionParametersPreviousHint:(id)sender;
- (void)showFunctionParametersNextHint:(id)sender;
- (void)triggerPathCompletion:(id)sender;
- (void)finishOrSelectAutocompleteItem:(id)sender;

// ── Hashes ────────────────────────────────────────────────────────────────────
+ (nullable NSString *)hexHashForAlgorithm:(NSString *)algo data:(NSData *)data;
- (void)generateHashForAlgorithm:(NSString *)algo;
- (void)copyHashForAlgorithm:(NSString *)algo;

// ── Mark text with styles (indicators, 5 colors) ─────────────────────────────
/// Mark all occurrences of text with Scintilla indicator for style 1-5.
- (void)markStyle:(NSInteger)style allOccurrencesOf:(NSString *)text matchCase:(BOOL)mc wholeWord:(BOOL)ww;
/// Mark the current selection with the given style (1-5).
- (void)markStyleSelection:(NSInteger)style;
/// Clear all marks for a given style (1-5).
- (void)clearMarkStyle:(NSInteger)style;
/// Clear all 5 mark styles.
- (void)clearAllMarkStyles;
/// Jump to the next (dir=1) or previous (dir=-1) mark of any style.
- (void)jumpToNextMark:(NSInteger)dir;
/// Copy all text segments that carry the given mark style.
- (void)copyTextWithMarkStyle:(NSInteger)style;

// ── Paste to bookmarked lines ─────────────────────────────────────────────────
- (void)pasteToBookmarkedLines:(id)sender;

// ── View symbol toggles ───────────────────────────────────────────────────────
- (void)toggleWrapSymbol:(id)sender;
- (void)toggleHideLineMarks:(id)sender;
- (void)hideLinesInSelection:(id)sender;

// ── Base64 URL-safe + strict variants ─────────────────────────────────────────
- (void)base64EncodeWithPadding:(id)sender;
- (void)base64DecodeStrict:(id)sender;
- (void)base64URLSafeEncode:(id)sender;
- (void)base64URLSafeDecode:(id)sender;

// ── Spell check ───────────────────────────────────────────────────────────────
@property (nonatomic) BOOL spellCheckEnabled;
- (void)runSpellCheck;
- (void)clearSpellCheck;

// ── Git gutter diff markers ───────────────────────────────────────────────────
/// Async: runs git diff, marks added/modified/deleted lines in the gutter.
- (void)updateGitDiffMarkers;
/// Clear all git gutter markers.
- (void)clearGitDiffMarkers;

// ── Git diff line highlights (pink background) ────────────────────────────────
/// Async: runs git diff, highlights changed lines with a pink background indicator.
- (void)applyGitDiffHighlights;
/// Clear all pink diff highlights.
- (void)clearGitDiffHighlights;

// ── Scintilla key overrides ───────────────────────────────────────────────────
/// Apply ScintillaKeys overrides from shortcuts.xml via SCI_ASSIGNCMDKEY.
- (void)applyScintillaKeyOverrides;

// ── Character insertion (ASCII Codes Panel) ───────────────────────────────────
/// Insert str at the current cursor position, replacing any selection.
/// str is interpreted as Unicode (e.g. converted from Windows-1252).
- (void)insertCharacterString:(NSString *)str;

// ── Column editor ─────────────────────────────────────────────────────────────
/// Returns the number of lines the column editor will affect:
/// selected lines if text is selected, or lines from cursor to end of doc otherwise.
- (NSInteger)columnEditorLineCount;
/// Insert text at the caret column of every line in the selection (or to end of doc if no selection).
- (void)columnInsertText:(NSString *)text;
/// Insert sequential numbers starting at startVal, stepping by step, using
/// printf format string fmt (e.g. "%d", "%04X"). One number per selected line.
- (void)columnInsertNumbersFrom:(long long)startVal step:(long long)step format:(NSString *)fmt;
/// Insert one pre-formatted string per line (index 0 = first selected/affected line).
/// If the array is shorter than the line count, the last element is repeated.
- (void)columnInsertStrings:(NSArray<NSString *> *)strings;

@end

NS_ASSUME_NONNULL_END

/// Default macOS key bindings for a Scintilla command, read from the same generated
/// table the editor installs (kSciDefaultKeys in EditorView.mm — built from
/// scintilla/src/KeyMap.cxx MapDefault plus the scintilla/cocoa/ScintillaCocoa.mm
/// macMapDefault overlay). Writes up to maxCombos key definitions
/// (keyDef = sckKey | (mod << 16)) into combos and returns how many it WROTE, so the
/// count is always safe as a loop bound. 0 means the command has no default binding
/// on macOS — every command with one is present in the table.
///
/// Exposed so the Shortcut Mapper can show what the editor really does rather than
/// keeping a second, hand-maintained copy of the defaults that can drift from it.
int NppScintillaDefaultKeyCombos(int sciID, int *combos, int maxCombos);
