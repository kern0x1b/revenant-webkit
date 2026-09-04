/*
 * HTTPS for a system whose TLS stopped being usable years ago.
 *
 * iOS 6 ships SecureTransport and OpenSSL 0.9.8, neither of which can negotiate
 * with a current server: no TLS 1.2 by default, no modern cipher suites, no SNI
 * in places that need it. Every request WebKit makes goes through NSURLConnection,
 * and NSURLProtocol is the documented place to take those requests over — so the
 * connection is made here, against a current OpenSSL, and handed back to WebKit
 * as an ordinary response.
 *
 * A page is a hundred requests or more, so what a request avoids doing matters as
 * much as what it does. Connections are kept open and handed to the next request
 * for the same host, the certificate store is parsed once for the process instead
 * of once per request, TLS sessions are resumed so a repeat handshake is one round
 * trip rather than two plus a signature check, and a body is passed to WebKit as
 * it arrives instead of being assembled first. On a 512 MB device that last one is
 * a memory measure as much as a speed one: jetsam is the other way a page load
 * ends here.
 */

#import "ModernTLSURLProtocol.h"

#import <openssl/ssl.h>
#import <openssl/err.h>
#import <openssl/evp.h>
#import <ctype.h>
#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <netdb.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <poll.h>
#import <pthread.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <time.h>
#import <unistd.h>
#import <zlib.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>

static NSString *const kHandledKey = @"ModernTLSHandled";

/* Servers close idle connections on their own schedule — five seconds is a common
 * one — and none of them announce it. Dropping ours early does not avoid the race,
 * only narrows it, so nothing here depends on this number being right. */
static const NSTimeInterval kIdleTimeout = 20.0;

/* How many spare connections to one host are worth holding open. It is a cap on
 * what is kept, not on what may be open at once: how many requests run in
 * parallel is WebKit's decision, and it makes it per host already. */
static const NSUInteger kIdlePerHost = 6;

static const int kConnectTimeout = 10;   /* seconds */
static const int kTransferTimeout = 30;  /* seconds */
static const NSTimeInterval kExchangeTimeout = 60.0;

/* Reading a redirect's body only to discard it is worth one buffer's worth of
 * work to keep the connection; past that, closing it is cheaper. */
static const unsigned long long kDrainLimit = 262144;

static const unsigned long long kImageTranscodeSizeLimit = 6 * 1024 * 1024;

static NSString *gCertificateAuthorities;
static SSL_CTX *gContext;
static int gHostSlot = -1;
static BOOL gLog;

/* One lock for both tables: they are touched once or twice per request and never
 * held across a blocking call. */
static pthread_mutex_t gPoolMutex = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary *gIdleConnections;   /* "host:port" -> connections, oldest first */
static NSMutableDictionary *gSessions;          /* host -> NSValue wrapping SSL_SESSION * */

/* Header names are case-insensitive, and servers differ on which case they
 * send; HTTP/2 origins answer in lower case even over HTTP/1.1. */
static NSString *headerValue(NSDictionary *headers, NSString *name)
{
    for (NSString *field in headers) {
        if ([field caseInsensitiveCompare:name] == NSOrderedSame)
            return [headers objectForKey:field];
    }
    return nil;
}

/* A missing header is nil, and -rangeOfString: on nil answers {0, 0}, which
 * reads as a match. Every header test goes through here instead. */
static BOOL headerContains(NSDictionary *headers, NSString *name, NSString *token)
{
    NSString *value = headerValue(headers, name);
    if (![value length])
        return NO;
    return [value rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound;
}

/* RFC 7230 gives header field values as ISO-8859-1, and a Content-Disposition
 * filename is where that still shows up; UTF-8 is what everything else means. */
static NSString *headerString(const char *bytes)
{
    NSString *text = [NSString stringWithUTF8String:bytes];
    if (!text)
        text = [[[NSString alloc] initWithCString:bytes encoding:NSISOLatin1StringEncoding] autorelease];
    return text;
}

/* ------------------------------------------------------------------ transport */

#define kDNSCacheHosts 16
#define kDNSCacheAddresses 6
#define kDNSCacheSeconds 120

typedef struct {
    char host[256];
    char port[8];
    struct sockaddr_storage storage[kDNSCacheAddresses];
    socklen_t length[kDNSCacheAddresses];
    int family[kDNSCacheAddresses];
    int socktype[kDNSCacheAddresses];
    int protocol[kDNSCacheAddresses];
    unsigned count;
    time_t expiry;
} DNSEntry;

static DNSEntry gDNSCache[kDNSCacheHosts];
static pthread_mutex_t gDNSMutex = PTHREAD_MUTEX_INITIALIZER;

static unsigned dnsCacheCopy(const char *host, const char *port, DNSEntry *out)
{
    struct timeval now;
    gettimeofday(&now, NULL);
    unsigned count = 0;
    pthread_mutex_lock(&gDNSMutex);
    for (unsigned i = 0; i < kDNSCacheHosts; i++) {
        if (!gDNSCache[i].count || gDNSCache[i].expiry <= now.tv_sec)
            continue;
        if (strcmp(gDNSCache[i].host, host) || strcmp(gDNSCache[i].port, port))
            continue;
        *out = gDNSCache[i];
        count = out->count;
        break;
    }
    pthread_mutex_unlock(&gDNSMutex);
    return count;
}

static void dnsCacheStore(const char *host, const char *port, struct addrinfo *addresses)
{
    if (strlen(host) >= sizeof(gDNSCache[0].host) || strlen(port) >= sizeof(gDNSCache[0].port))
        return;

    DNSEntry entry;
    memset(&entry, 0, sizeof(entry));
    strcpy(entry.host, host);
    strcpy(entry.port, port);
    for (struct addrinfo *address = addresses; address && entry.count < kDNSCacheAddresses; address = address->ai_next) {
        if (!address->ai_addr || address->ai_addrlen > sizeof(struct sockaddr_storage))
            continue;
        memcpy(&entry.storage[entry.count], address->ai_addr, address->ai_addrlen);
        entry.length[entry.count] = address->ai_addrlen;
        entry.family[entry.count] = address->ai_family;
        entry.socktype[entry.count] = address->ai_socktype;
        entry.protocol[entry.count] = address->ai_protocol;
        entry.count++;
    }
    if (!entry.count)
        return;

    struct timeval now;
    gettimeofday(&now, NULL);
    entry.expiry = now.tv_sec + kDNSCacheSeconds;

    pthread_mutex_lock(&gDNSMutex);
    unsigned slot = kDNSCacheHosts;
    for (unsigned i = 0; i < kDNSCacheHosts; i++) {
        if (gDNSCache[i].count && !strcmp(gDNSCache[i].host, host) && !strcmp(gDNSCache[i].port, port)) {
            slot = i;
            break;
        }
    }
    if (slot == kDNSCacheHosts) {
        for (unsigned i = 0; i < kDNSCacheHosts; i++) {
            if (!gDNSCache[i].count || gDNSCache[i].expiry <= now.tv_sec) {
                slot = i;
                break;
            }
        }
    }
    if (slot == kDNSCacheHosts) {
        time_t oldest = 0;
        slot = 0;
        for (unsigned i = 0; i < kDNSCacheHosts; i++) {
            if (!oldest || gDNSCache[i].expiry < oldest) {
                oldest = gDNSCache[i].expiry;
                slot = i;
            }
        }
    }
    gDNSCache[slot] = entry;
    pthread_mutex_unlock(&gDNSMutex);
}

static int connectToHost(const char *host, const char *port)
{
    DNSEntry cached;
    struct addrinfo nodes[kDNSCacheAddresses];
    struct addrinfo *addresses = NULL;
    struct addrinfo *resolved = NULL;

    unsigned cachedCount = dnsCacheCopy(host, port, &cached);
    if (cachedCount) {
        memset(nodes, 0, sizeof(nodes));
        for (unsigned i = 0; i < cachedCount; i++) {
            nodes[i].ai_family = cached.family[i];
            nodes[i].ai_socktype = cached.socktype[i];
            nodes[i].ai_protocol = cached.protocol[i];
            nodes[i].ai_addrlen = cached.length[i];
            nodes[i].ai_addr = (struct sockaddr *)&cached.storage[i];
            nodes[i].ai_next = (i + 1 < cachedCount) ? &nodes[i + 1] : NULL;
        }
        addresses = nodes;
    } else {
        struct addrinfo hints;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;

        if (getaddrinfo(host, port, &hints, &resolved) || !resolved)
            return -1;
        dnsCacheStore(host, port, resolved);
        addresses = resolved;
    }

    unsigned count = 0;
    for (struct addrinfo *address = addresses; address; address = address->ai_next)
        count++;

    struct pollfd *waiting = malloc(sizeof(struct pollfd) * count);
    int *flagsFor = malloc(sizeof(int) * count);
    unsigned live = 0;
    int handle = -1;
    for (struct addrinfo *address = addresses; address; address = address->ai_next) {
        int candidate = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (candidate < 0)
            continue;
        int flags = fcntl(candidate, F_GETFL, 0);
        fcntl(candidate, F_SETFL, flags | O_NONBLOCK);
        int reached = connect(candidate, address->ai_addr, address->ai_addrlen);
        if (!reached) {
            for (unsigned i = 0; i < live; i++)
                close(waiting[i].fd);
            live = 0;
            fcntl(candidate, F_SETFL, flags);
            handle = candidate;
            break;
        }
        if (errno != EINPROGRESS) {
            close(candidate);
            continue;
        }
        waiting[live].fd = candidate;
        waiting[live].events = POLLOUT;
        waiting[live].revents = 0;
        flagsFor[live] = flags;
        live++;
    }
    if (resolved)
        freeaddrinfo(resolved);

    struct timeval deadline;
    gettimeofday(&deadline, NULL);
    deadline.tv_sec += kConnectTimeout;
    while (live && handle < 0) {
        struct timeval now;
        gettimeofday(&now, NULL);
        long remainingMs = (deadline.tv_sec - now.tv_sec) * 1000
            + (deadline.tv_usec - now.tv_usec) / 1000;
        if (remainingMs <= 0)
            break;

        int ready = poll(waiting, live, (int)remainingMs);
        if (ready <= 0)
            break;

        for (unsigned i = 0; i < live && handle < 0; i++) {
            if (!(waiting[i].revents & (POLLOUT | POLLERR | POLLHUP)))
                continue;
            int failure = 0;
            socklen_t size = sizeof(failure);
            if (!getsockopt(waiting[i].fd, SOL_SOCKET, SO_ERROR, &failure, &size) && !failure) {
                handle = waiting[i].fd;
                fcntl(handle, F_SETFL, flagsFor[i]);
                waiting[i].fd = -1;
            } else {
                close(waiting[i].fd);
                waiting[i].fd = -1;
            }
        }
        unsigned kept = 0;
        for (unsigned i = 0; i < live; i++) {
            if (waiting[i].fd < 0)
                continue;
            waiting[kept] = waiting[i];
            flagsFor[kept] = flagsFor[i];
            kept++;
        }
        live = kept;
    }
    for (unsigned i = 0; i < live; i++)
        close(waiting[i].fd);
    free(waiting);
    free(flagsFor);
    if (handle < 0)
        return -1;

    int on = 1;
    /* A request is one small write that the server cannot answer until it has all
     * of it, so there is nothing for Nagle to coalesce it with. */
    setsockopt(handle, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
    /* Writing to a pooled connection the server has closed raises SIGPIPE, whose
     * default action is to kill the process; the write has to fail instead, which
     * is what tells us to dial again. */
    setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));

    struct timeval limit;
    limit.tv_sec = kTransferTimeout;
    limit.tv_usec = 0;
    setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof(limit));
    setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, &limit, sizeof(limit));
    return handle;
}

/* The client half of the session cache. OpenSSL's internal store is a server-side
 * thing; on a client the sessions have to be caught as they are issued and looked
 * up by name, and with TLS 1.3 they are issued after the handshake has finished,
 * on the first read — which is why this is a callback and not SSL_get1_session()
 * at connect time.
 *
 * What is kept is a copy, never the session object itself. OpenSSL marks a session
 * unusable when its connection ends without a close_notify, and that is how nearly
 * every server ends a keep-alive connection it no longer wants — so holding the
 * shared object would let one dropped connection cost a full handshake on the
 * next. Measured: with the object shared, every second handshake to a host that
 * drops connections is a full one; with a copy, all of them resume. */
static int rememberSession(SSL *ssl, SSL_SESSION *session)
{
    NSString *host = (NSString *)SSL_get_ex_data(ssl, gHostSlot);
    if (!host)
        return 0;
    SSL_SESSION *copy = SSL_SESSION_dup(session);
    if (!copy)
        return 0;

    pthread_mutex_lock(&gPoolMutex);
    SSL_SESSION *previous = (SSL_SESSION *)[[gSessions objectForKey:host] pointerValue];
    if (previous)
        SSL_SESSION_free(previous);
    [gSessions setObject:[NSValue valueWithPointer:copy] forKey:host];
    pthread_mutex_unlock(&gPoolMutex);

    /* 0 leaves the original where it was, with the connection that earned it. */
    return 0;
}

/* ---------------------------------------------------------------- connections */

static NSTimeInterval nowSeconds(void);

@interface ModernTLSConnection : NSObject
{
    NSString *_key;
    NSString *_host;
    int _handle;
    SSL *_ssl;
    NSTimeInterval _idleSince;
    BOOL _received;
    NSTimeInterval _exchangeDeadline;
    /* Reading the head of a response almost always pulls the first of the body in
     * with it, and on a kept connection it can pull in the head of the next one,
     * so the leftovers belong to the connection rather than to a request. */
    unsigned char _buffer[16384];
    NSUInteger _start;
    NSUInteger _end;
}
+ (ModernTLSConnection *)connectionToHost:(NSString *)host port:(NSString *)port key:(NSString *)key
                                  message:(NSString **)message code:(NSInteger *)code;
- (NSString *)key;
- (NSTimeInterval)idleSince;
- (void)markIdle;
- (BOOL)isUsable;
- (BOOL)hasRead;
- (void)beginExchange;
- (BOOL)writeData:(NSData *)data;
- (NSData *)readUpTo:(NSUInteger)limit;
- (BOOL)readLine:(char *)line size:(size_t)size;
- (void)shutdown;
@end

@implementation ModernTLSConnection

+ (ModernTLSConnection *)connectionToHost:(NSString *)host port:(NSString *)port key:(NSString *)key
                                  message:(NSString **)message code:(NSInteger *)code
{
    int handle = connectToHost([host UTF8String], [port UTF8String]);
    if (handle < 0) {
        *message = [NSString stringWithFormat:@"Cannot reach %@", host];
        *code = NSURLErrorCannotConnectToHost;
        return nil;
    }

    SSL *ssl = SSL_new(gContext);
    if (!ssl) {
        close(handle);
        *message = @"No TLS context";
        *code = NSURLErrorSecureConnectionFailed;
        return nil;
    }

    ModernTLSConnection *connection = [[ModernTLSConnection alloc] init];
    connection->_key = [key copy];
    connection->_host = [host copy];
    connection->_handle = handle;
    connection->_ssl = ssl;

    SSL_set_fd(ssl, handle);
    SSL_set_tlsext_host_name(ssl, [host UTF8String]);
    SSL_set1_host(ssl, [host UTF8String]);
    /* The session callback fires during the handshake as well as after it, and it
     * has nothing but the SSL to say which host the session belongs to. The name
     * is the connection's own copy, which outlives the SSL. */
    SSL_set_ex_data(ssl, gHostSlot, connection->_host);

    /* Copied on the way out for the same reason it was copied on the way in: how
     * this connection ends must not be able to spoil the next one's chances. */
    pthread_mutex_lock(&gPoolMutex);
    SSL_SESSION *stored = (SSL_SESSION *)[[gSessions objectForKey:host] pointerValue];
    SSL_SESSION *offer = stored ? SSL_SESSION_dup(stored) : NULL;
    pthread_mutex_unlock(&gPoolMutex);
    if (offer) {
        SSL_set_session(ssl, offer);
        SSL_SESSION_free(offer);
    }

    if (SSL_connect(ssl) != 1) {
        unsigned long reason = ERR_get_error();
        char text[256] = {0};
        ERR_error_string_n(reason, text, sizeof(text));
        *message = [NSString stringWithFormat:@"TLS handshake with %@ failed: %s", host, text];
        *code = NSURLErrorSecureConnectionFailed;
        [connection shutdown];
        [connection release];
        return nil;
    }

    if (gLog)
        fprintf(stderr, "[tls] connected %s  %s  %s\n", [key UTF8String],
            SSL_get_version(ssl), SSL_session_reused(ssl) ? "resumed" : "full handshake");
    [connection markIdle];
    return connection;
}

