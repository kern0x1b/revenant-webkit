#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <objc/objc.h>
#include <objc/runtime.h>

static void logLine(const char *line)
{
    FILE *f = fopen("/tmp/methods2-result.log", "a");
    if (f) {
        fprintf(f, "%s\n", line);
        fclose(f);
    }
}

static void dumpAll(const char *className, const char *filter)
{
    Class cls = objc_getClass(className);
    if (!cls) {
        char line[256];
        snprintf(line, sizeof(line), "%s: class not found", className);
        logLine(line);
        return;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    char line[256];
    snprintf(line, sizeof(line), "-- %s instance methods matching '%s' --", className, filter);
    logLine(line);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        if (strcasestr(name, filter)) {
            snprintf(line, sizeof(line), "  %s", name);
            logLine(line);
        }
    }
    free(methods);
}

__attribute__((constructor))
static void probeMethods2(void)
{
    logLine("=== probe-methods2 entered ===");
    dumpAll("SBAwayController", "lock");
    dumpAll("SBUIController", "lock");
    dumpAll("SBApplicationController", "lock");
    dumpAll("SpringBoard", "lock");
    dumpAll("SBDeviceLockController", "");
    logLine("=== done ===");
}
