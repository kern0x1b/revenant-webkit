/*
 * Launch and kill an app the way SpringBoard does, so a build can be tested
 * without anyone tapping an icon.
 */
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdio.h>

int main(int argc, char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (argc < 2) {
        fprintf(stderr, "usage: launch <bundle-identifier>\n");
        return 2;
    }

    void *services = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (!services) {
        fprintf(stderr, "SpringBoardServices unavailable: %s\n", dlerror());
        return 1;
    }

    int (*launch)(CFStringRef, Boolean) = dlsym(services, "SBSLaunchApplicationWithIdentifier");
    if (!launch) {
        fprintf(stderr, "SBSLaunchApplicationWithIdentifier not found\n");
        return 1;
    }

    CFStringRef identifier = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    int result = launch(identifier, false);
    CFRelease(identifier);

    fprintf(stderr, "%s (code %d)\n", result ? "launch refused" : "launched", result);
    [pool release];
    return result ? 1 : 0;
}
