#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"
#import "SearchCore.h"

NS_ASSUME_NONNULL_BEGIN

/// Centralized search operations — stateless utility methods. The options and
/// result types, and the operations that need no view (Find/Replace in Files,
/// Find in Projects), live in NPPSearchCore (SearchCore.h); this subclass adds
/// the operations on a ScintillaView. Both run the same engine and loops.
@interface SearchEngine : NPPSearchCore

/// Find next/prev occurrence in a ScintillaView. Returns YES if found.
+ (BOOL)findInView:(ScintillaView *)sci options:(NPPFindOptions *)opts forward:(BOOL)forward;

/// Replace current selection if it matches, then find next. Returns YES if next found.
+ (BOOL)replaceInView:(ScintillaView *)sci options:(NPPFindOptions *)opts;

/// Replace all occurrences. Returns replacement count.
+ (NSInteger)replaceAllInView:(ScintillaView *)sci options:(NPPFindOptions *)opts;

/// Count all occurrences. Returns count.
+ (NSInteger)countInView:(ScintillaView *)sci options:(NPPFindOptions *)opts;

/// Find all occurrences in a single ScintillaView. Returns one NPPSearchResult
/// per line with hits (each hit in matchRanges).
+ (NSArray<NPPSearchResult *> *)findAllInView:(ScintillaView *)sci
                                     filePath:(NSString *)path
                                      options:(NPPFindOptions *)opts;

/// Mark all occurrences with indicator style. Returns count.
+ (NSInteger)markAllInView:(ScintillaView *)sci options:(NPPFindOptions *)opts;

/// The view's word characters (SCI_GETWORDCHARS), for NPPFindOptions.wordChars.
+ (NSString *)wordCharsOfView:(ScintillaView *)sci;

@end

NS_ASSUME_NONNULL_END
