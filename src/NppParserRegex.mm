#import "NppParserRegex.h"
#define BOOST_REGEX_STANDALONE
#define BOOST_HAS_THREADS
#include "../regex/boost/regex.hpp"
#include <memory>
#include <vector>

@interface NppParserMatch : NSTextCheckingResult
@property (copy) NSArray<NSValue *> *ranges;
@end
@implementation NppParserMatch
- (NSTextCheckingType)resultType { return NSTextCheckingTypeRegularExpression; }
- (NSRange)range { return self.ranges.firstObject.rangeValue; }
- (NSUInteger)numberOfRanges { return self.ranges.count; }
- (NSRange)rangeAtIndex:(NSUInteger)i { return i < self.ranges.count ? self.ranges[i].rangeValue : NSMakeRange(NSNotFound,0); }
@end

@implementation NppParserRegex {
    std::unique_ptr<boost::wregex> _regex;
}
+ (instancetype)regularExpressionWithPattern:(NSString *)pattern options:(NSRegularExpressionOptions)options error:(NSError **)error {
    NppParserRegex *result=[self new];
    try {
        NSData *data=[pattern dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
        std::wstring wide(data.length/sizeof(wchar_t),0);
        memcpy(wide.data(),data.bytes,data.length);
        result->_regex=std::make_unique<boost::wregex>();
        result->_regex->imbue(std::locale("en_US.UTF-8"));
        boost::regex::flag_type flags=boost::regex::perl;
        if (!(options & NSRegularExpressionDotMatchesLineSeparators)) flags|=boost::regex::no_mod_s;
        else flags|=boost::regex::mod_s;
        if (!(options & NSRegularExpressionAnchorsMatchLines)) flags|=boost::regex::no_mod_m;
        if (options & NSRegularExpressionCaseInsensitive) flags|=boost::regex::icase;
        result->_regex->assign(wide,flags);
        return result;
    } catch (const std::exception &e) {
        if (error) *error=[NSError errorWithDomain:@"Nextpad.FunctionListRegex" code:1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithUTF8String:e.what()]}];
        return nil;
    }
}
- (void)enumerateMatchesInString:(NSString *)string options:(NSMatchingOptions)options range:(NSRange)range usingBlock:(void (^)(NSTextCheckingResult *,NSMatchingFlags,BOOL *))block {
    if (range.location>string.length || range.length>string.length-range.location) return;
    NSString *part=[string substringWithRange:range];
    NSData *data=[part dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    std::wstring wide(data.length/sizeof(wchar_t),0);
    memcpy(wide.data(),data.bytes,data.length);
    std::vector<NSUInteger> offsets(wide.size()+1);
    for (size_t i=0;i<wide.size();i++) offsets[i+1]=offsets[i]+(wide[i]>=0x10000?2:1);
    try {
        for (boost::wsregex_iterator i(wide.begin(),wide.end(),*_regex),end;i!=end;++i) {
            const auto &match=*i;
            NSMutableArray *ranges=[NSMutableArray new];
            for (size_t n=0;n<match.size();n++) {
                if (!match[n].matched) [ranges addObject:[NSValue valueWithRange:NSMakeRange(NSNotFound,0)]];
                else {
                    size_t a=(size_t)std::distance(wide.cbegin(),match[n].first),b=(size_t)std::distance(wide.cbegin(),match[n].second);
                    [ranges addObject:[NSValue valueWithRange:NSMakeRange(range.location+offsets[a],offsets[b]-offsets[a])]];
                }
            }
            NppParserMatch *result=[NppParserMatch new];result.ranges=ranges;
            BOOL stop=NO;block(result,0,&stop);if(stop)break;
        }
    } catch (const std::exception &e) { NSLog(@"Function List regex failed: %s",e.what()); }
}
- (NSTextCheckingResult *)firstMatchInString:(NSString *)string options:(NSMatchingOptions)options range:(NSRange)range {
    __block NSTextCheckingResult *result=nil;
    [self enumerateMatchesInString:string options:options range:range usingBlock:^(NSTextCheckingResult *match,NSMatchingFlags flags,BOOL *stop){result=match;*stop=YES;}];
    return result;
}
@end
