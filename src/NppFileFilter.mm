#import "NppFileFilter.h"
@implementation NppFileFilter {
    NSArray<NSString *> *_includes, *_excludes, *_rootDirs, *_allDirs;
}
- (instancetype)initWithString:(NSString *)filters {
    if (!(self = [super init])) return nil;
    NSMutableArray *includes = [NSMutableArray new], *excludes = [NSMutableArray new];
    NSMutableArray *root = [NSMutableArray new], *all = [NSMutableArray new];
    for (NSString *token in [filters componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@",; \t\r\n"]]) {
        if (!token.length) continue;
        if ([token hasPrefix:@"!+\\"] || [token hasPrefix:@"!+/"]) [all addObject:[token substringFromIndex:3]];
        else if ([token hasPrefix:@"!\\"] || [token hasPrefix:@"!/"]) [root addObject:[token substringFromIndex:2]];
        else if ([token hasPrefix:@"!"]) [excludes addObject:[token substringFromIndex:1]];
        else [includes addObject:token];
    }
    _includes = includes; _excludes = excludes; _rootDirs = root; _allDirs = all;
    return self;
}
static BOOL matches(NSString *name, NSString *glob) {
    // Windows' *.* means every filename, including README and Makefile.
    if ([glob isEqualToString:@"*.*"]) glob = @"*";
    return [[NSPredicate predicateWithFormat:@"SELF LIKE[c] %@", glob] evaluateWithObject:name];
}
- (BOOL)matchesFileName:(NSString *)name {
    for (NSString *glob in _excludes) if (matches(name, glob)) return NO;
    if (!_includes.count) return YES;
    for (NSString *glob in _includes) if (matches(name, glob)) return YES;
    return NO;
}
- (BOOL)excludesDirectory:(NSString *)relativePath {
    NSArray<NSString *> *parts = relativePath.pathComponents;
    for (NSUInteger i=0; i<parts.count; i++) {
        if (i == 0) for (NSString *glob in _rootDirs) if (matches(parts[i],glob)) return YES;
        for (NSString *glob in _allDirs) if (matches(parts[i],glob)) return YES;
    }
    return NO;
}
@end
