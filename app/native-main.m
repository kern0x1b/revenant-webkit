#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <sys/time.h>
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

static double millisecondsSinceExec(void)
{
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct kinfo_proc process;
    size_t size = sizeof(process);
    if (sysctl(mib, 4, &process, &size, NULL, 0) != 0 || size == 0)
        return -1;
    struct timeval now;
    gettimeofday(&now, NULL);
    double started = process.kp_proc.p_starttime.tv_sec
        + process.kp_proc.p_starttime.tv_usec / 1000000.0;
    return ((now.tv_sec + now.tv_usec / 1000000.0) - started) * 1000.0;
}

static void imageArrived(const struct mach_header *header, intptr_t slide)
{
    Dl_info where;
    const char *path = dladdr((const void *)header, &where) ? where.dli_fname : "?";
    const char *name = strrchr(path, '/');
    FILE *log = fopen("/tmp/native.log", "a");
    if (log) {
        fprintf(log, "%.3f [dyld] %s\n", CFAbsoluteTimeGetCurrent(), name ? name + 1 : path);
        fclose(log);
    }
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
    double beforeMain = millisecondsSinceExec();

    char bundle[PATH_MAX];
    bundleDirectory(bundle, sizeof(bundle), argv[0]);

    // Everything the engine prints goes nowhere.
    //
    // Launched by SpringBoard, this process has no terminal, and the log
    // machinery WTFLogAlways ends in - os_log - resolves to a compat stub that
    // discards its argument. So every port probe behind a /tmp flag file wrote
    // to a closed descriptor: the layout timer, the tile chatter, the option
    // dump. An investigation into grid layout enabled the layout instrument,
    // got zero lines, and had to fall back to probing the DOM from JavaScript.
    //
    // Pointing the descriptor at a file makes all of them work at once. It is
    // separate from /tmp/native.log, which the interface writes itself, so the
    // two do not interleave.
    freopen("/tmp/native-stderr.log", "a", stderr);
    setvbuf(stderr, NULL, _IOLBF, 0);

    note(@"[start] main reached %.0f ms after exec, pass %s", beforeMain,
         getenv("DYLD_FRAMEWORK_PATH") ? "two" : "one");
    if (getenv("DYLD_FRAMEWORK_PATH") && !access("/tmp/native-watch-images", F_OK))
        _dyld_register_func_for_add_image(imageArrived);

    if (!access("/tmp/native-system-engine", F_OK)) {
        note(@"running against the system engine by request");
        setenv("DYLD_FRAMEWORK_PATH", "", 1);
    }

    // The collector sizes its heap from the machine's memory, and 512 MB reads
    // as roomy - the heap then grows past what jetsam allows this process and
    // the system kills it mid-scroll. Both soak deaths were exactly this: no
    // crash, no signal, resident climbing to ~170 MB and then SIGKILL. Telling
    // the collector the machine is small keeps it collecting instead of growing.
    // Measured on a fixed local workload, so the answer is not the network's:
    //
    //   told 64 MB   benchmark 2481 ms   resident 170.3 MB   JS heap 22.5 MB
    //   told 24 MB   benchmark 2492 ms   resident 133.0 MB   JS heap  1.0 MB
    //
    // Thirty-seven megabytes back for a difference in speed smaller than the
    // noise between two runs. The collector spends the difference on collecting,
    // which on this device is the better trade: the memory it was holding is
    // what the system kills the process for.
    setenv("JSC_forceRAMSize", "25165824", 1);

    // The optimising compiler, kept within this machine.
    //
    // Its working vectors are the second largest allocator in the process after
    // the parser - AbstractValue, VariableEvent and the assembler's link records
    // together accounted for 58 MB over one feed. Two things bound them: one
    // compiler thread rather than one per core, on a device whose other core is
    // running the page; and a smaller ceiling on what is worth optimising, so a
    // single enormous function does not build enormous vectors.
    //
    // Measured over two pairs of runs on the site: parked 3% and 1% against 4%,
    // freezes 2 and 1 against 3, memory unchanged.
    setenv("JSC_numberOfDFGCompilerThreads", "1", 1);
    setenv("JSC_maximumOptimizationCandidateBytecodeCost", "20000", 1);

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
        char inserted[PATH_MAX * 2];
        inserted[0] = 0;
        if (access("/tmp/native-system-tls", F_OK) != 0 && access(tls, F_OK) == 0) {
            strlcpy(inserted, tls, sizeof(inserted));
            note(@"using our own TLS: %s", tls);
        }

        // The memory probe, when it is asked for. It charges every large block
        // to the code that asked for it, which is how the engine's own heap gets
        // a name without the heap-breakdown build, which traps on this port.
        char probe[PATH_MAX];
        snprintf(probe, sizeof(probe), "%s/MemProbe.dylib", bundle);
        if (access("/tmp/native-mem-probe", F_OK) == 0 && access(probe, F_OK) == 0) {
            if (inserted[0])
                strlcat(inserted, ":", sizeof(inserted));
            strlcat(inserted, probe, sizeof(inserted));
            note(@"charging large allocations to their callers");
        }
        if (inserted[0])
            setenv("DYLD_INSERT_LIBRARIES", inserted, 1);

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
    double beforeInterface = CFAbsoluteTimeGetCurrent();
    void *image = dlopen(interface, RTLD_LAZY | RTLD_GLOBAL);
    {
        struct task_basic_info info;
        mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
        double resident = 0, virt = 0;
        if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
            resident = info.resident_size / 1048576.0;
            virt = info.virtual_size / 1048576.0;
        }
        note(@"[start] interface and UIKit loaded in %.0f ms, %.1f MB in the process, %.1f MB mapped",
             (CFAbsoluteTimeGetCurrent() - beforeInterface) * 1000.0, resident, virt);
    }
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