- (void)dealloc
{
    [self shutdown];
    [_key release];
    [_host release];
    [super dealloc];
}

- (NSString *)key
{
    return _key;
}

- (NSTimeInterval)idleSince
{
    return _idleSince;
}

- (void)markIdle
{
    _idleSince = [NSDate timeIntervalSinceReferenceDate];
}

- (BOOL)hasRead
{
    return _received;
}

- (void)beginExchange
{
    _received = NO;
    _exchangeDeadline = nowSeconds() + kExchangeTimeout;
}

/* Whether this connection is worth handing to another request. There is no way to
 * be certain — the server may close it between this answer and the next write —
 * so the caller must still be able to start over; this only makes that rare. */
- (BOOL)isUsable
{
    if (_handle < 0 || !_ssl)
        return NO;
    if ([NSDate timeIntervalSinceReferenceDate] - _idleSince > kIdleTimeout)
        return NO;
    /* Bytes left over from the last response mean its framing was wrong, and
     * anything read on this connection from here would be misattributed. */
    if (_start < _end || SSL_pending(_ssl) > 0)
        return NO;

    struct pollfd probe;
    probe.fd = _handle;
    probe.events = POLLIN;
    probe.revents = 0;
    int ready = poll(&probe, 1, 0);
    if (ready < 0)
        return NO;
    if (!ready)
        return YES;

    /* Something is waiting, and on TLS 1.3 that is usually a session ticket rather
     * than trouble. Reading without blocking lets OpenSSL take the ticket — which
     * is how the next connection to this host gets to resume — and separates a
     * closed connection, which fails, from a healthy one, which has nothing to
     * give. Application data here belongs to no request of ours, so its arrival
     * means the framing is lost and the connection is done. */
    int flags = fcntl(_handle, F_GETFL, 0);
    fcntl(_handle, F_SETFL, flags | O_NONBLOCK);
    unsigned char byte;
    int got = SSL_read(_ssl, &byte, 1);
    int reason = SSL_get_error(_ssl, got);
    fcntl(_handle, F_SETFL, flags);

    if (got > 0)
        return NO;
    return reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE;
}

- (BOOL)writeData:(NSData *)data
{
    const unsigned char *bytes = (const unsigned char *)[data bytes];
    NSUInteger length = [data length], sent = 0;
    while (sent < length) {
        int wrote = SSL_write(_ssl, bytes + sent, (int)(length - sent));
        if (wrote <= 0)
            return NO;
        sent += wrote;
    }
    return YES;
}

- (BOOL)fill
{
    if (_start < _end)
        return YES;
    if (_exchangeDeadline && nowSeconds() >= _exchangeDeadline)
        return NO;
    _start = _end = 0;
    int read = SSL_read(_ssl, _buffer, sizeof(_buffer));
    if (read <= 0)
        return NO;
    _end = read;
    _received = YES;
    return YES;
}

/* Whatever has arrived, up to limit — never a wait for a full buffer, so a body
 * reaches WebKit at the rate the server sends it. */
- (NSData *)readUpTo:(NSUInteger)limit
{
    if (![self fill])
        return nil;
    NSUInteger available = _end - _start;
    if (available > limit)
        available = limit;
    NSData *data = [NSData dataWithBytes:_buffer + _start length:available];
    _start += available;
    return data;
}

/* Status lines, header fields and chunk sizes are all one line; a line longer than
 * the caller's buffer is truncated in what it returns but still consumed in full,
 * so the framing survives a header we cannot represent. */
- (BOOL)readLine:(char *)line size:(size_t)size
{
    size_t length = 0;
    for (;;) {
        if (![self fill])
            return NO;
        char byte = _buffer[_start++];
        if (byte == '\n') {
            if (length && line[length - 1] == '\r')
                length--;
            line[length] = 0;
            return YES;
        }
        if (length + 1 < size)
            line[length++] = byte;
    }
}

- (void)shutdown
{
    if (_ssl) {
        SSL_shutdown(_ssl);
        SSL_free(_ssl);
        _ssl = NULL;
    }
    if (_handle >= 0) {
        close(_handle);
        _handle = -1;
    }
}

@end

/* ----------------------------------------------------------------- the pool */

/* Called with the lock held, from both ends of the pool, so a host nobody visits
 * again still gives its sockets back as soon as anything else happens. */
static void expireIdleConnections(void)
{
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    for (NSString *key in [gIdleConnections allKeys]) {
        NSMutableArray *bucket = [gIdleConnections objectForKey:key];
        while ([bucket count] && now - [[bucket objectAtIndex:0] idleSince] > kIdleTimeout) {
            [[bucket objectAtIndex:0] shutdown];
            [bucket removeObjectAtIndex:0];
        }
        if (![bucket count])
            [gIdleConnections removeObjectForKey:key];
    }
}

static ModernTLSConnection *takeIdleConnection(NSString *key)
{
    for (;;) {
        ModernTLSConnection *connection = nil;

        pthread_mutex_lock(&gPoolMutex);
        expireIdleConnections();
        NSMutableArray *bucket = [gIdleConnections objectForKey:key];
        if ([bucket count]) {
            /* Newest last, and the newest is the one that has been idle for the
             * shortest time, so it is the least likely to have been closed. */
            connection = [[bucket lastObject] retain];
            [bucket removeLastObject];
        }
        pthread_mutex_unlock(&gPoolMutex);

        if (!connection)
            return nil;
        /* -isUsable reads from the socket, which is not something to do under the
         * lock — hence taking the connection out first and dropping it here. */
        if ([connection isUsable])
            return connection;
        [connection shutdown];
        [connection release];
    }
}

static void returnIdleConnection(ModernTLSConnection *connection)
{
    [connection markIdle];
    /* Reading now takes the TLS 1.3 session ticket while the connection is still
     * ours, so a host's first parallel connections can resume rather than each
     * paying for a full handshake. */
    if (![connection isUsable]) {
        [connection shutdown];
        return;
    }

    pthread_mutex_lock(&gPoolMutex);
    expireIdleConnections();
    NSMutableArray *bucket = [gIdleConnections objectForKey:[connection key]];
    if (!bucket) {
        bucket = [NSMutableArray array];
        [gIdleConnections setObject:bucket forKey:[connection key]];
    }
    [bucket addObject:connection];
    while ([bucket count] > kIdlePerHost) {
        [[bucket objectAtIndex:0] shutdown];
        [bucket removeObjectAtIndex:0];
    }
    pthread_mutex_unlock(&gPoolMutex);
}

/* ------------------------------------------------------------------- the cache */

/*
 * What survives a launch, and why none of it could be borrowed.
 *
 * Nothing else in this process remembers anything between runs. WebCore's memory
 * cache is eight megabytes that die with the process, its back-forward cache
 * holds zero pages under the constructor defaults this app deliberately keeps,
 * and +[WebView _setCacheModel:] — the one call that would size an on-disk cache
 * — runs only off a notification that +[WebPreferences standardPreferences]
 * never posts, so it does not run here at all.
 *
 * NSURLCache looks like the answer and is not. A request answered by an
 * NSURLProtocol subclass is never read from it: with an entry for the request
 * demonstrably present in the shared NSURLCache, -startLoading was still called,
 * -cachedResponse was still nil, and the bytes the protocol produced were the
 * ones returned. Asking for NSURLCacheStorageAllowed in
 * -didReceiveResponse:cacheStoragePolicy: does not change that; it is a request
 * addressed to a loader that is not in the path. That was run against the host's
 * Foundation rather than the device's, since the device has no way to run it —
 * but it decides nothing on its own, because even where the loader does write an
 * entry, nothing ever reads one back on the way in, and the read is the half a
 * cache is for.
 *
 * So all of it is here, and nothing downstream will catch a mistake in it. The
 * rules are RFC 9111's, for a private cache. What is deliberately left out:
 *
 *  - Stale responses are never served. must-revalidate, proxy-revalidate,
 *    stale-while-revalidate and stale-if-error therefore decide nothing and are
 *    not read: they all describe when a stale response may be used, and here the
 *    answer is never. The single exception is NSURLRequestReturnCacheDataElseLoad
 *    and its DontLoad sibling, where WebKit is asking for the stored copy at any
 *    age — that is the client's decision to make, not the origin's.
 *  - s-maxage, public-as-permission and proxy-revalidate address shared caches.
 *    This one is private, so s-maxage is ignored and `private` is honoured by
 *    storing rather than by refusing to.
 *  - GET only. HEAD is answered with the headers a GET would have had, including
 *    a Content-Length for a body it does not carry, so storing one under the key
 *    a GET reads would put a length against no bytes. The other methods are not
 *    cacheable in any case, and the unsafe ones invalidate instead (§4.4).
 *  - Range is not cached. A request carrying one is not answered from the cache
 *    and a 206 is never stored: writing a partial representation into a slot
 *    that will be read back as a whole one is the exact failure this file is not
 *    allowed to have.
 *  - Of the request directives, no-store, no-cache and max-age are honoured.
 *    min-fresh and max-stale are not read, and neither is only-if-cached — that
 *    last one WebKit expresses as NSURLRequestReturnCacheDataDontLoad on the
 *    request instead, which is honoured. WebKit sends none of the three as
 *    headers, and a directive that is read but not obeyed would be worse than
 *    one that is not read.
 *  - No digest is kept of a stored body, so a file corrupted in place is served
 *    as though it were sound. Hashing a hundred kilobytes on this processor is
 *    several milliseconds on exactly the path the cache exists to shorten. What
 *    is defended against instead is the corruption that is actually likely: a
 *    truncated or half-written file, which the recorded lengths catch, and a
 *    body reaching the disk after the rename that published it, which the fsync
 *    in -commit orders against.
 *  - One variant per key. RFC 9111 lets a cache keep several representations of
 *    a URI and choose between them with Vary; this keeps the most recent and
 *    treats a Vary mismatch as a miss. A cache may always evict, so keeping one
 *    is a subset of the allowed behaviour rather than a departure from it.
 *  - The qualified forms — no-cache="field", private="field" — are read as the
 *    unqualified ones. That is stricter than the response asked for, never
 *    looser.
 *  - Bodies are stored decoded. Content-Encoding is undone as the body streams
 *    past and is never held in its encoded form, so the encoded bytes do not
 *    exist to store by the time storing is possible; what is written is exactly
 *    what WebKit was handed, with the coding and framing headers stripped the
 *    same way they are on the wire path. It costs disk against a gzipped copy
 *    and buys a replay that is byte-for-byte the original delivery.
 *  - Set-Cookie is not stored. It was applied to NSHTTPCookieStorage when the
 *    response first arrived and that storage persists on its own; replaying a
 *    weeks-old Set-Cookie on every hit would resurrect cookies the server has
 *    since expired. Keeping session cookies out of a file on a device where
 *    every application runs as the same user is worth having besides.
 */

/* What the cache may occupy. The device shares eight gigabytes of flash with
 * everything else on it, and Library/Caches is a directory the system is
 * entitled to empty when space runs short, so this is a budget and not a
 * reservation. Twenty megabytes is set against what it is for: a web app's
 * shell — markup, script, stylesheets, fonts, icons — is two to five megabytes
 * once decoded, so this holds several apps' interfaces with room for the images
 * around them. Nothing here was measured on the device. If it is wrong it is
 * wrong in the direction of being too small, which costs a request rather than
 * correctness. */
static const unsigned long long kCacheCapacity = 20ULL * 1024 * 1024;

/* Eviction runs down to a low-water mark instead of to the cap, so a sweep is
 * worth the directory walk it costs rather than being due again immediately. */
static const unsigned long long kCacheLowWater = 16ULL * 1024 * 1024;

/* No single response may take more than an eighth of the cache. This is not an
 * RFC rule, it is admission control: one video or font blob big enough to push
 * the whole shell out makes the second launch slower, which is the one thing
 * the cache exists to prevent. */
static const unsigned long long kCacheEntryLimit = kCacheCapacity / 8;

/* Twenty megabytes of two-hundred-byte responses is a hundred thousand files,
 * and it is the sweep rather than the lookup that would pay for that — a lookup
 * opens one name it computed. This bounds the walk. */
static const NSUInteger kCacheEntries = 4000;

/* RFC 9111 §4.2.2 leaves the heuristic to the cache. Ours is the usual tenth of
 * the time since the representation last changed, and it applies only to a
 * response that says when that was — no Last-Modified, no guess, revalidate.
 * The day is a ceiling on how wrong the guess may be. */
static const NSTimeInterval kHeuristicFraction = 0.1;
static const NSTimeInterval kHeuristicCeiling = 86400.0;

/* Written once during +install, read without the lock afterwards; nil means the
 * directory could not be made and there is no cache this run. */
static NSString *gCacheDirectory;

/* Guards the sweep bookkeeping only. The entries themselves need no lock: a
 * write lands on a temporary name and is renamed into place, so a reader sees
 * either the whole of one version or the whole of another. */
static pthread_mutex_t gCacheMutex = PTHREAD_MUTEX_INITIALIZER;
/* What the directory holds, as of the last walk plus everything committed since.
 * Keeping the running total is what lets the cap mean the cap: a sweep is due
 * the moment this crosses it, rather than every so many bytes written and
 * therefore some unknown distance past it. */
static unsigned long long gCacheBytes;
static unsigned long long gCacheWrittenDuringSweep;
/* Whether a walk has finished in this process. Until one has, gCacheBytes is not
 * a number, it is a zero standing in for a directory nobody has looked at — and
 * treating that as "plenty of room" is how a cache grows every launch. */
static BOOL gCacheCounted;
/* Whether a walk is running *now*. Not whether one has been asked for: a walk
 * that has been queued and not reached is not one anything may defer to. */
static BOOL gCacheSweeping;
static unsigned long gCacheSerial;

/* Declared here because a committed write reports itself, and the bookkeeping it
 * reports to is further down with the rest of the housekeeping. isHopByHop() is
 * with the request code it was written for, further down still. */
static void cacheNoteWrite(unsigned long long bytes);
static BOOL isHopByHop(NSString *field);

static NSTimeInterval nowSeconds(void)
{
    return [NSDate timeIntervalSinceReferenceDate] + NSTimeIntervalSince1970;
}

/* ------------------------------------------------------- dates and directives */

/* RFC 9110 §5.6.7 gives three date formats and says a recipient must accept all
 * three. strptime() would do it in three lines and read the month name through
 * the process locale, which is not ours to depend on: WebKit and ICU are both in
 * this address space and both set locales. The grammar is fixed, so it is parsed
 * here instead. Answers epoch seconds, which is what everything below works in. */
static BOOL parseHTTPDate(NSString *text, NSTimeInterval *out)
{
    if (![text length])
        return NO;
    const char *bytes = [text UTF8String];
    if (!bytes)
        return NO;

    static const char *const months[] = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    char month[8] = {0};
    int day = 0, year = 0, hour = 0, minute = 0, second = 0;
    BOOL twoDigitYear = NO;

    const char *comma = strchr(bytes, ',');
    if (comma) {
        const char *rest = comma + 1;
        while (*rest == ' ')
            rest++;
        /* IMF-fixdate: 06 Nov 1994 08:49:37 GMT */
        if (sscanf(rest, "%2d %3s %4d %2d:%2d:%2d", &day, month, &year, &hour, &minute, &second) != 6) {
            /* The obsolete RFC 850 form: 06-Nov-94 08:49:37 GMT */
            if (sscanf(rest, "%2d-%3s-%2d %2d:%2d:%2d", &day, month, &year, &hour, &minute, &second) != 6)
                return NO;
            twoDigitYear = YES;
        }
    } else {
        /* asctime: Sun Nov  6 08:49:37 1994 */
        char weekday[8] = {0};
        if (sscanf(bytes, "%3s %3s %2d %2d:%2d:%2d %4d",
                weekday, month, &day, &hour, &minute, &second, &year) != 7)
            return NO;
    }

    int index = -1;
    for (int candidate = 0; candidate < 12; candidate++) {
        if (!strncmp(month, months[candidate], 3)) {
            index = candidate;
            break;
        }
    }
    if (index < 0)
        return NO;

    if (twoDigitYear) {
        /* RFC 9110 §5.6.7 again: a two-digit year that would land more than fifty
         * years ahead means the most recent past year ending in those digits. */
        time_t clock = time(NULL);
        struct tm present;
        gmtime_r(&clock, &present);
        year += 1900;
        while (year > present.tm_year + 1900 + 50)
            year -= 100;
    }

    struct tm parts;
    memset(&parts, 0, sizeof(parts));
    parts.tm_mday = day;
    parts.tm_mon = index;
    parts.tm_year = year - 1900;
    parts.tm_hour = hour;
    parts.tm_min = minute;
    parts.tm_sec = second;

    time_t moment = timegm(&parts);
    if (moment == (time_t)-1)
        return NO;
    *out = (NSTimeInterval)moment;
    return YES;
}

