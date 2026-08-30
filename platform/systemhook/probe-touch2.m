#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void logLine(NSString *line)
{
    FILE *f = fopen("/tmp/touch-probe2.log", "a");
    if (f) {
        fprintf(f, "%s\n", [line UTF8String]);
        fclose(f);
    }
}

__attribute__((constructor))
static void probeTouch2(void)
{
    logLine(@"=== probe-touch2 entered ===");

    UIScreen *screen = [UIScreen mainScreen];
    logLine([NSString stringWithFormat:@"UIScreen.scale=%f bounds=%@ applicationFrame=%@",
        screen.scale, NSStringFromCGRect(screen.bounds), NSStringFromCGRect(screen.applicationFrame)]);

    UIApplication *app = [UIApplication sharedApplication];
    logLine([NSString stringWithFormat:@"applicationState=%ld windows=%@", (long)app.applicationState, app.windows]);

    UIWindow *window = app.keyWindow;
    id controller = [window rootViewController];
    UIView *root = [controller view];
    Ivar scrollViewIvar = class_getInstanceVariable([controller class], "_scrollView");
    UIView *scrollView = scrollViewIvar ? object_getIvar(controller, scrollViewIvar) : nil;

    logLine([NSString stringWithFormat:@"window.isKeyWindow=%d window.hidden=%d window.alpha=%f", window.isKeyWindow, window.hidden, window.alpha]);

    UIResponder *r = scrollView;
    int depth = 0;
    while (r && depth < 10) {
        logLine([NSString stringWithFormat:@"chain[%d] = %@ (respondsToTouchesBegan=%d)", depth, r,
            [r respondsToSelector:@selector(touchesBegan:withEvent:)]]);
        r = [r nextResponder];
        depth++;
    }

    logLine([NSString stringWithFormat:@"controller respondsToTouchesBegan=%d",
        [controller respondsToSelector:@selector(touchesBegan:withEvent:)]]);

    Method m = class_getInstanceMethod([controller class], @selector(touchesBegan:withEvent:));
    logLine([NSString stringWithFormat:@"touchesBegan: IMP=%p defining class=%@", method_getImplementation(m), NSStringFromClass([controller class])]);

    logLine(@"=== done ===");
}
