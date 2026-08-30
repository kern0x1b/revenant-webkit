/*
 * The packaged application's own description of itself.
 *
 * One binary serves every packaged app; what makes a bundle Threads rather than
 * Instagram is WebApp.plist beside the executable. platform/package.py compiles
 * it from the authored JSON manifest, so everything here is already decided: the
 * hosts are lower-case, the colour is three floats, and every optional key is
 * present with a definite value. Nothing in this class re-decides what a missing
 * key meant, because that decision would then exist in two places and drift.
 *
 * See platform/package.py for the authoring format, and the manifests in
 * platform/apps for real ones.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class WebView;

@interface WebAppManifest : NSObject

/* Reads WebApp.plist out of the main bundle. Not called +load: that name
 * belongs to the Objective-C runtime, which would call it at image load time,
 * before anything here is ready to answer. Answers NO when there is none,
 * which is what an unpackaged development build looks like — the caller then
 * falls back to its own start URL. Reading twice is free; the document is
 * parsed once. */
+ (BOOL)loadManifest;

+ (NSString *)name;
+ (NSURL *)startURL;

/* The colour behind the page, before the first tile is painted and in whatever
 * the scroll view exposes past the end of the document. White is a browser's
 * answer; an application's is the colour of its own interface, and the launch
 * image the generator writes is this same colour, so the two meet without a
 * flash between them. */
+ (UIColor *)backgroundColor;

/* Whether a URL belongs to this application. Everything else is somewhere else,
 * and what happens to it is +opensExternalLinksInSafari. Sub-domains of a named
 * host count: naming www.threads.com admits static.threads.com but never
 * notthreads.com, which is what the leading-dot test below is for. */
+ (BOOL)isInternalURL:(NSURL *)url;
+ (BOOL)opensExternalLinksInSafari;

/* Turns on ModernTLSURLProtocol's cache-first shell policy for the manifest's
 * hosts and queues its precache list. Safe to call on every launch: a stored URL
 * inside the staleness bound is skipped. */
+ (void)applyNetworkPolicy;

/* The user agent, applied by asking WebKit to build one — a hand-written string
 * got threads.com to serve an empty shell instead of the site, so the manifest
 * carries the three version numbers rather than the sentence. A manifest that
 * really does need a literal string sets user_agent_string and gets it. */
+ (void)applyUserAgentToWebView:(WebView *)webView;

/* The manifest's stylesheet and script, run against a frame that has finished
 * loading. Answers nothing and does nothing when the manifest injects neither,
 * and never runs against a document on a host this application does not own. */
+ (void)injectIntoWebView:(WebView *)webView forURL:(NSURL *)url;

/* Everything this application stores, under one directory of its own:
 * <Library>/WebKitStorage/<bundle identifier>. The bundle identifier is in the
 * path because on this device every packaged app shares one home directory —
 * they are installed in /Applications, which gets no container of its own, so
 * NSHomeDirectory() is /var/mobile for all of them. Without the identifier,
 * Threads and Instagram would share a localStorage database. */
+ (NSString *)storageDirectory;

@end
