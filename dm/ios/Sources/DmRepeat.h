// A held direction repeats (the settings screen and Hearth's Home share it): the caller takes the first step itself, the next comes after DM_REPEAT_FIRST seconds,
// then each step returns the delay to the one after it. Main thread, NSTimer based; Foundation only (dm/ios/tests/t_home_focus.m)
#import <Foundation/Foundation.h>

#define DM_REPEAT_FIRST 0.4   // seconds before a held direction starts repeating
#define DM_REPEAT_NEXT  0.15  // seconds between repeats (the settings screen's sliders go faster)

@interface DmRepeat : NSObject
@property (nonatomic, readonly) NSInteger held;   // what is held (a direction), 0 = nothing
- (void)hold:(NSInteger)what step:(NSTimeInterval (^)(void))step;   // what != 0; replaces anything held before. step nil: held, but nothing repeats (a key already down when a screen opens)
- (void)stop;
@end
