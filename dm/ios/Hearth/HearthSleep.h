// Sleep (plan-hearth-p2.md 4.7): an app cannot put the iPad to sleep, so Sleep covers the screen in black, lets iPadOS lock after its own auto-lock time (the idle timer is allowed again),
// and any touch, key or controller button wakes it. The game is already paused under Home when Sleep is chosen; woke decides where the player lands (the game, or Home)
#import <Foundation/Foundation.h>

void hearth_sleep(void (^woke)(void));
BOOL hearth_asleep(void);
