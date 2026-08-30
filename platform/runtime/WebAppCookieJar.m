/* See WebAppCookieJar.h. */

#import "WebAppCookieJar.h"
#import "WebAppManifest.h"
#import <UIKit/UIKit.h>

/* The same file main.m writes to. Launched from SpringBoard there is no terminal
 * and syslogd on this device is not reliably running, so a cookie question is
 * answered by /tmp/browser.log or it is not answered at all. */
static void jarLog(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[[NSString alloc] initWithFormat:format arguments:arguments] autorelease];
    va_end(arguments);
    FILE *file = fopen("/tmp/browser.log", "a");
    if (!file)
        return;
    fprintf(file, "[cookies] %s\n", [line UTF8String]);
    fclose(file);
}

/* How long a cookie that carries no expiry of its own is kept.
 *
 * A session cookie has no lifetime in the protocol, so persisting one means
 * inventing a lifetime for it, and the honest number is "about as long as a
 * person expects to stay signed in to an app they have not opened". Ninety days
 * is that, and it also bounds the damage of the other direction: a server that
 * has invalidated the session answers with a fresh Set-Cookie or a redirect to
 * sign-in, and the stale one is replaced rather than accumulating. */
static const NSTimeInterval kSessionCookieLifetime = 90 * 24 * 60 * 60;

/* Writes are coalesced: a single page load can set a dozen cookies, and each one
 * posts its own change notification. */
static const NSTimeInterval kWriteDelay = 2.0;

static NSString *gPath;
static BOOL gStarted;

@interface WebAppCookieJar (Private)
+ (void)cookiesChanged:(NSNotification *)notification;
+ (void)applicationLeaving:(NSNotification *)notification;
@end

@implementation WebAppCookieJar

static NSString *jarPath(void)
{
    if (!gPath)
        gPath = [[[WebAppManifest storageDirectory]
            stringByAppendingPathComponent:@"cookies.plist"] retain];
    return gPath;
}

/* Does this cookie belong to this application?
 *
 * A cookie's domain is either a host name or that host name with a leading dot,
 * meaning "and every sub-domain". The manifest's hosts are plain names. So the
 * test is the manifest's own +isInternalURL: applied to the cookie's domain,
 * with the leading dot taken off first and a scheme put on so there is a URL to
 * hand it. Going through the manifest rather than re-implementing the suffix
 * rule here is deliberate: the dotted-suffix test is the thing that keeps
 * notthreads.com out, and it should exist once. */
static BOOL cookieBelongsToApp(NSHTTPCookie *cookie)
{
    NSString *domain = [cookie domain];
    if ([domain hasPrefix:@"."])
        domain = [domain substringFromIndex:1];
    if (![domain length])
        return NO;
    return [WebAppManifest isInternalURL:
        [NSURL URLWithString:[@"https://" stringByAppendingString:domain]]];
}

/* The cookie as something a property list can hold.
 *
 * -[NSHTTPCookie properties] is passed back to +cookieWithProperties: unchanged
 * on the way in, so the round trip keeps whatever CFNetwork put there — the
 * HttpOnly flag among them, which has no public key on this release and would be
 * lost by any dictionary built field by field. What cannot survive is the
 * NSURL under NSHTTPCookieOriginURL, which is not a property list type; it is
 * dropped, and NSHTTPCookieDomain is always present alongside it, which is what
 * +cookieWithProperties: needs. */
static NSDictionary *propertiesForStorage(NSHTTPCookie *cookie)
{
    NSDictionary *properties = [cookie properties];
    NSMutableDictionary *stored = [NSMutableDictionary dictionaryWithCapacity:
        [properties count] + 1];
    for (NSString *key in properties) {
        id value = [properties objectForKey:key];
        if ([value isKindOfClass:[NSString class]]
            || [value isKindOfClass:[NSNumber class]]
            || [value isKindOfClass:[NSDate class]])
            [stored setObject:value forKey:key];
    }
    if (![stored objectForKey:NSHTTPCookieDomain])
        return nil;
    if (![stored objectForKey:NSHTTPCookiePath])
        [stored setObject:@"/" forKey:NSHTTPCookiePath];
    return stored;
}

