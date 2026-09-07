#import "RevPrefs.h"

static NSString *const kRevDomain = @"space.kern0x1b.rev";

@interface RevAppsListController : PSListController
@end

@implementation RevAppsListController

// Installed user apps + Safari, as {id,name}, sorted by name. Safari is always
// first and defaults on; it is the app the engine actually re-execs today.
static NSArray *revListedApps(void) {
    NSMutableArray *out = [NSMutableArray array];
    [out addObject:@{ @"id": @"com.apple.mobilesafari", @"name": @"Safari", @"default": @YES }];

    Class ws = NSClassFromString(@"LSApplicationWorkspace");
    if (ws && [ws respondsToSelector:@selector(defaultWorkspace)]) {
        id workspace = [ws performSelector:@selector(defaultWorkspace)];
        NSArray *all = nil;
        if ([workspace respondsToSelector:@selector(allApplications)])
            all = [workspace performSelector:@selector(allApplications)];
        NSMutableArray *others = [NSMutableArray array];
        for (id proxy in all) {
            NSString *bid = [proxy respondsToSelector:@selector(applicationIdentifier)] ? [proxy performSelector:@selector(applicationIdentifier)] : nil;
            NSString *name = [proxy respondsToSelector:@selector(localizedName)] ? [proxy performSelector:@selector(localizedName)] : nil;
            NSString *type = [proxy respondsToSelector:@selector(applicationType)] ? [proxy performSelector:@selector(applicationType)] : nil;
            if (![bid isKindOfClass:[NSString class]] || ![name isKindOfClass:[NSString class]])
                continue;
            if (name.length == 0 || [bid isEqualToString:@"com.apple.mobilesafari"])
                continue;
            if (![type isEqualToString:@"User"])
                continue;
            [others addObject:@{ @"id": bid, @"name": name, @"default": @NO }];
        }
        [others sortUsingComparator:^NSComparisonResult(id a, id b) {
            return [[a objectForKey:@"name"] localizedCaseInsensitiveCompare:[b objectForKey:@"name"]];
        }];
        [out addObjectsFromArray:others];
    }
    return out;
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
    [g setProperty:@"Turn the RevWebKit engine on or off per app. Respring after changing." forKey:@"footerText"];
    [s addObject:g];

    for (NSDictionary *app in revListedApps()) {
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
