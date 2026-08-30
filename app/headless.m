/*
 * Headless harness: drives WebKit without UIApplicationMain.
 *
 * An app started from a shell blocks forever inside UIApplicationMain waiting
 * for SpringBoard, which never launched it. Everything worth measuring — does
 * the page load, how long it takes, what the DOM ends up containing, how much
 * memory it costs — is reachable by driving WebView directly on a run loop.
 */

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <signal.h>
#import <string.h>
#import <sys/ucontext.h>
#import <execinfo.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <WebKitLegacy/WebFrame.h>
#import <WebKitLegacy/WebPreferences.h>
#import <WebKitLegacy/WebPreferencesPrivate.h>
#import <WebKitLegacy/WebFeature.h>
#import <WebKitLegacy/WebView.h>
#import <WebKitLegacy/WebViewPrivate.h>
#import <WebKitLegacy/WAKWindow.h>
#import "ModernTLSURLProtocol.h"
#import <WebKitLegacy/WebCoreThreadRun.h>
#import "../platform/runtime/WebAppBridge.h"
#import "../platform/runtime/WebAppBytecodeCache.h"
#import "../platform/runtime/WebAppContentBlocker.h"
#import <WebKitLegacy/WebScriptObject.h>
#import <WebKitLegacy/WAKView.h>
#import <WebKitLegacy/WebFrameView.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>

extern void WebKitInitialize(void);
extern void WebThreadLock(void);
extern void WebThreadUnlock(void);
extern void WKSetCurrentGraphicsContext(CGContextRef);

#define LOG(fmt, ...) do { \
    fprintf(stderr, "[headless] " fmt "\n", ##__VA_ARGS__); \
    fflush(stderr); \
} while (0)

/* No crash reports are produced for this process, so the harness prints its own:
 * the faulting address, the program counter, and the slide of every loaded image
 * so the pc can be turned back into a symbol with atos. */
static void crashed(int sig, siginfo_t *info, void *context)
{
    ucontext_t *uc = (ucontext_t *)context;
    fprintf(stderr, "[headless] signal %d at %p, pc %08x, lr %08x\n",
        sig, info ? info->si_addr : NULL,
        (unsigned)uc->uc_mcontext->__ss.__pc, (unsigned)uc->uc_mcontext->__ss.__lr);
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "LegacyBrowser.app"))
            fprintf(stderr, "[headless]   %p %s\n", (void *)_dyld_get_image_vmaddr_slide(i), name);
    }
    void *frames[32];
    int count = backtrace(frames, 32);
    backtrace_symbols_fd(frames, count, STDERR_FILENO);
    fflush(stderr);
    _exit(139);
}

static void installCrashHandler(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = crashed;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
}

/* WebKitLegacy ships many finished features switched off — BroadcastChannel,
 * requestIdleCallback and the compression streams among them — because the old
 * API predates them. A site that feature-detects one of these quietly serves a
 * lesser page. Rather than name them by hand, ask the engine for its own list
 * and turn on everything it considers shipped. */
static void enableShippedFeatures(WebPreferences *preferences)
{
    NSMutableArray *turnedOn = [NSMutableArray array];
    NSArray *lists[] = { [WebPreferences _experimentalFeatures], [WebPreferences _internalFeatures] };
    for (unsigned i = 0; i < 2; i++) {
        for (WebFeature *feature in lists[i]) {
            if ([feature status] != WebFeatureStatusStable)
                continue;
            if ([preferences _isEnabledForFeature:feature])
                continue;
            [preferences _setEnabled:YES forFeature:feature];
            [turnedOn addObject:[feature key]];
        }
    }
    LOG("features enabled: %lu", (unsigned long)[turnedOn count]);
    LOG("  %s", [[turnedOn componentsJoinedByString:@", "] UTF8String] ?: "");
}

