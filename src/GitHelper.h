#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Utility class that wraps the git CLI via NSTask. No UI.
@interface GitHelper : NSObject

/// Returns YES if git CLI is available (not just the Xcode shim).
+ (BOOL)isGitAvailable;

/// Walk up from path looking for .git; returns the repo root or nil.
+ (nullable NSString *)gitRootForPath:(NSString *)path;

/// Returns current branch name (e.g. "main") or nil if not a git repo.
+ (nullable NSString *)currentBranchAtRoot:(NSString *)root;

/// Parse `git status --porcelain -u`. Returns array of dicts with "xy" and "path" keys.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)statusAtRoot:(NSString *)root;

/// Run `git diff HEAD -- path`. Returns the raw unified diff string or nil.
+ (nullable NSString *)diffForFile:(NSString *)path root:(NSString *)root;

/// Stage a file (git add). Calls completion on main queue.
+ (void)stageFile:(NSString *)path root:(NSString *)root
       completion:(void (^)(BOOL success, NSString *_Nullable error))cb;

/// Unstage a file (git restore --staged). Calls completion on main queue.
+ (void)unstageFile:(NSString *)path root:(NSString *)root
         completion:(void (^)(BOOL success, NSString *_Nullable error))cb;

/// Commit with message. Calls completion(success, errorMessage) on main queue.
+ (void)commitMessage:(NSString *)msg root:(NSString *)root
           completion:(void (^)(BOOL success, NSString *_Nullable error))cb;

@end

NS_ASSUME_NONNULL_END
