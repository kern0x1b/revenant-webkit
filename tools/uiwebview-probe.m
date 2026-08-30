#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdio.h>

static void note(const char *what)
{
    printf("%s\n", what);
    fflush(stdout);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        note("start");
        Class webView = NSClassFromString(@"WebView");
        printf("WebView class: %p (%s)\n", (void *)webView,
               webView ? class_getName(webView) : "absent");

        note("about to create UIWebView");
        UIWebView *view = [[UIWebView alloc] initWithFrame:CGRectMake(0, 0, 320, 480)];
        printf("UIWebView: %p\n", view);

        [view loadHTMLString:@"<html><body><p id='t'>hello from the engine</p></body></html>" baseURL:nil];

        for (int i = 0; i < 40; i++)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

        NSString *text = [view stringByEvaluatingJavaScriptFromString:@"document.getElementById('t').innerText"];
        printf("text: %s\n", text.length ? [text UTF8String] : "(empty)");

        NSString *engine = [view stringByEvaluatingJavaScriptFromString:@"navigator.userAgent"];
        printf("user agent: %s\n", engine.length ? [engine UTF8String] : "(empty)");
    }
    return 0;
}