/* WTF::memoryFootprint() reports resident_size on this port, because this kernel
 * answers TASK_VM_INFO at revision 0 and never fills in phys_footprint. Resident
 * counts clean file-backed and shared pages that releaseMemory() cannot lower, so
 * every threshold derived from it may be measuring the wrong thing - but the
 * alternative (the vm ledger's `internal` + `compressed`, which is what
 * phys_footprint is made of) is only usable if this kernel actually fills those
 * fields. That is one number away from being settled, so print it: `filled` is how
 * many of the TASK_VM_INFO_COUNT integers task_info claims to have written, and
 * internal/external/compressed are the ledger fields the rev-0 struct ends with.
 * If internal is a plausible non-zero number, MemoryFootprintCocoa.cpp can report
 * internal + compressed and the pressure thresholds can be rebased on the
 * reclaimable bytes instead of on resident. */
static void reportMemoryBreakdown(void)
{
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count) != KERN_SUCCESS) {
        LOG("vm info: unavailable");
        return;
    }
    LOG("vm info: filled %u of %u ints, resident %.1f MB, internal %.1f MB, external %.1f MB, compressed %.1f MB",
        (unsigned)count, (unsigned)TASK_VM_INFO_COUNT,
        vmInfo.resident_size / (1024.0 * 1024.0),
        vmInfo.internal / (1024.0 * 1024.0),
        vmInfo.external / (1024.0 * 1024.0),
        vmInfo.compressed / (1024.0 * 1024.0));
}

static double footprintMB(void)
{
    struct task_basic_info info;
    mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return -1;
    return info.resident_size / (1024.0 * 1024.0);
}

@interface LoadObserver : NSObject {
@public
    BOOL finished;
    BOOL failed;
    NSDate *start;
}
@end

@implementation LoadObserver

- (void)webView:(WebView *)sender didStartProvisionalLoadForFrame:(WebFrame *)frame
{
    if (frame == [sender mainFrame])
        LOG("provisional load started  (%.1f MB)", footprintMB());
}

/* The global object is replaced on every navigation, so the bridge has to be put
 * back each time; this is the callback that says it has just happened. */
- (void)webView:(WebView *)sender didClearWindowObject:(WebScriptObject *)windowObject forFrame:(WebFrame *)frame
{
    if (frame != [sender mainFrame])
        return;
    /* Installing the bridge evaluates a script, which means taking the web lock.
     * This delegate call arrives on the main thread at the moment the load
     * commits - exactly when the page's own scripts start running - so doing it
     * here directly is a main-thread wait on however long that takes. On a page
     * whose scripts run for seconds that is long enough for the watchdog. */
    WebView *webView = sender;
    WebThreadRun(^{
        [WebAppBridge installInWebView:webView forFrame:frame];
    });
}

- (void)webView:(WebView *)sender didCommitLoadForFrame:(WebFrame *)frame
{
    if (frame != [sender mainFrame])
        return;
    LOG("load committed  %.2f s  (%.1f MB)", -[start timeIntervalSinceNow], footprintMB());
    /* A modern site fails through rejected promises far more often than through
     * thrown errors, and those never reach window.onerror. */
    [sender stringByEvaluatingJavaScriptFromString:
        @"window.__errs=[];"
         "window.onerror=function(m,u,l){window.__errs.push('error: '+m+' @'+u+':'+l);};"
         "window.addEventListener('unhandledrejection',function(e){var r=e.reason;"
         "window.__errs.push('rejection: '+((r&&(r.stack||r.message))||r));});"
         "(function(){var c=window.console||{};var o=c.error;c.error=function(){"
         "window.__errs.push('console.error: '+Array.prototype.join.call(arguments,' '));"
         "if(o)o.apply(c,arguments);};window.console=c;})();"];
}

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    if (frame != [sender mainFrame])
        return;
    LOG("load finished  %.2f s  (%.1f MB)", -[start timeIntervalSinceNow], footprintMB());
    [WebAppBytecodeCache flush];
    finished = YES;
}

