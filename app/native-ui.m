#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#include <sys/stat.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <fcntl.h>
#include <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <signal.h>
#include <stdio.h>
#include <pthread.h>
#include <signal.h>
#include <execinfo.h>
#include <stdlib.h>
#include <unistd.h>

// Raised while the scroll offset is moving, read by the engine.
//
// The engine's draw path has to know this: laying out from the main thread costs
// four hundred milliseconds at load, and skipping it during a scroll costs the
// scroll. Neither the tile cache's tiling mode nor the frame view's last scroll
// type answers the question here, and the application is the only thing that
// knows for certain, because it is the one publishing the offset.
__attribute__((visibility("default"))) volatile int g_appIsScrolling = 0;

static void logLine(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // Opened once. This used to open and close the file on every line, and it is
    // called from paths that run per frame.
    static FILE *log;
    if (!log) {
        log = fopen("/tmp/native.log", "a");
        if (log)
            setvbuf(log, NULL, _IOLBF, 0);
    }
    if (log)
        fprintf(log, "%.3f %s\n", CFAbsoluteTimeGetCurrent(), [line UTF8String]);
    [line release];
}


// A touch UIKit believes in.
//
// Sending WebEvents to the engine exercises the engine but not the path a
// finger takes: the gesture recognisers, the scroll view and everything UIKit
// does on the interface thread never run, so nothing measured that way says
// anything about what a person feels. This OS has no setters on UITouch - the
// era wrote the fields directly - and a half-built touch crashes inside UIKit's
// own delivery, which is what happened when this was attempted with setters.
// The fields are found by name through the runtime, so the layout is read from
// the system rather than assumed.
@interface UIApplication (AppChromeSynthesis)
- (id)_touchesEvent;
@end

@interface UIEvent (AppChromeSynthesis)
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
- (void)_setTimestamp:(NSTimeInterval)timestamp;
@end

static void *ivarAddress(id object, const char *name)
{
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar)
        return NULL;
    return (char *)object + ivar_getOffset(ivar);
}

static BOOL setObjectIvar(id object, const char *name, id value)
{
    void *slot = ivarAddress(object, name);
    if (!slot)
        return NO;
    *(id *)slot = [value retain];
    return YES;
}

static BOOL setPointIvar(id object, const char *name, CGPoint value)
{
    void *slot = ivarAddress(object, name);
    if (!slot)
        return NO;
    *(CGPoint *)slot = value;
    return YES;
}

static BOOL setIntIvar(id object, const char *name, int value)
{
    void *slot = ivarAddress(object, name);
    if (!slot)
        return NO;
    *(int *)slot = value;
    return YES;
}

static UITouch *synthesizedTouch(UIWindow *window, CGPoint location)
{
    UITouch *touch = [[UITouch alloc] init];
    UIView *hit = [window hitTest:location withEvent:nil] ?: (UIView *)window;

    BOOL complete = YES;
    complete &= setObjectIvar(touch, "_window", window);
    complete &= setObjectIvar(touch, "_view", hit);
    complete &= setObjectIvar(touch, "_gestureView", hit);
    complete &= setPointIvar(touch, "_locationInWindow", location);
    complete &= setPointIvar(touch, "_previousLocationInWindow", location);
    complete &= setIntIvar(touch, "_phase", UITouchPhaseBegan);
    complete &= setIntIvar(touch, "_tapCount", 1);

    // UIKit walks this array while delivering; a touch it did not create itself
    // has it nil, and the walk is where delivery crashed.
    complete &= setObjectIvar(touch, "_gestureRecognizers", [NSMutableArray array]);

    void *timestamp = ivarAddress(touch, "_timestamp");
    if (timestamp)
        *(double *)timestamp = [[NSProcessInfo processInfo] systemUptime];
    else
        complete = NO;

    // _firstTouchForView is the first bit of the flags byte, and UIKit reads it
    // when deciding whether this is the touch that begins an interaction.
    unsigned char *flags = (unsigned char *)ivarAddress(touch, "_touchFlags");
    if (flags)
        *flags |= 0x01 | 0x02;
    else
        complete = NO;

    if (!complete) {
        logLine(@"could not build a touch this UIKit understands");
        [touch release];
        return nil;
    }
    return touch;
}

static void deliverTouch(UITouch *touch, UITouchPhase phase, CGPoint location)
{
    UIApplication *application = [UIApplication sharedApplication];
    if (![application respondsToSelector:@selector(_touchesEvent)])
        return;

    void *previous = ivarAddress(touch, "_previousLocationInWindow");
    void *current = ivarAddress(touch, "_locationInWindow");
    if (previous && current)
        *(CGPoint *)previous = *(CGPoint *)current;
    setPointIvar(touch, "_locationInWindow", location);
    setIntIvar(touch, "_phase", phase);

    void *timestamp = ivarAddress(touch, "_timestamp");
    if (timestamp)
        *(double *)timestamp = [[NSProcessInfo processInfo] systemUptime];

    UIEvent *event = [application _touchesEvent];
    if ([event respondsToSelector:@selector(_clearTouches)])
        [event _clearTouches];
    if ([event respondsToSelector:@selector(_setTimestamp:)])
        [event _setTimestamp:[[NSProcessInfo processInfo] systemUptime]];
    if (![event respondsToSelector:@selector(_addTouch:forDelayedDelivery:)])
        return;
    [event _addTouch:touch forDelayedDelivery:NO];

    [application sendEvent:event];
}


// Who moves the page, and what the engine told UIKit just before it happened.
static IMP originalSetContentOffset;
static IMP originalForwardInvocation;

static void logOffsetJump(UIScrollView *scroller, CGPoint from, CGPoint to, const char *how)
{
    if (from.y - to.y < 100 || to.y > 40)
        return;

    FILE *log = fopen("/tmp/native-jump.log", "a");
    if (!log)
        return;
    fprintf(log, "%.3f %s: %.0f -> %.0f (contentSize %.0f)\n",
        CFAbsoluteTimeGetCurrent(), how, from.y, to.y, scroller.contentSize.height);
    void *frames[20];
    int count = backtrace(frames, 20);
    char **symbols = backtrace_symbols(frames, count);
    for (int i = 1; i < count && i < 14; i++)
        fprintf(log, "    %s\n", symbols ? symbols[i] : "?");
    free(symbols);
    fclose(log);
}

static void interceptedSetContentOffset(id self, SEL selector, CGPoint offset)
{
    CGPoint before = [(UIScrollView *)self contentOffset];
    ((void (*)(id, SEL, CGPoint))originalSetContentOffset)(self, selector, offset);
    logOffsetJump(self, before, offset, "setContentOffset");
}

static void interceptedForwardInvocation(id self, SEL selector, NSInvocation *invocation)
{
    const char *name = sel_getName([invocation selector]);
    if (name && !strstr(name, "resource:didFinishLoadingFromDataSource")
        && !strstr(name, "DidCommitCompositingLayerChanges")) {
        FILE *log = fopen("/tmp/native-delegate.log", "a");
        if (log) {
            fprintf(log, "%.3f %s\n", CFAbsoluteTimeGetCurrent(), name);
            fclose(log);
        }
    }
    ((void (*)(id, SEL, NSInvocation *))originalForwardInvocation)(self, selector, invocation);
}

static void watchForOffsetJumps(void)
{
    Method plain = class_getInstanceMethod([UIScrollView class], @selector(setContentOffset:));
    if (plain) {
        originalSetContentOffset = method_getImplementation(plain);
        method_setImplementation(plain, (IMP)interceptedSetContentOffset);
    }
}

static void watchForDelegateMessages(void)
{
    Class forwarder = NSClassFromString(@"_WebSafeForwarder");
    Method method = forwarder ? class_getInstanceMethod(forwarder, @selector(forwardInvocation:)) : NULL;
    if (!method)
        return;
    originalForwardInvocation = method_getImplementation(method);
    method_setImplementation(method, (IMP)interceptedForwardInvocation);
}

@interface TouchLoggingWindow : UIWindow
@end

static bool (*webThreadIsBusy)(void);
static bool (*webThreadTryLockForFrame)(void);
static bool (*mainThreadMustWaitForEngine)(void);
static CGFloat lastCorrectedOffset = -1;

@implementation TouchLoggingWindow

static FILE *touchLog(void)
{
    static FILE *log;
    if (!log) {
        log = fopen("/tmp/native-touch.log", "w");
        if (log)
            setvbuf(log, NULL, _IOLBF, 0);
    }
    return log;
}

- (void)sendEvent:(UIEvent *)event
{
    FILE *log = touchLog();
    if (log && event.type == UIEventTypeTouches) {
        UITouch *touch = [[event allTouches] anyObject];
        CGPoint where = [touch locationInView:self];
        const char *phase = "?";
        switch (touch.phase) {
        case UITouchPhaseBegan: phase = "began"; break;
        case UITouchPhaseMoved: phase = "moved"; break;
        case UITouchPhaseEnded: phase = "ended"; break;
        case UITouchPhaseCancelled: phase = "cancelled"; break;
        default: break;
        }
        fprintf(log, "%.3f touch %s %.0f,%.0f\n", CFAbsoluteTimeGetCurrent(), phase, where.x, where.y);
    }
    double before = CFAbsoluteTimeGetCurrent();
    [super sendEvent:event];
    double took = CFAbsoluteTimeGetCurrent() - before;
    if (log && event.type == UIEventTypeTouches && took > 0.05)
        fprintf(log, "%.3f dispatch took %.0f ms\n", CFAbsoluteTimeGetCurrent(), took * 1000);
}

@end

// Reading another thread's stack without trusting it.
//
// A suspended thread can be caught mid-prologue, where r7 is not a frame pointer
// yet but whatever the previous frame left there. Dereferencing that faults, and
// a fault on a sampling thread takes the whole application down - which is
// exactly what happened: SIGSEGV at 0xffffffbc on a bare thread_start stack,
// with no engine frames in sight. The kernel will tell us whether an address is
// readable, so ask it instead of guessing.
static bool readWord(uintptr_t address, uintptr_t *out)
{
    if (address < 0x1000 || (address & 3))
        return false;
    vm_size_t got = 0;
    if (vm_read_overwrite(mach_task_self(), (vm_address_t)address, sizeof(*out), (vm_address_t)out, &got) != KERN_SUCCESS)
        return false;
    return got == sizeof(*out);
}

static int walkStack(thread_act_t thread, uintptr_t *frames, int capacity)
{
    _STRUCT_ARM_THREAD_STATE state;
    mach_msg_type_number_t count = ARM_THREAD_STATE_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE, (thread_state_t)&state, &count) != KERN_SUCCESS)
        return 0;

    int depth = 0;
    if (depth < capacity)
        frames[depth++] = state.__pc;
    if (depth < capacity)
        frames[depth++] = state.__lr;

    uintptr_t framePointer = state.__r[7];
    while (depth < capacity) {
        uintptr_t next = 0;
        uintptr_t returnAddress = 0;
        if (!readWord(framePointer, &next) || !readWord(framePointer + 4, &returnAddress))
            break;
        if (returnAddress < 0x1000)
            break;
        frames[depth++] = returnAddress;
        if (next <= framePointer)
            break;
        framePointer = next;
    }
    return depth;
}

// Walking the main thread's stack while it is stuck. Only the frame pointer
// chain is followed - r7 on this ABI - which is enough to name the caller that
// holds the interface, and cheap enough to do while the thread is suspended.
static void writeStackOfThread(FILE *log, thread_act_t thread)
{
    uintptr_t frames[24];
    int depth = walkStack(thread, frames, 24);

    for (int i = 0; i < depth; i++) {
        Dl_info info;
        // The address as well as the name: on a stripped binary dladdr answers
        // with the nearest exported symbol plus a large offset, which reads as a
        // confident wrong answer. The address can always be resolved offline
        // against the copy in dist/unstripped.
        if (dladdr((void *)frames[i], &info) && info.dli_sname)
            fprintf(log, "        %d %s  [%p]\n", i, info.dli_sname, (void *)frames[i]);
        else
            fprintf(log, "        %d %p\n", i, (void *)frames[i]);
    }
}

// The thread that actually owns the engine.
//
// A stalled interface almost always means the main thread is waiting for the
// web lock, and the stack of the waiter says nothing about who is holding it.
// The holder is the web thread, so name it once and photograph it too.
static thread_act_t findWebThread(void)
{
    thread_act_array_t threads;
    mach_msg_type_number_t threadCount = 0;
    if (task_threads(mach_task_self(), &threads, &threadCount) != KERN_SUCCESS)
        return MACH_PORT_NULL;

    thread_act_t found = MACH_PORT_NULL;
    for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
        pthread_t handle = pthread_from_mach_thread_np(threads[i]);
        char name[64] = { 0 };
        if (handle && !pthread_getname_np(handle, name, sizeof(name)) && strstr(name, "WebThread")) {
            found = threads[i];
            break;
        }
    }
    return found;
}

static bool stackMentionsWebThreadLock(thread_act_t thread)
{
    uintptr_t frames[24];
    int depth = walkStack(thread, frames, 24);
    for (int i = 0; i < depth; i++) {
        Dl_info info;
        if (dladdr((void *)frames[i], &info) && info.dli_sname && strstr(info.dli_sname, "WebThreadLock"))
            return true;
    }
    return false;
}


