// Registry and precedence of the in-app settings (dm/ios/Sources/DmSettings.m): environment > user file > Info.plist > default, locking, persistence, restart tracking, per-game sections.
// Foundation only, runs on the Mac: make -C dm/ios/tests run
#import <Foundation/Foundation.h>
#import "DmSettings.h"
#import "DmPalette.h"

static int g_fail, g_n;
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_fail++; printf("FAIL line %d: %s  ", __LINE__, #c); printf(__VA_ARGS__); printf("\n"); } } while (0)
#define EQ(a, b) do { NSString *_a = (a), *_b = (b); g_n++; if (!((_a == nil && _b == nil) || [_a isEqualToString:_b])) { g_fail++; printf("FAIL line %d: %s = %s, wanted %s\n", __LINE__, #a, _a.UTF8String ?: "(nil)", _b.UTF8String ?: "(nil)"); } } while (0)

static NSString *tmpFile(void) { return [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_settings_%@.json", NSUUID.UUID.UUIDString]]; }

// A store over fake environment and plist dictionaries (the real ones are the process environment and the Info.plist)
static DmSettings *make(NSArray *sections, NSString *path, NSMutableDictionary *env, NSDictionary *plist) {
    return [[DmSettings alloc] initWithSections:sections storePath:path env:^NSString *(NSString *k) { return env[k]; }
        setEnv:^(NSString *k, NSString *v) { if (v) env[k] = v; else [env removeObjectForKey:k]; } plist:^id(NSString *k) { return plist[k]; }];
}

static DmSettings *makeEx(NSArray *sections, NSDictionary *gameDefaults, BOOL (^caps)(NSString *), NSString *path, NSMutableDictionary *env, NSDictionary *plist) {
    return [[DmSettings alloc] initWithSections:sections gameDefaults:gameDefaults caps:caps storePath:path env:^NSString *(NSString *k) { return env[k]; }
        setEnv:^(NSString *k, NSString *v) { if (v) env[k] = v; else [env removeObjectForKey:k]; } plist:^id(NSString *k) { return plist[k]; }];
}
static DmSetting *find(DmSettings *s, NSString *key) { return [s settingForKey:key]; }

static NSDictionary *gameSection(void) {
    return @{@"id": @"game", @"title": @"Some Game", @"icon": @"star", @"settings": @[
        @{@"key": @"DM_GAME_FAST", @"label": @"Fast mode", @"type": @"toggle", @"default": @"0", @"apply": @"restart"},
        @{@"key": @"DM_GAME_LEVEL", @"label": @"Level", @"type": @"choice", @"default": @"b", @"options": @[@{@"value": @"a", @"label": @"A"}, @{@"value": @"b", @"label": @"B"}]},
        @{@"key": @"DM_GAME_BAD", @"label": @"Broken", @"type": @"slider", @"default": @"1", @"min": @1, @"max": @0, @"step": @1},     // min >= max: skipped, the others stay
        @{@"key": @"DM_GAME_LEVEL", @"label": @"Level again", @"type": @"toggle", @"default": @"0"}]};                                    // a duplicate key: skipped
}

int main(void) { @autoreleasepool {
    NSArray *builtin = [DmSettings builtinSections];

    // 1. the built-in registry is well formed: every entry parses, keys are unique, defaults are valid
    { NSMutableDictionary *env = [NSMutableDictionary dictionary]; DmSettings *s = make(builtin, tmpFile(), env, @{});
      NSMutableSet *seen = [NSMutableSet set]; NSUInteger n = 0;
      for (DmSection *sec in s.sections) for (DmSetting *st in sec.settings) { CHECK(![seen containsObject:st.key], "%s twice", st.key.UTF8String); [seen addObject:st.key]; n++; CHECK([st normalized:st.def] != nil, "default of %s", st.key.UTF8String); CHECK(st.label.length, "label"); }
      NSUInteger want = 0; for (NSDictionary *d in builtin) want += [d[@"settings"] count];
      CHECK(n == want, "%lu of %lu entries parsed", (unsigned long)n, (unsigned long)want);
      for (NSString *k in @[@"DM_LETTERBOX", @"DM_AMBIENT_LEVEL", @"DM_CONTROLS_LAYOUT", @"DM_CONTROLS_SCALE", @"DM_CONTROLS_OPACITY", @"DM_SHOW_FPS"]) CHECK([seen containsObject:k], "missing %s", k.UTF8String);
      EQ([s valueForKey:@"DM_LETTERBOX"], @"ambient"); EQ([s valueForKey:@"DM_CONTROLS_SCALE"], @"1"); EQ([s valueForKey:@"DM_SHOW_FPS"], @"0"); EQ([s valueForKey:@"DM_AMBIENT_LEVEL"], @"0.5"); }

    // 2. precedence: environment > user > plist > default
    { NSMutableDictionary *env = [NSMutableDictionary dictionary]; NSString *path = tmpFile();
      DmSettings *s = make(builtin, path, env, @{@"DMLetterbox": @"black", @"DMShowFPS": @"YES"});
      EQ([s valueForKey:@"DM_LETTERBOX"], @"black"); CHECK([s sourceForKey:@"DM_LETTERBOX"] == DmSourcePlist, "plist source");
      CHECK([s boolForKey:@"DM_SHOW_FPS"], "plist YES is on");
      CHECK([s sourceForKey:@"DM_CONTROLS_SCALE"] == DmSourceDefault, "default source");
      CHECK([s setValue:@"ambient" forKey:@"DM_LETTERBOX"], "user value accepted");
      EQ([s valueForKey:@"DM_LETTERBOX"], @"ambient"); CHECK([s sourceForKey:@"DM_LETTERBOX"] == DmSourceUser, "user beats plist");
      EQ(env[@"DM_LETTERBOX"], @"ambient");   // exported, the graphics layer reads it
      // a second launch with env.txt setting it: the environment beats the user's choice, and the screen cannot change it
      NSMutableDictionary *env2 = [@{@"DM_LETTERBOX": @"black"} mutableCopy];
      DmSettings *s2 = make(builtin, path, env2, @{});
      EQ([s2 valueForKey:@"DM_LETTERBOX"], @"black"); CHECK([s2 sourceForKey:@"DM_LETTERBOX"] == DmSourceEnv, "env source");
      CHECK(![s2 setValue:@"ambient" forKey:@"DM_LETTERBOX"], "locked by the environment"); EQ([s2 valueForKey:@"DM_LETTERBOX"], @"black");
      EQ(env2[@"DM_LETTERBOX"], @"black");
      [s2 applyToEnvironment]; EQ(env2[@"DM_LETTERBOX"], @"black");   // never overwrites the override
      // an invalid environment value is not an override
      NSMutableDictionary *env3 = [@{@"DM_CONTROLS_SCALE": @"huge"} mutableCopy]; DmSettings *s3 = make(builtin, path, env3, @{});
      CHECK([s3 sourceForKey:@"DM_CONTROLS_SCALE"] != DmSourceEnv, "invalid env ignored"); EQ([s3 valueForKey:@"DM_CONTROLS_SCALE"], @"1");
      // applyToEnvironment exports user and plist values, not defaults
      NSMutableDictionary *env4 = [NSMutableDictionary dictionary]; DmSettings *s4 = make(builtin, path, env4, @{@"DMControlsLayout": @"overlay"}); [s4 applyToEnvironment];
      EQ(env4[@"DM_LETTERBOX"], @"ambient"); EQ(env4[@"DM_CONTROLS_LAYOUT"], @"overlay"); CHECK(env4[@"DM_CONTROLS_SCALE"] == nil, "defaults are not exported"); }

    // 3. persistence: a new instance reads the file; bad entries are dropped; the file is plain JSON of the user's choices only
    { NSMutableDictionary *env = [NSMutableDictionary dictionary]; NSString *path = tmpFile();
      DmSettings *s = make(builtin, path, env, @{}); [s setValue:@"1.25" forKey:@"DM_CONTROLS_SCALE"]; [s setValue:@"on" forKey:@"DM_SHOW_FPS"];
      NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil];
      EQ(j[@"values"][@"DM_CONTROLS_SCALE"], @"1.25"); EQ(j[@"values"][@"DM_SHOW_FPS"], @"1"); CHECK([j[@"values"] count] == 2, "only the user's choices");
      DmSettings *again = make(builtin, path, [NSMutableDictionary dictionary], @{}); EQ([again valueForKey:@"DM_CONTROLS_SCALE"], @"1.25"); CHECK([again boolForKey:@"DM_SHOW_FPS"], "toggle persisted");
      [@"{\"version\":1,\"values\":{\"DM_CONTROLS_SCALE\":\"abc\",\"DM_LETTERBOX\":\"black\",\"DM_UNKNOWN\":\"1\"}}" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
      DmSettings *bad = make(builtin, path, [NSMutableDictionary dictionary], @{}); EQ([bad valueForKey:@"DM_CONTROLS_SCALE"], @"1"); EQ([bad valueForKey:@"DM_LETTERBOX"], @"black");
      [@"not json" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
      DmSettings *junk = make(builtin, path, [NSMutableDictionary dictionary], @{}); EQ([junk valueForKey:@"DM_LETTERBOX"], @"ambient"); }

    // 4. normalization: toggles, choices with aliases, sliders clamped and snapped, plist numbers
    { DmSettings *s = make(builtin, tmpFile(), [NSMutableDictionary dictionary], @{}); DmSetting *lb = nil, *sc = nil, *fps = nil;
      for (DmSection *sec in s.sections) for (DmSetting *st in sec.settings) { if ([st.key isEqualToString:@"DM_LETTERBOX"]) lb = st; if ([st.key isEqualToString:@"DM_CONTROLS_SCALE"]) sc = st; if ([st.key isEqualToString:@"DM_SHOW_FPS"]) fps = st; }
      EQ([lb normalized:@"BLACK"], @"black"); EQ([lb normalized:@"0"], @"black"); EQ([lb normalized:@"nope"], nil);
      EQ([sc normalized:@"9"], @"2.5"); EQ([sc normalized:@"0.1"], @"0.75"); EQ([sc normalized:@"1.02"], @"1"); EQ([sc normalized:@"1.03"], @"1.05"); EQ([sc normalized:@"1x"], nil); EQ([sc normalized:@""], nil);
      EQ([fps normalized:@"YES"], @"1"); EQ([fps normalized:@"Off"], @"0"); EQ([fps normalized:@(YES)], @"1"); EQ([fps normalized:@"2"], nil);
      EQ([sc displayValue:@"1.25"], @"125%"); EQ([fps displayValue:@"1"], @"On"); EQ([lb displayValue:@"black"], @"Black");
      CHECK(![s setValue:@"x" forKey:@"DM_CONTROLS_SCALE"], "unparsable value refused"); CHECK(![s setValue:@"1" forKey:@"DM_NOT_A_SETTING"], "unknown key refused"); }

    // 5. a game section is one entry per setting: it appears, resolves to its default, tracks restart-required changes; broken and duplicate entries are skipped without losing the rest
    { NSMutableArray *secs = [builtin mutableCopy]; [secs addObject:gameSection()]; NSMutableDictionary *env = [NSMutableDictionary dictionary]; NSString *path = tmpFile();
      DmSettings *s = make(secs, path, env, @{}); DmSection *g = s.sections.lastObject;
      EQ(g.title, @"Some Game"); CHECK(g.settings.count == 2, "%lu entries kept", (unsigned long)g.settings.count);
      EQ([s valueForKey:@"DM_GAME_LEVEL"], @"b"); CHECK(![s boolForKey:@"DM_GAME_FAST"], "fast off");
      CHECK(![s restartPending], "nothing pending at launch");
      [s setValue:@"1" forKey:@"DM_GAME_FAST"]; CHECK([s restartPending], "restart-only setting changed"); EQ(env[@"DM_GAME_FAST"], @"1");
      [s setValue:@"0" forKey:@"DM_GAME_FAST"]; CHECK(![s restartPending], "back to the launch value");
      [s setValue:@"1" forKey:@"DM_GAME_FAST"]; [s setValue:@"a" forKey:@"DM_GAME_LEVEL"]; CHECK([s restartPending], "pending again");   // a live setting does not clear it
      DmSettings *next = make(secs, path, [NSMutableDictionary dictionary], @{}); CHECK(![next restartPending], "a new launch starts from the stored values"); CHECK([next boolForKey:@"DM_GAME_FAST"], "restart value applied at launch"); }

    // 6. the game file loader: valid sections come back, a missing or invalid file is an empty list
    { NSString *path = tmpFile(); NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"sections": @[gameSection()]} options:0 error:nil]; [d writeToFile:path atomically:YES];
      CHECK([DmSettings gameSectionsFromFile:path].count == 1, "game file loaded");
      CHECK([DmSettings gameSectionsFromFile:@"/nonexistent/settings.json"].count == 0, "missing file"); CHECK([DmSettings gameSectionsFromFile:nil].count == 0, "no path");
      [@"[1,2]" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; CHECK([DmSettings gameSectionsFromFile:path].count == 0, "invalid file"); }

    // 7. resetSection drops the user's choices, announces each key, leaves other sections and locked keys alone
    { NSMutableDictionary *env = [@{@"DM_CONTROLS_LAYOUT": @"overlay"} mutableCopy]; DmSettings *s = make(builtin, tmpFile(), env, @{});
      [s setValue:@"1.4" forKey:@"DM_CONTROLS_SCALE"]; [s setValue:@"0.5" forKey:@"DM_CONTROLS_OPACITY"]; [s setValue:@"1" forKey:@"DM_SHOW_FPS"];
      NSMutableArray *got = [NSMutableArray array]; id tok = [NSNotificationCenter.defaultCenter addObserverForName:DmSettingDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) { [got addObject:n.object]; }];
      DmSection *controls = s.sections[1]; EQ(controls.ident, @"controls"); [s resetSection:controls];
      EQ([s valueForKey:@"DM_CONTROLS_SCALE"], @"1"); EQ([s valueForKey:@"DM_CONTROLS_OPACITY"], @"1"); CHECK([s boolForKey:@"DM_SHOW_FPS"], "performance section untouched");
      CHECK([got containsObject:@"DM_CONTROLS_SCALE"] && [got containsObject:@"DM_CONTROLS_OPACITY"], "announced"); CHECK(![got containsObject:@"DM_CONTROLS_LAYOUT"], "locked key not announced");
      EQ([s valueForKey:@"DM_CONTROLS_LAYOUT"], @"overlay"); [NSNotificationCenter.defaultCenter removeObserver:tok]; }

    // 8. the user-facing registry: the entries exist, parse, and show readable values (a slider's decimals follow its step and scale)
    { DmSettings *s = make(builtin, tmpFile(), [NSMutableDictionary dictionary], @{});
      for (NSString *k in @[@"DM_SHAKE_G", @"DM_LANG", @"DM_NICK", @"DM_VOLUME", @"DM_FPS_TARGET", @"DM_RENDER_SCALE", @"DM_VIBRATION", @"DM_VIBRATION_STRENGTH"]) CHECK(find(s, k) != nil, "missing %s", k.UTF8String);
      DmSetting *g = find(s, @"DM_SHAKE_G"); CHECK(g.type == DmSettingSlider && !g.restart, "shake threshold is a live slider");
      EQ([s valueForKey:@"DM_SHAKE_G"], @"1.5"); EQ([g displayValue:@"1.5"], @"1.5 G"); EQ([g displayValue:@"0.5"], @"0.5 G");
      EQ([g normalized:@"9"], @"4"); EQ([g normalized:@"0.04"], @"0.5"); EQ([g normalized:@"1.54"], @"1.5"); EQ([g normalized:@"1.56"], @"1.6");
      DmSetting *v = find(s, @"DM_VOLUME"); EQ([s valueForKey:@"DM_VOLUME"], @"1"); EQ([v displayValue:@"0.35"], @"35%"); EQ([v normalized:@"7"], @"1"); EQ([v normalized:@"-1"], @"0"); CHECK(!v.restart, "volume is live");
      DmSetting *l = find(s, @"DM_LANG"); CHECK(l.restart && l.type == DmSettingChoice, "language is a restart choice"); EQ([s valueForKey:@"DM_LANG"], @"en-US"); EQ([l normalized:@"EN-GB"], @"en-GB"); EQ([l normalized:@"klingon"], nil);
      DmSetting *vib = find(s, @"DM_VIBRATION"), *vs = find(s, @"DM_VIBRATION_STRENGTH");
      CHECK(vib.type == DmSettingToggle && !vib.restart && [s boolForKey:@"DM_VIBRATION"], "vibration is a live toggle, on by default"); EQ(vib.requires, @"haptics"); EQ(vs.requires, @"haptics");
      CHECK(vs.type == DmSettingSlider && !vs.restart, "strength is a live slider"); EQ([s valueForKey:@"DM_VIBRATION_STRENGTH"], @"1"); EQ([vs displayValue:@"0.6"], @"60%"); EQ([vs normalized:@"3"], @"1"); EQ([vs normalized:@"-3"], @"0");
      DmSetting *sc = find(s, @"DM_CONTROLS_SCALE"); EQ([sc displayValue:@"1.25"], @"125%");   // unchanged
      DmSetting *r = find(s, @"DM_RENDER_SCALE"); EQ([r displayValue:@"0.85"], @"85%"); EQ([r normalized:@"0.2"], @"0.5");
      DmSetting *f = find(s, @"DM_FPS_TARGET"); CHECK(f.restart, "frame cap restarts"); EQ(f.requires, @"fpscap"); EQ([f normalized:@"30"], @"30"); EQ([f normalized:@"45"], nil); EQ([f displayValue:@"0"], @"Game decides"); }

    // 9. text settings: trimmed, case kept, control characters refused, capped in characters and in bytes (the host copies 32 bytes), exported and locked like the others
    { DmSettings *s = make(builtin, tmpFile(), [NSMutableDictionary dictionary], @{}); DmSetting *n = find(s, @"DM_NICK");
      CHECK(n.type == DmSettingText && n.restart, "player name is a restart text"); EQ([s valueForKey:@"DM_NICK"], @"Player");
      EQ([n normalized:@"  Ash Ketchum  "], @"Ash Ketchum"); EQ([n normalized:@""], nil); EQ([n normalized:@"   "], nil); EQ([n normalized:@"a\nb"], nil); EQ([n normalized:@"a\tb"], nil);
      NSString *long40 = [@"" stringByPaddingToLength:40 withString:@"x" startingAtIndex:0]; EQ([n normalized:long40], [long40 substringToIndex:32]);
      NSString *emoji = [@"" stringByPaddingToLength:80 withString:@"\U0001F600" startingAtIndex:0];   // 4 bytes, 2 UTF-16 units each
      NSString *cut = [n normalized:emoji]; CHECK(cut.length > 0 && strlen(cut.UTF8String) <= 32, "capped to 32 bytes, got %zu", strlen(cut.UTF8String));
      CHECK([cut isEqualToString:[@"" stringByPaddingToLength:cut.length withString:@"\U0001F600" startingAtIndex:0]], "no broken character");
      CHECK([n textFits:@""] && [n textFits:@"Ash "] && [n textFits:[long40 substringToIndex:32]] && ![n textFits:[long40 substringToIndex:33]], "the editor accepts up to the limit and refuses past it");
      CHECK([n textFits:[@"" stringByPaddingToLength:16 withString:@"\U0001F600" startingAtIndex:0]], "8 emoji are 32 bytes");   // 16 UTF-16 units
      CHECK(![n textFits:[@"" stringByPaddingToLength:18 withString:@"\U0001F600" startingAtIndex:0]], "9 emoji are 36 bytes");
      EQ([n normalized:@"Zoë"], @"Zoë"); EQ([n displayValue:@"Ash"], @"Ash");
      NSMutableDictionary *env = [NSMutableDictionary dictionary]; NSString *path = tmpFile(); DmSettings *s2 = make(builtin, path, env, @{});
      CHECK([s2 setValue:@"Misty" forKey:@"DM_NICK"], "set"); EQ(env[@"DM_NICK"], @"Misty"); CHECK(![s2 setValue:@"" forKey:@"DM_NICK"], "empty refused"); EQ([s2 valueForKey:@"DM_NICK"], @"Misty");
      DmSettings *s3 = make(builtin, path, [NSMutableDictionary dictionary], @{}); EQ([s3 valueForKey:@"DM_NICK"], @"Misty");
      DmSettings *s4 = make(builtin, path, [@{@"DM_NICK": @"Dev"} mutableCopy], @{}); EQ([s4 valueForKey:@"DM_NICK"], @"Dev"); CHECK(![s4 setValue:@"x" forKey:@"DM_NICK"], "locked");
      [s2 resetAll]; EQ([s2 valueForKey:@"DM_NICK"], @"Player"); }

    // 10. per-game defaults sit between the Info.plist and the registry default: user > plist > game default > registry default; invalid ones are ignored; reset goes back to the game default
    { NSMutableDictionary *env = [NSMutableDictionary dictionary]; NSString *path = tmpFile();
      NSDictionary *gd = @{@"DM_CONTROLS_SCALE": @"1.5", @"DM_CONTROLS_OPACITY": @"zz", @"DM_NOT_A_SETTING": @"1", @"DM_LANG": @"fr"};
      DmSettings *s = makeEx(builtin, gd, nil, path, env, @{@"DMControlsScale": @"1.1"});
      EQ([s valueForKey:@"DM_CONTROLS_SCALE"], @"1.1"); CHECK([s sourceForKey:@"DM_CONTROLS_SCALE"] == DmSourcePlist, "plist beats the game default");
      EQ([s valueForKey:@"DM_LANG"], @"fr"); CHECK([s sourceForKey:@"DM_LANG"] == DmSourceDefault, "a game default is a default");
      EQ([s valueForKey:@"DM_CONTROLS_OPACITY"], @"1"); EQ([s valueForKey:@"DM_SHAKE_G"], @"1.5");
      [s applyToEnvironment]; EQ(env[@"DM_LANG"], @"fr"); CHECK(env[@"DM_SHAKE_G"] == nil, "a registry default is not exported, a game default is");
      [s setValue:@"en-GB" forKey:@"DM_LANG"]; EQ([s valueForKey:@"DM_LANG"], @"en-GB"); CHECK([s sourceForKey:@"DM_LANG"] == DmSourceUser, "user beats it");
      DmSection *sys = nil; for (DmSection *sec in s.sections) for (DmSetting *st in sec.settings) if ([st.key isEqualToString:@"DM_LANG"]) sys = sec;
      [s resetSection:sys]; EQ([s valueForKey:@"DM_LANG"], @"fr"); EQ(env[@"DM_LANG"], @"fr");
      NSString *gpath = tmpFile(); [[NSJSONSerialization dataWithJSONObject:@{@"defaults": @{@"DM_LANG": @"de"}, @"sections": @[]} options:0 error:nil] writeToFile:gpath atomically:YES];
      EQ([DmSettings gameDefaultsFromFile:gpath][@"DM_LANG"], @"de"); CHECK([DmSettings gameDefaultsFromFile:@"/nonexistent"].count == 0, "missing file"); CHECK([DmSettings gameDefaultsFromFile:nil].count == 0, "no path");
      [@"{\"defaults\": [1]}" writeToFile:gpath atomically:YES encoding:NSUTF8StringEncoding error:nil]; CHECK([DmSettings gameDefaultsFromFile:gpath].count == 0, "malformed defaults"); }

    // 11. a game section with the id of a built-in one merges into it; a second page appears only for a new id
    { NSDictionary *extra = @{@"id": @"controls", @"title": @"Ignored", @"settings": @[@{@"key": @"DM_GAME_RUMBLE", @"label": @"Game rumble", @"detail": @"d", @"type": @"toggle", @"default": @"1"},
                                                                                 @{@"key": @"DM_CONTROLS_SCALE", @"label": @"Again", @"type": @"toggle", @"default": @"0"}]};
      NSMutableArray *secs = [builtin mutableCopy]; [secs addObject:extra]; DmSettings *s = make(secs, tmpFile(), [NSMutableDictionary dictionary], @{});
      CHECK(s.sections.count == builtin.count, "no new page"); DmSection *c = s.sections[1]; EQ(c.title, @"Controls"); CHECK([c.settings.lastObject.key isEqualToString:@"DM_GAME_RUMBLE"], "merged at the end");
      CHECK(find(s, @"DM_CONTROLS_SCALE").type == DmSettingSlider, "a duplicate key keeps the first"); }

    // 12. resetAll drops every choice of every page, announces each changed key once, and leaves locked keys alone
    { NSMutableDictionary *env = [@{@"DM_CONTROLS_LAYOUT": @"overlay"} mutableCopy]; DmSettings *s = make(builtin, tmpFile(), env, @{});
      [s setValue:@"1.4" forKey:@"DM_CONTROLS_SCALE"]; [s setValue:@"1" forKey:@"DM_SHOW_FPS"]; [s setValue:@"2.5" forKey:@"DM_SHAKE_G"]; [s setValue:@"Zed" forKey:@"DM_NICK"]; [s setValue:@"black" forKey:@"DM_LETTERBOX"];
      NSMutableArray *got = [NSMutableArray array]; id tok = [NSNotificationCenter.defaultCenter addObserverForName:DmSettingDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) { [got addObject:n.object]; }];
      [s resetAll];
      EQ([s valueForKey:@"DM_CONTROLS_SCALE"], @"1"); CHECK(![s boolForKey:@"DM_SHOW_FPS"], "fps off"); EQ([s valueForKey:@"DM_SHAKE_G"], @"1.5"); EQ([s valueForKey:@"DM_NICK"], @"Player"); EQ([s valueForKey:@"DM_LETTERBOX"], @"ambient");
      CHECK(got.count == 5, "%lu announced", (unsigned long)got.count); CHECK(![got containsObject:@"DM_CONTROLS_LAYOUT"], "locked key not announced");
      EQ([s valueForKey:@"DM_CONTROLS_LAYOUT"], @"overlay");
      [s resetAll]; CHECK(got.count == 5, "a second reset announces nothing"); [NSNotificationCenter.defaultCenter removeObserver:tok]; }

    // 13. capabilities: a setting with `requires` is shown only when the build has it; a page left empty disappears; no provider = everything shown
    { NSMutableDictionary *env = [NSMutableDictionary dictionary]; NSMutableSet *have = [NSMutableSet set];
      DmSettings *s = makeEx(builtin, nil, ^BOOL(NSString *c) { return [have containsObject:c]; }, tmpFile(), env, @{});
      DmSetting *f = find(s, @"DM_FPS_TARGET"), *r = find(s, @"DM_RENDER_SCALE");
      CHECK(![s isAvailable:f] && ![s isAvailable:r], "hidden without the capability"); CHECK([s isAvailable:find(s, @"DM_SHAKE_G")], "an unconditional setting is always shown");
      DmSection *perf = nil; for (DmSection *sec in s.visibleSections) if ([sec.ident isEqualToString:@"performance"]) perf = sec; CHECK(perf != nil, "the page still has the fps counter");
      for (DmSetting *st in [s visibleSettingsInSection:perf]) CHECK(![st.key isEqualToString:@"DM_FPS_TARGET"], "frame cap hidden");
      [have addObject:@"fstep"]; CHECK([s isAvailable:r] && ![s isAvailable:f], "the render scale needs the stubs, the frame cap needs a cap of any kind");
      [have addObject:@"fpscap"]; CHECK([s isAvailable:f] && [s isAvailable:r], "shown with them"); CHECK([[s visibleSettingsInSection:perf] containsObject:f], "listed");
      [have removeObject:@"fstep"]; CHECK([s isAvailable:f] && ![s isAvailable:r], "an engine frame limit alone gives the cap but not the render scale");
      DmSetting *vib = find(s, @"DM_VIBRATION"); CHECK(![s isAvailable:vib], "vibration hidden without haptic hardware"); [have addObject:@"haptics"]; CHECK([s isAvailable:vib] && [s isAvailable:find(s, @"DM_VIBRATION_STRENGTH")], "shown with it");
      DmSettings *all = make(builtin, tmpFile(), [NSMutableDictionary dictionary], @{}); CHECK([all isAvailable:find(all, @"DM_FPS_TARGET")], "no provider: shown");
      NSDictionary *only = @{@"id": @"x", @"title": @"X", @"settings": @[@{@"key": @"DM_ONLY", @"label": @"Only", @"type": @"toggle", @"default": @"0", @"requires": @"nothing"}]};
      DmSettings *e = makeEx(@[only], nil, ^BOOL(NSString *c) { (void)c; return NO; }, tmpFile(), [NSMutableDictionary dictionary], @{}); CHECK(e.sections.count == 1 && e.visibleSections.count == 0, "an empty page is not listed");
      DmSettings *h = makeEx(builtin, nil, ^BOOL(NSString *c) { (void)c; return NO; }, tmpFile(), env, @{}); CHECK([h setValue:@"30" forKey:@"DM_FPS_TARGET"], "stored anyway"); EQ([h valueForKey:@"DM_FPS_TARGET"], @"30"); }

    // 14. the registry's own consistency: every `requires` names a known capability, every entry has a label and a detail, every slider default is inside its range
    { DmSettings *s = make(builtin, tmpFile(), [NSMutableDictionary dictionary], @{}); NSSet *known = [NSSet setWithObjects:@"fstep", @"fpscap", @"haptics", nil];
      for (DmSection *sec in s.sections) for (DmSetting *st in sec.settings) {
          if (st.requires) CHECK([known containsObject:st.requires], "%s requires unknown %s", st.key.UTF8String, st.requires.UTF8String);
          CHECK([st.label length] && [st.detail length], "%s needs a label and a detail", st.key.UTF8String);
          if (st.type == DmSettingSlider) { double d = st.def.doubleValue; CHECK(d >= st.min && d <= st.max, "%s default in range", st.key.UTF8String); } } }

    // 12. the text editor's counter, limit note and paste clipping (the panel only draws them), and the footer hints that follow the focused row
    { DmSettings *s = make(builtin, tmpFile(), [NSMutableDictionary dictionary], @{}); DmSetting *n = find(s, @"DM_NICK");
      NSString *(^xs)(NSUInteger) = ^NSString *(NSUInteger k) { return [@"" stringByPaddingToLength:k withString:@"x" startingAtIndex:0]; };
      NSString *(^em)(NSUInteger) = ^NSString *(NSUInteger k) { return [@"" stringByPaddingToLength:k * 2 withString:@"\U0001F600" startingAtIndex:0]; };   // k emoji, 4 bytes each
      CHECK([n textCount:@""] == 0 && [n textCount:@"Ash"] == 3 && [n textCount:em(3)] == 3 && [n textCount:@"é"] == 1, "the counter counts characters, not UTF-16 units");
      EQ([n textLimitNote:@""], nil); EQ([n textLimitNote:xs(31)], nil); EQ([n textLimitNote:xs(32)], @"Limit reached");
      EQ([n textLimitNote:[em(7) stringByAppendingString:@"abc"]], nil); EQ([n textLimitNote:[em(7) stringByAppendingString:@"abcd"]], @"Limit reached (32 bytes)"); EQ([n textLimitNote:em(8)], @"Limit reached (32 bytes)");
      EQ([n clippedReplacement:@"abcdef" inText:xs(30) range:NSMakeRange(30, 0)], @"ab"); EQ([n clippedReplacement:@"y" inText:xs(32) range:NSMakeRange(32, 0)], @"");
      EQ([n clippedReplacement:xs(40) inText:xs(32) range:NSMakeRange(0, 32)], xs(32)); EQ([n clippedReplacement:@"" inText:xs(32) range:NSMakeRange(5, 3)], @"");
      EQ([n clippedReplacement:@"\U0001F600" inText:xs(30) range:NSMakeRange(30, 0)], @""); EQ([n clippedReplacement:em(2) inText:xs(28) range:NSMakeRange(28, 0)], @"\U0001F600");   // never half a character
      EQ([n clippedReplacement:@"Z" inText:@"Ash" range:NSMakeRange(1, 1)], @"Z");
      NSString *(^names)(NSArray *) = ^NSString *(NSArray *h) { NSMutableArray *a = [NSMutableArray array]; for (NSArray *p in h) [a addObject:[NSString stringWithFormat:@"%@ %@", p[0], p[1]]]; return [a componentsJoinedByString:@" | "]; };
      EQ(names(dm_hints_for_focus(DmFocusCategory, NO, NO)), @"A Open | B Close | L R Category");
      EQ(names(dm_hints_for_focus(DmFocusToggle, NO, NO)), @"↔ Change | A Toggle | B Back | L R Category");
      EQ(names(dm_hints_for_focus(DmFocusChoice, NO, NO)), @"↔ Change | A Next | B Back | L R Category");
      EQ(names(dm_hints_for_focus(DmFocusSlider, NO, NO)), @"↔ Change | B Back | L R Category");   // A does nothing on a slider
      EQ(names(dm_hints_for_focus(DmFocusText, NO, NO)), @"A Edit | B Back | L R Category");       // left / right does nothing on a text row
      EQ(names(dm_hints_for_focus(DmFocusRestore, NO, NO)), @"A Restore | B Back | L R Category");
      EQ(names(dm_hints_for_focus(DmFocusRestoreAll, NO, NO)), @"A Restore | B Back | L R Category"); EQ(names(dm_hints_for_focus(DmFocusRestoreAll, NO, YES)), @"A Confirm | B Back | L R Category");
      EQ(names(dm_hints_for_focus(DmFocusRestart, NO, NO)), @"A Restart | B Back | L R Category");
      CHECK(dm_hints_for_focus(DmFocusEditor, NO, NO).count == 0 && dm_hints_for_focus(DmFocusEditor, YES, YES).count == 0, "the editor has its own Cancel and Save buttons: the footer says nothing (the screen hides it, the soft keyboard would cover it)");
      for (int k = DmFocusCategory; k <= DmFocusRestart; k++) CHECK(dm_hints_for_focus((DmFocusKind)k, NO, NO).count > 0, "a focus outside the editor always has a hint");
      for (int k = DmFocusCategory; k <= DmFocusRestart; k++) for (NSArray *p in dm_hints_for_focus((DmFocusKind)k, NO, YES)) CHECK(p.count == 2 && [p[0] length] && [p[1] length], "a hint is a glyph and a text");
      for (int k = DmFocusToggle; k <= DmFocusText; k++) EQ(names(dm_hints_for_focus((DmFocusKind)k, YES, NO)), @"B Back | L R Category");   // a row the environment locks changes nothing
    }

    // 13. a value equal to the default is not stored: the user's choice goes back to "default", for every type, so a later change of the default still applies
    { NSString *path = tmpFile(); NSMutableDictionary *env = [NSMutableDictionary dictionary]; DmSettings *s = make(builtin, path, env, @{});
      NSDictionary *(^stored)(void) = ^NSDictionary *{ NSData *d = [NSData dataWithContentsOfFile:path]; return d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil][@"values"] : @{}; };
      NSMutableArray *got = [NSMutableArray array]; id tok = [NSNotificationCenter.defaultCenter addObserverForName:DmSettingDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) { [got addObject:n.object]; }];
      // toggle (the reported case), choice, slider, text
      CHECK([s setValue:@"1" forKey:@"DM_SHOW_FPS"], "on"); EQ(stored()[@"DM_SHOW_FPS"], @"1"); CHECK([s sourceForKey:@"DM_SHOW_FPS"] == DmSourceUser, "chosen");
      CHECK([s setValue:@"0" forKey:@"DM_SHOW_FPS"], "off again"); CHECK(stored()[@"DM_SHOW_FPS"] == nil, "the default is not written, got %s", [[stored() description] UTF8String]); CHECK([s sourceForKey:@"DM_SHOW_FPS"] == DmSourceDefault, "back to default"); CHECK(![s boolForKey:@"DM_SHOW_FPS"], "value is the default");
      CHECK([s setValue:@"0" forKey:@"DM_SHOW_FPS"], "setting the default while on the default is fine"); CHECK(stored().count == 0, "still nothing stored"); EQ(env[@"DM_SHOW_FPS"], @"0");
      [s setValue:@"black" forKey:@"DM_LETTERBOX"]; EQ(stored()[@"DM_LETTERBOX"], @"black"); [s setValue:@"ambient" forKey:@"DM_LETTERBOX"]; CHECK(stored()[@"DM_LETTERBOX"] == nil, "choice default not written"); [s setValue:@"0" forKey:@"DM_LETTERBOX"]; EQ([s valueForKey:@"DM_LETTERBOX"], @"black");   // an alias of a non-default option is stored as the option
      [s setValue:@"ambient" forKey:@"DM_LETTERBOX"];
      [s setValue:@"1.4" forKey:@"DM_CONTROLS_SCALE"]; EQ(stored()[@"DM_CONTROLS_SCALE"], @"1.4"); [s setValue:@"1.0" forKey:@"DM_CONTROLS_SCALE"]; CHECK(stored()[@"DM_CONTROLS_SCALE"] == nil, "slider default not written"); EQ([s valueForKey:@"DM_CONTROLS_SCALE"], @"1");
      [s setValue:@"2.5" forKey:@"DM_SHAKE_G"]; [s setValue:@"1.52" forKey:@"DM_SHAKE_G"]; CHECK(stored()[@"DM_SHAKE_G"] == nil, "a slider value that snaps to the default is the default (1.52 -> 1.5)");
      [s setValue:@"Zed" forKey:@"DM_NICK"]; EQ(stored()[@"DM_NICK"], @"Zed"); [s setValue:@"  Player " forKey:@"DM_NICK"]; CHECK(stored()[@"DM_NICK"] == nil, "text default not written (trimmed)"); EQ([s valueForKey:@"DM_NICK"], @"Player");
      CHECK(stored().count == 0, "nothing of the above is left in the file");
      CHECK([got containsObject:@"DM_SHOW_FPS"] && [got containsObject:@"DM_NICK"], "dropping the choice is announced"); NSUInteger n0 = got.count; [s setValue:@"Player" forKey:@"DM_NICK"]; CHECK(got.count == n0, "setting the default while on it announces nothing");
      [NSNotificationCenter.defaultCenter removeObserver:tok];
      // the default that counts is the one in force: the Info.plist's, then the game's
      NSString *p2 = tmpFile(); DmSettings *pl = make(builtin, p2, [NSMutableDictionary dictionary], @{@"DMShowFPS": @YES});
      EQ([pl defaultValueForKey:@"DM_SHOW_FPS"], @"1"); CHECK([pl setValue:@"1" forKey:@"DM_SHOW_FPS"], "ok"); CHECK([pl sourceForKey:@"DM_SHOW_FPS"] == DmSourcePlist, "the plist default, not a stored copy");
      [pl setValue:@"0" forKey:@"DM_SHOW_FPS"]; CHECK([pl sourceForKey:@"DM_SHOW_FPS"] == DmSourceUser && ![pl boolForKey:@"DM_SHOW_FPS"], "off against a plist default is a choice");
      [pl setValue:@"1" forKey:@"DM_SHOW_FPS"]; CHECK([pl sourceForKey:@"DM_SHOW_FPS"] == DmSourcePlist, "and on again drops it");
      DmSettings *gd = makeEx(builtin, @{@"DM_LANG": @"fr", @"DM_SHAKE_G": @"2"}, nil, tmpFile(), [NSMutableDictionary dictionary], @{});
      [gd setValue:@"en-US" forKey:@"DM_LANG"]; EQ([gd valueForKey:@"DM_LANG"], @"en-US"); CHECK([gd sourceForKey:@"DM_LANG"] == DmSourceUser, "the registry default is not the default of this game: stored");
      [gd setValue:@"fr" forKey:@"DM_LANG"]; CHECK([gd sourceForKey:@"DM_LANG"] == DmSourceDefault, "the game's default is the default: dropped"); [gd setValue:@"2" forKey:@"DM_SHAKE_G"]; CHECK([gd sourceForKey:@"DM_SHAKE_G"] == DmSourceDefault, "slider with a game default");
      CHECK([gd restartPending] == NO, "a restart setting set back to its launch value is not pending");
      // the environment still locks
      NSMutableDictionary *e2 = [@{@"DM_SHOW_FPS": @"1"} mutableCopy]; DmSettings *lk = make(builtin, tmpFile(), e2, @{}); CHECK(![lk setValue:@"0" forKey:@"DM_SHOW_FPS"], "locked: the default is refused too"); CHECK(![lk setValue:@"1" forKey:@"DM_SHOW_FPS"], "locked");
      // what was stored survives a launch, and only choices are in the file
      DmSettings *w = make(builtin, path, [NSMutableDictionary dictionary], @{}); [w setValue:@"1" forKey:@"DM_SHOW_FPS"]; [w setValue:@"Zed" forKey:@"DM_NICK"]; [w setValue:@"1" forKey:@"DM_SHOW_FPS"]; EQ(stored()[@"DM_SHOW_FPS"], @"1"); [w setValue:@"0" forKey:@"DM_SHOW_FPS"];
      DmSettings *again = make(builtin, path, [NSMutableDictionary dictionary], @{}); CHECK(![again boolForKey:@"DM_SHOW_FPS"] && [again sourceForKey:@"DM_SHOW_FPS"] == DmSourceDefault, "after a relaunch it is still the default"); EQ([again valueForKey:@"DM_NICK"], @"Zed"); CHECK(stored().count == 1, "only the nickname is a choice"); }

    // 14. a setting that has no effect under another's value is disabled (`enabledWhen`): a registry field, evaluated on the effective value
    { NSMutableDictionary *env = [NSMutableDictionary dictionary]; DmSettings *s = make(builtin, tmpFile(), env, @{}); DmSetting *amb = find(s, @"DM_AMBIENT_LEVEL"), *lb = find(s, @"DM_LETTERBOX");
      EQ(amb.enabledWhenKey, @"DM_LETTERBOX"); EQ(amb.enabledNotEquals, @"black"); EQ(amb.enabledEquals, nil); CHECK(lb.enabledWhenKey == nil, "most entries have no condition");
      CHECK([s isEnabled:amb] && [s disabledNote:amb] == nil, "ambient bars: brightness is live");
      [s setValue:@"black" forKey:@"DM_LETTERBOX"]; CHECK(![s isEnabled:amb], "black bars: brightness does nothing"); EQ([s disabledNote:amb], @"Has no effect while Bars around the picture is Black");
      CHECK([s isEnabled:lb] && [s isEnabled:find(s, @"DM_SHOW_FPS")], "the others are untouched");
      CHECK([s setValue:@"0.8" forKey:@"DM_AMBIENT_LEVEL"], "the store itself still takes the value (the screen refuses to edit a disabled row)"); [s setValue:@"ambient" forKey:@"DM_LETTERBOX"]; CHECK([s isEnabled:amb], "ambient again"); EQ([s valueForKey:@"DM_AMBIENT_LEVEL"], @"0.8");   // what the user set while it was disabled is kept
      DmSettings *vp = make(builtin, tmpFile(), [NSMutableDictionary dictionary], @{@"DMLetterbox": @"black"}); CHECK(![vp isEnabled:find(vp, @"DM_AMBIENT_LEVEL")], "the Info.plist's black bars count");
      DmSettings *ev = make(builtin, tmpFile(), [@{@"DM_LETTERBOX": @"black"} mutableCopy], @{}); CHECK(![ev isEnabled:find(ev, @"DM_AMBIENT_LEVEL")], "so does the environment");
      DmSettings *al = make(builtin, tmpFile(), [@{@"DM_LETTERBOX": @"0"} mutableCopy], @{}); CHECK(![al isEnabled:find(al, @"DM_AMBIENT_LEVEL")], "an alias of the option counts as the option");
      DmSetting *vib = find(s, @"DM_VIBRATION"), *vs = find(s, @"DM_VIBRATION_STRENGTH");
      EQ(vs.enabledWhenKey, @"DM_VIBRATION"); EQ(vs.enabledEquals, @"1"); EQ(vs.enabledNotEquals, nil); CHECK(vib.enabledWhenKey == nil, "the toggle itself is always live");
      CHECK([s isEnabled:vs] && [s disabledNote:vs] == nil, "vibration on (default): strength is live");
      [s setValue:@"0" forKey:@"DM_VIBRATION"]; CHECK(![s isEnabled:vs], "vibration off: strength does nothing"); EQ([s disabledNote:vs], @"Has no effect unless Vibration is On"); CHECK([s isEnabled:vib], "the toggle stays live");
      [s setValue:@"0.4" forKey:@"DM_VIBRATION_STRENGTH"]; [s setValue:@"1" forKey:@"DM_VIBRATION"]; CHECK([s isEnabled:vs], "vibration on again"); EQ([s valueForKey:@"DM_VIBRATION_STRENGTH"], @"0.4");
      DmSettings *ve = make(builtin, tmpFile(), [@{@"DM_VIBRATION": @"off"} mutableCopy], @{}); CHECK(![ve isEnabled:find(ve, @"DM_VIBRATION_STRENGTH")], "vibration turned off in env.txt disables it too");
      // equals form, a game's own entry, and the ways an entry can be wrong
      NSDictionary *game = @{@"id": @"game", @"title": @"G", @"settings": @[
          @{@"key": @"DM_G_ON", @"label": @"On", @"type": @"toggle", @"default": @"1"},
          @{@"key": @"DM_G_LVL", @"label": @"Level", @"type": @"slider", @"min": @0, @"max": @1, @"step": @0.1, @"default": @"0.5", @"enabledWhen": @{@"key": @"DM_G_ON", @"equals": @"1"}},
          @{@"key": @"DM_G_BAD1", @"label": @"B1", @"type": @"toggle", @"default": @"0", @"enabledWhen": @{@"key": @"DM_G_ON"}},
          @{@"key": @"DM_G_BAD2", @"label": @"B2", @"type": @"toggle", @"default": @"0", @"enabledWhen": @{@"key": @"DM_G_ON", @"equals": @"1", @"notEquals": @"0"}},
          @{@"key": @"DM_G_BAD3", @"label": @"B3", @"type": @"toggle", @"default": @"0", @"enabledWhen": @{@"key": @"DM_G_BAD3", @"equals": @"1"}},
          @{@"key": @"DM_G_BAD4", @"label": @"B4", @"type": @"toggle", @"default": @"0", @"enabledWhen": @"DM_G_ON"},
          @{@"key": @"DM_G_ORPHAN", @"label": @"Orphan", @"type": @"toggle", @"default": @"0", @"enabledWhen": @{@"key": @"DM_NOT_THERE", @"equals": @"1"}},
          @{@"key": @"DM_G_JUNK", @"label": @"Junk", @"type": @"toggle", @"default": @"0", @"enabledWhen": @{@"key": @"DM_G_ON", @"equals": @"maybe"}}]};
      DmSettings *g = make(@[game], tmpFile(), [NSMutableDictionary dictionary], @{}); DmSetting *lv = find(g, @"DM_G_LVL");
      CHECK(lv != nil && find(g, @"DM_G_ON") != nil, "valid entries kept"); for (NSString *k in @[@"DM_G_BAD1", @"DM_G_BAD2", @"DM_G_BAD3", @"DM_G_BAD4"]) CHECK(find(g, k) == nil, "%s skipped", k.UTF8String);
      CHECK([g isEnabled:lv], "on"); [g setValue:@"0" forKey:@"DM_G_ON"]; CHECK(![g isEnabled:lv], "equals: off disables"); EQ([g disabledNote:lv], @"Has no effect unless On is On"); [g setValue:@"1" forKey:@"DM_G_ON"]; CHECK([g isEnabled:lv], "on again");
      CHECK([g isEnabled:find(g, @"DM_G_ORPHAN")], "a condition on a setting that is not registered never disables"); CHECK([g isEnabled:find(g, @"DM_G_JUNK")] && [g disabledNote:find(g, @"DM_G_JUNK")] == nil, "a condition value that does not parse never disables");
      // the built-in registry's conditions refer to real settings, with values those settings accept, and never to themselves or in a cycle of two
      for (DmSection *sec in s.sections) for (DmSetting *st in sec.settings) if (st.enabledWhenKey) {
          DmSetting *dep = find(s, st.enabledWhenKey); CHECK(dep != nil && dep != st, "%s depends on a registered other setting", st.key.UTF8String);
          CHECK([dep normalized:st.enabledEquals ?: st.enabledNotEquals] != nil, "%s: the condition value parses for %s", st.key.UTF8String, dep.key.UTF8String);
          CHECK(dep.enabledWhenKey == nil, "%s: no chain of conditions", st.key.UTF8String); } }

    // 15. the toggle / slider track is at least 3:1 against the row and the pane in both styles (WCAG non-text contrast), computed from the colour values the screen uses
    { CHECK(fabs(dm_contrast(0xFFFFFF, 0x000000) - 21) < 1e-9 && fabs(dm_contrast(0x777777, 0xFFFFFF) - 4.48) < 0.01, "the formula matches the WCAG reference values");
      double lr = dm_contrast(DM_TRACK_LIGHT, DM_ROW_LIGHT), lp = dm_contrast(DM_TRACK_LIGHT, DM_PANEL_LIGHT), dr = dm_contrast(DM_TRACK_DARK, DM_ROW_DARK), dp = dm_contrast(DM_TRACK_DARK, DM_PANEL_DARK);
      printf("track contrast: light row %.2f pane %.2f, dark row %.2f pane %.2f\n", lr, lp, dr, dp);
      CHECK(lr >= 3 && lp >= 3 && dr >= 3 && dp >= 3, "track %.2f %.2f %.2f %.2f", lr, lp, dr, dp);
      uint32_t seen = (uint32_t)lround(0.9 * 0xA6) * 0x010101; CHECK(dm_contrast(seen, DM_ROW_DARK) >= 3, "still 3:1 when a device renders the colour 10%% darker (measured on the old one)");
      CHECK(dm_contrast(0x8C8C8C, DM_ROW_DARK) < 3 && dm_contrast(0x8E8E8E, DM_ROW_LIGHT) < 3, "the old track colours were under 3:1"); }

    printf("t_settings: %d checks, %d failed\n", g_n, g_fail);
    return g_fail ? 1 : 0;
} }
