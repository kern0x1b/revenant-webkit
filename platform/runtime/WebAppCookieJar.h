/*
 * Cookies that survive a relaunch, and belong to this application.
 *
 * Two facts about NSHTTPCookieStorage on this device make the ordinary answer —
 * "CFNetwork persists cookies, so do nothing" — the wrong one:
 *
 *  1. A session cookie is never written to disk. That is correct for a browser,
 *     where a session ends when the window closes, and wrong for an application,
 *     where the session is the installation. A wrapped app whose sign-in lives
 *     in a session cookie asks the user to log in on every launch, and nothing
 *     else about it feeling like an application matters after that.
 *
 *  2. The jar is shared. These bundles are installed in /Applications and get no
 *     container of their own, so NSHomeDirectory() is /var/mobile for every one
 *     of them and for MobileSafari — one Cookies.binarycookies between the lot.
 *     Two packaged apps cannot hold two accounts on the same site, and clearing
 *     one clears Safari.
 *
 * So the embedder owns the durability, exactly as it already owns the HTTP
 * cache's. On launch this class reads its own file and puts those cookies into
 * the shared jar; whenever the jar changes it writes back the ones belonging to
 * this application's hosts. The shared jar remains what the engine and
 * ModernTLSURLProtocol read and write — nothing is intercepted, and there is no
 * second cookie implementation to disagree with the first.
 *
 * The file is <storage>/cookies.plist, where <storage> is
 * +[WebAppManifest storageDirectory] and therefore already per-application.
 */

#import <Foundation/Foundation.h>

@interface WebAppCookieJar : NSObject

/* Loads this application's cookies into the shared storage and starts watching
 * it for changes. Call once, before the first request goes out — a cookie that
 * arrives after the request that needed it is a login screen. */
+ (void)start;

/* Writes the jar out now. Called for you when the cookies change and when the
 * application is backgrounded or terminated; worth calling directly only at a
 * point the application knows is significant, such as immediately after a
 * sign-in has completed. */
+ (void)persist;

/* Forgets everything this application stored, in memory and on disk — a sign-out
 * that actually signs out, and one that does not touch any other application's
 * cookies for the same site. */
+ (void)clear;

@end
