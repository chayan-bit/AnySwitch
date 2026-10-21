// In-app settings registry and store (see DmSettings.h).
#import "DmSettings.h"

NSNotificationName const DmSettingDidChangeNotification = @"DmSettingDidChange";

static NSString *fmt(double v) { return [NSString stringWithFormat:@"%g", round(v * 10000) / 10000]; }
static void say(NSString *m) { fprintf(stderr, "[dm] settings: %s\n", m.UTF8String); }

@interface DmSection ()
- (void)keepOnly:(NSArray<DmSetting *> *)k;
@end

@implementation DmSetting {
    NSString *_key, *_plistKey, *_label, *_detail, *_suffix, *_def;
    NSArray<NSDictionary *> *_options;
    DmSettingType _type; double _min, _max, _step, _scale; BOOL _restart;
}
+ (instancetype)settingFromDictionary:(NSDictionary *)d error:(NSString **)err {
    DmSetting *s = [DmSetting new];
    NSString *key = d[@"key"], *label = d[@"label"], *type = d[@"type"];
    #define FAIL(m) do { if (err) *err = [NSString stringWithFormat:@"%@: %@", key ?: @"(no key)", m]; return nil; } while (0)
    if (![key isKindOfClass:NSString.class] || !key.length) FAIL(@"no key");
    if (![label isKindOfClass:NSString.class] || !label.length) FAIL(@"no label");
    s->_key = key; s->_label = label; s->_plistKey = d[@"plistKey"]; s->_detail = d[@"detail"]; s->_restart = [d[@"apply"] isEqualToString:@"restart"];
    if ([type isEqualToString:@"toggle"]) s->_type = DmSettingToggle;
    else if ([type isEqualToString:@"choice"]) {
        s->_type = DmSettingChoice; s->_options = d[@"options"];
        if (![s->_options isKindOfClass:NSArray.class] || s->_options.count < 2) FAIL(@"a choice needs two or more options");
        for (NSDictionary *o in s->_options) if (![o[@"value"] isKindOfClass:NSString.class] || ![o[@"label"] isKindOfClass:NSString.class]) FAIL(@"an option needs a value and a label");
    } else if ([type isEqualToString:@"slider"]) {
        s->_type = DmSettingSlider; s->_min = [d[@"min"] doubleValue]; s->_max = [d[@"max"] doubleValue]; s->_step = [d[@"step"] doubleValue]; s->_scale = d[@"scale"] ? [d[@"scale"] doubleValue] : 1;
        s->_suffix = d[@"suffix"] ?: @"";
        if (!(s->_max > s->_min) || !(s->_step > 0)) FAIL(@"a slider needs min < max and a step > 0");
    } else FAIL(@"type must be toggle, choice or slider");
    NSString *def = d[@"default"];
    if (![def isKindOfClass:NSString.class]) FAIL(@"no default (a string)");
    s->_def = [s normalized:def];
    if (!s->_def) FAIL(@"the default does not parse");
    #undef FAIL
    return s;
}
- (NSString *)normalized:(id)raw {
    if ([raw isKindOfClass:NSNumber.class]) raw = _type == DmSettingToggle ? ([raw boolValue] ? @"1" : @"0") : [raw stringValue];
    if (![raw isKindOfClass:NSString.class]) return nil;
    NSString *r = [[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] lowercaseString];
    if (!r.length) return nil;
    switch (_type) {
        case DmSettingToggle:
            if ([@[@"1", @"yes", @"true", @"on"] containsObject:r]) return @"1";
            if ([@[@"0", @"no", @"false", @"off"] containsObject:r]) return @"0";
            return nil;
        case DmSettingChoice:
            for (NSDictionary *o in _options) if ([[o[@"value"] lowercaseString] isEqualToString:r] || [[o[@"aliases"] valueForKey:@"lowercaseString"] containsObject:r]) return o[@"value"];
            return nil;
        case DmSettingSlider: {
            NSScanner *sc = [NSScanner scannerWithString:r]; double v;
            if (![sc scanDouble:&v] || !sc.atEnd || isnan(v)) return nil;
            v = fmin(fmax(v, _min), _max); v = _min + round((v - _min) / _step) * _step;
            return fmt(fmin(v, _max));
        }
    }
}
- (NSString *)displayValue:(NSString *)v {
    switch (_type) {
        case DmSettingToggle: return [v isEqualToString:@"1"] ? @"On" : @"Off";
        case DmSettingChoice: for (NSDictionary *o in _options) if ([o[@"value"] isEqualToString:v]) return o[@"label"]; return v;
        case DmSettingSlider: return [NSString stringWithFormat:@"%.0f%@", round(v.doubleValue * _scale * 100) / 100, _suffix];
    }
}
@end

