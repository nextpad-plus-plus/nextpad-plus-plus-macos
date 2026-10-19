//  NppPaths.h
//  Centralised resolver for the Nextpad++ user-data directory.
//
//  Nextpad++ keeps user configuration, plugins, backups, session state and the
//  like under a single base directory. Historically that was the hidden
//  ~/.nextpad++ folder (a straight port of %APPDATA%\Nextpad++ on Windows).
//  macOS applications are expected to store this kind of data under
//  ~/Library/Application Support/<AppName> instead (see GitHub issue #67), so
//  that is the base directory used now. NppConfigDir() migrates an existing
//  ~/.nextpad++ folder to the new location once, on first use.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Base user-data directory: ~/Library/Application Support/Nextpad++.
/// The directory is created if it does not exist. The first call after upgrading
/// from a build that used ~/.nextpad++ migrates that legacy folder here.
FOUNDATION_EXPORT NSString *NppConfigDir(void);
/// Set before the first NppConfigDir call (CLI -settingsDir and isolated test profiles).
FOUNDATION_EXPORT void NppSetConfigDirOverride(NSString *directory);

/// Convenience: NppConfigDir() joined with a relative subpath, e.g.
/// NppConfigSubpath(@"plugins") or NppConfigSubpath(@"shortcuts.xml").
FOUNDATION_EXPORT NSString *NppConfigSubpath(NSString *relativePath);

/// The legacy ~/.nextpad++ directory. Exposed for migration/diagnostics only;
/// normal code should use NppConfigDir()/NppConfigSubpath().
FOUNDATION_EXPORT NSString *NppLegacyConfigDir(void);

NS_ASSUME_NONNULL_END
