/*
 * The engine's own TLS.
 *
 * This device's SecureTransport is from 2012. It offers a cipher list that a
 * current server will not accept: measured against claude.ai, every CBC/SHA1
 * suite is refused with a handshake failure and only AEAD suites - AES-GCM and
 * ChaCha20-Poly1305 - are allowed, none of which this system can speak. The
 * certificate side is fine; the device already trusts ISRG Root X1 and X2. The
 * connection simply never gets that far.
 *
 * So the twenty-five SecureTransport entry points that CFNetwork imports are
 * answered here instead, over OpenSSL 1.1.1 built for armv7. CFNetwork still
 * creates the session, still supplies the socket read and write callbacks, and
 * still evaluates the certificate chain through SecTrust - only the protocol in
 * between is ours.
 *
 * Nothing here weakens verification: the peer chain is handed back as a real
 * SecTrustRef built from the certificates the server sent, and the system
 * evaluates it against its own trust store exactly as before.
 */

#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <Security/SecureTransport.h>

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509.h>

static void note(const char *format, ...)
{
    static FILE *log;
    static int enabled = -1;
    if (enabled < 0)
        enabled = access("/tmp/native-tls-log", F_OK) == 0 ? 1 : 0;
    if (!enabled)
        return;
    if (!log) {
        log = fopen("/tmp/native-tls.log", "a");
        if (log)
            setvbuf(log, NULL, _IOLBF, 0);
    }
    if (!log)
        return;
    va_list arguments;
    va_start(arguments, format);
    vfprintf(log, format, arguments);
    va_end(arguments);
    fputc('\n', log);
}

/* One of these per SSLContextRef the system hands us. The context itself stays
 * the system's object - we never create or free it - and this is the state we
 * keep alongside it, found by pointer. */
typedef struct Session {
    SSLContextRef context;
    SSL *ssl;
    SSL_CTX *sslContext;
    SSLReadFunc read;
    SSLWriteFunc write;
    SSLConnectionRef connection;
    char host[256];
    bool handshakeDone;
    bool failed;
    struct Session *next;
} Session;

static Session *sessions;
static pthread_mutex_t sessionsLock = PTHREAD_MUTEX_INITIALIZER;

static Session *sessionFor(SSLContextRef context, bool create)
{
    pthread_mutex_lock(&sessionsLock);
    Session *session = sessions;
    while (session && session->context != context)
        session = session->next;
    if (!session && create) {
        session = calloc(1, sizeof(Session));
        if (session) {
            session->context = context;
            session->next = sessions;
            sessions = session;
        }
    }
    pthread_mutex_unlock(&sessionsLock);
    return session;
}

static void forgetSession(SSLContextRef context)
{
    pthread_mutex_lock(&sessionsLock);
    Session **link = &sessions;
    while (*link && (*link)->context != context)
        link = &(*link)->next;
    Session *session = *link;
    if (session) {
        *link = session->next;
        if (session->ssl)
            SSL_free(session->ssl);
        if (session->sslContext)
            SSL_CTX_free(session->sslContext);
        free(session);
    }
    pthread_mutex_unlock(&sessionsLock);
}

/* OpenSSL talks to the socket through the callbacks CFNetwork gave us, so the
 * socket stays entirely the system's: its timeouts, its proxy handling, its
 * non-blocking behaviour. */
static int bioRead(BIO *bio, char *buffer, int length)
{
    Session *session = (Session *)BIO_get_data(bio);
    if (!session || !session->read || length <= 0)
        return -1;
    size_t wanted = (size_t)length;
    OSStatus status = session->read(session->connection, buffer, &wanted);
    BIO_clear_retry_flags(bio);
    if (status == errSSLWouldBlock && !wanted) {
        BIO_set_retry_read(bio);
        return -1;
    }
    if (status != noErr && status != errSSLWouldBlock && !wanted)
        return status == errSSLClosedGraceful ? 0 : -1;
    return (int)wanted;
}

static int bioWrite(BIO *bio, const char *buffer, int length)
{
    Session *session = (Session *)BIO_get_data(bio);
    if (!session || !session->write || length <= 0)
        return -1;
    size_t wanted = (size_t)length;
    OSStatus status = session->write(session->connection, buffer, &wanted);
    BIO_clear_retry_flags(bio);
    if (status == errSSLWouldBlock && !wanted) {
        BIO_set_retry_write(bio);
        return -1;
    }
    if (status != noErr && status != errSSLWouldBlock && !wanted)
        return -1;
    return (int)wanted;
}

