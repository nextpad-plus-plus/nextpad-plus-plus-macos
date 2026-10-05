#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"

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
// Mark
@property BOOL doPurge;
@property BOOL doBookmarkLine;
@property NSInteger markStyle; // 1-5
// Find in Projects
@property BOOL projectPanel1;
@property BOOL projectPanel2;
@property BOOL projectPanel3;
@end

/// A single match result from a Find All operation.
@interface NPPSearchResult : NSObject
@property (copy) NSString *filePath;
@property NSInteger lineNumber;     // 1-based
@property (copy) NSString *lineText;
@property NSInteger matchStart;     // byte offset within lineText
@property NSInteger matchLength;    // byte length of match
@end

/// A file's worth of search results.
@interface NPPFileResults : NSObject
@property (copy) NSString *filePath;
@property NSMutableArray<NPPSearchResult *> *results;
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
    NPPReplaceFileWriteFailed,       // write error (see *error)
};

/// Centralized search operations — stateless utility methods.
@interface SearchEngine : NSObject

/// Convert Extended search string (\n \r \t \0 \xNN) to literal characters.
+ (NSString *)expandExtendedString:(NSString *)input;

/// Build Scintilla SCFIND_* flags from options.
+ (int)scintillaFlagsForOptions:(NPPFindOptions *)opts;

/// Find next/prev occurrence in a ScintillaView. Returns YES if found.
+ (BOOL)findInView:(ScintillaView *)sci options:(NPPFindOptions *)opts forward:(BOOL)forward;

/// Replace current selection if it matches, then find next. Returns YES if next found.
+ (BOOL)replaceInView:(ScintillaView *)sci options:(NPPFindOptions *)opts;

/// Replace all occurrences. Returns replacement count.
+ (NSInteger)replaceAllInView:(ScintillaView *)sci options:(NPPFindOptions *)opts;

/// Replace all occurrences in an external file's decoded text using the same
/// normal/extended/regex, case, and whole-word semantics as Find in Files.
/// Returns the transformed text and writes the actual replacement count.
+ (NSString *)stringByReplacingAllInString:(NSString *)content
                                   options:(NPPFindOptions *)opts
                          replacementCount:(NSInteger *)replacementCount;

/// Count all occurrences. Returns count.
+ (NSInteger)countInView:(ScintillaView *)sci options:(NPPFindOptions *)opts;

/// Find all occurrences in a single ScintillaView. Returns array of NPPSearchResult.
+ (NSArray<NPPSearchResult *> *)findAllInView:(ScintillaView *)sci
                                     filePath:(NSString *)path
                                      options:(NPPFindOptions *)opts;

/// Mark all occurrences with indicator style. Returns count.
+ (NSInteger)markAllInView:(ScintillaView *)sci options:(NPPFindOptions *)opts;

/// Recursive directory search. Calls progressBlock on main thread with current file and running count.
/// Call -cancel on cancelToken (from any thread) to abort between files; the
/// results gathered so far are returned. Returns array of NPPFileResults.
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
/// left untouched. Safe to call off the main thread.
+ (NPPReplaceFileStatus)replaceAllInFile:(NSString *)path
                                 options:(NPPFindOptions *)opts
                        replacementCount:(NSInteger *)replacementCount
                                encoding:(nullable NSStringEncoding *)encodingOut
                                   error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
