// In-app settings: a data-driven registry (key, label, type, range or options, default, live / restart) and the store behind the settings screen (DmSettingsVC.m).
// Foundation only, so the registry and the precedence order run in a plain Mac test (dm/ios/tests/t_settings.m).
// Precedence, highest first: the environment (Documents/env.txt, which main.m turns into environment variables, or a real one: the developer's override, shown locked in the screen),
// then the user's choice (Documents/settings.json, not the save folder), then the Info.plist default (the key named by the entry's plistKey), then the entry's own default.
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DmSettingType) { DmSettingToggle, DmSettingChoice, DmSettingSlider };
typedef NS_ENUM(NSInteger, DmSettingSource) { DmSourceDefault, DmSourcePlist, DmSourceUser, DmSourceEnv };

extern NSNotificationName const DmSettingDidChangeNotification;   // object: the key; userInfo @"value": the new effective value

@interface DmSetting : NSObject
@property (nonatomic, readonly) NSString *key;        // the environment variable the rest of the app reads (DM_LETTERBOX)
@property (nonatomic, readonly) NSString *plistKey;   // Info.plist default, or nil
@property (nonatomic, readonly) NSString *label, *detail;
@property (nonatomic, readonly) DmSettingType type;
@property (nonatomic, readonly) NSArray<NSDictionary *> *options;   // choice: {value, label}
@property (nonatomic, readonly) double min, max, step, scale;       // slider range; scale multiplies the value for display (0.5 shown as 50 with scale 100)
@property (nonatomic, readonly) NSString *suffix;                   // slider: shown after the number ("%", "x")
@property (nonatomic, readonly) NSString *def;                      // default value as a string
@property (nonatomic, readonly) BOOL restart;                       // applies on the next launch (the screen offers a restart), else live
+ (instancetype)settingFromDictionary:(NSDictionary *)d error:(NSString **)err;
- (NSString *)normalized:(id)raw;      // a raw value (env, plist, file) as this setting stores it: toggles "0" / "1", choices one of the options, sliders clamped to the range and the step; nil when it does not parse
- (NSString *)displayValue:(NSString *)value;  // what the row shows: "Ambient", "On", "75%"
@end

@interface DmSection : NSObject
@property (nonatomic, readonly) NSString *ident, *title, *icon;     // icon: an SF Symbol name
@property (nonatomic, readonly) NSArray<DmSetting *> *settings;
@end

@interface DmSettings : NSObject
+ (instancetype)shared;   // the app's store: Documents/settings.json, the process environment, the main bundle's Info.plist and dm/settings.json (per-game entries)
- (instancetype)initWithSections:(NSArray<NSDictionary *> *)sections storePath:(NSString *)path env:(NSString *(^)(NSString *key))env setEnv:(void (^)(NSString *key, NSString *value))setEnv plist:(id (^)(NSString *plistKey))plist;
@property (nonatomic, readonly) NSArray<DmSection *> *sections;
- (NSString *)valueForKey:(NSString *)key;                // the effective value, normalized
- (BOOL)boolForKey:(NSString *)key;
- (double)doubleForKey:(NSString *)key;
- (DmSettingSource)sourceForKey:(NSString *)key;
- (BOOL)setValue:(NSString *)value forKey:(NSString *)key;   // live: stores, exports to the environment, posts the notification; NO when locked by the environment or the value does not parse
- (void)resetSection:(DmSection *)s;                       // drops the user's choices of the section
- (BOOL)restartPending;                                    // a restart-only setting differs from what this launch started with
- (void)applyToEnvironment;                                // exports user and plist values for the keys the environment does not set (the graphics layer reads DM_LETTERBOX itself)
+ (NSArray<NSDictionary *> *)builtinSections;
+ (NSArray<NSDictionary *> *)gameSectionsFromFile:(NSString *)path;   // dm/settings.json of the game profile: {"sections": [...]} in the same form; empty when absent or invalid (logged)
@end

void dm_settings_boot(void);   // main.m, after env.txt is in the environment and before UIApplicationMain: loads the user's file and exports it