- (void)webView:(WebView *)sender didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
    if (frame != [sender mainFrame])
        return;
    LOG("provisional load failed: %s", [[error localizedDescription] UTF8String]);
    failed = YES;
}

- (void)webView:(WebView *)sender didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
    if (frame != [sender mainFrame])
        return;
    LOG("load failed: %s", [[error localizedDescription] UTF8String]);
    failed = YES;
}

@end

static NSString *evaluate(WebView *webView, NSString *script)
{
    WebThreadLock();
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:script];
    WebThreadUnlock();
    return result;
}

/* WebKit's web thread hands off to the main run loop during startup, so all of
 * this has to happen from inside a running run loop rather than straight-line
 * code after main(). */
static NSString *gURLString;
static double gTimeout;
static BOOL gLoginFlow;
static LoadObserver *gObserver;
static WebView *gWebView;
static WAKWindow *gWindow;
static CALayer *gHostLayer;
static NSDate *gPhaseStart;

/* 0 loading, 1 settling after load, 2 waiting for the login form */
static int gPhase;

static NSString *const kClickLoginJS =
    @"(function(){var re=/^(log ?in|login|sign ?in|continue with|войти)/i;"
     "var els=document.querySelectorAll('a,button,[role=\"button\"],input[type=\"submit\"]');"
     "for(var i=0;i<els.length;i++){var e=els[i];"
     "var t=((e.innerText||e.value||e.getAttribute('aria-label')||'')+'').trim();"
     "if(re.test(t)){e.click();return 'clicked \"'+t+'\" <'+e.tagName+'>';}}"
     "var a=document.querySelector('a[href*=\"login\"],a[href*=\"signin\"]');"
     "if(a){a.click();return 'clicked href '+a.getAttribute('href');}"
     "return 'no login control found';})()";

/* The form may live in an iframe, so same-origin frames are counted too. */
static NSString *const kFormProbeJS =
    @"(function(){function count(d){try{return [d.querySelectorAll('input[type=\"password\"]').length,"
     "d.querySelectorAll('input[type=\"text\"],input[type=\"email\"],input[type=\"tel\"]').length,"
     "d.querySelectorAll('[contenteditable=\"true\"],[role=\"textbox\"]').length];}catch(e){return [0,0,0];}}"
     "var t=count(document);var f=document.querySelectorAll('iframe');"
     "for(var i=0;i<f.length;i++){var c=count(f[i].contentDocument||{querySelectorAll:function(){return [];}});"
     "t[0]+=c[0];t[1]+=c[1];t[2]+=c[2];}"
     "return t[0]+' password, '+t[1]+' text, '+t[2]+' editable, '+f.length+' iframes, at '+location.href;})()";

static NSString *const kPageTextJS =
    @"(function(){var t=(document.body?(document.body.innerText||document.body.textContent||''):'');"
     "return t.replace(/\\s+/g,' ').substring(0,400);})()";

/* Draw the page into a bitmap and write it out. A DOM with the right elements
 * in it is not proof that anything is painted. */
