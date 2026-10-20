#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Notepad++ include globs, !file exclusions, !\folder and !+\folder exclusions.
@interface NppFileFilter : NSObject
- (instancetype)initWithString:(nullable NSString *)filters;
- (BOOL)matchesFileName:(NSString *)name;
- (BOOL)excludesDirectory:(NSString *)relativePath;
@end
NS_ASSUME_NONNULL_END