// Naming a frame the linker cannot name.
//
// UIKit comes out of the shared cache with its symbol table stripped, so dladdr
// answers "<redacted>" for exactly the frames that say which UIKit call is
// taking the web lock on the main thread - which is the whole question when the
// interface freezes. Every Objective-C method is still there at runtime, with
// its implementation address, so the address can be named from the class list:
// the method whose implementation starts nearest below it.
//
// The table is built once, on the first frame that needs it, and only ever from
// the watchdog - never from anything that runs per frame.
typedef struct { uintptr_t address; const char *className; const char *selectorName; char kind; } MethodSpan;

static MethodSpan *methodSpans;
static int methodSpanCount;

static int compareMethodSpans(const void *a, const void *b)
{
    uintptr_t x = ((const MethodSpan *)a)->address, y = ((const MethodSpan *)b)->address;
    return x < y ? -1 : (x > y ? 1 : 0);
}

static void buildMethodSpans(void)
{
    if (methodSpans)
        return;
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0)
        return;
    Class *classes = (Class *)malloc(sizeof(Class) * classCount);
    if (!classes)
        return;
    objc_getClassList(classes, classCount);

    int capacity = 262144, used = 0;
    MethodSpan *spans = (MethodSpan *)malloc(sizeof(MethodSpan) * capacity);
    if (!spans) {
        free(classes);
        return;
    }
    for (int c = 0; c < classCount && used < capacity - 2; c++) {
        for (int meta = 0; meta < 2; meta++) {
            Class cls = meta ? object_getClass((id)classes[c]) : classes[c];
            unsigned int count = 0;
            Method *methods = class_copyMethodList(cls, &count);
            if (!methods)
                continue;
            for (unsigned int m = 0; m < count && used < capacity; m++) {
                spans[used].address = (uintptr_t)method_getImplementation(methods[m]) & ~(uintptr_t)1;
                spans[used].className = class_getName(classes[c]);
                spans[used].selectorName = sel_getName(method_getName(methods[m]));
                spans[used].kind = meta ? '+' : '-';
                used++;
            }
            free(methods);
        }
    }
    free(classes);
    qsort(spans, used, sizeof(MethodSpan), compareMethodSpans);
    methodSpanCount = used;
    methodSpans = spans;
}

static bool nameByMethodTable(uintptr_t address, char *out, size_t size)
{
    buildMethodSpans();
    if (!methodSpans || !methodSpanCount)
        return false;
    address &= ~(uintptr_t)1;
    int low = 0, high = methodSpanCount - 1, found = -1;
    while (low <= high) {
        int mid = (low + high) / 2;
        if (methodSpans[mid].address <= address) {
            found = mid;
            low = mid + 1;
        } else
            high = mid - 1;
    }
    // The distance is printed rather than judged: a frame inside a C function
    // that happens to sit after some method still reads as "after that method",
    // and a large offset says exactly that rather than pretending to a name.
    if (found < 0 || address - methodSpans[found].address > 0x40000)
        return false;
    snprintf(out, size, "after %c[%s %s] +0x%x", methodSpans[found].kind, methodSpans[found].className,
        methodSpans[found].selectorName, (unsigned)(address - methodSpans[found].address));
    return true;
}

static volatile double lastScrollActivity;

static void *mainThreadWatchdog(void *unused)
{
    (void)unused;
    FILE *log = fopen("/tmp/native-stall.log", "w");
    if (!log)
        return NULL;
    setvbuf(log, NULL, _IOLBF, 0);

    thread_act_t mainThread = MACH_PORT_NULL;
    {
        thread_act_array_t threads;
        mach_msg_type_number_t threadCount = 0;
        if (task_threads(mach_task_self(), &threads, &threadCount) == KERN_SUCCESS && threadCount > 0)
            mainThread = threads[0];
    }

    while (1) {
        usleep(100000);
        __block double responded = 0;
        double asked = CFAbsoluteTimeGetCurrent();
        dispatch_async(dispatch_get_main_queue(), ^{ responded = CFAbsoluteTimeGetCurrent(); });
        usleep(400000);
        if (responded == 0) {
            fprintf(log, "%.3f main thread stalled > 400 ms\n", asked);
            // Captured while suspended, named after resuming.
            //
            // dladdr takes the dyld lock and fprintf takes the FILE lock and
            // allocates. Doing either while the main thread is suspended can
            // deadlock the process on a lock that thread was already holding -
            // the instrument turning a stall that would have cleared into a
            // permanent freeze. So the suspend window contains nothing but the
            // register read and the stack walk.
            uintptr_t mainFrames[24];
            int mainDepth = 0;
            bool waitingForEngine = false;
            if (mainThread != MACH_PORT_NULL && thread_suspend(mainThread) == KERN_SUCCESS) {
                mainDepth = walkStack(mainThread, mainFrames, 24);
                thread_resume(mainThread);
            }
            for (int i = 0; i < mainDepth; i++) {
                Dl_info info;
                bool named = dladdr((void *)mainFrames[i], &info) && info.dli_sname && !strstr(info.dli_sname, "redacted");
                if (named && strstr(info.dli_sname, "WebThreadLock"))
                    waitingForEngine = true;
                char methodName[256];
                if (named)
                    fprintf(log, "        %d %s  [%p]\n", i, info.dli_sname, (void *)mainFrames[i]);
                else if (nameByMethodTable(mainFrames[i], methodName, sizeof(methodName)))
                    fprintf(log, "        %d %s  [%p]\n", i, methodName, (void *)mainFrames[i]);
                else
                    fprintf(log, "        %d %p\n", i, (void *)mainFrames[i]);
            }

            if (waitingForEngine) {
                thread_act_t webThread = findWebThread();
                uintptr_t webFrames[24];
                int webDepth = 0;
                if (webThread != MACH_PORT_NULL && thread_suspend(webThread) == KERN_SUCCESS) {
                    webDepth = walkStack(webThread, webFrames, 24);
                    thread_resume(webThread);
                }
                fprintf(log, "    holder: web thread%s\n", webDepth ? "" : " not found");
                for (int i = 0; i < webDepth; i++) {
                    Dl_info info;
                    char webMethodName[256];
                    if (dladdr((void *)webFrames[i], &info) && info.dli_sname && !strstr(info.dli_sname, "redacted"))
                        fprintf(log, "        %d %s  [%p]\n", i, info.dli_sname, (void *)webFrames[i]);
                    else if (nameByMethodTable(webFrames[i], webMethodName, sizeof(webMethodName)))
                        fprintf(log, "        %d %s  [%p]\n", i, webMethodName, (void *)webFrames[i]);
                    else
                        fprintf(log, "        %d %p\n", i, (void *)webFrames[i]);
                }
            }
            usleep(2000000);
        } else if (responded - asked > 0.1)
            fprintf(log, "%.3f main thread lag %.0f ms\n", asked, (responded - asked) * 1000);
    }
    return NULL;
}

// A native object handed to the page.
//
// Everything else the app could use to hear from the page is either blocked or
// expensive: a navigation to a private scheme is stopped by the site's content
// security policy, and evaluating JavaScript from the main thread takes the web
// lock - measured freezing the interface for hundreds of milliseconds at a time
// while the engine was busy. A call the other way costs nothing: it arrives on
// the web thread, already inside the engine, where sending an event needs no
// lock at all.
@interface AppChromeBridge : NSObject {
    id _engineWindow;
    CGPoint _pendingPress;
    BOOL _hasPendingPress;
    NSString *_chromeDescription;
    BOOL _chromeChanged;
}
@property (nonatomic, assign) id engineWindow;
- (void)describeChrome:(NSString *)json;
- (NSString *)takeChromeDescription;
- (BOOL)takePendingPress:(CGPoint *)location;
@end

@implementation AppChromeBridge

@synthesize engineWindow = _engineWindow;

+ (NSString *)webScriptNameForSelector:(SEL)selector
{
    if (selector == @selector(pressAtX:y:))
        return @"pressAt";
    if (selector == @selector(describeChrome:))
        return @"chrome";
    return nil;
}

+ (BOOL)isSelectorExcludedFromWebScript:(SEL)selector
{
    return selector != @selector(pressAtX:y:) && selector != @selector(describeChrome:);
}

+ (BOOL)isKeyExcludedFromWebScript:(const char *)name
{
    return YES;
}

// Called from the page, which means from inside script execution on the web
// thread. Sending the event here would re-enter the engine mid-script - the
// event runs layout and more script, and the thread stops. So the request is
// only recorded; the press itself happens from the main thread, outside any
// script.
- (void)pressAtX:(float)x y:(float)y
{
    _pendingPress = CGPointMake(x, y);
    _hasPendingPress = YES;
}

// The page hands over its own bars, once, as JSON. Recorded here and read from
// the main thread, for the same reason the press is: this runs inside script on
// the web thread and must not re-enter the engine.
- (void)describeChrome:(NSString *)json
{
    [_chromeDescription release];
    _chromeDescription = [json copy];
    _chromeChanged = YES;
}

- (NSString *)takeChromeDescription
{
    if (!_chromeChanged)
        return nil;
    _chromeChanged = NO;
    return [[_chromeDescription retain] autorelease];
}

- (BOOL)takePendingPress:(CGPoint *)location
{
    if (!_hasPendingPress)
        return NO;
    _hasPendingPress = NO;
    *location = _pendingPress;
    return YES;
}

@end

@interface NativeAppDelegate : NSObject <UIApplicationDelegate, UIWebViewDelegate>
@end

static BOOL triggerFired(const char *path, time_t *lastSeen, BOOL *seeded)
{
    struct stat marker;
    if (stat(path, &marker))
        return NO;
    if (!*seeded) {
        *seeded = YES;
        *lastSeen = marker.st_mtime;
        return NO;
    }
    if (marker.st_mtime == *lastSeen)
        return NO;
    *lastSeen = marker.st_mtime;
    return YES;
}

// Moving the pinned layers in the same breath as the scroll.
//
// CoreAnimation commits the frame from a run loop observer of its own, at
// kCFRunLoopBeforeWaiting. An observer ordered just below it is the last thing
// to run before that commit, so the scroll offset read here is the one the frame
// is drawn with and the correction lands in the same transaction as the scroll.
// Nothing about this depends on when the display link happened to fire.
static void correctPinnedLayersBeforeCommit(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *context)
{
    (void)observer;
    (void)activity;
    [(id)context correctPinnedLayers];
}