static void writeSnapshot(const char *path, CGSize size)
{
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, (size_t)size.width, (size_t)size.height, 8, 0,
        colorSpace, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        LOG("snapshot: could not create a bitmap");
        return;
    }

    CGContextSetRGBFillColor(context, 0, 1, 0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, size.width, size.height));

    {
        unsigned char *filled = CGBitmapContextGetData(context);
        LOG("snapshot: after fill, first pixel %02x %02x %02x %02x",
            filled[0], filled[1], filled[2], filled[3]);
    }

    /* Tiles are painted on the web thread; nothing has content until it has both
     * been asked to lay out and been given the time to do it. */
    WebThreadLock();
    [gWindow setVisible:YES];
    [gWindow setTilingMode:kWAKWindowTilingModeDisabled];
    [gWindow setTilingMode:kWAKWindowTilingModeMinimal];
    [gWindow setNeedsDisplay];
    [gWindow layoutTilesNow];
    WebThreadUnlock();
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2.0, false);

    WebThreadLock();
    WAKView *documentView = (WAKView *)[[[gWebView mainFrame] frameView] documentView];
    CGRect documentFrame = documentView ? [documentView frame] : CGRectZero;
    CGRect frameViewFrame = [[[gWebView mainFrame] frameView] frame];
    CGRect webViewFrame = [gWebView frame];
    LOG("snapshot: document view %p frame %g,%g %gx%g", documentView,
        documentFrame.origin.x, documentFrame.origin.y,
        documentFrame.size.width, documentFrame.size.height);
    LOG("snapshot: frame view %gx%g, web view %gx%g",
        frameViewFrame.size.width, frameViewFrame.size.height,
        webViewFrame.size.width, webViewFrame.size.height);
    /* With accelerated compositing the content lives in the layer tree rather
     * than in the view, so the window's layer is what actually has pixels. */
    /* Paint the window straight into this bitmap, with no CoreAnimation in
     * between: WKSetCurrentGraphicsContext is what the tile cache itself uses
     * before asking the window to draw. */
    WebThreadLock();
    WKSetCurrentGraphicsContext(context);
    /* Core Graphics counts rows from the bottom and a document from the top, so
     * without this the picture comes out upside down and every screenshot has to
     * be read in a mirror. */
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, 0, size.height);
    CGContextScaleCTM(context, 1, -1);
    [gWindow displayRect:CGRectMake(0, 0, size.width, size.height)];
    CGContextRestoreGState(context);
    WebThreadUnlock();
    {
        unsigned char *direct = CGBitmapContextGetData(context);
        LOG("snapshot: after direct paint, first pixel %02x %02x %02x, centre %02x %02x %02x",
            direct[0], direct[1], direct[2],
            direct[(size_t)(size.height / 2) * CGBitmapContextGetBytesPerRow(context) + (size_t)(size.width / 2) * 4],
            direct[(size_t)(size.height / 2) * CGBitmapContextGetBytesPerRow(context) + (size_t)(size.width / 2) * 4 + 1],
            direct[(size_t)(size.height / 2) * CGBitmapContextGetBytesPerRow(context) + (size_t)(size.width / 2) * 4 + 2]);
    }

    CALayer *hostLayer = [gWindow hostLayer] ?: gHostLayer;
    WebThreadLock();
    LOG("snapshot: host layer %p, %lu sublayers", hostLayer, (unsigned long)[[hostLayer sublayers] count]);
    for (CALayer *layer in [hostLayer sublayers]) {
        CGRect f = [layer frame];
        LOG("snapshot:   %s %g,%g %gx%g contents %p, %lu sublayers, hidden %d, opacity %g",
            class_getName([layer class]), f.origin.x, f.origin.y, f.size.width, f.size.height,
            [layer contents], (unsigned long)[[layer sublayers] count], [layer isHidden], [layer opacity]);
        for (CALayer *child in [layer sublayers]) {
            CGRect c = [child frame];
            LOG("snapshot:     %s %g,%g %gx%g contents %p",
                class_getName([child class]), c.origin.x, c.origin.y, c.size.width, c.size.height, [child contents]);
        }
    }
    WebThreadUnlock();
    WebThreadUnlock();

    CGImageRef image = CGBitmapContextCreateImage(context);
    unsigned char *pixels = CGBitmapContextGetData(context);
    size_t stride = CGBitmapContextGetBytesPerRow(context);
    unsigned long nonWhite = 0;
    for (size_t y = 0; y < (size_t)size.height; y++) {
        for (size_t x = 0; x < (size_t)size.width; x++) {
            unsigned char *pixel = pixels + y * stride + x * 4;
            if (pixel[0] < 250 || pixel[1] < 250 || pixel[2] < 250)
                nonWhite++;
        }
    }
    LOG("snapshot: %lu of %.0f pixels painted, first pixel %02x %02x %02x %02x, centre %02x %02x %02x",
        nonWhite, size.width * size.height, pixels[0], pixels[1], pixels[2], pixels[3],
        pixels[(size_t)(size.height / 2) * stride + (size_t)(size.width / 2) * 4],
        pixels[(size_t)(size.height / 2) * stride + (size_t)(size.width / 2) * 4 + 1],
        pixels[(size_t)(size.height / 2) * stride + (size_t)(size.width / 2) * 4 + 2]);

    CFStringRef file = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, file, kCFURLPOSIXPathStyle, false);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(url, kUTTypePNG, 1, NULL);
    if (destination) {
        CGImageDestinationAddImage(destination, image, NULL);
        CGImageDestinationFinalize(destination);
        CFRelease(destination);
        LOG("snapshot written to %s", path);
    } else
        LOG("snapshot: could not open %s", path);
    CFRelease(url);
    CFRelease(file);
    CGImageRelease(image);
    CGContextRelease(context);
}

