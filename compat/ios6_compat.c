/*
 * Symbols WebKit expects from libSystem that iOS 6 does not have. Defining them
 * here means the static linker resolves the references locally instead of
 * recording an import that dyld cannot satisfy on the device.
 */
#include <time.h>
#include <sys/time.h>
#include <mach/mach_time.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <dlfcn.h>

static double machToNanos(void)
{
    static double factor = 0.0;
    if (factor == 0.0) {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        factor = (double)tb.numer / (double)tb.denom;
    }
    return factor;
}

int clock_gettime(clockid_t clockID, struct timespec *ts)
{
    if (!ts) {
        errno = EFAULT;
        return -1;
    }
    switch ((int)clockID) {
    case 0: { /* CLOCK_REALTIME */
        struct timeval tv;
        if (gettimeofday(&tv, 0))
            return -1;
        ts->tv_sec = tv.tv_sec;
        ts->tv_nsec = tv.tv_usec * 1000;
        return 0;
    }
    default: { /* every monotonic / uptime flavour */
        uint64_t nanos = (uint64_t)(mach_absolute_time() * machToNanos());
        ts->tv_sec = (time_t)(nanos / 1000000000ULL);
        ts->tv_nsec = (long)(nanos % 1000000000ULL);
        return 0;
    }
    }
}

uint64_t clock_gettime_nsec_np(clockid_t clockID)
{
    struct timespec ts;
    if (clock_gettime(clockID, &ts))
        return 0;
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

/* ---- CommonCrypto: CCRandomGenerateBytes is iOS 8 ---- */
#include <stdlib.h>
int CCRandomGenerateBytes(void *bytes, size_t count)
{
    arc4random_buf(bytes, count);
    return 0; /* kCCSuccess */
}

/* ---- mach clocks added after iOS 6 ---- */
uint64_t mach_approximate_time(void) { return mach_absolute_time(); }
uint64_t mach_continuous_time(void) { return mach_absolute_time(); }
uint64_t mach_continuous_approximate_time(void) { return mach_absolute_time(); }

/* ---- the POSIX 2008 *at family arrived in iOS 8 ----
 * Resolve the directory descriptor back to a path with F_GETPATH and fall
 * through to the plain call. Not atomic the way the real ones are, but these
 * callers only ever walk directories they already hold open.
 */
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/stat.h>
#include <dirent.h>
#include <sys/param.h>

static int resolveAt(int dirFD, const char *path, char *out, size_t outSize)
{
    if (!path)
        return -1;
    if (path[0] == '/' || dirFD == AT_FDCWD) {
        if (strlcpy(out, path, outSize) >= outSize)
            return -1;
        return 0;
    }
    char dir[MAXPATHLEN];
    if (fcntl(dirFD, F_GETPATH, dir) == -1)
        return -1;
    if ((size_t)snprintf(out, outSize, "%s/%s", dir, path) >= outSize)
        return -1;
    return 0;
}

int openat(int dirFD, const char *path, int flags, ...)
{
    char full[MAXPATHLEN];
    if (resolveAt(dirFD, path, full, sizeof(full)))
        return -1;
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return open(full, flags, mode);
}

int unlinkat(int dirFD, const char *path, int flag)
{
    char full[MAXPATHLEN];
    if (resolveAt(dirFD, path, full, sizeof(full)))
        return -1;
    return (flag & AT_REMOVEDIR) ? rmdir(full) : unlink(full);
}

int fchmodat(int dirFD, const char *path, mode_t mode, int flag)
{
    char full[MAXPATHLEN];
    if (resolveAt(dirFD, path, full, sizeof(full)))
        return -1;
    return (flag & AT_SYMLINK_NOFOLLOW) ? lchmod(full, mode) : chmod(full, mode);
}

DIR *fdopendir(int fd)
{
    char dir[MAXPATHLEN];
    if (fcntl(fd, F_GETPATH, dir) == -1)
        return 0;
    DIR *d = opendir(dir);
    if (d)
        close(fd);
    return d;
}

/* ---- mkostemp is iOS 10; the flags callers pass are O_CLOEXEC at most ---- */
int mkostemp(char *templateName, int flags)
{
    int fd = mkstemp(templateName);
    if (fd >= 0 && (flags & O_CLOEXEC))
        fcntl(fd, F_SETFD, FD_CLOEXEC);
    return fd;
}

/* ---- dyld helpers added after iOS 6 ---- */
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
int _dyld_get_image_uuid(const struct mach_header *header, uuid_t uuid)
{
    (void)header;
    memset(uuid, 0, sizeof(uuid_t));
    return 0;
}

const struct mach_header *dyld_image_header_containing_address(const void *address)
{
    Dl_info info;
    if (dladdr(address, &info))
        return (const struct mach_header *)info.dli_fbase;
    return 0;
}

/* ---- introduced long after iOS 6 ---- */
#include <stdbool.h>
const struct mach_header *_dyld_get_dlopen_image_header(void *handle)
{
    (void)handle;
    return 0;
}

/* Gates Apple-internal debugging behaviour; a shipping device answers no. */
bool os_variant_allows_internal_security_policies(const char *subsystem)
{
    (void)subsystem;
    return false;
}

/* ---- SecTrustCopyCertificateChain is iOS 14 ---- */
#include <Security/Security.h>
CFArrayRef SecTrustCopyCertificateChain(SecTrustRef trust)
{
    if (!trust)
        return NULL;
    CFIndex count = SecTrustGetCertificateCount(trust);
    CFMutableArrayRef chain = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < count; i++) {
        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(trust, i);
        if (certificate)
            CFArrayAppendValue(chain, certificate);
    }
    return chain;
}