@implementation NativeAppDelegate {
    UIWindow *_window;
    UIWebView *_webView;
    AppChromeBridge *_bridge;
    CGFloat _restoreOffset;
    CGFloat _lastGoodOffset;
    UITouch *_fingerTouch;
    CGPoint _fingerStart;
    CGFloat _fingerTravel;
    NSInteger _fingerStepsLeft;
    NSInteger _fingerTotalSteps;
    CGFloat _flickDistance;
    NSInteger _flickStepsLeft;
    CFAbsoluteTime _launchStamp;
    NSInteger _framesThisSecond;
    CFAbsoluteTime _frameWindowStart;
    CGPoint _publishedOffset;
    BOOL _injectedForThisDocument;
    BOOL _hasLoadedAPage;
    BOOL _imagesHeldBack;
    UIView *_bottomBar;
    NSMutableArray *_bottomBarTargets;
    NSString *_bottomBarHost;
    int _burstNumber;
    int _burstShot;
    CGSize _publishedViewport;
    BOOL _hasPublishedViewport;
    int _framesAtRest;
    int _viewportPublishesSinceRest;
    id _engineFixedContent;
    id _engineWakWindow;
    CGFloat _dragTarget;
    NSInteger _dragStepsLeft;
    BOOL _styleInjected;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{
    logLine(@"launched, WebView class %@, frameworks %s",
            NSStringFromClass(NSClassFromString(@"WebView")),
            getenv("DYLD_FRAMEWORK_PATH") ?: "(unset)");

    // The launch cost is the network: eighteen of the twenty-two seconds to a
    // usable feed were spent fetching the site's bundles. iOS 6 ships with a
    // tiny shared URL cache, so every launch downloads the same megabytes
    // again. A real disk cache lets the second launch skip the radio.
    // Off by default: two soaks with it on died of memory six and seven times
    // where the same build without it died once or twice. Serving every bundle
    // instantly makes the hydration peak steeper than the release valves can
    // answer. The wiring stays for a device with more headroom.
    if (access("/tmp/native-asset-cache-on", F_OK) == 0) {
        extern void StaticAssetCacheRegister(void);
        StaticAssetCacheRegister();
        logLine(@"static asset cache registered");
    }

    NSURLCache *urlCache = [[NSURLCache alloc] initWithMemoryCapacity:2 * 1024 * 1024
                                                         diskCapacity:60 * 1024 * 1024
                                                             diskPath:@"webapp-url-cache"];
    [NSURLCache setSharedURLCache:urlCache];
    [urlCache release];

    NSString *userAgent = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"WebAppUserAgent"];
    if (userAgent.length) {
        [[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObject:userAgent forKey:@"UserAgent"]];
        logLine(@"user agent: %@", userAgent);
    }

    // A plain window unless someone asks for the touch log. The logging subclass
    // writes a line to a file inside -sendEvent:, which is UIKit's touch delivery
    // path - synchronous I/O on the main thread for every touch, and it showed up
    // in the stack of a frozen interface.
    Class windowClass = access("/tmp/native-watch-touches", F_OK) == 0
        ? [TouchLoggingWindow class] : [UIWindow class];
    _window = [[windowClass alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    _window.backgroundColor = [UIColor whiteColor];

    // applicationFrame is the screen minus the status bar; the web view must not
    // sit under it or the page draws over the clock and the battery.
    _webView = [[UIWebView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]];
    // Page not yet painted should look like page, not like a hole.
    //
    // Painting happens on the web thread behind the web lock, and that thread is
    // regularly inside a multi-second callback of the site's own - measured at up
    // to twelve seconds in one React scheduler message. While that runs, tiles
    // for newly exposed page cannot be drawn, and what showed through was the
    // scroll view's dark grey. White reads as "still coming", which is the truth,
    // instead of as a broken window.
    _webView.backgroundColor = [UIColor whiteColor];
    _webView.opaque = YES;
    for (UIView *scrollCandidate in _webView.subviews)
        scrollCandidate.backgroundColor = [UIColor whiteColor];
    _webView.delegate = self;
    _webView.scalesPageToFit = NO;

    // 512 MB, and the engine's own frameworks take a fifth of it before a page
    // is loaded. Keeping finished documents alive for the back button is the
    // one setting that reliably pushes this over the edge: measured going from
    // 160 to 194 MB across four navigations, with the malloc heap doubling,
    // after which the system takes the app away. A page that has to be
    // re-fetched on Back is a far smaller loss than the app dying.
    Class preferencesClass = NSClassFromString(@"WebPreferences");
    id preferences = [preferencesClass respondsToSelector:@selector(standardPreferences)]
        ? [preferencesClass performSelector:@selector(standardPreferences)] : nil;
    if ([preferences respondsToSelector:@selector(setUsesPageCache:)]) {
        [preferences setUsesPageCache:NO];
        logLine(@"page cache off");
    } else
        logLine(@"could not reach WebPreferences to switch the page cache off");
    _webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_window addSubview:_webView];
    [_window makeKeyAndVisible];

    NSString *start = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"WebAppStartURL"];
    if (!start.length)
        start = @"https://www.threads.com/";
    _launchStamp = CFAbsoluteTimeGetCurrent();
    // Started on the next turn of the run loop, not inside
    // didFinishLaunchingWithOptions:.
    //
    // The engine's first delegate message - identifierForInitialRequest - is sent
    // from the web thread and blocks until the main thread services its run loop
    // source. Begun during launch, that wait was measured at 1310 ms, because the
    // main thread was still building the window. A single turn later it is idle and
    // answers at once.
    [self performSelector:@selector(loadStartPage) withObject:nil afterDelay:0];
    logLine(@"loading %@", start);

    [self watchForSnapshotRequest];
    [self watchForEvalRequest];
    [self watchForTapRequest];
    [self watchForScrollRequest];
    [self watchForTypeRequest];
    [self servePendingPress];
    // Where each framework landed, once, so a stack from a stripped binary can be
    // read offline against the unstripped copy in dist/unstripped:
    //   atos -o dist/unstripped/WebCore -arch armv7 -l <base> <address>
    for (uint32_t image = 0; image < _dyld_image_count(); image++) {
        const char *name = _dyld_get_image_name(image);
        if (!name)
            continue;
        if (!strstr(name, "WebCore") && !strstr(name, "JavaScriptCore")
            && !strstr(name, "WebKit.framework") && !strstr(name, "NativeUI"))
            continue;
        logLine(@"[image] %p %s", _dyld_get_image_header(image), strrchr(name, '/') + 1);
    }

    // Images held back until the document is parsed - off unless asked for.
    //
    // The measurement that suggested it: sixty five percent of the window before
    // domInteractive has requests in flight, and the chain is manifest, one link,
    // then an image taking 2863 ms followed by five more, holding connections the
    // parser still needs. The measurement that settled it: domInteractive with
    // the deferral 5304, 4901, 6812 ms against 6308, 6175, 5271, 5532 without -
    // no effect outside a drift that moves both. The images overlap the parse
    // rather than gate it. Kept behind a flag rather than deleted, because the
    // reasoning holds for a page whose images really are on the critical path.
    Class imagePreferencesClass = NSClassFromString(@"WebPreferences");
    id imagePreferences = [imagePreferencesClass respondsToSelector:@selector(standardPreferences)]
        ? [imagePreferencesClass performSelector:@selector(standardPreferences)] : nil;
    if ([imagePreferences respondsToSelector:@selector(setLoadsImagesAutomatically:)]
        && access("/tmp/native-defer-images", F_OK) == 0) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(imagePreferences, @selector(setLoadsImagesAutomatically:), NO);
        _imagesHeldBack = YES;
        logLine(@"images held back until the document is parsed");
    }

    // Which allocator is actually serving the engine.
    //
    // bmalloc registers a malloc zone of its own, so the zone list is a direct
    // answer to a question that has been settled twice by inference: whether the
    // build that links the ported allocator actually runs it.
    {
        vm_address_t *zones = NULL;
        unsigned count = 0;
        if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &count) == KERN_SUCCESS) {
            char names[256];
            int used = 0;
            for (unsigned i = 0; i < count && used < (int)sizeof(names) - 24; i++) {
                const char *zoneName = malloc_get_zone_name((malloc_zone_t *)zones[i]);
                used += snprintf(names + used, sizeof(names) - used, "%s%s", used ? "," : "", zoneName ? zoneName : "?");
            }
            logLine(@"[zones] %u: %s", count, names);
        }
    }

    // Keeping the screen awake while measuring.
    //
    // Wi-Fi on this device sleeps with the screen, and the connection the
    // measurements run over dies with it - three sessions were lost mid-run that
    // way, one of them a sixty second sample that cannot be repeated cheaply.
    // Behind a flag so a reader's battery is never spent on it.
    if (access("/tmp/native-keep-awake", F_OK) == 0) {
        [UIApplication sharedApplication].idleTimerDisabled = YES;
        logLine(@"screen kept awake for measurement");
    }

    [self startCountingFrames];
    [self installPinnedLayerObserver];
    // Both of these are diagnostics on hot paths and neither belongs in a
    // session a person is using. The delegate one wrote a line to a file for
    // every message the engine sent its delegate - synchronous file writes on
    // whichever thread the engine happened to be on, including the web thread.
    // The scroll one intercepts every setContentOffset:, which is every frame of
    // every scroll.
    if (!access("/tmp/native-watch-jumps", F_OK))
        watchForOffsetJumps();
    if (!access("/tmp/native-watch-delegate", F_OK))
        watchForDelegateMessages();

    return YES;
}

- (NSString *)bundleText:(NSString *)name
{
    NSString *path = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:name];
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
}

- (void)applyInjection
{
    NSString *marker = [_webView stringByEvaluatingJavaScriptFromString:@"window.__appchromeScript?'1':'0'"];
    if ([marker isEqualToString:@"1"])
        return;
    _styleInjected = NO;
    logLine(@"injecting app chrome");

    // Evaluated on the web thread, not this one.
    //
    // stringByEvaluatingJavaScriptFromString: takes the web lock from the main
    // thread, and the injected script is not small - measured as the only dip in
    // the frame rate for a whole session, to 25 frames per second, with two
    // stalls. Handed to the engine's own window object from inside WebThreadRun,
    // the same work costs the interface nothing.
    NSString *css = [self bundleText:@"inject.css"];
    NSString *js = [self bundleText:@"inject.js"];
    id scriptObject = [self engineWindowScriptObject];
    if (!scriptObject) {
        if (css.length)
            [_webView stringByEvaluatingJavaScriptFromString:[NSString stringWithFormat:
                @"(function(){var s=document.getElementById('__appchrome');if(!s){s=document.createElement('style');"
                 "s.id='__appchrome';document.documentElement.appendChild(s);}s.textContent=%@;})()",
                [self quoteForJavaScript:css]]];
        if (js.length)
            [_webView stringByEvaluatingJavaScriptFromString:js];
        _styleInjected = YES;
        return;
    }

    NSString *styleScript = css.length ? [NSString stringWithFormat:
        @"(function(){var s=document.getElementById('__appchrome');if(!s){s=document.createElement('style');"
         "s.id='__appchrome';document.documentElement.appendChild(s);}s.textContent=%@;})()",
        [self quoteForJavaScript:css]] : nil;
    void (*runOnWebThread)(void (^)(void)) = (void (*)(void (^)(void)))dlsym(RTLD_DEFAULT, "WebThreadRun");
    if (!runOnWebThread) {
        if (styleScript)
            [_webView stringByEvaluatingJavaScriptFromString:styleScript];
        if (js.length)
            [_webView stringByEvaluatingJavaScriptFromString:js];
        _styleInjected = YES;
        return;
    }
    runOnWebThread(^{
        if (styleScript)
            ((id (*)(id, SEL, id))objc_msgSend)(scriptObject, @selector(evaluateWebScript:), styleScript);
        if (js.length)
            ((id (*)(id, SEL, id))objc_msgSend)(scriptObject, @selector(evaluateWebScript:), js);
    });
    _styleInjected = YES;
}

- (NSString *)quoteForJavaScript:(NSString *)text
{
    NSMutableString *quoted = [NSMutableString stringWithString:text];
    [quoted replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, quoted.length)];
    [quoted replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, quoted.length)];
    [quoted replaceOccurrencesOfString:@"\n" withString:@"\\n" options:0 range:NSMakeRange(0, quoted.length)];
    [quoted replaceOccurrencesOfString:@"\r" withString:@"" options:0 range:NSMakeRange(0, quoted.length)];
    return [NSString stringWithFormat:@"\"%@\"", quoted];
}

// The frame rate a person actually sees.
//
// requestAnimationFrame runs on the web thread and reported sixty while the
// phone was visibly stuttering: the interface is composited on the main thread,
// so that is where frames must be counted. A display link fires once per screen
// refresh; how many of those the main thread manages to service is the number.
- (void)countFrame:(id)link
{
    [self publishViewportToEngine];
    _framesThisSecond++;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _frameWindowStart < 2.0)
        return;

    double fps = _framesThisSecond / (now - _frameWindowStart);
    _framesThisSecond = 0;
    _frameWindowStart = now;

    static double worst = 60;
    if (fps < worst)
        worst = fps;
    static int reports;
    if (fps < 25 || !(reports++ % 15))
        logLine(@"[uifps] %.1f frames per second on the interface thread (worst %.1f)", fps, worst);
}

// A second correction, only when the scroll has moved again since the frame
// callback ran.
//
// The display link fires at some point in the frame and UIKit updates the scroll
// offset at another. When the offset changes after the callback, the correction
// the callback computed describes the previous position and CoreAnimation
// commits a bar that is one frame behind - which is what shaking is. This runs
// immediately before the commit and only when there is something to fix, so a
// quiet run loop costs one comparison.
- (void)correctPinnedLayers
{
    UIScrollView *scroller = [self pageScroller];
    if (!scroller)
        return;
    CGPoint offset = scroller.contentOffset;

    // What the frame is actually being drawn with.
    //
    // UIKit's momentum scrolling does not have to move contentOffset once per
    // frame: it can animate the layer and leave the property behind. If it does,
    // a correction computed from contentOffset describes a different position
    // than the one CoreAnimation is about to commit, and the bar is a step out on
    // every frame of the glide - which is what shaking is. This records both so
    // the two can be compared instead of assumed.
    {
        static int recordScroll = -1;
        if (recordScroll < 0)
            recordScroll = access("/tmp/native-scroll-trace", F_OK) == 0 ? 1 : 0;
        if (recordScroll) {
            CALayer *presented = [scroller.layer presentationLayer];
            if (presented) {
                static FILE *scrollLog;
                if (!scrollLog) {
                    scrollLog = fopen("/tmp/native-scroll.log", "w");
                    if (scrollLog)
                        setvbuf(scrollLog, NULL, _IOLBF, 0);
                }
                if (scrollLog)
                    fprintf(scrollLog, "%.3f property %.1f presented %.1f\n", CFAbsoluteTimeGetCurrent(),
                        (double)offset.y, (double)[presented bounds].origin.y);
            }
        }
    }

    if (offset.y == lastCorrectedOffset)
        return;
    lastCorrectedOffset = offset.y;
    CGSize viewport = scroller.bounds.size;
    if (viewport.width < 1 || viewport.height < 1)
        return;

    id fixedContent = [self engineFixedContent];
    if (!fixedContent)
        return;
    // scrollOrZoomChanged: wraps its own layer moves in a transaction with
    // actions disabled, so there is nothing to add around it here.
    ((void (*)(id, SEL, CGRect))objc_msgSend)(fixedContent, @selector(scrollOrZoomChanged:),
        CGRectMake(offset.x, offset.y, viewport.width, viewport.height));
}

