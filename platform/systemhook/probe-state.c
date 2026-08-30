#include <stdio.h>
#include <objc/objc.h>
#include <objc/runtime.h>
#include <objc/message.h>

static void logLine(const char *line)
{
    FILE *f = fopen("/tmp/state-result.log", "a");
    if (f) {
        fprintf(f, "%s\n", line);
        fclose(f);
    }
}

static void tryBoolCall(id target, const char *selName)
{
    SEL sel = sel_registerName(selName);
    char line[256];
    if (!target || !class_respondsToSelector(object_getClass(target), sel)) {
        snprintf(line, sizeof(line), "%s: not found", selName);
        logLine(line);
        return;
    }
    BOOL result = ((BOOL (*)(id, SEL))objc_msgSend)(target, sel);
    snprintf(line, sizeof(line), "%s: %s", selName, result ? "YES" : "NO");
    logLine(line);
}

__attribute__((constructor))
static void probeState(void)
{
    logLine("=== probe-state entered ===");

    Class awayClass = objc_getClass("SBAwayController");
    id away = awayClass ? ((id (*)(id, SEL))objc_msgSend)((id)awayClass, sel_registerName("sharedAwayController")) : nil;
    tryBoolCall(away, "isLocked");
    tryBoolCall(away, "isMakingEmergencyCall");
    tryBoolCall(away, "isPasswordProtected");

    Class lockClass = objc_getClass("SBDeviceLockController");
    id lock = lockClass ? ((id (*)(id, SEL))objc_msgSend)((id)lockClass, sel_registerName("sharedController")) : nil;
    tryBoolCall(lock, "isDeviceLocked");
    tryBoolCall(lock, "isPasswordProtected");

    Class uiClass = objc_getClass("SBUIController");
    id ui = uiClass ? ((id (*)(id, SEL))objc_msgSend)((id)uiClass, sel_registerName("sharedInstance")) : nil;
    tryBoolCall(ui, "isSystemGestureStateActive");

    logLine("=== done ===");
}
