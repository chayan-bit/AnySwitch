// HearthNotify.m on the Mac: the profile's end read from an embedded.mobileprovision (a plist inside other bytes), a date planted through env.txt wins over it,
// a planted date that is not ISO 8601 is ignored, and Home's line appears 2 days before and says how near the end is
#import "HearthNotify.h"

static int g_fail, g_n;
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_fail++; printf("FAIL line %d: %s  ", __LINE__, #c); printf(__VA_ARGS__); printf("\n"); } } while (0)

int main(void) { @autoreleasepool {
    NSString *t = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_notify.%d", getpid()]], *app = [t stringByAppendingPathComponent:@"Hearth.app"], *doc = [t stringByAppendingPathComponent:@"Documents"];
    for (NSString *d in @[app, doc]) [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    CHECK(!hearth_signing_ends(app, doc), "no profile: unknown");

    NSDate *end = [NSDate dateWithTimeIntervalSince1970:1793000000];
    NSMutableData *prov = [NSMutableData dataWithBytes:"\x30\x82junk" length:6];   // the CMS envelope around the plist
    [prov appendData:[NSPropertyListSerialization dataWithPropertyList:@{@"ExpirationDate": end, @"TeamName": @"Example"} format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]];
    [prov appendBytes:"\x00\xa0tail" length:6];
    [prov writeToFile:[app stringByAppendingPathComponent:@"embedded.mobileprovision"] atomically:YES];
    CHECK([hearth_signing_ends(app, doc) isEqual:end] && [hearth_profile(app)[@"TeamName"] isEqual:@"Example"], "the profile's ExpirationDate");

    [@"# a check\nDM_SHOW_FPS=1\nHEARTH_SIGNING_ENDS=2026-10-30T12:00:00Z\n" writeToFile:[doc stringByAppendingPathComponent:@"env.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    CHECK([hearth_signing_ends(app, doc) isEqual:[[NSISO8601DateFormatter new] dateFromString:@"2026-10-30T12:00:00Z"]], "a planted date wins");
    [@"HEARTH_SIGNING_ENDS=next tuesday\n" writeToFile:[doc stringByAppendingPathComponent:@"env.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    CHECK([hearth_signing_ends(app, doc) isEqual:end], "a planted date that is not ISO 8601 is ignored");

    NSCalendar *cal = NSCalendar.currentCalendar;
    NSDate *noon = [cal dateBySettingHour:12 minute:0 second:0 ofDate:[NSDate dateWithTimeIntervalSince1970:1792000000] options:0];
    NSDate *(^at)(NSInteger, NSInteger) = ^NSDate *(NSInteger days, NSInteger hours) { return [cal dateByAddingUnit:NSCalendarUnitHour value:days * 24 + hours toDate:noon options:0]; };
    CHECK(!hearth_signing_line(nil, noon), "unknown end: no line");
    CHECK(!hearth_signing_line(at(3, 0), noon) && !hearth_signing_line(at(2, 1), noon), "more than 2 days before: no line");
    CHECK([hearth_signing_line(at(2, 0), noon) isEqual:@"Signing ends in 2 days"], "%s", hearth_signing_line(at(2, 0), noon).UTF8String);
    CHECK([hearth_signing_line(at(1, -2), noon) isEqual:@"Signing ends tomorrow"], "%s", hearth_signing_line(at(1, -2), noon).UTF8String);
    CHECK([hearth_signing_line(at(0, 6), noon) isEqual:@"Signing ends today"], "%s", hearth_signing_line(at(0, 6), noon).UTF8String);
    CHECK([hearth_signing_line(at(0, -1), noon) isEqual:@"Signing has ended"] && [hearth_signing_line(noon, noon) isEqual:@"Signing has ended"], "ended");

    [NSFileManager.defaultManager removeItemAtPath:t error:nil];
    printf("t_notify: %d checks, %d failed\n", g_n, g_fail);
    return g_fail != 0;
} }