- (void)installPinnedLayerObserver
{
    // Just below CoreAnimation's own commit observer, which this version of
    // UIKit runs at order 2000000.
    CFRunLoopObserverContext context = {0, self, NULL, NULL, NULL};
    CFRunLoopObserverRef observer = CFRunLoopObserverCreate(kCFAllocatorDefault,
        kCFRunLoopBeforeWaiting, true, 1999999, correctPinnedLayersBeforeCommit, &context);
    if (!observer) {
        logLine(@"could not install the pinned layer observer");
        return;
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    CFRelease(observer);
    logLine(@"pinned layers corrected before each commit");
}

- (void)startCountingFrames
{
    Class linkClass = NSClassFromString(@"CADisplayLink");
    if (![linkClass respondsToSelector:@selector(displayLinkWithTarget:selector:)]) {
        logLine(@"no display link on this system");
        return;
    }
    id link = [linkClass displayLinkWithTarget:self selector:@selector(countFrame:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    _frameWindowStart = CFAbsoluteTimeGetCurrent();
    logLine(@"counting interface frames");
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application
{
    Class webViewClass = NSClassFromString(@"WebView");
    if ([webViewClass respondsToSelector:@selector(_releaseMemoryNow)]) {
        [webViewClass performSelector:@selector(_releaseMemoryNow)];
        logLine(@"memory warning: released engine memory");
    }
}


// When did the page become something a person can use? The document being
// "loaded" says nothing on a site that then builds itself in script - so this
// watches the document grow past one screen, which is the moment the feed is
// actually on glass.
- (void)reportReadiness
{
    static BOOL reported;
    if (reported)
        return;
    // The scroll view knows this and reading it takes no locks. Asking the page
    // instead meant a main-thread web-lock acquisition every two seconds, and
    // forever if the feed never grew - one guaranteed interface stall per two
    // seconds for the life of the session.
    UIScrollView *scroller = [self pageScroller];
    CGFloat documentHeight = scroller ? scroller.contentSize.height : 0;
    if (documentHeight > 700) {
        reported = YES;
        logLine(@"feed on glass %.1f s after launch", CFAbsoluteTimeGetCurrent() - _launchStamp);
        return;
    }
    [self performSelector:@selector(reportReadiness) withObject:nil afterDelay:2.0];
}

- (void)installBridge
{
    if (!_bridge) {
        _bridge = [[AppChromeBridge alloc] init];
        [_bridge setEngineWindow:[self engineWindow]];
    }
    id documentView = [_webView valueForKey:@"_documentView"];
    id engineWebView = [documentView respondsToSelector:@selector(webView)] ? [documentView performSelector:@selector(webView)] : nil;
    id scriptObject = [engineWebView respondsToSelector:@selector(windowScriptObject)]
        ? [engineWebView performSelector:@selector(windowScriptObject)] : nil;
    if (![scriptObject respondsToSelector:@selector(setValue:forKey:)]) {
        logLine(@"no window script object to install the bridge on (%@)", scriptObject);
        return;
    }
    [scriptObject setValue:_bridge forKey:@"appchrome"];
    logLine(@"bridge installed");
}

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType
{
    NSURL *url = [request URL];
    logLine(@"navigation request: %@", [[url absoluteString] length] > 60 ? [[url absoluteString] substringToIndex:60] : [url absoluteString]);
    if (navigationType != UIWebViewNavigationTypeOther || [[url scheme] hasPrefix:@"http"])
        _injectedForThisDocument = NO;
    // The promoted chrome belongs to the site it was read from.
    //
    // The bar is a real UIKit view in the window, so nothing removes it when the
    // reader leaves the site whose bar it is - it was seen sitting over
    // claude.ai, still carrying the Threads items. It goes as soon as a page
    // from another host starts loading; if that page describes a bar of its own,
    // the bridge builds it.
    if ([[url scheme] hasPrefix:@"http"] && _bottomBarHost
        && ![[url host] isEqualToString:_bottomBarHost]) {
        logLine(@"dropping the %@ bottom bar, now loading %@", _bottomBarHost, [url host]);
        [_bottomBar removeFromSuperview];
        [_bottomBar release];
        _bottomBar = nil;
        [_bottomBarHost release];
        _bottomBarHost = nil;
    }

    if (![[url scheme] isEqualToString:@"appchrome"])
        return YES;

    NSString *payload = [url resourceSpecifier];
    NSArray *parts = [payload componentsSeparatedByString:@"/"];
    if (parts.count == 2 && [[parts objectAtIndex:0] isEqualToString:@"sheet-close"]) {
        NSArray *coordinates = [[parts objectAtIndex:1] componentsSeparatedByString:@","];
        if (coordinates.count == 2)
            [self pressSheetCloseAt:CGPointMake([[coordinates objectAtIndex:0] floatValue],
                                                [[coordinates objectAtIndex:1] floatValue])];
    }
    return NO;
}

- (void)pressSheetCloseAt:(CGPoint)location
{
    static CFAbsoluteTime lastPress;
    if (CFAbsoluteTimeGetCurrent() - lastPress < 2.0)
        return;
    CGSize screen = _webView.bounds.size;
    if (location.x < 0 || location.y < 0 || location.x > screen.width || location.y > screen.height) {
        logLine(@"ignored a sheet-close report at %.0f,%.0f - not on screen", location.x, location.y);
        return;
    }
    id window = [self engineWindow];
    Class eventClass = NSClassFromString(@"WebEvent");
    if (!window || !eventClass)
        return;
    lastPress = CFAbsoluteTimeGetCurrent();
    for (int type = 0; type <= 1; type++) {
        id event = [[eventClass alloc] initWithMouseEventType:type timeStamp:CFAbsoluteTimeGetCurrent() location:location];
        [window sendEvent:event];
        [event release];
    }
    logLine(@"dismissed the app sheet at %.0f,%.0f", location.x, location.y);
}

// What the page itself reports.
//
// Without this a script that throws is invisible from the outside: the page
// simply does less than it should. The delegate is the engine's own console
// channel, so this catches the site's errors and warnings as the engine sees
// them, not only what a page chooses to hand to the bridge.
- (void)webView:(id)webView addMessageToConsole:(NSDictionary *)message withSource:(NSString *)source
{
    static FILE *log;
    static int enabled = -1;
    if (enabled < 0)
        enabled = access("/tmp/native-console", F_OK) == 0 ? 1 : 0;
    if (!enabled)
        return;
    if (!log) {
        log = fopen("/tmp/native-console.log", "w");
        if (log)
            setvbuf(log, NULL, _IOLBF, 0);
    }
    if (!log)
        return;

    NSString *text = [message objectForKey:@"message"];
    NSString *where = [message objectForKey:@"sourceURL"];
    id line = [message objectForKey:@"lineNumber"];
    fprintf(log, "%s | %s:%s | %s\n",
        [([message objectForKey:@"MessageLevel"] ?: @"log") UTF8String],
        where.length ? [[where lastPathComponent] UTF8String] : "?",
        line ? [[line description] UTF8String] : "?",
        text.length ? [text UTF8String] : "(empty)");
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error
{
    logLine(@"failed: %@", [error localizedDescription]);

    if (error.code == NSURLErrorCancelled)
        return;

    // A start page that never arrives is a white screen with no way out - the
    // app has no address bar. Retry with a growing pause, and only while the
    // document is still the empty shell (a failed subresource on a page that
    // already rendered is the site's business, not ours).
    NSString *nodes = [webView stringByEvaluatingJavaScriptFromString:@"String(document.getElementsByTagName('*').length)"];
    if ([nodes integerValue] > 10)
        return;
    static int retries;
    if (++retries > 5)
        return;
    NSTimeInterval delay = 2.0 * retries;
    logLine(@"retrying the start page in %.0f s (attempt %d)", delay, retries);
    [self performSelector:@selector(reloadStartPage) withObject:nil afterDelay:delay];
}

- (void)loadStartPage
{
    NSString *start = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"WebAppStartURL"];
    if (!start.length)
        start = @"https://www.threads.com/";
    logLine(@"loading %@", start);
    [_webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:start]]];
}

- (void)reloadStartPage
{
    NSString *start = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"WebAppStartURL"];
    if (!start.length)
        start = @"https://www.threads.com/";
    [_webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:start]]];
}

- (id)engineWindowScriptObject
{
    id engineWebView = [self engineWebView];
    if (![engineWebView respondsToSelector:@selector(windowScriptObject)])
        return nil;
    id scriptObject = [engineWebView performSelector:@selector(windowScriptObject)];
    return [scriptObject respondsToSelector:@selector(evaluateWebScript:)] ? scriptObject : nil;
}

- (id)engineWebView
{
    id documentView = [_webView valueForKey:@"_documentView"];
    return [documentView respondsToSelector:@selector(webView)] ? [documentView performSelector:@selector(webView)] : nil;
}

// Telling the engine where the window is.
//
// Everything on this port is painted into tiles in document coordinates and
// UIKit slides those tiles under the screen, so a position:fixed element
// scrolls away with the rest unless the engine is told, every frame, which
// rectangle of the document is currently on screen. This version of UIKit calls
// no such method on a 2025 engine - the selectors it knows are gone - so the app
// has to do it. Without this the site's own bars drift with the content and snap
// back at the next layout, and the page is never told it scrolled at all, so a
// feed that loads on scroll loads nothing.
//
// Driven from the display link rather than a scroll delegate so UIKit keeps its
// own delegate, and so the rectangle is published in the same frame the scroll
// is drawn in.
- (void)publishViewportToEngine
{
    UIScrollView *scroller = [self pageScroller];
    CGPoint offset = scroller ? scroller.contentOffset : CGPointZero;
    CGSize viewport = scroller ? scroller.bounds.size : CGSizeZero;

    // When the page last moved, so that the housekeeping running on the pulse
    // thread can stay out of the way of a scroll.
    static CGFloat previousOffset = -1;
    if (offset.y != previousOffset) {
        previousOffset = offset.y;
        lastScrollActivity = CFAbsoluteTimeGetCurrent();
    }

    static CFAbsoluteTime lastTrace;
    CFAbsoluteTime traceNow = CFAbsoluteTimeGetCurrent();
    if (traceNow - lastTrace > 2.0) {
        lastTrace = traceNow;
        id documentView = [_webView valueForKey:@"_documentView"];
        CGRect documentFrame = documentView ? [documentView frame] : CGRectZero;
        logLine(@"[viewport] offset %.0f bounds %.0fx%.0f contentSize %.0f document %.0f",
            offset.y, viewport.width, viewport.height,
            scroller ? scroller.contentSize.height : 0, documentFrame.size.height);
    }

    if (!scroller || viewport.width < 1 || viewport.height < 1)
        return;

    // Published on the first frame as well as on every move. The engine starts
    // with no idea where the window is, so a bar laid out against that default
    // lands in the wrong place - it appeared at the left edge and then jumped
    // down as soon as the first scroll finally told the engine the truth.
    BOOL moved = offset.y != _publishedOffset.y || offset.x != _publishedOffset.x
        || viewport.width != _publishedViewport.width || viewport.height != _publishedViewport.height
        || !_hasPublishedViewport;
    if (!moved) {
        if (_framesAtRest > 2)
            g_appIsScrolling = 0;
        if (_viewportPublishesSinceRest > 0 && ++_framesAtRest > 3) {
            _viewportPublishesSinceRest = 0;
            _framesAtRest = 0;
            id fixedContent = [self engineFixedContent];
            if ([fixedContent respondsToSelector:@selector(didFinishScrollingOrZooming)])
                [fixedContent performSelector:@selector(didFinishScrollingOrZooming)];
        }
        return;
    }

    g_appIsScrolling = 1;
    _publishedOffset = offset;
    _publishedViewport = viewport;
    _hasPublishedViewport = YES;
    _framesAtRest = 0;
    _viewportPublishesSinceRest++;

    CGRect onScreen = CGRectMake(offset.x, offset.y, viewport.width, viewport.height);

    // The rectangle the engine calls its viewport.
    //
    // WAKScrollView::unobscuredContentRect - which is what
    // ScrollView::unobscuredContentRect returns, and therefore what the engine
    // uses to lay out anything viewport-constrained and to decide what an
    // IntersectionObserver can see - is [window exposedScrollViewRect] converted
    // into document coordinates. This application never set it. The browser
    // application sets it on every scroll; here it stayed at whatever it was when
    // the window was made.
    //
    // So while a finger moved the page, the engine believed the viewport had not
    // moved: fixed elements were laid out against a stale rectangle and only
    // corrected when something else forced a layout, which is a bar that drifts
    // and snaps back, and no observer ever saw a post enter the screen, which is
    // a feed that does not load more.
    if (!_engineWakWindow)
        _engineWakWindow = [[self engineWindow] retain];
    if ([_engineWakWindow respondsToSelector:@selector(setExposedScrollViewRect:)]
        && access("/tmp/native-no-exposed-rect", F_OK) != 0) {
        void (*runOnWebThread)(void (^)(void)) = (void (*)(void (^)(void)))dlsym(RTLD_DEFAULT, "WebThreadRun");
        id window = _engineWakWindow;
        if (runOnWebThread) {
            runOnWebThread(^{
                ((void (*)(id, SEL, CGRect))objc_msgSend)(window, @selector(setExposedScrollViewRect:), onScreen);
            });
        }
    }

    // And the rectangle visibility is measured against.
    //
    // Separate from the fixed-position rect above: that one positions
    // viewport-constrained boxes, this one is LocalFrameView::layoutViewportRect,
    // which is the root an IntersectionObserver without an explicit root uses.
    // Its origin normally moves in LocalFrameView::scrollPositionChanged, which
    // this port never reaches, so without setting it here the engine believes the
    // window is still at the top of the document no matter how far a finger has
    // scrolled.
    // Every frame, now that it is cheap.
    //
    // Four times a second was tried and is not enough: between publishes the
    // engine lays viewport-constrained boxes out against a stale rectangle, and a
    // flick moves hundreds of pixels in that gap - the bar's screen position was
    // measured spread over 1592 px. The expense was never the storing of the
    // rectangle but the layout it used to trigger, and that is now off, so this
    // can run at frame rate.
    static CFAbsoluteTime lastLayoutViewportPublish;
    CFAbsoluteTime publishNow = CFAbsoluteTimeGetCurrent();
    double publishInterval = access("/tmp/native-slow-layout-viewport", F_OK) == 0 ? 0.0 : 0.25;
    if (publishNow - lastLayoutViewportPublish >= publishInterval) {
        lastLayoutViewportPublish = publishNow;
        id viewportTarget = [self engineWebView];
        SEL setLayoutViewport = @selector(_setLayoutViewportRect:);
        if ([viewportTarget respondsToSelector:setLayoutViewport]
            && access("/tmp/native-no-layout-viewport", F_OK) != 0)
            ((void (*)(id, SEL, CGRect))objc_msgSend)(viewportTarget, setLayoutViewport, onScreen);
    }

    // scrollOrZoomChanged: wraps its own layer moves in a transaction with
    // actions disabled, so there is nothing to add around it here.
    id fixedContent = [self engineFixedContent];
    if (fixedContent)
        ((void (*)(id, SEL, CGRect))objc_msgSend)(fixedContent, @selector(scrollOrZoomChanged:), onScreen);
    lastCorrectedOffset = offset.y;

    id engineWebView = [self engineWebView];
    SEL publish = @selector(_setCustomFixedPositionLayoutRectInWebThread:synchronize:);
    if ([engineWebView respondsToSelector:publish])
        ((void (*)(id, SEL, CGRect, BOOL))objc_msgSend)(engineWebView, publish, onScreen, NO);
}

