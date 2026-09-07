/*
 * Out-of-process write helper.
 *
 * A non-GET SoundCloud request (like/repost/follow) is refused with a DataDome
 * captcha when it comes from anything but the browser that solved the challenge:
 * the anti-bot binds its cookie to that client's TLS/HTTP fingerprint, so copied
 * headers never satisfy it. The one client that does is our own engine. Running
 * the engine inside the SoundCloud process, though, corrupts the host app's font
 * state and competes for its memory on a 512 MB device. So the write runs here,
 * in a separate process: its own memory, its own CoreText, headless (no render).
 *
 * Given a cookie jar, an HTTP method and a URL, it loads a light same-origin
 * soundcloud.com page (for the origin and CORS), issues the write with fetch()
 * over the engine's HTTP stack, and prints the resulting status. The common case
 * - a warm datadome cookie - needs no display at all. (A cold cookie that draws
 * a captcha is still handled by the in-process challenge path; this helper only
 * replays the request the browser is trusted to make.)
 *
 * Usage (de-risk, no IPC yet):
 *   scfix-writer <cookie-jar-file> <METHOD> <url>
 * cookie-jar-file: lines of "domain\tpath\tname\tvalue" (SC_FullCookieJar format).
 */

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <mach/mach.h>
#import <WebKitLegacy/WebView.h>
#import <WebKitLegacy/WebViewPrivate.h>
#import <WebKitLegacy/WebFrame.h>
#import <WebKitLegacy/WebPreferences.h>
#import <WebKitLegacy/WebPreferencesPrivate.h>
#import <WebKitLegacy/WAKWindow.h>
#import "ModernTLSURLProtocol.h"
#import "RevWasm.h"

extern void WebKitInitialize(void);
extern void WebThreadLock(void);
extern void WebThreadUnlock(void);

#define LOG(fmt, ...) do { fprintf(stderr, "[scfix-writer] " fmt "\n", ##__VA_ARGS__); fflush(stderr); } while (0)

static NSString *gJarPath, *gMethod, *gURL;
static WebView *gWebView;
static WAKWindow *gWindow;
static CALayer *gHostLayer;
static BOOL gFetchFired;
static int gPolls;

// A bare same-origin file: just enough to carry the soundcloud.com origin and its
// cookies to the fetch. The full SPA (which loads the DataDome tag) is too heavy
// for this device even in a separate process, so a warm/solved datadome cookie is
// relied on instead of live tag validation.
static NSString *const kLightPage = @"https://soundcloud.com/robots.txt";

static void installCookies(NSString *path) {
    NSString *jar = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (![jar length]) { LOG("no cookie jar at %s", [path UTF8String]); return; }
    NSHTTPCookieStorage *store = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    [store setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];
    int n = 0;
    for (NSString *line in [jar componentsSeparatedByString:@"\n"]) {
        NSArray *f = [line componentsSeparatedByString:@"\t"];
        if ([f count] < 4) continue;
        NSString *domain = [f objectAtIndex:0], *cpath = [f objectAtIndex:1];
        NSString *name = [f objectAtIndex:2], *value = [f objectAtIndex:3];
        if ([name length] == 0) continue;
        NSDictionary *props = [NSDictionary dictionaryWithObjectsAndKeys:
            domain, NSHTTPCookieDomain, ([cpath length] ? cpath : @"/"), NSHTTPCookiePath,
            name, NSHTTPCookieName, (value ?: @""), NSHTTPCookieValue, nil];
        NSHTTPCookie *c = [NSHTTPCookie cookieWithProperties:props];
        if (c) { [store setCookie:c]; n++; }
    }
    LOG("installed %d cookies", n);
}

static NSString *eval(NSString *js) {
    WebThreadLock();
    NSString *r = [gWebView stringByEvaluatingJavaScriptFromString:js];
    WebThreadUnlock();
    return r;
}

static void fireFetch(void) {
    NSString *js = [NSString stringWithFormat:
        @"(function(){window.__scw='';"
        @"var tok=(document.cookie.match(/oauth_token=([^;]+)/)||[])[1]||'';"
        @"function go(n){return fetch('%@',{method:'%@',credentials:'include',"
        @"headers:{'Authorization':'OAuth '+tok,'Accept':'application/json, text/javascript, */*; q=0.01'}})"
        @".then(function(r){if(r.status>=200&&r.status<300){window.__scw='status:'+r.status;return;}"
        @"return r.text().then(function(b){"
        @"if(r.status===403&&n<1){return new Promise(function(res){setTimeout(res,900);}).then(function(){return go(n+1);});}"
        @"var u='';try{u=(JSON.parse(b)||{}).url||'';}catch(e){}"
        @"window.__scw='status:'+r.status+(u?(' url:'+u):(' body:'+b.slice(0,160)));});});}"
        @"go(0).catch(function(e){window.__scw='err:'+e;});})()",
        gURL, [gMethod uppercaseString]];
    eval(js);
    LOG("fetch fired %s %s", [[gMethod uppercaseString] UTF8String], [gURL UTF8String]);
}