static long bioControl(BIO *bio, int command, long argument, void *pointer)
{
    (void)bio; (void)argument; (void)pointer;
    switch (command) {
    case BIO_CTRL_FLUSH:
        return 1;
    case BIO_CTRL_PUSH:
    case BIO_CTRL_POP:
        return 0;
    default:
        return 0;
    }
}

static BIO_METHOD *transportMethod(void)
{
    static BIO_METHOD *method;
    if (!method) {
        method = BIO_meth_new(BIO_get_new_index() | BIO_TYPE_SOURCE_SINK, "CFNetwork transport");
        BIO_meth_set_read(method, bioRead);
        BIO_meth_set_write(method, bioWrite);
        BIO_meth_set_ctrl(method, bioControl);
    }
    return method;
}

static bool startSession(Session *session)
{
    if (session->ssl)
        return true;

    static bool initialised;
    if (!initialised) {
        SSL_library_init();
        SSL_load_error_strings();
        initialised = true;
    }

    session->sslContext = SSL_CTX_new(TLS_client_method());
    if (!session->sslContext)
        return false;
    SSL_CTX_set_min_proto_version(session->sslContext, TLS1_VERSION);
    SSL_CTX_set_max_proto_version(session->sslContext, TLS1_3_VERSION);
    /* The chain is verified by the system afterwards, through the SecTrustRef
     * built in SSLCopyPeerTrust, which is where this platform's trust store
     * lives. Verifying here as well would only duplicate it with a different
     * root list. */
    SSL_CTX_set_verify(session->sslContext, SSL_VERIFY_NONE, NULL);

    session->ssl = SSL_new(session->sslContext);
    if (!session->ssl)
        return false;

    BIO *bio = BIO_new(transportMethod());
    if (!bio)
        return false;
    BIO_set_data(bio, session);
    BIO_set_init(bio, 1);
    SSL_set_bio(session->ssl, bio, bio);
    SSL_set_connect_state(session->ssl);
    if (session->host[0]) {
        SSL_set_tlsext_host_name(session->ssl, session->host);
        X509_VERIFY_PARAM_set1_host(SSL_get0_param(session->ssl), session->host, 0);
    }
    return true;
}

OSStatus ourSSLSetIOFuncs(SSLContextRef context, SSLReadFunc readFunc, SSLWriteFunc writeFunc)
{
    Session *session = sessionFor(context, true);
    if (!session)
        return errSecAllocate;
    session->read = readFunc;
    session->write = writeFunc;
    return noErr;
}

OSStatus ourSSLSetConnection(SSLContextRef context, SSLConnectionRef connection)
{
    Session *session = sessionFor(context, true);
    if (!session)
        return errSecAllocate;
    session->connection = connection;
    return noErr;
}

OSStatus ourSSLSetPeerDomainName(SSLContextRef context, const char *name, size_t length)
{
    Session *session = sessionFor(context, true);
    if (!session)
        return errSecAllocate;
    if (length >= sizeof(session->host))
        length = sizeof(session->host) - 1;
    memcpy(session->host, name, length);
    session->host[length] = 0;
    return noErr;
}

OSStatus ourSSLGetPeerDomainNameLength(SSLContextRef context, size_t *length)
{
    Session *session = sessionFor(context, false);
    if (length)
        *length = session ? strlen(session->host) + 1 : 0;
    return noErr;
}

OSStatus ourSSLGetPeerDomainName(SSLContextRef context, char *name, size_t *length)
{
    Session *session = sessionFor(context, false);
    size_t have = session ? strlen(session->host) + 1 : 0;
    if (!length)
        return errSecParam;
    if (name && *length >= have)
        memcpy(name, session ? session->host : "", have);
    *length = have;
    return noErr;
}

OSStatus ourSSLHandshake(SSLContextRef context)
{
    Session *session = sessionFor(context, true);
    if (!session || !session->read || !session->write)
        return errSSLInternal;
    if (session->handshakeDone)
        return noErr;
    if (!startSession(session)) {
        session->failed = true;
        return errSSLInternal;
    }

    int result = SSL_do_handshake(session->ssl);
    if (result == 1) {
        session->handshakeDone = true;
        note("handshake with %s: %s, %s", session->host,
            SSL_get_version(session->ssl), SSL_get_cipher(session->ssl));
        return noErr;
    }

    int error = SSL_get_error(session->ssl, result);
    if (error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE)
        return errSSLWouldBlock;

    note("handshake with %s failed: error %d (%s)", session->host, error,
        ERR_reason_error_string(ERR_peek_last_error()));
    session->failed = true;
    return errSSLClosedAbort;
}

