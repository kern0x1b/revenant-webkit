/*
 * One view, one URL, no chrome.
 *
 * WebKitLegacy on iOS does not draw into a UIView. A WebView is a WAKView
 * living inside a WAKWindow, the WAKWindow owns a tile cache, and the tile
 * cache draws into a CALayer. Hosting that layer in an ordinary UIView is what
 * UIWebView does internally.
 *
 * The tile cache paints nothing until it knows the screen it is painting for —
 * size, scale and tiling mode — so all three are set before the first load.
 */

#import <stdio.h>
#import <signal.h>
#import <mach/mach.h>
#import <unistd.h>
#import <sys/stat.h>
#import <pthread.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <malloc/malloc.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <execinfo.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <WebKitLegacy/WebFrame.h>
#import <WebKitLegacy/WebFrameView.h>
#import <WebKitLegacy/WebFrameViewPrivate.h>
#import <WebKitLegacy/WebPreferences.h>
#import <WebKitLegacy/WebPreferencesPrivate.h>
#import <WebKitLegacy/WebFixedPositionContent.h>
#import <WebKitLegacy/WebFeature.h>
#import <WebKitLegacy/WebView.h>
#import <WebKitLegacy/WAKWindow.h>
@class WAKScrollView;
@interface WAKScrollView : NSObject
- (void)setActualScrollPosition:(CGPoint)point;
@end
#import <WebKitLegacy/WAKView.h>
#import <WebKitLegacy/WebEvent.h>
#import <WebKitLegacy/WebCoreThreadRun.h>
#import <WebKitLegacy/WebCoreStatistics.h>
#import <WebKitLegacy/WebCache.h>
#import "ModernTLSURLProtocol.h"
#import <WebKitLegacy/WebViewPrivate.h>
#import <WebKitLegacy/WebPolicyDelegate.h>
#import <WebKitLegacy/WebFrameLoadDelegate.h>
#import "../platform/runtime/WebAppManifest.h"
#import "../platform/runtime/WebAppCookieJar.h"
#import "../platform/runtime/WebAppBridge.h"
#import "../platform/runtime/WebAppBytecodeCache.h"
#import "../platform/runtime/WebAppContentBlocker.h"
#import <WebKitLegacy/WebScriptObject.h>
#import <notify.h>
#import "WebKitUIKitDelegate.h"

/* Launched from SpringBoard there is no terminal, so the trace goes to a file. */
static void browserLog(const char *format, ...)
{
    static FILE *file;
    if (!file) {
        file = fopen("/tmp/browser.log", "w");
        if (!file)
            file = stderr;
        else
            dup2(fileno(file), STDERR_FILENO);
    }
    va_list arguments;
    va_start(arguments, format);
    fprintf(file, "[browser] ");
    vfprintf(file, format, arguments);
    fprintf(file, "\n");
    va_end(arguments);
    fflush(file);
}

#define LOG_STEP(fmt, ...) browserLog(fmt, ##__VA_ARGS__)

static void dumpThreadStacks(const char *why);
static void *watchWebThread(void *unused);


static void reportFatalSignal(int number, siginfo_t *info, void *context)
{
    void *frames[64];
    int count = backtrace(frames, 64);
    browserLog("FATAL signal %d at %p, %d frames", number, info ? info->si_addr : NULL, count);
    char **names = backtrace_symbols(frames, count);
    if (names) {
        for (int i = 0; i < count; i++)
            browserLog("  #%02d %s", i, names[i]);
    } else {
        for (int i = 0; i < count; i++)
            browserLog("  #%02d %p", i, frames[i]);
    }
    signal(number, SIG_DFL);
    raise(number);
}

static void reportUncaughtException(NSException *exception)
{
    browserLog("UNCAUGHT %s: %s", [[exception name] UTF8String] ?: "?",
        [[exception reason] UTF8String] ?: "?");
    NSArray *frames = [exception callStackSymbols];
    for (NSUInteger i = 0; i < [frames count] && i < 40; i++)
        browserLog("  %s", [[frames objectAtIndex:i] UTF8String] ?: "?");
}

static void installFatalSignalHandlers(void)
{
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = reportFatalSignal;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    NSSetUncaughtExceptionHandler(reportUncaughtException);
    int numbers[] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE };
    for (unsigned i = 0; i < sizeof(numbers) / sizeof(numbers[0]); i++)
        sigaction(numbers[i], &action, NULL);
}

/* When the screenshot request file was last touched, so one request is one
 * picture rather than one per poll. */
static time_t gLastSnapRequest;

extern void WebKitInitialize(void);
extern void WebThreadLock(void);
extern void WebThreadUnlock(void);

/* The page to open.
 *
 * A packaged application says so in its own WebApp.plist, which is the whole
 * difference between one bundle and another — see platform/package.py. A build
 * with no manifest is the development browser this started as, and still reads
 * /tmp/url.txt so that a site can be tried without packaging anything. */
