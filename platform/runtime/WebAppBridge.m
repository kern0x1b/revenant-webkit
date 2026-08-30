#import "WebAppBridge.h"
#import "WebAppManifest.h"

#import <WebKitLegacy/WebDataSource.h>
#import <WebKitLegacy/WebFrame.h>
#import <WebKitLegacy/WebScriptObject.h>
#import <WebKitLegacy/WebView.h>

/* The page's half of the arrangement. It is injected rather than expected of the
 * site, so a site that knows nothing about us still works: the script looks for
 * a tab bar in the markup, describes it to the application, and hides it. If it
 * finds nothing, it says nothing and the application draws no tab bar - which is
 * the right outcome for a page that has none, and for a site whose markup has
 * changed under us. */
static NSString * const kBridgeScript = @"(function () {\n"
    "  if (!window.legacyApp || window.legacyApp._installed) return;\n"
    "  window.legacyApp._installed = true;\n"
    "\n"
    "  /* A tab bar is a nav, or a role=tablist, pinned to the bottom of the\n"
    "   * viewport. Anchored on layout and role rather than on class names,\n"
    "   * because class names are generated and change without notice. */\n"
    "  function findTabBar() {\n"
    "    var candidates = document.querySelectorAll('nav, [role=\\\"tablist\\\"]');\n"
    "    var best = null, bestArea = 0;\n"
    "    for (var i = 0; i < candidates.length; i++) {\n"
    "      var element = candidates[i];\n"
    "      var box = element.getBoundingClientRect();\n"
    "      if (box.width < window.innerWidth * 0.8) continue;\n"
    "      if (box.height < 30 || box.height > 90) continue;\n"
    "      if (box.bottom < window.innerHeight - 20) continue;\n"
    "      var area = box.width * box.height;\n"
    "      if (area > bestArea) { best = element; bestArea = area; }\n"
    "    }\n"
    "    return best;\n"
    "  }\n"
    "\n"
    "  function describe(bar) {\n"
    "    var items = bar.querySelectorAll('a[href], [role=\\\"tab\\\"], button');\n"
    "    var described = [];\n"
    "    window.legacyApp._elements = [];\n"
    "    for (var i = 0; i < items.length; i++) {\n"
    "      var item = items[i];\n"
    "      var box = item.getBoundingClientRect();\n"
    "      if (box.width <= 0 || box.height <= 0) continue;\n"
    "      var label = (item.getAttribute('aria-label') || item.innerText || '').trim();\n"
    "      described.push({ label: label.slice(0, 24),\n"
    "                       href: item.getAttribute('href') || '' });\n"
    "      window.legacyApp._elements.push(item);\n"
    "    }\n"
    "    return described;\n"
    "  }\n"
    "\n"
    "  /* Activating means clicking what the site would have had us click, so the\n"
    "   * site's own router handles it. Setting location instead would be a whole\n"
    "   * fresh load, which on this device is seconds. */\n"
    "  window.legacyApp._activate = function (index) {\n"
    "    var element = (window.legacyApp._elements || [])[index];\n"
    "    if (!element) return false;\n"
    "    element.click();\n"
    "    return true;\n"
    "  };\n"
    "\n"
    "  function offer() {\n"
    "    var bar = findTabBar();\n"
    "    if (!bar) return false;\n"
    "    var described = describe(bar);\n"
    "    if (described.length < 2) return false;\n"
    "    bar.style.display = 'none';\n"
    "    window.legacyApp.declareTabBar(JSON.stringify(described));\n"
    "    return true;\n"
    "  }\n"
    "\n"
    "  /* A tab bar that is drawn by script does not exist at first paint, so ask\n"
    "   * again a few times and then stop rather than watching forever. */\n"
    "  var attempts = 0;\n"
    "  (function again() {\n"
    "    if (offer() || ++attempts > 12) return;\n"
    "    setTimeout(again, 500);\n"
    "  })();\n"
    "})();";

@implementation WebAppBridge

static NSArray *gDeclaredTabs;

