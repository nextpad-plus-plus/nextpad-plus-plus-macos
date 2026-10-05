// SearchCore.h
// Search options, results, and the search operations that need no editor view:
// Find/Replace in Files, Find in Projects, and replacing in a string. Foundation
// only, so the headless tests (ctest) can link it without AppKit. SearchEngine
// (SearchEngine.h) adds the operations on a ScintillaView.
//
// Every operation runs the editor's engine: Find in Files loads each file into
// a headless Scintilla Document and searches it with the same flags, the same
// Boost.Regex backend and the same loops as a tab (see regex/NppBufferSearch.h).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NPPSearchType) {
    NPPSearchNormal   = 0,
    NPPSearchExtended = 1,  // \n \r \t \0 \xNN escapes
    NPPSearchRegex    = 2,
};

typedef NS_ENUM(NSInteger, NPPSearchDir) {
    NPPSearchDown = 0,
    NPPSearchUp   = 1,
};

/// Holds all search parameters — shared across the unified Find window.
@interface NPPFindOptions : NSObject <NSCopying>
@property (copy) NSString *searchText;
@property (copy) NSString *replaceText;
@property BOOL matchCase;
@property BOOL wholeWord;
@property BOOL wrapAround;
@property BOOL inSelection;
@property NPPSearchDir direction;
@property NPPSearchType searchType;
@property BOOL dotMatchesNewline;
// Find in Files
@property (copy, nullable) NSString *filters;
@property (copy, nullable) NSString *directory;
@property BOOL isRecursive;
@property BOOL isInHiddenDirs;
/// Word characters for "Match whole word only" outside the editor (the
/// editor's SCI_GETWORDCHARS). nil uses Scintilla's default set.
@property (copy, nullable) NSString *wordChars;
// Mark
@property BOOL doPurge;
@property BOOL doBookmarkLine;
@property NSInteger markStyle; // 1-5
// Find in Projects
@property BOOL projectPanel1;
@property BOOL projectPanel2;
@property BOOL projectPanel3;
@end

/// One line of Find All / Find in Files results. As in Notepad++, a line with
/// several hits is listed once, with every hit in matchRanges.
@interface NPPSearchResult : NSObject
@property (copy) NSString *filePath;
@property NSInteger lineNumber;     // 1-based
@property (copy) NSString *lineText;    // the line without its EOL
/// First hit on the line, in UTF-16 units of lineText.
@property NSInteger matchStart;
@property NSInteger matchLength;
/// Every hit on the line (NSRange values in UTF-16 units of lineText), in
/// order. A match that continues onto later lines is cut at the end of this
/// line; an empty match (e.g. ^) has length 0.
@property (copy) NSArray<NSValue *> *matchRanges;
/// Number of hits on this line (matchRanges.count, at least 1).
@property (readonly) NSInteger hitCount;
@end

/// A file's worth of search results.
@interface NPPFileResults : NSObject
@property (copy) NSString *filePath;
@property NSMutableArray<NPPSearchResult *> *results;
/// Total hits in the file (the sum of the lines' hitCount).
@property (readonly) NSInteger hitCount;
@end

/// Thread-safe cancellation flag for a background Find/Replace in Files run.
/// One token per run, so a late -cancel can never stop the next search.
/// -cancel may be called from any thread; the worker polls isCancelled.
@interface NPPCancelToken : NSObject
@property (readonly, getter=isCancelled) BOOL cancelled;
- (void)cancel;
@end

/// Outcome of +replaceAllInFile:... for one file.
typedef NS_ENUM(NSInteger, NPPReplaceFileStatus) {
    NPPReplaceFileReplaced = 0,      // rewritten; replacementCount > 0
    NPPReplaceFileUnchanged,         // no match, or replacement was a no-op
    NPPReplaceFileUnreadable,        // missing, binary, or undecodable
    NPPReplaceFileUnrepresentable,   // result not encodable in the original encoding
    NPPReplaceFileDecodeNotClean,    // file did not decode cleanly; a rewrite would change other bytes
    NPPReplaceFileChangedOnDisk,     // file changed between read and write (e.g. saved in a tab)
    NPPReplaceFileOpenModified,      // file is open in a tab with unsaved changes
    NPPReplaceFileWriteFailed,       // write error (see *error)
};

@interface NPPSearchCore : NSObject

/// Convert Extended search string (\n \r \t \0 \xNN) to literal characters.
+ (NSString *)expandExtendedString:(NSString *)input;

/// Build Scintilla SCFIND_* flags from options.
+ (int)scintillaFlagsForOptions:(NPPFindOptions *)opts;