static NSString *startPage(void)
{
    NSURL *fromManifest = [WebAppManifest startURL];
    if (fromManifest)
        return [fromManifest absoluteString];

    NSString *configured = [NSString stringWithContentsOfFile:@"/tmp/url.txt"
        encoding:NSUTF8StringEncoding error:NULL];
    configured = [configured stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [configured length] ? configured : @"https://www.threads.com/";
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
    LOG_STEP("features enabled: %lu", (unsigned long)[turnedOn count]);
    LOG_STEP("  %s", [[turnedOn componentsJoinedByString:@", "] UTF8String] ?: "");
}

@interface UIView (WebKitIOS6BrowserView)
- (id)initWithWebView:(WebView *)webView frame:(CGRect)frame;
@end

@interface WebContentScrollView : UIScrollView
@end

@implementation WebContentScrollView

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    [super touchesBegan:touches withEvent:event];
    [[self nextResponder] touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    [super touchesMoved:touches withEvent:event];
    [[self nextResponder] touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    [super touchesEnded:touches withEvent:event];
    [[self nextResponder] touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
    [super touchesCancelled:touches withEvent:event];
    [[self nextResponder] touchesCancelled:touches withEvent:event];
}

@end

/* WebFrameLoadDelegate is named here as well as WebPolicyDelegate. It always
 * should have been — the frame load methods below are already implemented and
 * -setFrameLoadDelegate: has been warning about the missing conformance — and
 * with a policy delegate on the same object the compiler is now the only thing
 * that will notice a delegate method whose signature has drifted. */
@interface BrowserViewController : UIViewController <UIScrollViewDelegate,
                                                     WebFrameLoadDelegate,
                                                     WebPolicyDelegate,
                                                     WebKitRootLayerHandler> {
    WebView *_webView;
    WAKWindow *_wakWindow;
    CALayer *_hostLayer;
    UIScrollView *_scrollView;
    NSDate *_start;
    CGSize _viewportSize;   /* the screen the page is laid out for */
    CGSize _documentSize;   /* the area the engine has been sized to paint */
    BOOL _documentGrewBeyondViewport;
    CGFloat _tallestDocumentHeight;
    CGPoint _lastOffset;
    CGPoint _lastTouchPoint;
    BOOL _touchInPage;
    BOOL _settled;
    BOOL _fixedRectUpdateInFlight;
    CGRect _pendingFixedRect;
    UIView *_tabBar;        /* drawn by us, from what the page declared */
    BOOL _touchCancelledByScroll;
    WebKitUIKitDelegate *_uiKitDelegate;
    CALayer *_compositingRootLayer;   /* what WebCore last handed to -attachRootLayer:, or nil */
}
@end

@implementation BrowserViewController

- (void)loadView
{
    /* The status bar is drawn over the window, so a full-height view has its top
     * twenty points behind it and its last twenty below the screen. Give the
     * view the rectangle that is actually visible and everything downstream -
     * the viewport the page lays out for, the scroll view, the tile grid - is
     * measured against the same thing. */
    CGRect screen = [[UIScreen mainScreen] bounds];
    CGFloat statusBar = CGRectGetHeight([[UIApplication sharedApplication] statusBarFrame]);
    UIView *root = [[UIView alloc] initWithFrame:
        CGRectMake(0, statusBar, screen.size.width, screen.size.height - statusBar)];
    /* The colour the application is, not the colour a browser is. This is what
     * shows before the first tile is painted and past the end of the document,
     * and it is the same colour the generator writes into Default.png, so the
     * launch image and the first frame meet without a white flash between. */
    [root setBackgroundColor:[WebAppManifest backgroundColor]];
    [self setView:root];
    [root release];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    /* UIKit already keeps the status bar's height out of a view controller's
     * view: with the bar visible the root view is moved down and shortened, and
     * -bounds is that shortened rectangle. Subtracting the bar's height here as
     * well moved the page down twice - a white strip under the bar, and the same
     * amount of the page hanging off the bottom. Take the view as it is. */
    CGRect bounds = [[self view] bounds];
    LOG_STEP("view %g x %g at scale %g", bounds.size.width, bounds.size.height,
        [[UIScreen mainScreen] scale]);

    WebKitInitialize();
    LOG_STEP("WebKit initialised");
    {
        pthread_t webWatcher;
        pthread_create(&webWatcher, NULL, watchWebThread, NULL);
        pthread_detach(webWatcher);
    }

    /* Where the page's own storage lives, decided BEFORE the WebView exists.
     *
     * -[WebView _commonInitializationWithFrameName:groupName:] does
     * `WebViewGroup::getOrCreate(groupName, [preferences _localStorageDatabasePath])`,
     * and for an empty group name that constructs the group there and then with
     * whatever the path was at that moment. WebStorageNamespaceProvider keeps it,
     * and StorageNamespaceImpl builds a StorageSyncManager only when it is
     * non-empty — so a path set after this line reaches nothing, localStorage
     * lives in memory, and everything the site kept is gone at exit. Setting it
     * afterwards did appear to work from the second launch onwards, because
     * WebPreferences autosaves into NSUserDefaults and the next launch read it
     * back before the WebView was made; the first launch after an install always
     * lost its storage.
     *
     * The bundle identifier is in the path because these bundles are installed
     * in /Applications and get no container of their own: NSHomeDirectory() is
     * /var/mobile for every one of them, so without it Threads and Instagram
     * would share one localStorage database. */
    NSString *storage = [WebAppManifest storageDirectory];
    [[WebPreferences standardPreferences] _setLocalStorageDatabasePath:storage];
    /* WebDatabaseProvider reads this key out of NSUserDefaults by name, for both
     * WebSQL and IndexedDB, and it reads it lazily at first use rather than at
     * WebView construction — so unlike the path above this one is not order
     * sensitive. It is set here anyway so that the two live together. */
    [[NSUserDefaults standardUserDefaults] setObject:storage forKey:@"WebDatabaseDirectory"];
    LOG_STEP("page storage at %s", [storage UTF8String]);
    [WebAppBytecodeCache install];

    WebThreadLock();
    _webView = [[WebView alloc] initWithFrame:bounds frameName:nil groupName:nil];
    LOG_STEP("WebView %p", _webView);

    WebPreferences *preferences = [_webView preferences];
    [preferences setJavaScriptEnabled:YES];
    /* No cache model is set, deliberately. +_setCacheModel: runs only off the
     * cache-model-changed notification, and on iOS +standardPreferences — which
     * is what an unnamed WebView gets — is built with sendChangeNotification:NO
     * and never posts it. So WebCore keeps its own constructor defaults, and
     * those are tighter than any rung of the model ladder at 512 MB: an 8 MB
     * memory cache, a back-forward cache of zero pages, and a tile layer pool
     * of zero. WebCacheModelDocumentViewer would raise the memory cache to
     * 16 MB; its dead capacity of zero buys nothing here, because once a page's
     * live resources pass 8 MB the default's dead capacity is already zero and
     * the only thing left is 8 MB more live decoded image data. The same call
     * would also hand the tile layer pool 12 MB it does not have today.
     *
     * -setUsesPageCache: is gone for the same reason: BackForwardCache::canCache
     * refuses everything while the capacity is zero, so the preference decides
     * nothing. */
    [WebView _setMemoryCacheCapacitiesForLowMemoryDevice];
    /* WebChromeClientIOS::attachRootGraphicsLayer() is real - it hands the
     * promoted layer to -[WebView _UIKitDelegate], not to something under
     * PLATFORM(MAC) as an earlier comment here claimed. What was actually
     * missing was the delegate itself: nothing ever called
     * -_setUIKitDelegate:, so that hand-off went to nil and a layer the
     * engine promoted out of the tile paint (position:fixed is promoted by
     * default) was attached to nothing and simply never appeared - which is
     * why a page whose chrome and feed live in fixed containers painted
     * white the one time this was tried before. Wiring a real UIKit delegate
     * below, whose -attachRootLayer: puts the layer where it belongs, is
     * that missing half. */
    [preferences setAcceleratedCompositingEnabled:YES];

    [preferences setVideoPlaybackRequiresUserGesture:YES];
    [preferences setAudioPlaybackRequiresUserGesture:YES];
    [preferences setHiddenPageDOMTimerThrottlingEnabled:YES];
    [preferences setDOMTimersThrottlingEnabled:YES];
    [preferences _setTextAutosizingEnabled:NO];

    enableShippedFeatures(preferences);

    /* The path above is only half of it: the site also has to be allowed to use
     * the storage it now has somewhere to live in. */
    [preferences setDatabasesEnabled:YES];
    [preferences setLocalStorageEnabled:YES];

    /* The user agent is the manifest's, and it is expressed as the three version
     * numbers rather than as a sentence because WebKit builds a better sentence
     * than we do — a hand-written string got threads.com to serve an empty shell
     * instead of the site. */
    [WebAppManifest applyUserAgentToWebView:_webView];

    LOG_STEP("modern TLS: %s", [ModernTLSURLProtocol install] ? "installed" : "unavailable");
    [_webView setFrameLoadDelegate:self];
    /* A wrapped application decides for itself where a link may go; see
     * -webView:decidePolicyForNavigationAction:... below. */
    [_webView setPolicyDelegate:self];
    /* Everything else in WebKitUIKitDelegate.m is a no-op matching what this
     * embedder already got for free from WebDefaultUIKitDelegate before this
     * was set - the one call that matters is -attachRootLayer: below, which
     * is what setAcceleratedCompositingEnabled:YES above needed to actually
     * do anything. */
    _uiKitDelegate = [[WebKitUIKitDelegate alloc] init];
    [_uiKitDelegate setHandler:self];
    [_webView _setUIKitDelegate:_uiKitDelegate];
    WebThreadUnlock();

    /* UIKit's own UIWebBrowserView cannot host this WebView: it drives the view
     * through the system WebCore's WKWindowSetContentView, which then reaches
     * into structures belonging to a different WebCore and crashes. The window
     * and the layer have to be ours. */
    WebThreadLock();
    _hostLayer = [[CALayer alloc] init];
    /* The host layer is the document, not the screen. Its origin is the
     * document origin and it grows downwards as the page lays out, because
     * every measurement the tile cache makes comes from this layer:
     * LegacyTileGrid::bounds() is the host layer's size, so tiles exist only
     * inside it, and LegacyTileCache::visibleRectInLayer() is
     * -[WAKWindow extendedVisibleRect], which walks the superlayers and
     * intersects. Sitting in the scroll view, that walk already answers "which
     * part of the document is on screen" and it costs no web thread. */
    [_hostLayer setAnchorPoint:CGPointZero];
    [_hostLayer setPosition:CGPointZero];
    [_hostLayer setBounds:CGRectMake(0, 0, bounds.size.width, bounds.size.height)];
    _wakWindow = [[WAKWindow alloc] initWithLayer:_hostLayer];
    [_wakWindow setScreenSize:bounds.size];
    [_wakWindow setAvailableScreenSize:bounds.size];
    [_wakWindow setScreenScale:[[UIScreen mainScreen] scale]];
    [_wakWindow setVisible:YES];
    [_wakWindow setTilesOpaque:YES];
    /* LegacyTileGrid's normal cover rect is the visible rect inflated by half a
     * width each side and a full height above and below — 2w by 3h, which at
     * this size is four 320x512 tiles of 640x1024 backing store. Minimal
     * coverage is the visible rect alone, and centres the grid so 480 points
     * fall inside one 512-point row. */
    /* Nothing is tiled until the page has laid out something worth looking at.
     * A tile that exists is a tile CoreAnimation draws, and it draws on the main
     * thread while taking the web lock - so during the first seconds, when the
     * page's own scripts hold that lock without pause, every frame the main
     * thread tries to produce is a wait on them. On a page whose startup script
     * runs for five seconds that is long enough for SpringBoard to decide the
     * application has stopped answering. -settle takes it off Disabled. */
    [_wakWindow setTilingMode:kWAKWindowTilingModeDisabled];
    [_wakWindow setContentView:_webView];
    /* Where the viewport sits inside the document. WebCore reads this and not
     * the WAK scroll position: -[WAKScrollView unobscuredContentRect] is
     * [window exposedScrollViewRect] converted into the document view, and on
     * iOS ScrollView::visibleContentRect(), contentsScrollPosition() and hence
     * window.scrollY, the layout viewport and painting culling all go through
     * it. Guarded by its own lock, so setting it costs no web thread. */
    [_wakWindow setExposedScrollViewRect:CGRectMake(0, 0, bounds.size.width, bounds.size.height)];
    WebThreadUnlock();
    LOG_STEP("WAKWindow %p hosting layer %p", _wakWindow, _hostLayer);

    /* Scrolling. The embedder owns the scroll view; the host layer is one of
     * its sublayers, so Core Animation moves the painted document under the
     * finger without anything being asked of the web thread. */
    _viewportSize = bounds.size;
    _documentSize = bounds.size;
    _scrollView = [[WebContentScrollView alloc] initWithFrame:bounds];
    [_scrollView setDelegate:self];
    [_scrollView setShowsVerticalScrollIndicator:YES];
    [_scrollView setShowsHorizontalScrollIndicator:NO];
    [_scrollView setAlwaysBounceHorizontal:NO];
    [_scrollView setAlwaysBounceVertical:YES];
    [_scrollView setDirectionalLockEnabled:YES];
    [_scrollView setContentSize:bounds.size];
    /* A tap has to reach the page at once. UIScrollView otherwise holds the
     * touch back for about 150 ms to see whether the finger becomes a scroll;
     * with the delay off the page is told immediately, and the scroll view
     * still cancels the touch if a pan does start. */
    [_scrollView setDelaysContentTouches:NO];
    [_scrollView setCanCancelContentTouches:YES];
    [_scrollView setScrollsToTop:YES];
    /* Said explicitly because two things read it: -[WAKWindow extendedVisibleRect]
     * intersects at a superlayer only where masksToBounds is set, and a snapshot
     * renders the host layer with whatever clip it is given, which
     * LegacyTileHostLayer turns into an override visible rect and tiles. */
    [_scrollView setClipsToBounds:YES];
    [[_scrollView layer] addSublayer:_hostLayer];
    [[self view] addSubview:_scrollView];

    /* The page's own tab bar is a position:fixed strip that this embedder has to
     * repaint through the tile cache on every scroll frame, on the web thread,
     * on one slow core. Drawing it here instead costs nothing per frame and is
     * the most visible part of not looking like a browser. It appears only if
     * the page declares one, which the injected script does when it finds one. */
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(tabsDeclared:) name:@"WebAppBridgeTabsDeclared" object:nil];

    _start = [[NSDate date] retain];
    [self reportFootprint];
    NSString *page = startPage();

    /* A wrapped web app is one site, so its own hosts may serve its shell —
     * document, stylesheets, scripts, fonts — from disk without asking the
     * network first, the way a cache-first service worker does. Which hosts
     * those are is the manifest's business and not a guess from the start URL:
     * Threads draws its interface from static.cdninstagram.com, which no amount
     * of looking at https://www.threads.com/ would reveal. */
    if ([WebAppManifest loadManifest]) {
        [WebAppManifest applyNetworkPolicy];
    } else {
        NSString *shellHost = [[NSURL URLWithString:page] host];
        if ([shellHost length]) {
            [ModernTLSURLProtocol setShellCacheFirstEnabled:YES
                                                   forHosts:[NSArray arrayWithObject:shellHost]];
            LOG_STEP("shell cache-first: %s", [shellHost UTF8String]);
        }
    }

    WebThreadLock();
    [WebAppContentBlocker installInWebView:_webView];
    WebThreadUnlock();

    LOG_STEP("loading %s", [page UTF8String]);
    WebThreadLock();
    [[_webView mainFrame] loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:page]]];
    WebThreadUnlock();
}

/* The device's screen may be off when a build is tested, so the app captures
 * its own window rather than relying on a framebuffer grab. */
/* Input. WebKitLegacy takes touches as WebEvents posted to the WAKWindow; there
 * is no automatic path from UIKit, which is why a page with no event plumbing
 * looks frozen however well it renders. */
static WebEvent *touchEvent(WebEventType type, WebEventTouchPhaseType phase, CGPoint point)
{
    NSArray *locations = [NSArray arrayWithObject:[NSValue valueWithCGPoint:point]];
    NSArray *identifiers = [NSArray arrayWithObject:[NSNumber numberWithUnsignedInt:0]];
    NSArray *phases = [NSArray arrayWithObject:[NSNumber numberWithUnsignedInt:phase]];
    return [[[WebEvent alloc] initWithTouchEventType:type
        timeStamp:CACurrentMediaTime()
        location:point
        modifiers:0
        touchCount:1
        touchLocations:locations
        touchIdentifiers:identifiers
        touchPhases:phases
        isGesture:NO
        gestureScale:1
        gestureRotation:0] autorelease];
}

/* -[WAKWindow sendEvent:] is already asynchronous — it is a WebThreadRun of
 * -sendEventSynchronously:, and the web thread takes the lock itself before it
 * runs the queue. Taking the lock here as well bought nothing and made every
 * touch wait for the web thread to reach a yield point, which is most of what a
 * "delayed" tap was. The touch point is taken in the scroll view, whose bounds
 * origin is the content offset, so it is already in document coordinates —
 * which is what the window's coordinate space now is. */
/* A tap becomes a click through a mouse pair, not through the touch events:
 * WebCore dispatches touches to the DOM, but the click comes from the mouse
 * events UIWebView synthesises once a tap has been recognised. */
static WebEvent *mouseEvent(WebEventType type, CGPoint point)
{
    return [[[WebEvent alloc] initWithMouseEventType:type
        timeStamp:CACurrentMediaTime() location:point modifiers:0] autorelease];
}

/* Anything that touches the engine belongs on the web thread, not merely off the
 * main thread. Taking the lock from some other queue only moves the deadlock:
 * CoreAnimation draws the tile layers on the main thread, and
 * LegacyTileCache::drawLayer() takes the same lock there, so a background queue
 * holding it while a page runs script stops the main thread and the watchdog
 * kills the process a few seconds later. WebThreadRun() hands the work to the
 * thread that owns the lock already, so there is nothing to contend for. */
static void withWebLock(void (^work)(void))
{
    WebThreadRun(work);
}

- (void)sendTapAt:(CGPoint)point
{
    /* -sendEvent: hands the event to the web thread and waits for it. A click
     * makes WebCore run script and lay out, and that work wants the main thread,
     * so waiting for it from the main thread deadlocks. Sending from anywhere
     * else leaves the main thread free to answer. */
    WAKWindow *window = [_wakWindow retain];
    WebThreadRun(^{
        [window sendEvent:mouseEvent(WebEventMouseDown, point)];
        [window sendEvent:mouseEvent(WebEventMouseUp, point)];
        [window release];
    });
}

