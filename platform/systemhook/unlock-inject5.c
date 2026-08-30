/* Round 6. _updateDeviceLockedState overwrote SBDeviceLockController's own
 * raw state setter within the same injection (confirmed in round 5), which
 * means the actual ground truth SpringBoard reconciles against is lower
 * than SBDeviceLockController itself - the data-protection keybag, managed
 * by keybagd (seen spinning up in `ps` right after the first password
 * verification call) via MobileKeyBag.framework. dlsym against that
 * framework, already loaded in SpringBoard, resolved MKBUnlockDevice (real
 * symbol, confirmed present - see probe-keybag.c); MKBUnlockDeviceWithPasscode
 * does not exist on this OS version, ruling out that commonly-cited name.
 *
 * First attempt (a single NSString/CFStringRef argument, no flags) crashed
 * SpringBoard - recovered cleanly, launchd restarted it automatically, but
 * confirms that signature is wrong. Second attempt: (NSData *passcode, int
 * flags), matching a signature found afterward - unverified against any
 * primary source, so still a guess, but it corrects both likely causes of
 * the crash (wrong argument type, missing second argument) rather than
 * repeating the same shape with a different type. */
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include <objc/objc.h>
#include <objc/runtime.h>
#include <objc/message.h>

typedef int (*MKBUnlockDevice_t)(id passcode, int flags);

static void logLine(const char *line)
{
    FILE *f = fopen("/tmp/unlock-result.log", "a");
    if (f) {
        fprintf(f, "%s\n", line);
        fclose(f);
    }
}

static id nsData(const char *utf8)
{
    Class dataClass = objc_getClass("NSData");
    SEL sel = sel_registerName("dataWithBytes:length:");
    return ((id (*)(id, SEL, const void *, unsigned long))objc_msgSend)
        ((id)dataClass, sel, utf8, strlen(utf8));
}

static BOOL boolQuery(const char *className, const char *sharedSelName, const char *querySelName)
{
    Class cls = objc_getClass(className);
    if (!cls) return -1;
    id shared = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName(sharedSelName));
    if (!shared) return -1;
    SEL sel = sel_registerName(querySelName);
    if (!class_respondsToSelector(object_getClass(shared), sel)) return -1;
    return ((BOOL (*)(id, SEL))objc_msgSend)(shared, sel);
}

static void logState(const char *label)
{
    char line[192];
    snprintf(line, sizeof(line), "%s: SBAwayController.isLocked=%d SBDeviceLockController.isDeviceLocked=%d",
        label,
        boolQuery("SBAwayController", "sharedAwayController", "isLocked"),
        boolQuery("SBDeviceLockController", "sharedController", "isDeviceLocked"));
    logLine(line);
}

__attribute__((constructor))
static void unlockInject(void)
{
    logLine("=== round 6 entered ===");
    logState("before");

    void *handle = dlopen("/System/Library/PrivateFrameworks/MobileKeyBag.framework/MobileKeyBag", RTLD_NOW);
    MKBUnlockDevice_t fn = handle ? (MKBUnlockDevice_t)dlsym(handle, "MKBUnlockDevice") : NULL;
    if (!fn) {
        logLine("MKBUnlockDevice not resolved");
        return;
    }

    logLine("calling MKBUnlockDevice(data(\"1511\"), 0)");
    int result = fn(nsData("1511"), 0);
    char line[64];
    snprintf(line, sizeof(line), "MKBUnlockDevice returned %d", result);
    logLine(line);

    logState("after");
    logLine("=== done ===");
}