// PROBE mode: load any URL (a DataDome captcha page from our logs - DataDome's
// own CDN, not SoundCloud) and report what its JS environment check trips on, so
// the missing API behind "JavaScript disabled or not working" can be named.
static BOOL gProbeMode;
static void installDiag(void) {
    eval(@"(function(){if(window.__diag)return;window.__diag={errs:[],miss:[]};"
         @"window.onerror=function(m,u,l){window.__diag.errs.push(m+'@'+l);};"
         @"window.addEventListener('unhandledrejection',function(e){var r=e.reason;"
         @"window.__diag.errs.push('rej:'+((r&&(r.stack||r.message))||r));});"
         @"var ce=console.error;console.error=function(){window.__diag.errs.push('cerr:'+Array.prototype.join.call(arguments,' '));if(ce)ce.apply(console,arguments);};"
         @"var P=['Proxy','Reflect','WeakRef','WeakMap','Promise','fetch','Symbol','Intl','crypto','MutationObserver','requestAnimationFrame','Notification','matchMedia','WebAssembly','Worker','OffscreenCanvas','PerformanceObserver','IntersectionObserver','ResizeObserver','structuredClone','BigInt','queueMicrotask','TextEncoder','CSS','PointerEvent'];"
         @"for(var i=0;i<P.length;i++){try{if(typeof window[P[i]]==='undefined')window.__diag.miss.push(P[i]);}catch(e){window.__diag.miss.push(P[i]+'!');}}"
         @"try{var c=document.createElement('canvas');if(!c.getContext('webgl')&&!c.getContext('experimental-webgl'))window.__diag.miss.push('webgl');}catch(e){window.__diag.miss.push('webgl!');}"
         @"try{if(!(crypto&&crypto.subtle))window.__diag.miss.push('crypto.subtle');}catch(e){window.__diag.miss.push('crypto.subtle!');}"
         @"try{if(window.WebAssembly){window.__diag.wasm='pending';"
         @"var ib='AGFzbQEAAAABBwFgAn9/AX8CCwEDZW52A2V4dAAAAwIBAAcHAQNydW4AAQoKAQgAIAAgARAACw==';"
         @"var wb=Uint8Array.from(atob(ib),function(c){return c.charCodeAt(0);});"
         @"window.__diag.extlog='not-called';"
         @"WebAssembly.instantiate(wb,{env:{ext:function(a,b){window.__diag.extlog='called:'+a+','+b;return a*b;}}}).then(function(r){"
         @"window.__diag.wasm='run(6,7)='+r.instance.exports.run(6,7)+' ext='+window.__diag.extlog;})"
         @".catch(function(e){window.__diag.wasm='ERR:'+e;});}else window.__diag.wasm='no-WebAssembly';}catch(e){window.__diag.wasm='EXC:'+e;}"
         @"})()");
}

@interface WriterObserver : NSObject
@end
@implementation WriterObserver
// Install WebAssembly the moment the global object is fresh, before the page's
// own scripts run - a DataDome captcha checks for it during boot.
- (void)webView:(WebView *)sender didClearWindowObject:(id)windowObject forFrame:(WebFrame *)frame {
    if (frame != [sender mainFrame]) return;
    [RevWasm installInWebView:sender forFrame:frame];
}
- (void)webView:(WebView *)sender didCommitLoadForFrame:(WebFrame *)frame {
    if (frame != [sender mainFrame]) return;
    if (gProbeMode) installDiag();
}
- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame {
    if (frame != [sender mainFrame]) return;
    NSString *u = [sender mainFrameURL];
    LOG("page loaded: %s", [u UTF8String]);
    if (gProbeMode) { installDiag(); return; }
    if (gFetchFired) return;
    if ([u rangeOfString:@"soundcloud.com"].location == NSNotFound) return;
    gFetchFired = YES;
    fireFetch();
}
- (void)webView:(WebView *)sender didFailProvisionalLoadWithError:(NSError *)e forFrame:(WebFrame *)frame {
    if (frame == [sender mainFrame]) LOG("page load failed: %s", [[e localizedDescription] UTF8String]);
}
@end

