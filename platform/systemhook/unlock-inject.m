/* Injected via cynject into a running SpringBoard to submit the device
 * passcode programmatically, when there is no physical hand on the screen
 * and no remote-input channel (no VNC/veency installed, no internet over the
 * USB tunnel to install one). SBAwayController and -attemptUnlockWithPassword:
 * are iOS 5/6-era SpringBoard's own passcode entry path - well documented
 * from that jailbreak era, matching this device's iOS 6.1.3. */
#import <Foundation/Foundation.h>
#import <objc/message.h>

/* NSLog goes nowhere readable on this device (ASL is not persisting), so
 * every step is appended to a plain file instead. */
static void logLine(NSString *line)
{
    NSString *entry = [line stringByAppendingString:@"\n"];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/unlock-result.log"];
    if (!handle) {
        [[NSFileManager defaultManager] createFileAtPath:@"/tmp/unlock-result.log" contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/unlock-result.log"];
    }
    [handle seekToEndOfFile];
    [handle writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

__attribute__((constructor))
static void unlockInject(void)
{
    NSString *passcode = @"1511";
    logLine(@"constructor entered");

    Class awayControllerClass = NSClassFromString(@"SBAwayController");
    if (!awayControllerClass) {
        logLine(@"SBAwayController class not found");
        return;
    }
    logLine(@"SBAwayController class found");

    SEL sharedSel = @selector(sharedAwayController);
    if (![awayControllerClass respondsToSelector:sharedSel]) {
        logLine(@"+sharedAwayController not found");
        return;
    }
    id awayController = ((id (*)(id, SEL))objc_msgSend)(awayControllerClass, sharedSel);
    if (!awayController) {
        logLine(@"sharedAwayController returned nil");
        return;
    }
    logLine(@"got shared awayController instance");

    SEL unlockSel = @selector(attemptUnlockWithPassword:);
    if ([awayController respondsToSelector:unlockSel]) {
        logLine(@"calling attemptUnlockWithPassword:");
        ((void (*)(id, SEL, id))objc_msgSend)(awayController, unlockSel, passcode);
        logLine(@"attemptUnlockWithPassword: returned");
        return;
    }

    logLine(@"no known unlock selector responded");
}
