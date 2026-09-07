/* Minimal cross-file class declaration for RevWebViewHostViewController,
 * imported only by app/rev-browser-chrome.m (never by app/rev-webview-host.m
 * itself, which declares the real, fuller @interface for this same class -
 * two @interface blocks for one class name in one translation unit is a
 * compile error, so this one has to stay out of that file). A bare @class
 * forward declaration is not enough here: without a known superclass, the
 * compiler resolves -init against the wrong candidate found elsewhere in the
 * global method pool instead of UIViewController's. */

#import "RevWebViewHostEmbedding.h"

@interface RevWebViewHostViewController : UIViewController <RevWebViewHostControlling>
@end