- (id)engineFixedContent
{
    if (_engineFixedContent)
        return _engineFixedContent;
    id engineWebView = [self engineWebView];
    if ([engineWebView respondsToSelector:@selector(_fixedPositionContent)])
        _engineFixedContent = [[engineWebView performSelector:@selector(_fixedPositionContent)] retain];
    if (!_engineFixedContent)
        logLine(@"no fixed position content on the engine web view (%@)", engineWebView);
    else
        logLine(@"publishing the viewport to the engine");
    return _engineFixedContent;
}

- (id)engineWindow
{
    id documentView = [_webView valueForKey:@"_documentView"];
    id webView = [documentView respondsToSelector:@selector(webView)] ? [documentView performSelector:@selector(webView)] : nil;
    return [webView respondsToSelector:@selector(window)] ? [webView performSelector:@selector(window)] : nil;
}

// The bridge records what the page asked for; this runs on the main thread and
// performs it, so nothing re-enters the engine from inside script.
// The site's bars, drawn by the system instead of the page.
//
// A position:fixed bar lives inside the layer UIKit slides when it scrolls, so
// keeping it still means moving it the other way every frame - two systems, two
// transactions, and no amount of care makes that perfectly steady. Drawn as real
// views outside the web view, the bars are not in that path at all: nothing can
// make them drift, and the engine has two fewer composited layers to carry.
//
// The page reports its own bars once, through the bridge, and hides them. Taps
// become navigations, which is what the page's own controls were going to do.
- (void)serveChromeDescription
{
    NSString *json = [_bridge takeChromeDescription];
    if (!json.length)
        return;

    id parsed = nil;
    Class serialization = NSClassFromString(@"NSJSONSerialization");
    if ([serialization respondsToSelector:@selector(JSONObjectWithData:options:error:)]) {
        NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
        parsed = [serialization performSelector:@selector(JSONObjectWithData:options:error:)
                                    withObject:data withObject:nil];
    }
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        logLine(@"could not read the chrome description");
        return;
    }

    NSArray *items = [parsed objectForKey:@"bottom"];
    if (![items isKindOfClass:[NSArray class]] || !items.count) {
        logLine(@"no bottom bar in the chrome description");
        return;
    }

    [_bottomBar removeFromSuperview];
    [_bottomBar release];

    CGFloat height = 50;
    CGRect frame = _window.bounds;
    _bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, frame.size.height - height, frame.size.width, height)];
    _bottomBar.backgroundColor = [UIColor whiteColor];
    _bottomBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;

    UIView *hairline = [[UIView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, 1)];
    hairline.backgroundColor = [UIColor colorWithWhite:0.85 alpha:1];
    hairline.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_bottomBar addSubview:hairline];
    [hairline release];

    [_bottomBarTargets release];
    _bottomBarTargets = [[NSMutableArray alloc] init];

    CGFloat itemWidth = frame.size.width / items.count;
    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *item = [items objectAtIndex:i];
        if (![item isKindOfClass:[NSDictionary class]])
            continue;
        NSString *href = [item objectForKey:@"href"];
        NSString *label = [item objectForKey:@"label"];
        [_bottomBarTargets addObject:href.length ? href : @""];

        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.frame = CGRectMake(i * itemWidth, 1, itemWidth, height - 1);
        button.tag = (NSInteger)i;
        [button setTitle:(label.length ? label : @"?") forState:UIControlStateNormal];
        [button setTitleColor:[UIColor colorWithWhite:0.35 alpha:1] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:11];
        [button addTarget:self action:@selector(bottomBarItemPressed:) forControlEvents:UIControlEventTouchUpInside];
        [_bottomBar addSubview:button];
    }

    [_bottomBarHost release];
    _bottomBarHost = [[[NSURL URLWithString:[[[_webView request] URL] absoluteString]] host] copy];

    [_window addSubview:_bottomBar];
    CGRect windowOnScreen = [_window convertRect:_window.bounds toWindow:nil];
    CGRect barOnScreen = [_bottomBar convertRect:_bottomBar.bounds toView:nil];
    logLine(@"native bottom bar with %u items: window frame %.0f,%.0f %.0fx%.0f on screen %.0f..%.0f, bar on screen %.0f..%.0f, web view %.0f,%.0f %.0fx%.0f, screen %.0f, status bar hidden %d",
        (unsigned)items.count,
        _window.frame.origin.x, _window.frame.origin.y, _window.frame.size.width, _window.frame.size.height,
        windowOnScreen.origin.y, windowOnScreen.origin.y + windowOnScreen.size.height,
        barOnScreen.origin.y, barOnScreen.origin.y + barOnScreen.size.height,
        _webView.frame.origin.x, _webView.frame.origin.y, _webView.frame.size.width, _webView.frame.size.height,
        [UIScreen mainScreen].bounds.size.height,
        (int)[UIApplication sharedApplication].statusBarHidden);
}