- (void)sendTouchEndThenTapAt:(CGPoint)point
{
    WAKWindow *window = [_wakWindow retain];
    WebEvent *end = [touchEvent(WebEventTouchEnd, WebEventTouchPhaseEnded, point) retain];
    WebThreadRun(^{
        [window sendEvent:end];
        BOOL handled = [end wasHandled];
        [end release];
        if (!handled) {
            [window sendEvent:mouseEvent(WebEventMouseDown, point)];
            [window sendEvent:mouseEvent(WebEventMouseUp, point)];
        }
        [window release];
    });
}

/* Send a tap at a point on the screen, and say what the page thinks is there.
 *
 * The distinction that matters is between screen coordinates - what a finger
 * touches - and document coordinates, which is where the page has been scrolled
 * to. The scroll view's own coordinate system is the document's, because its
 * bounds origin is the scroll offset, so a UITouch reported through
 * -locationInView: is already in document coordinates. This takes a screen
 * point and does that conversion itself. */
- (void)tapAtScreenPoint:(CGPoint)onScreen
{
    CGPoint offset = [_scrollView contentOffset];
    CGPoint inDocument = CGPointMake(onScreen.x + offset.x, onScreen.y + offset.y);

    NSString *ask = [NSString stringWithFormat:
        @"(function(){var e=document.elementFromPoint(%g,%g);"
         "if(!e)return 'nothing';"
         "var t=(e.innerText||e.getAttribute('aria-label')||'').replace(/\\s+/g,' ').slice(0,40);"
         "return e.tagName+' \"'+t+'\"';})()",
        onScreen.x, onScreen.y];

    WebView *webView = _webView;
    WebThreadRun(^{
        NSString *under = [webView stringByEvaluatingJavaScriptFromString:ask];
        LOG_STEP("tap at screen %g,%g (document %g,%g): page says %s",
            onScreen.x, onScreen.y, inDocument.x, inDocument.y,
            [under UTF8String] ?: "(no answer)");
    });

    [self sendTouch:WebEventTouchBegin phase:WebEventTouchPhaseBegan at:inDocument];
    [self sendTouchEndThenTapAt:inDocument];
}

- (void)sendTouch:(WebEventType)type phase:(WebEventTouchPhaseType)phase at:(CGPoint)point
{
    /* -sendEvent: hands the event to the web thread and waits for the web thread
     * to finish with it. Called from the main thread that is a wait on whatever
     * the page happens to be doing, which is why taps appeared to do nothing.
     * WebThreadRun() puts the event on the web thread's own queue instead. */
    WAKWindow *window = [_wakWindow retain];
    WebEvent *event = [touchEvent(type, phase, point) retain];
    WebThreadRun(^{
        [window sendEvent:event];
        [event release];
        [window release];
    });
}

/* The pan recogniser and the page want the same finger, and UIKit decides in
 * favour of the pan the moment a drag begins. From then on the page is told the
 * touch was cancelled and no further move is forwarded: otherwise every frame
 * of a scroll also queued a WebEventTouchChange for a page that is not going to
 * see the end of the sequence anyway. */
- (void)cancelPageTouchForScrolling
{
    if (!_touchInPage || _touchCancelledByScroll)
        return;
    _touchCancelledByScroll = YES;
    [self sendTouch:WebEventTouchCancel phase:WebEventTouchPhaseCancelled at:_lastTouchPoint];
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    CGPoint point = [[touches anyObject] locationInView:_scrollView];
    LOG_STEP("touch began %g,%g", point.x, point.y);
    _touchInPage = YES;
    _touchCancelledByScroll = NO;
    _lastTouchPoint = point;
    [self sendTouch:WebEventTouchBegin phase:WebEventTouchPhaseBegan at:point];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    CGPoint point = [[touches anyObject] locationInView:_scrollView];
    _lastTouchPoint = point;
    if (_touchCancelledByScroll)
        return;
    [self sendTouch:WebEventTouchChange phase:WebEventTouchPhaseMoved at:point];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    CGPoint point = [[touches anyObject] locationInView:_scrollView];
    LOG_STEP("touch ended %g,%g", point.x, point.y);
    _touchInPage = NO;
    if (!_touchCancelledByScroll)
        [self sendTouchEndThenTapAt:point];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
    CGPoint point = [[touches anyObject] locationInView:_scrollView];
    _touchInPage = NO;
    if (_touchCancelledByScroll)
        return;
    _touchCancelledByScroll = YES;
    [self sendTouch:WebEventTouchCancel phase:WebEventTouchPhaseCancelled at:point];
}

static void sumLayerBacking(CALayer *layer, double *bytes, unsigned *withContents, unsigned *total)
{
    if (!layer)
        return;
    (*total)++;
    if ([layer contents]) {
        (*withContents)++;
        CGRect bounds = [layer bounds];
        CGFloat scale = [layer respondsToSelector:@selector(contentsScale)] ? [layer contentsScale] : 1.0;
        *bytes += bounds.size.width * scale * bounds.size.height * scale * 4.0;
    }
    for (CALayer *child in [layer sublayers])
        sumLayerBacking(child, bytes, withContents, total);
}

- (void)reportMemoryBreakdown
{
    NSDictionary *engine = [WebCoreStatistics memoryStatistics];
    NSArray *cache = [WebCache statistics];

    double jsHeap = [engine[@"JavaScriptHeapSize"] doubleValue];
    double jsFree = [engine[@"JavaScriptFreeSize"] doubleValue];
    double jsJIT = [engine[@"JavaScriptJITSize"] doubleValue];
    double fastCommitted = [engine[@"FastMallocCommittedVMBytes"] doubleValue];
    double fastFree = [engine[@"FastMallocFreeListBytes"] doubleValue];

    double imageCount = 0, imageSize = 0, imageLive = 0, imageDecoded = 0;
    double scriptCount = 0, scriptSize = 0, scriptLive = 0, scriptDecoded = 0;
    double styleSize = 0, styleDecoded = 0;
    if ([cache count] >= 4) {
        imageCount = [[[cache objectAtIndex:0] objectForKey:@"Images"] doubleValue];
        imageSize = [[[cache objectAtIndex:1] objectForKey:@"Images"] doubleValue];
        imageLive = [[[cache objectAtIndex:2] objectForKey:@"Images"] doubleValue];
        imageDecoded = [[[cache objectAtIndex:3] objectForKey:@"Images"] doubleValue];
        scriptCount = [[[cache objectAtIndex:0] objectForKey:@"JavaScript"] doubleValue];
        scriptSize = [[[cache objectAtIndex:1] objectForKey:@"JavaScript"] doubleValue];
        scriptLive = [[[cache objectAtIndex:2] objectForKey:@"JavaScript"] doubleValue];
        scriptDecoded = [[[cache objectAtIndex:3] objectForKey:@"JavaScript"] doubleValue];
        styleSize = [[[cache objectAtIndex:1] objectForKey:@"CSS"] doubleValue];
        styleDecoded = [[[cache objectAtIndex:3] objectForKey:@"CSS"] doubleValue];
    }

    NSString *fixedReport = [_webView stringByEvaluatingJavaScriptFromString:
        @"(function(){try{var out=[];var all=document.getElementsByTagName('*');"
        @"for(var i=0;i<all.length;i++){var e=all[i];var p=getComputedStyle(e).position;"
        @"if(p!=='fixed'&&p!=='sticky')continue;var r=e.getBoundingClientRect();"
        @"if(r.width<40||r.height<10)continue;"
        @"out.push(p[0]+':'+e.tagName+'@'+Math.round(r.top)+','+Math.round(r.left)+' '+Math.round(r.width)+'x'+Math.round(r.height));"
        @"if(out.length>5)break;}"
        @"return 'scrollY='+Math.round(window.pageYOffset)+' ['+out.join(' | ')+']';}catch(e){return 'err '+e;}})()"];
    LOG_STEP("fixed: %s", [fixedReport UTF8String] ?: "n/a");

    if (!access("/tmp/probe-nav", F_OK)) {
        FILE *clearProbe = fopen("/tmp/probe-nav", "w");
        if (clearProbe)
            fclose(clearProbe);
        NSString *nav = [_webView stringByEvaluatingJavaScriptFromString:
            @"(function(){try{var out=[];"
            @"var links=document.querySelectorAll('a[href],[role=link],[role=button],[role=tab]');"
            @"for(var i=0;i<links.length&&out.length<14;i++){var e=links[i];"
            @"var r=e.getBoundingClientRect();"
            @"if(r.width<20||r.height<20||r.bottom<0||r.top>window.innerHeight)continue;"
            @"var label=(e.getAttribute('aria-label')||e.getAttribute('href')||e.tagName);"
            @"out.push(Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2)+':'+label.substring(0,26));}"
            @"return 'url='+location.pathname+' vh='+window.innerHeight+' | '+out.join(' | ');}catch(e){return 'err '+e;}})()"];
        LOG_STEP("nav: %s", [nav UTF8String] ?: "n/a");
    }

    NSString *domCounts = [_webView stringByEvaluatingJavaScriptFromString:
        @"(function(){try{var a=document.getElementsByTagName('*').length;"
        @"var i=document.images.length;var d=0,t=0;"
        @"for(var k=0;k<document.images.length;k++){var m=document.images[k];"
        @"if(m.naturalWidth){t++;d+=m.naturalWidth*m.naturalHeight*4;}}"
        @"return a+','+i+','+t+','+Math.round(d/1048576);}catch(e){return 'err';}})()"];

    double layerBytes = 0;
    unsigned layersWithContents = 0, layersTotal = 0;
    sumLayerBacking([[[UIApplication sharedApplication] keyWindow] layer], &layerBytes, &layersWithContents, &layersTotal);
    double compositingBytes = 0;
    unsigned compositingWithContents = 0, compositingTotal = 0;
    sumLayerBacking(_compositingRootLayer, &compositingBytes, &compositingWithContents, &compositingTotal);

    NSURLCache *urlCache = [NSURLCache sharedURLCache];
    double urlCacheMemory = [urlCache currentMemoryUsage];
    double urlCacheCapacity = [urlCache memoryCapacity];

    NSCountedSet *types = [WebCoreStatistics javaScriptObjectTypeCounts];
    NSMutableArray *ranked = [NSMutableArray array];
    for (NSString *type in types)
        [ranked addObject:[NSArray arrayWithObjects:type, [NSNumber numberWithUnsignedInteger:[types countForObject:type]], nil]];
    [ranked sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [[b objectAtIndex:1] compare:[a objectAtIndex:1]];
    }];
    NSMutableString *topTypes = [NSMutableString string];
    for (NSUInteger i = 0; i < [ranked count] && i < 6; i++)
        [topTypes appendFormat:@"%@%@=%@", i ? @" " : @"", [[ranked objectAtIndex:i] objectAtIndex:0], [[ranked objectAtIndex:i] objectAtIndex:1]];

    static const double MB = 1024.0 * 1024.0;
    LOG_STEP("memory: jsHeap %.1f (free %.1f) | jit %.1f | fastMalloc %.1f (free %.1f) | images %.0f: size %.1f live %.1f decoded %.1f | layers %.1f in %u/%u | jsObjects %zu | dom(all,img,loaded,decodedMB) %s | glyphPages %zu fonts %zu",
        jsHeap / MB, jsFree / MB, jsJIT / MB, fastCommitted / MB, fastFree / MB,
        imageCount, imageSize / MB, imageLive / MB, imageDecoded / MB,
        layerBytes / MB, layersWithContents, layersTotal,
        [WebCoreStatistics javaScriptObjectsCount],
        [domCounts UTF8String] ?: "n/a",
        [WebCoreStatistics glyphPageCount], [WebCoreStatistics cachedFontDataCount]);
    NSDictionary *code = [WebCoreStatistics codeMemoryStatistics];
    LOG_STEP("layers: window %.1f MB in %u/%u | compositing tree %.1f MB in %u/%u",
        layerBytes / MB, layersWithContents, layersTotal,
        compositingBytes / MB, compositingWithContents, compositingTotal);
    LOG_STEP("code: unlinked %lu blocks = %.1f MB | linked %lu blocks = %.1f MB | executables %lu = %.1f MB",
        (unsigned long)[code[@"UnlinkedCodeBlockCount"] unsignedLongValue], [code[@"UnlinkedCodeBlockBytes"] doubleValue] / MB,
        (unsigned long)[code[@"CodeBlockCount"] unsignedLongValue], [code[@"CodeBlockBytes"] doubleValue] / MB,
        (unsigned long)[code[@"ExecutableCount"] unsignedLongValue], [code[@"SourceBytes"] doubleValue] / MB);
    LOG_STEP("memory2: urlCache %.1f of %.1f MB | scripts %.0f: size %.1f live %.1f decoded %.1f | css size %.1f decoded %.1f | jsTypes %s",
        urlCacheMemory / MB, urlCacheCapacity / MB,
        scriptCount, scriptSize / MB, scriptLive / MB, scriptDecoded / MB,
        styleSize / MB, styleDecoded / MB, [topTypes UTF8String] ?: "");
}

