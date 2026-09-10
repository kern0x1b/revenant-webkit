#import <UIKit/UIKit.h>
#include <stdio.h>

int main(void)
{
    @autoreleasepool {
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        printf("items %lu changeCount %ld\n", (unsigned long)[pasteboard numberOfItems], (long)[pasteboard changeCount]);
        printf("string [%s]\n", [pasteboard string] ? [[pasteboard string] UTF8String] : "(none)");
        for (NSString *type in [pasteboard pasteboardTypes]) {
            id value = [pasteboard valueForPasteboardType:type];
            const char *shape = [value isKindOfClass:[NSString class]] ? "string"
                : [value isKindOfClass:[NSData class]] ? "data" : "other";
            printf("  %-40s %s\n", [type UTF8String], shape);
        }
    }
    return 0;
}