/* Cache-Control is a list of directives, some of which carry a value that may be
 * quoted and may itself contain commas — so it cannot be cut on commas first.
 * Names come back lower-cased; a directive with no value maps to an empty string,
 * which is why every caller tests for nil rather than for length. */
static NSDictionary *parseCacheControl(NSString *text)
{
    NSMutableDictionary *directives = [NSMutableDictionary dictionary];
    if (![text length])
        return directives;
    const char *bytes = [text UTF8String];
    if (!bytes)
        return directives;

    size_t length = strlen(bytes), at = 0;
    while (at < length) {
        while (at < length && (bytes[at] == ',' || isspace((unsigned char)bytes[at])))
            at++;
        size_t nameStart = at;
        while (at < length && bytes[at] != '=' && bytes[at] != ',' && !isspace((unsigned char)bytes[at]))
            at++;
        if (at == nameStart)
            break;
        NSString *name = [[[NSString alloc] initWithBytes:bytes + nameStart length:at - nameStart
            encoding:NSASCIIStringEncoding] autorelease];

        NSString *value = @"";
        while (at < length && isspace((unsigned char)bytes[at]))
            at++;
        if (at < length && bytes[at] == '=') {
            at++;
            while (at < length && isspace((unsigned char)bytes[at]))
                at++;
            if (at < length && bytes[at] == '"') {
                at++;
                char unquoted[256];
                size_t written = 0;
                while (at < length && bytes[at] != '"') {
                    if (bytes[at] == '\\' && at + 1 < length)
                        at++;
                    if (written + 1 < sizeof(unquoted))
                        unquoted[written++] = bytes[at];
                    at++;
                }
                if (at < length)
                    at++;
                value = [[[NSString alloc] initWithBytes:unquoted length:written
                    encoding:NSASCIIStringEncoding] autorelease];
            } else {
                size_t valueStart = at;
                while (at < length && bytes[at] != ',' && !isspace((unsigned char)bytes[at]))
                    at++;
                value = [[[NSString alloc] initWithBytes:bytes + valueStart length:at - valueStart
                    encoding:NSASCIIStringEncoding] autorelease];
            }
        }
        if ([name length] && value)
            [directives setObject:value forKey:[name lowercaseString]];
    }
    return directives;
}

/* RFC 9111 §1.2.2: delta-seconds is a run of digits, and a value too large to
 * represent is taken as the largest one that is. Anything else is not a
 * delta-seconds at all — a max-age the cache cannot read is not one it gets to
 * invent a number for. */
static BOOL parseDeltaSeconds(NSString *value, NSTimeInterval *out)
{
    if (![value length])
        return NO;
    const char *bytes = [value UTF8String];
    if (!bytes)
        return NO;
    for (const char *at = bytes; *at; at++) {
        if (!isdigit((unsigned char)*at))
            return NO;
    }
    unsigned long long seconds = strtoull(bytes, NULL, 10);
    if (seconds > 2147483648ULL)
        seconds = 2147483648ULL;
    *out = (NSTimeInterval)seconds;
    return YES;
}

static BOOL deltaSeconds(NSDictionary *directives, NSString *name, NSTimeInterval *out)
{
    return parseDeltaSeconds([directives objectForKey:name], out);
}

/* ------------------------------------------------------------- the entry file */

/* magic | metadata length | body length | metadata | body. The two lengths are
 * in the fixed part rather than inside the metadata because the body length is
 * only known when the body ends, and a fixed field can be written back over
 * without the encoding of the number changing its size. */
static const char kCacheMagic[8] = { 'M', 'T', 'L', 'S', 'c', 'v', '1', '\0' };
/* An enumerator rather than a static const, so that it is a constant expression
 * and the header buffer below is an array rather than a variable-length one. */
enum { kCacheHeaderSize = 20 };

@interface ModernTLSCacheEntry : NSObject
{
@public
    NSData *file;               /* the whole entry, mapped; the body is a range of it */
    NSString *path;
    NSString *url;
    NSInteger status;
    NSDictionary *headers;      /* as WebKit was handed them, and will be again */
    NSDictionary *selecting;    /* the Vary-named request fields, as they were then */
    NSTimeInterval requested;
    NSTimeInterval received;
    NSUInteger bodyOffset;
    NSUInteger bodyLength;
}
@end

@implementation ModernTLSCacheEntry
- (void)dealloc
{
    [file release];
    [path release];
    [url release];
    [headers release];
    [selecting release];
    [super dealloc];
}
@end

static NSString *cachePathForKey(NSString *key)
{
    if (!gCacheDirectory)
        return nil;
    const char *bytes = [key UTF8String];
    if (!bytes)
        return nil;

    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int size = 0;
    if (!EVP_Digest(bytes, strlen(bytes), digest, &size, EVP_sha256(), NULL))
        return nil;

    char name[2 * EVP_MAX_MD_SIZE + 1];
    for (unsigned int at = 0; at < size; at++)
        snprintf(name + 2 * at, 3, "%02x", digest[at]);
    return [gCacheDirectory stringByAppendingPathComponent:
        [NSString stringWithUTF8String:name]];
}

/* Reads an entry back, or answers nil for anything it cannot vouch for. Every
 * test here exists because the alternative is handing WebKit bytes that are not
 * the ones the origin sent: a truncated file, a file from an older layout, or —
 * the reason the URL is stored at all — the other side of a hash collision. */
static ModernTLSCacheEntry *readCacheEntry(NSString *path, NSString *key)
{
    NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if ([file length] < kCacheHeaderSize)
        return nil;

    const unsigned char *bytes = (const unsigned char *)[file bytes];
    if (memcmp(bytes, kCacheMagic, sizeof(kCacheMagic)))
        return nil;

    uint32_t metadataLength = 0;
    uint64_t bodyLength = 0;
    memcpy(&metadataLength, bytes + 8, sizeof(metadataLength));
    memcpy(&bodyLength, bytes + 12, sizeof(bodyLength));

    if ((unsigned long long)[file length]
        != (unsigned long long)kCacheHeaderSize + metadataLength + bodyLength)
        return nil;

    NSData *encoded = [file subdataWithRange:NSMakeRange(kCacheHeaderSize, metadataLength)];
    NSDictionary *metadata = [NSPropertyListSerialization propertyListWithData:encoded
        options:NSPropertyListImmutable format:NULL error:NULL];
    if (![metadata isKindOfClass:[NSDictionary class]])
        return nil;

    NSString *url = [metadata objectForKey:@"url"];
    NSDictionary *headers = [metadata objectForKey:@"headers"];
    NSDictionary *selecting = [metadata objectForKey:@"vary"];
    NSNumber *status = [metadata objectForKey:@"status"];
    NSNumber *requested = [metadata objectForKey:@"requested"];
    NSNumber *received = [metadata objectForKey:@"received"];
    if (![url isKindOfClass:[NSString class]] || ![headers isKindOfClass:[NSDictionary class]]
        || ![selecting isKindOfClass:[NSDictionary class]] || ![status isKindOfClass:[NSNumber class]]
        || ![requested isKindOfClass:[NSNumber class]] || ![received isKindOfClass:[NSNumber class]])
        return nil;
    if (![url isEqualToString:key])
        return nil;

    ModernTLSCacheEntry *entry = [[[ModernTLSCacheEntry alloc] init] autorelease];
    entry->file = [file retain];
    entry->path = [path copy];
    entry->url = [url copy];
    entry->headers = [headers retain];
    entry->selecting = [selecting retain];
    entry->status = [status integerValue];
    entry->requested = [requested doubleValue];
    entry->received = [received doubleValue];
    entry->bodyOffset = (NSUInteger)(kCacheHeaderSize + metadataLength);
    entry->bodyLength = (NSUInteger)bodyLength;
    return entry;
}

static void removeCacheEntry(NSString *key)
{
    NSString *path = cachePathForKey(key);
    if (path)
        unlink([path fileSystemRepresentation]);
}

/* The body is written as it streams, so the entry never exists whole in memory,
 * and it is written under a name nothing reads. Only the rename at the end makes
 * it visible, which is what lets a reader that arrives at any moment see either
 * the previous version entire or this one entire and never a half of either. */
@interface ModernTLSCacheWriter : NSObject
{
    NSString *_temporary;
    NSString *_final;
    int _handle;
    unsigned long long _written;
}
- (id)initForKey:(NSString *)key metadata:(NSDictionary *)metadata;
- (BOOL)appendBody:(NSData *)data;
- (BOOL)commit;
- (void)abandon;
@end

@implementation ModernTLSCacheWriter

- (id)initForKey:(NSString *)key metadata:(NSDictionary *)metadata
{
    if (!(self = [super init]))
        return nil;
    _handle = -1;

    NSString *path = cachePathForKey(key);
    NSData *encoded = [NSPropertyListSerialization dataWithPropertyList:metadata
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if (!path || !encoded || [encoded length] > UINT32_MAX) {
        [self release];
        return nil;
    }
    _final = [path copy];

    pthread_mutex_lock(&gCacheMutex);
    unsigned long serial = ++gCacheSerial;
    pthread_mutex_unlock(&gCacheMutex);
    _temporary = [[gCacheDirectory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"partial-%d-%lu", (int)getpid(), serial]] copy];

    /* 0600 rather than the umask: a cache of a logged-in web app's pages is worth
     * as much as the session that fetched them, and on this device every
     * application runs as the same user. */
    _handle = open([_temporary fileSystemRepresentation], O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (_handle < 0) {
        [self release];
        return nil;
    }

    unsigned char head[kCacheHeaderSize];
    uint32_t metadataLength = (uint32_t)[encoded length];
    uint64_t bodyLength = 0;
    memcpy(head, kCacheMagic, sizeof(kCacheMagic));
    memcpy(head + 8, &metadataLength, sizeof(metadataLength));
    memcpy(head + 12, &bodyLength, sizeof(bodyLength));

    if (write(_handle, head, sizeof(head)) != (ssize_t)sizeof(head)
        || write(_handle, [encoded bytes], [encoded length]) != (ssize_t)[encoded length]) {
        [self release];
        return nil;
    }
    return self;
}

- (void)dealloc
{
    [self abandon];
    [_temporary release];
    [_final release];
    [super dealloc];
}

- (BOOL)appendBody:(NSData *)data
{
    if (_handle < 0)
        return NO;
    if (_written + [data length] > kCacheEntryLimit)
        return NO;
    if (write(_handle, [data bytes], [data length]) != (ssize_t)[data length])
        return NO;
    _written += [data length];
    return YES;
}

- (BOOL)commit
{
    if (_handle < 0)
        return NO;

    uint64_t bodyLength = _written;
    if (pwrite(_handle, &bodyLength, sizeof(bodyLength), 12) != (ssize_t)sizeof(bodyLength)) {
        [self abandon];
        return NO;
    }
    /* The rename below is a metadata change, and on a journalled filesystem a
     * metadata change can reach the disk before the data it refers to. Without
     * this, a reboot at the wrong moment leaves a file of the right length full
     * of nothing, which reads back as a valid entry and is served as one. Not
     * F_FULLFSYNC: the point is to order these two writes against each other, not
     * to promise the entry survives a power cut — a lost entry is only a miss. */
    fsync(_handle);
    close(_handle);
    _handle = -1;

    if (rename([_temporary fileSystemRepresentation], [_final fileSystemRepresentation])) {
        unlink([_temporary fileSystemRepresentation]);
        return NO;
    }
    cacheNoteWrite(kCacheHeaderSize + _written);
    return YES;
}

- (void)abandon
{
    if (_handle >= 0) {
        close(_handle);
        _handle = -1;
        unlink([_temporary fileSystemRepresentation]);
    }
}

@end

/* --------------------------------------------------------------- housekeeping */

typedef struct {
    char name[80];
    off_t size;
    time_t used;
} ModernTLSCacheFile;

static int compareByUse(const void *left, const void *right)
{
    time_t first = ((const ModernTLSCacheFile *)left)->used;
    time_t second = ((const ModernTLSCacheFile *)right)->used;
    return first < second ? -1 : first > second ? 1 : 0;
}

/* Eviction, least recently used first, where "used" is the file's modification
 * time. A hit touches the file with utimes(), which is one syscall against a
 * file that is not rewritten, so keeping the ordering costs nothing on the path
 * the cache exists to make fast. Everything expensive is here instead, off that
 * path and on a background queue. */
/* One pass. Answers what the directory holds afterwards, and reports through
 * `removed` whether it was able to take anything out — which is what tells the
 * caller apart from a directory it cannot shrink. */
static unsigned long long sweepOnce(BOOL *removed)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    *removed = NO;
    DIR *directory = opendir([gCacheDirectory fileSystemRepresentation]);
    if (!directory) {
        [pool release];
        return 0;
    }

    ModernTLSCacheFile *files = NULL;
    NSUInteger count = 0, capacity = 0;
    unsigned long long total = 0;

    struct dirent *listing;
    while ((listing = readdir(directory))) {
        if (listing->d_name[0] == '.')
            continue;

        char path[PATH_MAX];
        snprintf(path, sizeof(path), "%s/%s", [gCacheDirectory fileSystemRepresentation], listing->d_name);
        struct stat details;
        if (stat(path, &details) || !S_ISREG(details.st_mode))
            continue;

        /* A partial file belongs to a write that is either still running in this
         * process — in which case its name carries this pid — or died with an
         * earlier one and will never be finished. */
        if (!strncmp(listing->d_name, "partial-", 8)) {
            char mine[32];
            snprintf(mine, sizeof(mine), "partial-%d-", (int)getpid());
            if (strncmp(listing->d_name, mine, strlen(mine)))
                unlink(path);
            continue;
        }
        if (strlen(listing->d_name) >= sizeof(((ModernTLSCacheFile *)0)->name))
            continue;

        if (count == capacity) {
            NSUInteger wanted = capacity ? capacity * 2 : 256;
            ModernTLSCacheFile *grown = realloc(files, wanted * sizeof(ModernTLSCacheFile));
            if (!grown)
                break;
            files = grown;
            capacity = wanted;
        }
        strlcpy(files[count].name, listing->d_name, sizeof(files[count].name));
        files[count].size = details.st_size;
        files[count].used = details.st_mtime;
        total += (unsigned long long)details.st_size;
        count++;
    }
    closedir(directory);

    unsigned long long held = total;
    NSUInteger kept = count;
    if (total > kCacheCapacity || count > kCacheEntries) {
        qsort(files, count, sizeof(ModernTLSCacheFile), compareByUse);
        for (NSUInteger at = 0; at < count && (held > kCacheLowWater || kept > kCacheEntries); at++) {
            char path[PATH_MAX];
            snprintf(path, sizeof(path), "%s/%s", [gCacheDirectory fileSystemRepresentation], files[at].name);
            if (unlink(path))
                continue;
            held -= (unsigned long long)files[at].size;
            kept--;
            *removed = YES;
        }
    }
    if (gLog)
        fprintf(stderr, "[cache] swept: %lu entries in %llu bytes, kept %lu in %llu\n",
            (unsigned long)count, total, (unsigned long)kept, held);
    free(files);
    [pool release];
    return held;
}

/* Passes until the directory is inside the cap, which takes more than one only if
 * enough was committed during a walk to undo it. It cannot spin: a pass that
 * removes nothing ends it, so a directory that will not shrink costs one walk and
 * not a thread. */
static void sweepCache(void)
{
    pthread_mutex_lock(&gCacheMutex);
    if (gCacheSweeping) {
        /* Another thread is in the directory. It re-reads the total before it
         * stops, so it will see whatever this call was about. */
        pthread_mutex_unlock(&gCacheMutex);
        return;
    }
    gCacheSweeping = YES;
    pthread_mutex_unlock(&gCacheMutex);

    for (;;) {
        BOOL removed = NO;
        unsigned long long held = sweepOnce(&removed);

        pthread_mutex_lock(&gCacheMutex);
        /* Entries committed while the walk was running are not in what it counted. */
        gCacheBytes = held + gCacheWrittenDuringSweep;
        gCacheWrittenDuringSweep = 0;
        gCacheCounted = YES;
        BOOL again = gCacheBytes > kCacheCapacity && removed;
        if (!again)
            gCacheSweeping = NO;
        pthread_mutex_unlock(&gCacheMutex);

        if (!again)
            return;
    }
}

/* The launch-time walk, and the only one that is dispatched: it clears out what
 * the last run left — its temporaries above all — and puts a number on a
 * directory this process has not looked at. Nothing waits on it and the first
 * page load must not, so it is not allowed to be the only walk either; see
 * cacheNoteWrite(). */
static void scheduleSweep(void)
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        sweepCache();
    });
}

