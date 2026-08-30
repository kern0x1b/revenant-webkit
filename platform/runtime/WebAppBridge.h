/*
 * The object a wrapped site can talk to, and the only one.
 *
 * WebKitLegacy installs an Objective-C object into a page's global scope and
 * lets script call its methods. What the header for that facility claims - that
 * nothing is exported unless you ask - is not what the code does: ObjcClass::
 * methodNamed() walks the class and every superclass up to NSObject and offers
 * every selector it finds, skipping one only if the class says to. A bridge that
 * does not say so hands the page -release, -dealloc and -performSelector:.
 *
 * So this class denies everything and permits by name, and the permitted list is
 * the whole of its API surface. Adding a method here is not enough to expose it;
 * it has to be named in +isSelectorExcludedFromWebScript: as well.
 */

#import <Foundation/Foundation.h>

@class WebFrame;
@class WebView;

@interface WebAppBridge : NSObject

/* Install this bridge into a frame's global scope as `window.legacyApp`. Call
 * from -webView:didClearWindowObject:forFrame:, which is the only moment the
 * global object is known to be fresh, and only for a frame showing a page this
 * application stands in for - the same delegate call arrives for a page we have
 * merely navigated to, and a stranger's page has no business holding this.
 *
 * The frame is required, not read back from webView.mainFrameURL: that call
 * arrives at the moment the frame's own global object is replaced, which can
 * be before -mainFrameURL has settled on the new document (it can still read
 * the previous page, or about:blank) - the frame passed to this same delegate
 * call is the one thing guaranteed to know which load this is. */
+ (void)installInWebView:(WebView *)webView forFrame:(WebFrame *)frame;

/* What the page last declared as its tab bar, as an array of dictionaries with
 * `label` and `href` keys, or nil if it has declared none. Read from the main
 * thread; the declaration arrives on the web thread and is published here. */
+ (NSArray *)declaredTabs;

/* Tell the page that the person chose tab `index` of what it declared. The page
 * is asked to activate its own element rather than being sent to a URL: a URL
 * is a fresh load, which on this device costs seconds, while the element lets
 * the site's own router do what it would have done for a tap. */
+ (void)activateTab:(NSUInteger)index inWebView:(WebView *)webView;

@end
