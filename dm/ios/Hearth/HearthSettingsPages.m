// Hearth's own settings pages (HearthSettingsPages.h)
#import "HearthSettingsPages.h"
#import "HearthLaunch.h"
#import "HearthHomeViews.h"
#import "HearthSound.h"
#import "DmSettings.h"
#import "DmSettingsViews.h"
#import "DmHaptics.h"
#import "DmPadBits.h"

void dm_gamepad_set_capture(void (^handler)(uint64_t buttons, int32_t lx, int32_t ly));

#define SOURCE_URL @"https://github.com/chayan-bit/AnySwitch"
#define DEV_KEY @"HearthDeveloper"
#define LOG_TAIL (256 * 1024)   // a log viewer shows the end of the file: the newest lines are the ones a player is asked about

static NSString *bytes(unsigned long long n) { return [NSByteCountFormatter stringFromByteCount:(long long)n countStyle:NSByteCountFormatterCountStyleFile]; }
static NSString *when(double t) { return t > 0 ? [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:t] dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle] : @"Never"; }
static NSString *duration(double s) {
    NSDateComponentsFormatter *f = [NSDateComponentsFormatter new]; f.allowedUnits = NSCalendarUnitHour | NSCalendarUnitMinute; f.unitsStyle = NSDateComponentsFormatterUnitsStyleFull;
    return s <= 0 ? @"None" : s < 60 ? @"Less than a minute" : [f stringFromTimeInterval:s];
}
static NSString *tail(NSString *path) {   // the end of a text file, cut at a line start
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path]; if (!h) return nil;
    unsigned long long n = [h seekToEndOfFile]; [h seekToFileOffset:n > LOG_TAIL ? n - LOG_TAIL : 0];
    NSString *s = [[NSString alloc] initWithData:[h readDataToEndOfFile] encoding:NSUTF8StringEncoding] ?: @""; [h closeFile];
    if (n > LOG_TAIL) { NSRange nl = [s rangeOfString:@"\n"]; if (nl.location != NSNotFound) s = [s substringFromIndex:NSMaxRange(nl)]; }
    return s;
}

#pragma mark - Text viewer

