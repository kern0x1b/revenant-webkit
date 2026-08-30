#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

static void dumpMethods(Class c, char prefix)
{
    unsigned count = 0;
    Method *methods = class_copyMethodList(c, &count);
    for (unsigned i = 0; i < count; i++)
        printf("%c%s\t%s\n", prefix, sel_getName(method_getName(methods[i])),
               method_getTypeEncoding(methods[i]));
    free(methods);
}

static void dumpClass(const char *name)
{
    Class c = objc_getClass(name);
    if (!c) {
        fprintf(stderr, "no such class: %s\n", name);
        return;
    }
    dumpMethods(c, '-');
    dumpMethods(object_getClass(c), '+');
}

int main(int argc, const char *argv[])
{
    if (argc < 3) {
        fprintf(stderr, "usage: objc-surface <dylib> <class> [class...]\n");
        return 2;
    }

    if (!dlopen(argv[1], RTLD_NOW)) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 1;
    }

    for (int i = 2; i < argc; i++)
        dumpClass(argv[i]);

    return 0;
}