/* ---- mach exception server stubs ----
 * The mig-generated server code always references all three handlers even
 * though only one can be reached. WebKit says the same in its own copy: they
 * exist so the generated file links.
 */
#include <mach/mach.h>
#include <mach/exception_types.h>

kern_return_t catch_mach_exception_raise(mach_port_t exceptionPort, mach_port_t thread,
    mach_port_t task, exception_type_t exception, mach_exception_data_t code,
    mach_msg_type_number_t codeCount)
{
    (void)exceptionPort; (void)thread; (void)task;
    (void)exception; (void)code; (void)codeCount;
    return KERN_FAILURE;
}

kern_return_t catch_mach_exception_raise_state(mach_port_t exceptionPort,
    exception_type_t exception, const mach_exception_data_t code, mach_msg_type_number_t codeCount,
    int *flavor, const thread_state_t inState, mach_msg_type_number_t inStateCount,
    thread_state_t outState, mach_msg_type_number_t *outStateCount)
{
    (void)exceptionPort; (void)exception; (void)code; (void)codeCount;
    (void)flavor; (void)inState; (void)inStateCount; (void)outState; (void)outStateCount;
    return KERN_FAILURE;
}

kern_return_t catch_mach_exception_raise_state_identity(mach_port_t exceptionPort,
    mach_port_t thread, mach_port_t task, exception_type_t exception,
    mach_exception_data_t code, mach_msg_type_number_t codeCount, int *flavor,
    thread_state_t inState, mach_msg_type_number_t inStateCount,
    thread_state_t outState, mach_msg_type_number_t *outStateCount)
{
    (void)exceptionPort; (void)thread; (void)task; (void)exception;
    (void)code; (void)codeCount; (void)flavor; (void)inState; (void)inStateCount;
    (void)outState; (void)outStateCount;
    return KERN_FAILURE;
}

kern_return_t catch_mach_exception_raise_state_identity_protected(mach_port_t exceptionPort,
    uint64_t threadID, mach_port_t task, exception_type_t exception,
    mach_exception_data_t code, mach_msg_type_number_t codeCount, int *flavor,
    thread_state_t inState, mach_msg_type_number_t inStateCount,
    thread_state_t outState, mach_msg_type_number_t *outStateCount)
{
    (void)exceptionPort; (void)threadID; (void)task; (void)exception;
    (void)code; (void)codeCount; (void)flavor; (void)inState; (void)inStateCount;
    (void)outState; (void)outStateCount;
    return KERN_FAILURE;
}
