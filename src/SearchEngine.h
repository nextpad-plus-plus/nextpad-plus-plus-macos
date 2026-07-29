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
/// Set *cancelFlag to YES to abort. Returns array of NPPFileResults.
/// totalFilesScanned (optional out): total number of files examined.
+ (NSArray<NPPFileResults *> *)findInDirectory:(NSString *)directory
                                       options:(NPPFindOptions *)opts
                                 progressBlock:(nullable void(^)(NSString *currentFile, NSInteger hits))progressBlock
                                    cancelFlag:(BOOL *)cancelFlag
                            totalFilesScanned:(nullable NSInteger *)totalFilesScanned;

/// Search within a specific list of file paths (for Find in Projects).
/// Applies file filters from opts.filters. Returns array of NPPFileResults.
+ (NSArray<NPPFileResults *> *)findInFilePaths:(NSArray<NSString *> *)filePaths
                                       options:(NPPFindOptions *)opts
                                 progressBlock:(nullable void(^)(NSString *currentFile, NSInteger hits))progressBlock
                                    cancelFlag:(BOOL *)cancelFlag
                            totalFilesScanned:(nullable NSInteger *)totalFilesScanned;

@end

NS_ASSUME_NONNULL_END
