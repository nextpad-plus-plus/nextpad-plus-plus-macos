//
//  TahoeToolbarConfig.h
//  Nextpad++ (macOS) — Liquid Glass / Tahoe profile
//
//  Persistence + model for the Tahoe toolbar's group layout, stored in
//  ~/Library/Application Support/Nextpad++/toolbarButtonsTahoeConf.xml. This is a SEPARATE file from the
//  Classic toolbarButtonsConf.xml on purpose (see RFC §5.2.6): the Classic file
//  is rename-to-activate, whereas the Tahoe toolbar must be active whenever the
//  user is in the Tahoe appearance — driven by NPPAppearanceStyle, not by whether
//  a Classic config was hand-edited. This file is live (read-if-present) and
//  auto-materialized by the host on first Tahoe build.
//
//  This class owns ONLY the data + file I/O. It knows nothing about AppKit toolbar
//  construction (MainWindowController) or the Preferences UI; both consume it.
//
//  Model shape — an ordered NSArray of group dictionaries:
//      @{ @"label":    NSString,                     // capsule title, unique
//         @"kind":     @"builtin" | @"plugins",
//         @"primary":  NSArray<NSString*>,           // shown on the capsule
//         @"overflow": NSArray<NSString*>,           // behind the label's ▾ menu
//         @"hidden":   NSArray<NSString*> }           // not shown (kept so the
//                                                      // editor can re-surface them
//                                                      // and reconcile won't re-add)
//  For "builtin" groups the entries are toolbar button ids (TB_New, …, the kTB*
//  string space). For the "plugins" group they are plugin command NAMES (the
//  registered tooltip) — NOT the per-session cmdID, which isn't stable.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted (by the Preferences editor) when the Tahoe toolbar layout file changes,
/// so the live MainWindowController rebuilds its toolbar. No userInfo.
extern NSString *const NPPTahoeToolbarConfigChanged;

@interface TahoeToolbarConfig : NSObject

/// ~/Library/Application Support/Nextpad++/toolbarButtonsTahoeConf.xml
+ (NSString *)filePath;

/// Parse the file into the model. Returns nil if the file does not exist (the
/// caller then materializes defaults). Malformed entries are skipped gracefully.
+ (nullable NSArray<NSDictionary *> *)loadConfiguration;

/// Serialize the model to the file (with a commented schema header). YES on success.
+ (BOOL)saveModel:(NSArray<NSDictionary *> *)model;

/// Delete the file (Reset to Defaults — the host regenerates it on next build).
+ (void)removeFile;

// ── Catalog injected by MainWindowController at startup (single source of truth,
//    no duplication of the button tables). Used by the Preferences editor. ──

/// The default built-in groups, in dict form (kind=builtin). Empty until set.
+ (void)setDefaultBuiltinGroups:(NSArray<NSDictionary *> *)groups;
+ (NSArray<NSDictionary *> *)defaultBuiltinGroups;

/// Map of built-in button id → human display name (from toolbarDescriptors()).
+ (void)setButtonDisplayNames:(NSDictionary<NSString *, NSString *> *)names;
/// Display name for a built-in button id; falls back to the id minus "TB_".
+ (NSString *)displayNameForId:(NSString *)btnId;

@end

NS_ASSUME_NONNULL_END
