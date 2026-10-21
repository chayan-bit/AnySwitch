// Registry and precedence of the in-app settings (dm/ios/Sources/DmSettings.m): environment > user file > Info.plist > default, locking, persistence, restart tracking, per-game sections.
// Foundation only, runs on the Mac: make -C dm/ios/tests run
#import <Foundation/Foundation.h>
#import "DmSettings.h"

static int g_fail, g_n;
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_fail++; printf("FAIL line %d: %s  ", __LINE__, #c); printf(__VA_ARGS__); printf("\n"); } } while (0)
#define EQ(a, b) do { NSString *_a = (a), *_b = (b); g_n++; if (!((_a == nil && _b == nil) || [_a isEqualToString:_b])) { g_fail++; printf("FAIL line %d: %s = %s, wanted %s\n", __LINE__, #a, _a.UTF8String ?: "(nil)", _b.UTF8String ?: "(nil)"); } } while (0)

static NSString *tmpFile(void) { return [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_settings_%@.json", NSUUID.UUID.UUIDString]]; }

// A store over fake environment and plist dictionaries (the real ones are the process environment and the Info.plist)
static DmSettings *make(NSArray *sections, NSString *path, NSMutableDictionary *env, NSDictionary *plist) {
    return [[DmSettings alloc] initWithSections:sections storePath:path env:^NSString *(NSString *k) { return env[k]; }
        setEnv:^(NSString *k, NSString *v) { if (v) env[k] = v; else [env removeObjectForKey:k]; } plist:^id(NSString *k) { return plist[k]; }];
}

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

    printf("t_settings: %d checks, %d failed\n", g_n, g_fail);
    return g_fail ? 1 : 0;
} }
