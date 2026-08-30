#import "WebAppBytecodeCache.h"

#import "WebAppManifest.h"

#import <WebKitLegacy/WebView.h>
#import <WebKitLegacy/WebViewPrivate.h>
#import <stdio.h>
#import <stdlib.h>

static NSString * const WebAppBytecodeCacheDisableFile = @"/tmp/no-bytecode-cache";
static NSString * const WebAppBytecodeCacheDirectoryName = @"JSCBytecode";
static const unsigned long long WebAppBytecodeCacheDefaultMaximumSize = 96ULL * 1024 * 1024;

@implementation WebAppBytecodeCache

+ (BOOL)isEnabled
{
    const char *setting = getenv("BROWSER_BYTECODE_CACHE");
    if (setting && setting[0])
        return setting[0] != '0';

    return ![[NSFileManager defaultManager] fileExistsAtPath:WebAppBytecodeCacheDisableFile];
}

+ (NSString *)directory
{
    return [[WebAppManifest storageDirectory] stringByAppendingPathComponent:WebAppBytecodeCacheDirectoryName];
}

+ (unsigned long long)maximumSize
{
    const char *setting = getenv("BROWSER_BYTECODE_CACHE_MB");
    if (setting && setting[0]) {
        unsigned long long megabytes = strtoull(setting, NULL, 10);
        if (megabytes)
            return megabytes * 1024 * 1024;
    }
    return WebAppBytecodeCacheDefaultMaximumSize;
}

+ (void)install
{
    if (![self isEnabled]) {
        fprintf(stderr, "BYTECODE off\n");
        return;
    }

    [WebView _setJavaScriptBytecodeCacheDirectory:[self directory] maximumSize:[self maximumSize]];
}

+ (void)flush
{
    if (![self isEnabled])
        return;

    [WebView _flushJavaScriptBytecodeCache];
}

+ (void)flushAfterDelay
{
    if (![self isEnabled])
        return;

    [self performSelector:@selector(flush) withObject:nil afterDelay:8.0];
}

+ (void)cancelDelayedFlush
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flush) object:nil];
}

+ (void)clear
{
    [WebView _clearJavaScriptBytecodeCache];
}

@end
