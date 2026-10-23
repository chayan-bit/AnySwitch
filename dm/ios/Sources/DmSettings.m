// In-app settings registry and store (see DmSettings.h).
#import "DmSettings.h"

NSNotificationName const DmSettingDidChangeNotification = @"DmSettingDidChange";

static NSString *fmt(double v) { return [NSString stringWithFormat:@"%g", round(v * 10000) / 10000]; }
static void say(NSString *m) { fprintf(stderr, "[dm] settings: %s\n", m.UTF8String); }
static NSArray<NSDictionary *> *withScopes(NSArray<NSDictionary *> *sections);

@interface DmSection ()
- (void)keepOnly:(NSArray<DmSetting *> *)k;
@end

@implementation DmSetting {
    NSString *_key, *_plistKey, *_label, *_detail, *_suffix, *_def;
    NSArray<NSDictionary *> *_options; NSDictionary<NSString *, NSString *> *_defaultAtFps; BOOL _exportDefault;
    DmSettingType _type; DmSettingScope _scope; double _min, _max, _step, _scale; BOOL _restart; NSInteger _decimals; NSUInteger _maxLength, _maxBytes; NSString *_requires, *_enabledWhenKey, *_enabledEquals, *_enabledNotEquals;
}
+ (instancetype)settingFromDictionary:(NSDictionary *)d error:(NSString **)err {
    DmSetting *s = [DmSetting new];
    NSString *key = d[@"key"], *label = d[@"label"], *type = d[@"type"];
    #define FAIL(m) do { if (err) *err = [NSString stringWithFormat:@"%@: %@", key ?: @"(no key)", m]; return nil; } while (0)
    if (![key isKindOfClass:NSString.class] || !key.length) FAIL(@"no key");
    if (![label isKindOfClass:NSString.class] || !label.length) FAIL(@"no label");
    s->_key = key; s->_label = label; s->_plistKey = d[@"plistKey"]; s->_detail = d[@"detail"]; s->_restart = [d[@"apply"] isEqualToString:@"restart"];
    if ([d[@"requires"] isKindOfClass:NSString.class] && [d[@"requires"] length]) s->_requires = d[@"requires"];
    id sc = d[@"scope"] ?: @"system";
    NSNumber *scope = [sc isKindOfClass:NSString.class] ? @{@"system": @(DmScopeSystem), @"game": @(DmScopeGame), @"both": @(DmScopeBoth)}[sc] : nil;
    if (!scope) FAIL(@"scope must be system, game or both");
    s->_scope = scope.integerValue;
    id when = d[@"enabledWhen"];
    if (when) {
        BOOL ok = [when isKindOfClass:NSDictionary.class]; NSString *wk = ok ? when[@"key"] : nil, *eq = ok ? when[@"equals"] : nil, *ne = ok ? when[@"notEquals"] : nil;
        BOOL hasEq = [eq isKindOfClass:NSString.class], hasNe = [ne isKindOfClass:NSString.class];
        if (![wk isKindOfClass:NSString.class] || !wk.length || [wk isEqualToString:key]) FAIL(@"enabledWhen needs the key of another setting");
        if (hasEq == hasNe) FAIL(@"enabledWhen needs exactly one of equals and notEquals (a string)");
        s->_enabledWhenKey = wk; s->_enabledEquals = hasEq ? eq : nil; s->_enabledNotEquals = hasNe ? ne : nil;
    }
    if ([type isEqualToString:@"toggle"]) s->_type = DmSettingToggle;
    else if ([type isEqualToString:@"choice"]) {
        s->_type = DmSettingChoice; s->_options = d[@"options"];
        if (![s->_options isKindOfClass:NSArray.class] || s->_options.count < 2) FAIL(@"a choice needs two or more options");
        for (NSDictionary *o in s->_options) if (![o[@"value"] isKindOfClass:NSString.class] || ![o[@"label"] isKindOfClass:NSString.class]) FAIL(@"an option needs a value and a label");
    } else if ([type isEqualToString:@"slider"]) {
        s->_type = DmSettingSlider; s->_min = [d[@"min"] doubleValue]; s->_max = [d[@"max"] doubleValue]; s->_step = [d[@"step"] doubleValue]; s->_scale = d[@"scale"] ? [d[@"scale"] doubleValue] : 1;
        s->_suffix = d[@"suffix"] ?: @"";
        if (!(s->_max > s->_min) || !(s->_step > 0)) FAIL(@"a slider needs min < max and a step > 0");
        if ([d[@"decimals"] isKindOfClass:NSNumber.class]) s->_decimals = MIN(MAX([d[@"decimals"] integerValue], 0), 3);
        else { double shown = s->_step * s->_scale; for (s->_decimals = 0; s->_decimals < 3 && fabs(shown * pow(10, s->_decimals) - round(shown * pow(10, s->_decimals))) > 1e-6; s->_decimals++); }
    } else if ([type isEqualToString:@"text"]) {
        s->_type = DmSettingText; s->_maxLength = [d[@"maxLength"] unsignedIntegerValue] ?: 64; s->_maxBytes = [d[@"maxBytes"] unsignedIntegerValue];
    } else FAIL(@"type must be toggle, choice, slider or text");
    NSString *def = d[@"default"];
    if (![def isKindOfClass:NSString.class]) FAIL(@"no default (a string)");
    s->_def = [s normalized:def];
    if (!s->_def) FAIL(@"the default does not parse");
    s->_exportDefault = [d[@"exportDefault"] boolValue];
    id atFps = d[@"defaultAtFps"];
    if (atFps) {   // {"30": "sharp"}: the default at that frame rate target; a live entry only (a restart entry would report a pending restart when the target moves), every value must parse
        if (![atFps isKindOfClass:NSDictionary.class] || !((NSDictionary *)atFps).count || s->_restart) FAIL(@"defaultAtFps is an object of fps to value, for a live entry");
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (id fps in atFps) {
            NSString *v = [atFps[fps] isKindOfClass:NSString.class] ? [s normalized:atFps[fps]] : nil;
            if (![fps isKindOfClass:NSString.class] || [fps intValue] <= 0 || !v) FAIL(@"defaultAtFps needs a positive fps and a value that parses");
            m[fps] = v;
        }
        s->_defaultAtFps = m;
    }
    #undef FAIL
    return s;
}
- (NSString *)normalized:(id)raw {
    if ([raw isKindOfClass:NSNumber.class]) raw = _type == DmSettingToggle ? ([raw boolValue] ? @"1" : @"0") : [raw stringValue];
    if (![raw isKindOfClass:NSString.class]) return nil;
    if (_type == DmSettingText) return [self normalizedText:raw];
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
        case DmSettingText: return nil;   // handled above
    }
}
// Text: trimmed, no control characters (a newline or a tab is refused, not dropped), cut at a whole character to the length limit and the byte limit
- (NSString *)normalizedText:(NSString *)raw {
    NSString *t = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!t.length || [t rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    __block NSUInteger end = 0, chars = 0, bytes = 0; NSUInteger maxChars = _maxLength, maxBytes = _maxBytes;
    [t enumerateSubstringsInRange:NSMakeRange(0, t.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) {
        (void)er; NSUInteger b = [sub lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (chars + 1 > maxChars || (maxBytes && bytes + b > maxBytes)) { *stop = YES; return; }
        chars++; bytes += b; end = NSMaxRange(r);
    }];
    NSString *cut = [[t substringToIndex:end] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return cut.length ? cut : nil;
}
- (BOOL)textFits:(NSString *)text {
    return [self textCount:text] <= _maxLength && (!_maxBytes || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= _maxBytes);
}
- (NSUInteger)textCount:(NSString *)text {
    __block NSUInteger chars = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *s, NSRange r, NSRange e, BOOL *stop) { (void)s; (void)r; (void)e; (void)stop; chars++; }];
    return chars;
}
- (NSString *)textLimitNote:(NSString *)text {
    if ([self textCount:text] >= _maxLength) return @"Limit reached";
    if (_maxBytes && [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1 > _maxBytes) return [NSString stringWithFormat:@"Limit reached (%lu bytes)", (unsigned long)_maxBytes];
    return nil;
}
- (NSString *)clippedReplacement:(NSString *)rep inText:(NSString *)text range:(NSRange)range {
    NSString *head = [text substringToIndex:range.location], *tail = [text substringFromIndex:NSMaxRange(range)];
    __block NSUInteger end = 0;
    [rep enumerateSubstringsInRange:NSMakeRange(0, rep.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *s, NSRange r, NSRange e, BOOL *stop) {
        (void)s; (void)e;
        if (![self textFits:[[head stringByAppendingString:[rep substringToIndex:NSMaxRange(r)]] stringByAppendingString:tail]]) { *stop = YES; return; }
        end = NSMaxRange(r);
    }];
    return [rep substringToIndex:end];
}
- (NSString *)displayValue:(NSString *)v {
    switch (_type) {
        case DmSettingToggle: return [v isEqualToString:@"1"] ? @"On" : @"Off";
        case DmSettingChoice: for (NSDictionary *o in _options) if ([o[@"value"] isEqualToString:v]) return o[@"label"]; return v;
        case DmSettingSlider: return [NSString stringWithFormat:@"%.*f%@", (int)_decimals, v.doubleValue * _scale, _suffix];
        case DmSettingText: return v;
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
    NSString *_path, *_gameId; NSMutableDictionary<NSString *, NSString *> *_user, *_game, *_envLock, *_launch, *_gameDef; int _frameTarget;   // _user: the system layer, _game: this game's layer
    void (^_setEnv)(NSString *, NSString *); id (^_plist)(NSString *); BOOL _quiet;   // _quiet: a store of a game that is not running (no notifications)
    __weak DmSettings *_peer;   // the store sharing this one's system layer (linkSystemLayer:)
}
+ (NSString *)internalResDetailForMemory:(unsigned long long)bytes {
    NSString *d = @"Draws the game at a multiple of its original resolution for a sharper picture. Higher settings use more memory and battery and can lower the frame rate.";
    return bytes > 8ull << 30 ? d : [d stringByAppendingString:@" This device has 8 GB of memory or less: at 2x, some of the picture may stay at 1x when memory runs short, and the game can close."];
}
+ (NSArray<NSDictionary *> *)builtinSections {
    NSDictionary *(^slider)(NSString *, NSString *, NSString *, NSString *, double, double, double, NSString *) = ^(NSString *key, NSString *plist, NSString *label, NSString *detail, double min, double max, double step, NSString *def) {
        return @{@"key": key, @"plistKey": plist, @"label": label, @"detail": detail, @"type": @"slider", @"min": @(min), @"max": @(max), @"step": @(step), @"scale": @100, @"suffix": @"%", @"default": def}; };
    NSArray *languages = @[@[@"en-US", @"English (US)"], @[@"en-GB", @"English (UK)"], @[@"ja", @"Japanese"], @[@"fr", @"French"], @[@"fr-CA", @"French (Canada)"], @[@"de", @"German"], @[@"it", @"Italian"],
                           @[@"es", @"Spanish"], @[@"es-419", @"Spanish (Latin America)"], @[@"nl", @"Dutch"], @[@"pt", @"Portuguese"], @[@"pt-BR", @"Portuguese (Brazil)"], @[@"ru", @"Russian"], @[@"ko", @"Korean"],
                           @[@"zh-Hans", @"Chinese (Simplified)"], @[@"zh-Hant", @"Chinese (Traditional)"]];
    NSMutableArray *langOptions = [NSMutableArray array];
    for (NSArray *l in languages) [langOptions addObject:@{@"value": l[0], @"label": l[1]}];
    NSMutableDictionary *ambient = [slider(@"DM_AMBIENT_LEVEL", @"DMAmbientLevel", @"Ambient brightness", @"How bright the blurred picture in the bars is.", 0.2, 1.0, 0.05, @"0.5") mutableCopy];
    ambient[@"enabledWhen"] = @{@"key": @"DM_LETTERBOX", @"notEquals": @"black"};   // black bars have no picture in them to brighten
    return withScopes(@[
        @{@"id": @"display", @"title": @"Display", @"icon": @"display", @"settings": @[
            @{@"key": @"DM_LETTERBOX", @"plistKey": @"DMLetterbox", @"label": @"Bars around the picture", @"type": @"choice", @"default": @"ambient",
              @"detail": @"Ambient fills the bars with a soft blurred copy of the picture. Black leaves them plain black.",
              @"options": @[@{@"value": @"ambient", @"label": @"Ambient"}, @{@"value": @"black", @"label": @"Black", @"aliases": @[@"0"]}]},
            ambient,
            @{@"key": @"DM_UPSCALE", @"label": @"Upscaling", @"type": @"choice", @"default": @"bilinear", @"defaultAtFps": @{@"30": @"sharp"},   // Sharp costs about 4 ms of GPU per frame: an eighth of a 30 fps frame, a quarter of a 60 fps one
              @"detail": @"How the game's picture is enlarged to the screen. Sharp (AMD FidelityFX Super Resolution 1) keeps edges and text crisp, and is the default for games that run at 30 fps. Bilinear is the plain, softer stretch and costs the least; it is the default at 60 fps.",
              @"options": @[@{@"value": @"bilinear", @"label": @"Bilinear"}, @{@"value": @"sharp", @"label": @"Sharp"}]},
            @{@"key": @"DM_UPSCALE_SHARPNESS", @"label": @"Sharpening", @"type": @"slider", @"min": @0, @"max": @1.0, @"step": @0.05, @"scale": @100, @"suffix": @"%", @"default": @"0.8",
              @"enabledWhen": @{@"key": @"DM_UPSCALE", @"equals": @"sharp"},   // bilinear has no sharpening pass
              @"detail": @"How strongly Sharp sharpens the enlarged picture. 0% keeps only the edge-aware enlargement."},
            @{@"key": @"DM_RENDER_SCALE", @"label": @"Render scale", @"type": @"slider", @"min": @0.5, @"max": @1.0, @"step": @0.05, @"scale": @100, @"suffix": @"%", @"default": @"1", @"apply": @"restart", @"requires": @"fstep",
              @"detail": @"Draws the 3D picture at a fraction of the game's own size, which runs cooler and smoother. 100% keeps the game's own size and its dynamic resolution."},
            @{@"key": @"DM_INTERNAL_RES", @"plistKey": @"DMInternalRes", @"label": @"Internal resolution", @"type": @"choice", @"default": @"1", @"apply": @"restart", @"requires": @"internalres",
              @"detail": [self internalResDetailForMemory:NSProcessInfo.processInfo.physicalMemory],
              @"options": @[@{@"value": @"1", @"label": @"1x (original)", @"aliases": @[@"1.0"]}, @{@"value": @"1.5", @"label": @"1.5x"}, @{@"value": @"2", @"label": @"2x", @"aliases": @[@"2.0"]}]},
            @{@"key": @"DM_OPMODE", @"label": @"Console mode", @"type": @"choice", @"default": @"1", @"apply": @"restart", @"exportDefault": @YES,   // the host's own default is the game profile's op_mode; a game that needs Handheld says so in its pack defaults
              @"detail": @"Docked draws the game at its larger docked resolution. Handheld draws it at its portable resolution, which saves power and runs cooler. Auto is Docked while an external display is connected, else Handheld.",
              @"options": @[@{@"value": @"auto", @"label": @"Auto"}, @{@"value": @"0", @"label": @"Handheld", @"aliases": @[@"handheld"]}, @{@"value": @"1", @"label": @"Docked", @"aliases": @[@"docked", @"console"]}]}]},
        @{@"id": @"controls", @"title": @"Controls", @"icon": @"gamecontroller", @"settings": @[
            @{@"key": @"DM_CONTROLS_LAYOUT", @"plistKey": @"DMControlsLayout", @"label": @"Touch controls", @"type": @"choice", @"default": @"auto",
              @"detail": @"Auto puts the controls in the bars around the picture when the bars are tall enough. Overlay keeps them over the picture.",
              @"options": @[@{@"value": @"auto", @"label": @"Auto"}, @{@"value": @"overlay", @"label": @"Overlay", @"aliases": @[@"0"]}]},
            slider(@"DM_CONTROLS_SCALE", @"DMControlsScale", @"Controls size", @"Size of the stick, the A, B, X, Y keys and the D-pad. Bigger controls reach up over the picture.", 0.75, 2.5, 0.05, @"1"),
            slider(@"DM_CONTROLS_OPACITY", @"DMControlsOpacity", @"Controls opacity", @"How see-through the touch controls are.", 0.3, 1.0, 0.05, @"1"),
            @{@"key": @"DM_CONTROLS_IDLE_FADE", @"label": @"Fade when idle", @"type": @"toggle", @"default": @"1",
              @"detail": @"Fades the touch controls after a few seconds without a touch, so they do not cover the game's own prompts. A touch brings them back."},
            @{@"key": @"DM_PAD_LAYOUT", @"label": @"Touch layout", @"type": @"choice", @"default": @"auto",
              @"detail": @"2D shows the buttons a 2D game needs. 3D adds the D-pad, the right stick and the stick buttons. Game's choice uses the layout the game starts in. The 2D / 3D button over the game switches it too.",
              @"options": @[@{@"value": @"auto", @"label": @"Game's choice"}, @{@"value": @"2d", @"label": @"2D"}, @{@"value": @"3d", @"label": @"3D"}]},
            @{@"key": @"DM_SHAKE_G", @"label": @"Shake sensitivity", @"type": @"slider", @"min": @0.5, @"max": @4.0, @"step": @0.1, @"scale": @1, @"suffix": @" G", @"default": @"1.5",
              @"detail": @"How hard the device has to be shaken to shake the controller. A lower number reacts to a gentler shake."},
            @{@"key": @"DM_VIBRATION", @"label": @"Vibration", @"type": @"toggle", @"default": @"1", @"requires": @"haptics",
              @"detail": @"Plays the game's rumble on the controller, or on the device when no controller is connected."},
            @{@"key": @"DM_VIBRATION_STRENGTH", @"label": @"Vibration strength", @"type": @"slider", @"min": @0, @"max": @1.0, @"step": @0.05, @"scale": @100, @"suffix": @"%", @"default": @"1", @"requires": @"haptics", @"enabledWhen": @{@"key": @"DM_VIBRATION", @"equals": @"1"},   // no rumble, nothing to scale
              @"detail": @"How strong the rumble feels. 100% is the game's own level."}]},
        @{@"id": @"audio", @"title": @"Audio", @"icon": @"speaker.wave.2", @"settings": @[
            slider(@"DM_VOLUME", @"DMVolume", @"Volume", @"The game's sound level. The device's own volume still applies on top.", 0, 1.0, 0.05, @"1")]},
        @{@"id": @"performance", @"title": @"Performance", @"icon": @"speedometer", @"settings": @[
            @{@"key": @"DM_FPS_TARGET", @"label": @"Frame rate cap", @"type": @"choice", @"default": @"0", @"apply": @"restart", @"requires": @"fpscap",
              @"detail": @"Game decides leaves the frame rate to the game. 30 or 60 caps it, which can run cooler.",
              @"options": @[@{@"value": @"0", @"label": @"Game decides"}, @{@"value": @"30", @"label": @"30 fps"}, @{@"value": @"60", @"label": @"60 fps"}]},
            @{@"key": @"DM_PSO_FLEX", @"label": @"Flexible pipelines", @"type": @"toggle", @"default": @"1", @"apply": @"restart", @"requires": @"nvn", @"exportDefault": @YES,   // the host's own default is off (the Mac host and its tests)
              @"detail": @"Prepares the game's graphics pipelines in the background and skips a draw for a moment instead of stalling. It can make the first launch slightly slower but avoids hitches while playing."},
            @{@"key": @"DM_SHOW_FPS", @"plistKey": @"DMShowFPS", @"label": @"Frame rate counter", @"type": @"toggle", @"default": @"0",
              @"detail": @"Shows the frames per second at the top of the screen."}]},
        @{@"id": @"system", @"title": @"System", @"icon": @"gearshape", @"settings": @[
            @{@"key": @"DM_LANG", @"label": @"Game language", @"type": @"choice", @"default": @"en-US", @"apply": @"restart", @"options": langOptions,
              @"detail": @"The language the game starts in, when it has it. The game reads it once at start."},
            @{@"key": @"DM_NICK", @"label": @"Player name", @"type": @"text", @"default": @"Player", @"maxLength": @32, @"maxBytes": @32, @"apply": @"restart",
              @"detail": @"The name the game shows for the player, up to 32 characters."}]},
        @{@"id": @"appearance", @"title": @"Appearance", @"icon": @"circle.lefthalf.filled", @"settings": @[
            @{@"key": @"DM_APPEARANCE", @"label": @"Appearance", @"type": @"choice", @"default": @"system",
              @"options": @[@{@"value": @"system", @"label": @"Same as the device"}, @{@"value": @"light", @"label": @"Light"}, @{@"value": @"dark", @"label": @"Dark"}],
              @"detail": @"Light or dark menus, or follow the device's own appearance."}]},
    ]);
}
// Where each built-in entry's player choice lives (docs/settings.md); an entry not named here is system
+ (NSDictionary<NSString *, NSString *> *)builtinScopes {
    return @{@"DM_LETTERBOX": @"both", @"DM_UPSCALE": @"both", @"DM_UPSCALE_SHARPNESS": @"both", @"DM_RENDER_SCALE": @"game", @"DM_INTERNAL_RES": @"game", @"DM_OPMODE": @"both",
             @"DM_CONTROLS_LAYOUT": @"both", @"DM_PAD_LAYOUT": @"game", @"DM_VIBRATION": @"both", @"DM_FPS_TARGET": @"game", @"DM_PSO_FLEX": @"game", @"DM_LANG": @"both"};
}
static NSArray<NSDictionary *> *withScope(NSArray<NSDictionary *> *sections, NSString *(^scopeOf)(NSDictionary *entry)) {   // copies with "scope" set on the entries scopeOf names one for
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *sec in sections) {
        if (![sec isKindOfClass:NSDictionary.class] || ![sec[@"settings"] isKindOfClass:NSArray.class]) { [out addObject:sec]; continue; }
        NSMutableArray *list = [NSMutableArray array];
        for (NSDictionary *e in sec[@"settings"]) {
            NSString *sc = [e isKindOfClass:NSDictionary.class] ? scopeOf(e) : nil;
            if (!sc) { [list addObject:e]; continue; }
            NSMutableDictionary *m = [e mutableCopy]; m[@"scope"] = sc; [list addObject:m];
        }
        NSMutableDictionary *m = [sec mutableCopy]; m[@"settings"] = list; [out addObject:m];
    }
    return out;
}
static NSArray<NSDictionary *> *withScopes(NSArray<NSDictionary *> *sections) {
    NSDictionary *t = [DmSettings builtinScopes];
    return withScope(sections, ^NSString *(NSDictionary *e) { id k = e[@"key"]; return [k isKindOfClass:NSString.class] ? t[k] : nil; });
}
static NSDictionary *gameFile(NSString *path) {
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (!data) return nil;
    NSError *e = nil; id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:&e];
    if (![j isKindOfClass:NSDictionary.class]) { say([NSString stringWithFormat:@"%@ is not a settings file: %@", path.lastPathComponent, e.localizedDescription ?: @"not an object"]); return nil; }
    return j;
}
+ (NSArray<NSDictionary *> *)gameSectionsFromFile:(NSString *)path {
    NSDictionary *j = gameFile(path); if (!j) return @[];
    if (j[@"sections"] == nil) return @[];   // a file may hold only "defaults"
    if (![j[@"sections"] isKindOfClass:NSArray.class]) { say([NSString stringWithFormat:@"%@: \"sections\" is not an array", path.lastPathComponent]); return @[]; }
    return withScope(j[@"sections"], ^NSString *(NSDictionary *e) { return e[@"scope"] ? nil : @"game"; });   // a game's own rows are per game unless they say otherwise
}
+ (NSDictionary<NSString *, id> *)gameDefaultsFromFile:(NSString *)path {
    NSDictionary *j = gameFile(path); if (!j || j[@"defaults"] == nil) return @{};
    if (![j[@"defaults"] isKindOfClass:NSDictionary.class]) { say([NSString stringWithFormat:@"%@: \"defaults\" is not an object", path.lastPathComponent]); return @{}; }
    return j[@"defaults"];
}
static NSString *g_game_id, *g_pack_root;   // the launched game and its pack (Hearth); nil = no game: the shared store is the system store
static BOOL g_shared_made;
static __weak DmSettings *g_shared_store, *g_system_store;   // linked once both exist
void dm_settings_set_game(NSString *titleId, NSString *root) {
    if (g_shared_made) say(@"[RED] dm_settings_set_game after the shared store was made: it stays the store it was");
    g_game_id = titleId.copy; g_pack_root = root.copy;
}
// A store over Documents/settings.json and the process environment; live = it exports to the environment and announces changes (the running game's, or the system store when none runs)
static DmSettings *app_store(NSString *gameId, NSString *packRoot, BOOL live) {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *game = gameId ? [packRoot stringByAppendingPathComponent:@"profile/settings.json"] : nil;
    NSMutableArray *secs = [[DmSettings builtinSections] mutableCopy];
    if (game) [secs addObjectsFromArray:[DmSettings gameSectionsFromFile:game]];
    DmSettings *s = [[DmSettings alloc] initWithSections:secs gameDefaults:game ? [DmSettings gameDefaultsFromFile:game] : nil caps:nil gameId:gameId storePath:[doc stringByAppendingPathComponent:@"settings.json"]
        env:^NSString *(NSString *k) { const char *e = getenv(k.UTF8String); return e && *e ? @(e) : nil; }
        setEnv:live ? ^(NSString *k, NSString *v) { if (v) setenv(k.UTF8String, v.UTF8String, 1); else unsetenv(k.UTF8String); } : ^(NSString *k, NSString *v) { (void)k; (void)v; }
        plist:^id(NSString *k) { id p = [NSBundle.mainBundle objectForInfoDictionaryKey:k]; return [p isKindOfClass:NSString.class] && [p hasPrefix:@"$"] ? nil : p; }];   // xcodegen leaves an unset ${VAR} as it is
    s->_quiet = !live;
    return s;
}
+ (instancetype)shared {
    static DmSettings *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ g_shared_made = YES; s = app_store(g_game_id, g_pack_root, YES); g_shared_store = s; [g_system_store linkSystemLayer:s]; });
    return s;
}
// Its own store, never the shared one: Home reads it before a game is launched in this process, and the shared store must become that game's.
// It neither exports nor announces itself; it is linked to the shared store (linkSystemLayer:), so a change made on Home reaches the running game through the game's store
+ (instancetype)systemStore {
    static DmSettings *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = app_store(nil, nil, NO); g_system_store = s; [g_shared_store linkSystemLayer:s]; });
    return s;
}
+ (instancetype)storeForGame:(NSString *)titleId packRoot:(NSString *)root {
    return [titleId isEqualToString:g_game_id] ? [self shared] : app_store(titleId, root, NO);
}
- (instancetype)initWithSections:(NSArray<NSDictionary *> *)sections storePath:(NSString *)path env:(NSString *(^)(NSString *))env setEnv:(void (^)(NSString *, NSString *))setEnv plist:(id (^)(NSString *))plist {
    return [self initWithSections:sections gameDefaults:nil caps:nil gameId:nil storePath:path env:env setEnv:setEnv plist:plist];
}
- (instancetype)initWithSections:(NSArray<NSDictionary *> *)sections gameDefaults:(NSDictionary<NSString *, id> *)gameDefaults caps:(BOOL (^)(NSString *))caps storePath:(NSString *)path env:(NSString *(^)(NSString *))env setEnv:(void (^)(NSString *, NSString *))setEnv plist:(id (^)(NSString *))plist {
    return [self initWithSections:sections gameDefaults:gameDefaults caps:caps gameId:nil storePath:path env:env setEnv:setEnv plist:plist];
}
// The file as {"system": {...}, "games": {...}}: version 2 as it is, a version 1 file's "values" as the system layer, anything else empty
static NSDictionary *read_store(NSString *path) {
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    NSDictionary *j = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![j isKindOfClass:NSDictionary.class]) return @{};
    if ([j[@"version"] isKindOfClass:NSNumber.class] && [j[@"version"] intValue] >= 2) return j;
    return [j[@"values"] isKindOfClass:NSDictionary.class] ? @{@"system": j[@"values"]} : @{};
}
// Sections that share an id become one page: the first one's title and icon, the entries of all of them in order
static NSArray<NSDictionary *> *mergeById(NSArray<NSDictionary *> *sections) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array]; NSMutableDictionary<NSString *, NSNumber *> *at = [NSMutableDictionary dictionary];
    for (NSDictionary *d in sections) {
        NSString *ident = d[@"id"]; NSNumber *i = [ident isKindOfClass:NSString.class] ? at[ident] : nil;
        if (!i) { if ([ident isKindOfClass:NSString.class]) at[ident] = @(out.count); [out addObject:d]; continue; }
        NSMutableDictionary *m = [out[i.unsignedIntegerValue] mutableCopy];
        NSArray *a = [m[@"settings"] isKindOfClass:NSArray.class] ? m[@"settings"] : @[], *b = [d[@"settings"] isKindOfClass:NSArray.class] ? d[@"settings"] : @[];
        m[@"settings"] = [a arrayByAddingObjectsFromArray:b]; out[i.unsignedIntegerValue] = m;
    }
    return out;
}
- (instancetype)initWithSections:(NSArray<NSDictionary *> *)sections gameDefaults:(NSDictionary<NSString *, id> *)gameDefaults caps:(BOOL (^)(NSString *))caps gameId:(NSString *)gameId storePath:(NSString *)path env:(NSString *(^)(NSString *))env setEnv:(void (^)(NSString *, NSString *))setEnv plist:(id (^)(NSString *))plist {
    if (!(self = [super init])) return nil;
    _path = path; _gameId = gameId.copy; _setEnv = [setEnv copy]; _plist = [plist copy]; _capabilities = [caps copy]; _byKey = [NSMutableDictionary dictionary]; _user = [NSMutableDictionary dictionary]; _game = [NSMutableDictionary dictionary]; _envLock = [NSMutableDictionary dictionary]; _launch = [NSMutableDictionary dictionary]; _gameDef = [NSMutableDictionary dictionary];
    NSMutableArray *secs = [NSMutableArray array];
    for (NSDictionary *d in mergeById(sections)) {
        DmSection *s = [DmSection sectionFromDictionary:d]; if (!s) { say([NSString stringWithFormat:@"skipped section %@", d[@"id"]]); continue; }
        NSMutableArray *keep = [NSMutableArray array];
        for (DmSetting *st in s.settings) { if (_byKey[st.key]) { say([NSString stringWithFormat:@"%@ is registered twice, the second entry is skipped", st.key]); continue; } _byKey[st.key] = st; [keep addObject:st]; }
        [s keepOnly:keep]; [secs addObject:s];
    }
    _sections = secs;
    for (DmSetting *st in _byKey.allValues) if (st.enabledWhenKey && !_byKey[st.enabledWhenKey]) say([NSString stringWithFormat:@"%@: enabledWhen names %@, which is not registered: always enabled", st.key, st.enabledWhenKey]);
    for (NSString *k in gameDefaults) {
        DmSetting *st = _byKey[k]; NSString *n = st ? [st normalized:gameDefaults[k]] : nil;
        if (n) _gameDef[k] = n; else say([NSString stringWithFormat:@"ignoring the game default of %@", k]);
    }
    for (DmSetting *st in _byKey.allValues) { NSString *e = env(st.key); NSString *n = e ? [st normalized:e] : nil; if (n) _envLock[st.key] = n; else if (e) say([NSString stringWithFormat:@"ignoring %@=%@ from the environment: not a valid value", st.key, e]); }
    NSDictionary *f = read_store(path), *games = [f[@"games"] isKindOfClass:NSDictionary.class] ? f[@"games"] : nil;
    [self load:f[@"system"] into:_user from:path];
    if (_gameId) [self load:games[_gameId] into:_game from:path];
    for (DmSetting *st in _byKey.allValues) _launch[st.key] = [self valueForKey:st.key];
    return self;
}
- (void)load:(NSDictionary *)layer into:(NSMutableDictionary<NSString *, NSString *> *)into from:(NSString *)path {
    if (![layer isKindOfClass:NSDictionary.class]) return;
    for (NSString *k in layer) {
        DmSetting *st = [k isKindOfClass:NSString.class] ? _byKey[k] : nil; NSString *n = st ? [st normalized:layer[k]] : nil;
        if (n) into[k] = n; else say([NSString stringWithFormat:@"ignoring %@ in %@", k, path.lastPathComponent]);
    }
}
- (BOOL)inGameLayer:(DmSetting *)s { return _gameId && s.scope != DmScopeSystem; }   // where this store keeps the player's choice of s
- (DmSetting *)settingForKey:(NSString *)key { return _byKey[key]; }
- (BOOL)isAvailable:(DmSetting *)s { return !s.requires.length || !_capabilities || _capabilities(s.requires); }
- (NSArray<DmSetting *> *)visibleSettingsInSection:(DmSection *)sec {
    NSMutableArray *out = [NSMutableArray array]; for (DmSetting *s in sec.settings) if ([self isAvailable:s] && (_gameId || s.scope != DmScopeGame)) [out addObject:s]; return out;
}
- (NSArray<DmSection *> *)visibleSections {
    NSMutableArray *out = [NSMutableArray array]; for (DmSection *s in _sections) if ([self visibleSettingsInSection:s].count) [out addObject:s]; return out;
}
// `enabledWhen` compares the other setting's effective value (the environment counts) with the condition, both as that setting stores them; a condition that does not parse never disables
- (BOOL)isEnabled:(DmSetting *)s {
    DmSetting *dep = s.enabledWhenKey ? _byKey[s.enabledWhenKey] : nil; if (!dep) return YES;
    NSString *want = [dep normalized:s.enabledEquals ?: s.enabledNotEquals]; if (!want) return YES;
    return [[self valueForKey:dep.key] isEqualToString:want] == (s.enabledEquals != nil);
}
- (NSString *)disabledNote:(DmSetting *)s {
    if ([self isEnabled:s]) return nil;
    DmSetting *dep = _byKey[s.enabledWhenKey]; NSString *shown = [dep displayValue:[dep normalized:s.enabledEquals ?: s.enabledNotEquals]];
    return [NSString stringWithFormat:s.enabledEquals ? @"Has no effect unless %@ is %@" : @"Has no effect while %@ is %@", dep.label, shown];
}
- (DmSettingSource)sourceForKey:(NSString *)key {
    DmSetting *s = _byKey[key]; if (!s) return DmSourceDefault;
    if (_envLock[key]) return DmSourceEnv;
    if ([self inGameLayer:s] && _game[key]) return DmSourceGame;
    if (_user[key]) return DmSourceUser;   // a game entry's system value only comes from a version 1 file, the single game's choice then
    if (s.plistKey.length && [s normalized:_plist(s.plistKey)]) return DmSourcePlist;
    return DmSourceDefault;
}
- (NSString *)systemValueForKey:(NSString *)key { return _user[key] ?: [self defaultValueForKey:key]; }   // the plist counts as part of the default here
- (BOOL)followsSystem:(DmSetting *)s { return _gameId && s.scope == DmScopeBoth && !_game[s.key]; }
- (void)useSystemForKey:(NSString *)key { DmSetting *s = _byKey[key]; if (s && [self inGameLayer:s]) [self dropKeys:@[key]]; }
- (NSString *)valueForKey:(NSString *)key {
    DmSetting *s = _byKey[key]; if (!s) return nil;
    switch ([self sourceForKey:key]) {
        case DmSourceEnv: return _envLock[key];
        case DmSourceGame: return _game[key];
        case DmSourceUser: return _user[key];
        case DmSourcePlist: return [s normalized:_plist(s.plistKey)];
        default: return [self defaultValueForKey:key];
    }
}
- (NSString *)defaultValueForKey:(NSString *)key {
    DmSetting *s = _byKey[key]; if (!s) return nil;
    NSString *p = s.plistKey.length ? [s normalized:_plist(s.plistKey)] : nil;
    return p ?: _gameDef[key] ?: (_frameTarget > 0 ? s.defaultAtFps[[NSString stringWithFormat:@"%d", _frameTarget]] : nil) ?: s.def;
}
- (int)frameTarget { return _frameTarget; }
- (void)setFrameTarget:(int)target {
    if (target == _frameTarget) return;
    NSMutableDictionary<NSString *, NSString *> *before = [NSMutableDictionary dictionary];
    for (DmSetting *s in _byKey.allValues) if (s.defaultAtFps) before[s.key] = [self valueForKey:s.key];
    _frameTarget = target;
    for (NSString *k in [before.allKeys sortedArrayUsingSelector:@selector(compare:)]) {   // a user's or the environment's value does not move with the target, so only a default is announced
        NSString *v = [self valueForKey:k]; if ([v isEqualToString:before[k]]) continue;
        [NSNotificationCenter.defaultCenter postNotificationName:DmSettingDidChangeNotification object:k userInfo:@{@"value": v}];   // not exported to the environment: it is a default, not a choice
    }
}
- (BOOL)boolForKey:(NSString *)key { return [[self valueForKey:key] isEqualToString:@"1"]; }
- (double)doubleForKey:(NSString *)key { return [self valueForKey:key].doubleValue; }
// Writes these keys' current choices into the file on disk, each into the layer this store keeps it in, leaving every other key there as it is
- (void)persist:(NSArray<NSString *> *)keys {
    NSDictionary *f = read_store(_path);
    NSMutableDictionary *sys = [f[@"system"] isKindOfClass:NSDictionary.class] ? [f[@"system"] mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableDictionary *games = [f[@"games"] isKindOfClass:NSDictionary.class] ? [f[@"games"] mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableDictionary *mine = _gameId && [games[_gameId] isKindOfClass:NSDictionary.class] ? [games[_gameId] mutableCopy] : [NSMutableDictionary dictionary];
    for (NSString *k in keys) { BOOL g = [self inGameLayer:_byKey[k]]; (g ? mine : sys)[k] = (g ? _game : _user)[k]; }   // nil removes
    if (_gameId) { if (mine.count) games[_gameId] = mine; else [games removeObjectForKey:_gameId]; }
    NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"version": @2, @"system": sys, @"games": games} options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    NSError *e = nil; if (!d || ![d writeToFile:_path options:NSDataWritingAtomic error:&e]) say([NSString stringWithFormat:@"[RED] could not write %@: %@", _path.lastPathComponent, e.localizedDescription]);
    for (NSString *k in keys) if (![self inGameLayer:_byKey[k]]) [_peer peerSystemValue:_user[k] forKey:k];   // every change of the system layer passes here
}
- (void)linkSystemLayer:(DmSettings *)other { if (other == self) return; _peer = other; other->_peer = self; }
// The peer's system layer changed for key (v nil: no choice): take it, and when this store's effective value changes with it, export and announce it here
- (void)peerSystemValue:(NSString *)v forKey:(NSString *)key {
    if (!_byKey[key]) return;
    NSString *before = [self valueForKey:key];
    if (v) _user[key] = v; else [_user removeObjectForKey:key];
    if (![before isEqualToString:[self valueForKey:key]]) [self announce:key];
}
- (void)announce:(NSString *)key {
    NSString *v = [self valueForKey:key]; _setEnv(key, v);
    if (!_quiet) [NSNotificationCenter.defaultCenter postNotificationName:DmSettingDidChangeNotification object:key userInfo:@{@"value": v}];
}
- (BOOL)setValue:(NSString *)value forKey:(NSString *)key {
    DmSetting *s = _byKey[key]; NSString *n = s ? [s normalized:value] : nil;
    if (!n || _envLock[key] || (!_gameId && s.scope == DmScopeGame)) return NO;
    BOOL g = [self inGameLayer:s]; NSMutableDictionary *layer = g ? _game : _user;
    // The value it would have without this choice again (a game: its system value; the system: the default): no explicit copy, so a later change of what it falls back to still applies
    // (not for a default that moves with the frame rate target: the choice is kept)
    if (!s.defaultAtFps && [n isEqualToString:g ? [self systemValueForKey:key] : [self defaultValueForKey:key]]) {
        if (layer[key]) { [layer removeObjectForKey:key]; [self persist:@[key]]; [self announce:key]; }
        return YES;
    }
    if ([layer[key] isEqualToString:n]) return YES;
    layer[key] = n; [self persist:@[key]]; [self announce:key];
    return YES;
}
- (void)dropKeys:(NSArray<NSString *> *)keys {   // forgets the user's choices of these keys (each from the layer this store keeps it in), stores once, announces each key the environment does not set
    NSMutableArray *gone = [NSMutableArray array];
    for (NSString *k in keys) { NSMutableDictionary *layer = [self inGameLayer:_byKey[k]] ? _game : _user; if (layer[k]) { [layer removeObjectForKey:k]; [gone addObject:k]; } }
    if (!gone.count) return;
    [self persist:gone];
    for (NSString *k in [gone sortedArrayUsingSelector:@selector(compare:)]) if (!_envLock[k]) [self announce:k];
}
- (void)resetSection:(DmSection *)sec { [self dropKeys:[sec.settings valueForKey:@"key"]]; }
- (void)resetAll { [self dropKeys:_byKey.allKeys]; }
- (BOOL)restartPending {
    for (DmSetting *s in _byKey.allValues) if (s.restart && ![[self valueForKey:s.key] isEqualToString:_launch[s.key]]) return YES;
    return NO;
}
- (void)applyToEnvironment {
    for (DmSetting *s in _byKey.allValues) {
        DmSettingSource src = [self sourceForKey:s.key];
        if (src == DmSourceUser || src == DmSourceGame || src == DmSourcePlist || (src == DmSourceDefault && (_gameDef[s.key] || s.exportDefault))) _setEnv(s.key, [self valueForKey:s.key]);   // a registry default is the code's own default and is not exported, unless the entry says its code defaults to something else (exportDefault)
    }
}
@end

void dm_settings_boot(void) { [[DmSettings shared] applyToEnvironment]; }

NSArray<NSArray<NSString *> *> *dm_hints_for_focus(DmFocusKind kind, BOOL locked, BOOL armed) {
    NSMutableArray *h = [NSMutableArray array];
    if (kind == DmFocusCategory) return @[@[@"A", @"Open"], @[@"B", @"Close"], @[@"L R", @"Category"]];
    if (kind == DmFocusEditor) return @[];   // the editor panel has its own Cancel and Save buttons; a footer would sit behind the soft keyboard
    if (kind == DmFocusHomeGame) return @[@[@"A", @"Start"], @[@"+", @"Options"]];   // Home has no Back: B does nothing there
    if (kind == DmFocusHomeBlocked) return @[@[@"A", @"Details"], @[@"+", @"Options"]];
    if (kind == DmFocusHomeButton) return @[@[@"A", @"Open"]];
    if (kind == DmFocusHomeRunning) return @[@[@"A", @"Resume"], @[@"X", @"Close"], @[@"+", @"Options"]];
    if (!locked) switch (kind) {
        case DmFocusToggle: [h addObject:@[@"↔", @"Change"]]; [h addObject:@[@"A", @"Toggle"]]; break;
        case DmFocusChoice: [h addObject:@[@"↔", @"Change"]]; [h addObject:@[@"A", @"Next"]]; break;
        case DmFocusSlider: [h addObject:@[@"↔", @"Change"]]; break;
        case DmFocusText: [h addObject:@[@"A", @"Edit"]]; break;
        case DmFocusRestore: [h addObject:@[@"A", @"Restore"]]; break;
        case DmFocusRestoreAll: [h addObject:@[@"A", armed ? @"Confirm" : @"Restore"]]; break;
        case DmFocusRestart: [h addObject:@[@"A", @"Restart"]]; break;
        case DmFocusAction: [h addObject:@[@"A", armed ? @"Confirm" : @"Select"]]; break;
        default: break;
    }
    [h addObject:@[@"B", @"Back"]]; [h addObject:@[@"L R", @"Category"]];
    return h;
}
