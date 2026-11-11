// When Hearth's signing ends (HearthNotify.h)
#import "HearthNotify.h"
#import <UserNotifications/UserNotifications.h>

static NSString *const NOTE_ID = @"hearth.signing";
static const NSTimeInterval DAY = 86400, WARN_BEFORE = 2 * 86400;

NSDictionary *hearth_profile(NSString *bundlePath) {
    NSData *d = [NSData dataWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"]]; if (!d) return nil;
    NSRange a = [d rangeOfData:[@"<?xml" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, d.length)];   // the plist inside the CMS envelope
    NSRange b = [d rangeOfData:[@"</plist>" dataUsingEncoding:NSUTF8StringEncoding] options:NSDataSearchBackwards range:NSMakeRange(0, d.length)];
    if (a.location == NSNotFound || b.location == NSNotFound || NSMaxRange(b) <= a.location) return nil;
    id p = [NSPropertyListSerialization propertyListWithData:[d subdataWithRange:NSMakeRange(a.location, NSMaxRange(b) - a.location)] options:0 format:nil error:nil];
    return [p isKindOfClass:NSDictionary.class] ? p : nil;
}

static NSString *env_value(NSString *documentsDir, NSString *key) {   // the environment first, then Documents/env.txt (KEY=VALUE lines, # comments), as main.m reads it at a launch
    const char *e = getenv(key.UTF8String); if (e && *e) return @(e);
    NSString *txt = [NSString stringWithContentsOfFile:[documentsDir stringByAppendingPathComponent:@"env.txt"] encoding:NSUTF8StringEncoding error:nil];
    for (NSString *raw in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *ln = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([ln hasPrefix:[key stringByAppendingString:@"="]]) return [ln substringFromIndex:key.length + 1];
    }
    return nil;
}

NSDate *hearth_signing_ends(NSString *bundlePath, NSString *documentsDir) {
    NSString *planted = env_value(documentsDir, @"HEARTH_SIGNING_ENDS");
    if (planted.length) {
        NSDate *d = [[NSISO8601DateFormatter new] dateFromString:planted];
        if (d) return d;
        NSLog(@"hearth: [RED] HEARTH_SIGNING_ENDS=%@ is not an ISO 8601 date (2026-10-30T12:00:00Z): the profile's date is used", planted);
    }
    id e = hearth_profile(bundlePath)[@"ExpirationDate"];
    return [e isKindOfClass:NSDate.class] ? e : nil;
}

NSString *hearth_signing_line(NSDate *ends, NSDate *now) {
    if (!ends) return nil;
    NSTimeInterval left = [ends timeIntervalSinceDate:now];
    if (left > WARN_BEFORE) return nil;
    if (left <= 0) return @"Signing has ended";
    NSCalendar *cal = NSCalendar.currentCalendar;
    NSInteger days = [cal components:NSCalendarUnitDay fromDate:[cal startOfDayForDate:now] toDate:[cal startOfDayForDate:ends] options:0].day;   // calendar days: "tomorrow" means tomorrow
    return days <= 0 ? @"Signing ends today" : days == 1 ? @"Signing ends tomorrow" : [NSString stringWithFormat:@"Signing ends in %ld days", (long)days];
}

void hearth_notify_schedule(NSDate *ends) {
    UNUserNotificationCenter *c = UNUserNotificationCenter.currentNotificationCenter;
    [c getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *s) {
        if (s.authorizationStatus != UNAuthorizationStatusAuthorized && s.authorizationStatus != UNAuthorizationStatusProvisional) return;
        [c removePendingNotificationRequestsWithIdentifiers:@[NOTE_ID]];
        NSTimeInterval at = [ends timeIntervalSinceNow] - DAY;
        if (!ends || at <= 0) return;
        UNMutableNotificationContent *m = [UNMutableNotificationContent new];
        m.title = @"Hearth's signing ends tomorrow";
        m.body = [NSString stringWithFormat:@"Install Hearth again from the Mac before %@. Games and saves stay.", [NSDateFormatter localizedStringFromDate:ends dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle]];
        UNNotificationRequest *r = [UNNotificationRequest requestWithIdentifier:NOTE_ID content:m trigger:[UNTimeIntervalNotificationTrigger triggerWithTimeInterval:at repeats:NO]];
        [c addNotificationRequest:r withCompletionHandler:^(NSError *e) { if (e) NSLog(@"hearth: [RED] the signing reminder was not scheduled: %@", e.localizedDescription); else NSLog(@"hearth: signing reminder in %.0f h", at / 3600); }];
    }];
}

void hearth_notify_ask(NSDate *ends, void (^done)(BOOL allowed)) {
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound completionHandler:^(BOOL granted, NSError *e) {
        if (e) NSLog(@"hearth: notification permission: %@", e.localizedDescription);
        if (granted) hearth_notify_schedule(ends);
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(granted); });
    }];
}