- (void)bottomBarItemPressed:(UIButton *)button
{
    NSUInteger index = (NSUInteger)button.tag;
    if (index >= _bottomBarTargets.count)
        return;
    NSString *href = [_bottomBarTargets objectAtIndex:index];
    if (!href.length)
        return;
    NSURL *url = [NSURL URLWithString:href relativeToURL:[_webView.request URL]];
    if (!url)
        return;
    logLine(@"native bar navigating to %@", [url absoluteString]);
    [_webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)servePendingPress
{
    // Injecting when the document actually has content, not when the load ends.
    //
    // This was hung off webViewDidFinishLoad:, and this site never reaches it -
    // it keeps connections open and the delegate callback does not arrive. So the
    // bridge and the injected script were absent for whole sessions, and
    // everything that depends on them silently did nothing: the install sheet was
    // never dismissed, the bars were never promoted. Measured on the device:
    // window.__appchromeV read 0 and window.appchrome was undefined.
    //
    // The scroll view's content size is the cheapest evidence that a document
    // exists, and reading it takes no locks. One evaluation per document, not a
    // poll: the flag is cleared when a main-frame navigation starts.
    if (_imagesHeldBack) {
        UIScrollView *scroller = [self pageScroller];
        if (scroller && scroller.contentSize.height > 700) {
            _imagesHeldBack = NO;
            Class preferencesClass = NSClassFromString(@"WebPreferences");
            id preferences = [preferencesClass respondsToSelector:@selector(standardPreferences)]
                ? [preferencesClass performSelector:@selector(standardPreferences)] : nil;
            if ([preferences respondsToSelector:@selector(setLoadsImagesAutomatically:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(preferences, @selector(setLoadsImagesAutomatically:), YES);
                logLine(@"images released");
            }
        }
    }

    if (!_injectedForThisDocument) {
        UIScrollView *scroller = [self pageScroller];
        if (scroller && scroller.contentSize.height > 700) {
            _injectedForThisDocument = YES;
            [self installBridge];
            [self applyInjection];
        }
    }

    [self serveChromeDescription];
    // Sampled here because this already runs on the main thread every fraction
    // of a second and reading a scroll view costs nothing: the position to
    // restore has to be remembered before the sheet appears, since by the time
    // it is up the feed is unmounted and the offset is already zero.
    UIScrollView *tracked = [self pageScroller];
    if (tracked) {
        // Watching for the jump to the top. Sampled often enough to catch it and
        // cheap enough to leave on: reading a scroll view touches no locks.
        static CGFloat previousOffset;
        static CGFloat previousSize;
        CGFloat offset = tracked.contentOffset.y;
        CGFloat size = tracked.contentSize.height;
        if (previousOffset - offset > 100 && size >= previousSize - 1)
            logLine(@"[jump] offset %.0f -> %.0f while contentSize %.0f -> %.0f",
                previousOffset, offset, previousSize, size);
        previousOffset = offset;
        previousSize = size;

        if (size > tracked.bounds.size.height * 1.5 && offset > 40)
            _lastGoodOffset = offset;
    }

    CGPoint at;
    if (_bridge && [_bridge takePendingPress:&at]) {
        static CFAbsoluteTime lastPress;
        CGSize screen = _webView.bounds.size;
        if (at.x > 0 && at.y > 0 && at.x < screen.width && at.y < screen.height
            && CFAbsoluteTimeGetCurrent() - lastPress > 2.0) {
            lastPress = CFAbsoluteTimeGetCurrent();
            id window = [self engineWindow];
            Class eventClass = NSClassFromString(@"WebEvent");
            if (window && eventClass) {
                for (int type = 0; type <= 1; type++) {
                    id event = [[eventClass alloc] initWithMouseEventType:type timeStamp:CFAbsoluteTimeGetCurrent() location:at];
                    [window sendEvent:event];
                    [event release];
                }
                logLine(@"pressed at %.0f,%.0f for the page", at.x, at.y);

                // The sheet unmounts the feed while it is up, so the scroll
                // position is lost and the reader is thrown back to the top
                // every time this site raises it. Remember where they were and
                // put them back once the feed is tall again.
                if (_restoreOffset <= 0 && _lastGoodOffset > 0) {
                    _restoreOffset = _lastGoodOffset;
                    [self performSelector:@selector(restoreScrollPosition) withObject:nil afterDelay:0.8];
                }
            }
        }
    }
    [self performSelector:@selector(servePendingPress) withObject:nil afterDelay:0.4];
}

- (void)restoreScrollPosition
{
    UIScrollView *scroller = [self pageScroller];
    if (!scroller || _restoreOffset <= 0)
        return;

    CGFloat reachable = scroller.contentSize.height - scroller.bounds.size.height;
    if (reachable < _restoreOffset) {
        static int waits;
        // The feed rebuilds a screenful at a time after the sheet unmounted it,
        // and six seconds was routinely not enough - the restore silently gave
        // up and the reader landed at the top, which read as "оно ускакивает".
        if (++waits < 40) {
            [self performSelector:@selector(restoreScrollPosition) withObject:nil afterDelay:0.5];
            return;
        }
        waits = 0;
        // The full position is not coming back; whatever part of the feed is
        // rebuilt is still closer to where the reader was than the top is.
        if (reachable > 100) {
            [scroller setContentOffset:CGPointMake(0, reachable) animated:NO];
            logLine(@"put the reader part-way back: %.0f of %.0f", reachable, _restoreOffset);
        } else
            logLine(@"gave up restoring %.0f - the feed did not come back", _restoreOffset);
        _restoreOffset = 0;
        return;
    }

    [scroller setContentOffset:CGPointMake(0, _restoreOffset) animated:NO];
    logLine(@"put the reader back at %.0f", _restoreOffset);
    _restoreOffset = 0;
}

- (void)watchForTypeRequest
{
    // Whatever happens in here, the timer must be armed again. One
    // exception used to end the chain silently and every trigger it serves
    // stopped working - measured as a flick harness that fired once after a
    // launch and never again, which quietly invalidated every measurement
    // that used it.
    @try {
        struct stat marker;
        static time_t lastRequest;
        static BOOL seeded1;
        if (triggerFired("/tmp/native-type", &lastRequest, &seeded1)) {
            NSString *text = [NSString stringWithContentsOfFile:@"/tmp/native-type" encoding:NSUTF8StringEncoding error:NULL];
            text = [text stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            id window = [self engineWindow];
            Class eventClass = NSClassFromString(@"WebEvent");
            if (!window || !eventClass || !text.length) {
                logLine(@"type failed: window=%@ text=%@", window, text);
            } else {
                for (NSUInteger i = 0; i < text.length; i++) {
                    NSString *character = [text substringWithRange:NSMakeRange(i, 1)];
                    for (int type = 4; type <= 5; type++) {
                        id event = [[eventClass alloc] initWithKeyEventType:type
                                                                  timeStamp:CFAbsoluteTimeGetCurrent()
                                                                 characters:character
                                                charactersIgnoringModifiers:character
                                                                  modifiers:0
                                                                isRepeating:NO
                                                                  withFlags:0
                                                       withInputManagerHint:nil
                                                                    keyCode:0
                                                                   isTabKey:NO];
                        [window sendEvent:event];
                        [event release];
                    }
                }
                logLine(@"typed \"%@\" through the engine window", text);
            }
        }
    } @catch (id chainError) {
        logLine(@"watchForTypeRequest raised %@", chainError);
    }
    [self performSelector:@selector(watchForTypeRequest) withObject:nil afterDelay:0.5];
}

- (void)watchForScrollRequest
{
    // Whatever happens in here, the timer must be armed again. One
    // exception used to end the chain silently and every trigger it serves
    // stopped working - measured as a flick harness that fired once after a
    // launch and never again, which quietly invalidated every measurement
    // that used it.
    @try {
        struct stat marker;
        static time_t lastRequest;
        static time_t lastDrag;
        static time_t lastURL;
        static BOOL seeded2;
        if (triggerFired("/tmp/native-scroll", &lastRequest, &seeded2)) {
            NSString *value = [NSString stringWithContentsOfFile:@"/tmp/native-scroll" encoding:NSUTF8StringEncoding error:NULL];
            CGFloat offset = [[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] floatValue];
            UIScrollView *scroller = nil;
            for (UIView *view in _webView.subviews) {
                if ([view isKindOfClass:[UIScrollView class]]) { scroller = (UIScrollView *)view; break; }
            }
            if (scroller) {
                [scroller setContentOffset:CGPointMake(0, offset) animated:NO];
                logLine(@"scrolled to %.0f, content height %.0f", offset, scroller.contentSize.height);
            } else
                logLine(@"no scroll view found");
        }
        static BOOL seeded3;
        static time_t lastFlick;
        static BOOL seededFlick;
        if (triggerFired("/tmp/native-flick", &lastFlick, &seededFlick)) {
            NSString *text = [NSString stringWithContentsOfFile:@"/tmp/native-flick" encoding:NSUTF8StringEncoding error:NULL];
            NSArray *parts = [[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@","];
            _flickDistance = parts.count > 0 ? [[parts objectAtIndex:0] floatValue] : 300;
            _flickStepsLeft = parts.count > 1 ? [[parts objectAtIndex:1] intValue] : 6;
            logLine(@"flicking %.0f px, %d times", _flickDistance, (int)_flickStepsLeft);
            [self flickStep];
        }

        static time_t lastFinger;
        static BOOL seededFinger;
        if (triggerFired("/tmp/native-finger", &lastFinger, &seededFinger)) {
            NSString *fingerText = [NSString stringWithContentsOfFile:@"/tmp/native-finger" encoding:NSUTF8StringEncoding error:NULL];
            NSArray *fingerParts = [[fingerText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@","];
            // Held back: on this OS UITouch has no setters for the fields UIKit
            // needs, and a half-built touch crashed inside its own delivery. The
            // measurement below uses the scroll view's own animation instead, which
            // goes through the same interface-thread work without inventing events.
            // Kept, but off: a touch built by hand crashes inside UIKit's own
            // delivery on this OS, and an instrument that breaks what it measures is
            // worse than no instrument. The scroll view's own animation below goes
            // through the same interface-thread work without inventing events.
            if (access("/tmp/native-finger-enabled", F_OK) == 0 && fingerParts.count >= 2 && !_fingerTouch) {
                _fingerStart = CGPointMake([[fingerParts objectAtIndex:0] floatValue], [[fingerParts objectAtIndex:1] floatValue]);
                _fingerTravel = fingerParts.count > 2 ? [[fingerParts objectAtIndex:2] floatValue] : 0;
                _fingerStepsLeft = fingerParts.count > 3 ? [[fingerParts objectAtIndex:3] intValue] : (_fingerTravel ? 20 : 1);
                _fingerTotalSteps = _fingerStepsLeft;
                _fingerTouch = [synthesizedTouch(_window, _fingerStart) retain];
                if (_fingerTouch) {
                    deliverTouch(_fingerTouch, UITouchPhaseBegan, _fingerStart);
                    logLine(@"finger down at %.0f,%.0f travel %.0f in %d steps",
                        _fingerStart.x, _fingerStart.y, _fingerTravel, (int)_fingerStepsLeft);
                    [self performSelector:@selector(fingerStep) withObject:nil afterDelay:1.0 / 60.0];
                }
            }
        }

        if (triggerFired("/tmp/native-url", &lastURL, &seeded3)) {
            NSString *text = [NSString stringWithContentsOfFile:@"/tmp/native-url" encoding:NSUTF8StringEncoding error:NULL];
            NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSURL *url = [NSURL URLWithString:trimmed];
            if (url) {
                logLine(@"loading %@", trimmed);
                [_webView loadRequest:[NSURLRequest requestWithURL:url]];
            }
        }

        static BOOL seeded4;
        if (triggerFired("/tmp/native-drag", &lastDrag, &seeded4)) {
            NSString *value = [NSString stringWithContentsOfFile:@"/tmp/native-drag" encoding:NSUTF8StringEncoding error:NULL];
            _dragTarget = [[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] floatValue];
            _dragStepsLeft = 40;
            [self dragStep];
        }
    } @catch (id chainError) {
        logLine(@"watchForScrollRequest raised %@", chainError);
    }
    [self performSelector:@selector(watchForScrollRequest) withObject:nil afterDelay:0.5];
}

- (UIScrollView *)pageScroller
{
    for (UIView *view in _webView.subviews)
        if ([view isKindOfClass:[UIScrollView class]])
            return (UIScrollView *)view;
    return nil;
}

- (void)fingerStep
{
    if (!_fingerTouch)
        return;

    if (_fingerStepsLeft <= 0) {
        CGPoint end = CGPointMake(_fingerStart.x, _fingerStart.y + _fingerTravel);
        deliverTouch(_fingerTouch, UITouchPhaseEnded, end);
        logLine(@"finger up at %.0f,%.0f", end.x, end.y);
        [_fingerTouch release];
        _fingerTouch = nil;
        return;
    }

    NSInteger done = _fingerTotalSteps - _fingerStepsLeft + 1;
    CGPoint at = CGPointMake(_fingerStart.x, _fingerStart.y + _fingerTravel * done / _fingerTotalSteps);
    _fingerStepsLeft--;
    if (_fingerTravel)
        deliverTouch(_fingerTouch, UITouchPhaseMoved, at);
    [self performSelector:@selector(fingerStep) withObject:nil afterDelay:1.0 / 60.0];
}

// A flick, as UIKit performs one: its own animation, on its own thread, with
// every callback and tile request a finger would produce.
- (void)flickStep
{
    UIScrollView *scroller = [self pageScroller];
    if (!scroller || _flickStepsLeft <= 0) {
        if (scroller)
            logLine(@"flick sequence finished at %.0f", scroller.contentOffset.y);
        return;
    }
    _flickStepsLeft--;
    CGFloat reachable = MAX(0, scroller.contentSize.height - scroller.bounds.size.height);
    logLine(@"flick: offset %.0f contentSize %.0f bounds %.0f reachable %.0f",
        scroller.contentOffset.y, scroller.contentSize.height, scroller.bounds.size.height, reachable);
    // Clamped at both ends. Only the top was, so a run of upward flicks walked
    // the offset far past zero - measured at -4513 - and the page then reads
    // window.pageYOffset as negative, computes a nonsense distance to the bottom
    // and stops asking for more posts. An instrument that puts the page into a
    // state a finger cannot reach is worse than no instrument.
    CGFloat target = MAX(0, MIN(reachable, scroller.contentOffset.y + _flickDistance));
    [scroller setContentOffset:CGPointMake(0, target) animated:YES];
    [self performSelector:@selector(flickStep) withObject:nil afterDelay:1.2];
}

- (void)dragStep
{
    UIScrollView *scroller = [self pageScroller];
    if (!scroller || _dragStepsLeft <= 0) {
        if (scroller)
            logLine(@"drag finished at %.0f", scroller.contentOffset.y);
        return;
    }
    CGFloat maximumOffset = MAX(0, scroller.contentSize.height - scroller.bounds.size.height);
    if (_dragTarget > maximumOffset)
        _dragTarget = maximumOffset;
    CGFloat current = scroller.contentOffset.y;
    CGFloat step = (_dragTarget - current) / _dragStepsLeft;
    _dragStepsLeft--;
    [scroller setContentOffset:CGPointMake(0, current + step) animated:NO];
    [self performSelector:@selector(dragStep) withObject:nil afterDelay:1.0 / 60.0];
}

- (void)watchForTapRequest
{
    // Whatever happens in here, the timer must be armed again. One
    // exception used to end the chain silently and every trigger it serves
    // stopped working - measured as a flick harness that fired once after a
    // launch and never again, which quietly invalidated every measurement
    // that used it.
    @try {
        struct stat marker;
        static time_t lastRequest;
        static BOOL seeded5;
        if (triggerFired("/tmp/native-tap", &lastRequest, &seeded5)) {
            NSString *point = [NSString stringWithContentsOfFile:@"/tmp/native-tap" encoding:NSUTF8StringEncoding error:NULL];
            NSArray *parts = [[point stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@","];
            if (parts.count == 2) {
                CGPoint where = CGPointMake([[parts objectAtIndex:0] floatValue], [[parts objectAtIndex:1] floatValue]);
                id window = [self engineWindow];
                Class eventClass = NSClassFromString(@"WebEvent");
                if (window && eventClass) {
                    for (int type = 0; type <= 1; type++) {
                        id event = [[eventClass alloc] initWithMouseEventType:type timeStamp:CFAbsoluteTimeGetCurrent() location:where];
                        [window sendEvent:event];
                        [event release];
                    }
                    logLine(@"tapped %.0f,%.0f through the engine window", where.x, where.y);
                } else
                    logLine(@"tap failed: window=%@ eventClass=%@", window, eventClass);
            }
        }
    } @catch (id chainError) {
        logLine(@"watchForTapRequest raised %@", chainError);
    }
    [self performSelector:@selector(watchForTapRequest) withObject:nil afterDelay:0.5];
}

- (void)watchForEvalRequest
{
    // Whatever happens in here, the timer must be armed again. One
    // exception used to end the chain silently and every trigger it serves
    // stopped working - measured as a flick harness that fired once after a
    // launch and never again, which quietly invalidated every measurement
    // that used it.
    @try {
        struct stat marker;
        static time_t lastRequest;
        static BOOL seeded6;
        if (triggerFired("/tmp/native-eval", &lastRequest, &seeded6)) {
            NSString *script = [NSString stringWithContentsOfFile:@"/tmp/native-eval" encoding:NSUTF8StringEncoding error:NULL];
            NSString *result = script.length ? [_webView stringByEvaluatingJavaScriptFromString:script] : @"(empty)";
            [(result ? result : @"(nil)") writeToFile:@"/tmp/native-eval-result" atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        }
    } @catch (id chainError) {
        logLine(@"watchForEvalRequest raised %@", chainError);
    }
    [self performSelector:@selector(watchForEvalRequest) withObject:nil afterDelay:0.5];
}

- (void)watchForSnapshotRequest
{
    // Whatever happens in here, the timer must be armed again. One
    // exception used to end the chain silently and every trigger it serves
    // stopped working - measured as a flick harness that fired once after a
    // launch and never again, which quietly invalidated every measurement
    // that used it.
    @try {
        struct stat marker;
        static time_t lastRequest;
        static BOOL seeded7;
        if (triggerFired("/tmp/native-snap", &lastRequest, &seeded7))
            [self writeSnapshot];

        static time_t lastBurst;
        static BOOL seededBurst;
        if (triggerFired("/tmp/native-snap-burst", &lastBurst, &seededBurst))
            [self writeSnapshotBurst];
    } @catch (id chainError) {
        logLine(@"watchForSnapshotRequest raised %@", chainError);
    }
    [self performSelector:@selector(watchForSnapshotRequest) withObject:nil afterDelay:1.0];
}

// Where the bars are painted, three frames apart.
//
// A drifting bar cannot be seen in one still, and the render tree reports where
// it believes the bar is rather than where the compositor drew it. Three shots
// during one scroll settle the question.
- (void)writeSnapshotBurst
{
    static int burst;
    burst++;
    _burstNumber = burst;
    _burstShot = 0;
    [self nextBurstShot];
}

- (void)nextBurstShot
{
    // Chained rather than slept through: four shots a eighth of a second apart
    // used to be three sleepForTimeInterval: calls on the main thread, which is
    // 360 ms of deliberately blocked interface inside a diagnostic.
    [self writeSnapshotTo:[NSString stringWithFormat:@"/tmp/burst-%d-%d.png", _burstNumber, _burstShot]];
    if (++_burstShot < 10)
        [self performSelector:@selector(nextBurstShot) withObject:nil afterDelay:0.05];
}

- (void)writeSnapshotTo:(NSString *)path
{
    CGImageRef (*screenImage)(void) = (CGImageRef (*)(void))dlsym(RTLD_DEFAULT, "UIGetScreenImage");
    if (!screenImage) {
        logLine(@"no screen capture available");
        return;
    }
    CGImageRef image = screenImage();
    if (!image)
        return;
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, (CFStringRef)path, kCFURLPOSIXPathStyle, false);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    if (destination) {
        CGImageDestinationAddImage(destination, image, NULL);
        CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CFRelease(url);
    CGImageRelease(image);
    logLine(@"snapshot written to %@", path);
}

- (void)writeSnapshot
{
    [self writeSnapshotTo:@"/tmp/native-shot.png"];

    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
        logLine(@"footprint %.1f MB resident, %.1f MB peak", info.resident_size / 1048576.0, info.resident_size_max / 1048576.0);
    id documentView = [_webView valueForKey:@"_documentView"];
    id webView = [documentView respondsToSelector:@selector(webView)] ? [documentView performSelector:@selector(webView)] : nil;
    id wakWindow = [webView respondsToSelector:@selector(window)] ? [webView performSelector:@selector(window)] : nil;
    if (wakWindow && [wakWindow respondsToSelector:@selector(screenSize)]) {
        CGSize (*screenSize)(id, SEL) = (CGSize (*)(id, SEL))objc_msgSend_stret;
        CGSize size = screenSize(wakWindow, @selector(screenSize));
        logLine(@"engine screen size: %.0f x %.0f", size.width, size.height);
    } else
        logLine(@"engine window: documentView=%@ webView=%@ window=%@", documentView, webView, wakWindow);

    logLine(@"frames: uiWebView=%@ scroll=%@ browser=%@ document=%@",
            NSStringFromCGRect(_webView.frame),
            NSStringFromCGRect([[_webView.subviews objectAtIndex:0] frame]),
            NSStringFromCGRect([[[[_webView.subviews objectAtIndex:0] subviews] objectAtIndex:0] frame]),
            documentView ? NSStringFromCGRect([documentView frame]) : @"(none)");

    logLine(@"content: bodyScrollWidth=%@ docScrollWidth=%@ outerWidth=%@ screen=%@",
            [_webView stringByEvaluatingJavaScriptFromString:@"String(document.body.scrollWidth)"],
            [_webView stringByEvaluatingJavaScriptFromString:@"String(document.documentElement.scrollWidth)"],
            [_webView stringByEvaluatingJavaScriptFromString:@"String(window.outerWidth)"],
            [_webView stringByEvaluatingJavaScriptFromString:@"screen.width+'x'+screen.height"]);
    logLine(@"layout: innerWidth=%@ clientWidth=%@ scale=%@ viewport=%@",
            [_webView stringByEvaluatingJavaScriptFromString:@"String(window.innerWidth)"],
            [_webView stringByEvaluatingJavaScriptFromString:@"String(document.documentElement.clientWidth)"],
            [_webView stringByEvaluatingJavaScriptFromString:@"String(window.devicePixelRatio)"],
            [_webView stringByEvaluatingJavaScriptFromString:@"(document.querySelector('meta[name=viewport]')||{}).content||'(none)'"]);
}
@end


int NativeAppMain(int argc, char *argv[]);

// The address that faulted and the register that held it.
//
// A stack alone names the function; it does not say which pointer was bad, and
// on this port the answer has twice turned out to be a value that looked fine
// in the source. The three-argument handler carries siginfo and the thread
// state at the fault, which together give the faulting address, the exact
// instruction, and the registers feeding it.
static void reportSignal(int number);

static void reportSignalDetailed(int number, siginfo_t *info, void *contextPointer)
{
    FILE *log = fopen("/tmp/native-death.log", "a");
    if (log) {
        fprintf(log, "signal %d code %d at %p\n", number, info ? info->si_code : 0,
            info ? info->si_addr : NULL);
        // The thread state, at its documented place in the context.
        //
        // On armv7 Darwin a ucontext_t is: onstack, sigmask, stack (three
        // words), link, mcsize, then the machine context pointer - so the
        // pointer is the eighth word. The machine context begins with the ARM
        // exception state (exception, fsr, far) and the thread state follows:
        // r0 through r12, sp, lr, pc, cpsr. Scanning for "something that looks
        // like a pointer" was tried first and picked the wrong word.
        if (contextPointer) {
            unsigned *context = (unsigned *)contextPointer;
            unsigned *machineContext = (unsigned *)context[7];
            if (machineContext && ((uintptr_t)machineContext & 3) == 0) {
                unsigned *exception = machineContext;
                unsigned *thread = machineContext + 3;
                fprintf(log, "  exception %08x fsr %08x far %08x\n",
                    exception[0], exception[1], exception[2]);
                fprintf(log, "  pc %08x lr %08x sp %08x cpsr %08x\n",
                    thread[15], thread[14], thread[13], thread[16]);
                for (int i = 0; i < 13; i++)
                    fprintf(log, "  r%-2d %08x\n", i, thread[i]);
            }
        }
        fclose(log);
    }
    reportSignal(number);
}

static void reportSignal(int number)
{
    FILE *log = fopen("/tmp/native-death.log", "a");
    if (log) {
        fprintf(log, "signal %d\n", number);
        void *frames[24];
        int count = backtrace(frames, 24);
        char **names = backtrace_symbols(frames, count);
        for (int i = 0; names && i < count; i++)
            fprintf(log, "  %s\n", names[i]);
        fclose(log);
    }
    _exit(128 + number);
}

static void reportExit(void)
{
    FILE *log = fopen("/tmp/native-death.log", "a");
    if (log) {
        fprintf(log, "clean exit\n");
        fclose(log);
    }
}


// Not stopping the interface to retile.
//
// Every main-thread freeze over 400 ms recorded on the device had one stack:
//
//   CALayer layoutBelowIfNeeded -> layoutSublayers -> UIView
//   layoutSublayersOfLayer: -> -[UIWebDocumentView layoutSubviews] ->
//   -[UIWebTiledView layoutSubviews] -> WebThreadLock -> parked
//
// That runs inside every CoreAnimation layout pass, so on every frame of a
// scroll, and it takes the web lock. While the engine is laying out a batch of
// newly arrived posts the main thread parks there and nothing moves - which is
// what a reader sees as the bars jumping and the page going dead under the
// finger.
//
// The retile is not urgent. Asked to run while the engine is busy, this defers
// it to the next frame instead, and the tiles stay one frame old. What is not
// acceptable is deferring it forever: a scroll that outruns the drawn tiles
// shows blank page, so after a few frames it waits like it used to. The
// engine's answer is a plain flag read, no lock involved.
static void (*originalTiledLayoutSubviews)(id, SEL);

static void tiledLayoutSubviews(id self, SEL selector)
{
    // Ask the engine for the lock; do not wait for it.
    //
    // -[UIWebTiledView layoutSubviews] runs inside every CoreAnimation layout
    // pass and takes the web lock unconditionally, so the interface waits for
    // whatever the engine is doing. With the lock-wait distribution recorded on
    // the device this was the largest remaining source of the tail: single waits
    // of 156 and 533 ms in one scroll, and it is the frame under which the
    // seconds-long ones appeared.
    //
    // An earlier version of this skipped the call outright for a fixed budget of
    // time, and that was wrong in a way the numbers hid: this method is also
    // where tiles for newly exposed page get made, so skipping it for two
    // seconds left the reader a white screen with the content sitting unpainted
    // behind it. Skipping only while the lock is actually held is a different
    // thing - the skip lasts exactly as long as the engine is busy, and the
    // engine invalidates the tiles when it finishes, which brings UIKit straight
    // back here.
    // Bounded, not unconditional. Skipping this also skips the compositing
    // flush, and that flush is what fills composited layers - the page's fixed
    // bars stayed empty while the engine had them in exactly the right place.
    // After a tenth of a second without a real pass, wait however long the
    // engine needs.
    // The engine-side tile layer already asks the web thread for the pass it is
    // owed; here it is enough never to wait.
    if (webThreadTryLockForFrame && !webThreadTryLockForFrame())
        return;
    originalTiledLayoutSubviews(self, selector);
}

static void deferTileLayoutWhileEngineIsBusy(void)
{
    webThreadIsBusy = (bool (*)(void))dlsym(RTLD_DEFAULT, "WebThreadIsBusy");
    webThreadTryLockForFrame = (bool (*)(void))dlsym(RTLD_DEFAULT, "WebThreadTryLockForFrame");
    mainThreadMustWaitForEngine = (bool (*)(void))dlsym(RTLD_DEFAULT, "_ZN7WebCore15LegacyTileCache27mainThreadMustWaitForEngineEv");
    if (!webThreadTryLockForFrame) {
        logLine(@"tile layout not deferred: the engine does not export WebThreadTryLockForFrame");
        return;
    }
    Class tiled = objc_getClass("UIWebTiledView");
    Method method = tiled ? class_getInstanceMethod(tiled, @selector(layoutSubviews)) : NULL;
    if (!method) {
        logLine(@"tile layout not deferred: no -[UIWebTiledView layoutSubviews]");
        return;
    }
    originalTiledLayoutSubviews = (void (*)(id, SEL))method_getImplementation(method);
    method_setImplementation(method, (IMP)tiledLayoutSubviews);
    logLine(@"tile layout skips a frame rather than waiting for the engine");
}

static void installDeathTraps(void)
{
    int signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE, SIGPIPE, SIGTERM };
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = reportSignalDetailed;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++)
        sigaction(signals[i], &action, NULL);
    atexit(reportExit);
}

// Sampling the thread that does the work.
//
// The main thread is idle during a scroll - eighty three percent of its samples
// were mach_msg_trap - so a profile of it says nothing. The engine runs on the
// web thread, and a stack rather than a bare program counter is what names the
// work: the counter alone lands in malloc or a CoreFoundation leaf and tells you
// nothing about which layout or paint asked for it.
static void *webThreadSampler(void *unused)
{
    (void)unused;
    if (access("/tmp/native-profile-web", F_OK) != 0)
        return NULL;

    FILE *log = fopen("/tmp/native-webprof.log", "w");
    if (!log)
        return NULL;
    setvbuf(log, NULL, _IOFBF, 65536);

    // The same stack walker, aimed at either thread. The main thread is where a
    // person feels the page, and a single program counter does not say whether
    // mach_msg_trap is a run loop with nothing to do or a wait for an answer
    // from the web thread - the stack above it does.
    bool sampleMainThread = access("/tmp/native-profile-mainstack", F_OK) == 0;
    thread_act_t webThread = MACH_PORT_NULL;
    while (webThread == MACH_PORT_NULL) {
        usleep(500000);
        if (sampleMainThread) {
            thread_act_array_t threads;
            mach_msg_type_number_t threadCount = 0;
            if (task_threads(mach_task_self(), &threads, &threadCount) == KERN_SUCCESS && threadCount > 0) {
                webThread = threads[0];
                vm_deallocate(mach_task_self(), (vm_address_t)threads, threadCount * sizeof(thread_act_t));
            }
        } else
            webThread = findWebThread();
    }

    // Only the passes that matter.
    //
    // A profile spread over a whole session mixes a five second render in with
    // minutes of idling and says nothing about either. The engine raises this
    // counter while it is inside a call from C++ into script, which is exactly
    // the window that freezes the interface, so sampling only while it is up
    // gives a profile of the freeze itself.
    volatile int *insideScript = (volatile int *)dlsym(RTLD_DEFAULT, "g_webkitIOS6InsideScript");
    fprintf(log, "web thread found, script counter %s\n", insideScript ? "available" : "MISSING");

    while (1) {
        usleep(20000);
        // While script is running, or - when the whole window is what is being
        // studied, as during a load - unconditionally.
        static int scopedToScript = -1;
        if (scopedToScript < 0)
            scopedToScript = access("/tmp/native-profile-scoped", F_OK) == 0 ? 1 : 0;
        if (scopedToScript && insideScript && !*insideScript)
            continue;
        if (thread_suspend(webThread) != KERN_SUCCESS)
            break;

        _STRUCT_ARM_THREAD_STATE state;
        mach_msg_type_number_t count = ARM_THREAD_STATE_COUNT;
        if (thread_get_state(webThread, ARM_THREAD_STATE, (thread_state_t)&state, &count) == KERN_SUCCESS) {
            uintptr_t frames[12];
            int depth = walkStack(webThread, frames, 12);
            thread_resume(webThread);

            // Addresses only. dladdr walks a symbol table on every frame of
            // every sample, and with it in the loop this sampler doubled the very
            // pauses it was measuring - eleven seconds became five with it off.
            // The addresses resolve offline against dist/unstripped using the
            // image bases the application logs at launch.
            for (int i = 0; i < depth; i++)
                fprintf(log, "%s%p", i ? ";" : "", (void *)frames[i]);
            fprintf(log, "\n");
        } else
            thread_resume(webThread);
    }
    fclose(log);
    return NULL;
}

static int profileFileDescriptor = -1;

static void *sampler(void *unused)
{
    (void)unused;
    profileFileDescriptor = open("/tmp/native-prof.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    char header[4096];
    int used = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name)
            continue;
        if (!strstr(name, "WebCore") && !strstr(name, "JavaScriptCore") && !strstr(name, "WebKit") && !strstr(name, "NativeUI"))
            continue;
        used += snprintf(header + used, sizeof(header) - used, "image %p %s\n", _dyld_get_image_header(i), name);
        if (used > (int)sizeof(header) - 200)
            break;
    }
    if (profileFileDescriptor >= 0 && used > 0)
        write(profileFileDescriptor, header, used);

    mach_port_t self = pthread_mach_thread_np(pthread_self());
    while (1) {
        usleep(50000);
        // Recording is on from launch: the session that matters is the one a
        // person has in their hands, and it cannot be asked to wait for a
        // switch to be flipped. One suspend and one register read every fifty
        // milliseconds costs a fraction of a percent.
        if (access("/tmp/native-profile-off", F_OK) == 0)
            continue;
        thread_act_array_t threads;
        mach_msg_type_number_t threadCount = 0;
        if (task_threads(mach_task_self(), &threads, &threadCount) != KERN_SUCCESS)
            continue;
        mach_port_t busiest = MACH_PORT_NULL;
        int busiestUsage = -1;
        for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
            if (threads[i] == self)
                continue;
            struct thread_basic_info basic;
            mach_msg_type_number_t basicCount = THREAD_BASIC_INFO_COUNT;
            if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&basic, &basicCount) != KERN_SUCCESS)
                continue;
            if (basic.cpu_usage > busiestUsage) {
                busiestUsage = basic.cpu_usage;
                busiest = threads[i];
            }
        }
        // The main thread is the one the user feels; sample it by name rather
        // than by whoever burns the most CPU, because a blocked thread burns
        // none and is exactly what needs catching.
        if (!access("/tmp/native-profile-main", F_OK) && threadCount > 0)
            busiest = threads[0];

        if (busiest != MACH_PORT_NULL && thread_suspend(busiest) == KERN_SUCCESS) {
            _STRUCT_ARM_THREAD_STATE state;
            mach_msg_type_number_t stateCount = ARM_THREAD_STATE_COUNT;
            kern_return_t got = thread_get_state(busiest, ARM_THREAD_STATE, (thread_state_t)&state, &stateCount);
            thread_resume(busiest);
            if (got == KERN_SUCCESS && profileFileDescriptor >= 0) {
                char line[512];
                Dl_info info;
                int n;
                if (dladdr((void *)state.__pc, &info) && info.dli_sname) {
                    n = snprintf(line, sizeof(line), "sym %s +%u\n", info.dli_sname,
                        (unsigned)((uintptr_t)state.__pc - (uintptr_t)info.dli_saddr));
                } else {
                    Dl_info caller;
                    if (dladdr((void *)state.__lr, &caller) && caller.dli_sname)
                        n = snprintf(line, sizeof(line), "sym (unnamed via %s)\n", caller.dli_sname);
                    else
                        n = snprintf(line, sizeof(line), "pc %08x\n", (unsigned)state.__pc);
                }
                write(profileFileDescriptor, line, n);
            }
        }
        vm_deallocate(mach_task_self(), (vm_address_t)threads, threadCount * sizeof(thread_act_t));
    }
    return NULL;
}

// What the process is actually holding, by the kernel's own label.
//
// The previous version of this guessed: any readable-writable region over a
// megabyte was called "graphics/tiles". That put every large malloc block in the
// same bucket as CoreAnimation and reported 92 MB of tiles on a 320x460 screen -
// a number that sent the search in the wrong direction. Every region carries a
// user tag saying which allocator asked for it, so it can be asked instead of
// guessed.
static const char *nameForMemoryTag(unsigned tag)
{
    switch (tag) {
    case 1: return "malloc default";
    case 2: return "malloc small";
    case 3: return "malloc large";
    case 4: return "malloc huge";
    case 6: return "malloc realloc";
    case 7: return "malloc tiny";
    case 8: case 9: return "malloc large reusable";
    case 11: return "analysis";
    case 20: return "IOKit";
    case 30: return "thread stacks";
    case 33: return "dylib data";
    case 40: case 41: return "Foundation";
    case 42: return "CoreGraphics";
    case 50: return "fonts";
    case 51: return "CoreAnimation layers";
    case 52: return "decoded images";
    case 54: return "CoreGraphics data";
    case 55: return "CoreGraphics shared";
    case 56: return "framebuffers";
    case 57: return "layer backing stores";
    case 60: case 61: return "dyld";
    case 63: return "sqlite";
    case 64: return "JavaScriptCore heap";
    case 65: return "JIT code";
    case 66: return "JIT register file";
    case 74: return "ImageIO";
    case 0: return "untagged";
    default: return NULL;
    }
}

static void reportMemoryRegions(FILE *log)
{
    vm_address_t address = 0;
    natural_t depth = 0;

    enum { kTagLimit = 80 };
    uint64_t residentByTag[kTagLimit] = {0};
    unsigned regionsByTag[kTagLimit] = {0};
    uint64_t residentOther = 0, residentMapped = 0;

    while (1) {
        vm_size_t size = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &address, &size, &depth,
                (vm_region_recurse_info_t)&info, &count) != KERN_SUCCESS)
            break;
        if (info.is_submap) {
            depth++;
            continue;
        }
        uint64_t resident = (uint64_t)info.pages_resident * vm_page_size;
        // Anything backed by a file on disk is the frameworks and the shared
        // cache; it is not what grows while a feed is read.
        if (info.share_mode == SM_TRUESHARED || info.external_pager)
            residentMapped += resident;
        else if (info.user_tag < kTagLimit) {
            residentByTag[info.user_tag] += resident;
            regionsByTag[info.user_tag]++;
        } else
            residentOther += resident;
        address += size;
    }

    fprintf(log, "    memory: file-backed %.1f MB;", residentMapped / 1048576.0);
    for (unsigned tag = 0; tag < kTagLimit; tag++) {
        if (residentByTag[tag] < 1048576)
            continue;
        const char *name = nameForMemoryTag(tag);
        if (name)
            fprintf(log, " %s %.1f MB (%u);", name, residentByTag[tag] / 1048576.0, regionsByTag[tag]);
        else
            fprintf(log, " tag %u %.1f MB (%u);", tag, residentByTag[tag] / 1048576.0, regionsByTag[tag]);
    }
    if (residentOther >= 1048576)
        fprintf(log, " other %.1f MB;", residentOther / 1048576.0);
    fprintf(log, "\n");
}

