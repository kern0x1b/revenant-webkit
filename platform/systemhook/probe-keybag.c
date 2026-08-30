#include <stdio.h>
#include <dlfcn.h>

static void logLine(const char *line)
{
    FILE *f = fopen("/tmp/keybag-result.log", "a");
    if (f) {
        fprintf(f, "%s\n", line);
        fclose(f);
    }
}

__attribute__((constructor))
static void probeKeybag(void)
{
    logLine("=== probe-keybag entered ===");

    void *handle = dlopen("/System/Library/PrivateFrameworks/MobileKeyBag.framework/MobileKeyBag", RTLD_NOW);
    char line[256];
    snprintf(line, sizeof(line), "dlopen handle: %p (dlerror: %s)", handle, dlerror() ?: "none");
    logLine(line);
    if (!handle)
        handle = RTLD_DEFAULT;

    const char *candidates[] = {
        "MKBUnlockDeviceWithPasscode",
        "MKBDeviceUnlock",
        "MKBUnlockDevice",
        "MKBGetDeviceLockState",
        "MKBDeviceIsLocked",
        "MKBGetDeviceLockStatus",
        "MKBDeviceUnlockedSinceBoot",
        NULL
    };
    for (int i = 0; candidates[i]; i++) {
        void *sym = dlsym(handle, candidates[i]);
        snprintf(line, sizeof(line), "%s: %p", candidates[i], sym);
        logLine(line);
    }

    logLine("=== done ===");
}
