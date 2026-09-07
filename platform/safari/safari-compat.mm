// Two kinds of gap keep Mobile Safari from running on our WebKit 2.54:
//   1. Safari-glue classes our WebKit no longer carries and that are NOT in the
//      system WebUI/WebBookmarks frameworks (only WebGeolocationManager so far).
//      Everything else resolves to those real frameworks under flat namespace, so
//      stubbing it would shadow the real class and crash on its real methods.
//   2. Foundation/UIKit methods our 2.54 code calls that iOS 6 predates. Provided
//      here as categories that map onto the iOS 6 equivalent.
#import <Foundation/Foundation.h>

@interface WebGeolocationManager : NSObject @end
@implementation WebGeolocationManager
+ (id)sharedWebGeolocationManager { static WebGeolocationManager *s; if (!s) s = [self new]; return s; }
- (void)setDelegate:(id)d {}
- (void)forwardInvocation:(NSInvocation *)inv {}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [NSMethodSignature signatureWithObjCTypes:"v@:@"]; }
@end

// -[NSData initWithBytesNoCopy:length:deallocator:] arrived in iOS 7. iOS 6 has
// initWithBytes:length: (which copies), so copy and immediately hand the caller's
// buffer to its deallocator - semantically identical, the buffer is no longer
// referenced.
@interface NSData (RevIOS6Compat) @end
@implementation NSData (RevIOS6Compat)
- (id)initWithBytesNoCopy:(void *)bytes length:(NSUInteger)length deallocator:(void (^)(void *, NSUInteger))deallocator
{
    self = [self initWithBytes:bytes length:length];
    if (deallocator) deallocator(bytes, length);
    return self;
}
@end


// +[NSCalendar calendarWithIdentifier:] is iOS 8+. iOS 6 has the initialiser.
@interface NSCalendar (RevIOS6Compat) @end
@implementation NSCalendar (RevIOS6Compat)
+ (id)calendarWithIdentifier:(NSString *)identifier
{
    return [[[NSCalendar alloc] initWithCalendarIdentifier:identifier] autorelease];
}
@end

// iOS 6 WebKit/WebCore internal C++ entry points MobileSafari calls that upstream
// WebKit 2.54 dropped. All are memory diagnostics or simple getters - no-op /
// best-effort bodies. Mangling ignores return type, so any type that compiles is
// fine as long as the name matches what Safari imports.
#include <stddef.h>
#include <stdint.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
namespace WebKit {
    class MemoryMeasure {
    public:
        ~MemoryMeasure();
        static void enableLogging(bool);
        static bool isLoggingEnabled();
        static size_t taskMemory();
    };
    MemoryMeasure::~MemoryMeasure() {}
    void MemoryMeasure::enableLogging(bool) {}
    bool MemoryMeasure::isLoggingEnabled() { return false; }
    size_t MemoryMeasure::taskMemory() {
        task_basic_info info;
        mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
            return info.resident_size;
        return 0;
    }
}
namespace WebCore {
    uint64_t systemTotalMemory();
    uint64_t systemTotalMemory() {
        uint64_t bytes = 0;
        size_t len = sizeof(bytes);
        if (sysctlbyname("hw.memsize", &bytes, &len, 0, 0) == 0 && bytes)
            return bytes;
        return (uint64_t)512 * 1024 * 1024;
    }
    void* currentCFHTTPCookieStorage();
    void* currentCFHTTPCookieStorage() { return 0; }
}

// iOS 6 WTF threading primitives MobileSafari links that 2.54 renamed away. Safari
// imports only the Mutex/ThreadCondition CONSTRUCTORS - lock/unlock/wait are
// inlined in Safari against a member at offset 0 - so these are thin pthread
// wrappers whose object is a pthread primitive at offset 0.
#include <pthread.h>
#include <dispatch/dispatch.h>
namespace WTF {
    typedef uint32_t ThreadIdentifier;
    typedef void (*ThreadFunction)(void* argument);

