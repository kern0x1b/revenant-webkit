/*
 * Objective-C replacements for PAL's Swift sources.
 *
 * swiftc has no armv7 target, so these classes have to be provided some other
 * way. They are small and the behaviour is well defined, so the Swift is simply
 * reimplemented rather than stubbed out.
 */
#import <Foundation/Foundation.h>

@interface WebPALRegexHelper : NSObject
+ (BOOL)matchPattern:(NSString *)pattern value:(NSString *)value shouldIgnoreCase:(BOOL)shouldIgnoreCase;
@end

@implementation WebPALRegexHelper

+ (BOOL)matchPattern:(NSString *)pattern value:(NSString *)value shouldIgnoreCase:(BOOL)shouldIgnoreCase
{
    if (!pattern || !value)
        return NO;

    NSRegularExpressionOptions options = shouldIgnoreCase ? NSRegularExpressionCaseInsensitive : 0;
    NSError *error = nil;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                               options:options
                                                                                 error:&error];
    if (!expression || error)
        return NO;

    // Swift's `value.contains(expression)` is a search, not a full-string match.
    return [expression numberOfMatchesInString:value
                                       options:0
                                         range:NSMakeRange(0, [value length])] > 0;
}

@end
