/* Round 4: the broader method dump (probe-methods2.c) turned up an explicit
 * -setLocked: setter on SBAwayController, plus -[SpringBoard isLocked] as a
 * separate mirror of the same state. Neither the earlier action-style
 * methods (attemptUnlock, unlockWithSound:, the 4-arg bypassPinLock
 * variant) flipped isLocked, so trying the setter directly this round -
 * the most surgical option, a single BOOL - before anything else. */
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

static BOOL tryBoolQuery(id target, const char *selName)
{
    SEL sel = sel_registerName(selName);
    if (!target || !class_respondsToSelector(object_getClass(target), sel))
        return -1;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, sel);
}

__attribute__((constructor))
static void unlockInject(void)
{
    logLine("=== round 4 entered ===");

    Class awayControllerClass = objc_getClass("SBAwayController");
    if (!awayControllerClass) {
        logLine("SBAwayController not found");
        return;
    }
    id awayController = ((id (*)(id, SEL))objc_msgSend)((id)awayControllerClass, sel_registerName("sharedAwayController"));
    if (!awayController) {
        logLine("sharedAwayController nil");
        return;
    }

    char line[128];
    snprintf(line, sizeof(line), "before: isLocked=%d", tryBoolQuery(awayController, "isLocked"));
    logLine(line);

    SEL setLockedSel = sel_registerName("setLocked:");
    if (class_respondsToSelector(object_getClass(awayController), setLockedSel)) {
        logLine("calling setLocked:NO");
        ((void (*)(id, SEL, BOOL))objc_msgSend)(awayController, setLockedSel, NO);
        logLine("  -> returned, no crash");
    } else {
        logLine("setLocked: not found");
    }

    snprintf(line, sizeof(line), "after setLocked:NO: isLocked=%d", tryBoolQuery(awayController, "isLocked"));
    logLine(line);

    /* If the setter alone did not stick (a computed/overridden property, or
     * one that requires the completion callback to actually commit), try
     * the 3-arg finish-unlock variant next - this is the natural completion
     * call for whatever attemptDeviceUnlockWithPassword:appRequested:
     * started, distinct from the 4-arg bypassPinLock: variant already tried
     * without effect. */
    SEL finishSel = sel_registerName("_finishUnlockWithSound:unlockSource:isAutoUnlock:");
    if (class_respondsToSelector(object_getClass(awayController), finishSel)) {
        logLine("calling _finishUnlockWithSound:unlockSource:isAutoUnlock:");
        ((void (*)(id, SEL, BOOL, int, BOOL))objc_msgSend)
            (awayController, finishSel, NO, 0, NO);
        logLine("  -> returned, no crash");
    } else {
        logLine("_finishUnlockWithSound:unlockSource:isAutoUnlock: not found");
    }

    snprintf(line, sizeof(line), "after _finishUnlock...: isLocked=%d", tryBoolQuery(awayController, "isLocked"));
    logLine(line);

    logLine("=== done ===");
}
