// Held-direction repeat (DmRepeat.h)
#import "DmRepeat.h"

@implementation DmRepeat {
    NSTimer *_timer; NSUInteger _gen;   // _gen: a timer of an earlier hold does nothing
}
- (void)dealloc { [_timer invalidate]; }
- (void)stop { [_timer invalidate]; _timer = nil; _held = 0; _gen++; }
- (void)hold:(NSInteger)what step:(NSTimeInterval (^)(void))step {
    [self stop]; _held = what;
    if (step) [self schedule:DM_REPEAT_FIRST gen:_gen step:step];
}
- (void)schedule:(NSTimeInterval)after gen:(NSUInteger)gen step:(NSTimeInterval (^)(void))step {
    __weak DmRepeat *w = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:after repeats:NO block:^(NSTimer *t) {
        (void)t; DmRepeat *s = w; if (!s || s->_gen != gen) return;
        NSTimeInterval next = step();
        if (s->_gen == gen) [s schedule:next gen:gen step:step];   // the step may have stopped the repeat
    }];
}
@end