static void probeDump(CFRunLoopTimerRef t, void *info) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *errs = eval(@"(window.__diag?JSON.stringify(window.__diag.errs):'(no diag)')");
    NSString *miss = eval(@"(window.__diag?JSON.stringify(window.__diag.miss):'(no diag)')");
    NSString *title = eval(@"(document.title||'')");
    NSString *bodyText = eval(@"((document.body?document.body.innerText:'')||'').slice(0,300).replace(/\\s+/g,' ')");
    NSString *html = eval(@"((document.documentElement?document.documentElement.outerHTML:'')||'').slice(0,600).replace(/\\s+/g,' ')");
    NSString *scripts = eval(@"(function(){var s=[].map.call(document.querySelectorAll('script[src]'),function(e){return e.src;});return s.join(' | ').slice(0,500);})()");
    NSString *wasmRef = eval(@"(function(){var t=[].map.call(document.querySelectorAll('script'),function(e){return e.textContent||'';}).join('\\n');return (/WebAssembly|\\.wasm|instantiate/.test(t)?'yes':'no')+' iframes:'+document.querySelectorAll('iframe').length;})()");
    NSString *wasm = eval(@"(window.__diag?(window.__diag.wasm||'(none)'):'(no diag)')");
    printf("PROBE-WASM: %s\n", [wasm UTF8String]);
    printf("PROBE-TITLE: %s\n", [title UTF8String]);
    printf("PROBE-MISSING: %s\n", [miss UTF8String]);
    printf("PROBE-ERRORS: %s\n", [errs UTF8String]);
    printf("PROBE-BODY: %s\n", [bodyText UTF8String]);
    printf("PROBE-WASMREF: %s\n", [wasmRef UTF8String]);
    printf("PROBE-SCRIPTS: %s\n", [scripts UTF8String]);
    printf("PROBE-HTML: %s\n", [html UTF8String]);
    fflush(stdout);
    [pool release];
    exit(0);
}

static void poll(CFRunLoopTimerRef t, void *info) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (gFetchFired) {
        NSString *st = eval(@"(window.__scw||'')");
        gPolls++;
        if ([st length]) LOG("poll %d: %s", gPolls, [st UTF8String]);
        if ([st hasPrefix:@"status:"]) {
            printf("SCWRITE:%s\n", [st UTF8String]);
            fflush(stdout);
            LOG("done: %s", [st UTF8String]);
            [pool release];
            exit(0);
        }
        if ([st hasPrefix:@"err:"] || gPolls > 40) {
            printf("SCWRITE:%s\n", [[st length] ? st : @"timeout" UTF8String]);
            fflush(stdout);
            [pool release];
            exit([st hasPrefix:@"err:"] ? 3 : 2);
        }
    }
    [pool release];
}

static void start(CFRunLoopTimerRef t, void *info) {
    LOG("modern TLS: %s", [ModernTLSURLProtocol install] ? "installed" : "unavailable");
    installCookies(gJarPath);
    WebKitInitialize();

    CGRect bounds = CGRectMake(0, 0, 320, 480);
    WebThreadLock();
    gHostLayer = [[CALayer layer] retain];
    [gHostLayer setFrame:bounds];
    gWindow = [[WAKWindow alloc] initWithLayer:gHostLayer];
    [gWindow setScreenSize:bounds.size];
    [gWindow setAvailableScreenSize:bounds.size];
    [gWindow setScreenScale:2];
    [gWindow setVisible:YES];
    gWebView = [[WebView alloc] initWithFrame:bounds frameName:nil groupName:nil];
    [gWindow setContentView:gWebView];
    WebPreferences *p = [gWebView preferences];
    [p setJavaScriptEnabled:YES];
    [p setAcceleratedCompositingEnabled:NO];
    if ([p respondsToSelector:@selector(setWebGLEnabled:)]) [p setWebGLEnabled:YES];
    if ([p respondsToSelector:@selector(setWebAssemblyEnabled:)]) [p setWebAssemblyEnabled:YES];
    [gWebView _setBrowserUserAgentProductVersion:@"18.7" buildVersion:@"604.1" bundleVersion:@"604.1"];
    [gWebView setFrameLoadDelegate:[WriterObserver new]];
    NSString *loadURL = gProbeMode ? gURL : kLightPage;
    LOG("loading %s", [loadURL UTF8String]);
    [[gWebView mainFrame] loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:loadURL]]];
    WebThreadUnlock();

    if (gProbeMode) {
        // Let the captcha's JS boot and trip its environment check, then report.
        CFRunLoopTimerRef d = CFRunLoopTimerCreate(kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 12.0, 0, 0, 0, probeDump, NULL);
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), d, kCFRunLoopCommonModes);
        return;
    }
    CFRunLoopTimerRef pt = CFRunLoopTimerCreate(kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + 0.5, 0.5, 0, 0, poll, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), pt, kCFRunLoopCommonModes);
}

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (argc < 4) { fprintf(stderr, "usage: scfix-writer <jar> <METHOD> <url>\n"); return 64; }
    gJarPath = [[NSString stringWithUTF8String:argv[1]] retain];
    gMethod = [[NSString stringWithUTF8String:argv[2]] retain];
    gURL = [[NSString stringWithUTF8String:argv[3]] retain];
    gProbeMode = [gMethod isEqualToString:@"PROBE"];

    setenv("JSC_largeHeapSize", "4194304", 1);
    // DataDome's captcha runs a WebAssembly challenge; with WASM off its script
    // reports "JavaScript disabled or not working". Force it on for this process.
    setenv("JSC_useWasm", "1", 1);
    setenv("JSC_numberOfGCMarkers", "1", 1);

    CFRunLoopTimerRef s = CFRunLoopTimerCreate(kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent(), 0, 0, 0, start, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), s, kCFRunLoopCommonModes);
    CFRunLoopRun();
    [pool release];
    return 0;
}