static void cacheNoteWrite(unsigned long long bytes)
{
    pthread_mutex_lock(&gCacheMutex);
    if (gCacheSweeping)
        gCacheWrittenDuringSweep += bytes;
    else
        gCacheBytes += bytes;
    /* Over the cap, or over a directory this process has never counted. The
     * second is not a nicety: the launch-time walk is queued, and a launch that
     * stores a page and then ends — which is the ordinary shape of one on this
     * device — can finish before that queue is ever reached. */
    BOOL due = !gCacheCounted || gCacheBytes > kCacheCapacity;
    pthread_mutex_unlock(&gCacheMutex);

    /* Walked on the caller's thread rather than handed to a queue, because a
     * queued walk is one that a short launch never performs. It costs nothing
     * that is waiting: this is reached from -commit, after the last byte of the
     * response has already gone to WebKit. Measured before it was moved here:
     * thirteen launches storing two megabytes each left twenty-seven megabytes on
     * disk under a twenty megabyte cap, because only one of the thirteen lived
     * long enough for its sweep to run. sweepCache() returns at once if another
     * thread is already in the directory. */
    if (due)
        sweepCache();
}

/* Library/Caches, under the bundle identifier, because that is the directory the
 * system is entitled to empty when the device runs out of room — which is
 * exactly the licence an HTTP cache wants and the reason not to put this in
 * Documents, where losing it would be the user's problem rather than ours. */
static BOOL installCache(void)
{
    NSArray *directories = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (![directories count])
        return NO;
    NSString *identifier = [[NSBundle mainBundle] bundleIdentifier] ?: @"ModernTLS";
    NSString *path = [[[directories objectAtIndex:0] stringByAppendingPathComponent:identifier]
        stringByAppendingPathComponent:@"HTTPCache"];

    if (![[NSFileManager defaultManager] createDirectoryAtPath:path
            withIntermediateDirectories:YES attributes:nil error:NULL])
        return NO;
    gCacheDirectory = [path copy];

    /* The one walk that is not triggered by a write: it clears out whatever the
     * last run left behind, including the temporaries of a run that was killed
     * mid-request, and it does so on a background queue so the first load of
     * this one never waits for it. */
    scheduleSweep();
    return YES;
}

/* ---------------------------------------------------------------- the policy */

/* RFC 9111 §4.1: the cache key. The method is not in it because only GET reaches
 * here, and the fragment is not in it because a fragment is never sent and never
 * distinguishes one response from another. */
static NSString *cacheKeyForURL(NSURL *url)
{
    NSString *text = [url absoluteString];
    NSRange fragment = [text rangeOfString:@"#"];
    if (fragment.location != NSNotFound)
        text = [text substringToIndex:fragment.location];
    return text;
}

static NSString *cacheKeyForRequest(NSURLRequest *request)
{
    return cacheKeyForURL([request URL]);
}

/* RFC 9111 §4.1 again: the fields the response named in Vary, recorded with the
 * values the request carried, so a later request can be told apart from this one.
 * An absent field is recorded as absent rather than as empty — "no Accept-Language
 * at all" and "Accept-Language: " are different requests to a server that varies
 * on it. */
static NSDictionary *selectingHeaders(NSString *vary, NSDictionary *wire)
{
    NSMutableDictionary *selecting = [NSMutableDictionary dictionary];
    for (NSString *field in [vary componentsSeparatedByString:@","]) {
        NSString *name = [[field stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
        if (![name length])
            continue;
        NSString *value = headerValue(wire, name);
        [selecting setObject:value ?: (id)[NSNull null] forKey:name];
    }
    return selecting;
}

static BOOL selectingHeadersMatch(NSDictionary *selecting, NSDictionary *wire)
{
    for (NSString *name in selecting) {
        id stored = [selecting objectForKey:name];
        NSString *value = headerValue(wire, name);
        if (stored == [NSNull null]) {
            if (value)
                return NO;
        } else if (![stored isEqual:value]) {
            return NO;
        }
    }
    return YES;
}

/* RFC 9111 §4.2.3, in the order the section gives it. The two timestamps the
 * entry carries are what make this work across a launch: without the moment the
 * request went out, a response that spent an hour in someone else's cache is
 * indistinguishable from one that was fetched a second ago. */
static NSTimeInterval entryAge(ModernTLSCacheEntry *entry)
{
    NSTimeInterval dateValue = entry->received;
    NSTimeInterval parsed = 0;
    if (parseHTTPDate(headerValue(entry->headers, @"Date"), &parsed))
        dateValue = parsed;

    NSTimeInterval ageValue = 0;
    if (!parseDeltaSeconds(headerValue(entry->headers, @"Age"), &ageValue))
        ageValue = 0;

    NSTimeInterval apparent = entry->received - dateValue;
    if (apparent < 0)
        apparent = 0;
    NSTimeInterval corrected = ageValue + (entry->received - entry->requested);
    NSTimeInterval initial = apparent > corrected ? apparent : corrected;
    NSTimeInterval resident = nowSeconds() - entry->received;
    if (resident < 0)
        resident = 0;
    return initial + resident;
}

/* RFC 9111 §4.2.1, in its order: the response's own max-age, then Expires
 * measured against the response's Date, then the heuristic. s-maxage is skipped
 * on purpose; it is addressed to shared caches and this one is private. */
static NSTimeInterval entryFreshnessLifetime(ModernTLSCacheEntry *entry, NSDictionary *directives)
{
    NSTimeInterval maxAge = 0;
    if (deltaSeconds(directives, @"max-age", &maxAge))
        return maxAge;

    NSString *expires = headerValue(entry->headers, @"Expires");
    if ([expires length]) {
        NSTimeInterval dateValue = entry->received, expiresValue = 0;
        NSTimeInterval parsed = 0;
        if (parseHTTPDate(headerValue(entry->headers, @"Date"), &parsed))
            dateValue = parsed;
        /* §5.3: an Expires a cache cannot parse — "0" and "-1" are the ones
         * actually sent — means already expired, not "no opinion". Falling
         * through to the heuristic here would invent freshness out of a header
         * whose whole purpose was to deny it. */
        if (!parseHTTPDate(expires, &expiresValue))
            return 0;
        NSTimeInterval lifetime = expiresValue - dateValue;
        return lifetime > 0 ? lifetime : 0;
    }

    NSTimeInterval modified = 0, dateValue = 0;
    if (parseHTTPDate(headerValue(entry->headers, @"Last-Modified"), &modified)
        && parseHTTPDate(headerValue(entry->headers, @"Date"), &dateValue)
        && dateValue > modified) {
        NSTimeInterval lifetime = (dateValue - modified) * kHeuristicFraction;
        return lifetime > kHeuristicCeiling ? kHeuristicCeiling : lifetime;
    }
    return 0;
}

typedef enum {
    ModernTLSCacheUnusable,   /* nothing stored that answers this request */
    ModernTLSCacheValidate,   /* stored, but the origin has to say it still holds */
    ModernTLSCacheFresh       /* answerable from disk, with no connection at all */
} ModernTLSCacheVerdict;

/* Whether a stored response that has already been matched to this request — see
 * selectingHeadersMatch() — is fresh enough to answer it. */
static ModernTLSCacheVerdict verdictForEntry(ModernTLSCacheEntry *entry,
    NSDictionary *requestDirectives)
{
    BOOL hasValidator = [headerValue(entry->headers, @"ETag") length]
        || [headerValue(entry->headers, @"Last-Modified") length];
    NSDictionary *responseDirectives = parseCacheControl(headerValue(entry->headers, @"Cache-Control"));

    /* §5.2.2.4 and §5.2.1.4. no-cache on either side means the stored response
     * may be kept but not used without asking, so a stored response with no way
     * to ask is a stored response that cannot be used. */
    if ([responseDirectives objectForKey:@"no-cache"] || [requestDirectives objectForKey:@"no-cache"])
        return hasValidator ? ModernTLSCacheValidate : ModernTLSCacheUnusable;

    NSTimeInterval age = entryAge(entry);
    NSTimeInterval lifetime = entryFreshnessLifetime(entry, responseDirectives);

    /* §5.2.1.1: the request may hold the response to a shorter life than the
     * origin gave it, never to a longer one. */
    NSTimeInterval requestMaxAge = 0;
    if (deltaSeconds(requestDirectives, @"max-age", &requestMaxAge) && requestMaxAge < lifetime)
        lifetime = requestMaxAge;

    if (age < lifetime)
        return ModernTLSCacheFresh;
    return hasValidator ? ModernTLSCacheValidate : ModernTLSCacheUnusable;
}

/* RFC 9111 §3. What may be written down, for a private cache and for what this
 * protocol is able to replay afterwards. */
static BOOL responseIsStorable(NSInteger status, NSDictionary *headers, NSDictionary *directives)
{
    /* Not a final response, or not one whose body is the whole representation.
     * 304 is excluded because it has no body of its own — it updates an entry
     * rather than becoming one — and 206 because a range is not a representation
     * this cache can hand back as if it were the document. */
    if (status < 200 || status == 206 || status == 304)
        return NO;
    if ([directives objectForKey:@"no-store"])
        return NO;

    /* §4.1: a Vary of * says no request ever matches this response, so storing it
     * is storing something that can only ever be a miss. */
    NSString *vary = headerValue(headers, @"Vary");
    if ([[vary stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]] isEqualToString:@"*"])
        return NO;

    /* §15.1's heuristically cacheable set, less 206: a partial representation is
     * not a representation this cache can hand back whole, and 206 is the only
     * member of that list whose body is not the whole of anything. */
    static const NSInteger byDefault[] = { 200, 203, 204, 300, 301, 308, 404, 405, 410, 414, 501 };
    for (size_t at = 0; at < sizeof(byDefault) / sizeof(byDefault[0]); at++) {
        if (status == byDefault[at])
            return YES;
    }

    /* Everything else needs the origin to have said, in so many words, that it
     * may be kept — an explicit expiry, or a directive that grants storage. */
    NSTimeInterval ignored = 0;
    return deltaSeconds(directives, @"max-age", &ignored)
        || [headerValue(headers, @"Expires") length] != 0
        || [directives objectForKey:@"public"] != nil
        || [directives objectForKey:@"private"] != nil;
}

static NSDictionary *cacheMetadata(ModernTLSCacheEntry *entry)
{
    return [NSDictionary dictionaryWithObjectsAndKeys:
        entry->url, @"url",
        [NSNumber numberWithInteger:entry->status], @"status",
        entry->headers, @"headers",
        entry->selecting, @"vary",
        [NSNumber numberWithDouble:entry->requested], @"requested",
        [NSNumber numberWithDouble:entry->received], @"received", nil];
}

/* RFC 9111 §4.3.4: the fields a 304 carries replace the stored ones. Two are held
 * back. The stored body is decoded and the stored Content-Length describes it as
 * such; a 304's Content-Length and Content-Encoding describe the representation
 * on the wire, and letting them through would leave the entry advertising a
 * length and a coding that its own bytes do not have. */
static void mergeStoredHeaders(ModernTLSCacheEntry *entry, NSDictionary *fresh)
{
    NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:entry->headers];
    for (NSString *field in fresh) {
        if (isHopByHop(field)
            || [field caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame
            || [field caseInsensitiveCompare:@"Content-Encoding"] == NSOrderedSame
            || [field caseInsensitiveCompare:@"Set-Cookie"] == NSOrderedSame)
            continue;
        /* The stored name may differ from this one only in case, and two spellings
         * of one field would both be handed to WebKit. */
        for (NSString *existing in [merged allKeys]) {
            if ([existing caseInsensitiveCompare:field] == NSOrderedSame && ![existing isEqualToString:field])
                [merged removeObjectForKey:existing];
        }
        [merged setObject:[fresh objectForKey:field] forKey:field];
    }
    NSDictionary *replacement = [merged copy];
    [entry->headers release];
    entry->headers = replacement;
}

/* Writing the whole entry again to change a few header fields is more work than
 * the change is worth, and it is done anyway: metadata sits at the head of the
 * file, so changing it moves the body. It is worth it because of when it happens
 * — after the response has already been handed to WebKit from the copy that is
 * still on disk, so the cost lands on nothing that is waiting. */
static void rewriteCacheEntry(ModernTLSCacheEntry *entry, NSString *key)
{
    ModernTLSCacheWriter *writer = [[ModernTLSCacheWriter alloc]
        initForKey:key metadata:cacheMetadata(entry)];
    if (!writer)
        return;

    BOOL whole = YES;
    for (NSUInteger at = 0; whole && at < entry->bodyLength; ) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSUInteger chunk = MIN(entry->bodyLength - at, (NSUInteger)65536);
        whole = [writer appendBody:[entry->file
            subdataWithRange:NSMakeRange(entry->bodyOffset + at, chunk)]];
        [pool release];
        at += chunk;
    }
    if (whole)
        [writer commit];
    else
        [writer abandon];
    [writer release];
}

/* RFC 9111 §4.4. A request that changed something at the origin makes whatever is
 * stored for that URI wrong, and the response to it does not say what the new
 * representation is — only that the old one is no longer it. Location and
 * Content-Location go too, but only when they name the same host: otherwise a
 * server could empty this cache of any URI it cared to name. */
static void invalidateCacheForRequest(NSURLRequest *request, NSDictionary *headers, NSInteger status)
{
    if (!gCacheDirectory || status >= 400)
        return;
    NSString *method = [request HTTPMethod] ?: @"GET";
    if ([method caseInsensitiveCompare:@"GET"] == NSOrderedSame
        || [method caseInsensitiveCompare:@"HEAD"] == NSOrderedSame
        || [method caseInsensitiveCompare:@"OPTIONS"] == NSOrderedSame
        || [method caseInsensitiveCompare:@"TRACE"] == NSOrderedSame)
        return;

    NSURL *url = [request URL];
    removeCacheEntry(cacheKeyForRequest(request));

    NSString *names[] = { @"Location", @"Content-Location" };
    for (size_t at = 0; at < sizeof(names) / sizeof(names[0]); at++) {
        NSString *value = headerValue(headers, names[at]);
        if (![value length])
            continue;
        NSURL *target = [NSURL URLWithString:value relativeToURL:url];
        if (target && [[target host] caseInsensitiveCompare:[url host]] == NSOrderedSame)
            removeCacheEntry(cacheKeyForURL(target));
    }
}

/* ------------------------------------------- the app-shell policy (not RFC 9111) */

/* Everything above this line is RFC 9111 and serves nothing stale. Nothing below
 * it is, and that is not a bug in the cache — it is a policy, off by default,
 * that a wrapped application turns on for its own origins.
 *
 * This engine exists to wrap a web application so that it behaves like a native
 * one, and such an application is two things that age at very different speeds.
 * There is a shell — the document, and the scripts, styles and fonts that draw
 * the interface — which changes when the operator ships a release. And there is
 * data, which changes every minute. HTTP has one freshness model for both, so in
 * practice the shell arrives marked no-cache, or with a max-age of a few minutes,
 * and every launch pays a revalidation round trip before the first pixel. On this
 * device, over a phone network, that round trip is most of the time to first
 * paint — and it almost always ends in a 304 saying the shell has not changed.
 *
 * The web's answer to this is a Service Worker running a cache-first strategy.
 * WebKitLegacy has no Service Worker, so the strategy has to live here, in the
 * one place that sees every request. What it does is what a cache-first Service
 * Worker does and no more: a stored shell response is handed over immediately,
 * however stale HTTP considers it, and a revalidation is started behind the page
 * so that the next launch is current.
 *
 * Four things keep this from being a cache that is simply wrong:
 *
 *   - It is off. The embedder has to turn it on and name the hosts its
 *     application is made of. An unconfigured build behaves exactly as it did.
 *   - It is narrow. Only requests classified as shell are served this way, and
 *     the classifier below refuses anything it cannot positively identify. Data
 *     is never served from it: a chat client showing yesterday's messages
 *     instantly is worse than one that waits.
 *   - It is bounded. Past kShellMaxStale the stored copy is not used at all and
 *     the request goes to the network like any other.
 *   - It says so. Every response it serves is logged as a policy decision rather
 *     than as a cache hit, under [shell] rather than [cache].
 *
 * What is *stored* is untouched by any of this: storage stays RFC 9111
 * throughout, so a response the origin said not to keep is still not kept, and
 * turning the policy off restores standard behaviour on the spot — there is no
 * separate store to flush, only a rule that stops being applied. */

/* How stale a shell response may be and still be served without asking. A month
 * is not acceptable and neither is a day.
 *
 * The number does not describe the staleness this policy normally produces. Every
 * cache-first hit queues a revalidation, so an application opened even once a week
 * is refreshed by that launch and the next one starts from a current shell: the
 * steady state is one launch behind, not seven days behind. What this bound
 * describes is the worst case — the application that has not been opened for a
 * long time — and what it costs to be wrong there.
 *
 * Too short, and the policy stops paying for itself: at a day, a user who opens
 * the application every morning waits for the network every morning, which is the
 * round trip this exists to remove. Too long, and the operator loses control of
 * what is running on the device: a shell served from here cannot be revoked any
 * faster than this bound, so it is also how long a bad release can keep painting.
 * A week is the outside edge of "ship a fix and expect it live", and it means the
 * only launches that ever wait are the ones after a real absence — where the user
 * is not comparing this launch against yesterday's anyway.
 *
 * It is deliberately longer than kHeuristicCeiling. That one bounds how wrong a
 * *guess* about an origin's intent may be, and a day is generous for a guess.
 * This one bounds a decision that was made on purpose. */
