/* See WebAppManifest.h. */

#import "WebAppManifest.h"
#import "../../app/ModernTLSURLProtocol.h"
#import <WebKitLegacy/WebView.h>
#import <WebKitLegacy/WebViewPrivate.h>

static NSDictionary *gManifest;
static BOOL gLoaded;

@implementation WebAppManifest

+ (BOOL)loadManifest
{
    if (gLoaded)
        return gManifest != nil;
    gLoaded = YES;

    NSString *path = [[NSBundle mainBundle] pathForResource:@"WebApp" ofType:@"plist"];
    if (!path)
        return NO;
    /* -dictionaryWithContentsOfFile: rather than NSJSONSerialization, and a
     * binary plist rather than the JSON the manifest is authored in, because
     * this call has no error path to get wrong: a file that is missing, damaged
     * or the wrong shape all arrive here as nil. The generator is the only thing
     * that ever writes this file, so a parse failure is a build bug, not a
     * runtime condition to recover from. */
    gManifest = [[NSDictionary dictionaryWithContentsOfFile:path] retain];
    return gManifest != nil;
}

static id manifestValue(NSString *key)
{
    [WebAppManifest loadManifest];
    return [gManifest objectForKey:key];
}

+ (NSString *)name
{
    return manifestValue(@"Name");
}

+ (NSURL *)startURL
{
    NSString *text = manifestValue(@"StartURL");
    return [text length] ? [NSURL URLWithString:text] : nil;
}

+ (UIColor *)backgroundColor
{
    NSArray *components = manifestValue(@"BackgroundColor");
    if ([components count] != 3)
        return [UIColor whiteColor];
    return [UIColor colorWithRed:[[components objectAtIndex:0] floatValue]
                           green:[[components objectAtIndex:1] floatValue]
                            blue:[[components objectAtIndex:2] floatValue]
                           alpha:1.0];
}

/* A host is inside the application if it is one of the named hosts or a
 * sub-domain of one. The dot matters: without it "notthreads.com" ends with
 * "threads.com" and a phishing page would be treated as part of the app —
 * which, once there is a native object in the page, is not a cosmetic mistake. */
static BOOL hostMatches(NSString *host, NSString *named)
{
    if ([host caseInsensitiveCompare:named] == NSOrderedSame)
        return YES;
    NSString *suffix = [@"." stringByAppendingString:named];
    return [host length] > [suffix length]
        && [[host substringFromIndex:[host length] - [suffix length]]
            caseInsensitiveCompare:suffix] == NSOrderedSame;
}

+ (BOOL)isInternalURL:(NSURL *)url
{
    NSString *host = [url host];
    if (![host length])
        return NO;
    for (NSString *named in manifestValue(@"InternalHosts")) {
        if (hostMatches(host, named))
            return YES;
    }
    return NO;
}

+ (BOOL)opensExternalLinksInSafari
{
    return [manifestValue(@"OpenExternalLinksInSafari") boolValue];
}

+ (void)applyNetworkPolicy
{
    NSArray *shell = manifestValue(@"ShellHosts");
    if ([shell count])
        [ModernTLSURLProtocol setShellCacheFirstEnabled:YES forHosts:shell];

    NSArray *precache = manifestValue(@"PrecacheURLs");
    if ([precache count])
        [ModernTLSURLProtocol precacheURLs:precache];
}

+ (void)applyUserAgentToWebView:(WebView *)webView
{
    NSString *literal = manifestValue(@"UserAgentString");
    if ([literal length]) {
        [webView setCustomUserAgent:literal];
        return;
    }
    NSString *product = manifestValue(@"UserAgentProductVersion");
    if (![product length])
        return;
    [webView _setBrowserUserAgentProductVersion:product
                                   buildVersion:manifestValue(@"UserAgentBuildVersion")
                                  bundleVersion:manifestValue(@"UserAgentBundleVersion")];
}

