// revclip — print what the system pasteboard holds, and the types it holds it as.
// The phone has no way to look: this is how a copy made by a page is checked
// against what every other app on the device would actually see.
//
//   revclip            the plain-text value and every type on item 0
//
// Build (armv7, iOS 6): see .claude/skills/test.
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