static unsigned gHistogramBuckets[24];
static uint64_t gHistogramBytes[24];

static unsigned bucketForSize(vm_size_t size)
{
    unsigned bucket = 0;
    while (bucket < 23 && size > (vm_size_t)(16u << bucket))
        bucket++;
    return bucket;
}

static void recordRanges(task_t task, void *context, unsigned type, vm_range_t *ranges, unsigned count)
{
    (void)task; (void)context; (void)type;
    for (unsigned i = 0; i < count; i++) {
        unsigned bucket = bucketForSize(ranges[i].size);
        gHistogramBuckets[bucket]++;
        gHistogramBytes[bucket] += ranges[i].size;
    }
}

static kern_return_t readInProcess(task_t task, vm_address_t address, vm_size_t size, void **out)
{
    (void)task; (void)size;
    *out = (void *)address;
    return KERN_SUCCESS;
}

- (void)reportAllocationHistogram
{
    memset(gHistogramBuckets, 0, sizeof(gHistogramBuckets));
    memset(gHistogramBytes, 0, sizeof(gHistogramBytes));

    vm_address_t *zones = NULL;
    unsigned zoneCount = 0;
    if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &zoneCount) != KERN_SUCCESS)
        return;

    for (unsigned z = 0; z < zoneCount; z++) {
        malloc_zone_t *zone = (malloc_zone_t *)zones[z];
        if (!zone || !zone->introspect || !zone->introspect->enumerator)
            continue;
        zone->introspect->enumerator(mach_task_self(), NULL, MALLOC_PTR_IN_USE_RANGE_TYPE,
            (vm_address_t)zone, readInProcess, recordRanges);
    }

    for (unsigned bucket = 0; bucket < 24; bucket++) {
        if (!gHistogramBuckets[bucket])
            continue;
        LOG_STEP("  alloc <=%u B: %u blocks, %.1f MB", 16u << bucket,
            gHistogramBuckets[bucket], gHistogramBytes[bucket] / (1024.0 * 1024.0));
    }
}

/* The process is killed with no record of why, so its own footprint is the
 * only evidence available. */
- (void)reportFootprint
{
    struct task_basic_info info;
    mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
    BOOL gotInfo = task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS;
    if (gotInfo)
        LOG_STEP("footprint %.1f MB at %.0f s", info.resident_size / (1024.0 * 1024.0),
            -[_start timeIntervalSinceNow]);

    static int breakdownTick = 0;
    if (++breakdownTick % 5 == 0)
        WebThreadRun(^{ [self reportMemoryBreakdown]; });

    if (!access("/tmp/scavenge", F_OK)) {
        FILE *clearScavenge = fopen("/tmp/scavenge", "w");
        if (clearScavenge)
            fclose(clearScavenge);
        struct task_basic_info before;
        mach_msg_type_number_t beforeCount = TASK_BASIC_INFO_COUNT;
        task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&before, &beforeCount);
        WebThreadRun(^{
            [WebCoreStatistics garbageCollectJavaScriptObjects];
            [WebCoreStatistics returnFreeMemoryToSystem];
            [WebCache empty];
            vm_address_t *zones = NULL;
            unsigned zoneCount = 0;
            size_t inUseBefore = 0, allocatedBefore = 0;
            if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &zoneCount) == KERN_SUCCESS) {
                for (unsigned z = 0; z < zoneCount; z++) {
                    malloc_zone_t *zone = (malloc_zone_t *)zones[z];
                    if (!zone)
                        continue;
                    if (zone->introspect && zone->introspect->statistics) {
                        malloc_statistics_t statistics;
                        memset(&statistics, 0, sizeof(statistics));
                        zone->introspect->statistics(zone, &statistics);
                        inUseBefore += statistics.size_in_use;
                        allocatedBefore += statistics.size_allocated;
                    }
                    malloc_zone_pressure_relief(zone, 0);
                }
                LOG_STEP("scavenge: zones %u, in use %.1f MB, allocated %.1f MB before relief",
                    zoneCount, inUseBefore / (1024.0 * 1024.0), allocatedBefore / (1024.0 * 1024.0));
            }
            struct task_basic_info after;
            mach_msg_type_number_t afterCount = TASK_BASIC_INFO_COUNT;
            task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&after, &afterCount);
            LOG_STEP("scavenge: %.1f MB -> %.1f MB (released %.1f MB)",
                before.resident_size / (1024.0 * 1024.0),
                after.resident_size / (1024.0 * 1024.0),
                (double)((long long)before.resident_size - (long long)after.resident_size) / (1024.0 * 1024.0));
        });
    }

    static vm_size_t footprintAtLastCollection;
    if (gotInfo) {
        if (!footprintAtLastCollection)
            footprintAtLastCollection = info.resident_size;
        BOOL grew = info.resident_size > footprintAtLastCollection + 8 * 1024 * 1024;
        BOOL high = info.resident_size > 135 * 1024 * 1024;
        if (grew || high) {
            footprintAtLastCollection = info.resident_size;
            WebThreadRun(^{
                [WebCoreStatistics garbageCollectJavaScriptObjects];
            });
        } else if (info.resident_size < footprintAtLastCollection)
            footprintAtLastCollection = info.resident_size;
    }
    /* A screenshot on demand. Nobody can see this screen from where the work is
     * being done, and reporting on a page without having looked at it is how
     * three wrong claims got made in a row. Touching /tmp/snap asks for one.
     *
     * It runs on the web thread because -[LegacyTileHostLayer renderInContext:]
     * takes the web thread lock to draw, and taking that from the main thread
     * freezes the interface for as long as the page is busy - which is what the
     * stall watchdog caught the old timer-driven version doing. */
    /* /tmp is sticky and these files are written by root while this runs as
     * mobile, so unlink() is refused and the trigger would fire for ever.
     * Emptying the file is something the owner permits and says the same thing. */
    if (!access("/tmp/snap", F_OK)) {
        struct stat marker;
        if (!stat("/tmp/snap", &marker) && marker.st_mtime != gLastSnapRequest) {
            FILE *clear = fopen("/tmp/snap", "w");
            if (clear) fclose(clear);
            if (!stat("/tmp/snap", &marker))
                gLastSnapRequest = marker.st_mtime;
            /* On the main thread: -renderInContext: walks a UIKit layer tree,
             * and doing that from another thread freezes the interface. */
            [self writeSnapshot];
        }
    }

    /* Arbitrary script on demand, written into /tmp/js. This is how a question
     * about the page gets answered without asking someone to hold the phone. */
    if (!access("/tmp/js", F_OK)) {
        NSString *script = [NSString stringWithContentsOfFile:@"/tmp/js"
            encoding:NSUTF8StringEncoding error:NULL];
        FILE *clear = fopen("/tmp/js", "w");
        if (clear) fclose(clear);
        if ([script length]) {
            WebView *webView = _webView;
            WebThreadRun(^{
                NSString *answer = [webView stringByEvaluatingJavaScriptFromString:script];
                LOG_STEP("js: %s", [answer UTF8String] ?: "(no answer)");
            });
        }
    }

    static time_t lastScrollRequest;
    struct stat scrollMarker;
    if (!stat("/tmp/scroll", &scrollMarker) && scrollMarker.st_mtime != lastScrollRequest) {
        lastScrollRequest = scrollMarker.st_mtime;
        NSString *where = [NSString stringWithContentsOfFile:@"/tmp/scroll"
            encoding:NSUTF8StringEncoding error:NULL];
        FILE *clearScroll = fopen("/tmp/scroll", "w");
        if (clearScroll) fclose(clearScroll);
        NSArray *parts = [where componentsSeparatedByString:@","];
        if ([parts count] == 2) {
            CGPoint target = CGPointMake([[parts objectAtIndex:0] floatValue],
                                         [[parts objectAtIndex:1] floatValue]);
            [self->_scrollView setContentOffset:target animated:NO];
            [self restoreNormalTilingAfterScrolling];
            LOG_STEP("scrolled to %g,%g (content %g x %g)", target.x, target.y,
                [self->_scrollView contentSize].width, [self->_scrollView contentSize].height);
        }
    }

    /* A tap on demand, at screen coordinates, written as "x,y" into /tmp/tap.
     * The same reason as the screenshot above: whether a tap reaches the page is
     * not something that can be established by reading the code, and asking
     * someone to press the screen and describe what happened is a slow and lossy
     * way to find out. This sends exactly what a finger sends. */
    static time_t lastTapRequest;
    struct stat tapMarker;
    if (!stat("/tmp/tap", &tapMarker) && tapMarker.st_mtime != lastTapRequest) {
        lastTapRequest = tapMarker.st_mtime;
        NSString *where = [NSString stringWithContentsOfFile:@"/tmp/tap"
            encoding:NSUTF8StringEncoding error:NULL];
        FILE *clearTap = fopen("/tmp/tap", "w");
        if (clearTap) fclose(clearTap);
        NSArray *parts = [where componentsSeparatedByString:@","];
        LOG_STEP("tap trigger: read %s, %lu parts",
            where ? [[where stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] UTF8String] : "(nil)",
            (unsigned long)[parts count]);
        if ([parts count] == 2) {
            CGPoint onScreen = CGPointMake([[parts objectAtIndex:0] floatValue],
                                           [[parts objectAtIndex:1] floatValue]);
            [self tapAtScreenPoint:onScreen];
        }
    }

    if (!access("/tmp/compare-webview", F_OK)) {
        FILE *clearCompare = fopen("/tmp/compare-webview", "w");
        if (clearCompare)
            fclose(clearCompare);
        Class systemWebView = NSClassFromString(@"WebView");
        Class ourWebView = NSClassFromString(@"LegacyIOSWebView");
        if (!systemWebView || !ourWebView) {
            LOG_STEP("compare: system %p ours %p", systemWebView, ourWebView);
        } else {
            NSMutableSet *oursSelectors = [NSMutableSet set];
            for (Class c = ourWebView; c && c != [NSObject class]; c = class_getSuperclass(c)) {
                unsigned count = 0;
                Method *methods = class_copyMethodList(c, &count);
                for (unsigned i = 0; i < count; i++)
                    [oursSelectors addObject:NSStringFromSelector(method_getName(methods[i]))];
                free(methods);
            }
            unsigned systemTotal = 0, missing = 0;
            NSMutableArray *missingNames = [NSMutableArray array];
            for (Class c = systemWebView; c && c != [NSObject class]; c = class_getSuperclass(c)) {
                unsigned count = 0;
                Method *methods = class_copyMethodList(c, &count);
                for (unsigned i = 0; i < count; i++) {
                    NSString *name = NSStringFromSelector(method_getName(methods[i]));
                    systemTotal++;
                    if (![oursSelectors containsObject:name]) {
                        missing++;
                        if ([missingNames count] < 40)
                            [missingNames addObject:name];
                    }
                }
                free(methods);
            }
            LOG_STEP("compare: system WebView has %u methods, ours has %u, missing from ours %u",
                systemTotal, (unsigned)[oursSelectors count], missing);
            LOG_STEP("compare missing: %s",
                [[missingNames componentsJoinedByString:@" "] UTF8String] ?: "");
        }
    }

    static time_t lastDragRequest;
    struct stat dragMarker;
    if (!stat("/tmp/drag", &dragMarker) && dragMarker.st_mtime != lastDragRequest) {
        lastDragRequest = dragMarker.st_mtime;
        NSString *where = [NSString stringWithContentsOfFile:@"/tmp/drag"
            encoding:NSUTF8StringEncoding error:NULL];
        FILE *clearDrag = fopen("/tmp/drag", "w");
        if (clearDrag)
            fclose(clearDrag);
        NSArray *parts = [where componentsSeparatedByString:@","];
        if ([parts count] == 2) {
            CGFloat from = [[parts objectAtIndex:0] floatValue];
            CGFloat to = [[parts objectAtIndex:1] floatValue];
            LOG_STEP("drag: %g -> %g (content %g)", from, to, [_scrollView contentSize].height);
            [_scrollView setContentOffset:CGPointMake(0, from) animated:NO];
            [self scrollViewWillBeginDragging:_scrollView];
            CGFloat step = (to - from) / 8;
            for (int i = 1; i <= 8; i++) {
                [_scrollView setContentOffset:CGPointMake(0, from + step * i) animated:NO];
                [self scrollViewDidScroll:_scrollView];
            }
            [self scrollViewDidEndDragging:_scrollView willDecelerate:NO];
            LOG_STEP("drag ended at %g (content %g)", [_scrollView contentOffset].y,
                [_scrollView contentSize].height);
        }
    }

    if (!access("/tmp/repaint", F_OK)) {
        FILE *clearRepaint = fopen("/tmp/repaint", "w");
        if (clearRepaint)
            fclose(clearRepaint);
        WAKWindow *window = [_wakWindow retain];
        WebThreadRun(^{
            [window setNeedsDisplay];
            [window layoutTiles];
            [window release];
            LOG_STEP("forced repaint");
        });
    }

    if (!access("/tmp/histogram", F_OK)) {
        FILE *clearHistogram = fopen("/tmp/histogram", "w");
        if (clearHistogram)
            fclose(clearHistogram);
        [self reportAllocationHistogram];
    }

    static int statsCounter;
    if (++statsCounter >= 1) {
        statsCounter = 0;

        vm_address_t *zones = NULL;
        unsigned zoneCount = 0;
        if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &zoneCount) == KERN_SUCCESS) {
            size_t totalInUse = 0, totalSize = 0;
            for (unsigned z = 0; z < zoneCount; z++) {
                malloc_zone_t *zone = (malloc_zone_t *)zones[z];
                if (!zone || !zone->introspect || !zone->introspect->statistics)
                    continue;
                malloc_statistics_t statistics;
                memset(&statistics, 0, sizeof(statistics));
                zone->introspect->statistics(zone, &statistics);
                totalInUse += statistics.size_in_use;
                totalSize += statistics.size_allocated;
                if (statistics.size_in_use > 512 * 1024)
                    LOG_STEP("  zone %s: in use %.1f MB, allocated %.1f MB, blocks %u",
                        malloc_get_zone_name(zone) ?: "(unnamed)",
                        statistics.size_in_use / (1024.0 * 1024.0),
                        statistics.size_allocated / (1024.0 * 1024.0),
                        statistics.blocks_in_use);
            }
            LOG_STEP("malloc zones: %u, in use %.1f MB, allocated %.1f MB",
                zoneCount, totalInUse / (1024.0 * 1024.0), totalSize / (1024.0 * 1024.0));
        }

        WebView *statsView = _webView;
        WebThreadRun(^{
            LOG_STEP("renderTree %lu nodes, cache %s",
                (unsigned long)[statsView _renderTreeSize],
                [[[WebCache statistics] description] UTF8String] ?: "?");
        });

        {
            extern kern_return_t mach_vm_region_recurse(vm_map_t, mach_vm_address_t *, mach_vm_size_t *, natural_t *, vm_region_recurse_info_t, mach_msg_type_number_t *);
            mach_vm_address_t address = 0;
            uint64_t textResident = 0, anonResident = 0, otherResident = 0, totalResident = 0;
            uint64_t webcoreText = 0, jscText = 0;
            static uint64_t residentByTag[256];
            memset(residentByTag, 0, sizeof(residentByTag));
            static unsigned bigRegionTag[24];
            static uint64_t bigRegionBytes[24];
            unsigned bigRegionCount = 0;
            for (;;) {
                mach_vm_size_t regionSize = 0;
                natural_t depth = 1;
                vm_region_submap_info_data_64_t info;
                mach_msg_type_number_t infoCount = VM_REGION_SUBMAP_INFO_COUNT_64;
                if (mach_vm_region_recurse(mach_task_self(), &address, &regionSize, &depth,
                        (vm_region_recurse_info_t)&info, &infoCount) != KERN_SUCCESS)
                    break;
                if (info.is_submap) {
                    depth++;
                    continue;
                }
                uint64_t resident = (uint64_t)info.pages_resident * vm_page_size;
                totalResident += resident;
                Dl_info symbol;
                if (info.share_mode != SM_PRIVATE && dladdr((void *)(uintptr_t)address, &symbol) && symbol.dli_fname) {
                    textResident += resident;
                    if (strstr(symbol.dli_fname, "WebCore"))
                        webcoreText += resident;
                    else if (strstr(symbol.dli_fname, "JavaScriptCore"))
                        jscText += resident;
                } else if (dladdr((void *)(uintptr_t)address, &symbol) && symbol.dli_fname) {
                    textResident += resident;
                    if (strstr(symbol.dli_fname, "WebCore"))
                        webcoreText += resident;
                    else if (strstr(symbol.dli_fname, "JavaScriptCore"))
                        jscText += resident;
                } else if (info.user_tag == VM_MEMORY_MALLOC || info.user_tag == VM_MEMORY_MALLOC_SMALL
                        || info.user_tag == VM_MEMORY_MALLOC_LARGE || info.user_tag == VM_MEMORY_MALLOC_TINY
                        || info.user_tag == VM_MEMORY_MALLOC_HUGE || !info.user_tag)
                    anonResident += resident;
                else
                    otherResident += resident;

                if (info.user_tag < 256)
                    residentByTag[info.user_tag] += resident;

                if (resident >= 1048576 && bigRegionCount < 24) {
                    bigRegionTag[bigRegionCount] = info.user_tag;
                    bigRegionBytes[bigRegionCount] = resident;
                    bigRegionCount++;
                }
                address += regionSize;
            }

            for (unsigned pick = 0; pick < 8; pick++) {
                unsigned best = 0;
                for (unsigned tag = 1; tag < 256; tag++) {
                    if (residentByTag[tag] > residentByTag[best])
                        best = tag;
                }
                if (!residentByTag[best] || residentByTag[best] < 1048576)
                    break;
                LOG_STEP("  vmtag %u: %.1f MB", best, residentByTag[best] / 1048576.0);
                residentByTag[best] = 0;
            }

            for (unsigned r = 0; r < bigRegionCount; r++) {
                if (bigRegionBytes[r] >= 2 * 1048576)
                    LOG_STEP("  region tag %u: %.1f MB", bigRegionTag[r], bigRegionBytes[r] / 1048576.0);
            }
            LOG_STEP("vmmap: total %.1f MB | mapped code %.1f MB (WebCore %.1f, JSC %.1f) | malloc/anon %.1f MB | other %.1f MB",
                totalResident / 1048576.0, textResident / 1048576.0,
                webcoreText / 1048576.0, jscText / 1048576.0,
                anonResident / 1048576.0, otherResident / 1048576.0);
        }

        task_vm_info_data_t vmInfo;
        mach_msg_type_number_t vmCount = TASK_VM_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &vmCount) == KERN_SUCCESS)
            LOG_STEP("vm: internal %.1f MB, compressed %.1f MB, resident %.1f MB",
                vmInfo.internal / (1024.0 * 1024.0),
                vmInfo.compressed / (1024.0 * 1024.0),
                vmInfo.resident_size / (1024.0 * 1024.0));
        WebThreadRun(^{
            LOG_STEP("jsObjects %zu globals %zu memStats %s",
                [WebCoreStatistics javaScriptObjectsCount],
                [WebCoreStatistics javaScriptGlobalObjectsCount],
                [[[WebCoreStatistics memoryStatistics] description] UTF8String]);
            LOG_STEP("jsTypeCounts %s",
                [[[WebCoreStatistics javaScriptObjectTypeCounts] description] UTF8String]);
        });
    }

    [self performSelector:@selector(reportFootprint) withObject:nil afterDelay:2.0];
}