/* Reading the injected files once and keeping them. They are a few kilobytes and
 * a wrapped application navigates within itself constantly, so the alternative
 * is a file read on every page. */
static NSString *bundledText(NSString *name)
{
    static NSMutableDictionary *cache;
    if (![name length])
        return nil;
    if (!cache)
        cache = [[NSMutableDictionary alloc] init];
    NSString *text = [cache objectForKey:name];
    if (text)
        return [text length] ? text : nil;

    NSString *path = [[NSBundle mainBundle] pathForResource:
        [name stringByDeletingPathExtension] ofType:[name pathExtension]];
    text = path ? [NSString stringWithContentsOfFile:path
        encoding:NSUTF8StringEncoding error:NULL] : nil;
    /* An empty string stands for "looked, found nothing", so a missing file costs
     * one lookup rather than one per navigation. */
    [cache setObject:text ?: @"" forKey:name];
    return [text length] ? text : nil;
}

/* A string as a JavaScript literal. The stylesheet is arbitrary text arriving in
 * the middle of a script, so it is quoted properly rather than wrapped in quotes
 * and hoped over: a single apostrophe in a CSS comment would otherwise end the
 * literal and turn the rest of the stylesheet into syntax errors. */
static NSString *javaScriptLiteral(NSString *text)
{
    NSMutableString *quoted = [NSMutableString stringWithString:@"\""];
    NSUInteger length = [text length];
    for (NSUInteger at = 0; at < length; at++) {
        unichar character = [text characterAtIndex:at];
        switch (character) {
        case '"':  [quoted appendString:@"\\\""]; break;
        case '\\': [quoted appendString:@"\\\\"]; break;
        case '\n': [quoted appendString:@"\\n"]; break;
        case '\r': [quoted appendString:@"\\r"]; break;
        /* U+2028 and U+2029 are line terminators to a JavaScript parser and
         * ordinary characters to everything else, so a stylesheet that contains
         * one would break the script without looking as though it could. */
        case 0x2028: [quoted appendString:@"\\u2028"]; break;
        case 0x2029: [quoted appendString:@"\\u2029"]; break;
        default:
            if (character < 0x20)
                [quoted appendFormat:@"\\u%04x", character];
            else
                [quoted appendFormat:@"%C", character];
        }
    }
    [quoted appendString:@"\""];
    return quoted;
}

+ (void)injectIntoWebView:(WebView *)webView forURL:(NSURL *)url
{
    /* Never against a page this application does not own. The injected script in
     * particular runs with the page's own authority, and handing it to whatever a
     * link led to is handing it to a stranger. */
    if (![self isInternalURL:url])
        return;

    NSString *style = bundledText(manifestValue(@"InjectStyleSheet"));
    if ([style length]) {
        /* Appended to <head> as a real stylesheet rather than pushed through
         * WebPreferences' user stylesheet URL, because the preference takes a
         * file: URL and applies it to every document in the process, including
         * the ones on hosts checked against above. */
        NSString *script = [NSString stringWithFormat:
            @"(function(){var s=document.getElementById('webapp-chrome');"
             "if(!s){s=document.createElement('style');s.id='webapp-chrome';"
             "(document.head||document.documentElement).appendChild(s);}"
             "s.textContent=%@;})()", javaScriptLiteral(style)];
        [webView stringByEvaluatingJavaScriptFromString:script];
    }

    NSString *code = bundledText(manifestValue(@"InjectScript"));
    if ([code length])
        [webView stringByEvaluatingJavaScriptFromString:code];
}

+ (NSString *)storageDirectory
{
    static NSString *directory;
    if (directory)
        return directory;

    NSString *library = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,
        NSUserDomainMask, YES) lastObject];
    NSString *identifier = [[NSBundle mainBundle] bundleIdentifier] ?: @"LegacyWebApp";
    directory = [[[library stringByAppendingPathComponent:@"WebKitStorage"]
        stringByAppendingPathComponent:identifier] retain];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:NULL];
    return directory;
}

@end