static void dumpMetrics(const char *label)
{
    LOG("--- %s ---", label);
    LOG("title: %s", [[gWebView mainFrameTitle] UTF8String] ?: "(none)");
    LOG("url: %s", [[gWebView mainFrameURL] UTF8String] ?: "(none)");
    LOG("readyState: %s", [evaluate(gWebView, @"document.readyState") UTF8String] ?: "(none)");
    LOG("body length: %s", [evaluate(gWebView, @"String(document.body?document.body.innerHTML.length:0)") UTF8String] ?: "0");
    LOG("elements: %s", [evaluate(gWebView, @"String(document.getElementsByTagName('*').length)") UTF8String] ?: "0");
    LOG("inputs: %s  links: %s  scripts: %s",
        [evaluate(gWebView, @"String(document.querySelectorAll('input').length)") UTF8String] ?: "0",
        [evaluate(gWebView, @"String(document.querySelectorAll('a').length)") UTF8String] ?: "0",
        [evaluate(gWebView, @"String(document.querySelectorAll('script').length)") UTF8String] ?: "0");
    LOG("forms: %s  iframes: %s",
        [evaluate(gWebView, @"String(document.forms.length)") UTF8String] ?: "0",
        [evaluate(gWebView, @"String(document.querySelectorAll('iframe').length)") UTF8String] ?: "0");
    LOG("js errors (%s): %s",
        [evaluate(gWebView, @"String((window.__errs||[]).length)") UTF8String] ?: "?",
        [evaluate(gWebView, @"String((window.__errs||[]).slice(0,6).join(' || ')||'none')") UTF8String] ?: "?");
    LOG("text: %s", [evaluate(gWebView, kPageTextJS) UTF8String] ?: "(none)");

    /* A question about one particular page is asked once and then not again, so
     * take it from the environment rather than growing another argument. */
    const char *probe = getenv("HEADLESS_PROBE");
    if (probe && *probe) {
        NSString *answer = evaluate(gWebView, [NSString stringWithUTF8String:probe]);
        LOG("probe: %s", [answer UTF8String] ?: "(nothing)");
    }
    char path[256];
    snprintf(path, sizeof(path), "/tmp/shot-%s.png", label);
    for (char *c = path; *c; c++) {
        if (*c == ' ')
            *c = '-';
    }
    writeSnapshot(path, CGSizeMake(320, 480));
    LOG("footprint: %.1f MB", footprintMB());
    reportMemoryBreakdown();
}

static void finish(int status)
{
    [WebAppBytecodeCache flush];
    LOG("exiting, status %d, %.1f MB", status, footprintMB());
    exit(status);
}

/* No UIApplicationMain/dispatch_main here to drain an autorelease pool once
 * per run-loop turn the way app/main.m gets automatically - this harness is
 * plain CFRunLoopRun(), so every autoreleased temporary this produces
 * (notably evaluate()'s NSString, called on most ticks including the
 * up-to-45s/0.5s form-probe poll below) would otherwise sit resident until
 * the process exits. tick() is a thin pooled wrapper around tickBody() so
 * each 0.5s firing drains its own temporaries instead of accumulating them
 * for the run's whole lifetime; tickBody()'s early returns are all normal
 * control flow (the only unpooled exit is finish()'s exit(status), where the
 * OS reclaims everything regardless). */
