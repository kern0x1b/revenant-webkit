// A disk cache for the site's immutable bundles.
//
// iOS 6 will not put an HTTPS response on disk, so every launch downloads the
// same megabytes of framework JavaScript again - measured at 18.5 of the 22
// seconds it takes to reach a usable feed. The bundle URLs are content-hashed
// (rsrc.php/...), so a byte once fetched is valid forever; this protocol serves
// those bytes from disk and fetches them once.
//
// Only GET requests to the static CDN are touched. HTML, feeds, images and
// anything with credentials pass through untouched.

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *cacheRoot(void)
{
    static NSString *root;
    if (!root) {
        NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
        root = [[caches stringByAppendingPathComponent:@"static-assets"] retain];
        [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    return root;
}

static NSString *cachePathForURL(NSURL *url)
{
    const char *bytes = [[url absoluteString] UTF8String];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(bytes, (CC_LONG)strlen(bytes), digest);
    NSMutableString *name = [NSMutableString stringWithCapacity:2 * CC_SHA1_DIGEST_LENGTH];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++)
        [name appendFormat:@"%02x", digest[i]];
    return [cacheRoot() stringByAppendingPathComponent:name];
}

@interface StaticAssetCacheProtocol : NSURLProtocol {
    NSURLConnection *_connection;
    NSFileHandle *_sink;
    NSString *_sinkPath;
    NSHTTPURLResponse *_response;
}
@end

@implementation StaticAssetCacheProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    if (![[[request HTTPMethod] uppercaseString] isEqualToString:@"GET"])
        return NO;
    NSURL *url = [request URL];
    if (![[url scheme] isEqualToString:@"https"])
        return NO;
    if (![[url host] isEqualToString:@"static.cdninstagram.com"])
        return NO;

    // Only the content-hashed bundle path, and only code and style. Everything
    // else on this host is allowed to be dynamic - caching one such response
    // stalled hydration with no error to show for it.
    NSString *path = [url path];
    if ([path rangeOfString:@"/rsrc.php/"].location == NSNotFound)
        return NO;
    if (![path hasSuffix:@".js"] && ![path hasSuffix:@".css"])
        return NO;
    if ([NSURLProtocol propertyForKey:@"StaticAssetCachePassThrough" inRequest:request])
        return NO;
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}

- (void)startLoading
{
    NSString *path = cachePathForURL([[self request] URL]);
    NSData *cached = [NSData dataWithContentsOfFile:path];
    if (cached.length) {
        // Delivered on the next turn of the run loop: answering inside
        // startLoading re-enters the loader from its own call, which is the
        // kind of surprise that stalls it with nothing in the console.
        [self performSelector:@selector(deliverFromDisk:) withObject:cached afterDelay:0];
        return;
    }

    NSMutableURLRequest *passThrough = [[[self request] mutableCopy] autorelease];
    [NSURLProtocol setProperty:[NSNumber numberWithBool:YES] forKey:@"StaticAssetCachePassThrough" inRequest:passThrough];

    // Streamed to a temporary file rather than held in memory: half a dozen of
    // these run at once during a load, and megabytes of buffered bundle on a
    // device this size is exactly the peak that gets the process killed.
    _sinkPath = [[path stringByAppendingString:@".partial"] retain];
    [[NSFileManager defaultManager] createFileAtPath:_sinkPath contents:nil attributes:nil];
    _sink = [[NSFileHandle fileHandleForWritingAtPath:_sinkPath] retain];

    _connection = [[NSURLConnection alloc] initWithRequest:passThrough delegate:self];
}

- (void)deliverFromDisk:(NSData *)cached
{
    NSString *path = cachePathForURL([[self request] URL]);
    NSString *contentType = [NSString stringWithContentsOfFile:[path stringByAppendingString:@".type"]
                                                      encoding:NSUTF8StringEncoding error:NULL]
        ?: @"application/octet-stream";
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:[[self request] URL] statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:[NSDictionary dictionaryWithObjectsAndKeys:
            contentType, @"Content-Type",
            [NSString stringWithFormat:@"%lu", (unsigned long)cached.length], @"Content-Length",
            @"max-age=31536000", @"Cache-Control",
            // The bundles are loaded with crossorigin: without this header the
            // engine discards the response after fetching it, silently, and
            // hydration waits forever on a script that will never run.
            @"*", @"Access-Control-Allow-Origin",
            @"*", @"Timing-Allow-Origin", nil]];
    [[self client] URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [[self client] URLProtocol:self didLoadData:cached];
    [[self client] URLProtocolDidFinishLoading:self];
    [response release];
}

- (void)stopLoading
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_connection cancel];
    [_connection release];
    _connection = nil;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    if ([response isKindOfClass:[NSHTTPURLResponse class]])
        _response = (NSHTTPURLResponse *)[response retain];
    [[self client] URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    @try { [_sink writeData:data]; } @catch (NSException *e) { [_sink release]; _sink = nil; }
    [[self client] URLProtocol:self didLoadData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    [_sink closeFile];
    if (_response.statusCode == 200 && _sinkPath) {
        NSString *path = cachePathForURL([[self request] URL]);
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        if ([[NSFileManager defaultManager] moveItemAtPath:_sinkPath toPath:path error:NULL]) {
            NSString *contentType = [[_response allHeaderFields] objectForKey:@"Content-Type"];
            if (contentType)
                [contentType writeToFile:[path stringByAppendingString:@".type"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
    } else if (_sinkPath)
        [[NSFileManager defaultManager] removeItemAtPath:_sinkPath error:NULL];
    [[self client] URLProtocolDidFinishLoading:self];
    [_sink release]; _sink = nil;
    [_sinkPath release]; _sinkPath = nil;
    [_response release]; _response = nil;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    [[self client] URLProtocol:self didFailWithError:error];
    [_sink closeFile];
    if (_sinkPath)
        [[NSFileManager defaultManager] removeItemAtPath:_sinkPath error:NULL];
    [_sink release]; _sink = nil;
    [_sinkPath release]; _sinkPath = nil;
    [_response release]; _response = nil;
}

- (void)dealloc
{
    [_connection release];
    [_sink release];
    [_sinkPath release];
    [_response release];
    [super dealloc];
}

@end

void StaticAssetCacheRegister(void)
{
    [NSURLProtocol registerClass:[StaticAssetCacheProtocol class]];
}