/* Sizing the engine to the document.
 *
 * A tile is only made inside the host layer and is only painted where the
 * window's content view reaches: LegacyTileGrid::bounds() is the host layer's
 * size, and -[WAKView _drawRect:context:lockFocus:] intersects the rect it is
 * given with its own bounds and returns if nothing is left. With both left at
 * one screen there is exactly one screen of tiles, every pixel of it wrong the
 * moment the page moves — which is why scrolling used to mean repainting.
 *
 * Sized to the document, tiles are in document coordinates: the scroll view
 * moves the host layer, the tiles under it stay valid, and only newly exposed
 * area has to be painted at all.
 *
 * Layout stays on the screen size. -_setFixedLayoutSize: pins
 * ScrollView::layoutSize() — the initial containing block, so
 * documentElement.clientHeight and the CSS viewport units — to the viewport
 * whatever the view is resized to, and makes
 * LocalFrameView::shouldLayoutAfterContentsResized() false, so growing the view
 * to fit the content cannot feed back into a taller layout and grow it again.
 * (webkit.org/b/165781 is that loop; useFixedLayout() is its guard.) */
- (void)setDocumentSize:(CGSize)size
{
    if (size.width < _viewportSize.width)
        size.width = _viewportSize.width;
    if (size.height < _viewportSize.height)
        size.height = _viewportSize.height;
    if (CGSizeEqualToSize(size, _documentSize))
        return;
    _documentSize = size;

    [_scrollView setContentSize:size];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_hostLayer setBounds:CGRectMake(0, 0, size.width, size.height)];
    [_hostLayer setPosition:CGPointZero];
    [CATransaction commit];

    WAKWindow *window = [_wakWindow retain];
    WebView *webView = [_webView retain];
    CGSize viewport = _viewportSize;
    WebThreadRun(^{
        /* -setContentRect: is how the tile cache is told the host layer changed
         * size: it calls LegacyTileCache::hostLayerSizeChanged(), which resizes
         * each grid's own layer to match. */
        [window setContentRect:CGRectMake(0, 0, size.width, size.height)];
        [webView _setFixedLayoutSize:viewport];
        [webView setFrame:CGRectMake(0, 0, size.width, size.height)];
        [window layoutTiles];
        [webView release];
        [window release];
    });
    LOG_STEP("document %g x %g", size.width, size.height);
}

/* WebKitRootLayerHandler. Called on the main thread (WebKitUIKitDelegate
 * hops there itself) whenever WebCore has a compositing layer tree to show -
 * or, with a nil layer, when it no longer does. _hostLayer is already in
 * document coordinates (see setDocumentSize: above, and the tile-size
 * comment on the ivar), the same space GraphicsLayer positions the root
 * layer in, so parenting it here needs no extra geometry of our own; WebCore
 * keeps it positioned and sized as the page's composited content changes.
 * Added as a sibling of WAKWindow's own tile-host sublayer, on top: the tile
 * cache keeps painting ordinary (non-promoted) document content on the CPU,
 * and this layer is only what the engine chose to promote out of that -
 * position:fixed by default, plus anything else WebCore itself decides
 * warrants its own GPU layer. */
- (void)attachRootLayer:(CALayer *)rootLayer
{
    if (_compositingRootLayer == rootLayer)
        return;
    [_compositingRootLayer removeFromSuperlayer];
    _compositingRootLayer = rootLayer;
    if (rootLayer)
        [_hostLayer addSublayer:rootLayer];
}

/* End-to-end check that a touch reaches the page: find a link, tap where it is,
 * and see whether the frame navigates. */