static void tickBody(CFRunLoopTimerRef timer, void *info)
{
    double elapsed = -[gPhaseStart timeIntervalSinceNow];

    if (gPhase == 0) {
        if (gObserver->failed) {
            dumpMetrics("load failed");
            finish(1);
        }
        if (!gObserver->finished) {
            if (elapsed > gTimeout) {
                LOG("load timed out after %.0f s", gTimeout);
                dumpMetrics("timed out");
                finish(2);
            }
            return;
        }
        /* A single-page app keeps building the DOM after the load event. */
        gPhase = 1;
        [gPhaseStart release];
        gPhaseStart = [[NSDate date] retain];
        LOG("settling for 5 s");
        return;
    }

    if (gPhase == 1) {
        /* The cookie dialog appears seconds after the load event and blocks
         * everything behind it until answered. */
        if (elapsed > 3.0 && elapsed < 3.6) {
            LOG("cookie dialog: %s", [evaluate(gWebView,
                @"(function(){if(window.__consent)return 'already';"
                 "var re=/(allow all cookies|accept all|decline optional|only allow essential)/i;"
                 "var els=document.querySelectorAll('button,[role=\"button\"],div[tabindex],a');"
                 "for(var i=0;i<els.length;i++){var t=((els[i].innerText||'')+'').trim();"
                 "if(t&&t.length<40&&re.test(t)){els[i].click();window.__consent=1;return 'clicked '+t;}}"
                 "return 'not present';})()") UTF8String] ?: "?");
        }
        if (elapsed < 14.0)
            return;
        dumpMetrics("loaded");
        if (!gLoginFlow)
            finish(gObserver->failed ? 1 : 0);
        LOG("login: %s", [evaluate(gWebView, kClickLoginJS) UTF8String] ?: "?");
        gPhase = 2;
        [gPhaseStart release];
        gPhaseStart = [[NSDate date] retain];
        return;
    }

    NSString *probe = evaluate(gWebView, kFormProbeJS);
    if ([probe hasPrefix:@"0 password"] && elapsed < 45.0) {
        if ((int)(elapsed * 2) % 10 == 0)
            LOG("waiting for form  %.0f s: %s  (%.1f MB)", elapsed, [probe UTF8String], footprintMB());
        return;
    }
    LOG("form probe: %s", [probe UTF8String] ?: "?");
    dumpMetrics("after login click");
    finish([probe hasPrefix:@"0 password"] ? 3 : 0);
}

static void tick(CFRunLoopTimerRef timer, void *info)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    tickBody(timer, info);
    [pool release];
}

