/*
 * Classes WebKit references that iOS 6 does not have. dyld binds these at load
 * time, so they must be real classes rather than something registered later.
 * They carry no behaviour; reaching one means a code path needs guarding.
 */
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#import <stdio.h>

@interface CABackdropLayer : CALayer
@end

@interface LSAppLink : NSObject
@end

@interface LSBundleProxy : NSObject
@end

@interface NSPresentationIntent : NSObject
@end

@interface _LSOpenConfiguration : NSObject
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wobjc-property-implementation"

@implementation NSDateComponentsFormatter
+ (id)alloc
{
    static BOOL said_NSDateComponentsFormatter; if (!said_NSDateComponentsFormatter) { said_NSDateComponentsFormatter = YES; fprintf(stderr, "[ios6] class unavailable: NSDateComponentsFormatter\n"); }
    return [super alloc];
}

/* The unitsStyle/allowedUnits/formattingContext/maximumUnitCount properties
 * work - they're auto-synthesized from Foundation.h's real @interface, which
 * this file has no @interface of its own to override. This method is not a
 * property, so nothing synthesizes it: WebKit's media accessibility duration
 * text (RenderThemeCocoa.mm) sets those properties and then calls this, gets
 * an unrecognized-selector exception, and that killed the process on real
 * playback/scroll - "WebKit discarding exception" only catches what the
 * BEGIN_BLOCK_OBJC_EXCEPTIONS wrapper is still inside when it throws, not
 * whatever runs after. Largest-unit-first, up to maximumUnitCount units,
 * matching the "full" style's word form since that's the only style this
 * engine's one caller asks for. */
- (NSString *)stringFromTimeInterval:(NSTimeInterval)interval
{
    if (!(interval >= 0))
        interval = 0;
    long long total = (long long)(interval + 0.5);
    long long hours = total / 3600;
    long long minutes = (total % 3600) / 60;
    long long seconds = total % 60;

    NSCalendarUnit allowed = self.allowedUnits;
    if (!allowed)
        allowed = NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond;
    NSInteger maxUnits = self.maximumUnitCount;
    if (maxUnits <= 0)
        maxUnits = 3;

    NSMutableArray *parts = [NSMutableArray array];
    if ((allowed & NSCalendarUnitHour) && hours)
        [parts addObject:[NSString stringWithFormat:@"%lld %@", hours, hours == 1 ? @"hour" : @"hours"]];
    if ((allowed & NSCalendarUnitMinute) && (minutes || (parts.count == 0 && !(allowed & NSCalendarUnitSecond))))
        [parts addObject:[NSString stringWithFormat:@"%lld %@", minutes, minutes == 1 ? @"minute" : @"minutes"]];
    if ((allowed & NSCalendarUnitSecond) && (seconds || parts.count == 0))
        [parts addObject:[NSString stringWithFormat:@"%lld %@", seconds, seconds == 1 ? @"second" : @"seconds"]];

    while ((NSInteger)parts.count > maxUnits)
        [parts removeLastObject];
    return [parts componentsJoinedByString:@", "];
}
@end

@implementation NSItemProvider
+ (id)alloc
{
    static BOOL said_NSItemProvider; if (!said_NSItemProvider) { said_NSItemProvider = YES; fprintf(stderr, "[ios6] class unavailable: NSItemProvider\n"); }
    return [super alloc];
}
@end

@implementation NSURLSession
+ (id)alloc
{
    static BOOL said_NSURLSession; if (!said_NSURLSession) { said_NSURLSession = YES; fprintf(stderr, "[ios6] class unavailable: NSURLSession\n"); }
    return [super alloc];
}
@end

@implementation CABackdropLayer
+ (id)alloc
{
    static BOOL said_CABackdropLayer; if (!said_CABackdropLayer) { said_CABackdropLayer = YES; fprintf(stderr, "[ios6] class unavailable: CABackdropLayer\n"); }
    return [super alloc];
}
@end

@implementation LSAppLink
+ (id)alloc
{
    static BOOL said_LSAppLink; if (!said_LSAppLink) { said_LSAppLink = YES; fprintf(stderr, "[ios6] class unavailable: LSAppLink\n"); }
    return [super alloc];
}

/* WebFrameLoaderClient.mm calls this class method directly - no +alloc
 * involved, so the log-once above never fires for it - whenever WebKit
 * treats a navigation as an app-link candidate (an outbound link that
 * looks like it could open a native app instead). No app-link resolver
 * actually exists on this system to ask, so the honest answer is always
 * "no", which is exactly what makes the caller fall through to opening the
 * link in this browser itself - not a crash from an unimplemented class
 * method. */
