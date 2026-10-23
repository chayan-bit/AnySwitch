// The pieces of Hearth's Home screen (HearthHomeVC.m): a game tile, a round system button, the top bar with the player, the clock and the battery
#import <UIKit/UIKit.h>
#import "HearthLibrary.h"
#import "HearthTheme.h"

NSString *hearth_state_line(HearthGame *g);   // the short line a tile shows when its game cannot start ("Rebuild needed", "Needs signing"), nil when it can

@interface HearthTile : UIControl
- (instancetype)initWithGame:(HearthGame *)g metrics:(HearthMetrics)m;   // m.tile: the art's edge; m.nameH and m.stateH: room above the art for the focused game's name and below it for the state line
@property (nonatomic, readonly) HearthGame *game;
@property (nonatomic, readonly) CGFloat size;
@property (nonatomic, readonly) UIView *art;   // the rounded icon (the launch zoom starts from it)
@property (nonatomic) BOOL chosen;              // Home's focus is on it: grows a little and shows the game's name above it (not UIKit's own `focused`)
- (void)setChosen:(BOOL)chosen animated:(BOOL)animated;
@property (nonatomic) BOOL playing;             // the game paused under Home: its state line says Playing
@end

@interface HearthRoundButton : UIControl
- (instancetype)initWithSymbol:(NSString *)symbol label:(NSString *)label;
- (void)setMetrics:(HearthMetrics)m;   // the size, the symbol's size and the corner radius of this screen
@end

@interface HearthTopBar : UIView
- (void)setPlayer:(NSString *)name;
- (void)setMetrics:(HearthMetrics)m;   // avatar size and fonts of this screen
@end