static void startBrowsing(CFRunLoopTimerRef timer, void *info)
{
    LOG("modern TLS: %s", [ModernTLSURLProtocol install] ? "installed" : "unavailable");
    LOG("initialising WebKit  (%.1f MB)", footprintMB());
    WebKitInitialize();
    LOG("WebKit initialised  (%.1f MB)", footprintMB());

    CGRect bounds = CGRectMake(0, 0, 320, 480);
    WebThreadLock();
    LOG("creating WAKWindow");
    /* -initWithFrame: makes a window with no tile cache, whose content has to be
     * painted by hand; -initWithLayer: is the one that gives WebKit somewhere to
     * draw. */
    gHostLayer = [[CALayer alloc] init];
    [gHostLayer setFrame:bounds];
    WAKWindow *window = [[WAKWindow alloc] initWithLayer:gHostLayer];
    gWindow = window;
    /* The tile cache paints nothing until it knows what screen it is for. */
    [window setScreenSize:bounds.size];
    [window setAvailableScreenSize:bounds.size];
    [window setScreenScale:2];
    [window setVisible:YES];
    [window setTilesOpaque:YES];
    [window setTilingMode:kWAKWindowTilingModeMinimal];
    LOG("WAKWindow %p, creating WebView", window);
    gWebView = [[WebView alloc] initWithFrame:bounds frameName:nil groupName:nil];
    LOG("WebView %p, setting content view", gWebView);
    [window setContentView:gWebView];
    LOG("content view set");

    WebPreferences *preferences = [gWebView preferences];
    [preferences setJavaScriptEnabled:YES];
    [preferences setJavaScriptCanOpenWindowsAutomatically:NO];
    /* This harness has no UIKit delegate wired up (see app/main.m, which now
     * does), so WebChromeClientIOS::attachRootGraphicsLayer() would hand any
     * promoted layer to nil and it would never appear in a snapshot -
     * position:fixed is promoted by default. Left off here since this tool
     * measures text/DOM state and timing, not visual fidelity. */
    [preferences setAcceleratedCompositingEnabled:NO];

    enableShippedFeatures(preferences);
    /* Let WebKit build its own user agent, with the Safari version LightKit
     * uses on this same device — a hand-written string got threads.com to
     * serve an empty shell instead of the site. */
    [gWebView _setBrowserUserAgentProductVersion:@"18.7" buildVersion:@"604.1" bundleVersion:@"604.1"];

    gObserver = [[LoadObserver alloc] init];
    gObserver->start = [[NSDate date] retain];
    [gWebView setFrameLoadDelegate:gObserver];

    /* Same shell policy as the app, so a measurement here describes what the
     * app actually does. */
    NSString *shellHost = [[NSURL URLWithString:gURLString] host];
    if ([shellHost length]) {
        [ModernTLSURLProtocol setShellCacheFirstEnabled:YES
                                               forHosts:[NSArray arrayWithObject:shellHost]];
        LOG("shell cache-first: %s", [shellHost UTF8String]);
    }

    [WebAppContentBlocker installInWebView:gWebView];
    [WebAppBytecodeCache install];

    LOG("loading %s", [gURLString UTF8String]);
    [[gWebView mainFrame] loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:gURLString]]];
    WebThreadUnlock();

    gPhaseStart = [gObserver->start retain];
    CFRunLoopTimerRef poll = CFRunLoopTimerCreate(kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + 0.5, 0.5, 0, 0, tick, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), poll, kCFRunLoopCommonModes);
}

int main(int argc, char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    gURLString = argc > 1 ? [[NSString stringWithUTF8String:argv[1]] retain] : @"https://www.threads.com/";
    gTimeout = argc > 2 ? atof(argv[2]) : 120.0;
    gLoginFlow = argc > 3 && !strcmp(argv[3], "login");

    /* Read once by JSC at the first JSC::initialize(), which this harness
     * reaches through WebKitInitialize(). See app/main.m for why 4 MB. */
    setenv("JSC_largeHeapSize", "4194304", 1);
    setenv("JSC_smallHeapRAMFraction", "0.08", 1);
    setenv("JSC_mediumHeapRAMFraction", "0.2", 1);
    setenv("JSC_smallHeapGrowthFactor", "1.25", 1);
    setenv("JSC_mediumHeapGrowthFactor", "1.12", 1);
    setenv("JSC_largeHeapGrowthFactor", "1.05", 1);
    setenv("JSC_minNumberOfWorklistThreads", "1", 1);
    setenv("JSC_maxNumberOfWorklistThreads", "1", 1);
    setenv("JSC_numberOfGCMarkers", "1", 1);
    setenv("JSC_useWasm", "0", 1);
    setenv("JSC_jitPolicyScale", "0.5", 1);

    installCrashHandler();
    LOG("start  (%.1f MB)", footprintMB());

    CFRunLoopTimerRef startup = CFRunLoopTimerCreate(kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent(), 0, 0, 0, startBrowsing, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), startup, kCFRunLoopCommonModes);

    CFRunLoopRun();
    [pool release];
    return 0;
}
