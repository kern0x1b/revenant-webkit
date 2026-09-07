/* Shared between app/rev-webview-host.m (the WAKWindow/WebView hosting
 * implementation) and app/rev-browser-chrome.m (the Safari-look-alike chrome
 * built around it), so the chrome can drive the host and hear back from it
 * without either file needing the other's full interface. Left unused (and
 * harmless) by the standalone rev-webview-host.m test harness build. */

#import <UIKit/UIKit.h>
@class WebView;

@protocol RevWebViewHostDelegate <NSObject>
@optional
- (void)webViewHost:(id)host didStartLoadWithURLString:(NSString *)urlString;
- (void)webViewHost:(id)host didUpdateProgress:(double)progress;
- (void)webViewHost:(id)host didUpdateTitle:(NSString *)title;
- (void)webViewHost:(id)host didUpdateURLString:(NSString *)urlString canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)webViewHost:(id)host didFinishLoadWithURLString:(NSString *)urlString canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)webViewHost:(id)host didFailLoadWithError:(NSError *)error;
- (void)webViewHost:(id)host didScrollToOffsetY:(CGFloat)offsetY tracking:(BOOL)tracking;
@end

@protocol RevWebViewHostControlling <NSObject>
- (void)setHostDelegate:(id<RevWebViewHostDelegate>)delegate;
- (id<RevWebViewHostDelegate>)hostDelegate;
/* Must be called before the view loads (i.e. right after -init) - see the
 * standalone harness's own -loadView for the default it replaces. */
- (void)setEmbeddedContentFrame:(CGRect)frame;
/* The URL the host loads on its own in -viewDidLoad. Set before the view
 * loads (right after -init) to hand the page in as a parameter, instead of
 * the standalone harness's /tmp/rev-url.txt default. */
- (void)setStartURLString:(NSString *)urlString;
- (void)loadURLString:(NSString *)urlString;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
- (WebView *)webView;
@end
