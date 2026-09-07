#import "RevPrefs.h"
#import <stdlib.h>
#import <string.h>
#import <signal.h>
#import <sys/sysctl.h>

static NSString *const kRevDomain = @"space.kern0x1b.rev";

@interface RevRootListController : PSListController {
    NSInteger _aboutTaps;
}
@end

@implementation RevRootListController

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *domain = [spec propertyForKey:@"defaults"] ?: kRevDomain;
    NSString *key = [spec propertyForKey:@"key"];
    CFPreferencesAppSynchronize((CFStringRef)domain);
    CFPropertyListRef v = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)domain);
    id value = [(id)v autorelease];
    return value ?: [spec propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *domain = [spec propertyForKey:@"defaults"] ?: kRevDomain;
    NSString *key = [spec propertyForKey:@"key"];
    CFPreferencesSetAppValue((CFStringRef)key, (CFTypeRef)value, (CFStringRef)domain);
    CFPreferencesAppSynchronize((CFStringRef)domain);
}

- (BOOL)revDeveloperVisible {
    CFPreferencesAppSynchronize((CFStringRef)kRevDomain);
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("ShowDeveloper"), (CFStringRef)kRevDomain);
    id value = [(id)v autorelease];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

- (PSSpecifier *)revSwitchNamed:(NSString *)name key:(NSString *)key defaultOn:(BOOL)on {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
                                                    target:self
                                                       set:@selector(setPreferenceValue:specifier:)
                                                       get:@selector(readPreferenceValue:)
                                                    detail:Nil
                                                      cell:PSSwitchCell
                                                      edit:Nil];
    [s setProperty:kRevDomain forKey:@"defaults"];
    [s setProperty:key forKey:@"key"];
    [s setProperty:(on ? @YES : @NO) forKey:@"default"];
    return s;
}

- (NSArray *)specifiers {
    if (_specifiers)
        return _specifiers;
    NSMutableArray *s = [NSMutableArray array];

    PSSpecifier *g1 = [PSSpecifier groupSpecifierWithName:@"New Tab"];
    [g1 setProperty:@"When a blank tab opens, show your bookmarks as a start page." forKey:@"footerText"];
    [s addObject:g1];
    [s addObject:[self revSwitchNamed:@"Bookmarks start page" key:@"NewTabStartPage" defaultOn:YES]];

    PSSpecifier *g2 = [PSSpecifier groupSpecifierWithName:@"Custom Home URL"];
    [g2 setProperty:@"On with a URL below: every new tab opens that URL instead. Off: uses the start-page setting above." forKey:@"footerText"];
    [s addObject:g2];
    [s addObject:[self revSwitchNamed:@"Use custom URL" key:@"CustomURLEnabled" defaultOn:NO]];
    PSSpecifier *tf = [PSSpecifier preferenceSpecifierNamed:@"URL"
                                                     target:self
                                                        set:@selector(setPreferenceValue:specifier:)
                                                        get:@selector(readPreferenceValue:)
                                                     detail:Nil
                                                       cell:PSEditTextCell
                                                       edit:Nil];
    [tf setProperty:kRevDomain forKey:@"defaults"];
    [tf setProperty:@"CustomURL" forKey:@"key"];
    [tf setProperty:@"https://example.com" forKey:@"placeholder"];
    [tf setProperty:@NO forKey:@"autoCaps"];
    [tf setProperty:@NO forKey:@"autoCorrection"];
    [tf setProperty:@(UIKeyboardTypeURL) forKey:@"keyboardType"];
    [s addObject:tf];

    PSSpecifier *g3 = [PSSpecifier groupSpecifierWithName:@"Actions"];
    [g3 setProperty:@"A settings change takes effect on the next new tab. If it does not, close and reopen the app; if it still does not, respring." forKey:@"footerText"];
    [s addObject:g3];
    PSSpecifier *rs = [PSSpecifier preferenceSpecifierNamed:@"Respring"
                                                     target:self
                                                        set:Nil
                                                        get:Nil
                                                     detail:Nil
                                                       cell:PSButtonCell
                                                       edit:Nil];
    [rs setProperty:@"respring" forKey:@"action"];
    [s addObject:rs];

    PSSpecifier *g4 = [PSSpecifier groupSpecifierWithName:@"About"];
    [g4 setProperty:@"RevWebKit — a modern WebKit engine for iOS 6." forKey:@"footerText"];
    [s addObject:g4];
    PSSpecifier *ab = [PSSpecifier preferenceSpecifierNamed:@"RevWebKit"
                                                     target:self
                                                        set:Nil
                                                        get:Nil
                                                     detail:Nil
                                                       cell:PSButtonCell
                                                       edit:Nil];
    [ab setProperty:@"revAboutTapped" forKey:@"action"];
    [s addObject:ab];

    if ([self revDeveloperVisible]) {
        PSSpecifier *g5 = [PSSpecifier groupSpecifierWithName:@"Developer"];
        [g5 setProperty:@"Per-app injection of the RevWebKit tweak." forKey:@"footerText"];
        [s addObject:g5];
        PSSpecifier *link = [PSSpecifier preferenceSpecifierNamed:@"Per-App Injection"
                                                           target:self
                                                              set:Nil
                                                              get:Nil
                                                           detail:NSClassFromString(@"RevAppsListController")
                                                             cell:PSLinkCell
                                                             edit:Nil];
        [s addObject:link];
    }

    _specifiers = [s copy];
    return _specifiers;
}

- (void)revAboutTapped {
    if (++_aboutTaps < 7)
        return;
    _aboutTaps = 0;
    CFPreferencesSetAppValue(CFSTR("ShowDeveloper"), kCFBooleanTrue, (CFStringRef)kRevDomain);
    CFPreferencesAppSynchronize((CFStringRef)kRevDomain);
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)respring {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0)
        return;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs)
        return;
    if (sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
        int count = (int)(size / sizeof(struct kinfo_proc));
        for (int i = 0; i < count; i++) {
            if (strcmp(procs[i].kp_proc.p_comm, "SpringBoard") == 0)
                kill(procs[i].kp_proc.p_pid, SIGKILL);
        }
    }
    free(procs);
}

@end