static const NSTimeInterval kShellMaxStale = 7 * 86400.0;

/* Revalidations do not run while the page is loading. The device has two slow
 * cores and a hard memory ceiling, and a burst of background requests during the
 * load would spend exactly the time the policy just saved — the round trip would
 * not be on the critical path any more, it would simply be next to it, competing
 * for the same cores, the same sockets and the same jetsam budget.
 *
 * So a hit queues its revalidation and nothing else. The queue drains on one
 * serial background queue, one request at a time, and only once the foreground
 * has been quiet for kShellQuietPeriod — no request started, finished or failed.
 * Two seconds is long enough that a normal subresource chain has ended (each
 * response WebKit gets tends to produce the next request within a few hundred
 * milliseconds) and short enough to still be inside the launch, which is the only
 * time a wrapped application is reliably running at all.
 *
 * Quiet is measured from request boundaries, so a single very long transfer can
 * look quiet while it is still streaming. That is accepted rather than fixed: the
 * cost of being wrong is one background request at background priority, which is
 * the same bound the policy accepts everywhere else. */
static const NSTimeInterval kShellQuietPeriod = 2.0;
/* If the foreground never goes quiet — a page that polls, say — revalidations
 * cannot simply never run, or the cache would never move forward. After this long
 * the queue drains anyway, still one at a time and still at background priority. */
static const NSTimeInterval kShellQuietDeadline = 30.0;
/* A gap between revalidations, so that a drained queue is a trickle rather than a
 * second page load. */
static const NSTimeInterval kShellRevalidateGap = 0.25;
/* A shell is tens of resources, not hundreds. Anything past this is either not a
 * shell or not worth the battery, and the next launch will queue it again. */
static const NSUInteger kShellQueueLimit = 64;

/* Written by the embedder before any load and read on every request. gShellHosts
 * being nil is what says the policy is off — enabling it without naming hosts is
 * not possible, because a cache-first rule for the whole internet is not a policy,
 * it is a broken cache. */
static pthread_mutex_t gShellMutex = PTHREAD_MUTEX_INITIALIZER;
static BOOL gShellCacheFirst;
static NSSet *gShellHosts;              /* lower-cased host names */
static NSMutableSet *gShellDeclared;    /* cache keys the embedder called shell outright */
static NSMutableArray *gShellPending;   /* NSURLRequests waiting to be revalidated */
static NSMutableSet *gShellInFlight;    /* their keys, so one URL is queued once */
static BOOL gShellDraining;
static dispatch_queue_t gShellRunner;
static NSTimeInterval gShellForegroundAt;
static NSString *gShellUserAgent;       /* the last one WebKit sent; see +precacheURLs: */

/* The client a background revalidation is given. NSURLProtocol requires one and
 * this policy has nobody to answer: the point of the fetch is the file it leaves
 * behind, not the bytes it produces. Everything is dropped on the floor, which is
 * also why -onClientThread:with: calls straight through for a background load
 * instead of hopping to a run loop nobody is running. */
@interface ModernTLSDiscardedClient : NSObject <NSURLProtocolClient>
@end

@implementation ModernTLSDiscardedClient
- (void)URLProtocol:(NSURLProtocol *)p wasRedirectedToRequest:(NSURLRequest *)r
    redirectResponse:(NSURLResponse *)response {}
- (void)URLProtocol:(NSURLProtocol *)p cachedResponseIsValid:(NSCachedURLResponse *)c {}
- (void)URLProtocol:(NSURLProtocol *)p didReceiveResponse:(NSURLResponse *)response
    cacheStoragePolicy:(NSURLCacheStoragePolicy)policy {}
- (void)URLProtocol:(NSURLProtocol *)p didLoadData:(NSData *)data {}
- (void)URLProtocolDidFinishLoading:(NSURLProtocol *)p {}
- (void)URLProtocol:(NSURLProtocol *)p didFailWithError:(NSError *)error {}
- (void)URLProtocol:(NSURLProtocol *)p
    didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)c {}
- (void)URLProtocol:(NSURLProtocol *)p
    didCancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)c {}
@end

@interface ModernTLSURLProtocol (ModernTLSShellPolicy)
+ (void)runShellRequest:(NSURLRequest *)request;
@end

/* Every foreground request pushes the quiet window out. Called at the start of a
 * load and at each of the three ways one ends. */
static void shellNoteForegroundActivity(void)
{
    /* Read without the lock: it is written once, before any load, and a stale
     * read of NO only means the bookkeeping below is skipped while the policy is
     * off — which is precisely when it does not matter. */
    if (!gShellCacheFirst)
        return;
    pthread_mutex_lock(&gShellMutex);
    gShellForegroundAt = nowSeconds();
    pthread_mutex_unlock(&gShellMutex);
}

/* WebKit's own word for what a request is for. WebCore sets Sec-Fetch-Dest on
 * every request from a trustworthy origin — which is every request that reaches
 * this file, since it only takes https — from the Fetch destination of the load:
 * "document", "iframe", "style", "script", "font", "image", "json", and "empty"
 * for XMLHttpRequest and fetch(). See CachedResourceLoader::updateHTTPRequestHeaders.
 * That is the distinction this policy needs, made by the code that actually knows
 * the answer, and it is why the shell can be told from the data at all.
 *
 * It can be missing: a site on the quirks list has the header suppressed, and a
 * frame with no document yet is not given one either. Two weaker signals stand in.
 * Accept is set per resource type by CachedResourceRequest::acceptHeaderValueFromType
 * and is unambiguous for exactly two of them — a document and a stylesheet;
 * scripts and XHR are both given the same catch-all and cannot be told apart by
 * it, so nothing is guessed from that. mainDocumentURL is WebKit's first-party-for-cookies URL,
 * which for a top-level navigation is the request's own URL.
 *
 * Answers nil for anything it cannot name, and nil is not shell. */
static NSString *shellDestinationForRequest(NSURLRequest *request, NSDictionary *wire)
{
    NSString *destination = headerValue(wire, @"Sec-Fetch-Dest");
    if ([destination length])
        return [destination lowercaseString];

    NSString *accept = headerValue(wire, @"Accept");
    if ([accept hasPrefix:@"text/html,"])
        return @"document";
    if ([accept hasPrefix:@"text/css,"])
        return @"style";

    NSURL *first = [request mainDocumentURL];
    if (first && [[first absoluteString] isEqualToString:[[request URL] absoluteString]])
        return @"document";
    return nil;
}

/* Whether the response that is stored is the kind of thing the request said it
 * was asking for. Both halves have to agree before anything stale is served.
 *
 * This is the check that keeps data out. An XMLHttpRequest is "empty" and matches
 * nothing here whatever it fetched, so an HTML fragment pulled in by script is not
 * a document as far as this is concerned. And a destination cannot be taken at its
 * word either: a "script" whose stored response is application/json is a JSON
 * document loaded through a script tag or mislabelled by the origin, and it is not
 * served stale. Nothing is admitted on one signal alone. */
static BOOL shellEntryMatchesDestination(NSString *destination, ModernTLSCacheEntry *entry)
{
    NSString *type = headerValue(entry->headers, @"Content-Type");
    if (![type length])
        return NO;                      /* nothing to check against */
    NSRange parameters = [type rangeOfString:@";"];
    if (parameters.location != NSNotFound)
        type = [type substringToIndex:parameters.location];
    type = [[type stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];

    if ([destination isEqualToString:@"document"] || [destination isEqualToString:@"iframe"])
        return [type isEqualToString:@"text/html"] || [type isEqualToString:@"application/xhtml+xml"];

    if ([destination isEqualToString:@"style"])
        return [type isEqualToString:@"text/css"];

    if ([destination isEqualToString:@"script"]) {
        static NSArray *scripts;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            scripts = [[NSArray alloc] initWithObjects:@"text/javascript", @"application/javascript",
                @"application/x-javascript", @"text/ecmascript", @"application/ecmascript", nil];
        });
        return [scripts containsObject:type];
    }

    if ([destination isEqualToString:@"font"])
        return [type hasPrefix:@"font/"] || [type isEqualToString:@"application/font-woff"]
            || [type isEqualToString:@"application/x-font-woff"]
            || [type isEqualToString:@"application/font-sfnt"]
            || [type isEqualToString:@"application/vnd.ms-fontobject"];

    /* Everything else — image, media, manifest, json, empty, and whatever the
     * Fetch spec adds next — is not shell. Images are left out on purpose: an
     * avatar or a piece of album art is data wearing a picture's clothes, and the
     * ones that really are shell are almost always served under a versioned URL,
     * where RFC 9111 already answers them from disk without any of this. */
    return NO;
}

/* The whole of the decision, in one place, for an entry that has already been
 * matched to this request by Vary. */
static BOOL shellPolicyAppliesTo(NSURLRequest *request, NSDictionary *wire,
    ModernTLSCacheEntry *entry, NSString *key)
{
    if (!gShellCacheFirst)
        return NO;

    NSString *host = [[[request URL] host] lowercaseString];
    if (![host length])
        return NO;

    pthread_mutex_lock(&gShellMutex);
    BOOL ours = [gShellHosts containsObject:host];
    BOOL declared = [gShellDeclared containsObject:key];
    pthread_mutex_unlock(&gShellMutex);
    if (!ours)
        return NO;

    if (!declared && !shellEntryMatchesDestination(shellDestinationForRequest(request, wire), entry))
        return NO;

    /* The bound. Past it the policy stops applying and the request is answered by
     * the rules above, which is to say by revalidating or by fetching. */
    return entryAge(entry) <= kShellMaxStale;
}

static void shellWaitForQuiet(void)
{
    NSTimeInterval deadline = nowSeconds() + kShellQuietDeadline;
    for (;;) {
        pthread_mutex_lock(&gShellMutex);
        NSTimeInterval last = gShellForegroundAt;
        pthread_mutex_unlock(&gShellMutex);
        NSTimeInterval now = nowSeconds();
        if (now - last >= kShellQuietPeriod || now >= deadline)
            return;
        [NSThread sleepForTimeInterval:0.25];
    }
}

/* Runs on gShellRunner, which is serial, so there is never more than one of these
 * in the air: one socket, one handshake, one body, against a foreground that has
 * already said it is finished. */
static void shellDrain(void)
{
    for (;;) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSURLRequest *next = nil;
        pthread_mutex_lock(&gShellMutex);
        if ([gShellPending count]) {
            next = [[gShellPending objectAtIndex:0] retain];
            [gShellPending removeObjectAtIndex:0];
        } else {
            gShellDraining = NO;
        }
        pthread_mutex_unlock(&gShellMutex);

        if (!next) {
            [pool release];
            return;
        }

        shellWaitForQuiet();
        if (gLog)
            fprintf(stderr, "[shell] revalidating %s in the background\n",
                [[[next URL] absoluteString] UTF8String]);
        [ModernTLSURLProtocol runShellRequest:next];

        pthread_mutex_lock(&gShellMutex);
        [gShellInFlight removeObject:cacheKeyForRequest(next)];
        pthread_mutex_unlock(&gShellMutex);
        [next release];
        [pool release];
        [NSThread sleepForTimeInterval:kShellRevalidateGap];
    }
}