    class Mutex { public: Mutex(); pthread_mutex_t m_mutex; };
    Mutex::Mutex() { pthread_mutex_init(&m_mutex, 0); }

    class ThreadCondition { public: ThreadCondition(); pthread_cond_t m_condition; };
    ThreadCondition::ThreadCondition() { pthread_cond_init(&m_condition, 0); }

    static pthread_mutex_t s_staticMutex = PTHREAD_MUTEX_INITIALIZER;
    void lockAtomicallyInitializedStaticMutex();
    void unlockAtomicallyInitializedStaticMutex();
    void lockAtomicallyInitializedStaticMutex() { pthread_mutex_lock(&s_staticMutex); }
    void unlockAtomicallyInitializedStaticMutex() { pthread_mutex_unlock(&s_staticMutex); }

    ThreadIdentifier currentThread();
    ThreadIdentifier currentThread() { return (ThreadIdentifier)pthread_mach_thread_np(pthread_self()); }

    struct ThreadTrampoline { ThreadFunction entry; void* data; };
    static void* threadStart(void* p) {
        ThreadTrampoline t = *(ThreadTrampoline*)p; free(p);
        t.entry(t.data);
        return 0;
    }
    ThreadIdentifier createThread(ThreadFunction, void*, const char*);
    ThreadIdentifier createThread(ThreadFunction entry, void* data, const char*) {
        ThreadTrampoline* t = (ThreadTrampoline*)malloc(sizeof(ThreadTrampoline));
        t->entry = entry; t->data = data;
        pthread_t thread;
        if (pthread_create(&thread, 0, threadStart, t) != 0) { free(t); return 0; }
        return (ThreadIdentifier)pthread_mach_thread_np(thread);
    }

    void callOnMainThread(ThreadFunction, void*);
    void callOnMainThread(ThreadFunction fn, void* data) {
        dispatch_async(dispatch_get_main_queue(), ^{ fn(data); });
    }
}

#include <execinfo.h>
#include <signal.h>
static void rev_crash_handler(int sig) {
    fprintf(stderr, "[REVCRASH] signal %d\n", sig);
    void* bt[64];
    int n = backtrace(bt, 64);
    backtrace_symbols_fd(bt, n, fileno(stderr));
    fflush(stderr);
    signal(sig, SIG_DFL);
    raise(sig);
}
__attribute__((constructor))
static void rev_crash_init() {
    signal(SIGSEGV, rev_crash_handler);
    signal(SIGBUS, rev_crash_handler);
    signal(SIGABRT, rev_crash_handler);
    signal(SIGILL, rev_crash_handler);
    signal(SIGTRAP, rev_crash_handler);
}

// ---- Dynamic bookmarks start page: a blank Safari tab renders the user's
// bookmarks (live from Bookmarks.db) as tiles instead of a white page.
#import <objc/runtime.h>
#import <sqlite3.h>

@interface NSObject (RevStartPage)
- (id)browserView;
- (void)loadHTMLString:(NSString *)string baseURL:(id)url;
@end

static NSString *revHTMLEscape(const char *s) {
    if (!s) return @"";
    NSMutableString *m = [NSMutableString stringWithUTF8String:s];
    [m replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"'" withString:@"&#39;" options:0 range:NSMakeRange(0, m.length)];
    return m;
}