- (void)tapFirstLink
{
    withWebLock(^{
        [self tapFirstLinkLocked];
    });
}

- (void)tapFirstLinkLocked
{
    NSString *where = [_webView stringByEvaluatingJavaScriptFromString:
        @"(function(){var a=document.querySelectorAll('a[href]');"
         "for(var i=0;i<a.length;i++){var r=a[i].getBoundingClientRect();"
         "if(r.width>20&&r.height>8&&r.top>0&&r.top<400)"
         "return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2)+','+a[i].href;}"
         "return '';})()"];

    NSArray *parts = [where componentsSeparatedByString:@","];
    if ([parts count] < 3) {
        LOG_STEP("tap: no link found");
        return;
    }
    CGPoint offset = [_scrollView contentOffset];
    CGPoint point = CGPointMake([[parts objectAtIndex:0] floatValue] + offset.x,
        [[parts objectAtIndex:1] floatValue] + offset.y);
    LOG_STEP("tap at %g,%g targeting %s", point.x, point.y,
        [[parts objectAtIndex:2] UTF8String]);

    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/tap-via-script"]) {
        [_webView stringByEvaluatingJavaScriptFromString:
            @"(function(){var a=document.querySelectorAll('a[href]');"
             "for(var i=0;i<a.length;i++){var r=a[i].getBoundingClientRect();"
             "if(r.width>20&&r.height>8&&r.top>0&&r.top<400){a[i].click();return;}}})()"];
        LOG_STEP("clicked by script");
    } else
        [self sendTapAt:point];
    [self performSelector:@selector(reportURL) withObject:nil afterDelay:6.0];
}

- (void)reportURL
{
    LOG_STEP("after tap, url is %s", [[_webView mainFrameURL] UTF8String] ?: "?");
}

/* The engine's own contents size. WebCore pushes it onto the WAK document view
 * (ScrollView::platformSetContentsSize is -[WAKView setBoundsSize:]), so this
 * is the laid out document rather than an estimate, and it runs no JavaScript.
 * Layout happens after the load finishes, so this is asked again a few times. */
/* Tiles ahead of the finger are built first: the tile cache biases its
 * speculative order along the direction it is told about. */
static WAKTilingDirection tilingDirectionForDelta(CGPoint delta)
{
    if (fabs(delta.y) >= fabs(delta.x))
        return delta.y >= 0 ? kWAKTilingDirectionDown : kWAKTilingDirectionUp;
    return delta.x >= 0 ? kWAKTilingDirectionRight : kWAKTilingDirectionLeft;
}

- (void)contentsSizeChanged:(NSValue *)boxedSize
{
    CGSize content = [boxedSize CGSizeValue];
    if (content.width < 1 || content.height < 1)
        return;
    [self applyDocumentHeight:content.height];
}

- (void)applyDocumentHeight:(CGFloat)height
{
    if (height > _viewportSize.height)
        _documentGrewBeyondViewport = YES;
    else if (_documentGrewBeyondViewport)
        return;

    if (height > _tallestDocumentHeight)
        _tallestDocumentHeight = height;
    else if (_tallestDocumentHeight > 0)
        height = _tallestDocumentHeight;

    CGSize page = CGSizeMake(_viewportSize.width, MAX(height, _viewportSize.height));
    if (CGSizeEqualToSize(page, [_scrollView contentSize]))
        return;

    CGPoint offset = [_scrollView contentOffset];
    [self setDocumentSize:page];
    [_scrollView setContentSize:page];

    CGFloat furthest = MAX(0, page.height - _viewportSize.height);
    if (offset.y > furthest)
        offset.y = furthest;
    if (!CGPointEqualToPoint(offset, [_scrollView contentOffset]))
        [_scrollView setContentOffset:offset animated:NO];

    LOG_STEP("content size %g x %g (offset %g, was %g, dragging %d)", page.width, page.height,
        offset.y, [_scrollView contentOffset].y, (int)[_scrollView isDragging]);
    if (_settled)
        [self settle];
}

- (void)updateContentSize
{
    withWebLock(^{
        CGSize content = [self->_webView _contentsSize];
        if (content.width < 1 || content.height < 1)
            return;
        /* The scroll view is UIKit, and UIKit is the main thread's. */
        dispatch_async(dispatch_get_main_queue(), ^{
            [self applyDocumentHeight:content.height];
        });
    });
    /* A feed grows as it loads more, so this is a standing question, not one
     * asked once. It costs a short script on the web thread. */
    [self performSelector:@selector(updateContentSize) withObject:nil afterDelay:5.0];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    [self cancelPageTouchForScrolling];
    [_wakWindow setTilingMode:kWAKWindowTilingModePanning];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    CGPoint offset = [scrollView contentOffset];
    CGPoint delta = CGPointMake(offset.x - _lastOffset.x, offset.y - _lastOffset.y);
    if (delta.y < -120 && !_scrollView.isDragging)
        LOG_STEP("SNAPBACK %g -> %g (content %g, viewport %g, dragging %d, decelerating %d)",
            _lastOffset.y, offset.y, [scrollView contentSize].height, _viewportSize.height,
            (int)[scrollView isDragging], (int)[scrollView isDecelerating]);
    _lastOffset = offset;

    /* Nothing on this path takes the web thread lock. The host layer is a
     * sublayer of the scroll view's, so Core Animation has already moved the
     * painted document under the finger; all that is left is to say where the
     * viewport now is and to ask, without waiting, for whatever tiles that
     * needs. -[WAKWindow layoutTiles] is a WebThreadRun behind
     * m_hasPendingLayoutTiles, so calling it every event queues at most one. */
    if (delta.x || delta.y)
        [_wakWindow setTilingDirection:tilingDirectionForDelta(delta)];
    [_wakWindow setExposedScrollViewRect:CGRectMake(offset.x, offset.y,
        _viewportSize.width, _viewportSize.height)];

    /* This is what keeps a site's own chrome - its top bar, its tab bar, its
     * dialogs - standing still while the content moves under them.
     *
     * Everything here is painted into tiles in document coordinates and the
     * scroll view slides those tiles under the screen, so on its own a
     * position:fixed element scrolls away with everything else. WebCore has the
     * machinery for exactly this case: told where the viewport currently is, it
     * lays fixed elements out against that rectangle instead of against the top
     * of the document, so they land where they should in the tiles being
     * painted. UIWebView calls this on every scroll event; we now do too.
     *
     * synchronize:NO means the rect is published on the web thread's next turn
     * rather than waiting for it here, which is the difference between a scroll
     * that keeps up with the finger and one that does not. */
    _pendingFixedRect = CGRectMake(offset.x, offset.y, _viewportSize.width, _viewportSize.height);
    {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [[_webView _fixedPositionContent] scrollOrZoomChanged:_pendingFixedRect];
        [CATransaction commit];
    }
    [_webView _setCustomFixedPositionLayoutRectInWebThread:_pendingFixedRect synchronize:NO];
    if (!_fixedRectUpdateInFlight) {
        _fixedRectUpdateInFlight = YES;
        WebView *webView = [_webView retain];
        WebThreadRun(^{
            self->_fixedRectUpdateInFlight = NO;
            [webView _markScrolledByUser];
            [webView _setCustomFixedPositionLayoutRect:self->_pendingFixedRect];
            [webView _viewGeometryDidChange];
            [webView release];
        });
    }

    [_wakWindow layoutTiles];
}

/* Scrolling leaves the tile cache in whatever mode the scroll needed - the
 * status bar tap sets ScrollToTop, which suspends the page's timers until
 * something takes it off again. Coming to rest means going back to Normal, whose
 * cover rect reaches beyond the screen edge, and then asking for the tiles that
 * rect now wants. Both are the engine's business, so both go to the web thread.
 *
 * Four different ends of a scroll arrive here - a drag that stops without
 * momentum, momentum running out, a programmatic scroll landing, and the
 * scroll-to-top animation finishing - and any of them may be the last one. */
