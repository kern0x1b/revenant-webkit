#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void logLine(NSString *line)
{
    FILE *f = fopen("/tmp/touch-probe.log", "a");
    if (f) {
        fprintf(f, "%s\n", [line UTF8String]);
        fclose(f);
    }
}

__attribute__((constructor))
static void probeTouch(void)
{
    logLine(@"=== probe-touch entered ===");

    UIWindow *window = [[UIApplication sharedApplication] keyWindow];
    logLine([NSString stringWithFormat:@"keyWindow=%@ userInteractionEnabled=%d", window, window.userInteractionEnabled]);

    id controller = [window rootViewController];
    logLine([NSString stringWithFormat:@"rootViewController=%@", controller]);

    UIView *root = [controller view];
    logLine([NSString stringWithFormat:@"root view=%@ frame=%@ userInteractionEnabled=%d", root, NSStringFromCGRect(root.frame), root.userInteractionEnabled]);

    Ivar scrollViewIvar = class_getInstanceVariable([controller class], "_scrollView");
    if (scrollViewIvar) {
        UIScrollView *scrollView = object_getIvar(controller, scrollViewIvar);
        logLine([NSString stringWithFormat:@"_scrollView=%@ frame=%@ bounds=%@ userInteractionEnabled=%d hidden=%d alpha=%f",
            scrollView, NSStringFromCGRect(scrollView.frame), NSStringFromCGRect(scrollView.bounds),
            scrollView.userInteractionEnabled, scrollView.hidden, scrollView.alpha]);
        logLine([NSString stringWithFormat:@"scrollEnabled=%d canCancelContentTouches=%d delaysContentTouches=%d",
            scrollView.scrollEnabled, scrollView.canCancelContentTouches, scrollView.delaysContentTouches]);
        for (UIGestureRecognizer *gr in scrollView.gestureRecognizers)
            logLine([NSString stringWithFormat:@"  gr on scrollView: %@ enabled=%d", gr, gr.enabled]);
    } else {
        logLine(@"_scrollView ivar not found");
    }

    logLine([NSString stringWithFormat:@"root subviews: %@", root.subviews]);
    for (UIView *sub in root.subviews) {
        logLine([NSString stringWithFormat:@"  subview=%@ frame=%@ hidden=%d alpha=%f userInteractionEnabled=%d",
            sub, NSStringFromCGRect(sub.frame), sub.hidden, sub.alpha, sub.userInteractionEnabled]);
    }

    for (UIGestureRecognizer *gr in root.gestureRecognizers)
        logLine([NSString stringWithFormat:@"gr on root: %@ enabled=%d", gr, gr.enabled]);

    CGPoint testPoint = CGPointMake(190, 400);
    UIView *hit = [window hitTest:testPoint withEvent:nil];
    logLine([NSString stringWithFormat:@"hitTest at %@ => %@", NSStringFromCGPoint(testPoint), hit]);

    logLine(@"=== done ===");
}