+ (void)openWithURL:(NSURL *)url configuration:(id)configuration completionHandler:(void (^)(BOOL success, NSError *error))completionHandler
{
    static BOOL said_LSAppLink_open; if (!said_LSAppLink_open) { said_LSAppLink_open = YES; fprintf(stderr, "[ios6] class unavailable: LSAppLink openWithURL:\n"); }
    (void)url; (void)configuration;
    if (completionHandler)
        completionHandler(NO, nil);
}
@end

@implementation LSBundleProxy
+ (id)alloc
{
    static BOOL said_LSBundleProxy; if (!said_LSBundleProxy) { said_LSBundleProxy = YES; fprintf(stderr, "[ios6] class unavailable: LSBundleProxy\n"); }
    return [super alloc];
}
@end

@implementation NSPresentationIntent
+ (id)alloc
{
    static BOOL said_NSPresentationIntent; if (!said_NSPresentationIntent) { said_NSPresentationIntent = YES; fprintf(stderr, "[ios6] class unavailable: NSPresentationIntent\n"); }
    return [super alloc];
}
@end

@implementation _LSOpenConfiguration
+ (id)alloc
{
    fprintf(stderr, "[ios6] class unavailable: _LSOpenConfiguration\n");
    return [super alloc];
}
@end

#pragma clang diagnostic pop

/* Power and thermal state arrived in iOS 9. A device this old has neither, and
 * WebKit only uses them to throttle itself. */
@interface NSProcessInfo (WebKitIOS6Power)
@end

@implementation NSProcessInfo (WebKitIOS6Power)
- (BOOL)isLowPowerModeEnabled { return NO; }
- (NSInteger)thermalState { return 0; /* NSProcessInfoThermalStateNominal */ }
@end

/*
 * UITraitCollection is iOS 8. WebCore soft-links it and traps when it is
 * missing, so the class has to exist; it only ever stores and returns the
 * current collection, which on a system with no traits is nil.
 */
@implementation UITraitCollection

static UITraitCollection *webKitIOS6CurrentTraitCollection;

+ (UITraitCollection *)currentTraitCollection
{
    return webKitIOS6CurrentTraitCollection;
}

+ (void)setCurrentTraitCollection:(UITraitCollection *)collection
{
    if (webKitIOS6CurrentTraitCollection == collection)
        return;
    [webKitIOS6CurrentTraitCollection release];
    webKitIOS6CurrentTraitCollection = [collection retain];
}

@end

/*
 * +[CATransaction addCommitHandler:forPhase:] is iOS 9. WebKit registers two
 * handlers around each rendering update: one before layout and one after the
 * commit. Both callers run from a run-loop observer immediately before the
 * commit, so running the pre-layout block now is the same moment; the
 * post-commit block maps onto the completion block CoreAnimation has always had.
 */
@interface CATransaction (WebKitIOS6CommitHandlers)
@end

@implementation CATransaction (WebKitIOS6CommitHandlers)

+ (void)addCommitHandler:(void (^)(void))block forPhase:(unsigned)phase
{
    if (!block)
        return;
    if (phase == 2 /* kCATransactionPhasePostCommit */) {
        // Back to the thread that registered it, never to the main queue.
        //
        // The engine registers this from the web thread, at the end of its own
        // rendering update. Hopping to the main queue put the post-commit work
        // on the main thread without the web lock its callers assume - and worse,
        // that work calls schedulePostRenderingUpdate(), which binds a repeating
        // run loop observer to whatever run loop it finds and never rebinds it.
        // Bound to the main run loop, in the common modes, its body begins with
        // WebThreadLock(): the main thread was taking the web lock on every turn
        // of its own run loop, for the life of the process, including inside a
        // scroll. That is the freeze - taps ignored, no frames, the web thread
        // holding the lock in a script handler while the interface queued up
        // behind it.
        //
        // On the web thread the same observer binds to the web run loop, where
        // WebThreadLock() is a recursive no-op.
        void (^copied)(void) = [block copy];
        void (*runOnWebThread)(void (^)(void)) = (void (*)(void (^)(void)))dlsym(RTLD_DEFAULT, "WebThreadRun");
        if (runOnWebThread) {
            runOnWebThread(^{
                copied();
                [copied release];
            });
        } else {
            copied();
            [copied release];
        }
        return;
    }
    block();
}

@end

/*
 * -[CADisplayLink setPreferredFramesPerSecond:] is iOS 10. The same thing is
 * expressed here as a frame interval: how many display refreshes to skip.
 */
@interface CADisplayLink (WebKitIOS6FrameRate)
@end

@implementation CADisplayLink (WebKitIOS6FrameRate)

- (NSInteger)preferredFramesPerSecond
{
    NSInteger interval = [self frameInterval];
    return interval > 0 ? 60 / interval : 60;
}

- (void)setPreferredFramesPerSecond:(NSInteger)framesPerSecond
{
    [self setFrameInterval:framesPerSecond > 0 ? MAX(1, 60 / framesPerSecond) : 1];
}

@end
