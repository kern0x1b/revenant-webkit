#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// UIKit reaches WebKit through absolute system paths, and dyld resolves those
// through DYLD_FRAMEWORK_PATH before it consults the shared cache. iOS 6 ignores
// LC_DYLD_ENVIRONMENT and SpringBoard passes no environment, so the app sets the
// variable itself and re-executes. execv keeps the pid, and the launch handshake
// survives it - measured on the device.
//
// UIKit must not be linked by this binary: it has to arrive after the variable
// is in place, which is why the interface lives in NativeUI.dylib.

static void note(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    FILE *log = fopen("/tmp/native.log", "a");
    if (log) {
        fprintf(log, "%.3f %s\n", CFAbsoluteTimeGetCurrent(), [line UTF8String]);
        fclose(log);
    }
    [line release];
}

static void bundleDirectory(char *out, size_t size, const char *argv0)
{
    char self[PATH_MAX];
    uint32_t length = sizeof(self);
    if (_NSGetExecutablePath(self, &length) != 0)
        strlcpy(self, argv0, sizeof(self));
    char directory[PATH_MAX];
    strlcpy(directory, self, sizeof(directory));
    strlcpy(out, dirname(directory), size);
}

int main(int argc, char *argv[])
{
    char bundle[PATH_MAX];
    bundleDirectory(bundle, sizeof(bundle), argv[0]);

    if (!access("/tmp/native-system-engine", F_OK)) {
        note(@"running against the system engine by request");
        setenv("DYLD_FRAMEWORK_PATH", "", 1);
    }

    // The collector sizes its heap from the machine's memory, and 512 MB reads
    // as roomy - the heap then grows past what jetsam allows this process and
    // the system kills it mid-scroll. Both soak deaths were exactly this: no
    // crash, no signal, resident climbing to ~170 MB and then SIGKILL. Telling
    // the collector the machine is small keeps it collecting instead of growing.
    setenv("JSC_forceRAMSize", "67108864", 1);

    // Every JavaScriptCore option, settable without a rebuild.
    //
    // Comparing two values of a tier-up threshold used to mean two full builds
    // and two installs, which is how a day gets spent without an answer. The
    // engine reads any JSC_-prefixed variable at startup, so a file of KEY=VALUE
    // lines read here is a complete A/B harness for the whole option set.
    // The same file also carries engine variables, not just JSC ones - anything
    // the engine reads from the environment at startup.
    FILE *options = fopen("/tmp/native-jsc-options", "r");
    if (options) {
        char line[256];
        while (fgets(line, sizeof(line), options)) {
            char *newline = strchr(line, '\n');
            if (newline)
                *newline = 0;
            char *equals = strchr(line, '=');
            if (!equals || line[0] == '#')
                continue;
            *equals = 0;
            setenv(line, equals + 1, 1);
            fprintf(stderr, "[option] %s=%s\n", line, equals + 1);
        }
        fclose(options);
    }

    if (!getenv("DYLD_FRAMEWORK_PATH")) {
        char frameworks[PATH_MAX];
        snprintf(frameworks, sizeof(frameworks), "%s/Frameworks", bundle);
        setenv("DYLD_FRAMEWORK_PATH", frameworks, 1);
        note(@"relaunching against %s", frameworks);

        // The engine's own TLS, inserted in the same relaunch.
        //
        // This system's SecureTransport offers only cipher suites a current
        // server refuses, so without this the browser cannot open sites that
        // have moved on - measured against claude.ai, which accepts nothing but
        // AEAD suites. TLS.dylib answers those calls over OpenSSL instead. It
        // can be left out with a file, to compare against the system's.
        char tls[PATH_MAX];
        snprintf(tls, sizeof(tls), "%s/TLS.dylib", bundle);
        if (access("/tmp/native-system-tls", F_OK) != 0 && access(tls, F_OK) == 0) {
            setenv("DYLD_INSERT_LIBRARIES", tls, 1);
            note(@"using our own TLS: %s", tls);
        }

        char self[PATH_MAX];
        uint32_t length = sizeof(self);
        if (_NSGetExecutablePath(self, &length) != 0)
            strlcpy(self, argv[0], sizeof(self));
        execv(self, argv);
        note(@"execv failed");
        return 1;
    }

    char interface[PATH_MAX];
    snprintf(interface, sizeof(interface), "%s/NativeUI.dylib", bundle);
    void *image = dlopen(interface, RTLD_LAZY | RTLD_GLOBAL);
    if (!image) {
        note(@"failed to load the interface: %s", dlerror());
        return 1;
    }

    int (*run)(int, char **) = (int (*)(int, char **))dlsym(image, "NativeAppMain");
    if (!run) {
        note(@"NativeAppMain missing: %s", dlerror());
        return 1;
    }

    return run(argc, argv);
}