/// Flags for the loop operations (Replace All, Find All, Mark All, Count, and
/// Find/Replace in Files): scintillaFlagsForOptions plus, in regex mode, the
/// empty-match rules that keep e.g. `$` from matching twice at one place.
+ (int)loopFlagsForOptions:(NPPFindOptions *)opts;
/// Flags for a single Find Next.
+ (int)findNextFlagsForOptions:(NPPFindOptions *)opts;
/// Flags for checking whether the selection is a match before Replace.
+ (int)findForReplaceFlagsForOptions:(NPPFindOptions *)opts;

/// Nil if the options' search text can be searched for; otherwise the reason
/// (in regex mode, the engine's message for a pattern that does not compile).
+ (nullable NSString *)patternErrorForOptions:(NPPFindOptions *)opts;

/// Add one hit to Find All results. lineBytes/lineLength are the UTF-8 bytes
/// of the line (without EOL); hitStart/hitEnd are byte offsets in that line
/// (hitEnd is clamped to the line). A hit on the same line as the last result
/// is added to that result's matchRanges.
+ (void)appendHitToResults:(NSMutableArray<NPPSearchResult *> *)results
                  filePath:(NSString *)path
                lineNumber:(NSInteger)lineNumber
                 lineBytes:(const char *)lineBytes
                lineLength:(NSUInteger)lineLength
                  hitStart:(NSUInteger)hitStart
                    hitEnd:(NSUInteger)hitEnd;

/// Find every match in a string with the editor's semantics. One
/// NPPSearchResult per line with hits. cancelToken may be nil.
+ (NSArray<NPPSearchResult *> *)findAllInString:(NSString *)content
                                       filePath:(NSString *)path
                                        options:(NPPFindOptions *)opts
                                    cancelToken:(nullable NPPCancelToken *)cancelToken;

/// Replace all occurrences in an external file's decoded text with the same
/// engine and semantics as Replace All in the editor. Returns the transformed
/// text and writes the actual replacement count.
+ (NSString *)stringByReplacingAllInString:(NSString *)content
                                   options:(NPPFindOptions *)opts
                          replacementCount:(NSInteger *)replacementCount;

/// Recursive directory search. Calls progressBlock on main thread with current file and running count.
/// Call -cancel on cancelToken (from any thread) to abort between files (and
/// periodically within a large file); the results gathered so far are
/// returned. Returns array of NPPFileResults.
/// totalFilesScanned (optional out): total number of files examined.
/// Files are decoded with the editor's encoding detection (NppTextEncoding);
/// binary files are skipped.
+ (NSArray<NPPFileResults *> *)findInDirectory:(NSString *)directory
                                       options:(NPPFindOptions *)opts
                                 progressBlock:(nullable void(^)(NSString *currentFile, NSInteger hits))progressBlock
                                   cancelToken:(nullable NPPCancelToken *)cancelToken
                            totalFilesScanned:(nullable NSInteger *)totalFilesScanned;

/// Search within a specific list of file paths (for Find in Projects).
/// Applies file filters from opts.filters. Returns array of NPPFileResults.
+ (NSArray<NPPFileResults *> *)findInFilePaths:(NSArray<NSString *> *)filePaths
                                       options:(NPPFindOptions *)opts
                                 progressBlock:(nullable void(^)(NSString *currentFile, NSInteger hits))progressBlock
                                   cancelToken:(nullable NPPCancelToken *)cancelToken
                            totalFilesScanned:(nullable NSInteger *)totalFilesScanned;

/// Replace All in a file on disk (Replace in Files / Replace in Projects).
/// The file is decoded with the same rules as Find in Files and written back
/// in its original encoding, keeping its BOM. Never writes a lossy result: if
/// the replaced text cannot be represented in the original encoding the file
/// is left untouched and NPPReplaceFileUnrepresentable is returned, with
/// *encodingOut set to that encoding. A file whose decoded text does not
/// re-encode to its original bytes (NPPReplaceFileDecodeNotClean) or that
/// changed on disk since it was read (NPPReplaceFileChangedOnDisk) is also
/// left untouched. The new contents are staged in a temp file and committed
/// by a rename on the main thread, where editor saves also run, so a save
/// can't slip in between the final check and the write. isOpenAndModified
/// (optional, called on the main thread just before the commit) returns YES
/// to skip a file that has unsaved changes in an editor tab
/// (NPPReplaceFileOpenModified). Safe to call off the main thread.
+ (NPPReplaceFileStatus)replaceAllInFile:(NSString *)path
                                 options:(NPPFindOptions *)opts
                        replacementCount:(NSInteger *)replacementCount
                                encoding:(nullable NSStringEncoding *)encodingOut
                       isOpenAndModified:(nullable BOOL (^)(NSString *path))isOpenAndModified
                                   error:(NSError * _Nullable * _Nullable)error;

/// Call on the main thread before starting a background search: builds
/// Scintilla's lazily initialised, unlocked case tables up front.
+ (void)prepareForBackgroundSearch;

@end

NS_ASSUME_NONNULL_END
