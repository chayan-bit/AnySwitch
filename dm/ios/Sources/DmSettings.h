// In-app settings: a data-driven registry (key, label, type, range or options, default, live / restart) and the store behind the settings screen (DmSettingsVC.m).
// Foundation only, so the registry and the precedence order run in a plain Mac test (dm/ios/tests/t_settings.m).
// Precedence, highest first: the environment (Documents/env.txt, which main.m turns into environment variables, or a real one: the developer's override, shown locked in the screen),
// then the user's choice (Documents/settings.json, not the save folder), then the Info.plist default (the key named by the entry's plistKey),
// then the game's own default (the "defaults" of dm/settings.json), then the entry's own default.
// An entry with `requires` is shown only when the build has that capability (DmSettings.capabilities, set by the app from what the loaded game provides).
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DmSettingType) { DmSettingToggle, DmSettingChoice, DmSettingSlider, DmSettingText };
typedef NS_ENUM(NSInteger, DmSettingSource) { DmSourceDefault, DmSourcePlist, DmSourceUser, DmSourceEnv };

extern NSNotificationName const DmSettingDidChangeNotification;   // object: the key; userInfo @"value": the new effective value

@interface DmSetting : NSObject
@property (nonatomic, readonly) NSString *key;        // the environment variable the rest of the app reads (DM_LETTERBOX)
@property (nonatomic, readonly) NSString *plistKey;   // Info.plist default, or nil
@property (nonatomic, readonly) NSString *label, *detail;
@property (nonatomic, readonly) DmSettingType type;
@property (nonatomic, readonly) NSArray<NSDictionary *> *options;   // choice: {value, label}
@property (nonatomic, readonly) double min, max, step, scale;       // slider range; scale multiplies the value for display (0.5 shown as 50 with scale 100)
@property (nonatomic, readonly) NSString *suffix;                   // slider: shown after the number ("%", " G")
@property (nonatomic, readonly) NSInteger decimals;                 // slider: decimals shown (derived from step x scale unless the entry says "decimals")
@property (nonatomic, readonly) NSUInteger maxLength, maxBytes;     // text: at most this many characters (composed sequences) and, when maxBytes is not 0, UTF-8 bytes
@property (nonatomic, readonly) NSString *requires;                 // capability the build must have for the row to be shown ("fstep": the frame-step stubs), or nil
@property (nonatomic, readonly) NSString *def;                      // registry default as a string
@property (nonatomic, readonly) BOOL restart;                       // applies on the next launch (the screen offers a restart), else live
+ (instancetype)settingFromDictionary:(NSDictionary *)d error:(NSString **)err;
- (NSString *)normalized:(id)raw;      // a raw value (env, plist, file) as this setting stores it: toggles "0" / "1", choices one of the options, sliders clamped to the range and the step, text trimmed and cut to its limits; nil when it does not parse
- (BOOL)textFits:(NSString *)text;      // text: within the length and byte limits (the editor refuses typing past them)
- (NSUInteger)textCount:(NSString *)text;   // text: the number of characters (composed sequences) the editor's counter shows
- (NSString *)textLimitNote:(NSString *)text;   // text: nil while another character would still fit, else "Limit reached" (with the byte limit named when that is what stops the typing)
- (NSString *)clippedReplacement:(NSString *)replacement inText:(NSString *)text range:(NSRange)range;   // text: the part of the replacement (cut at a whole character) that still fits when it replaces range in text; a paste past the limit keeps what fits
- (NSString *)displayValue:(NSString *)value;  // what the row shows: "Ambient", "On", "75%", "1.5 G"
@end

// Where the focus is on the settings screen: what the footer's button hints say follows from it
typedef NS_ENUM(NSInteger, DmFocusKind) { DmFocusCategory, DmFocusToggle, DmFocusChoice, DmFocusSlider, DmFocusText, DmFocusRestore, DmFocusRestoreAll, DmFocusRestart };
// The footer hints {glyph, text} for a focus: only the buttons that do something there (a slider has no A, a locked row has neither A nor left / right, a restore-all that waits for its second press says Confirm)
NSArray<NSArray<NSString *> *> *dm_hints_for_focus(DmFocusKind kind, BOOL locked, BOOL armed);

@interface DmSection : NSObject
@property (nonatomic, readonly) NSString *ident, *title, *icon;     // icon: an SF Symbol name
@property (nonatomic, readonly) NSArray<DmSetting *> *settings;
@end

@interface DmSettings : NSObject
+ (instancetype)shared;   // the app's store: Documents/settings.json, the process environment, the main bundle's Info.plist and dm/settings.json (per-game entries and defaults)
- (instancetype)initWithSections:(NSArray<NSDictionary *> *)sections storePath:(NSString *)path env:(NSString *(^)(NSString *key))env setEnv:(void (^)(NSString *key, NSString *value))setEnv plist:(id (^)(NSString *plistKey))plist;
// gameDefaults: {key: value} replacing the registry default for this game; caps: whether the build has a capability (nil: every row is shown)
- (instancetype)initWithSections:(NSArray<NSDictionary *> *)sections gameDefaults:(NSDictionary<NSString *, id> *)gameDefaults caps:(BOOL (^)(NSString *capability))caps storePath:(NSString *)path env:(NSString *(^)(NSString *key))env setEnv:(void (^)(NSString *key, NSString *value))setEnv plist:(id (^)(NSString *plistKey))plist;
@property (nonatomic, copy) BOOL (^capabilities)(NSString *capability);   // the app sets it once it can tell what the game provides; read each time the screen is built
@property (nonatomic, readonly) NSArray<DmSection *> *sections;           // every page of the registry; sections with the same id are merged (a game's entries join the built-in page)
@property (nonatomic, readonly) NSArray<DmSection *> *visibleSections;    // the pages with at least one available entry
- (DmSetting *)settingForKey:(NSString *)key;
- (BOOL)isAvailable:(DmSetting *)s;                                       // the build has what the entry requires
- (NSArray<DmSetting *> *)visibleSettingsInSection:(DmSection *)s;
- (NSString *)valueForKey:(NSString *)key;                // the effective value, normalized
- (BOOL)boolForKey:(NSString *)key;
- (double)doubleForKey:(NSString *)key;
- (DmSettingSource)sourceForKey:(NSString *)key;
- (BOOL)setValue:(NSString *)value forKey:(NSString *)key;   // live: stores, exports to the environment, posts the notification; NO when locked by the environment or the value does not parse
- (void)resetSection:(DmSection *)s;                       // drops the user's choices of the section
- (void)resetAll;                                          // drops every choice of every section; each changed key is announced once, keys the environment sets are left alone
- (BOOL)restartPending;                                    // a restart-only setting differs from what this launch started with
- (void)applyToEnvironment;                                // exports user, plist and game-default values for the keys the environment does not set (code that reads DM_* itself sees the effective value)
+ (NSArray<NSDictionary *> *)builtinSections;
+ (NSArray<NSDictionary *> *)gameSectionsFromFile:(NSString *)path;       // dm/settings.json of the game profile: {"sections": [...]} in the same form; empty when absent or invalid (logged)
+ (NSDictionary<NSString *, id> *)gameDefaultsFromFile:(NSString *)path;   // the same file's {"defaults": {"DM_KEY": "value"}}; empty when absent or invalid (logged)
@end

void dm_settings_boot(void);   // main.m, after env.txt is in the environment and before UIApplicationMain: loads the user's file and exports it