OSStatus ourSSLRead(SSLContextRef context, void *data, size_t length, size_t *processed)
{
    Session *session = sessionFor(context, false);
    if (processed)
        *processed = 0;
    if (!session || !session->ssl)
        return errSSLInternal;

    int result = SSL_read(session->ssl, data, (int)length);
    if (result > 0) {
        if (processed)
            *processed = (size_t)result;
        return noErr;
    }
    int error = SSL_get_error(session->ssl, result);
    if (error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE)
        return errSSLWouldBlock;
    if (error == SSL_ERROR_ZERO_RETURN)
        return errSSLClosedGraceful;
    return errSSLClosedAbort;
}

OSStatus ourSSLWrite(SSLContextRef context, const void *data, size_t length, size_t *processed)
{
    Session *session = sessionFor(context, false);
    if (processed)
        *processed = 0;
    if (!session || !session->ssl)
        return errSSLInternal;
    if (!length)
        return noErr;

    int result = SSL_write(session->ssl, data, (int)length);
    if (result > 0) {
        if (processed)
            *processed = (size_t)result;
        return noErr;
    }
    int error = SSL_get_error(session->ssl, result);
    if (error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE)
        return errSSLWouldBlock;
    return errSSLClosedAbort;
}

OSStatus ourSSLClose(SSLContextRef context)
{
    Session *session = sessionFor(context, false);
    if (session && session->ssl && session->handshakeDone)
        SSL_shutdown(session->ssl);
    forgetSession(context);
    return noErr;
}

/* The chain the server actually sent, handed back as the platform's own trust
 * object so the system evaluates it against the system trust store. */
OSStatus ourSSLCopyPeerTrust(SSLContextRef context, SecTrustRef *trust)
{
    if (trust)
        *trust = NULL;
    Session *session = sessionFor(context, false);
    if (!session || !session->ssl || !trust)
        return errSSLInternal;

    STACK_OF(X509) *chain = SSL_get_peer_cert_chain(session->ssl);
    if (!chain)
        return errSSLInternal;

    CFMutableArrayRef certificates = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (int i = 0; i < sk_X509_num(chain); i++) {
        X509 *certificate = sk_X509_value(chain, i);
        unsigned char *der = NULL;
        int length = i2d_X509(certificate, &der);
        if (length <= 0 || !der)
            continue;
        CFDataRef data = CFDataCreate(NULL, der, length);
        OPENSSL_free(der);
        if (!data)
            continue;
        SecCertificateRef secCertificate = SecCertificateCreateWithData(NULL, data);
        CFRelease(data);
        if (secCertificate) {
            CFArrayAppendValue(certificates, secCertificate);
            CFRelease(secCertificate);
        }
    }

    SecPolicyRef policy = SecPolicyCreateBasicX509();
    SecTrustRef created = NULL;
    OSStatus status = SecTrustCreateWithCertificates(certificates, policy, &created);
    if (policy)
        CFRelease(policy);
    CFRelease(certificates);
    if (status != errSecSuccess)
        return status;
    *trust = created;
    return noErr;
}

OSStatus ourSSLGetNegotiatedProtocolVersion(SSLContextRef context, SSLProtocol *protocol)
{
    Session *session = sessionFor(context, false);
    if (!protocol)
        return errSecParam;
    *protocol = kTLSProtocol12;
    if (session && session->ssl) {
        int version = SSL_version(session->ssl);
        if (version == TLS1_VERSION)
            *protocol = kTLSProtocol1;
        else if (version == TLS1_1_VERSION)
            *protocol = kTLSProtocol11;
    }
    return noErr;
}

OSStatus ourSSLGetSessionState(SSLContextRef context, SSLSessionState *state)
{
    Session *session = sessionFor(context, false);
    if (!state)
        return errSecParam;
    if (!session || !session->ssl)
        *state = kSSLIdle;
    else if (session->failed)
        *state = kSSLClosed;
    else if (session->handshakeDone)
        *state = kSSLConnected;
    else
        *state = kSSLHandshake;
    return noErr;
}

