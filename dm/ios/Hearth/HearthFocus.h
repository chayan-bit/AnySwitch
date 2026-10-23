// Home's focus (notes: plan-hearth-p2.md 4.2), our own model as in the settings screen: zones in a column (the tile row, the button row), up and down switch zones,
// left and right move inside one, and each zone remembers its place. A touch hides the ring; the next key or controller direction only brings it back.
// Foundation only, so dm/ios/tests/t_home_focus.m runs it on the Mac.
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, HearthDir) { HearthDirNone = 0, HearthDirUp, HearthDirDown, HearthDirLeft, HearthDirRight };

@interface HearthFocus : NSObject
- (instancetype)initWithZones:(NSInteger)zones;
- (void)setCount:(NSInteger)n forZone:(NSInteger)zone;   // the items of a zone (0 = up and down skip it); positions are clamped to the new count
@property (nonatomic, readonly) NSInteger zone, index;   // where the focus is; index -1 when every zone is empty
- (NSInteger)indexInZone:(NSInteger)zone;                // the remembered place of a zone
- (BOOL)move:(HearthDir)d;                               // YES when the focus moved; with the ring hidden it only shows the ring
- (void)focusZone:(NSInteger)zone index:(NSInteger)i;    // a touch chose this item; the ring stays as it is
@property (nonatomic, readonly) BOOL ringVisible;
- (void)touched;                                         // a touch: the ring hides
- (void)showRing;                                        // a key or controller button other than a direction (A on a hidden ring acts on the focused item and shows it)
@end
