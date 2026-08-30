#import <Foundation/Foundation.h>

@class WebView;

@interface WebAppContentBlocker : NSObject

+ (BOOL)isEnabled;
+ (void)installInWebView:(WebView *)webView;
+ (void)removeFromWebView:(WebView *)webView;

@end
