#import "GitHelper.h"

@implementation GitHelper

// ── Private: run git synchronously, return stdout string ─────────────────────

+ (NSString *)_run:(NSArray<NSString *> *)args dir:(NSString *)dir {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/git";
    task.arguments = args;
    task.currentDirectoryPath = dir;
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError  = errPipe;
    @try {
        [task launch];
    } @catch (NSException *) {
        return @"";
    }
    // Drain stdout and stderr concurrently while git runs. Each pipe buffer is
    // only ~64KB; if either fills, git blocks on write and never exits — and
    // reading just one stream before waitUntilExit still deadlocks on the other.
    NSFileHandle *errFH = errPipe.fileHandleForReading;
    dispatch_semaphore_t errDone = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [errFH readDataToEndOfFile];
        dispatch_semaphore_signal(errDone);
    });
    NSData *data = [outPipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    dispatch_semaphore_wait(errDone, DISPATCH_TIME_FOREVER);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

// ── Public API ────────────────────────────────────────────────────────────────

+ (BOOL)isGitAvailable {
    static BOOL checked = NO;
    static BOOL available = NO;
    if (checked) return available;
    checked = YES;

    // Check if /usr/bin/git exists AND is a real binary, not just the Xcode shim.
    // The shim is a small stub (~170KB) that triggers "Install Command Line Tools".
    // Real git is much larger. We also check for .git directory presence via stat
    // to avoid triggering the shim dialog.
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:@"/usr/bin/git"]) return NO;

    // Try running "git --version" with DEVELOPER_DIR set to block the install prompt.
    // If git is real, it returns version info. If it's the shim, it fails silently.
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/git";
    task.arguments = @[@"--version"];
    task.environment = @{@"GIT_TERMINAL_PROMPT": @"0"};
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError  = errPipe;
    @try {
        [task launch];
        [task waitUntilExit];
        available = (task.terminationStatus == 0);
    } @catch (NSException *) {
        available = NO;
    }
    return available;
}

+ (nullable NSString *)gitRootForPath:(NSString *)path {
    // path may be a file or directory; normalize to directory
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir]) return nil;
    NSString *dir = isDir ? path : path.stringByDeletingLastPathComponent;

    NSString *result = [self _run:@[@"rev-parse", @"--show-toplevel"] dir:dir];
    result = [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return result.length ? result : nil;
}

+ (nullable NSString *)currentBranchAtRoot:(NSString *)root {
    NSString *result = [self _run:@[@"rev-parse", @"--abbrev-ref", @"HEAD"] dir:root];
    result = [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return result.length ? result : nil;
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)statusAtRoot:(NSString *)root {
    // core.quotePath=false makes git emit non-ASCII paths as raw UTF-8 instead
    // of C-quoting them (e.g. "café.txt" rather than "\"caf\303\251.txt\""),
    // so substringFromIndex:3 yields a usable pathspec for add/diff/open.
    NSString *out = [self _run:@[@"-c", @"core.quotePath=false", @"status", @"--porcelain", @"-u"] dir:root];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        if (line.length < 4) continue;
        NSString *xy   = [line substringToIndex:2];
        NSString *path = [[line substringFromIndex:3]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        // Handle rename format "old -> new"
        NSRange arrow = [path rangeOfString:@" -> "];
        if (arrow.location != NSNotFound)
            path = [path substringFromIndex:arrow.location + arrow.length];
        if (path.length) [items addObject:@{@"xy": xy, @"path": path}];
    }
    return items;
}

+ (nullable NSString *)diffForFile:(NSString *)path root:(NSString *)root {
    NSString *result = [self _run:@[@"diff", @"HEAD", @"--", path] dir:root];
    return result.length ? result : nil;
}

+ (void)stageFile:(NSString *)path root:(NSString *)root completion:(void (^)(BOOL))cb {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self _run:@[@"add", @"--", path] dir:root];
        dispatch_async(dispatch_get_main_queue(), ^{ if (cb) cb(YES); });
    });
}

+ (void)unstageFile:(NSString *)path root:(NSString *)root completion:(void (^)(BOOL))cb {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self _run:@[@"restore", @"--staged", @"--", path] dir:root];
        dispatch_async(dispatch_get_main_queue(), ^{ if (cb) cb(YES); });
    });
}

+ (void)commitMessage:(NSString *)msg root:(NSString *)root
           completion:(void (^)(BOOL, NSString *_Nullable))cb {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/usr/bin/git";
        task.arguments = @[@"commit", @"-m", msg];
        task.currentDirectoryPath = root;
        NSPipe *outPipe = [NSPipe pipe];
        NSPipe *errPipe = [NSPipe pipe];
        task.standardOutput = outPipe;
        task.standardError  = errPipe;
        @try {
            [task launch];
        } @catch (NSException *) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (cb) cb(NO, nil); });
            return;
        }
        // Drain stdout concurrently so a large commit summary can't fill the
        // pipe buffer and deadlock git before it exits; read stderr here.
        NSFileHandle *outFH = outPipe.fileHandleForReading;
        dispatch_semaphore_t outDone = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [outFH readDataToEndOfFile];
            dispatch_semaphore_signal(outDone);
        });
        NSData *errData = [errPipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        dispatch_semaphore_wait(outDone, DISPATCH_TIME_FOREVER);
        int status = task.terminationStatus;
        NSString *errMsg = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (cb) cb(status == 0, status == 0 ? nil : errMsg);
        });
    });
}

@end