/* Called with the lock held. */
static void shellStartDrainingLocked(void)
{
    if (gShellDraining || ![gShellPending count])
        return;
    if (!gShellRunner) {
        gShellRunner = dispatch_queue_create("modern-tls-shell", NULL);
        dispatch_set_target_queue(gShellRunner,
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    }
    gShellDraining = YES;
    dispatch_async(gShellRunner, ^{ shellDrain(); });
}

/* Queues the revalidation that pays for the stale response just served. The
 * request is rebuilt rather than reused so that the conditional headers this
 * cache may add are not carried over, and so that it can be given the one cache
 * policy that means "ask the origin, whatever you have on disk". Everything else
 * WebKit sent — the user agent, Accept, Accept-Language, Sec-Fetch-Dest — is
 * copied verbatim, because those are the fields an origin varies on and a
 * revalidation made under a different set of them would store a variant that the
 * next real request misses. */
static void shellQueueRevalidation(NSURLRequest *request, NSString *key)
{
    NSMutableURLRequest *refresh = [[[NSMutableURLRequest alloc] initWithURL:[request URL]] autorelease];
    [refresh setHTTPMethod:@"GET"];
    [refresh setMainDocumentURL:[request mainDocumentURL]];
    [refresh setCachePolicy:NSURLRequestReloadRevalidatingCacheData];
    NSDictionary *headers = [request allHTTPHeaderFields];
    for (NSString *field in headers) {
        if ([field caseInsensitiveCompare:@"If-None-Match"] == NSOrderedSame
            || [field caseInsensitiveCompare:@"If-Modified-Since"] == NSOrderedSame
            || [field caseInsensitiveCompare:@"If-Range"] == NSOrderedSame
            || [field caseInsensitiveCompare:@"Range"] == NSOrderedSame)
            continue;
        [refresh setValue:[headers objectForKey:field] forHTTPHeaderField:field];
    }

    pthread_mutex_lock(&gShellMutex);
    NSString *agent = [headers objectForKey:@"User-Agent"];
    if ([agent length] && ![agent isEqualToString:gShellUserAgent]) {
        [gShellUserAgent release];
        gShellUserAgent = [agent copy];
    }
    if ([gShellInFlight containsObject:key] || [gShellPending count] >= kShellQueueLimit) {
        pthread_mutex_unlock(&gShellMutex);
        return;
    }
    if (!gShellPending) {
        gShellPending = [[NSMutableArray alloc] init];
        gShellInFlight = [[NSMutableSet alloc] init];
    }
    [gShellPending addObject:refresh];
    [gShellInFlight addObject:key];
    shellStartDrainingLocked();
    pthread_mutex_unlock(&gShellMutex);
}

/* ------------------------------------------------------------------- requests */

/* -[NSURL path] hands back a percent-decoded path, which would put raw spaces and
 * other reserved characters into the request line; the escaped form is taken out
 * of the absolute string instead. */
static NSString *requestTarget(NSURL *url)
{
    NSString *text = [url absoluteString];
    NSRange separator = [text rangeOfString:@"://"];
    NSUInteger authority = separator.location == NSNotFound ? 0 : NSMaxRange(separator);
    NSRange rest = NSMakeRange(authority, [text length] - authority);

    NSRange slash = [text rangeOfString:@"/" options:0 range:rest];
    NSRange query = [text rangeOfString:@"?" options:0 range:rest];
    NSUInteger start = MIN(slash.location, query.location);
    if (start == NSNotFound)
        return @"/";

    NSString *target = [text substringFromIndex:start];
    NSRange fragment = [target rangeOfString:@"#"];
    if (fragment.location != NSNotFound)
        target = [target substringToIndex:fragment.location];
    if (![target hasPrefix:@"/"])
        target = [@"/" stringByAppendingString:target];
    return [target length] ? target : @"/";
}

/* Headers that describe this one hop rather than the message, and so are neither
 * forwarded from WebKit's request nor handed back in the response. */
static BOOL isHopByHop(NSString *field)
{
    static NSArray *names;
    static dispatch_once_t once;
    /* Requests run on several threads at a time, so this is built exactly once. */
    dispatch_once(&once, ^{
        names = [[NSArray alloc] initWithObjects:@"Connection", @"Keep-Alive", @"Transfer-Encoding",
            @"TE", @"Trailer", @"Upgrade", @"Proxy-Connection", @"Proxy-Authenticate", nil];
    });
    for (NSString *name in names) {
        if ([field caseInsensitiveCompare:name] == NSOrderedSame)
            return YES;
    }
    return NO;
}

typedef enum {
    ModernTLSExchangeReusable,    /* answered in full; the connection can serve another request */
    ModernTLSExchangeSpent,       /* finished with, one way or another; close it */
    ModernTLSExchangeUnanswered,  /* not one byte came back; the request can simply be sent again */
    ModernTLSExchangeMismatched   /* a 304 about a representation this cache does not hold */
} ModernTLSExchange;

typedef enum {
    ModernTLSFramingNone,
    ModernTLSFramingLength,
    ModernTLSFramingChunked,
    ModernTLSFramingUntilClose
} ModernTLSFraming;

@implementation ModernTLSURLProtocol {
    volatile BOOL _cancelled;
    NSThread *_clientThread;
    z_stream _inflater;
    BOOL _inflating;
    /* The cache's share of a request's state. _cacheKey being nil is what says
     * "this request has nothing to do with the cache" — every store below is
     * gated on it, so one check covers HEAD, Range, and a request that asked not
     * to be stored. */
    NSString *_cacheKey;
    NSMutableDictionary *_wireHeaders;
    ModernTLSCacheWriter *_writer;
    ModernTLSCacheEntry *_validating;
    NSTimeInterval _requestTime;
    /* A revalidation this file started for itself, with no client waiting on the
     * far end of it. See the app-shell policy section. */
    BOOL _background;
    BOOL _transcodingImage;
    NSMutableData *_imageBuffer;
    NSData *_requestBody;
    BOOL _requestBodyRead;
}

+ (BOOL)install
{
    NSString *authorities = [[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:authorities])
        return NO;
    gCertificateAuthorities = [authorities copy];
    gLog = getenv("MODERN_TLS_LOG") != NULL;

    SSL_library_init();
    SSL_load_error_strings();

    /* One context for the process. Reading and parsing 150-odd certificates is
     * work worth doing once, and the context is also what a resumable session is
     * attached to, so sharing it is what makes resumption possible at all. */
    gContext = SSL_CTX_new(TLS_client_method());
    if (!gContext)
        return NO;
    SSL_CTX_set_min_proto_version(gContext, TLS1_2_VERSION);
    SSL_CTX_set_cipher_list(gContext, "HIGH:!aNULL:!eNULL:!MD5:!RC4:!3DES:!EXPORT");
    SSL_CTX_set_ciphersuites(gContext, "TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256");
    SSL_CTX_set_verify(gContext, SSL_VERIFY_PEER, NULL);
    if (!SSL_CTX_load_verify_locations(gContext, [gCertificateAuthorities UTF8String], NULL)) {
        SSL_CTX_free(gContext);
        gContext = NULL;
        return NO;
    }
    /* Sessions are kept in gSessions, by host, so OpenSSL's own store is left out
     * of it — on a client it would only grow. */
    SSL_CTX_set_session_cache_mode(gContext, SSL_SESS_CACHE_CLIENT | SSL_SESS_CACHE_NO_INTERNAL_STORE);
    SSL_CTX_sess_set_new_cb(gContext, rememberSession);
    gHostSlot = SSL_get_ex_new_index(0, NULL, NULL, NULL, NULL);

    gIdleConnections = [[NSMutableDictionary alloc] init];
    gSessions = [[NSMutableDictionary alloc] init];

    /* A cache that cannot be opened is a cache that is not used, and that is all
     * it is: every request still works, each one just costs what it costs. It is
     * not a reason to refuse to install the protocol, which is what the return
     * value here means. */
    if (!installCache() && gLog)
        fprintf(stderr, "[cache] no cache directory; running without one\n");

    return [NSURLProtocol registerClass:self];
}

/* --------------------------------------------- the app-shell policy, configured */

/* See the long comment above shellDestinationForRequest() and the constants near
 * it: this is a deliberate departure from RFC 9111 and these four methods are the
 * whole of its surface. Until +setShellCacheFirstEnabled:forHosts: is called with
 * YES and a non-empty list, none of it runs. */

+ (void)setShellCacheFirstEnabled:(BOOL)enabled forHosts:(NSArray *)hosts
{
    NSMutableSet *named = [NSMutableSet set];
    for (NSString *host in hosts) {
        if ([host length])
            [named addObject:[host lowercaseString]];
    }
    pthread_mutex_lock(&gShellMutex);
    [gShellHosts release];
    gShellHosts = [named copy];
    /* Naming no hosts is the same as switching it off. There is no sensible
     * reading of "cache-first, everywhere". */
    gShellCacheFirst = enabled && [named count] > 0;
    pthread_mutex_unlock(&gShellMutex);
    if (gLog)
        fprintf(stderr, "[shell] cache-first %s for %lu host(s)\n",
            gShellCacheFirst ? "on" : "off", (unsigned long)[named count]);
}

+ (BOOL)shellCacheFirstEnabled
{
    return gShellCacheFirst;
}

+ (void)declareShellURLs:(NSArray *)urls
{
    pthread_mutex_lock(&gShellMutex);
    if (!gShellDeclared)
        gShellDeclared = [[NSMutableSet alloc] init];
    for (id url in urls) {
        NSURL *target = [url isKindOfClass:[NSURL class]] ? url : [NSURL URLWithString:url];
        if (target)
            [gShellDeclared addObject:cacheKeyForURL(target)];
    }
    pthread_mutex_unlock(&gShellMutex);
}

/* Warms the store, so that a packaged application can fetch its shell once at
 * install time and be instant on the first launch rather than the second.
 *
 * The requests go through the same serial background queue as the revalidations,
 * for the same reason: install time is not necessarily a quiet moment, and a
 * dozen simultaneous handshakes on two cores is not a warm-up, it is a stall.
 *
 * A URL already stored and inside the staleness bound is skipped outright — this
 * is idempotent, and calling it on every launch costs a directory lookup per URL
 * and nothing else. The requests carry the last user agent WebKit was seen to
 * send, if this process has seen one; an origin that varies on the user agent and
 * is precached before any page has loaded will store a variant that the first
 * real request then misses, which wastes the fetch but breaks nothing. */
+ (void)precacheURLs:(NSArray *)urls
{
    if (!gCacheDirectory)
        return;
    [self declareShellURLs:urls];

    pthread_mutex_lock(&gShellMutex);
    NSString *agent = [[gShellUserAgent retain] autorelease];
    pthread_mutex_unlock(&gShellMutex);

    for (id each in urls) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSURL *url = [each isKindOfClass:[NSURL class]] ? each : [NSURL URLWithString:each];
        if (!url || [[url scheme] caseInsensitiveCompare:@"https"] != NSOrderedSame) {
            [pool release];
            continue;
        }
        NSString *key = cacheKeyForURL(url);
        NSString *path = cachePathForKey(key);
        ModernTLSCacheEntry *entry = path ? readCacheEntry(path, key) : nil;
        if (entry && entryAge(entry) <= kShellMaxStale) {
            [pool release];
            continue;
        }
        NSMutableURLRequest *request = [[[NSMutableURLRequest alloc] initWithURL:url] autorelease];
        [request setHTTPMethod:@"GET"];
        [request setMainDocumentURL:url];
        if ([agent length])
            [request setValue:agent forHTTPHeaderField:@"User-Agent"];

        pthread_mutex_lock(&gShellMutex);
        if (![gShellInFlight containsObject:key] && [gShellPending count] < kShellQueueLimit) {
            if (!gShellPending) {
                gShellPending = [[NSMutableArray alloc] init];
                gShellInFlight = [[NSMutableSet alloc] init];
            }
            [gShellPending addObject:request];
            [gShellInFlight addObject:key];
            shellStartDrainingLocked();
        }
        pthread_mutex_unlock(&gShellMutex);
        [pool release];
    }
}

/* Drives one request to completion with nobody listening, on the calling thread.
 * The whole of the ordinary path runs — the pool, the handshake, the conditional,
 * the 304 merge, the store — and only the delivery is thrown away, which is what
 * makes a background revalidation and a foreground load the same code rather than
 * a second implementation that can drift from it. */
+ (void)runShellRequest:(NSURLRequest *)request
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    ModernTLSDiscardedClient *sink = [[ModernTLSDiscardedClient alloc] init];
    ModernTLSURLProtocol *protocol = [[self alloc] initWithRequest:request
        cachedResponse:nil client:sink];
    protocol->_background = YES;
    /* Released in -dealloc like any other; nothing is ever sent to it. */
    protocol->_clientThread = [[NSThread currentThread] retain];
    [protocol performRequest:request];
    [protocol release];
    [sink release];
    [pool release];
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    if ([NSURLProtocol propertyForKey:kHandledKey inRequest:request])
        return NO;
    return [[[request URL] scheme] caseInsensitiveCompare:@"https"] == NSOrderedSame;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}

- (void)startLoading
{
    {
        static unsigned started;
        static double firstStart;
        double now = nowSeconds();
        if (!firstStart)
            firstStart = now;
        started++;
        NSURL *u = [[self request] URL];
        fprintf(stderr, "[net] #%u %.2fs %s %s%s\n", started, now - firstStart,
            [[[self request] HTTPMethod] UTF8String] ?: "?",
            [[u host] UTF8String] ?: "?", [[u path] UTF8String] ?: "");
    }

    /* NSURLProtocol's client must be told about the load on the thread that
     * started it. Answering from the network thread loses callbacks. */
    _clientThread = [[NSThread currentThread] retain];

    NSMutableURLRequest *request = [[self request] mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:request];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        [self performRequest:request];
        [request release];
        [pool release];
    });
}

- (void)dealloc
{
    /* Not in -stopLoading: a delivery scheduled from the network thread may still
     * be on its way to this thread when the load is cancelled. */
    [_clientThread release];
    if (_inflating)
        inflateEnd(&_inflater);
    /* A load cancelled mid-body leaves a half-written entry, which -abandon
     * removes. Committing it would store a truncated representation under a key
     * that reads back as a whole one. */
    [_writer abandon];
    [_writer release];
    [_validating release];
    [_cacheKey release];
    [_wireHeaders release];
    [_imageBuffer release];
    [_requestBody release];
    [super dealloc];
}

- (void)onClientThread:(SEL)selector with:(id)argument
{
    if (_cancelled)
        return;
    /* A background revalidation is not answering anybody: its client drops
     * everything, and the thread it was started on is inside -performRequest:
     * rather than running a run loop. Hopping there would queue every chunk of
     * every body until the load finished, which on this device is the one cost
     * this whole policy exists to avoid paying. */
    if (_background) {
        [self performSelector:selector withObject:argument];
        return;
    }
    [self performSelector:selector onThread:_clientThread withObject:argument
        waitUntilDone:NO modes:[NSArray arrayWithObjects:NSRunLoopCommonModes, nil]];
}

/* The -deliver methods below all run on the client thread, and so does
 * -stopLoading, which is what makes testing _cancelled here — after the hop, not
 * only before it — enough to stop talking to a client that has gone. */

- (void)deliverResponse:(NSHTTPURLResponse *)response
{
    if (_cancelled)
        return;
    {
        static BOOL first;
        if (!first) {
            first = YES;
            FILE *log = fopen("/tmp/native.log", "a");
            if (log) {
                fprintf(log, "%.3f [start] first byte of %s\n", CFAbsoluteTimeGetCurrent(),
                    [[[response URL] absoluteString] UTF8String] ?: "?");
                fclose(log);
            }
        }
    }
    if ([response statusCode] >= 400) {
        NSURLRequest *sent = [self request];
        NSURL *url = [response URL];
        fprintf(stderr, "[net] HTTP %ld %s %s%s\n", (long)[response statusCode],
            [[sent HTTPMethod] UTF8String] ?: "?",
            [[url host] UTF8String] ?: "?",
            [[url path] UTF8String] ?: "");
        NSDictionary *sentHeaders = [sent allHTTPHeaderFields];
        for (NSString *name in sentHeaders)
            fprintf(stderr, "[net]   > %s: %s\n", [name UTF8String],
                [[sentHeaders objectForKey:name] UTF8String] ?: "");
        NSData *body = [sent HTTPBody];
        if (body) {
            NSString *text = [[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] autorelease];
            fprintf(stderr, "[net]   > body(%u): %s\n", (unsigned)[body length],
                [[text substringToIndex:MIN((NSUInteger)300, [text length])] UTF8String] ?: "?");
        } else if ([sent HTTPBodyStream])
            fprintf(stderr, "[net]   > body: stream\n");
        else
            fprintf(stderr, "[net]   > body: none\n");
        NSDictionary *got = [response allHeaderFields];
        for (NSString *name in got)
            fprintf(stderr, "[net]   < %s: %s\n", [name UTF8String],
                [[[got objectForKey:name] description] UTF8String] ?: "");
    }
    [[self client] URLProtocol:self didReceiveResponse:response
        cacheStoragePolicy:NSURLCacheStorageAllowed];
}

- (void)deliverData:(NSData *)data
{
    if (_cancelled)
        return;
    [[self client] URLProtocol:self didLoadData:data];
}

- (void)deliverFinish:(id)ignored
{
    if (!_background)
        shellNoteForegroundActivity();
    if (_cancelled)
        return;
    [[self client] URLProtocolDidFinishLoading:self];
}

- (void)deliverRedirect:(NSArray *)pair
{
    if (!_background)
        shellNoteForegroundActivity();
    if (_cancelled)
        return;
    [[self client] URLProtocol:self wasRedirectedToRequest:[pair objectAtIndex:0]
        redirectResponse:[pair objectAtIndex:1]];
}

- (void)deliverError:(NSError *)error
{
    if (!_background)
        shellNoteForegroundActivity();
    if (_cancelled)
        return;
    NSURL *url = [[self request] URL];
    fprintf(stderr, "[net] FAIL %s %s%s code %ld: %s\n",
        [[[self request] HTTPMethod] UTF8String] ?: "?",
        [[url host] UTF8String] ?: "?",
        [[url path] UTF8String] ?: "",
        (long)[error code],
        [[error localizedDescription] UTF8String] ?: "?");
    [[self client] URLProtocol:self didFailWithError:error];
}

- (void)stopLoading
{
    _cancelled = YES;
}

- (void)failWithMessage:(NSString *)message code:(NSInteger)code
{
    NSDictionary *info = [NSDictionary dictionaryWithObject:message ?: @"Load failed"
        forKey:NSLocalizedDescriptionKey];
    [self onClientThread:@selector(deliverError:)
        with:[NSError errorWithDomain:NSURLErrorDomain code:code userInfo:info]];
}

/* ------------------------------------------------------------------ the body */

/* Content-Encoding is undone as the body arrives, so the decoded bytes reach
 * WebKit in the same shape and at the same time the encoded ones reach us, and
 * neither form is ever held whole. */
/* The one place decoded bytes exist. WebKit gets them and, if this response is
 * being kept, so does the file — written as it passes rather than assembled,
 * which is what lets an entry be stored without ever holding one. */
- (void)emitDecoded:(NSData *)data
{
    if (![data length])
        return;
    if (_transcodingImage) {
        [_imageBuffer appendData:data];
        return;
    }
    if (_writer && ![_writer appendBody:data]) {
        /* Past the per-entry limit, or the write failed. Delivery is unaffected;
         * only the stored copy is given up, and whole is the only way to give it
         * up — a body missing its tail is not a shorter body. */
        [_writer abandon];
        [_writer release];
        _writer = nil;
    }
    [self onClientThread:@selector(deliverData:) with:data];
}

- (BOOL)emitRaw:(NSData *)data
{
    if (!_inflating) {
        [self emitDecoded:data];
        return YES;
    }

    _inflater.next_in = (Bytef *)[data bytes];
    _inflater.avail_in = (uInt)[data length];

    unsigned char out[16384];
    int status;
    do {
        _inflater.next_out = out;
        _inflater.avail_out = sizeof(out);
        status = inflate(&_inflater, Z_NO_FLUSH);
        if (status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR) {
            if (gLog)
                fprintf(stderr, "[tls]   inflate failed: %d (%s)\n", status, _inflater.msg ?: "");
            return NO;
        }
        NSUInteger produced = sizeof(out) - _inflater.avail_out;
        if (produced)
            [self emitDecoded:[NSData dataWithBytes:out length:produced]];
    } while (status == Z_OK && (_inflater.avail_in || !_inflater.avail_out));

    return YES;
}

/* One chunk: read, handed on, and released inside its own pool. Streaming is only
 * worth doing if the body is never held whole, and a pool that lives as long as
 * the request would hold every chunk of it to the end. Answers the number of
 * bytes taken off the connection, kEnded at the end of the data, or kUndecodable
 * when the content coding gave out. */
static const NSInteger kEnded = -1;
static const NSInteger kUndecodable = -2;

- (NSInteger)pumpFrom:(ModernTLSConnection *)connection limit:(NSUInteger)limit deliver:(BOOL)deliver
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSData *chunk = [connection readUpTo:limit];
    NSInteger taken = kEnded;
    if (chunk) {
        taken = (NSInteger)[chunk length];
        if (deliver && ![self emitRaw:chunk])
            taken = kUndecodable;
    }
    [pool release];
    return taken;
}

/* Reads exactly as much as the framing says the body is, delivering as it goes,
 * and answers whether the whole of it arrived. deliver:NO is the redirect case:
 * the bytes are only read so that the connection can be kept. */
