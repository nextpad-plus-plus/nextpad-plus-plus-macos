#import "NppAPICompletion.h"
#import "NppPaths.h"

@implementation NppAPICompletion {
    NSDictionary<NSString *, NSArray<NSDictionary *> *> *_functions;
    NSArray<NSString *> *_words;
}
+ (instancetype)completionForLanguage:(NSString *)language {
    NSString *name = language.length ? language : @"normal";
    if (![name.lastPathComponent isEqualToString:name]) name = @"normal";
    NSString *user = [NppConfigSubpath(@"autoCompletion") stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"xml"]];
    NSString *path = [[NSFileManager defaultManager] fileExistsAtPath:user] ? user :
        [[NSBundle mainBundle] pathForResource:(@{@"javascript.js":@"javascript",@"coffeescript":@"coffee",@"baanc":@"BaanC"}[name] ?: name) ofType:@"xml" inDirectory:@"autoCompletion"];
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
    NSDate *date = path ? [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil].fileModificationDate : nil;
    NSString *key = path ?: name;
    @synchronized(cache) {
        NSDictionary *entry = cache[key];
        if (entry && [entry[@"date"] isEqual:date ?: NSNull.null]) return entry[@"api"];
        NppAPICompletion *api = [[self alloc] initWithData:path ? [NSData dataWithContentsOfFile:path] : NSData.data];
        cache[key] = @{@"date": date ?: NSNull.null, @"api": api};
        return api;
    }
}
- (instancetype)initWithData:(NSData *)data {
    if (!(self = [super init])) return nil;
    NSXMLDocument *doc = data.length ? [[NSXMLDocument alloc] initWithData:data options:0 error:nil] : nil;
    NSXMLElement *env = [doc nodesForXPath:@"/NotepadPlus/AutoComplete/Environment" error:nil].firstObject;
    _ignoreCase = ![[env attributeForName:@"ignoreCase"].stringValue isEqualToString:@"no"];
    _startFunc = [env attributeForName:@"startFunc"].stringValue ?: @"(";
    _stopFunc = [env attributeForName:@"stopFunc"].stringValue ?: @")";
    _paramSeparator = [env attributeForName:@"paramSeparator"].stringValue ?: @",";
    _additionalWordChars = [env attributeForName:@"additionalWordChar"].stringValue ?: @"";
    NSMutableDictionary *functions = [NSMutableDictionary new];
    NSMutableSet *words = [NSMutableSet new];
    for (NSXMLElement *word in [doc nodesForXPath:@"/NotepadPlus/AutoComplete/KeyWord" error:nil]) {
        NSString *name = [word attributeForName:@"name"].stringValue;
        if (!name.length || [name rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) continue;
        [words addObject:name];
        NSMutableArray *overloads = [NSMutableArray new];
        for (NSXMLElement *overload in [word elementsForName:@"Overload"]) {
            NSMutableArray *params = [NSMutableArray new];
            for (NSXMLElement *param in [overload elementsForName:@"Param"])
                [params addObject:[param attributeForName:@"name"].stringValue ?: @""];
            [overloads addObject:@{@"return": [overload attributeForName:@"retVal"].stringValue ?: @"",
                @"description": [overload attributeForName:@"descr"].stringValue ?: @"", @"parameters": params}];
        }
        functions[_ignoreCase ? name.lowercaseString : name] = overloads;
    }
    _functions = functions;
    _words = [words.allObjects sortedArrayUsingSelector:@selector(compare:)];
    return self;
}
- (NSArray<NSString *> *)wordsWithPrefix:(NSString *)prefix {
    NSMutableArray *result = [NSMutableArray new];
    NSStringCompareOptions options = _ignoreCase ? NSCaseInsensitiveSearch : 0;
    for (NSString *word in _words)
        if ([word rangeOfString:prefix options:options | NSAnchoredSearch].location == 0) [result addObject:word];
    return result;
}
- (NSArray<NSDictionary *> *)overloadsForFunction:(NSString *)name {
    return _functions[_ignoreCase ? name.lowercaseString : name] ?: @[];
}
- (NSString *)signatureForFunction:(NSString *)name overload:(NSUInteger)index parameter:(NSUInteger)param highlight:(NSRange *)range {
    *range = NSMakeRange(0, 0);
    NSArray *overloads = [self overloadsForFunction:name];
    if (!overloads.count) return @"";
    NSDictionary *entry = overloads[index % overloads.count];
    NSMutableString *tip = [NSMutableString new];
    if (overloads.count > 1) [tip appendFormat:@"\001%lu/%lu\002 ", (unsigned long)(index % overloads.count + 1), (unsigned long)overloads.count];
    if ([entry[@"return"] length]) [tip appendFormat:@"%@ ", entry[@"return"]];
    [tip appendFormat:@"%@%@", name, _startFunc];
    NSArray<NSString *> *params = entry[@"parameters"];
    for (NSUInteger i = 0; i < params.count; i++) {
        if (i) [tip appendFormat:@"%@ ", _paramSeparator];
        NSUInteger start = [tip lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        [tip appendString:params[i]];
        if (i == param) *range = NSMakeRange(start, [params[i] lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    }
    [tip appendString:_stopFunc];
    if ([entry[@"description"] length]) [tip appendFormat:@"\n%@", entry[@"description"]];
    return tip;
}
@end
