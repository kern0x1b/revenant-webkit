/* Round 5. SBAwayController's own isLocked flipped via -setLocked:NO but
 * reverted shortly after - SBDeviceLockController's isDeviceLocked never
 * budged through any of the SBAwayController-side calls, and is the more
 * likely authoritative source SpringBoard reconciles against (it has its
 * own -_updateDeviceLockedState, which is presumably what re-asserted
 * SBAwayController's flag back to locked). Trying its own private setter,
 * -_setDeviceLockState:, found the same way as everything else this round -
 * walking the real method list (probe-methods2.c), not assumed. */
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

static BOOL boolQuery(id target, const char *selName)
{
    SEL sel = sel_registerName(selName);
    if (!target || !class_respondsToSelector(object_getClass(target), sel))
        return -1;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, sel);
}

__attribute__((constructor))
static void unlockInject(void)
{
    logLine("=== round 5 entered ===");

    Class lockClass = objc_getClass("SBDeviceLockController");
    if (!lockClass) {
        logLine("SBDeviceLockController not found");
        return;
    }
    id lockController = ((id (*)(id, SEL))objc_msgSend)((id)lockClass, sel_registerName("sharedController"));
    if (!lockController) {
        logLine("sharedController nil");
        return;
    }

    char line[128];
    snprintf(line, sizeof(line), "before: isDeviceLocked=%d isBlocked=%d",
        boolQuery(lockController, "isDeviceLocked"), boolQuery(lockController, "isBlocked"));
    logLine(line);

    SEL setStateSel = sel_registerName("_setDeviceLockState:");
    if (class_respondsToSelector(object_getClass(lockController), setStateSel)) {
        logLine("calling _setDeviceLockState:0");
        ((void (*)(id, SEL, int))objc_msgSend)(lockController, setStateSel, 0);
        logLine("  -> returned, no crash");
    } else {
        logLine("_setDeviceLockState: not found");
    }

    snprintf(line, sizeof(line), "after _setDeviceLockState:0: isDeviceLocked=%d isBlocked=%d",
        boolQuery(lockController, "isDeviceLocked"), boolQuery(lockController, "isBlocked"));
    logLine(line);

    /* If the raw state set alone did not stick, _updateDeviceLockedState is
     * presumably what recomputes it from other inputs on its own initiative
     * (the same recompute that likely reverted SBAwayController's flag) -
     * calling it explicitly after clearing whatever it reads from could
     * make the clear the one that sticks instead of being overwritten by a
     * stale reconciliation racing in from elsewhere. */
    SEL updateSel = sel_registerName("_updateDeviceLockedState");
    if (class_respondsToSelector(object_getClass(lockController), updateSel)) {
        logLine("calling _updateDeviceLockedState");
        ((void (*)(id, SEL))objc_msgSend)(lockController, updateSel);
        logLine("  -> returned, no crash");
    }

    snprintf(line, sizeof(line), "after _updateDeviceLockedState: isDeviceLocked=%d isBlocked=%d",
        boolQuery(lockController, "isDeviceLocked"), boolQuery(lockController, "isBlocked"));
    logLine(line);

    logLine("=== done ===");
}
