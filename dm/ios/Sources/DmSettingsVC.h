// The settings screen: a category list on the left, the chosen category's rows on the right, an amber focus ring with a breathing glow, button hints at the bottom (see DmSettingsVC.m).
// Controller: D-pad or left stick moves, A selects / changes, B goes back (closes from the category list), L / R (and ZL / ZR) switch category. Touch: tap, drag a slider. Hardware keyboard: arrows, return, escape, [ and ].
#import <UIKit/UIKit.h>
#import "DmSettings.h"

// A row of a page that is not a registry section (Hearth's Data Management, About, a game's Options): information, or an action, which may ask for a second press first
@interface DmPageItem : NSObject
+ (instancetype)info:(NSString *)title detail:(NSString *)detail;
+ (instancetype)action:(NSString *)title detail:(NSString *)detail run:(void (^)(void))run;
+ (instancetype)unavailable:(NSString *)title detail:(NSString *)reason;   // an action that cannot be done now: the row is dimmed like a setting with no effect, its detail says why
@property (nonatomic, copy) NSString *title, *detail;
@property (nonatomic, copy) void (^run)(void);       // nil: information only
@property (nonatomic) BOOL destructive, unavailable;
@property (nonatomic, copy) NSString *confirmTitle;  // set: the first press shows this title, the second runs the action
@end
// A category of the screen: a registry section (its rows), or a page of items built each time it is shown
@interface DmPage : NSObject
+ (instancetype)section:(DmSection *)section;
+ (instancetype)page:(NSString *)title icon:(NSString *)symbol items:(NSArray<DmPageItem *> *(^)(void))items;
+ (NSArray<DmPage *> *)pagesOf:(DmSettings *)settings gameRowsOnly:(BOOL)gameOnly;   // the store's visible sections; gameOnly keeps only rows of scope game or both (a game's Options)
@property (nonatomic, readonly) DmSection *section;
@property (nonatomic, readonly) NSString *title, *icon;
@property (nonatomic, readonly) BOOL gameRowsOnly;
@property (nonatomic, readonly, copy) NSArray<DmPageItem *> *(^items)(void);
@end

@interface DmSettingsVC : UIViewController
- (instancetype)initWithSettings:(DmSettings *)settings size:(CGSize)size;   // size: the screen the view will fill; a short side under 500 pt (a phone in landscape) gets the compact sizes
@property (nonatomic, copy) void (^onClose)(void);     // the screen asks to be closed (B on the category list, the close button, escape)
@property (nonatomic, copy) void (^onRestart)(void);   // the restart row was chosen; the default exits the process
@property (nonatomic, readonly) NSInteger section;
@property (nonatomic, copy) NSArray<DmPage *> *pages;   // set before the view loads; nil: every visible section of the store
@property (nonatomic, copy) NSString *heading;          // the big title, "Settings" when nil
@property (nonatomic, copy) void (^onChange)(void);     // after the player changed a value (a quiet store announces nothing)
- (void)resumeController;   // a screen over this one handed the controller back: what is held now does nothing until it is released
- (void)reloadPages;   // the categories again (a page appeared or went), keeping the place when it can
// The text editor panel for a page's own value (a user's name): save gets the trimmed text and returns whether it was taken
- (void)editText:(NSString *)title value:(NSString *)value maxBytes:(NSUInteger)maxBytes save:(BOOL (^)(NSString *text))save;
// The physical controller's state (DmPadBits.h buttons, left stick) as handed over by dm_gamepad_set_capture; the first call only records what is already held
- (void)padState:(uint64_t)buttons lx:(int32_t)lx ly:(int32_t)ly;
// Jump to a state (tests and screenshots): the category, whether the focus is in the pane, and the row there
- (void)selectSection:(NSInteger)section focusPane:(BOOL)pane row:(NSInteger)row;
@end