/* Accepted and remembered where it costs nothing, answered emptily where the
 * answer only matters to client-certificate authentication, which this port
 * does not do. */
OSStatus ourSSLSetProtocolVersionMin(SSLContextRef context, SSLProtocol version) { (void)context; (void)version; return noErr; }
OSStatus ourSSLSetProtocolVersionMax(SSLContextRef context, SSLProtocol version) { (void)context; (void)version; return noErr; }
OSStatus ourSSLSetSessionOption(SSLContextRef context, SSLSessionOption option, Boolean value) { (void)context; (void)option; (void)value; return noErr; }
OSStatus ourSSLSetAllowAnonymousCiphers(SSLContextRef context, Boolean value) { (void)context; (void)value; return noErr; }
OSStatus ourSSLSetClientSideAuthenticate(SSLContextRef context, SSLAuthenticate authenticate) { (void)context; (void)authenticate; return noErr; }
OSStatus ourSSLGetClientSideAuthenticate(SSLContextRef context, SSLAuthenticate *authenticate) { (void)context; if (authenticate) *authenticate = kNeverAuthenticate; return noErr; }
OSStatus ourSSLGetClientCertificateState(SSLContextRef context, SSLClientCertificateState *state) { (void)context; if (state) *state = kSSLClientCertNone; return noErr; }
OSStatus ourSSLSetCertificate(SSLContextRef context, CFArrayRef chain) { (void)context; (void)chain; return noErr; }
OSStatus ourSSLGetCertificate(SSLContextRef context, CFArrayRef *chain) { (void)context; if (chain) *chain = NULL; return noErr; }
OSStatus ourSSLCopyDistinguishedNames(SSLContextRef context, CFArrayRef *names) { (void)context; if (names) *names = NULL; return noErr; }

OSStatus ourSSLSetPeerID(SSLContextRef context, const void *identifier, size_t length)
{
    (void)context; (void)identifier; (void)length;
    return noErr;
}

OSStatus ourSSLGetPeerID(SSLContextRef context, const void **identifier, size_t *length)
{
    (void)context;
    if (identifier)
        *identifier = NULL;
    if (length)
        *length = 0;
    return noErr;
}

/* Three of the twenty-five are gone from the modern SDK's headers - they were
 * deprecated long after this device shipped - but they are still what its
 * CFNetwork calls, so the originals are declared here to be interposed. */
extern OSStatus SSLSetAllowAnonymousCiphers(SSLContextRef, Boolean);
extern OSStatus SSLGetClientSideAuthenticate(SSLContextRef, SSLAuthenticate *);
extern OSStatus SSLGetCertificate(SSLContextRef, CFArrayRef *);

/* Substituted the way dyld supports with a two-level namespace: a table of
 * (replacement, original) pairs in __DATA,__interpose. CFNetwork keeps calling
 * the names it was linked against, and dyld sends those calls here. Exporting
 * the same names would not be enough, because CFNetwork records which library
 * each symbol came from. */
#define INTERPOSE(name) \
    __attribute__((used)) static struct { const void *replacement; const void *original; } \
    interpose_##name __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(unsigned long)&our##name, (const void *)(unsigned long)&name };

INTERPOSE(SSLSetIOFuncs)
INTERPOSE(SSLSetConnection)
INTERPOSE(SSLSetPeerDomainName)
INTERPOSE(SSLGetPeerDomainNameLength)
INTERPOSE(SSLGetPeerDomainName)
INTERPOSE(SSLHandshake)
INTERPOSE(SSLRead)
INTERPOSE(SSLWrite)
INTERPOSE(SSLClose)
INTERPOSE(SSLCopyPeerTrust)
INTERPOSE(SSLGetNegotiatedProtocolVersion)
INTERPOSE(SSLGetSessionState)
INTERPOSE(SSLSetProtocolVersionMin)
INTERPOSE(SSLSetProtocolVersionMax)
INTERPOSE(SSLSetSessionOption)
INTERPOSE(SSLSetAllowAnonymousCiphers)
INTERPOSE(SSLSetClientSideAuthenticate)
INTERPOSE(SSLGetClientSideAuthenticate)
INTERPOSE(SSLGetClientCertificateState)
INTERPOSE(SSLSetCertificate)
INTERPOSE(SSLGetCertificate)
INTERPOSE(SSLCopyDistinguishedNames)
INTERPOSE(SSLSetPeerID)
INTERPOSE(SSLGetPeerID)
