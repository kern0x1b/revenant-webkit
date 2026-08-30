/* See earlier revisions in git history / prior build logs for how the two
 * classes and the password-verification selector were found by walking the
 * real runtime method lists (probe-methods.c) rather than assumed.
 *
 * attemptDeviceUnlockWithPassword:appRequested: verifies the password (YES)
 * and unlockWithSound: runs without crashing, but isLocked/isDeviceLocked
 * stayed YES afterward (confirmed via probe-state.c) - the visible lock UI
 * was not actually dismissed. Trying the other zero-argument dismissal
 * selectors from the same method dump instead of guessing the 4-argument
 * private variant's parameter types blind. */
#include <stdio.h>
#include <objc/objc.h>
#include <objc/runtime.h>
#include <objc/message.h>

static void logLine(const char *line)
{
    FILE *f = fopen("/tmp/unlock-result.log", "a");
    if (f) {
        fprintf(f, "%s\n", line);
        fclose(f);
    }
}

static id nsString(const char *utf8)
{
    Class stringClass = objc_getClass("NSString");
    SEL stringWithUTF8Sel = sel_registerName("stringWithUTF8String:");
    return ((id (*)(id, SEL, const char *))objc_msgSend)((id)stringClass, stringWithUTF8Sel, utf8);
}

static void tryVoidCall(id target, const char *selName)
{
    SEL sel = sel_registerName(selName);
    if (!target || !class_respondsToSelector(object_getClass(target), sel)) {
        logLine(selName);
        logLine("  -> not found");
        return;
    }
    logLine(selName);
    ((void (*)(id, SEL))objc_msgSend)(target, sel);
    logLine("  -> returned, no crash");
}

__attribute__((constructor))
static void unlockInject(void)
{
    logLine("constructor entered (round 2)");

    Class lockControllerClass = objc_getClass("SBDeviceLockController");
    Class awayControllerClass = objc_getClass("SBAwayController");
    if (!lockControllerClass || !awayControllerClass) {
        logLine("required class missing");
        return;
    }

    id lockController = ((id (*)(id, SEL))objc_msgSend)((id)lockControllerClass, sel_registerName("sharedController"));
    id awayController = ((id (*)(id, SEL))objc_msgSend)((id)awayControllerClass, sel_registerName("sharedAwayController"));

    SEL verifySel = sel_registerName("attemptDeviceUnlockWithPassword:appRequested:");
    if (class_respondsToSelector(object_getClass(lockController), verifySel)) {
        BOOL verified = ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)
            (lockController, verifySel, nsString("1511"), NO);
        logLine(verified ? "password re-verified: YES" : "password re-verified: NO");
    }

    /* Every zero-argument dismissal-shaped selector from the earlier method
     * dump, tried in order most to least likely - each guarded, so a
     * not-found selector just logs and moves on rather than guessing types. */
    tryVoidCall(awayController, "attemptUnlock");
    tryVoidCall(awayController, "unlockAlwaysFullscreenAwayView");
    tryVoidCall(awayController, "_disablePluginControllersForUnlock");
    tryVoidCall(awayController, "_sendToDeviceLockOwnerDeviceUnlockSucceeded");

    /* None of the above flipped isLocked/isDeviceLocked (checked separately
     * via probe-state.c). Trying the private 4-argument variant that names
     * exactly what is wanted - bypassPinLock:YES - with sound off, source 0
     * (the passcode/manual source is conventionally 0 in SpringBoard's own
     * enums of this era), not an auto-unlock. All four are 4-byte register
     * values on this 32-bit target (BOOL/int/NSInteger alike), so an exact
     * type guess for "unlockSource" does not risk a stack/register
     * corruption the way guessing an object-vs-scalar argument would -
     * worst case this is a no-op or a SpringBoard crash, and SpringBoard is
     * restarted automatically by launchd either way. */
    SEL fullSel = sel_registerName("_unlockWithSound:unlockSource:isAutoUnlock:bypassPinLock:");
    if (class_respondsToSelector(object_getClass(awayController), fullSel)) {
        logLine("calling _unlockWithSound:unlockSource:isAutoUnlock:bypassPinLock:");
        ((void (*)(id, SEL, BOOL, int, BOOL, BOOL))objc_msgSend)
            (awayController, fullSel, NO, 0, NO, YES);
        logLine("  -> returned, no crash");
    } else {
        logLine("_unlockWithSound:unlockSource:isAutoUnlock:bypassPinLock: not found");
    }

    logLine("=== done ===");
}
