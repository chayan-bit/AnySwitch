// In-app settings: a data-driven registry (key, label, type, range or options, default, live / restart) and the store behind the settings screen (DmSettingsVC.m).
// Foundation only, so the registry and the precedence order run in a plain Mac test (dm/ios/tests/t_settings.m).
// Precedence, highest first: the environment (Documents/env.txt, which main.m turns into environment variables, or a real one: the developer's override, shown locked in the screen),
// then the player's choice for this game (a game store; entries of scope game or both), then the player's system choice (Documents/settings.json, not the save folder), then the Info.plist default (the key named by the entry's plistKey),
// then the game's own default (the "defaults" of the bundled pack's profile/settings.json), then the default the game's frame rate target gives it (`defaultAtFps`), then the entry's own default.
// An entry with `requires` is shown only when the build has that capability (DmSettings.capabilities, set by the app from what the loaded game provides).
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DmSettingType) { DmSettingToggle, DmSettingChoice, DmSettingSlider, DmSettingText };
typedef NS_ENUM(NSInteger, DmSettingSource) { DmSourceDefault, DmSourcePlist, DmSourceUser, DmSourceEnv, DmSourceGame };   // User: the player's system choice; Game: the player's choice for this game
// Where a player's choice lives (`"scope"`, default system; a pack's own entries default to game): system = one value for every game, game = per game only, both = a system value a game may override
typedef NS_ENUM(NSInteger, DmSettingScope) { DmScopeSystem, DmScopeGame, DmScopeBoth };

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
@property (nonatomic, readonly) NSString *enabledWhenKey, *enabledEquals, *enabledNotEquals;   // `enabledWhen`: {"key": "DM_X", "equals": "v"} or {"key": "DM_X", "notEquals": "v"}: the entry has an effect only then, else the screen shows it disabled (nil when it always has one)
@property (nonatomic, readonly) NSString *def;                      // registry default as a string
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *defaultAtFps;   // `defaultAtFps`: {"30": "sharp"}: the default while the game's frame rate target (DmSettings.frameTarget) is that many fps; any other target uses `def`. Live entries only. Nil when the default does not depend on it
@property (nonatomic, readonly) BOOL exportDefault;                 // `exportDefault`: the default is exported to the environment like a player's value, because the code that reads the key has another default of its own (off)
@property (nonatomic, readonly) BOOL restart;                       // applies on the next launch (the screen offers a restart), else live
@property (nonatomic, readonly) DmSettingScope scope;
+ (instancetype)settingFromDictionary:(NSDictionary *)d error:(NSString **)err;
- (NSString *)normalized:(id)raw;      // a raw value (env, plist, file) as this setting stores it: toggles "0" / "1", choices one of the options, sliders clamped to the range and the step, text trimmed and cut to its limits; nil when it does not parse
- (BOOL)textFits:(NSString *)text;      // text: within the length and byte limits (the editor refuses typing past them)
- (NSUInteger)textCount:(NSString *)text;   // text: the number of characters (composed sequences) the editor's counter shows
- (NSString *)textLimitNote:(NSString *)text;   // text: nil while another character would still fit, else "Limit reached" (with the byte limit named when that is what stops the typing)
- (NSString *)clippedReplacement:(NSString *)replacement inText:(NSString *)text range:(NSRange)range;   // text: the part of the replacement (cut at a whole character) that still fits when it replaces range in text; a paste past the limit keeps what fits
- (NSString *)displayValue:(NSString *)value;  // what the row shows: "Ambient", "On", "75%", "1.5 G"
@end

// Where the focus is on the settings screen: what the footer's button hints say follows from it
typedef NS_ENUM(NSInteger, DmFocusKind) { DmFocusCategory, DmFocusToggle, DmFocusChoice, DmFocusSlider, DmFocusText, DmFocusRestore, DmFocusRestoreAll, DmFocusRestart, DmFocusEditor,
    DmFocusHomeGame, DmFocusHomeBlocked, DmFocusHomeButton };   // Hearth's Home: a game tile, a tile that cannot start (A explains why), a system button
// The footer hints {glyph, text} for a focus: only the buttons that do something there (a slider has no A, a locked or disabled row has neither A nor left / right, a restore-all that waits for its second press says Confirm; the text editor has its own Cancel and Save buttons, so the footer shows nothing then)
NSArray<NSArray<NSString *> *> *dm_hints_for_focus(DmFocusKind kind, BOOL locked, BOOL armed);

@interface DmSection : NSObject
@property (nonatomic, readonly) NSString *ident, *title, *icon;     // icon: an SF Symbol name
@property (nonatomic, readonly) NSArray<DmSetting *> *settings;
@end

