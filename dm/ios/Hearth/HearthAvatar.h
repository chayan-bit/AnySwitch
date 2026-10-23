// Users' pictures and the two pickers built on them (plan-hearth-p3.md 3.3): "Who is playing?" before a game that needs a user, and the avatar chooser (art or a photo).
// A picture is Documents/Users/<uid>/avatar.jpg, 256x256, what the host's LoadProfileImage serves; art (a symbol on a colour) is rendered into it.
#import <UIKit/UIKit.h>
#import "HearthUsers.h"

HearthUsers *hearth_users(void);   // the app's users, loaded once (the first start names the first user after the old Player name setting)
UIImage *hearth_avatar_image(HearthUser *u);   // avatar.jpg, else the art drawn now
void hearth_avatar_ensure(void);   // every user without avatar.jpg gets one drawn from their art (before a boot: the host reads the files)
// "Who is playing?": the users as picture tiles and Cancel; focus starts on `preferred`. done gets nil for Cancel
void hearth_pick_user(UIViewController *over, NSString *title, HearthUser *preferred, void (^done)(HearthUser *u));
// The avatar chooser: the art choices and "Photo" (the photo library, centre-cropped to a square). done says whether the picture changed
void hearth_choose_avatar(UIViewController *over, HearthUser *u, void (^done)(BOOL changed));