+ (void)start
{
    if (gStarted)
        return;
    gStarted = YES;

    NSArray *stored = [NSArray arrayWithContentsOfFile:jarPath()];
    NSDate *now = [NSDate date];
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSUInteger restored = 0;

    for (NSDictionary *entry in stored) {
        if (![entry isKindOfClass:[NSDictionary class]])
            continue;
        NSMutableDictionary *properties = [[entry mutableCopy] autorelease];

        /* Two lifetimes, kept apart. A cookie the server dated keeps its own
         * date and is dropped once it passes. A cookie the server left as a
         * session cookie was written here with the moment it was first stored,
         * under a key of ours, and gets kSessionCookieLifetime from then — and
         * it goes back into the jar with no expiry, so the engine and the site
         * both still see it as the session cookie it is. */
        NSDate *expires = [properties objectForKey:NSHTTPCookieExpires];
        if ([expires isKindOfClass:[NSDate class]]) {
            if ([expires timeIntervalSinceDate:now] <= 0)
                continue;
        } else {
            NSDate *first = [properties objectForKey:@"WebAppFirstStored"];
            if (![first isKindOfClass:[NSDate class]])
                continue;
            if (-[first timeIntervalSinceDate:now] > kSessionCookieLifetime)
                continue;
        }
        [properties removeObjectForKey:@"WebAppFirstStored"];

        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:properties];
        /* +cookieWithProperties: answers nil for a dictionary it cannot make a
         * cookie out of, which here means the file was written by an older
         * layout or damaged. One unusable entry is not a reason to lose the
         * rest of the sign-in. */
        if (!cookie)
            continue;
        [storage setCookie:cookie];
        restored++;
    }

    NSNotificationCenter *centre = [NSNotificationCenter defaultCenter];
    [centre addObserver:self selector:@selector(cookiesChanged:)
                   name:NSHTTPCookieManagerCookiesChangedNotification object:storage];
    /* Backgrounding and termination are the two moments the system gives notice
     * of. The third way this process ends is jetsam, which gives none — which is
     * why the change notification above exists rather than only these two. */
    [centre addObserver:self selector:@selector(applicationLeaving:)
                   name:UIApplicationDidEnterBackgroundNotification object:nil];
    [centre addObserver:self selector:@selector(applicationLeaving:)
                   name:UIApplicationWillTerminateNotification object:nil];

    jarLog(@"restored %lu of %lu stored, from %@", (unsigned long)restored,
        (unsigned long)[stored count], jarPath());
}

+ (void)cookiesChanged:(NSNotification *)notification
{
    /* This notification arrives on whichever thread set the cookie, and
     * ModernTLSURLProtocol sets them from a global dispatch queue whose run loop
     * is never run — a -performSelector:afterDelay: scheduled there is scheduled
     * onto nothing and the jar would never be written. The main run loop is the
     * one that is certainly running. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSObject cancelPreviousPerformRequestsWithTarget:self
            selector:@selector(persist) object:nil];
        [self performSelector:@selector(persist) withObject:nil afterDelay:kWriteDelay];
    });
}

+ (void)applicationLeaving:(NSNotification *)notification
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(persist) object:nil];
    [self persist];
}

+ (void)persist
{
    /* The moment a session cookie was first seen, kept across writes so that its
     * ninety days run from when it arrived rather than from the last time
     * anything else in the jar changed. */
    static NSMutableDictionary *firstSeen;
    if (!firstSeen)
        firstSeen = [[NSMutableDictionary alloc] init];

    NSDate *now = [NSDate date];
    NSMutableArray *entries = [NSMutableArray array];
    /* Rebuilt rather than added to. A site that re-issues its session cookie
     * with a new value on every request would otherwise leave one dead entry per
     * request in the table for the lifetime of the process. */
    NSMutableDictionary *stillPresent = [NSMutableDictionary dictionary];

    for (NSHTTPCookie *cookie in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies]) {
        if (!cookieBelongsToApp(cookie))
            continue;
        NSDictionary *properties = propertiesForStorage(cookie);
        if (!properties)
            continue;

        NSDate *expires = [cookie expiresDate];
        if (expires && [expires timeIntervalSinceDate:now] <= 0)
            continue;

        if (!expires) {
            /* Keyed by everything that makes one session cookie a different
             * cookie from another, so that a re-issued cookie of the same name
             * on the same host restarts its own clock. */
            NSString *identity = [NSString stringWithFormat:@"%@\n%@\n%@\n%@",
                [cookie domain], [cookie path], [cookie name], [cookie value]];
            NSDate *first = [firstSeen objectForKey:identity];
            if (!first)
                first = now;
            [stillPresent setObject:first forKey:identity];
            NSMutableDictionary *dated = [[properties mutableCopy] autorelease];
            [dated setObject:first forKey:@"WebAppFirstStored"];
            properties = dated;
        }
        [entries addObject:properties];
    }

    [firstSeen setDictionary:stillPresent];

    /* Atomically, because the alternative is a half-written jar on a device that
     * is killed for memory in the middle of a write, and a half-written jar is a
     * sign-out. */
    if (![entries writeToFile:jarPath() atomically:YES])
        jarLog(@"could not write %@", jarPath());
    else
        jarLog(@"wrote %lu", (unsigned long)[entries count]);
}

+ (void)clear
{
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *cookie in [[[storage cookies] copy] autorelease]) {
        if (cookieBelongsToApp(cookie))
            [storage deleteCookie:cookie];
    }
    [[NSFileManager defaultManager] removeItemAtPath:jarPath() error:NULL];
}

@end