- (BOOL)readBodyFrom:(ModernTLSConnection *)connection
             framing:(ModernTLSFraming)framing
              length:(unsigned long long)length
             deliver:(BOOL)deliver
{
    if (framing == ModernTLSFramingNone)
        return YES;
    if (!deliver && (framing == ModernTLSFramingUntilClose || length > kDrainLimit))
        return NO;

    if (framing == ModernTLSFramingLength) {
        while (length) {
            if (_cancelled)
                return NO;
            NSInteger taken = [self pumpFrom:connection
                limit:(NSUInteger)MIN(length, (unsigned long long)65536) deliver:deliver];
            if (taken < 0)
                return NO;
            length -= taken;
        }
        return YES;
    }

    if (framing == ModernTLSFramingChunked) {
        char line[512];
        unsigned long long drained = 0;
        for (;;) {
            if (_cancelled)
                return NO;
            if (![connection readLine:line size:sizeof(line)])
                return NO;
            /* strtoull stops at the semicolon of a chunk extension by itself. */
            unsigned long long size = strtoull(line, NULL, 16);
            if (!size)
                break;
            drained += size;
            if (!deliver && drained > kDrainLimit)
                return NO;
            while (size) {
                NSInteger taken = [self pumpFrom:connection
                    limit:(NSUInteger)MIN(size, (unsigned long long)65536) deliver:deliver];
                if (taken < 0)
                    return NO;
                size -= taken;
            }
            /* The CRLF that closes the chunk. */
            if (![connection readLine:line size:sizeof(line)])
                return NO;
        }
        /* Trailers, to the empty line that ends the message. */
        for (int field = 0; field < 64; field++) {
            if (![connection readLine:line size:sizeof(line)])
                return NO;
            if (!line[0])
                return YES;
        }
        return NO;
    }

    /* No length and no chunking: the close is the framing, so the connection is
     * spent whatever happens. */
    for (;;) {
        if (_cancelled)
            return NO;
        NSInteger taken = [self pumpFrom:connection limit:65536 deliver:deliver];
        if (taken == kEnded)
            return YES;
        if (taken < 0)
            return NO;
    }
}

/* --------------------------------------------------------------- the exchange */

/* The header fields as they actually go out, built before they are serialised so
 * that something other than the socket can read them. Vary is matched against
 * this rather than against WebKit's request, because what the server saw
 * included the Cookie and the Accept-Encoding this protocol added and WebKit
 * knows nothing about. */
- (NSMutableDictionary *)wireHeadersFor:(NSURLRequest *)request
{
    NSURL *url = [request URL];
    NSString *authority = [url port]
        ? [NSString stringWithFormat:@"%@:%@", [url host], [url port]] : [url host];

    NSMutableDictionary *wire = [NSMutableDictionary dictionary];
    [wire setObject:authority ?: @"" forKey:@"Host"];
    [wire setObject:@"keep-alive" forKey:@"Connection"];
    [wire setObject:@"gzip" forKey:@"Accept-Encoding"];

    NSDictionary *headers = [request allHTTPHeaderFields];
    for (NSString *field in headers) {
        if ([field caseInsensitiveCompare:@"Host"] == NSOrderedSame
            || [field caseInsensitiveCompare:@"Accept-Encoding"] == NSOrderedSame
            || [field caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame
            || isHopByHop(field))
            continue;
        [wire setObject:[headers objectForKey:field] forKey:field];
    }

    NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:url];
    NSString *cookieHeader = [[NSHTTPCookie requestHeaderFieldsWithCookies:cookies] objectForKey:@"Cookie"];
    if ([cookieHeader length])
        [wire setObject:cookieHeader forKey:@"Cookie"];

    NSData *body = [self bodyForRequest:request];
    /* A request with a body says so even when it is empty, or the server waits for
     * one that never comes. */
    if (body)
        [wire setObject:[NSString stringWithFormat:@"%lu", (unsigned long)[body length]]
            forKey:@"Content-Length"];
    return wire;
}

static NSData *collectRequestBody(NSURLRequest *request)
{
    NSData *body = [request HTTPBody];
    if (body)
        return body;

    NSInputStream *stream = [request HTTPBodyStream];
    if (!stream)
        return nil;

    NSMutableData *collected = [NSMutableData data];
    [stream open];
    uint8_t buffer[8192];
    for (;;) {
        NSInteger got = [stream read:buffer maxLength:sizeof(buffer)];
        if (got <= 0)
            break;
        [collected appendBytes:buffer length:(NSUInteger)got];
    }
    [stream close];
    return collected;
}

- (NSData *)bodyForRequest:(NSURLRequest *)request
{
    if (!_requestBodyRead) {
        _requestBodyRead = YES;
        _requestBody = [collectRequestBody(request) retain];
    }
    return _requestBody;
}

- (NSData *)messageForRequest:(NSURLRequest *)request target:(NSString *)target
                      headers:(NSDictionary *)wire
{
    NSMutableString *head = [NSMutableString stringWithFormat:@"%@ %@ HTTP/1.1\r\n",
        [request HTTPMethod] ?: @"GET", target];
    /* Host first because RFC 9110 §7.2 asks for it; the rest in whatever order the
     * dictionary offers, which is allowed — order matters only between repeats of
     * one field name, and there are none here. */
    [head appendFormat:@"Host: %@\r\n", [wire objectForKey:@"Host"]];
    for (NSString *field in wire) {
        if ([field caseInsensitiveCompare:@"Host"] == NSOrderedSame)
            continue;
        [head appendFormat:@"%@: %@\r\n", field, [wire objectForKey:field]];
    }
    [head appendString:@"\r\n"];

    NSMutableData *message = [NSMutableData dataWithData:[head dataUsingEncoding:NSUTF8StringEncoding]];
    /* One write, so head and body travel in the same segment where they fit. */
    NSData *body = [self bodyForRequest:request];
    if ([body length])
        [message appendData:body];
    return message;
}

/* WebKit is told what a redirected request should look like; the rules for what
 * survives a redirect are the browser's, not the server's. */
- (NSMutableURLRequest *)redirectedRequestTo:(NSURL *)target status:(NSInteger)status
{
    NSMutableURLRequest *next = [[[self request] mutableCopy] autorelease];
    [next setURL:target];
    [NSURLProtocol removePropertyForKey:kHandledKey inRequest:next];

    NSString *method = [next HTTPMethod] ?: @"GET";
    BOOL unsafe = [method caseInsensitiveCompare:@"GET"] != NSOrderedSame
        && [method caseInsensitiveCompare:@"HEAD"] != NSOrderedSame;
    if (status == 303 || ((status == 301 || status == 302) && unsafe)) {
        [next setHTTPMethod:@"GET"];
        [next setHTTPBody:nil];
        [next setValue:nil forHTTPHeaderField:@"Content-Type"];
    }
    return next;
}


/* ------------------------------------------------------------ from the cache */

/* Hands a stored response to WebKit exactly as the network path would have, and
 * answers whether it could. The bytes come out of a mapping in sixty-four
 * kilobyte pieces rather than in one, so a large entry is never resident whole
 * on the way past and the client thread can release each piece as it takes it. */
- (BOOL)deliverEntry:(ModernTLSCacheEntry *)entry
{
    NSURL *url = [[self request] URL];
    NSHTTPURLResponse *response = [[[NSHTTPURLResponse alloc] initWithURL:url
        statusCode:entry->status HTTPVersion:@"HTTP/1.1" headerFields:entry->headers] autorelease];
    if (!response)
        return NO;

    NSString *location = headerValue(entry->headers, @"Location");
    if (entry->status >= 300 && entry->status < 400 && [location length]) {
        NSURL *target = [NSURL URLWithString:location relativeToURL:url];
        if (!target)
            return NO;
        [self onClientThread:@selector(deliverRedirect:) with:[NSArray arrayWithObjects:
            [self redirectedRequestTo:target status:entry->status], response, nil]];
        return YES;
    }

    /* Least-recently-used, kept current with one syscall against a file that is
     * not otherwise touched. Doing this before the delivery rather than after
     * means an entry counts as used even if the load is cancelled mid-body. */
    utimes([entry->path fileSystemRepresentation], NULL);

    [self onClientThread:@selector(deliverResponse:) with:response];
    for (NSUInteger at = 0; at < entry->bodyLength; ) {
        if (_cancelled)
            return YES;
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSUInteger chunk = MIN(entry->bodyLength - at, (NSUInteger)65536);
        [self onClientThread:@selector(deliverData:)
            with:[entry->file subdataWithRange:NSMakeRange(entry->bodyOffset + at, chunk)]];
        [pool release];
        at += chunk;
    }
    [self onClientThread:@selector(deliverFinish:) with:nil];
    return YES;
}

/* Decides what the cache has to say about this request, before anything is
 * dialled. Answers YES when the request has been answered in full from disk —
 * which is the whole point of the file: no socket, no handshake, no round trip.
 * Otherwise it may still have arranged for the request that follows to be a
 * conditional one, and left _validating holding the entry that conditional is
 * about. */
- (BOOL)answerFromCache:(NSURLRequest *)request wire:(NSMutableDictionary *)wire
{
    if (!gCacheDirectory)
        return NO;
    /* Only GET is stored, so only GET can be answered, and leaving _cacheKey nil
     * is also what keeps the store path below from ever seeing a HEAD — whose
     * Content-Length describes a body it does not carry. */
    if ([([request HTTPMethod] ?: @"GET") caseInsensitiveCompare:@"GET"] != NSOrderedSame)
        return NO;
    /* A request WebKit has already made conditional is WebKit revalidating its own
     * memory cache against the origin. Answering that from here, or adding a
     * second validator to it, would be answering a question nobody asked. A Range
     * request is not answerable from an entry that holds whole representations. */
    if (headerValue(wire, @"If-None-Match") || headerValue(wire, @"If-Modified-Since")
        || headerValue(wire, @"Range"))
        return NO;

    NSDictionary *requestDirectives = parseCacheControl(headerValue(wire, @"Cache-Control"));
    /* §5.2.1.5: no-store forbids keeping any part of this request or of its
     * answer, so this one never touches the file in either direction. */
    if ([requestDirectives objectForKey:@"no-store"])
        return NO;

    _cacheKey = [cacheKeyForRequest(request) copy];

    /* WebKit's own cache policy, which it sets on the request and which this is
     * the only code left to honour. A reload still stores what it fetches — it is
     * the reading that was refused, not the writing. */
    NSURLRequestCachePolicy policy = [request cachePolicy];
    if (policy == NSURLRequestReloadIgnoringLocalCacheData
        || policy == NSURLRequestReloadIgnoringLocalAndRemoteCacheData)
        return NO;

    NSString *path = cachePathForKey(_cacheKey);
    ModernTLSCacheEntry *entry = path ? readCacheEntry(path, _cacheKey) : nil;
    /* Stored, but against a request that differed where the origin said it
     * mattered. One variant is kept per key, so this is a miss and the entry that
     * is here stays here — it is somebody else's answer, not a bad one. */
    if (entry && !selectingHeadersMatch(entry->selecting, wire))
        entry = nil;

    /* The two policies where WebKit is asking for the stored copy at whatever age
     * it has — a back or forward navigation, where the point is to show the page
     * that was there. Freshness is the origin's word on when this code may skip
     * the network of its own accord; here it is the client choosing, which it
     * may. */
    if (policy == NSURLRequestReturnCacheDataElseLoad
        || policy == NSURLRequestReturnCacheDataDontLoad) {
        if (entry) {
            if ([self deliverEntry:entry]) {
                if (gLog)
                    fprintf(stderr, "[cache] served on request %s\n", [_cacheKey UTF8String]);
                return YES;
            }
            /* Matched and still unusable means the file is not what it claims. */
            removeCacheEntry(_cacheKey);
        }
        if (policy == NSURLRequestReturnCacheDataDontLoad) {
            /* DontLoad means exactly that. Reaching the network here — which is
             * what falling through would do — answers a question that was not the
             * one asked, and this policy is the one place where a failure is the
             * correct answer. */
            [self failWithMessage:@"Not in the cache, and the request forbids loading it"
                code:NSURLErrorResourceUnavailable];
            return YES;
        }
        return NO;
    }
    if (!entry)
        return NO;

    ModernTLSCacheVerdict verdict = verdictForEntry(entry, requestDirectives);
    /* §5.2.1.4 by another route: this policy is WebKit saying the stored copy may
     * be used only if the origin confirms it, which is the same instruction a
     * no-cache directive gives. */
    if (policy == NSURLRequestReloadRevalidatingCacheData && verdict == ModernTLSCacheFresh)
        verdict = ModernTLSCacheValidate;

    if (verdict == ModernTLSCacheFresh) {
        if ([self deliverEntry:entry]) {
            if (gLog)
                fprintf(stderr, "[cache] hit %s\n", [_cacheKey UTF8String]);
            return YES;
        }
        removeCacheEntry(_cacheKey);
        return NO;
    }

    /* ---- the app-shell policy. Not RFC 9111; see its own section above. ----
     *
     * A stale shell response is handed over now and made current behind the page.
     * Everything that could mean "the client wants the origin asked" is honoured
     * before this is reached and none of it is overridden here: a reload and a
     * revalidating policy have already returned or been forced to Validate above,
     * and a request carrying no-cache, Pragma: no-cache or max-age=0 — which is
     * what WebKit sends for a fetch() with cache: 'no-cache' — is left alone. What
     * this does override is the *origin's* no-cache and its expiry, deliberately,
     * which is the whole of the deviation. */
    NSTimeInterval requestedAge = 0;
    BOOL clientWantsOrigin = [requestDirectives objectForKey:@"no-cache"] != nil
        || headerContains(wire, @"Pragma", @"no-cache")
        || (deltaSeconds(requestDirectives, @"max-age", &requestedAge) && requestedAge == 0);
    if (verdict != ModernTLSCacheFresh && !clientWantsOrigin
        && policy == NSURLRequestUseProtocolCachePolicy
        && shellPolicyAppliesTo(request, wire, entry, _cacheKey)) {
        if ([self deliverEntry:entry]) {
            if (gLog)
                fprintf(stderr, "[shell] served stale by policy, age %.0fs: %s\n",
                    entryAge(entry), [_cacheKey UTF8String]);
            shellQueueRevalidation(request, _cacheKey);
            return YES;
        }
        removeCacheEntry(_cacheKey);
        return NO;
    }

    if (verdict == ModernTLSCacheValidate) {
        /* §4.3.1. Both validators go out when both are known: the origin is told
         * to prefer the entity tag, and the date is there for one that kept only
         * that. Neither is invented — a stored response with no validator at all
         * came back ModernTLSCacheUnusable, not ModernTLSCacheValidate. */
        NSString *tag = headerValue(entry->headers, @"ETag");
        NSString *modified = headerValue(entry->headers, @"Last-Modified");
        if ([tag length])
            [wire setObject:tag forKey:@"If-None-Match"];
        if ([modified length])
            [wire setObject:modified forKey:@"If-Modified-Since"];
        _validating = [entry retain];
        if (gLog)
            fprintf(stderr, "[cache] revalidating %s\n", [_cacheKey UTF8String]);
    }
    return NO;
}

- (NSData *)shrinkImageData:(NSData *)data
{
    CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)data, NULL);
    if (!source)
        return nil;

    NSDictionary *thumbnailOptions = [NSDictionary dictionaryWithObjectsAndKeys:
        (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailFromImageAlways,
        (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailWithTransform,
        [NSNumber numberWithInt:900], (id)kCGImageSourceThumbnailMaxPixelSize, nil];
    CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (CFDictionaryRef)thumbnailOptions);
    CFRelease(source);
    if (!thumbnail)
        return nil;

    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((CFMutableDataRef)out,
        kUTTypeJPEG, 1, NULL);
    if (!destination) {
        CGImageRelease(thumbnail);
        return nil;
    }
    NSDictionary *encodeOptions = [NSDictionary dictionaryWithObject:[NSNumber numberWithFloat:0.72f]
        forKey:(id)kCGImageDestinationLossyCompressionQuality];
    CGImageDestinationAddImage(destination, thumbnail, (CFDictionaryRef)encodeOptions);
    BOOL wrote = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(thumbnail);

    if (!wrote || ![out length] || [out length] >= [data length])
        return nil;
    return out;
}