@implementation DmSection { NSString *_ident, *_title, *_icon; NSArray<DmSetting *> *_settings; }
- (void)keepOnly:(NSArray<DmSetting *> *)k { _settings = k; }
+ (instancetype)sectionFromDictionary:(NSDictionary *)d {
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *sd in d[@"settings"]) {
        NSString *e = nil; DmSetting *s = [DmSetting settingFromDictionary:sd error:&e];
        if (s) [list addObject:s]; else say([NSString stringWithFormat:@"skipped an entry of section %@: %@", d[@"id"], e]);
    }
    if (!list.count || ![d[@"id"] length] || ![d[@"title"] length]) return nil;
    DmSection *s = [DmSection new]; s->_ident = d[@"id"]; s->_title = d[@"title"]; s->_icon = d[@"icon"] ?: @"gearshape"; s->_settings = list; return s;
}
@end

@implementation DmSettings {
    NSArray<DmSection *> *_sections; NSMutableDictionary<NSString *, DmSetting *> *_byKey;
    NSString *_path; NSMutableDictionary<NSString *, NSString *> *_user, *_envLock, *_launch;
    void (^_setEnv)(NSString *, NSString *); id (^_plist)(NSString *);
}
+ (NSArray<NSDictionary *> *)builtinSections {
    NSDictionary *(^slider)(NSString *, NSString *, NSString *, NSString *, double, double, double, NSString *) = ^(NSString *key, NSString *plist, NSString *label, NSString *detail, double min, double max, double step, NSString *def) {
        return @{@"key": key, @"plistKey": plist, @"label": label, @"detail": detail, @"type": @"slider", @"min": @(min), @"max": @(max), @"step": @(step), @"scale": @100, @"suffix": @"%", @"default": def}; };
    return @[
        @{@"id": @"display", @"title": @"Display", @"icon": @"display", @"settings": @[
            @{@"key": @"DM_LETTERBOX", @"plistKey": @"DMLetterbox", @"label": @"Bars around the picture", @"type": @"choice", @"default": @"ambient",
              @"detail": @"Ambient fills the bars with a soft blurred copy of the picture. Black leaves them plain black.",
              @"options": @[@{@"value": @"ambient", @"label": @"Ambient"}, @{@"value": @"black", @"label": @"Black", @"aliases": @[@"0"]}]},
            slider(@"DM_AMBIENT_LEVEL", @"DMAmbientLevel", @"Ambient brightness", @"How bright the blurred picture in the bars is.", 0.2, 1.0, 0.05, @"0.5")]},
        @{@"id": @"controls", @"title": @"Controls", @"icon": @"gamecontroller", @"settings": @[
            @{@"key": @"DM_CONTROLS_LAYOUT", @"plistKey": @"DMControlsLayout", @"label": @"Touch controls", @"type": @"choice", @"default": @"auto",
              @"detail": @"Auto puts the controls in the bars around the picture when the bars are tall enough. Overlay keeps them over the picture.",
              @"options": @[@{@"value": @"auto", @"label": @"Auto"}, @{@"value": @"overlay", @"label": @"Overlay", @"aliases": @[@"0"]}]},
            slider(@"DM_CONTROLS_SCALE", @"DMControlsScale", @"Controls size", @"Size of the stick, the A, B, X, Y keys and the D-pad. Bigger controls reach up over the picture.", 0.75, 2.5, 0.05, @"1"),
            slider(@"DM_CONTROLS_OPACITY", @"DMControlsOpacity", @"Controls opacity", @"How see-through the touch controls are.", 0.3, 1.0, 0.05, @"1")]},
        @{@"id": @"performance", @"title": @"Performance", @"icon": @"speedometer", @"settings": @[
            @{@"key": @"DM_SHOW_FPS", @"plistKey": @"DMShowFPS", @"label": @"Frame rate counter", @"type": @"toggle", @"default": @"0",
              @"detail": @"Shows the frames per second at the top of the screen."}]},
    ];
}
+ (NSArray<NSDictionary *> *)gameSectionsFromFile:(NSString *)path {
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (!data) return @[];
    NSError *e = nil; NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:&e];
    if (![j isKindOfClass:NSDictionary.class] || ![j[@"sections"] isKindOfClass:NSArray.class]) { say([NSString stringWithFormat:@"%@ is not a settings file: %@", path.lastPathComponent, e.localizedDescription ?: @"no \"sections\" array"]); return @[]; }
    return j[@"sections"];
}
+ (instancetype)shared {
    static DmSettings *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSMutableArray *secs = [[DmSettings builtinSections] mutableCopy];
        [secs addObjectsFromArray:[DmSettings gameSectionsFromFile:[[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm"] stringByAppendingPathComponent:@"settings.json"]]];
        s = [[DmSettings alloc] initWithSections:secs storePath:[doc stringByAppendingPathComponent:@"settings.json"]
            env:^NSString *(NSString *k) { const char *e = getenv(k.UTF8String); return e && *e ? @(e) : nil; }
            setEnv:^(NSString *k, NSString *v) { if (v) setenv(k.UTF8String, v.UTF8String, 1); else unsetenv(k.UTF8String); }
            plist:^id(NSString *k) { id p = [NSBundle.mainBundle objectForInfoDictionaryKey:k]; return [p isKindOfClass:NSString.class] && [p hasPrefix:@"$"] ? nil : p; }];   // xcodegen leaves an unset ${VAR} as it is
    });
    return s;
}
- (instancetype)initWithSections:(NSArray<NSDictionary *> *)sections storePath:(NSString *)path env:(NSString *(^)(NSString *))env setEnv:(void (^)(NSString *, NSString *))setEnv plist:(id (^)(NSString *))plist {
    if (!(self = [super init])) return nil;
    _path = path; _setEnv = [setEnv copy]; _plist = [plist copy]; _byKey = [NSMutableDictionary dictionary]; _user = [NSMutableDictionary dictionary]; _envLock = [NSMutableDictionary dictionary]; _launch = [NSMutableDictionary dictionary];
    NSMutableArray *secs = [NSMutableArray array];
    for (NSDictionary *d in sections) {
        DmSection *s = [DmSection sectionFromDictionary:d]; if (!s) { say([NSString stringWithFormat:@"skipped section %@", d[@"id"]]); continue; }
        NSMutableArray *keep = [NSMutableArray array];
        for (DmSetting *st in s.settings) { if (_byKey[st.key]) { say([NSString stringWithFormat:@"%@ is registered twice, the second entry is skipped", st.key]); continue; } _byKey[st.key] = st; [keep addObject:st]; }
        [s keepOnly:keep]; [secs addObject:s];
    }
    _sections = secs;
    for (DmSetting *st in _byKey.allValues) { NSString *e = env(st.key); NSString *n = e ? [st normalized:e] : nil; if (n) _envLock[st.key] = n; else if (e) say([NSString stringWithFormat:@"ignoring %@=%@ from the environment: not a valid value", st.key, e]); }
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    NSDictionary *j = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([j[@"values"] isKindOfClass:NSDictionary.class]) for (NSString *k in j[@"values"]) {
        DmSetting *st = _byKey[k]; NSString *n = st ? [st normalized:j[@"values"][k]] : nil;
        if (n) _user[k] = n; else say([NSString stringWithFormat:@"ignoring %@ in %@", k, path.lastPathComponent]);
    }
    for (DmSetting *st in _byKey.allValues) _launch[st.key] = [self valueForKey:st.key];
    return self;
}
- (DmSetting *)settingForKey:(NSString *)key { return _byKey[key]; }
- (DmSettingSource)sourceForKey:(NSString *)key {
    DmSetting *s = _byKey[key]; if (!s) return DmSourceDefault;
    if (_envLock[key]) return DmSourceEnv;
    if (_user[key]) return DmSourceUser;
    if (s.plistKey.length && [s normalized:_plist(s.plistKey)]) return DmSourcePlist;
    return DmSourceDefault;
}
- (NSString *)valueForKey:(NSString *)key {
    DmSetting *s = _byKey[key]; if (!s) return nil;
    switch ([self sourceForKey:key]) {
        case DmSourceEnv: return _envLock[key];
        case DmSourceUser: return _user[key];
        case DmSourcePlist: return [s normalized:_plist(s.plistKey)];
        default: return s.def;
    }
}
- (BOOL)boolForKey:(NSString *)key { return [[self valueForKey:key] isEqualToString:@"1"]; }
- (double)doubleForKey:(NSString *)key { return [self valueForKey:key].doubleValue; }
- (void)persist {
    NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"version": @1, @"values": _user} options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    NSError *e = nil; if (!d || ![d writeToFile:_path options:NSDataWritingAtomic error:&e]) say([NSString stringWithFormat:@"[RED] could not write %@: %@", _path.lastPathComponent, e.localizedDescription]);
}
- (void)announce:(NSString *)key { NSString *v = [self valueForKey:key]; _setEnv(key, v); [NSNotificationCenter.defaultCenter postNotificationName:DmSettingDidChangeNotification object:key userInfo:@{@"value": v}]; }
- (BOOL)setValue:(NSString *)value forKey:(NSString *)key {
    DmSetting *s = _byKey[key]; NSString *n = s ? [s normalized:value] : nil;
    if (!n || _envLock[key]) return NO;
    if ([_user[key] isEqualToString:n]) return YES;
    _user[key] = n; [self persist]; [self announce:key];
    return YES;
}
- (void)resetSection:(DmSection *)sec {
    BOOL any = NO;
    for (DmSetting *s in sec.settings) if (_user[s.key]) { [_user removeObjectForKey:s.key]; any = YES; }
    if (!any) return;
    [self persist];
    for (DmSetting *s in sec.settings) if (!_envLock[s.key]) [self announce:s.key];
}
- (BOOL)restartPending {
    for (DmSetting *s in _byKey.allValues) if (s.restart && ![[self valueForKey:s.key] isEqualToString:_launch[s.key]]) return YES;
    return NO;
}
- (void)applyToEnvironment {
    for (DmSetting *s in _byKey.allValues) { DmSettingSource src = [self sourceForKey:s.key]; if (src == DmSourceUser || src == DmSourcePlist) _setEnv(s.key, [self valueForKey:s.key]); }
}
@end

void dm_settings_boot(void) { [[DmSettings shared] applyToEnvironment]; }