static void *heartbeat(void *unused)
{
    FILE *log = fopen("/tmp/native-pulse.log", "w");
    if (!log)
        return NULL;
    setvbuf(log, NULL, _IONBF, 0);
    fprintf(log, "pulse thread started\n");
    for (int second = 1; ; second++) {
        sleep(1);
        if (second % 10)
            continue;
        struct mach_task_basic_info info;
        mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
        if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
            fprintf(log, "alive %d s, resident %.1f MB, peak %.1f MB\n", second,
                info.resident_size / 1048576.0, info.resident_size_max / 1048576.0);

            // The kill arrives at about 175 MB resident with no warning the
            // process can catch, so the only working defence is to not be
            // there. The engine's own low-memory hook fires when the tile code
            // happens to poll; this one fires on the process's actual size.
            // Two levels, because the strong one is destructive: it deletes
            // every compiled script, the font caches and the style resolver.
            // Running it on a short timer kept the engine regenerating bytecode
            // under the web lock and held the interface near one frame per
            // second. So the routine answer is a collection and the cheap
            // caches, and the strong one waits until the kill is actually near.
            double residentMB = info.resident_size / 1048576.0;
            static double lastSqueeze;
            static double lastHardSqueeze;
            double now = CFAbsoluteTimeGetCurrent();
            if (residentMB > 162 && now - lastHardSqueeze > 60) {
                lastHardSqueeze = now;
                lastSqueeze = now;
                fprintf(log, "    resident %.1f MB - full release\n", residentMB);
                dispatch_async(dispatch_get_main_queue(), ^{
                    Class webViewClass = NSClassFromString(@"WebView");
                    if ([webViewClass respondsToSelector:@selector(_releaseMemoryNow)])
                        [webViewClass performSelector:@selector(_releaseMemoryNow)];
                });
            }

            // A standing cap on decoded images, not a response to pressure.
            // They are the largest block in the process and they only ever grow
            // on a feed that never removes a post, so waiting for pressure means
            // waiting for the kill.
            // Ask the engine what it is actually holding, every twenty seconds.
            static double lastBreakdown;
            if (now - lastBreakdown > 20) {
                lastBreakdown = now;
                dispatch_async(dispatch_get_main_queue(), ^{
                    Class webViewClass = NSClassFromString(@"WebView");
                    if ([webViewClass respondsToSelector:@selector(_reportMemoryBreakdown)])
                        [webViewClass performSelector:@selector(_reportMemoryBreakdown)];
                });
            }

            // No cap on decoded images.
            //
            // This used to prune live resources to six megabytes every six
            // seconds above a hundred, on the belief that decoded image data was
            // the largest block in the process. The engine's own count says
            // otherwise: 1.6 MB in 24 images, while the JavaScript heap was
            // 41 MB and climbing. So the prune was pruning nothing, six times a
            // minute, on the web thread, holding the web lock that UIKit needs on
            // every frame - and undecoding pictures the next paint decodes again.
            //
            // The belief came from the application's own region walk, which
            // called every large writable region "graphics/tiles" and reported
            // 92 MB of them. Asked for the kernel's tags instead, the process has
            // no CoreAnimation backing stores worth naming: it has 87 MB of large
            // malloc blocks.

            if (residentMB > 148 && now - lastSqueeze > 20) {
                lastSqueeze = now;
                fprintf(log, "    resident %.1f MB - gentle release\n", residentMB);
                dispatch_async(dispatch_get_main_queue(), ^{
                    Class webViewClass = NSClassFromString(@"WebView");
                    if ([webViewClass respondsToSelector:@selector(_relieveMemoryPressure)])
                        [webViewClass performSelector:@selector(_relieveMemoryPressure)];
                    else if ([webViewClass respondsToSelector:@selector(garbageCollectNow)])
                        [webViewClass performSelector:@selector(garbageCollectNow)];
                });
            }
        } else
            fprintf(log, "alive %d s\n", second);

        if (!(second % 20))
            reportMemoryRegions(log);

        thread_act_array_t threads;
        mach_msg_type_number_t threadCount = 0;
        if (task_threads(mach_task_self(), &threads, &threadCount) == KERN_SUCCESS) {
            for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
                struct thread_basic_info basic;
                mach_msg_type_number_t basicCount = THREAD_BASIC_INFO_COUNT;
                if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&basic, &basicCount) != KERN_SUCCESS)
                    continue;
                if (basic.cpu_usage < TH_USAGE_SCALE / 20)
                    continue;
                struct thread_identifier_info ident;
                mach_msg_type_number_t identCount = THREAD_IDENTIFIER_INFO_COUNT;
                uint64_t handle = 0;
                if (thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ident, &identCount) == KERN_SUCCESS)
                    handle = ident.thread_handle;
                fprintf(log, "    thread %u handle %llx cpu %.0f%% state %d user %us sys %us\n", i, handle,
                    100.0 * basic.cpu_usage / TH_USAGE_SCALE, basic.run_state,
                    basic.user_time.seconds, basic.system_time.seconds);
            }
            vm_deallocate(mach_task_self(), (vm_address_t)threads, threadCount * sizeof(thread_act_t));
        }
    }
    fclose(log);
    return NULL;
}

int NativeAppMain(int argc, char *argv[])
{
    pthread_t pulse;
    pthread_create(&pulse, NULL, heartbeat, NULL);
    pthread_detach(pulse);

    pthread_t profiler;
    pthread_create(&profiler, NULL, sampler, NULL);
    pthread_t webProfiler;
    pthread_create(&webProfiler, NULL, webThreadSampler, NULL);
    pthread_detach(profiler);

    pthread_t watchdog;
    pthread_create(&watchdog, NULL, mainThreadWatchdog, NULL);
    pthread_detach(watchdog);

    installDeathTraps();
    deferTileLayoutWhileEngineIsBusy();
    freopen("/tmp/native-stderr.log", "w", stderr);
    setvbuf(stderr, NULL, _IONBF, 0);
    logLine(@"entering UIApplicationMain");
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"NativeAppDelegate");
    }
}
