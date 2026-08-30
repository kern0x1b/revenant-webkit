#import <Foundation/Foundation.h>

@class WebView;

@interface WebAppBytecodeCache : NSObject

+ (BOOL)isEnabled;
+ (void)install;
+ (void)flush;
+ (void)flushAfterDelay;
+ (void)cancelDelayedFlush;
+ (void)clear;

@end