- (void)restoreNormalTilingAfterScrolling
{
    [[_webView _fixedPositionContent] didFinishScrollingOrZooming];
    WAKWindow *window = [_wakWindow retain];
    WebView *webView = [_webView retain];
    CGPoint offset = [_scrollView contentOffset];
    CGSize viewport = _viewportSize;
    WebThreadRun(^{
        [webView _setCustomFixedPositionLayoutRect:CGRectMake(offset.x, offset.y,
            viewport.width, viewport.height)];
        [webView _viewGeometryDidChange];
        [webView release];
        [window setTilingMode:kWAKWindowTilingModeNormal];
        [window setExposedScrollViewRect:CGRectMake(offset.x, offset.y,
            viewport.width, viewport.height)];
        [window layoutTiles];
        [window setNeedsDisplayInRect:CGRectMake(offset.x, offset.y,
            viewport.width, viewport.height)];
        [window release];
    });
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    if (!decelerate)
        [self restoreNormalTilingAfterScrolling];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    [self restoreNormalTilingAfterScrolling];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView
{
    [self restoreNormalTilingAfterScrolling];
}

/* The status bar tap. ScrollToTop suspends invalidation like Panning, and
 * LegacyTileGrid::visibleRect() additionally forces the visible rect's y to 0,
 * so the top of the document is tiled while the animation is still running
 * rather than after it lands. */
- (BOOL)scrollViewShouldScrollToTop:(UIScrollView *)scrollView
{
    /* Only if the scroll is going to happen: the mode pauses the page's timers
     * and nothing but -scrollViewDidScrollToTop: takes it off again. */
    if ([scrollView contentOffset].y > 0)
        [_wakWindow setTilingMode:kWAKWindowTilingModeScrollToTop];
    return YES;
}

- (void)scrollViewDidScrollToTop:(UIScrollView *)scrollView
{
    [self restoreNormalTilingAfterScrolling];
}

/* The page told us what its tab bar contains. Build one. */
- (void)tabsDeclared:(NSNotification *)note
{
    NSArray *tabs = [WebAppBridge declaredTabs];
    if (![tabs count])
        return;

    [_tabBar removeFromSuperview];
    [_tabBar release];

    CGRect bounds = [[self view] bounds];
    CGFloat height = 48;
    _tabBar = [[UIView alloc] initWithFrame:
        CGRectMake(0, bounds.size.height - height, bounds.size.width, height)];
    [_tabBar setBackgroundColor:[UIColor colorWithWhite:0.09 alpha:1]];

    CGFloat width = bounds.size.width / [tabs count];
    for (NSUInteger i = 0; i < [tabs count]; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        [button setFrame:CGRectMake(i * width, 0, width, height)];
        [button setTitle:[[tabs objectAtIndex:i] objectForKey:@"label"]
                forState:UIControlStateNormal];
        [[button titleLabel] setFont:[UIFont systemFontOfSize:11]];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [button setTag:(NSInteger)i];
        [button addTarget:self action:@selector(tabTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [_tabBar addSubview:button];
    }
    [[self view] addSubview:_tabBar];

    /* The page keeps the full height it laid out for; the bar sits over the
     * bottom of it, which is where the page's own bar was. */
    LOG_STEP("native tab bar: %lu items", (unsigned long)[tabs count]);
}

- (void)tabTapped:(UIButton *)button
{
    LOG_STEP("tab %ld tapped", (long)[button tag]);
    WebView *webView = _webView;
    NSUInteger index = (NSUInteger)[button tag];
    WebThreadRun(^{
        [WebAppBridge activateTab:index inWebView:webView];
    });
}

/* Renders the whole layer tree on the main thread, and
 * -[LegacyTileHostLayer renderInContext:] takes the web thread lock to do it, so
 * this freezes the interface for as long as the page is busy. It is a debugging
 * tool, not something to run on a timer - which is what it was doing, and what
 * the stall watchdog caught it doing. */
- (void)writeSnapshot
{
    CGRect bounds = [[self view] bounds];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, (size_t)bounds.size.width, (size_t)bounds.size.height,
        8, 0, colorSpace, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        LOG_STEP("snapshot: no bitmap");
        return;
    }

    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, bounds);
    /* Core Graphics counts rows from the bottom and Core Animation from the top,
     * so without this the picture comes out upside down. */
    CGImageRef (*screenImage)(void) = (CGImageRef (*)(void))dlsym(RTLD_DEFAULT, "UIGetScreenImage");
    CGImageRef screen = screenImage ? screenImage() : NULL;
    if (screen) {
        CGContextDrawImage(context, bounds, screen);
        CGImageRelease(screen);
    } else {
        CGContextTranslateCTM(context, 0, bounds.size.height);
        CGContextScaleCTM(context, 1, -1);
        [[[self view] layer] renderInContext:context];
    }

    unsigned char *pixels = CGBitmapContextGetData(context);
    size_t stride = CGBitmapContextGetBytesPerRow(context);
    unsigned long painted = 0;
    for (size_t y = 0; y < (size_t)bounds.size.height; y++) {
        for (size_t x = 0; x < (size_t)bounds.size.width; x++) {
            unsigned char *pixel = pixels + y * stride + x * 4;
            /* The bitmap is filled white before the layer draws into it, so
             * "painted" means "not still that white". Testing against green,
             * which is what the other harness fills with, counted every white
             * pixel and always reported a full screen. */
            if (pixel[0] != 255 || pixel[1] != 255 || pixel[2] != 255)
                painted++;
        }
    }
    unsigned char *centre = pixels + (size_t)(bounds.size.height / 2) * stride + (size_t)(bounds.size.width / 2) * 4;
    LOG_STEP("snapshot: %lu of %.0f pixels differ from the fill, centre %02x %02x %02x",
        painted, bounds.size.width * bounds.size.height, centre[0], centre[1], centre[2]);

    CGImageRef image = CGBitmapContextCreateImage(context);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, CFSTR("/tmp/app-shot.png"), kCFURLPOSIXPathStyle, false);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(url, kUTTypePNG, 1, NULL);
    if (destination) {
        CGImageDestinationAddImage(destination, image, NULL);
        CGImageDestinationFinalize(destination);
        CFRelease(destination);
        LOG_STEP("snapshot written");
    }
    CFRelease(url);
    CGImageRelease(image);
    CGContextRelease(context);
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

- (void)webView:(WebView *)sender addMessageToConsole:(NSDictionary *)message withSource:(NSString *)source
{
    NSString *text = [message objectForKey:@"message"];
    NSString *level = [message objectForKey:@"MessageLevel"];
    NSString *url = [message objectForKey:@"sourceURL"];
    id line = [message objectForKey:@"lineNumber"];
    LOG_STEP("console[%s] %s (%s:%s)",
        [level UTF8String] ?: "log",
        [text UTF8String] ?: "?",
        [[url lastPathComponent] UTF8String] ?: "?",
        [[line description] UTF8String] ?: "?");
}

- (void)webView:(WebView *)sender didCommitLoadForFrame:(WebFrame *)frame
{
    if (frame != [sender mainFrame])
        return;
    LOG_STEP("committed %.2f s", -[_start timeIntervalSinceNow]);
    _settled = NO;
    _documentGrewBeyondViewport = NO;
    _tallestDocumentHeight = 0;
}

/* A feed that keeps fetching never finishes loading, so an application that
 * waits for -didFinishLoadForFrame: to settle its tiles and size its document
 * waits forever on exactly the sites this exists to run. The page is usable as
 * soon as it has laid out something visible; take that as the moment instead,
 * and let a later finish be a no-op. */
- (void)webView:(WebView *)sender didFirstVisuallyNonEmptyLayoutInFrame:(WebFrame *)frame
{
    if (frame != [sender mainFrame])
        return;
    LOG_STEP("first visible layout %.2f s", -[_start timeIntervalSinceNow]);
    [self settle];
}

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    if (frame != [sender mainFrame])
        return;
    LOG_STEP("finished %.2f s", -[_start timeIntervalSinceNow]);
    [WebAppBytecodeCache cancelDelayedFlush];
    [WebAppBytecodeCache flushAfterDelay];
    /* The manifest's stylesheet, applied before anything is asked to paint, so
     * the first frame the user sees is already the application's rather than the
     * page's. It is a no-op for a document on a host this application does not
     * own, and for a build with no manifest. */
    [WebAppManifest injectIntoWebView:sender forURL:[NSURL URLWithString:[sender mainFrameURL]]];
    [self settle];
}

/* Lay the page out into tiles and come to rest in the normal tiling mode.
 *
 * This is not a once-per-load thing. The first visible layout is the earliest
 * moment worth tiling, and on a feed that keeps fetching it is also the only
 * moment that ever arrives - but what is on screen at that point is a fraction
 * of what will be there a few seconds later. So it runs again when the load does
 * finish, and again whenever the document changes size, which is what a feed
 * growing looks like from here. All of it is on the web thread and bounded by
 * the tile cache's own capacity, so running it more often costs little. */
- (void)settle
{
    /* Only the first pass paints synchronously. -layoutTilesNow paints every
     * tile the cover rect wants before it returns, and the cover rect spans a
     * document that on a feed is thousands of points tall; doing that again
     * every time the feed grows holds the web thread long enough that the main
     * thread waiting on the same lock to draw is killed by the watchdog. Later
     * passes ask with -layoutTiles, which is a queued request the tile cache
     * coalesces. */
    BOOL first = !_settled;
    _settled = YES;
    /* This delegate call arrives on the main thread, and everything below takes
     * the web lock and then paints every tile synchronously. Doing that here
     * stops the main run loop for as long as the paint takes, and SpringBoard
     * kills an application that stops answering - which is why the process died
     * about twenty-five seconds in with no crash report and plenty of memory to
     * spare. It is the same rule -withWebLock: exists for. */
    withWebLock(^{
    [self->_wakWindow setTilingMode:kWAKWindowTilingModeDisabled];
    /* Normal, not Minimal, is the mode to come to rest in. Minimal is
     * LegacyTileGrid::shouldUseMinimalTileCoverage(): the cover rect collapses
     * to the visible rect, so there is never a tile beyond the screen edge and
     * the first frame of every scroll exposes unpainted document. Normal
     * inflates the cover rect by half a width each side and a full height above
     * and below, which is the area a scroll is about to move into. The cost is
     * bounded by the cache itself — LegacyTileCache::tileCapacityForGrid()
     * against LegacyTileGrid::dropDistantTiles() — and -didReceiveMemoryWarning
     * drops everything off screen. */
    [self->_wakWindow setTilingMode:kWAKWindowTilingModeNormal];
    if (first) {
        /* setNeedsDisplay marks every existing tile dirty for a full CPU
         * repaint (LegacyTileCache::setNeedsDisplay() invalidates the whole
         * document rect), which only the first pass needs: there is nothing
         * painted yet to preserve. Later passes re-run this same -settle as
         * the feed grows (-updateContentSize below re-arms every 2s while
         * scroll height keeps changing); repainting tiles that already have
         * correct content on every one of those passes was pure waste on the
         * same web lock the comment above is already careful about. WebCore's
         * own layout-driven repaint invalidation (ScrollView::
         * platformRepaintContentRectangle) already marks the newly
         * laid-out region dirty on its own; nothing here needs to help it. */
        [self->_wakWindow setNeedsDisplay];
        [self->_wakWindow layoutTilesNow];
    } else {
        [self->_wakWindow layoutTiles];
    }
    LOG_STEP("post-load: tiles laid out (%s)", first ? "now" : "queued");
    });
    /* The document has no height until it has been laid out, and layout happens
     * after this callback returns. Nothing below the first screen can paint
     * before the view has been sized to it, so the first ask is soon. */
    /* Each of these takes the web lock, and CoreAnimation takes the same lock on
     * the main thread when it draws a tile (LegacyTileCache::drawLayer). Asking
     * repeatedly while the page is still running script is a collision waiting
     * to happen, and the main thread loses. Ask once, late enough that the first
     * layout is done. */
    [self performSelector:@selector(updateContentSize) withObject:nil afterDelay:1.0];
}

/* Where a link is allowed to go.
 *
 * This is most of what separates an application from a browser showing one site.
 * Today a link to a help page, a privacy policy or somebody's personal site
 * navigates in place, and there is no back button, no address bar and no
 * gesture — the application has silently become a browser on a page that is not
 * it, with no way home. An application hands that to Safari and stays where it
 * was.
 *
 * Only navigations reach here, not subresources, so the cost is one dictionary
 * lookup per page rather than per request. A build with no manifest has no
 * internal hosts and +opensExternalLinksInSafari is false, so everything is
 * allowed through and the development browser behaves as it did. */
- (void)webView:(WebView *)sender decidePolicyForNavigationAction:(NSDictionary *)action
                                                          request:(NSURLRequest *)request
                                                            frame:(WebFrame *)frame
                                                 decisionListener:(id<WebPolicyDecisionListener>)listener
{
    if ([self sendToSafariIfExternal:[request URL]])
        [listener ignore];
    else
        [listener use];
}

/* target="_blank" and window.open(). There is no second window in a wrapped
 * application, so an external one goes to Safari and an internal one is loaded
 * where the user already is — which is not what a browser would do, and is
 * exactly what a native application does with a link to itself. Left alone,
 * neither happens: this embedder has no UI delegate to create a window with, so
 * every such link does nothing at all. */
- (void)webView:(WebView *)sender decidePolicyForNewWindowAction:(NSDictionary *)action
                                                          request:(NSURLRequest *)request
                                                     newFrameName:(NSString *)frameName
                                                 decisionListener:(id<WebPolicyDecisionListener>)listener
{
    [listener ignore];
    if ([self sendToSafariIfExternal:[request URL]])
        return;
    NSURLRequest *here = [NSURLRequest requestWithURL:[request URL]];
    WebFrame *mainFrame = [sender mainFrame];
    WebThreadRun(^{ [mainFrame loadRequest:here]; });
}

- (BOOL)sendToSafariIfExternal:(NSURL *)url
{
    if (![WebAppManifest opensExternalLinksInSafari])
        return NO;
    /* A scheme this application cannot load is external whatever its host says:
     * mailto:, tel: and itms-apps: all belong to something else on the device. */
    NSString *scheme = [[url scheme] lowercaseString];
    BOOL loadable = [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]
        || [scheme isEqualToString:@"about"] || [scheme isEqualToString:@"data"]
        || [scheme isEqualToString:@"blob"];
    if (loadable && [WebAppManifest isInternalURL:url])
        return NO;
    if ([scheme isEqualToString:@"about"] || [scheme isEqualToString:@"data"]
        || [scheme isEqualToString:@"blob"])
        return NO;

    LOG_STEP("external link -> Safari: %s", [[url absoluteString] UTF8String]);
    /* -openURL: is UIKit's, and this delegate is not promised to the main
     * thread. Deciding is synchronous because the listener must be answered on
     * the thread that asked; only the handover is deferred. */
    NSURL *target = [url retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] openURL:target];
        [target release];
    });
    return YES;
}

- (void)webView:(WebView *)sender didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
    LOG_STEP("provisional load failed: %s", [[error localizedDescription] UTF8String]);
}

- (void)webView:(WebView *)sender didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
    LOG_STEP("load failed: %s", [[error localizedDescription] UTF8String]);
}

/* The system's own pressure signal. WebKit installs a low-memory handler from
 * -[WebView _commonInitialization], but on this release the dispatch source
 * that was meant to drive it is refused, so until the handler learned to poll
 * kern.memorystatus_level nothing ever reached it. UIKit's warning is the same
 * signal graded by the kernel rather than by us, and the tiles outside the
 * visible rect are ours to drop. */
- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    LOG_STEP("memory warning");
    WAKWindow *window = [_wakWindow retain];
    WebThreadRun(^{
        [window removeAllNonVisibleTiles];
        [window release];
    });
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    WebThreadLock();
    [_webView _setUIKitDelegate:nil];
    WebThreadUnlock();
    [_uiKitDelegate setHandler:nil];
    [_uiKitDelegate release];
    [_tabBar release];
    [_start release];
    [_webView release];
    [_wakWindow release];
    [_hostLayer release];
    [_scrollView release];
    [super dealloc];
}