static NSString *revJSEscape(const char *s) {
    if (!s) return @"";
    NSMutableString *m = [NSMutableString stringWithUTF8String:s];
    [m replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"</" withString:@"<\\/" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\r" withString:@" " options:0 range:NSMakeRange(0, m.length)];
    return m;
}

static NSString *revBase64(NSData *data) {
    static const char t[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const uint8_t *b = (const uint8_t *)data.bytes;
    NSUInteger len = data.length;
    NSMutableString *out = [NSMutableString stringWithCapacity:((len + 2) / 3) * 4];
    for (NSUInteger i = 0; i < len; i += 3) {
        uint32_t n = (uint32_t)b[i] << 16;
        if (i + 1 < len) n |= (uint32_t)b[i + 1] << 8;
        if (i + 2 < len) n |= (uint32_t)b[i + 2];
        [out appendFormat:@"%c%c%c%c", t[(n >> 18) & 63], t[(n >> 12) & 63],
            (i + 1 < len) ? t[(n >> 6) & 63] : '=', (i + 2 < len) ? t[n & 63] : '='];
    }
    return out;
}

static NSString *revFaviconDir(void) { return @"/var/mobile/Library/Safari/RevFavicons"; }

static NSString *revFaviconPath(NSString *host) {
    NSString *safe = [host stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [revFaviconDir() stringByAppendingFormat:@"/%@.png", safe];
}

static NSString *revFaviconSrc(NSString *host) {
    NSString *google = [NSString stringWithFormat:@"https://www.google.com/s2/favicons?sz=128&domain=%@", host];
    NSString *path = revFaviconPath(host);
    NSData *cached = [NSData dataWithContentsOfFile:path];
    if (cached.length > 50)
        return [NSString stringWithFormat:@"data:image/png;base64,%@", revBase64(cached)];
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("rev.favicons", 0); });
    NSString *g = [google copy];
    NSString *p = [path copy];
    dispatch_async(q, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:revFaviconDir() withIntermediateDirectories:YES attributes:nil error:nil];
        if ([fm fileExistsAtPath:p]) return;
        NSData *d = [NSData dataWithContentsOfURL:[NSURL URLWithString:g]];
        if (d.length > 50) [d writeToFile:p atomically:YES];
    });
    return @"";
}

static NSString *revHTMLEsc(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    NSMutableString *m = [[s mutableCopy] autorelease];
    [m replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"'" withString:@"&#39;" options:0 range:NSMakeRange(0, m.length)];
    return m;
}

#define REV_FOLDER_SVG @"<svg viewBox='0 0 48 48'><path fill='#8aa0bf' d='M5 13c0-1.7 1.3-3 3-3h11l4 4h17c1.7 0 3 1.3 3 3v18c0 1.7-1.3 3-3 3H8c-1.7 0-3-1.3-3-3z'/><path fill='#a7bad6' d='M5 18h38v20c0 1.7-1.3 3-3 3H8c-1.7 0-3-1.3-3-3z'/></svg>"