// A read-only text page over the settings screen (a log, the licences). B, Escape or the close button closes it; the controller goes back to the screen under it
@interface HearthTextVC : UIViewController
@end
@implementation HearthTextVC {
    NSString *_title, *_text; BOOL _mono; UITextView *_view; __weak DmSettingsVC *_under; uint64_t _prev; BOOL _based;
}
+ (void)show:(NSString *)title text:(NSString *)text mono:(BOOL)mono over:(DmSettingsVC *)under {
    HearthTextVC *t = [self new]; t->_title = title; t->_text = text; t->_mono = mono; t->_under = under;
    t.modalPresentationStyle = UIModalPresentationOverFullScreen;
    [under presentViewController:t animated:YES completion:nil];
    __weak HearthTextVC *w = t;
    dm_gamepad_set_capture(^(uint64_t m, int32_t lx, int32_t ly) { (void)lx; [w pad:m ly:ly]; });
    fprintf(stderr, "hearth: text page %s\n", title.UTF8String);
}
- (void)viewDidLoad {
    [super viewDidLoad];
    __weak HearthTextVC *w = self; dm_on_style(self.view, ^{ w.view.backgroundColor = DmUI.bg; });
    UILabel *head = [UILabel new]; head.text = _title; head.font = [DmUI font:28 weight:UIFontWeightBold]; head.textColor = DmUI.text; head.tag = 1;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem]; close.tag = 2;
    [close setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    close.tintColor = DmUI.sub; close.backgroundColor = DmUI.row; close.layer.cornerRadius = 22; close.accessibilityLabel = @"Close";
    [close addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    _view = [UITextView new]; _view.editable = NO; _view.text = _text; _view.textColor = DmUI.text; _view.backgroundColor = UIColor.clearColor;
    _view.font = _mono ? [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular] : [DmUI font:15 weight:UIFontWeightRegular];
    for (UIView *v in @[head, close, _view]) [self.view addSubview:v];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; UIEdgeInsets si = self.view.safeAreaInsets; CGFloat l = si.left + 40, r = b.size.width - si.right - 40, top = MAX(si.top, 22);
    [self.view viewWithTag:1].frame = CGRectMake(l, top, r - l - 60, 60);
    [self.view viewWithTag:2].frame = CGRectMake(r - 44, top + 8, 44, 44);
    _view.frame = CGRectMake(l, top + 72, r - l, b.size.height - top - 72 - MAX(si.bottom, 16));
}
- (void)viewDidAppear:(BOOL)a {
    [super viewDidAppear:a]; [self becomeFirstResponder];
    if (_mono) [_view scrollRangeToVisible:NSMakeRange(_view.text.length, 0)];   // a log opens at its newest line
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)close {
    DmSettingsVC *u = _under; __weak DmSettingsVC *wu = u;
    dm_gamepad_set_capture(^(uint64_t m, int32_t lx, int32_t ly) { [wu padState:m lx:lx ly:ly]; });   // the first call only records what is held, so the B that closed this does nothing there
    [self dismissViewControllerAnimated:YES completion:^{ [u becomeFirstResponder]; }];
}
- (void)scrollBy:(CGFloat)dy {
    CGFloat max = MAX(0, _view.contentSize.height - _view.bounds.size.height);
    _view.contentOffset = CGPointMake(0, MIN(MAX(_view.contentOffset.y + dy, 0), max));
}
- (void)pad:(uint64_t)m ly:(int32_t)ly {
    uint64_t want = m & 1ull << DMB_B;
    if (!_based) { _based = YES; _prev = want; return; }
    if (want & ~_prev) [self close];
    _prev = want;
    if (m & 1ull << DMB_DOWN || ly < -20000) [self scrollBy:24]; else if (m & 1ull << DMB_UP || ly > 20000) [self scrollBy:-24];
}
- (NSArray<UIKeyCommand *> *)keyCommands {
    NSMutableArray *r = [NSMutableArray array];
    for (NSArray *p in @[@[UIKeyInputEscape, @"close"], @[UIKeyInputDownArrow, @"keyDown"], @[UIKeyInputUpArrow, @"keyUp"]]) {
        UIKeyCommand *c = [UIKeyCommand keyCommandWithInput:p[0] modifierFlags:0 action:NSSelectorFromString(p[1])]; c.wantsPriorityOverSystemBehavior = YES; [r addObject:c];
    }
    return r;
}
- (void)keyDown { [self scrollBy:120]; }
- (void)keyUp { [self scrollBy:-120]; }
- (BOOL)prefersStatusBarHidden { return YES; }
@end

#pragma mark - Pages shared by both screens

static DmPageItem *action(NSString *t, NSString *d, void (^run)(void)) { return [DmPageItem action:t detail:d run:run]; }
static DmPageItem *info(NSString *t, NSString *d) { return [DmPageItem info:t detail:d]; }
static DmPageItem *confirmed(DmPageItem *it, NSString *ask) { it.destructive = YES; it.confirmTitle = ask; return it; }
static void tell(UIViewController *over, NSString *title, NSString *msg) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [over presentViewController:a animated:YES completion:nil];
}
static void show_log(HearthGame *g, DmSettingsVC *over) {
    NSString *p = [[hearth_library() logDirFor:g] stringByAppendingPathComponent:@"log.txt"];
    [HearthTextVC show:[NSString stringWithFormat:@"Log: %@", g.name] text:tail(p) ?: @"This game has no log yet. It writes one when it starts." mono:YES over:over];
}
static DmPageItem *delete_game_item(HearthGame *g, DmSettingsVC *(^vc)(void), void (^done)(void)) {
    if (g.bundled) return info(@"Delete game", @"This game is built into the app and goes only when Hearth is deleted.");
    if ([hearth_running_game().titleId isEqual:g.titleId]) return info(@"Delete game", @"Close the game first.");
    return confirmed(action(@"Delete game", @"Removes the game and its prepared shaders. Its saves stay.", ^{
        NSString *why = nil;
        if (![hearth_library() deleteGame:g error:&why]) { tell(vc(), @"The game was not deleted", why); return; }
        hearth_sound(HearthSoundClose); if (done) done();   // the library logs the deletion
    }), [NSString stringWithFormat:@"Press again to delete %@", g.name]);
}
static DmPageItem *delete_saves_item(HearthGame *g, DmSettingsVC *(^vc)(void)) {
    if ([hearth_running_game().titleId isEqual:g.titleId]) return info(@"Delete saves", @"Close the game first.");
    return confirmed(action(@"Delete saves", @"Removes this game's saved progress. This cannot be undone.", ^{
        NSString *why = nil;
        if (![hearth_library() deleteSavesOf:g error:&why]) tell(vc(), @"The saves were not deleted", why);
    }), [NSString stringWithFormat:@"Press again to delete the saves of %@", g.name]);
}

