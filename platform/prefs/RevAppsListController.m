#import "RevPrefs.h"

static NSString *const kRevDomain = @"space.kern0x1b.rev";

@interface RevAppsListController : PSListController
@end

@implementation RevAppsListController

static NSArray *revSupportedApps(void) {
    return @[
        @{ @"id": @"com.apple.mobilesafari", @"name": @"Safari", @"default": @YES },
    ];
}

- (NSDictionary *)revInjectedApps {
    CFPreferencesAppSynchronize((CFStringRef)kRevDomain);
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("InjectedApps"), (CFStringRef)kRevDomain);
    id value = [(id)v autorelease];
    return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}

- (id)readInjection:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"revBundle"];
    id v = [[self revInjectedApps] objectForKey:bid];
    if (v)
        return v;
    return [spec propertyForKey:@"default"] ?: @NO;
}

- (void)setInjection:(id)value specifier:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"revBundle"];
    if (!bid)
        return;
    NSMutableDictionary *apps = [[[self revInjectedApps] mutableCopy] autorelease];
    [apps setObject:(value ?: @NO) forKey:bid];
    CFPreferencesSetAppValue(CFSTR("InjectedApps"), (CFTypeRef)apps, (CFStringRef)kRevDomain);
    CFPreferencesAppSynchronize((CFStringRef)kRevDomain);
}

- (NSArray *)specifiers {
    if (_specifiers)
        return _specifiers;
    NSMutableArray *s = [NSMutableArray array];

    PSSpecifier *g = [PSSpecifier groupSpecifierWithName:@"Apps"];
    [g setProperty:@"Turn the RevWebKit tweak on or off per app. Injection currently targets Safari; more apps appear here as per-app support grows. Respring after changing." forKey:@"footerText"];
    [s addObject:g];

    for (NSDictionary *app in revSupportedApps()) {
        PSSpecifier *sw = [PSSpecifier preferenceSpecifierNamed:[app objectForKey:@"name"]
                                                         target:self
                                                            set:@selector(setInjection:specifier:)
                                                            get:@selector(readInjection:)
                                                         detail:Nil
                                                           cell:PSSwitchCell
                                                           edit:Nil];
        [sw setProperty:[app objectForKey:@"id"] forKey:@"revBundle"];
        [sw setProperty:[app objectForKey:@"default"] forKey:@"default"];
        [s addObject:sw];
    }

    _specifiers = [s copy];
    return _specifiers;
}

- (NSString *)navigationTitle {
    return @"Per-App Injection";
}

@end
