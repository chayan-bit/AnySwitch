// The pieces of Hearth's Home screen (HearthHomeVC.m): a game tile, a round system button, the top bar with the player, the clock and the battery
#import <UIKit/UIKit.h>
#import "HearthLibrary.h"

NSString *hearth_state_line(HearthGame *g);   // the short line a tile shows when its game cannot start ("Rebuild needed", "Needs signing"), nil when it can

@interface HearthTile : UIControl
- (instancetype)initWithGame:(HearthGame *)g;
@property (nonatomic, readonly) HearthGame *game;
@property (nonatomic, readonly) UIView *art;   // the rounded icon (the launch zoom starts from it)
@property (nonatomic) BOOL chosen;              // Home's focus is on it: grows a little and shows the game's name above it (not UIKit's own `focused`)
- (void)setChosen:(BOOL)chosen animated:(BOOL)animated;
@property (nonatomic) BOOL playing;             // the game paused under Home: its state line says Playing
@end

@interface HearthRoundButton : UIControl
- (instancetype)initWithSymbol:(NSString *)symbol label:(NSString *)label;
@end

@interface HearthTopBar : UIView
- (void)setPlayer:(NSString *)name;
@end