#pragma mark - System Settings

static NSString *size_detail(NSDictionary<NSString *, NSNumber *> *s) {
    NSMutableArray *parts = [NSMutableArray array], *tiny = [NSMutableArray array];   // parts under 1 KB are placeholders ("2 bytes add-ons"): listed only when nothing bigger is
    for (NSArray *k in @[@[@"code", @"code"], @[@"shaders", @"shaders"], @[@"pipelines", @"pipelines"], @[@"files", @"game files"], @[@"addons", @"add-ons"], @[@"other", @"other"], @[@"save", @"saves"]]) {
        unsigned long long n = [s[k[0]] unsignedLongLongValue];
        if (n) [(n < 1024 ? tiny : parts) addObject:[NSString stringWithFormat:@"%@ %@", bytes(n), k[1]]];
    }
    if (!parts.count) parts = tiny;
    return parts.count ? [parts componentsJoinedByString:@", "] : @"Nothing on this iPad yet";
}
static unsigned long long installed(NSDictionary<NSString *, NSNumber *> *s) { unsigned long long n = 0; for (NSString *k in s) if (![k isEqual:@"save"]) n += s[k].unsignedLongLongValue; return n; }

static NSArray<DmPageItem *> *data_items(DmSettingsVC *(^vc)(void)) {
    NSMutableArray *out = [NSMutableArray array];
    for (HearthGame *g in [hearth_library() scan]) {
        NSDictionary *s = [hearth_library() sizesOf:g];
        [out addObject:info([NSString stringWithFormat:@"%@: %@", g.name, bytes(installed(s))], size_detail(s))];
        [out addObject:delete_game_item(g, vc, nil)];
        [out addObject:delete_saves_item(g, vc)];
    }
    return out;
}
// The provisioning profile the app was installed with: its team and when it expires (the 7-day profile of a free Apple ID)
static NSDictionary *profile(void) {
    NSData *d = [NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"]]; if (!d) return nil;
    NSRange a = [d rangeOfData:[@"<?xml" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, d.length)];
    NSRange b = [d rangeOfData:[@"</plist>" dataUsingEncoding:NSUTF8StringEncoding] options:NSDataSearchBackwards range:NSMakeRange(0, d.length)];
    if (a.location == NSNotFound || b.location == NSNotFound || NSMaxRange(b) <= a.location) return nil;
    id p = [NSPropertyListSerialization propertyListWithData:[d subdataWithRange:NSMakeRange(a.location, NSMaxRange(b) - a.location)] options:0 format:nil error:nil];
    return [p isKindOfClass:NSDictionary.class] ? p : nil;
}
static NSArray<DmPageItem *> *signing_items(void) {
    HearthLibrary *lib = hearth_library(); NSDictionary *p = profile(); NSDate *exp = p[@"ExpirationDate"];
    NSMutableArray *out = [NSMutableArray arrayWithObject:info(@"This copy of Hearth", [NSString stringWithFormat:@"Team %@, app ID %@", lib.appSigner.team ?: @"none (not signed by a team)", lib.bundleId ?: @"unknown"])];
    if ([exp isKindOfClass:NSDate.class]) {
        long days = (long)floor(exp.timeIntervalSinceNow / 86400);
        [out addObject:info(days >= 0 ? [NSString stringWithFormat:@"Signing ends in %ld %@", days, days == 1 ? @"day" : @"days"] : @"Signing has ended",
                            [NSString stringWithFormat:@"On %@. Install Hearth again from the Mac before then; games and saves stay.", [NSDateFormatter localizedStringFromDate:exp dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle]])];
    } else [out addObject:info(@"No provisioning profile", @"This build was not installed with one (a simulator or a development run).")];
    for (HearthGame *g in [lib scan])
        [out addObject:info(g.name, g.reason == HEARTH_NEEDS_SIGNING ? @"Needs signing: import it again from the Mac." : g.bundled || g.codePath ? @"Its code is inside the app." : @"Signed for this Hearth.")];
    [out addObject:info(@"Signing on the iPad", @"Comes in a later version. Until then the Mac signs each game when it is imported.")];
    return out;
}
static NSArray<DmPage *> *system_pages(DmSettingsVC *(^vc)(void));
static void reload(DmSettingsVC *v) { __weak DmSettingsVC *w = v; v.pages = system_pages(^{ return w; }); [v reloadPages]; }   // the Developer page came or went
static NSArray<DmPageItem *> *about_items(DmSettingsVC *(^vc)(void)) {
    NSDictionary *i = NSBundle.mainBundle.infoDictionary;
    NSString *sv = i[@"CFBundleShortVersionString"] ?: @"?", *bv = i[@"CFBundleVersion"] ?: @"?";
    NSString *v = [sv isEqual:bv] ? sv : [NSString stringWithFormat:@"%@ (%@)", sv, bv];   // the build number only when it says something the version does not
    static int presses;
    BOOL dev = [NSUserDefaults.standardUserDefaults boolForKey:DEV_KEY];
    return @[
        action(@"Version", v, ^{   // pressed 7 times: the Developer page appears
            if (dev || ++presses < 7) return;
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:DEV_KEY]; presses = 0;
            fprintf(stderr, "hearth: Developer page shown\n"); reload(vc());
        }),
        action(@"Source code", SOURCE_URL, ^{ [UIApplication.sharedApplication openURL:[NSURL URLWithString:SOURCE_URL] options:@{} completionHandler:nil]; }),
        action(@"Licences", @"The software Hearth includes and its licences.", ^{
            NSString *t = [NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"licenses" ofType:@"txt"] encoding:NSUTF8StringEncoding error:nil];
            [HearthTextVC show:@"Licences" text:t ?: @"The licences file is missing from this build." mono:NO over:vc()];
        }),
        action(@"Share log", @"Hearth's log and the games' logs, to send with a problem report.", ^{
            HearthLibrary *lib = hearth_library(); NSMutableArray *urls = [NSMutableArray array]; NSFileManager *fm = NSFileManager.defaultManager;
            NSString *h = [lib.documentsDir stringByAppendingPathComponent:@"Logs/hearth.txt"]; if ([fm fileExistsAtPath:h]) [urls addObject:[NSURL fileURLWithPath:h]];
            for (HearthGame *g in [lib scan]) { NSString *p = [[lib logDirFor:g] stringByAppendingPathComponent:@"log.txt"]; if ([fm fileExistsAtPath:p]) [urls addObject:[NSURL fileURLWithPath:p]]; }
            DmSettingsVC *over = vc(); if (!urls.count) { tell(over, @"No logs yet", @"A log is written when Hearth or a game starts."); return; }
            UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
            a.popoverPresentationController.sourceView = over.view; a.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(over.view.bounds), CGRectGetMidY(over.view.bounds), 1, 1);
            [over presentViewController:a animated:YES completion:nil];
        }),
    ];
}
static NSArray<DmPageItem *> *developer_items(DmSettingsVC *(^vc)(void)) {
    HearthLibrary *lib = hearth_library(); NSMutableArray *out = [NSMutableArray array];
    NSString *env = [NSString stringWithContentsOfFile:[lib.documentsDir stringByAppendingPathComponent:@"env.txt"] encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *l in [env componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) { NSString *t = [l stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; if (t.length && ![t hasPrefix:@"#"]) [lines addObject:t]; }
    [out addObject:info(@"Environment overrides (Documents/env.txt)", lines.count ? [lines componentsJoinedByString:@"\n"] : @"None")];
    NSMutableArray *locked = [NSMutableArray array]; DmSettings *st = DmSettings.systemStore;
    for (DmSection *s in st.sections) for (DmSetting *x in s.settings) if ([st sourceForKey:x.key] == DmSourceEnv) [locked addObject:x.label];
    [out addObject:info(@"Settings the environment locks", locked.count ? [locked componentsJoinedByString:@", "] : @"None")];
    [out addObject:info(@"Logs", [NSString stringWithFormat:@"Documents/Logs/hearth.txt, and Documents/Logs/<title id>/log.txt per game"])];
    [out addObject:action(@"Hide this page", @"Press the version line in About 7 times to show it again.", ^{
        [NSUserDefaults.standardUserDefaults removeObjectForKey:DEV_KEY]; reload(vc());
    })];
    return out;
}

static NSArray<DmPage *> *system_pages(DmSettingsVC *(^vc)(void)) {
    NSMutableArray *p = [[DmPage pagesOf:DmSettings.systemStore gameRowsOnly:NO] mutableCopy];
    [p addObject:[DmPage page:@"Data Management" icon:@"externaldrive.fill" items:^{ return data_items(vc); }]];
    [p addObject:[DmPage page:@"Signing" icon:@"checkmark.seal.fill" items:^{ return signing_items(); }]];
    [p addObject:[DmPage page:@"About" icon:@"info.circle.fill" items:^{ return about_items(vc); }]];
    if ([NSUserDefaults.standardUserDefaults boolForKey:DEV_KEY]) [p addObject:[DmPage page:@"Developer" icon:@"hammer.fill" items:^{ return developer_items(vc); }]];
    return p;
}
DmSettingsVC *hearth_system_settings(CGSize size) {
    DmSettingsVC *v = [[DmSettingsVC alloc] initWithSettings:DmSettings.systemStore size:size];
    __weak DmSettingsVC *w = v; DmSettingsVC *(^vc)(void) = ^{ return w; };
    v.pages = system_pages(vc);
    v.onChange = ^{ hearth_apply_appearance(); };   // the system store announces nothing; a running game hears it through the linked store
    return v;
}

#pragma mark - A game's Options

static DmSettings *options_store(HearthGame *g) {
    DmSettings *s = [DmSettings storeForGame:g.titleId packRoot:g.root];
    if ([hearth_running_game().titleId isEqual:g.titleId]) return s;   // the live store: the game reported its capabilities (front_ios.m)
    NSDictionary *caps = [hearth_library() capsOf:g];
    s.capabilities = ^BOOL(NSString *c) { return [c isEqualToString:@"haptics"] ? dm_haptics_available() : [caps[c] boolValue]; };   // before the first start: only the rows that need nothing
    return s;
}
DmSettingsVC *hearth_options(HearthGame *g, CGSize size, void (^gone)(void)) {
    HearthLibrary *lib = hearth_library(); DmSettings *store = options_store(g);
    DmSettingsVC *v = [[DmSettingsVC alloc] initWithSettings:store size:size];
    __weak DmSettingsVC *w = v; DmSettingsVC *(^vc)(void) = ^{ return w; };
    BOOL learned = [hearth_running_game().titleId isEqual:g.titleId] || [lib capsOf:g] != nil;
    NSMutableArray *pages = [NSMutableArray arrayWithObject:[DmPage page:@"Overview" icon:@"info.circle.fill" items:^{
        NSDictionary *s = [lib sizesOf:g];
        NSMutableArray *o = [NSMutableArray arrayWithArray:@[info(@"Publisher", g.publisher.length ? g.publisher : @"Unknown"), info(@"Title ID", g.titleId),
            info(@"Size", [NSString stringWithFormat:@"%@ (%@)", bytes(installed(s)), size_detail(s)]),
            info(@"Last played", when(g.lastPlayed)), info(@"Play time", duration([lib playTimeOf:g]))]];
        if (!learned) [o addObject:info(@"More options appear after the first start", @"Some settings depend on what the game provides, which Hearth learns when it runs.")];
        return o;
    }]];
    [pages addObjectsFromArray:[DmPage pagesOf:store gameRowsOnly:YES]];
    [pages addObject:[DmPage page:@"Manage" icon:@"wrench.and.screwdriver.fill" items:^{
        NSMutableArray *o = [NSMutableArray array];
        if ([hearth_running_game().titleId isEqual:g.titleId]) [o addObject:action(@"Close game", @"Ends the game. Progress that was not saved is lost.", ^{ hearth_confirm_close(vc()); })];
        [o addObject:action(@"View log", @"The end of this game's log.", ^{ show_log(g, vc()); })];
        [o addObject:delete_game_item(g, vc, gone)];
        [o addObject:delete_saves_item(g, vc)];
        return o;
    }]];
    v.pages = pages; v.heading = g.name;
    v.onChange = ^{ hearth_apply_appearance(); };
    return v;
}

#pragma mark - Appearance

void hearth_apply_appearance(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{   // a change in the game's own settings screen (the shared store announces it)
        [NSNotificationCenter.defaultCenter addObserverForName:DmSettingDidChangeNotification object:@"DM_APPEARANCE" queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; hearth_apply_appearance(); }];
    });
    NSString *ap = [DmSettings.systemStore valueForKey:@"DM_APPEARANCE"];
    UIUserInterfaceStyle st = [ap isEqualToString:@"light"] ? UIUserInterfaceStyleLight : [ap isEqualToString:@"dark"] ? UIUserInterfaceStyleDark : UIUserInterfaceStyleUnspecified;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) if ([sc isKindOfClass:UIWindowScene.class])
        for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.overrideUserInterfaceStyle != st) { w.overrideUserInterfaceStyle = st; fprintf(stderr, "hearth: appearance %s\n", ap.UTF8String); }
}
