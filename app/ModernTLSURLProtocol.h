/* See ModernTLSURLProtocol.m. */

#import <Foundation/Foundation.h>

@interface ModernTLSURLProtocol : NSURLProtocol
/* Registers the protocol and points it at the certificate authorities in the
 * application bundle. Returns NO if those are missing. */
+ (BOOL)install;

/* ---------------------------- the app-shell policy ----------------------------
 *
 * A cache-first strategy for the shell of a wrapped web application — the
 * document and the scripts, styles and fonts that draw its interface — in the
 * shape a Service Worker would give it, for an engine that has no Service Worker.
 * A stored shell response is served without touching the network even when HTTP
 * considers it stale, and refreshed behind the page.
 *
 * This is a deliberate departure from RFC 9111 and it is off unless it is turned
 * on. The reasoning, the bound on how stale is too stale, and the rules for what
 * counts as shell are all in the .m file, in the section that carries this name.
 */

/* Turns the policy on for the named hosts — the origins the wrapped application
 * is made of, host names only, case-insensitive. Passing NO, or an empty list,
 * turns it off again and restores standard behaviour on the spot: there is no
 * separate store to flush, only a rule that stops being applied. */
+ (void)setShellCacheFirstEnabled:(BOOL)enabled forHosts:(NSArray *)hosts;
+ (BOOL)shellCacheFirstEnabled;

/* Names URLs (NSURL or NSString) that are shell whatever the classifier would
 * make of them — for an application whose shell it cannot see, a script served as
 * text/plain being the usual case. Additive, and independent of the hosts list,
 * which still has to admit them. */
+ (void)declareShellURLs:(NSArray *)urls;

/* Fetches each URL in the background and stores what comes back, so that a
 * packaged application can warm its shell at install time and be instant on the
 * first launch rather than the second. The URLs are declared shell. One already
 * stored and inside the staleness bound is skipped, so calling this on every
 * launch is cheap. Returns at once; the work is queued behind the page. */
+ (void)precacheURLs:(NSArray *)urls;
@end
