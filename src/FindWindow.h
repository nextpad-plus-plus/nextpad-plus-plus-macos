#import <Cocoa/Cocoa.h>
#import "SearchEngine.h"

NS_ASSUME_NONNULL_BEGIN

@class FindWindow;
@class EditorView;
@class SearchResultsPanel;
@class ProjectPanel;

typedef NS_ENUM(NSInteger, FindWindowTab) {
    FindWindowTabFind       = 0,
    FindWindowTabReplace    = 1,
    FindWindowTabFindInFiles = 2,
    FindWindowTabFindInProjects = 3,
    FindWindowTabMark       = 4,
};

@protocol FindWindowDelegate <NSObject>
- (nullable EditorView *)currentEditor;
- (NSArray<EditorView *> *)allOpenEditors;
- (void)findWindow:(FindWindow *)fw navigateToFile:(NSString *)path
            atLine:(NSInteger)line;
- (void)findWindow:(FindWindow *)fw showResults:(NSArray *)results
     forSearchText:(NSString *)text options:(NPPFindOptions *)opts
      filesSearched:(NSInteger)filesSearched;
- (void)findWindowShowSearchResultsPanel:(FindWindow *)fw;
- (nullable SearchResultsPanel *)searchResultsPanel;
- (nullable ProjectPanel *)projectPanel;
@end

/// Unified 5-tab Find/Replace/Find in Files/Find in Projects/Mark window.
@interface FindWindow : NSWindowController <NSWindowDelegate, NSComboBoxDelegate>

@property (nonatomic, weak, nullable) id<FindWindowDelegate> delegate;

/// Singleton accessor.
+ (instancetype)sharedWindow;

/// Show the window and switch to the specified tab.
- (void)showTab:(FindWindowTab)tab;

/// Current search options (read from UI controls).
- (NPPFindOptions *)currentOptions;

/// Pre-fill the search field with text (e.g., from editor selection).
- (void)setSearchText:(NSString *)text;

/// Pre-fill the directory field (for Find in Files tab).
- (void)setDirectory:(NSString *)path;

/// Check a specific Project Panel checkbox (0, 1, or 2) and uncheck the others.
- (void)selectProjectPanel:(NSInteger)index;

/// Get current search text for findNext/findPrev from menu.
@property (nonatomic, readonly) NSString *searchText;

@end

NS_ASSUME_NONNULL_END