static NSString *revStartPageHTMLForFolder(int folderId) {
    NSMutableString *grid = [NSMutableString string];
    NSString *title = @"Favorites";
    sqlite3 *db = NULL;
    if (sqlite3_open_v2("/var/mobile/Library/Safari/Bookmarks.db", &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
        if (folderId != 0) {
            sqlite3_stmt *ts = NULL;
            if (sqlite3_prepare_v2(db, "SELECT title FROM bookmarks WHERE id=?", -1, &ts, NULL) == SQLITE_OK) {
                sqlite3_bind_int(ts, 1, folderId);
                if (sqlite3_step(ts) == SQLITE_ROW) {
                    const char *t = (const char *)sqlite3_column_text(ts, 0);
                    if (t) title = [NSString stringWithUTF8String:t];
                }
                sqlite3_finalize(ts);
            }
        }
        sqlite3_stmt *st = NULL;
        const char *q = "SELECT id,type,title,url FROM bookmarks WHERE parent=? AND deleted=0 AND hidden=0 AND special_id=0 AND title NOT LIKE 'com.apple.%' ORDER BY order_index";
        if (sqlite3_prepare_v2(db, q, -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_int(st, 1, folderId);
            while (sqlite3_step(st) == SQLITE_ROW) {
                int idv = sqlite3_column_int(st, 0);
                int type = sqlite3_column_int(st, 1);
                const char *titleC = (const char *)sqlite3_column_text(st, 2);
                const char *urlC = (const char *)sqlite3_column_text(st, 3);
                NSString *name = revHTMLEsc(titleC ? [NSString stringWithUTF8String:titleC] : @"");
                if (type == 1) {
                    [grid appendFormat:@"<a class='t' href='favorites:///folder/%d'><span class='i fo'>%@</span><span class='n'>%@</span></a>", idv, REV_FOLDER_SVG, name];
                } else {
                    NSString *rawUrl = urlC ? [NSString stringWithUTF8String:urlC] : @"";
                    NSString *host = [[NSURL URLWithString:rawUrl] host];
                    NSString *fav = host.length ? revFaviconSrc(host) : @"";
                    NSString *img = fav.length ? [NSString stringWithFormat:@"<img src='%@'>", revHTMLEsc(fav)] : @"";
                    [grid appendFormat:@"<a class='t' href='%@'><span class='i'>%@</span><span class='n'>%@</span></a>", revHTMLEsc(rawUrl), img, name];
                }
            }
            sqlite3_finalize(st);
        }
        sqlite3_close(db);
    }
    if (grid.length == 0)
        [grid appendString:@"<div class='empty'>Empty</div>"];
    return [NSString stringWithFormat:@"<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>%@</title>"
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1,minimum-scale=1,user-scalable=no\">"
        "<style>"
        "*{margin:0;padding:0;box-sizing:border-box;-webkit-tap-highlight-color:transparent}"
        "body{font-family:'Helvetica Neue',Helvetica,sans-serif;background:#dfe3e8;color:#333;padding:10px 12px}"
        ".hdr{font-size:12px;font-weight:600;color:#8a8f96;text-transform:uppercase;letter-spacing:.4px;margin:2px 2px 10px}"
        ".grid{font-size:0}"
        ".t{display:inline-block;width:64px;vertical-align:top;margin:0 6px 12px 0;text-decoration:none;color:#444;text-align:center}"
        ".i{display:flex;align-items:center;justify-content:center;width:60px;height:60px;margin:0 auto 5px;"
        "border-radius:13px;overflow:hidden;background:linear-gradient(#fff,#e9edf2);border:1px solid #c3c9d2;"
        "box-shadow:0 1px 1px rgba(255,255,255,.7) inset,0 1px 2px rgba(0,0,0,.14);"
        "-webkit-transition:-webkit-transform .1s ease,opacity .1s ease}"
        ".t:active .i{-webkit-transform:scale(.88);opacity:.6}"
        ".t.load .i{opacity:.45}"
        ".t.load .n{opacity:.45}"
        ".i.fo{background:linear-gradient(#eef1f5,#dbe1ea)}"
        ".i img{width:44px;height:44px}"
        ".i svg{width:40px;height:40px}"
        ".n{display:block;width:64px;font-size:11px;line-height:14px;height:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}"
        ".empty{color:#9aa0a8;font-size:13px;margin:8px 2px}"
        "</style></head><body>"
        "<div class=\"hdr\">%@</div><div class=\"grid\">%@</div>"
        "</body></html>", revHTMLEsc(title), revHTMLEsc(title), grid];
}

@interface RevStartPageProtocol : NSURLProtocol { BOOL _stopped; } @end
@implementation RevStartPageProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [[[request URL] scheme] caseInsensitiveCompare:@"favorites"] == NSOrderedSame;
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b { return NO; }
- (void)startLoading {
    [self performSelector:@selector(revDeliver) withObject:nil afterDelay:0.0];
}
- (void)revDeliver {
    if (_stopped)
        return;
    int folderId = 0;
    NSString *path = [[[self request] URL] path];
    NSRange fr = [path rangeOfString:@"/folder/"];
    if (fr.location != NSNotFound)
        folderId = [[path substringFromIndex:fr.location + fr.length] intValue];
    NSData *data = [revStartPageHTMLForFolder(folderId) dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *headers = [NSDictionary dictionaryWithObjectsAndKeys:
        @"text/html; charset=utf-8", @"Content-Type",
        [NSString stringWithFormat:@"%lu", (unsigned long)data.length], @"Content-Length", nil];
    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:[[self request] URL] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:headers];
    id<NSURLProtocolClient> client = [self client];
    [client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [client URLProtocol:self didLoadData:data];
    [client URLProtocolDidFinishLoading:self];
    [resp release];
}
- (void)stopLoading {
    _stopped = YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}
@end

@interface NSObject (RevTabDoc)
- (void)loadURL:(NSURL *)url userDriven:(BOOL)userDriven;
@end

// ---- Preferences (space.kern0x1b.rev, written by the Settings PreferenceBundle).
static id revPref(NSString *key) {
    CFPreferencesAppSynchronize(CFSTR("space.kern0x1b.rev"));
    CFPropertyListRef v = CFPreferencesCopyAppValue((CFStringRef)key, CFSTR("space.kern0x1b.rev"));
    return [(id)v autorelease];
}
static BOOL revPrefBool(NSString *key, BOOL def) {
    id v = revPref(key);
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : def;
}
static NSString *revPrefString(NSString *key) {
    id v = revPref(key);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}
static BOOL revInjectionEnabledForThisApp(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid) return NO;
    id apps = revPref(@"InjectedApps");
    if ([apps isKindOfClass:[NSDictionary class]]) {
        id v = [apps objectForKey:bid];
        if (v) return [v boolValue];
    }
    return [bid isEqualToString:@"com.apple.mobilesafari"];
}

// window.WebAssembly (wasm3) is installed at window-object-clear, before the page's
// scripts run. Swizzle whichever Safari frame-load-delegate class implements
// -webView:didClearWindowObject:forFrame:, chain the original, then install RevWasm.
#import "RevWasm.h"
static void (*g_didClear_orig)(id, SEL, id, id, id);
static void rev_didClear(id self, SEL _cmd, id webView, id windowObject, id frame) {
    if (g_didClear_orig) g_didClear_orig(self, _cmd, webView, windowObject, frame);
    @try { [RevWasm installInWebView:(WebView *)webView forFrame:(WebFrame *)frame]; } @catch (id e) {}
}
static void rev_install_wasm_hook(void) {
    SEL sel = @selector(webView:didClearWindowObject:forFrame:);
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        Method m = class_getInstanceMethod(classes[i], sel);
        if (m && class_getMethodImplementation(classes[i], sel) != (IMP)rev_didClear) {
            g_didClear_orig = (void (*)(id, SEL, id, id, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)rev_didClear);
            break;
        }
    }
    free(classes);
}

static IMP g_openBlank_orig;
static id rev_openBlankTabDocument(id self, SEL _cmd) {
    id doc = ((id(*)(id, SEL))g_openBlank_orig)(self, _cmd);
    if (!doc)
        return doc;
    NSString *target = nil;
    if (revPrefBool(@"CustomURLEnabled", NO)) {
        NSString *u = revPrefString(@"CustomURL");
        u = [u stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (u.length) {
            if ([u rangeOfString:@"://"].location == NSNotFound)
                u = [@"https://" stringByAppendingString:u];
            target = u;
        }
    }
    if (!target && revPrefBool(@"NewTabStartPage", YES))
        target = @"favorites:///";
    if (!target)
        return doc;
    id docRef = [doc retain];
    NSString *t = [target copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if ([docRef respondsToSelector:@selector(loadURL:userDriven:)])
                [docRef loadURL:[NSURL URLWithString:t] userDriven:NO];
        } @catch (id e) {}
        [docRef release];
        [t release];
    });
    return doc;
}

__attribute__((constructor))
static void rev_startpage_init(void) {
    if (!revInjectionEnabledForThisApp())
        return;
    [NSURLProtocol registerClass:[RevStartPageProtocol class]];
    rev_install_wasm_hook();

    Class tc = NSClassFromString(@"TabController");
    if (!tc) return;
    Method m = class_getInstanceMethod(tc, @selector(_openBlankTabDocument));
    if (!m) return;
    g_openBlank_orig = method_getImplementation(m);
    method_setImplementation(m, (IMP)rev_openBlankTabDocument);
}
