// When this copy of Hearth stops opening (plan-hearth-p3.md 7): a free Apple ID's provisioning profile lasts 7 days. Home's top bar says so from 2 days before
// (hearth_signing_line), and one local notification comes the day before, once the player has allowed notifications from the Signing page (the request is theirs to make).
// Foundation and UserNotifications only, so dm/ios/tests/t_notify.m runs it on the Mac.
#import <Foundation/Foundation.h>

NSDictionary *hearth_profile(NSString *bundlePath);   // the embedded.mobileprovision's plist (team, ExpirationDate), nil without one
// The profile's end; HEARTH_SIGNING_ENDS (ISO 8601, in the environment or Documents/env.txt) plants another date for a check. nil: unknown (no profile)
NSDate *hearth_signing_ends(NSString *bundlePath, NSString *documentsDir);
NSString *hearth_signing_line(NSDate *ends, NSDate *now);   // Home's amber line: nil more than 2 days before; "Signing ends in 2 days", "Signing ends tomorrow", "Signing ends today", "Signing has ended"
// The notification the day before (one, replaced on every call; none when that moment has passed). Does nothing until the player allowed notifications
void hearth_notify_schedule(NSDate *ends);
// The Signing page's row: ask once (iPadOS shows its prompt), then schedule; done on the main thread with the outcome
void hearth_notify_ask(NSDate *ends, void (^done)(BOOL allowed));
