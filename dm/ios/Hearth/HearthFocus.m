// Home's focus model (HearthFocus.h)
#import "HearthFocus.h"

@implementation HearthFocus {
    NSInteger _n, *_count, *_pos;   // per zone: the number of items and the remembered place
    BOOL _placed;                    // the player (a move or a focus) put the focus where it is; NO while it only sits where the item counts left it
}
- (instancetype)initWithZones:(NSInteger)zones {
    if (!(self = [super init])) return nil;
    _n = MAX(zones, 1); _count = calloc((size_t)_n, sizeof *_count); _pos = calloc((size_t)_n, sizeof *_pos); _ringVisible = YES;
    return self;
}
- (void)dealloc { free(_count); free(_pos); }
- (NSInteger)index { return _count[_zone] ? _pos[_zone] : -1; }
- (NSInteger)indexInZone:(NSInteger)z { return z >= 0 && z < _n ? _pos[z] : 0; }
- (void)setCount:(NSInteger)c forZone:(NSInteger)z {
    if (z < 0 || z >= _n) return;
    _count[z] = MAX(c, 0); _pos[z] = MIN(_pos[z], MAX(_count[z] - 1, 0));
    if (!_count[_zone] || !_placed) for (NSInteger i = 0; i < _n; i++) if (_count[i]) { _zone = i; break; }   // the focused zone emptied, or nobody chose it: the first one with items
}
- (BOOL)move:(HearthDir)d {
    if (d == HearthDirNone) return NO;
    if (!_ringVisible) { _ringVisible = YES; return NO; }
    if (d == HearthDirLeft || d == HearthDirRight) {
        NSInteger p = _pos[_zone] + (d == HearthDirRight ? 1 : -1);
        if (p < 0 || p >= _count[_zone]) return NO;
        _pos[_zone] = p; _placed = YES; return YES;
    }
    for (NSInteger z = _zone + (d == HearthDirDown ? 1 : -1); z >= 0 && z < _n; z += d == HearthDirDown ? 1 : -1)
        if (_count[z]) { _zone = z; _placed = YES; return YES; }
    return NO;
}
- (void)focusZone:(NSInteger)z index:(NSInteger)i {
    if (z < 0 || z >= _n || i < 0 || i >= _count[z]) return;
    _zone = z; _pos[z] = i; _placed = YES;
}
- (void)touched { _ringVisible = NO; }
- (void)showRing { _ringVisible = YES; }
@end
