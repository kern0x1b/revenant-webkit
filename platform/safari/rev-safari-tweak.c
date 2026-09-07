// Substrate tweak: when Mobile Safari launches, put our WebKit 2.54 under it.
// dyld honours no DYLD_* substitution for an already-running image, so the tweak
// sets the variables and re-execs; the second launch loads our engine first.
#include <stdlib.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <string.h>
#include <stdio.h>

extern char ***_NSGetArgv(void);

__attribute__((constructor))
static void rev_safari_init(void)
{
    freopen("/tmp/rev-safari-stderr.log", "a", stderr);
    setvbuf(stderr, 0, _IOLBF, 0);
    fprintf(stderr, "[tweak] ctor pass, active=%s\n", getenv("REV_SAFARI_ACTIVE") ? "yes" : "no");
    if (getenv("REV_SAFARI_ACTIVE"))
        return;                      // already the re-exec'd launch
    setenv("REV_SAFARI_ACTIVE", "1", 1);
    setenv("DYLD_FORCE_FLAT_NAMESPACE", "1", 1);
    setenv("DYLD_INSERT_LIBRARIES",
        "/usr/lib/rev-fw/JavaScriptCore.framework/JavaScriptCore:/usr/lib/rev-fw/WebCore.framework/WebCore:/usr/lib/rev-fw/WebKit.framework/WebKit:/usr/lib/rev-safari-compat.dylib:/usr/lib/rev-TLS.dylib", 1);
    setenv("DYLD_FRAMEWORK_PATH", "/usr/lib/rev-fw", 1);
    setenv("JSC_forceRAMSize", "25165824", 1);

    char path[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0)
        return;
    FILE *f = fopen("/tmp/rev-safari-tweak.log", "a");
    if (f) { fprintf(f, "re-exec %s\n", path); fclose(f); }
    execv(path, *_NSGetArgv());
}
