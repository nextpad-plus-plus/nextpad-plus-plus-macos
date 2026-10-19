//  NppPaths.mm
//  See NppPaths.h.

#import "NppPaths.h"

static NSString *sConfigOverride;
static BOOL sConfigInitialized;
void NppSetConfigDirOverride(NSString *directory) {
    NSCAssert(!sConfigInitialized, @"Set the configuration directory before loading configuration");
    sConfigOverride = [directory.stringByExpandingTildeInPath stringByStandardizingPath];
}

NSString *NppLegacyConfigDir(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".nextpad++"];
}

static NSString *NppComputeConfigDir(void) {
    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    if (appSupport.length == 0) {
        // Should not happen on macOS, but keep a sane fallback.
        appSupport = [NSHomeDirectory()
            stringByAppendingPathComponent:@"Library/Application Support"];
    }
    return [appSupport stringByAppendingPathComponent:@"Nextpad++"];
}

// Recursively move everything under `src` into `dst`, NEVER overwriting an
// existing destination. Returns YES iff `src` ends up fully drained (so the
// caller may remove it).
//   - No collision: a plain move (atomic same-volume rename) handles a file or a
//     whole subtree at once; falls back to copy+delete across volumes.
//   - Both sides are directories: merge child-by-child with the same rule.
//   - File-vs-existing collision: the destination (newer) copy wins and the
//     legacy item is left in place — nothing is lost.
static BOOL NppMergeMove(NSFileManager *fm, NSString *src, NSString *dst) {
    BOOL srcIsDir = NO;
    if (![fm fileExistsAtPath:src isDirectory:&srcIsDir]) return YES;  // vanished

    if (![fm fileExistsAtPath:dst]) {
        NSError *moveErr = nil;
        if ([fm moveItemAtPath:src toPath:dst error:&moveErr]) return YES;
        NSError *copyErr = nil;
        if ([fm copyItemAtPath:src toPath:dst error:&copyErr]) {
            [fm removeItemAtPath:src error:NULL];
            return YES;
        }
        NSLog(@"[Config] Failed to migrate %@ (move: %@; copy: %@)", src, moveErr, copyErr);
        return NO;
    }

    BOOL dstIsDir = NO;
    [fm fileExistsAtPath:dst isDirectory:&dstIsDir];
    if (!srcIsDir || !dstIsDir) {
        NSLog(@"[Config] Keeping %@; legacy copy left at %@", dst, src);
        return NO;
    }

    BOOL drained = YES;
    for (NSString *name in [fm contentsOfDirectoryAtPath:src error:NULL]) {
        if (!NppMergeMove(fm, [src stringByAppendingPathComponent:name],
                              [dst stringByAppendingPathComponent:name]))
            drained = NO;
    }
    if (drained) [fm removeItemAtPath:src error:NULL];
    return drained;
}

// One-time migration of a legacy ~/.nextpad++ tree into the new base dir.
//
// The new base dir may ALREADY EXIST on a first upgrade — e.g. NppLocalizer
// eagerly creates ~/Library/Application Support/Nextpad++/localization. So
// "new dir exists" is NOT a valid "already migrated" sentinel; treating it as
// one would strand the user's real config/session/plugins in ~/.nextpad++.
// Instead we recursively merge the legacy tree into the new one, never
// clobbering anything already present, and remove the legacy dir only once it
// is fully drained (so a partial failure leaves un-migrated items in place).
static void NppMigrateLegacyIfNeeded(NSString *newDir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *legacy = NppLegacyConfigDir();

    BOOL legacyIsDir = NO;
    BOOL hasLegacy = [fm fileExistsAtPath:legacy isDirectory:&legacyIsDir] && legacyIsDir;
    if (!hasLegacy) return;                    // nothing to migrate (fresh install)

    [fm createDirectoryAtPath:newDir withIntermediateDirectories:YES
                   attributes:nil error:NULL];

    if (NppMergeMove(fm, legacy, newDir))
        NSLog(@"[Config] Migrated legacy %@ into %@", legacy, newDir);
    else
        NSLog(@"[Config] Partially migrated %@ into %@ (some items kept in place)",
              legacy, newDir);
}

NSString *NppConfigDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sConfigInitialized = YES;
        NSString *environmentOverride = NSProcessInfo.processInfo.environment[@"NEXTPAD_SETTINGS_DIR"];
        NSString *override = sConfigOverride.length ? sConfigOverride : environmentOverride;
        dir = override.length ? [override.stringByExpandingTildeInPath stringByStandardizingPath] : NppComputeConfigDir();
        if (!override.length) NppMigrateLegacyIfNeeded(dir);
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
    });
    return dir;
}

NSString *NppConfigSubpath(NSString *relativePath) {
    return [NppConfigDir() stringByAppendingPathComponent:relativePath];
}