@interface DmSettings : NSObject
+ (instancetype)shared;   // the running game's store (dm_settings_set_game before the first call), over the process environment and the main bundle's Info.plist; made once per process
+ (instancetype)systemStore;   // the system layer only (no game rows), for Home; it neither exports nor announces (a game's store reads the file when the game starts)
+ (instancetype)storeForGame:(NSString *)titleId packRoot:(NSString *)root;   // a game's store (its pack's profile/settings.json rows and defaults): the shared store for the running game, else one that neither exports nor announces
// Documents/settings.json is {"version": 2, "system": {key: value}, "games": {title id: {key: value}}}; a version 1 file ({"values": ...}) is read as the system layer and written as version 2 on the first change.
// Each change merges into the file on disk key by key, so a system store and a game store over the same file do not undo each other's changes
- (instancetype)initWithSections:(NSArray<NSDictionary *> *)sections storePath:(NSString *)path env:(NSString *(^)(NSString *key))env setEnv:(void (^)(NSString *key, NSString *value))setEnv plist:(id (^)(NSString *plistKey))plist;
// gameDefaults: {key: value} replacing the registry default for this game; caps: whether the build has a capability (nil: every row is shown)
- (instancetype)initWithSections:(NSArray<NSDictionary *> *)sections gameDefaults:(NSDictionary<NSString *, id> *)gameDefaults caps:(BOOL (^)(NSString *capability))caps storePath:(NSString *)path env:(NSString *(^)(NSString *key))env setEnv:(void (^)(NSString *key, NSString *value))setEnv plist:(id (^)(NSString *plistKey))plist;
// gameId: nil = the system store (game-scope rows hidden and refused), else that game's store: changes of game and both entries go to its layer, of system entries to the system layer
- (instancetype)initWithSections:(NSArray<NSDictionary *> *)sections gameDefaults:(NSDictionary<NSString *, id> *)gameDefaults caps:(BOOL (^)(NSString *capability))caps gameId:(NSString *)gameId storePath:(NSString *)path env:(NSString *(^)(NSString *key))env setEnv:(void (^)(NSString *key, NSString *value))setEnv plist:(id (^)(NSString *plistKey))plist;
@property (nonatomic, readonly) NSString *gameId;
@property (nonatomic) int frameTarget;   // the game's frame rate target (30 or 60; 0 = not known), set by the app as the host reports it (it can change while the game runs). Moves the default of every `defaultAtFps` entry, and announces (DmSettingDidChangeNotification) each one whose effective value changes with it
@property (nonatomic, copy) BOOL (^capabilities)(NSString *capability);   // the app sets it once it can tell what the game provides; read each time the screen is built
@property (nonatomic, readonly) NSArray<DmSection *> *sections;           // every page of the registry; sections with the same id are merged (a game's entries join the built-in page)
@property (nonatomic, readonly) NSArray<DmSection *> *visibleSections;    // the pages with at least one available entry
- (DmSetting *)settingForKey:(NSString *)key;
- (BOOL)isEnabled:(DmSetting *)s;                                         // false while the entry's `enabledWhen` condition on another setting's effective value does not hold (it has no effect then: the screen dims it and does not edit it)
- (NSString *)disabledNote:(DmSetting *)s;                                // why it is disabled ("Has no effect while Bars around the picture is Black"), nil when enabled
- (BOOL)isAvailable:(DmSetting *)s;                                       // the build has what the entry requires
- (NSArray<DmSetting *> *)visibleSettingsInSection:(DmSection *)s;
- (NSString *)valueForKey:(NSString *)key;                // the effective value, normalized
- (NSString *)defaultValueForKey:(NSString *)key;         // the value when the user has chosen none and the environment sets none: Info.plist, else the game's default, else the one for the frame rate target, else the registry's
- (BOOL)boolForKey:(NSString *)key;
- (double)doubleForKey:(NSString *)key;
- (DmSettingSource)sourceForKey:(NSString *)key;
- (NSString *)systemValueForKey:(NSString *)key;          // what a game store falls back to without its own choice: the system choice, else the default (the environment aside)
- (BOOL)followsSystem:(DmSetting *)s;                     // a game store's entry of scope both with no choice of this game's own (the row says "System setting")
- (void)useSystemForKey:(NSString *)key;                  // drops this game's own choice of the key
- (BOOL)setValue:(NSString *)value forKey:(NSString *)key;   // into the layer the entry's scope names (NO for a game entry in the system store; a game's value equal to its system value drops the game's choice). Live: stores, exports to the environment, posts the notification; NO when locked by the environment or the value does not parse. A value equal to the default is not stored (the user's choice is dropped), so a later change of the default still applies (a `defaultAtFps` entry keeps every choice: its default moves with the frame rate target)
- (void)resetSection:(DmSection *)s;                       // drops the user's choices of the section, each from the layer this store writes it to (a game store: the game's own choices and the system-only entries)
- (void)resetAll;                                          // drops every choice of every section; each changed key is announced once, keys the environment sets are left alone
- (BOOL)restartPending;                                    // a restart-only setting differs from what this launch started with
- (void)applyToEnvironment;                                // exports user, plist and game-default values for the keys the environment does not set (code that reads DM_* itself sees the effective value)
+ (NSArray<NSDictionary *> *)builtinSections;
+ (NSDictionary<NSString *, NSString *> *)builtinScopes;   // key: "game" or "both" for the built-in entries that are not system-only
+ (NSString *)internalResDetailForMemory:(unsigned long long)bytes;      // the Internal resolution row's detail: with a memory note on devices with 8 GB or less (NSProcessInfo.physicalMemory)
+ (NSArray<NSDictionary *> *)gameSectionsFromFile:(NSString *)path;       // a pack's profile/settings.json: {"sections": [...]} in the same form, entries without a scope get scope game; empty when absent or invalid (logged)
+ (NSDictionary<NSString *, id> *)gameDefaultsFromFile:(NSString *)path;   // the same file's {"defaults": {"DM_KEY": "value"}}; empty when absent or invalid (logged)
@end

void dm_settings_set_game(NSString *titleId, NSString *root);   // before the first +shared: the launched game, whose pack supplies profile/settings.json (game rows and defaults) and whose layer the shared store uses
void dm_settings_boot(void);   // main.m, after env.txt is in the environment and before UIApplicationMain: loads the user's file and exports it