/* Deny by default. This is the entire exported surface, and a method that is not
 * listed here cannot be called from the page however public it looks in the
 * header - which is the point, since without this every selector inherited from
 * NSObject would be callable too. */
+ (BOOL)isSelectorExcludedFromWebScript:(SEL)selector
{
    return selector != @selector(declareTabBar:);
}

/* Without this the page would have to call `declareTabBar_`, because the bridge
 * mangles a colon into an underscore. */
+ (NSString *)webScriptNameForSelector:(SEL)selector
{
    if (selector == @selector(declareTabBar:))
        return @"declareTabBar";
    return nil;
}

/* No properties, for the same reason as the selectors above. */
+ (BOOL)isKeyExcludedFromWebScript:(const char *)name
{
    return YES;
}

/* Called by the page, on the web thread. The argument is JSON rather than a
 * JavaScript array because the bridge would otherwise hand us WebScriptObjects
 * whose contents have to be read back one -webScriptValueAtIndex: at a time,
 * each of which is another trip across. */
- (void)declareTabBar:(NSString *)json
{
    if (![json isKindOfClass:[NSString class]] || ![json length])
        return;

    NSData *encoded = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:encoded options:0 error:&error];
    if (![parsed isKindOfClass:[NSArray class]])
        return;

    /* Everything in here came from a web page, so nothing in it is trusted to be
     * the shape it claims. Keep the entries that are, drop the rest. */
    NSMutableArray *tabs = [NSMutableArray array];
    for (id entry in (NSArray *)parsed) {
        if (![entry isKindOfClass:[NSDictionary class]])
            continue;
        NSString *label = [(NSDictionary *)entry objectForKey:@"label"];
        NSString *href = [(NSDictionary *)entry objectForKey:@"href"];
        if (![label isKindOfClass:[NSString class]])
            continue;
        [tabs addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            label, @"label",
            [href isKindOfClass:[NSString class]] ? href : @"", @"href", nil]];
    }
    if ([tabs count] < 2)
        return;

    /* The declaration arrives on the web thread and is read from the main one. */
    NSArray *published = [tabs copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [gDeclaredTabs release];
        gDeclaredTabs = published;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"WebAppBridgeTabsDeclared"
                                                            object:nil];
    });
}

+ (NSArray *)declaredTabs
{
    return gDeclaredTabs;
}

+ (void)installInWebView:(WebView *)webView forFrame:(WebFrame *)frame
{
    /* This delegate call arrives for every frame of every page, including one we
     * have merely navigated to. A stranger's page does not get the bridge.
     *
     * A build with no manifest is the plain browser, which stands in for nobody,
     * so there is no "stranger" to distinguish and every page is treated alike.
     * What that grants is small by construction - the one exported selector
     * takes a JSON string and remembers some labels - and the deny-by-default
     * list above is what keeps it that way.
     *
     * The URL comes from the frame's own data source, not -[webView
     * mainFrameURL]: this delegate call fires the moment the frame's global
     * object is replaced, which can be ahead of -mainFrameURL settling on the
     * new document (it can still read the previous page or about:blank),
     * silently skipping the install on every real navigation. The frame
     * passed in here is the one thing that already knows which load this is:
     * still provisional at this point, so its provisionalDataSource is
     * checked first, falling back to dataSource for the rare call that
     * arrives after commit. */
    NSURL *url = [[frame provisionalDataSource] request].URL ?: [[frame dataSource] request].URL;
    if ([WebAppManifest loadManifest] && url && ![WebAppManifest isInternalURL:url])
        return;

    WebAppBridge *bridge = [[WebAppBridge alloc] init];
    [[webView windowScriptObject] setValue:bridge forKey:@"legacyApp"];
    [bridge release];

    [webView stringByEvaluatingJavaScriptFromString:kBridgeScript];
}

+ (void)activateTab:(NSUInteger)index inWebView:(WebView *)webView
{
    NSString *call = [NSString stringWithFormat:@"legacyApp._activate(%lu)",
        (unsigned long)index];
    [webView stringByEvaluatingJavaScriptFromString:call];
}

@end