@end

@interface AppDelegate : NSObject <UIApplicationDelegate> {
    UIWindow *_window;
}
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{
    LOG_STEP("app launched");
    [[UIApplication sharedApplication] setIdleTimerDisabled:YES];

    /* Before the first request, because a cookie that arrives after the request
     * that needed it is a login screen. The accept policy comes first for the
     * same reason it always did, and now also because the jar is about to put
     * cookies into that storage. */
    [[NSHTTPCookieStorage sharedHTTPCookieStorage]
        setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];
    [WebAppCookieJar start];

    _window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [_window setRootViewController:[[[BrowserViewController alloc] init] autorelease]];
    [_window makeKeyAndVisible];
    return YES;
}

/* A process that stops answering and a process that has been put to sleep look
 * identical from outside - both stop logging and are killed a little later with
 * no crash report. These say which happened. */
- (void)applicationWillResignActive:(UIApplication *)application
{
    LOG_STEP("resigning active");
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    LOG_STEP("entered background");
    [WebAppBytecodeCache flush];
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    LOG_STEP("became active");
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    LOG_STEP("terminating");
    [WebAppBytecodeCache flush];
}

- (void)dealloc
{
    [_window release];
    [super dealloc];
}

@end

static void handleUncaughtException(NSException *exception)
{
    LOG_STEP("uncaught exception: %s: %s", [[exception name] UTF8String], [[exception reason] UTF8String]);
    LOG_STEP("backtrace: %s", [[[exception callStackSymbols] componentsJoinedByString:@" | "] UTF8String]);
}

/* When the application stops answering, SpringBoard kills it about twenty
 * seconds later and leaves no crash report, so from outside a hang and a crash
 * look the same and neither says where. This makes the process tell us: the main
 * run loop bumps a counter, a thread that is not the main one watches the
 * counter, and if it has not moved for long enough it signals the main thread,
 * whose handler prints where it is standing. */
static volatile uint32_t gMainLoopTicks;
static pthread_t gMainThread;

static void reportMainThreadStall(int number)
{
    (void)number;
    LOG_STEP("main thread has not answered for 8 s; it is here:");
    void *frames[40];
    int count = backtrace(frames, 40);
    char **symbols = backtrace_symbols(frames, count);
    for (int i = 0; i < count && symbols; i++)
        LOG_STEP("  %s", symbols[i]);
}

static void dumpThreadStacks(const char *why)
{
    thread_act_array_t threads;
    mach_msg_type_number_t threadCount = 0;
    if (task_threads(mach_task_self(), &threads, &threadCount) != KERN_SUCCESS)
        return;

    browserLog("STACKS (%s): %u threads", why, (unsigned)threadCount);
    thread_t self = mach_thread_self();
    for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
        if (threads[i] == self)
            continue;
        if (thread_suspend(threads[i]) != KERN_SUCCESS)
            continue;

        arm_thread_state_t state;
        mach_msg_type_number_t stateCount = ARM_THREAD_STATE_COUNT;
        if (thread_get_state(threads[i], ARM_THREAD_STATE, (thread_state_t)&state, &stateCount) == KERN_SUCCESS) {
            browserLog("  thread %u: pc=%p lr=%p sp=%p r7=%p",
                (unsigned)i, (void *)state.__pc, (void *)state.__lr,
                (void *)state.__sp, (void *)state.__r[7]);

            uintptr_t pcs[32];
            unsigned depth = 0;
            pcs[depth++] = (uintptr_t)state.__pc;
            if (state.__lr)
                pcs[depth++] = (uintptr_t)state.__lr;
            uintptr_t frame = (uintptr_t)state.__r[7];
            uintptr_t stackLow = (uintptr_t)state.__sp;
            while (depth < 32 && frame > stackLow && frame < stackLow + 1024 * 1024 && !(frame & 3)) {
                uintptr_t next = *(uintptr_t *)frame;
                uintptr_t returnAddress = *(uintptr_t *)(frame + sizeof(uintptr_t));
                if (!returnAddress || next <= frame)
                    break;
                pcs[depth++] = returnAddress;
                frame = next;
            }

            for (unsigned f = 0; f < depth; f++) {
                Dl_info symbol;
                if (dladdr((void *)pcs[f], &symbol) && symbol.dli_sname) {
                    browserLog("    #%02u %p %s + %ld", f, (void *)pcs[f], symbol.dli_sname,
                        (long)((uintptr_t)pcs[f] - (uintptr_t)symbol.dli_saddr));
                } else if (dladdr((void *)pcs[f], &symbol) && symbol.dli_fname) {
                    browserLog("    #%02u %p %s + %ld", f, (void *)pcs[f], symbol.dli_fname,
                        (long)((uintptr_t)pcs[f] - (uintptr_t)symbol.dli_fbase));
                } else
                    browserLog("    #%02u %p", f, (void *)pcs[f]);
            }
        }
        thread_resume(threads[i]);
    }
    mach_port_deallocate(mach_task_self(), self);
    vm_deallocate(mach_task_self(), (vm_address_t)threads, threadCount * sizeof(thread_t));
}

static volatile uint32_t gWebThreadBeats;

static void *watchWebThread(void *unused)
{
    (void)unused;
    uint32_t lastSeen = 0;
    int quietSeconds = 0;
    BOOL reported = NO;
    for (;;) {
        sleep(1);
        WebThreadRun(^{ gWebThreadBeats++; });
        if (gWebThreadBeats != lastSeen) {
            lastSeen = gWebThreadBeats;
            quietSeconds = 0;
            reported = NO;
            continue;
        }
        if (++quietSeconds >= 6 && !reported) {
            reported = YES;
            browserLog("WEB THREAD STALLED for %d s", quietSeconds);
            dumpThreadStacks("web thread stalled");
        }
    }
    return NULL;
}

static void *watchMainThread(void *unused)
{
    (void)unused;
    uint32_t lastSeen = 0;
    int quietSeconds = 0;
    BOOL reported = NO;
    int elapsed = 0;
    for (;;) {
        sleep(1);
        elapsed++;
        /* This thread's own heartbeat, so the log says how far the process got
         * even when the main thread has stopped writing to it - which is the
         * case we are trying to see. */
        struct task_basic_info info;
        mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
        double megabytes = 0;
        if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
            megabytes = info.resident_size / (1024.0 * 1024.0);
        LOG_STEP("watchdog %d s: main loop ticks %u, %.1f MB", elapsed,
            (unsigned)gMainLoopTicks, megabytes);

        if (gMainLoopTicks != lastSeen) {
            lastSeen = gMainLoopTicks;
            quietSeconds = 0;
            reported = NO;
            continue;
        }
        if (++quietSeconds >= 3 && !reported) {
            reported = YES;
            pthread_kill(gMainThread, SIGUSR1);
            dumpThreadStacks("main loop stalled");
        }
    }
    return NULL;
}

static void tickMainLoop(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
    (void)observer; (void)activity; (void)info;
    gMainLoopTicks++;
}

static void watchForStalls(void)
{
    gMainThread = pthread_self();
    signal(SIGUSR1, reportMainThreadStall);

    CFRunLoopObserverRef observer = CFRunLoopObserverCreate(NULL,
        kCFRunLoopBeforeWaiting | kCFRunLoopAfterWaiting, true, 0, tickMainLoop, NULL);
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    CFRelease(observer);

    pthread_t watcher;
    pthread_create(&watcher, NULL, watchMainThread, NULL);
}

static void handleFatalSignal(int number)
{
    LOG_STEP("fatal signal %d", number);
    void *frames[32];
    int count = backtrace(frames, 32);
    char **symbols = backtrace_symbols(frames, count);
    for (int i = 0; i < count && symbols; i++)
        LOG_STEP("  %s", symbols[i]);
    _exit(128 + number);
}

/* JSC reads its options out of the environment once, from the first
 * JSC::initialize() — which this app reaches only through WebKitInitialize().
 * None of the three frameworks has a __mod_init_func section, so nothing of
 * WebKit has run by the time main() does and setenv() here is seen.
 *
 * WebCore builds its VM as HeapType::Large, whose first-collection threshold is
 * min(largeHeapSize, ramSize * smallHeapRAMFraction). iOS raises
 * smallHeapRAMFraction to 0.8, so on 512 MB the second term is 410 MB and the
 * threshold is a flat 32 MB: no collection at all until the JS heap reaches
 * 32 MB, and 32 MB stays the floor under every later growth calculation.
 * 4 MB is what JSC itself uses for a Medium heap. smallHeapRAMFraction is left
 * alone because at this floor it could only bind below 0.008. */
static void setJavaScriptHeapFloor(void)
{
    setenv("JSC_largeHeapSize", "4194304", 1);
    setenv("JSC_smallHeapRAMFraction", "0.08", 1);
    setenv("JSC_mediumHeapRAMFraction", "0.2", 1);
    setenv("JSC_smallHeapGrowthFactor", "1.25", 1);
    setenv("JSC_mediumHeapGrowthFactor", "1.12", 1);
    setenv("JSC_largeHeapGrowthFactor", "1.05", 1);
    setenv("JSC_minNumberOfWorklistThreads", "1", 1);
    setenv("JSC_maxNumberOfWorklistThreads", "1", 1);
    FILE *overrides = fopen("/tmp/jsc-env", "r");
    if (overrides) {
        char line[256];
        while (fgets(line, sizeof(line), overrides)) {
            char *end = line + strlen(line);
            while (end > line && (end[-1] == '\n' || end[-1] == '\r' || end[-1] == ' '))
                *--end = '\0';
            char *equals = strchr(line, '=');
            if (!equals || equals == line)
                continue;
            *equals = '\0';
            setenv(line, equals + 1, 1);
            LOG_STEP("jsc override %s=%s", line, equals + 1);
        }
        fclose(overrides);
    }
    setenv("JSC_numberOfGCMarkers", "1", 1);
    setenv("JSC_useWasm", "0", 1);
    setenv("JSC_jitPolicyScale", "0.5", 1);
}

/* The kernel kills this process when it passes its memory high-water mark, and
 * the mark a plain application gets on a 512 MB device is smaller than a page
 * of a modern site needs. Of the memorystatus commands this kernel answers,
 * only 5 — set the high-water mark — is accepted; the limit-property commands
 * of later releases are refused. Raising it is the difference between a page
 * that finishes and a process that disappears without a crash report. */
extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t size);

static void raiseMemoryLimit(void)
{
    static const uint32_t megabytes = 400;
    if (!memorystatus_control(5 /* set high-water mark */, getpid(), megabytes, NULL, 0)) {
        LOG_STEP("memory high-water mark set to %u MB", megabytes);
        return;
    }
    /* Refused, because this runs as the user applications run as rather than as
     * root. The process publishes its identity instead, so something with the
     * privilege can raise the mark on its behalf. */
    FILE *file = fopen("/tmp/browser.pid", "w");
    if (file) {
        fprintf(file, "%d\n", getpid());
        fclose(file);
    }
    LOG_STEP("memory high-water mark refused; pid %d published", getpid());
}

int main(int argc, char *argv[])
{
    raiseMemoryLimit();
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    installFatalSignalHandlers();
    setJavaScriptHeapFloor();
    LOG_STEP("main entered");
    NSSetUncaughtExceptionHandler(handleUncaughtException);
    watchForStalls();
    signal(SIGSEGV, handleFatalSignal);
    signal(SIGBUS, handleFatalSignal);
    signal(SIGILL, handleFatalSignal);
    signal(SIGABRT, handleFatalSignal);
    int result = 0;
    @try {
        result = UIApplicationMain(argc, argv, nil, @"AppDelegate");
    } @catch (NSException *exception) {
        handleUncaughtException(exception);
    }
    LOG_STEP("UIApplicationMain returned %d", result);
    [pool release];
    return result;
}