- (ModernTLSExchange)exchangeOn:(ModernTLSConnection *)connection
                        message:(NSData *)message
                        request:(NSURLRequest *)request
{
    NSURL *url = [request URL];
    [connection beginExchange];
    /* The two moments RFC 9111 §4.2.3 needs. Without the first, a response that
     * spent an hour in someone else's cache before reaching a slow link cannot be
     * told from one fetched a second ago, and this cache would carry that error
     * forward every launch. */
    _requestTime = nowSeconds();
    if (![connection writeData:message])
        return ModernTLSExchangeUnanswered;

    char line[8192];
    NSInteger status = 0;
    int major = 1, minor = 1;
    NSMutableDictionary *headers = nil;

    /* 1xx is an interim answer — a 100 Continue, or the 103 an origin sends ahead
     * of the real one — and the response WebKit is waiting for is the next one. */
    for (int interim = 0; interim < 8; interim++) {
        if (![connection readLine:line size:sizeof(line)]) {
            /* Nothing at all came back. On a connection taken from the pool that
             * means the server had already closed it, which is not an error: the
             * caller sends the request again on a new one. */
            if (![connection hasRead])
                return ModernTLSExchangeUnanswered;
            [self failWithMessage:[NSString stringWithFormat:@"No reply from %@", [url host]]
                code:NSURLErrorNetworkConnectionLost];
            return ModernTLSExchangeSpent;
        }

        long code = 0;
        if (sscanf(line, "HTTP/%d.%d %ld", &major, &minor, &code) < 3) {
            [self failWithMessage:@"Malformed response" code:NSURLErrorBadServerResponse];
            return ModernTLSExchangeSpent;
        }
        status = code;

        headers = [NSMutableDictionary dictionary];
        BOOL complete = NO;
        for (int field = 0; field < 256; field++) {
            if (![connection readLine:line size:sizeof(line)])
                break;
            if (!line[0]) {
                complete = YES;
                break;
            }
            char *colon = strchr(line, ':');
            if (!colon)
                continue;
            *colon = 0;
            NSString *name = headerString(line);
            NSString *value = [headerString(colon + 1)
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (!name || !value)
                continue;
            NSString *existing = [headers objectForKey:name];
            /* Several Set-Cookie lines are normal and must not overwrite each other. */
            [headers setObject:existing ? [existing stringByAppendingFormat:@", %@", value] : value
                forKey:name];
        }
        if (!complete) {
            [self failWithMessage:@"Malformed response" code:NSURLErrorBadServerResponse];
            return ModernTLSExchangeSpent;
        }

        if (status < 100 || status >= 200 || status == 101)
            break;
    }
    if (status >= 100 && status < 200 && status != 101) {
        [self failWithMessage:@"Nothing but interim replies" code:NSURLErrorBadServerResponse];
        return ModernTLSExchangeSpent;
    }
    NSTimeInterval receivedTime = nowSeconds();

    BOOL isHead = [[request HTTPMethod] caseInsensitiveCompare:@"HEAD"] == NSOrderedSame;
    /* These carry no body however they are described: a HEAD is answered with the
     * headers a GET would have had, including its Content-Length, and 204 and 304
     * are defined to end at the blank line. Believing Content-Length here is how a
     * kept connection deadlocks on a body that is never sent. */
    BOOL bodiless = isHead || status == 204 || status == 304 || (status >= 100 && status < 200);

    ModernTLSFraming framing = ModernTLSFramingNone;
    unsigned long long length = 0;
    NSString *contentLength = headerValue(headers, @"Content-Length");
    if (bodiless)
        framing = ModernTLSFramingNone;
    else if (headerContains(headers, @"Transfer-Encoding", @"chunked"))
        framing = ModernTLSFramingChunked;
    else if ([contentLength length] && isdigit([contentLength characterAtIndex:0])) {
        framing = ModernTLSFramingLength;
        length = strtoull([contentLength UTF8String], NULL, 10);
    } else
        framing = ModernTLSFramingUntilClose;

    /* HTTP/1.1 keeps the connection unless the server says otherwise; HTTP/1.0 is
     * the other way round, and not worth pooling for the few origins still on it. */
    BOOL keepable = (major == 1 && minor >= 1)
        && !headerContains(headers, @"Connection", @"close")
        && framing != ModernTLSFramingUntilClose;

    if (gLog) {
        fprintf(stderr, "[tls] %s -> %ld  %s  %s\n", [[url absoluteString] UTF8String], (long)status,
            framing == ModernTLSFramingChunked ? "chunked"
                : framing == ModernTLSFramingLength ? [contentLength UTF8String]
                : framing == ModernTLSFramingNone ? "no body" : "until close",
            keepable ? "keep-alive" : "closing");
        fflush(stderr);
    }

    NSArray *setCookies = [NSHTTPCookie cookiesWithResponseHeaderFields:headers forURL:url];
    if ([setCookies count])
        [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookies:setCookies forURL:url mainDocumentURL:nil];

    invalidateCacheForRequest(request, headers, status);

    /* RFC 9111 §4.3.3: a 304 answering the conditional this cache sent means the
     * stored response is still the right one, and the exchange ends without a
     * body having crossed the wire at all. */
    if (status == 304 && _validating) {
        NSString *tag = headerValue(headers, @"ETag");
        NSString *stored = headerValue(_validating->headers, @"ETag");
        ModernTLSCacheEntry *entry = [[_validating retain] autorelease];
        [_validating release];
        _validating = nil;

        if ([tag length] && [stored length] && ![tag isEqualToString:stored]) {
            /* The origin validated a representation other than the one it was
             * asked about. A body its own validator no longer identifies is not a
             * body to hand anybody, so the entry goes and the request is put
             * again with nothing conditional about it. */
            removeCacheEntry(_cacheKey);
            return ModernTLSExchangeMismatched;
        }

        /* §4.3.4, and the clock the age calculation runs on is reset to this
         * exchange: a revalidated response is fresh again, not merely confirmed. */
        mergeStoredHeaders(entry, headers);
        entry->requested = _requestTime;
        entry->received = receivedTime;
        if (![self deliverEntry:entry]) {
            removeCacheEntry(_cacheKey);
            return ModernTLSExchangeMismatched;
        }
        if (gLog)
            fprintf(stderr, "[cache] validated %s\n", [_cacheKey UTF8String]);
        /* Only now, with WebKit already answered, is the file brought up to date;
         * it is the one piece of this that nothing is waiting for. */
        rewriteCacheEntry(entry, _cacheKey);
        return keepable ? ModernTLSExchangeReusable : ModernTLSExchangeSpent;
    }
    /* A 304 nobody here asked for belongs to WebKit's own conditional request and
     * is passed through untouched; the stored entry, if there is one, has been
     * told nothing and stays as it was. */
    [_validating release];
    _validating = nil;

    BOOL encoded = !bodiless && headerContains(headers, @"Content-Encoding", @"gzip");

    /* WebKit is handed the entity it is actually given. The framing headers
     * describe this hop and the coding headers describe bytes it never sees, so
     * neither is passed on — a Content-Length counting gzipped bytes against a
     * decoded body is a lie WebKit would be right to believe. This is also
     * exactly what gets stored, so that a replay is the same delivery. */
    NSMutableDictionary *visible = [NSMutableDictionary dictionaryWithCapacity:[headers count]];
    for (NSString *field in headers) {
        if (isHopByHop(field))
            continue;
        if (encoded && ([field caseInsensitiveCompare:@"Content-Encoding"] == NSOrderedSame
            || [field caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame))
            continue;
        [visible setObject:[headers objectForKey:field] forKey:field];
    }

    /* What will be kept, decided before a byte of the body has been read so that
     * the body can be written as it streams past instead of assembled first. */
    if (_cacheKey) {
        NSDictionary *directives = parseCacheControl(headerValue(headers, @"Cache-Control"));
        if (responseIsStorable(status, headers, directives)) {
            NSMutableDictionary *kept = [NSMutableDictionary dictionaryWithDictionary:visible];
            for (NSString *field in [kept allKeys]) {
                if ([field caseInsensitiveCompare:@"Set-Cookie"] == NSOrderedSame)
                    [kept removeObjectForKey:field];
            }
            _writer = [[ModernTLSCacheWriter alloc] initForKey:_cacheKey
                metadata:[NSDictionary dictionaryWithObjectsAndKeys:
                    _cacheKey, @"url",
                    [NSNumber numberWithInteger:status], @"status",
                    kept, @"headers",
                    selectingHeaders(headerValue(headers, @"Vary"), _wireHeaders), @"vary",
                    [NSNumber numberWithDouble:_requestTime], @"requested",
                    [NSNumber numberWithDouble:receivedTime], @"received", nil]];
        } else if (status >= 200 && status < 400) {
            /* The origin has answered for this URI with a representation this
             * cache is not allowed to keep — it has turned on no-store, or begun
             * varying on everything. What is on disk predates that answer and has
             * no business outliving it.
             *
             * The status test is the whole of the care needed here. An error is
             * also unstorable, and an error carries no representation: a 503 to a
             * revalidation says the origin is having a bad minute, not that
             * yesterday's copy was wrong, and deleting on it would turn one failed
             * request into a cold cache. Error pages are routinely sent no-store,
             * so keying this off the directive rather than the status is exactly
             * the mistake that costs the entry. */
            removeCacheEntry(_cacheKey);
        }
    }

    /* A redirect is reported to WebKit rather than followed here, so that it
     * keeps its own record of where the document came from. Its body is read only
     * to leave the connection at a message boundary. */
    NSString *location = headerValue(headers, @"Location");
    if (status >= 300 && status < 400 && [location length]) {
        NSURL *target = [NSURL URLWithString:location relativeToURL:url];
        if (!target) {
            [self failWithMessage:@"Unusable redirect" code:NSURLErrorBadServerResponse];
            return ModernTLSExchangeSpent;
        }
        /* A redirect is nothing but its headers, so its entry is complete the
         * moment they are read. Storing it is what lets a later launch skip a
         * round trip whose only answer was ever "somewhere else". */
        if (_writer) {
            [_writer commit];
            [_writer release];
            _writer = nil;
        }
        if (keepable)
            keepable = [self readBodyFrom:connection framing:framing length:length deliver:NO];

        NSHTTPURLResponse *response = [[[NSHTTPURLResponse alloc] initWithURL:url statusCode:status
            HTTPVersion:@"HTTP/1.1" headerFields:visible] autorelease];
        [self onClientThread:@selector(deliverRedirect:)
            with:[NSArray arrayWithObjects:[self redirectedRequestTo:target status:status], response, nil]];
        return keepable ? ModernTLSExchangeReusable : ModernTLSExchangeSpent;
    }

    if (encoded) {
        memset(&_inflater, 0, sizeof(_inflater));
        /* 16 + MAX_WBITS accepts a gzip wrapper; nothing else is asked for. */
        if (inflateInit2(&_inflater, 16 + MAX_WBITS) != Z_OK) {
            [self failWithMessage:@"Cannot decode gzip" code:NSURLErrorCannotDecodeContentData];
            return ModernTLSExchangeSpent;
        }
        _inflating = YES;
    }

    NSString *contentType = headerValue(headers, @"Content-Type");
    NSString *method = [[self request] HTTPMethod] ?: @"GET";
    BOOL transcodable = status == 200
        && [method caseInsensitiveCompare:@"GET"] == NSOrderedSame
        && framing == ModernTLSFramingLength
        && [[contentType lowercaseString] hasPrefix:@"image/"]
        && !headerContains(headers, @"Content-Type", @"svg")
        && length > 4096
        && length <= kImageTranscodeSizeLimit;

    if (transcodable) {
        _transcodingImage = YES;
        _imageBuffer = [[NSMutableData alloc] initWithCapacity:(NSUInteger)length];
        if (_writer) {
            [_writer abandon];
            [_writer release];
            _writer = nil;
        }
    } else {
        NSHTTPURLResponse *response = [[[NSHTTPURLResponse alloc] initWithURL:url statusCode:status
            HTTPVersion:@"HTTP/1.1" headerFields:visible] autorelease];
        [self onClientThread:@selector(deliverResponse:) with:response];
    }

    BOOL whole = [self readBodyFrom:connection framing:framing length:length deliver:YES];

    if (_inflating) {
        if (gLog)
            fprintf(stderr, "[tls]   inflated %lu -> %lu bytes\n",
                (unsigned long)_inflater.total_in, (unsigned long)_inflater.total_out);
        inflateEnd(&_inflater);
        _inflating = NO;
    }

    if (_transcodingImage) {
        NSData *original = [_imageBuffer autorelease];
        _imageBuffer = nil;
        _transcodingImage = NO;

        NSData *shrunk = (whole && !_cancelled) ? [self shrinkImageData:original] : nil;
        NSMutableDictionary *finalHeaders = [NSMutableDictionary dictionaryWithDictionary:visible];
        NSData *deliverable = original;
        if (shrunk) {
            [finalHeaders setObject:@"image/jpeg" forKey:@"Content-Type"];
            [finalHeaders setObject:[NSString stringWithFormat:@"%lu", (unsigned long)[shrunk length]]
                forKey:@"Content-Length"];
            deliverable = shrunk;
        }
        NSHTTPURLResponse *response = [[[NSHTTPURLResponse alloc] initWithURL:url statusCode:status
            HTTPVersion:@"HTTP/1.1" headerFields:finalHeaders] autorelease];
        [self onClientThread:@selector(deliverResponse:) with:response];
        if ([deliverable length])
            [self onClientThread:@selector(deliverData:) with:deliverable];
    }

    /* An entry is only worth having if it is the whole representation, and only
     * the body's own framing can say that it was. A cancelled load is the same
     * case seen from the other side. */
    if (_writer) {
        if (whole && !_cancelled)
            [_writer commit];
        else
            [_writer abandon];
        [_writer release];
        _writer = nil;
    }

    if (!whole) {
        if (!_cancelled)
            [self failWithMessage:[NSString stringWithFormat:@"Reply from %@ ended early", [url host]]
                code:NSURLErrorNetworkConnectionLost];
        return ModernTLSExchangeSpent;
    }

    [self onClientThread:@selector(deliverFinish:) with:nil];
    return keepable ? ModernTLSExchangeReusable : ModernTLSExchangeSpent;
}

- (void)performRequest:(NSURLRequest *)request
{
    if (!_background)
        shellNoteForegroundActivity();
    NSURL *url = [request URL];
    NSString *host = [url host];
    if (![host length]) {
        [self failWithMessage:@"No host in URL" code:NSURLErrorBadURL];
        return;
    }
    NSString *port = [url port] ? [[url port] stringValue] : @"443";
    NSString *key = [NSString stringWithFormat:@"%@:%@", [host lowercaseString], port];

    _wireHeaders = [[self wireHeadersFor:request] retain];
    /* The only line in this file that makes a launch faster rather than a request
     * cheaper. Everything below it — the pool, the handshake, the round trip — is
     * what a stored answer skips, and it skips all of it: the return here is
     * before the first syscall that would touch the network. */
    if ([self answerFromCache:request wire:_wireHeaders])
        return;

    NSData *message = [self messageForRequest:request target:requestTarget(url)
        headers:_wireHeaders];

    ModernTLSConnection *connection = takeIdleConnection(key);
    BOOL pooled = connection != nil;

    for (;;) {
        if (!connection) {
            NSString *reason = nil;
            NSInteger code = NSURLErrorCannotConnectToHost;
            connection = [ModernTLSConnection connectionToHost:host port:port key:key
                message:&reason code:&code];
            if (!connection) {
                [self failWithMessage:reason code:code];
                return;
            }
        }

        ModernTLSExchange outcome = [self exchangeOn:connection message:message request:request];
        if (outcome == ModernTLSExchangeMismatched) {
            /* The revalidation was answered about something this cache does not
             * hold, and the entry it was about has already been dropped. Asking
             * again without the conditional is the only way to end up with the
             * representation the origin actually has. It cannot happen twice:
             * _validating is nil from here, so there is no conditional left to
             * mismatch. A fresh connection because a spent one is cheaper to
             * replace than to reason about. */
            [connection shutdown];
            [connection release];
            connection = nil;
            pooled = NO;
            [_wireHeaders removeObjectForKey:@"If-None-Match"];
            [_wireHeaders removeObjectForKey:@"If-Modified-Since"];
            message = [self messageForRequest:request target:requestTarget(url)
                headers:_wireHeaders];
            continue;
        }
        if (outcome == ModernTLSExchangeUnanswered) {
            [connection shutdown];
            [connection release];
            connection = nil;
            /* The one case that has to be got right for pooling to be safe at all:
             * a server may close a kept connection at any moment, and it looks
             * exactly like this — the write succeeded into a socket that was
             * already gone, or the read ended before a byte of the reply. Nothing
             * has been handed to the client and nothing has been read, so the
             * request is sent again on a connection of our own making, where the
             * same silence really is a failure. */
            if (pooled) {
                if (gLog)
                    fprintf(stderr, "[tls] %s was closed; retrying on a new connection\n", [key UTF8String]);
                pooled = NO;
                continue;
            }
            [self failWithMessage:[NSString stringWithFormat:@"Connection to %@ closed before a reply", host]
                code:NSURLErrorNetworkConnectionLost];
            return;
        }

        /* A cancelled load leaves the body half-read, and half a body is not a
         * message boundary — that connection cannot be given to anyone else. */
        if (outcome == ModernTLSExchangeReusable && !_cancelled)
            returnIdleConnection(connection);
        else
            [connection shutdown];
        [connection release];
        return;
    }
}

@end
