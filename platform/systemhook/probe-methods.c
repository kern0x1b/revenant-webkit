#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <objc/objc.h>
#include <objc/runtime.h>

static void logLine(const char *line)
{
    FILE *f = fopen("/tmp/methods-result.log", "a");
    if (f) {
        fprintf(f, "%s\n", line);
        fclose(f);
    }
}

static void dumpMethods(const char *className)
{
    Class cls = objc_getClass(className);
    if (!cls) {
        logLine("class not found");
        return;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    char line[256];
    snprintf(line, sizeof(line), "-- instance methods of %s (%u) --", className, count);
    logLine(line);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *name = sel_getName(sel);
        if (strstr(name, "nlock") || strstr(name, "assword") || strstr(name, "asscode") || strstr(name, "ttempt")) {
            snprintf(line, sizeof(line), "  %s", name);
            logLine(line);
        }
    }
    free(methods);

    count = 0;
    Method *classMethods = class_copyMethodList(object_getClass((id)cls), &count);
    snprintf(line, sizeof(line), "-- class methods of %s (%u) --", className, count);
    logLine(line);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(classMethods[i]);
        const char *name = sel_getName(sel);
        if (strstr(name, "hared") || strstr(name, "nlock")) {
            snprintf(line, sizeof(line), "  %s", name);
            logLine(line);
        }
    }
    free(classMethods);
}

__attribute__((constructor))
static void probeMethods(void)
{
    logLine("=== probe-methods entered ===");
    dumpMethods("SBAwayController");
    dumpMethods("SBLockScreenManager");
    dumpMethods("SBDeviceLockController");
    dumpMethods("SBUIController");
    logLine("=== done ===");
}
