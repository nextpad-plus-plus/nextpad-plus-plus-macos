#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Reads the original Notepad++ autoCompletion XML format, including overloads.
@interface NppAPICompletion : NSObject
@property (readonly) BOOL ignoreCase;
@property (readonly, copy) NSString *startFunc;
@property (readonly, copy) NSString *stopFunc;
@property (readonly, copy) NSString *paramSeparator;
@property (readonly, copy) NSString *additionalWordChars;
+ (instancetype)completionForLanguage:(NSString *)language;
- (instancetype)initWithData:(NSData *)data;
- (NSArray<NSString *> *)wordsWithPrefix:(NSString *)prefix;
- (NSArray<NSDictionary *> *)overloadsForFunction:(NSString *)name;
- (NSString *)signatureForFunction:(NSString *)name overload:(NSUInteger)index parameter:(NSUInteger)param highlight:(NSRange *)range;
@end
NS_ASSUME_NONNULL_END
