#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Boost/Perl syntax for the original Notepad++ Function List parser XML.
@interface NppParserRegex : NSObject
+ (nullable instancetype)regularExpressionWithPattern:(NSString *)pattern options:(NSRegularExpressionOptions)options error:(NSError * _Nullable * _Nullable)error;
- (nullable NSTextCheckingResult *)firstMatchInString:(NSString *)string options:(NSMatchingOptions)options range:(NSRange)range;
- (void)enumerateMatchesInString:(NSString *)string options:(NSMatchingOptions)options range:(NSRange)range usingBlock:(void (^)(NSTextCheckingResult *, NSMatchingFlags, BOOL *))block;
@end
NS_ASSUME_NONNULL_END
