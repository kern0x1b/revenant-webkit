#import "WebAppContentBlocker.h"

#import <WebKitLegacy/WebView.h>
#import <WebKitLegacy/WebViewPrivate.h>
#import <stdio.h>
#import <stdlib.h>

static NSString * const WebAppContentBlockerListName = @"legacy-blocklist";
static NSString * const WebAppContentBlockerDisableFile = @"/tmp/no-content-blocker";

@implementation WebAppContentBlocker

+ (BOOL)isEnabled
{
    const char *setting = getenv("BROWSER_CONTENT_BLOCKER");
    if (setting && setting[0])
        return setting[0] != '0';

    return ![[NSFileManager defaultManager] fileExistsAtPath:WebAppContentBlockerDisableFile];
}

+ (void)installInWebView:(WebView *)webView
{
    if (![self isEnabled]) {
        fprintf(stderr, "CONTENTBLOCK off\n");
        return;
    }

    NSString *path = [[NSBundle mainBundle] pathForResource:@"blockrules" ofType:@"json"];
    NSString *rules = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
    if (![rules length]) {
        fprintf(stderr, "CONTENTBLOCK no rule list in bundle\n");
        return;
    }

    NSUInteger count = [[rules componentsSeparatedByString:@"url-filter"] count] - 1;
    NSDate *started = [NSDate date];
    BOOL installed = [webView _addContentRuleList:rules name:WebAppContentBlockerListName];
    fprintf(stderr, "CONTENTBLOCK %s %lu rules in %.0f ms\n", installed ? "installed" : "REJECTED",
        (unsigned long)count, -[started timeIntervalSinceNow] * 1000.0);
}

+ (void)removeFromWebView:(WebView *)webView
{
    [webView _removeContentRuleListNamed:WebAppContentBlockerListName];
    fprintf(stderr, "CONTENTBLOCK removed\n");
}

@end
