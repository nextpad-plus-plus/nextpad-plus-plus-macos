//
//  TahoeToolbarConfig.mm
//  Nextpad++ (macOS) — Liquid Glass / Tahoe profile
//
//  See TahoeToolbarConfig.h for the model + rationale.
//

#import "TahoeToolbarConfig.h"
#import "NppPaths.h"

NSString *const NPPTahoeToolbarConfigChanged = @"NPPTahoeToolbarConfigChanged";

// Mirrors nppConfigDir() in MainWindowController.mm (kept local to avoid a header
// dependency): ~/Library/Application Support/Nextpad++.
static NSString *_tahoeConfigDir(void) {
    return NppConfigDir();
}

static NSString *const kSchemaHeader =
    @" Tahoe Toolbar Layout (Nextpad++ macOS — Liquid Glass appearance)\n"
    @"  ============================================================\n"
    @"  This file is generated and managed by Nextpad++. It is LIVE: it takes\n"
    @"  effect immediately when the appearance is set to Tahoe (no rename needed,\n"
    @"  unlike toolbarButtonsConf.xml). Edit it from Preferences ▸ Toolbar, or by\n"
    @"  hand here. Delete it to restore defaults.\n\n"
    @"  Each <Group> becomes one toolbar capsule. <Primary> buttons show on the\n"
    @"  capsule; <Overflow> buttons sit behind the capsule label's ▾ menu; <Hidden>\n"
    @"  buttons are not shown. Built-in buttons are referenced by id (<Btn id=...>),\n"
    @"  plugin buttons by their command name (<Btn name=...>). ";

@implementation TahoeToolbarConfig

static NSArray<NSDictionary *> *sDefaultBuiltinGroups = nil;
static NSDictionary<NSString *, NSString *> *sDisplayNames = nil;

+ (NSString *)filePath {
    return [_tahoeConfigDir() stringByAppendingPathComponent:@"toolbarButtonsTahoeConf.xml"];
}

#pragma mark - Catalog (injected by MainWindowController)

+ (void)setDefaultBuiltinGroups:(NSArray<NSDictionary *> *)groups {
    sDefaultBuiltinGroups = [groups copy];
}

+ (NSArray<NSDictionary *> *)defaultBuiltinGroups {
    return sDefaultBuiltinGroups ?: @[];
}

+ (void)setButtonDisplayNames:(NSDictionary<NSString *, NSString *> *)names {
    sDisplayNames = [names copy];
}

+ (NSString *)displayNameForId:(NSString *)btnId {
    NSString *n = sDisplayNames[btnId];
    if (n.length) return n;
    if ([btnId hasPrefix:@"TB_"]) return [btnId substringFromIndex:3];
    return btnId;
}

#pragma mark - Load

+ (nullable NSArray<NSDictionary *> *)loadConfiguration {
    NSString *path = [self filePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;

    NSXMLDocument *doc = [[NSXMLDocument alloc]
        initWithContentsOfURL:[NSURL fileURLWithPath:path] options:0 error:nil];
    if (!doc) return nil;

    NSMutableArray<NSDictionary *> *model = [NSMutableArray array];
    NSArray *groupNodes = [doc nodesForXPath:@"//TahoeToolbar/Group" error:nil];
    for (NSXMLElement *gEl in groupNodes) {
        NSString *label = [gEl attributeForName:@"label"].stringValue;
        NSString *kind  = [gEl attributeForName:@"kind"].stringValue ?: @"builtin";
        if (!label.length) continue;
        BOOL isPlugins = [kind isEqualToString:@"plugins"];

        NSMutableDictionary *g = [NSMutableDictionary dictionary];
        g[@"label"] = label;
        g[@"kind"]  = isPlugins ? @"plugins" : @"builtin";
        // "customized" marks that the user has taken over this group's layout, so
        // the host stops re-applying its smart default (used for the Plugins group).
        if ([[gEl attributeForName:@"customized"].stringValue isEqualToString:@"yes"])
            g[@"customized"] = @YES;
        for (NSString *section in @[@"primary", @"overflow", @"hidden"]) {
            NSMutableArray<NSString *> *entries = [NSMutableArray array];
            NSString *cap = [section capitalizedString];   // Primary / Overflow / Hidden
            NSArray *btns = [gEl nodesForXPath:
                [NSString stringWithFormat:@"%@/Btn", cap] error:nil];
            for (NSXMLElement *bEl in btns) {
                NSString *attr = isPlugins ? @"name" : @"id";
                NSString *val  = [bEl attributeForName:attr].stringValue;
                if (val.length) [entries addObject:val];
            }
            g[section] = entries;
        }
        [model addObject:g];
    }
    return model.count ? model : nil;
}

#pragma mark - Save

+ (BOOL)saveModel:(NSArray<NSDictionary *> *)model {
    NSXMLElement *root = [NSXMLElement elementWithName:@"NotepadPlus"];
    NSXMLElement *tb   = [NSXMLElement elementWithName:@"TahoeToolbar"];
    [root addChild:tb];

    for (NSDictionary *g in model) {
        NSString *label = g[@"label"];
        if (!label.length) continue;
        BOOL isPlugins = [g[@"kind"] isEqualToString:@"plugins"];

        NSXMLElement *gEl = [NSXMLElement elementWithName:@"Group"];
        [gEl addAttribute:[NSXMLNode attributeWithName:@"label" stringValue:label]];
        [gEl addAttribute:[NSXMLNode attributeWithName:@"kind"
                                           stringValue:(isPlugins ? @"plugins" : @"builtin")]];
        if ([g[@"customized"] boolValue])
            [gEl addAttribute:[NSXMLNode attributeWithName:@"customized" stringValue:@"yes"]];
        for (NSString *section in @[@"primary", @"overflow", @"hidden"]) {
            NSXMLElement *sEl = [NSXMLElement elementWithName:[section capitalizedString]];
            for (NSString *entry in (NSArray *)(g[section] ?: @[])) {
                if (![entry isKindOfClass:[NSString class]] || !entry.length) continue;
                NSXMLElement *bEl = [NSXMLElement elementWithName:@"Btn"];
                [bEl addAttribute:[NSXMLNode attributeWithName:(isPlugins ? @"name" : @"id")
                                                   stringValue:entry]];
                [sEl addChild:bEl];
            }
            [gEl addChild:sEl];
        }
        [tb addChild:gEl];
    }

    NSXMLDocument *doc = [NSXMLDocument documentWithRootElement:root];
    doc.version = @"1.0";
    doc.characterEncoding = @"UTF-8";
    // Lead with the schema comment (insert before the root element).
    [doc insertChild:[NSXMLNode commentWithStringValue:kSchemaHeader] atIndex:0];

    NSData *data = [doc XMLDataWithOptions:NSXMLNodePrettyPrint];
    NSString *dir = _tahoeConfigDir();
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [data writeToFile:[self filePath] atomically:YES];
}

+ (void)removeFile {
    [[NSFileManager defaultManager] removeItemAtPath:[self filePath] error:nil];
}

@end
