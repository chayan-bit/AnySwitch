// The Gallery screen (HearthGalleryVC.h). The files and their order come from HearthGallery.m; this file only shows them
#import "HearthGalleryVC.h"
#import "HearthGallery.h"
#import "HearthSound.h"
#import "HearthTheme.h"
#import "DmSettingsViews.h"
#import "DmPadBits.h"
#import "DmRepeat.h"
#import <ImageIO/ImageIO.h>
#import <Photos/Photos.h>

#define GAP 16.0        // between pictures in the grid
#define THUMB_PX 640    // a thumbnail's longer edge in pixels: sharp at the grid's size on a 2x screen

static NSString *documents(void) { return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject; }
// shortcut: thumbnails live in memory only (decoded again on each open, about 10 ms a picture); keep them on disk if a Gallery of hundreds feels slow
static NSCache<NSString *, UIImage *> *thumbs(void) { static NSCache *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = [NSCache new]; c.countLimit = 300; }); return c; }
static UIImage *thumb_of(NSString *path) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL); if (!src) return nil;
    NSDictionary *o = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES, (id)kCGImageSourceThumbnailMaxPixelSize: @THUMB_PX, (id)kCGImageSourceCreateThumbnailWithTransform: @YES};
    CGImageRef im = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)o); CFRelease(src);
    if (!im) return nil;
    UIImage *u = [UIImage imageWithCGImage:im]; CGImageRelease(im); return u;
}
static NSString *when(NSDate *d) { static NSDateFormatter *f; if (!f) { f = [NSDateFormatter new]; f.dateStyle = NSDateFormatterMediumStyle; f.timeStyle = NSDateFormatterShortStyle; } return [f stringFromDate:d]; }

@interface HearthShotCell : UICollectionViewCell
@property (nonatomic, readonly) UIImageView *image;
@property (nonatomic, copy) NSString *path;
@end
@implementation HearthShotCell
- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    _image = [[UIImageView alloc] initWithFrame:self.contentView.bounds]; _image.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _image.contentMode = UIViewContentModeScaleAspectFill; _image.clipsToBounds = YES; _image.layer.cornerRadius = 12; _image.layer.cornerCurve = kCACornerCurveContinuous;
    __weak UIImageView *w = _image; dm_on_style(_image, ^{ w.backgroundColor = DmUI.row; });
    [self.contentView addSubview:_image];
    self.isAccessibilityElement = YES; self.accessibilityTraits = UIAccessibilityTraitButton | UIAccessibilityTraitImage;
    return self;
}
@end

static UIButton *pill(NSString *title, NSString *symbol) {
    UIButtonConfiguration *c = UIButtonConfiguration.filledButtonConfiguration;
    c.title = title; c.image = symbol ? [UIImage systemImageNamed:symbol] : nil; c.imagePadding = 8; c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    c.baseBackgroundColor = DmUI.row; c.baseForegroundColor = DmUI.text;
    c.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) { NSMutableDictionary *m = a.mutableCopy; m[NSFontAttributeName] = [DmUI font:18 weight:UIFontWeightSemibold]; return m; };
    c.contentInsets = NSDirectionalEdgeInsetsMake(10, 18, 10, 18);
    return [UIButton buttonWithConfiguration:c primaryAction:nil];
}

@interface HearthGalleryVC () <UICollectionViewDataSource, UICollectionViewDelegate>
@end

@implementation HearthGalleryVC {
    NSArray<NSDictionary *> *_all, *_shown, *_games; NSInteger _filter, _cell, _cols; BOOL _onChips, _ringShown, _baselined, _closing, _armed; uint64_t _prev; DmRepeat *_repeat;
    UILabel *_head, *_empty; UIButton *_closeButton; UIScrollView *_chipRow; NSArray<UIButton *> *_chips; UICollectionView *_grid; DmFocusView *_chipRing, *_cellRing; DmHintBar *_hints;
    UIView *_viewer, *_card; UIImageView *_big; UILabel *_caption, *_detail; UIButton *_back, *_del, *_share, *_save; DmHintBar *_viewHints; NSInteger _at; NSTimer *_statusTimer;
}

#pragma mark - Build

- (void)viewDidLoad {
    [super viewDidLoad];
    _repeat = [DmRepeat new]; _at = -1;
    __weak HearthGalleryVC *w = self; dm_on_style(self.view, ^{ w.view.backgroundColor = DmUI.bg; });
    _head = [UILabel new]; _head.text = @"Gallery"; _head.font = [DmUI font:34 weight:UIFontWeightBold]; _head.textColor = DmUI.text; _head.accessibilityTraits = UIAccessibilityTraitHeader;
    _closeButton = [UIButton buttonWithType:UIButtonTypeClose]; _closeButton.accessibilityLabel = @"Close Gallery";
    [_closeButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    _chipRow = [UIScrollView new]; _chipRow.showsHorizontalScrollIndicator = NO; _chipRow.clipsToBounds = NO;
    _chipRing = [DmFocusView new]; _chipRing.radius = 28;
    UICollectionViewFlowLayout *l = [UICollectionViewFlowLayout new]; l.minimumInteritemSpacing = GAP; l.minimumLineSpacing = GAP;
    _grid = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:l]; _grid.backgroundColor = UIColor.clearColor; _grid.clipsToBounds = NO;
    _grid.dataSource = self; _grid.delegate = self; [_grid registerClass:HearthShotCell.class forCellWithReuseIdentifier:@"shot"];
    _cellRing = [DmFocusView new]; _cellRing.radius = 18; _cellRing.layer.zPosition = 10; [_grid addSubview:_cellRing];
    _empty = [UILabel new]; _empty.text = @"No screenshots yet.\nDuring a game, the Capture button beside HOME takes one."; _empty.numberOfLines = 0;
    _empty.font = [DmUI font:22 weight:UIFontWeightSemibold]; _empty.textColor = DmUI.sub; _empty.textAlignment = NSTextAlignmentCenter;
    _hints = [DmHintBar new];
    for (UIView *v in @[_head, _closeButton, _chipRow, _grid, _empty, _hints]) [self.view addSubview:v];
    [self buildViewer];
    [self reloadKeeping:nil];
}
- (void)buildViewer {   // dark whatever the system style: a picture reads best on black
    _viewer = [UIView new]; _viewer.backgroundColor = UIColor.blackColor; _viewer.overrideUserInterfaceStyle = UIUserInterfaceStyleDark; _viewer.hidden = YES;
    _big = [UIImageView new]; _big.contentMode = UIViewContentModeScaleAspectFit; _big.userInteractionEnabled = YES; _big.isAccessibilityElement = YES;
    [_big addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleInfo)]];
    for (NSNumber *d in @[@(UISwipeGestureRecognizerDirectionLeft), @(UISwipeGestureRecognizerDirectionRight)]) {
        UISwipeGestureRecognizer *s = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swiped:)]; s.direction = d.unsignedIntegerValue; [_big addGestureRecognizer:s];
    }
    _card = [UIView new]; _card.layer.cornerRadius = 22; _card.layer.cornerCurve = kCACornerCurveContinuous;
    __weak UIView *card = _card; dm_on_style(_card, ^{ card.backgroundColor = DmUI.panel; });
    _caption = [UILabel new]; _caption.font = [DmUI font:20 weight:UIFontWeightSemibold]; _caption.textColor = DmUI.text;
    _detail = [UILabel new]; _detail.font = [DmUI font:16 weight:UIFontWeightMedium]; _detail.textColor = DmUI.sub;
    _back = pill(@"Back", @"chevron.left"); _del = pill(@"Delete", @"trash"); _share = pill(@"Share", @"square.and.arrow.up"); _save = pill(@"Save to Photos", @"photo.badge.arrow.down");
    [_back addTarget:self action:@selector(closeViewer) forControlEvents:UIControlEventTouchUpInside];
    [_del addTarget:self action:@selector(deletePressed) forControlEvents:UIControlEventTouchUpInside];
    [_share addTarget:self action:@selector(share) forControlEvents:UIControlEventTouchUpInside];
    [_save addTarget:self action:@selector(saveToPhotos) forControlEvents:UIControlEventTouchUpInside];
    _viewHints = [DmHintBar new]; [_viewHints setHints:@[@[@"↔", @"Move"], @[@"A", @"Info"], @[@"X", @"Delete"], @[@"Y", @"Share"], @[@"+", @"Save to Photos"], @[@"B", @"Back"]]];
    for (UIView *v in @[_caption, _detail, _del, _share, _save]) [_card addSubview:v];
    for (UIView *v in @[_big, _back, _card, _viewHints]) [_viewer addSubview:v];
    [self.view addSubview:_viewer];
}
- (void)viewDidAppear:(BOOL)a {
    [super viewDidAppear:a]; [self becomeFirstResponder];
    fprintf(stderr, "hearth: Gallery open (%lu pictures)\n", (unsigned long)_all.count);
}
- (void)dealloc { [_repeat stop]; [_statusTimer invalidate]; }
- (BOOL)canBecomeFirstResponder { return YES; }

#pragma mark - Data

// Reads the Gallery again; keep: the picture to stay on (after a delete, the one now in its place)
- (void)reloadKeeping:(NSString *)keep {
    NSMutableArray *all = [NSMutableArray array], *games = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *it in hearth_gallery_items(documents())) {
        if (![[it[@"path"] pathExtension].lowercaseString isEqual:@"jpg"]) continue;   // shortcut: clips are not shown (spike R1 did not run, so Hearth writes none); a player for .mp4 comes with clips
        [all addObject:it];
        if (![seen containsObject:it[@"titleId"]]) { [seen addObject:it[@"titleId"]]; [games addObject:it]; }
    }
    NSString *was = _filter > 0 && _filter <= (NSInteger)_games.count ? _games[(NSUInteger)_filter - 1][@"titleId"] : nil;
    _all = all; _games = games; _filter = 0;
    for (NSUInteger i = 0; i < games.count; i++) if ([games[i][@"titleId"] isEqual:was]) _filter = (NSInteger)i + 1;
    [self buildChips]; [self applyFilterKeeping:keep];
}
- (void)buildChips {
    for (UIView *v in _chips) [v removeFromSuperview];
    NSMutableArray *cs = [NSMutableArray array];
    NSMutableArray *names = [NSMutableArray arrayWithObject:@"All"]; for (NSDictionary *g in _games) [names addObject:g[@"title"]];
    for (NSUInteger i = 0; i < names.count; i++) {
        UIButton *b = pill(names[i], nil); b.tag = (NSInteger)i;
        [b addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_chipRow addSubview:b]; [cs addObject:b];
    }
    [_chipRow addSubview:_chipRing];
    _chips = cs;
}
- (void)applyFilterKeeping:(NSString *)keep {
    NSString *tid = _filter > 0 ? _games[(NSUInteger)_filter - 1][@"titleId"] : nil;
    _shown = tid ? [_all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"titleId == %@", tid]] : _all;
    for (UIButton *b in _chips) {
        UIButtonConfiguration *c = b.configuration; BOOL on = b.tag == _filter;
        c.baseBackgroundColor = on ? DmUI.accent : DmUI.row; c.baseForegroundColor = on ? UIColor.blackColor : DmUI.text; b.configuration = c;
        b.accessibilityTraits = UIAccessibilityTraitButton | (on ? UIAccessibilityTraitSelected : 0);
    }
    _cell = 0; for (NSUInteger i = 0; i < _shown.count; i++) if ([_shown[i][@"path"] isEqual:keep]) _cell = (NSInteger)i;
    _empty.hidden = _all.count > 0; _chipRow.hidden = _all.count == 0;
    if (!_shown.count) _onChips = YES;
    [_grid reloadData]; [self.view setNeedsLayout]; [self.view layoutIfNeeded]; [self showFocus:NO];
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; UIEdgeInsets si = self.view.safeAreaInsets;
    CGFloat left = MAX(si.left, 0) + HEARTH_MARGIN, right = b.size.width - MAX(si.right, 0) - HEARTH_MARGIN, top = MAX(si.top, 0) + 24, w = right - left;
    _head.frame = CGRectMake(left, top, w - 60, 48);
    _closeButton.frame = CGRectMake(right - 44, top + 2, 44, 44);
    CGFloat x = 0; for (UIButton *c in _chips) { CGSize s = [c sizeThatFits:CGSizeMake(400, 52)]; c.frame = CGRectMake(x, 0, s.width, 52); x += s.width + 12; }
    _chipRow.frame = CGRectMake(left, top + 68, w, 52); _chipRow.contentSize = CGSizeMake(MAX(x - 12, 0), 52);
    CGFloat hh = [_hints heightWithCompact:NO], barTop = b.size.height - MAX(si.bottom, 0) - HEARTH_BAR_HEIGHT;
    _hints.frame = CGRectMake(left, barTop + (HEARTH_BAR_HEIGHT - hh) / 2, w, hh);
    CGFloat gy = top + 68 + 52 + 28;
    _grid.frame = CGRectMake(left, gy, w, barTop - gy);
    _empty.frame = CGRectMake(left, top + 68, w, barTop - top - 68);
    _cols = w >= 960 ? 4 : 3;
    CGFloat iw = floor((w - (_cols - 1) * GAP) / _cols);
    ((UICollectionViewFlowLayout *)_grid.collectionViewLayout).itemSize = CGSizeMake(iw, round(iw * 9 / 16));
    // the viewer: the picture fills the screen; the back button at the top left, the info card and the hints along the bottom
    _viewer.frame = b; _big.frame = b;
    CGSize bs = [_back sizeThatFits:CGSizeMake(300, 52)]; _back.frame = CGRectMake(left, top, bs.width, 52);
    CGFloat ch = 88, cy = barTop - ch - 8;
    _card.frame = CGRectMake(left, cy, w, ch);
    CGFloat bx = w - 20;
    for (UIButton *p in @[_save, _share, _del]) { CGSize s = [p sizeThatFits:CGSizeMake(400, 52)]; bx -= s.width; p.frame = CGRectMake(bx, (ch - 52) / 2, s.width, 52); bx -= 12; }
    _caption.frame = CGRectMake(24, 16, bx - 36, 28); _detail.frame = CGRectMake(24, 46, bx - 36, 24);
    _viewHints.frame = CGRectMake(left, barTop + (HEARTH_BAR_HEIGHT - hh) / 2, w, hh);
    [self showFocus:NO];
}

#pragma mark - Grid

- (NSInteger)collectionView:(UICollectionView *)v numberOfItemsInSection:(NSInteger)s { (void)v; (void)s; return (NSInteger)_shown.count; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)v cellForItemAtIndexPath:(NSIndexPath *)ip {
    HearthShotCell *c = [v dequeueReusableCellWithReuseIdentifier:@"shot" forIndexPath:ip];
    NSDictionary *it = _shown[(NSUInteger)ip.item]; NSString *p = it[@"path"];
    c.path = p; c.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", it[@"title"], when(it[@"date"])];
    UIImage *t = [thumbs() objectForKey:p]; c.image.image = t;
    if (!t) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *im = thumb_of(p); if (!im) return;
        [thumbs() setObject:im forKey:p];
        dispatch_async(dispatch_get_main_queue(), ^{ if ([c.path isEqual:p]) c.image.image = im; });   // the cell may show another picture by now
    });
    return c;
}
- (void)collectionView:(UICollectionView *)v didSelectItemAtIndexPath:(NSIndexPath *)ip {
    (void)v; _ringShown = NO; _onChips = NO; _cell = ip.item; [self showFocus:NO]; [self openViewer:_cell];
}
- (void)scrollViewWillBeginDragging:(UIScrollView *)s { (void)s; _ringShown = NO; [self showFocus:NO]; }
- (void)chipTapped:(UIButton *)b { _ringShown = NO; [self pickFilter:b.tag]; }
- (void)pickFilter:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_chips.count) return;
    if (i != _filter) hearth_sound(HearthSoundMove);
    _filter = i; [self applyFilterKeeping:nil];
}
- (void)showFocus:(BOOL)animated {
    BOOL chips = _onChips || !_shown.count;
    UIButton *chip = _filter < (NSInteger)_chips.count ? _chips[(NSUInteger)_filter] : nil;
    CGRect cf = CGRectZero;
    if (_shown.count) { NSIndexPath *ip = [NSIndexPath indexPathForItem:MIN(_cell, (NSInteger)_shown.count - 1) inSection:0]; cf = [_grid layoutAttributesForItemAtIndexPath:ip].frame;
                        if (!chips) [_grid scrollRectToVisible:CGRectInset(cf, 0, -GAP) animated:animated]; }
    void (^place)(void) = ^{ if (chip) self->_chipRing.frame = CGRectInset(chip.frame, -5, -5); self->_cellRing.frame = CGRectInset(cf, -6, -6); };
    if (animated && !UIAccessibilityIsReduceMotionEnabled()) [UIView animateWithDuration:HEARTH_FOCUS_SECONDS delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:place completion:nil];
    else place();
    if (chip && chips) [_chipRow scrollRectToVisible:CGRectInset(chip.frame, -20, 0) animated:animated];
    _chipRing.active = _ringShown && chips && chip; _cellRing.active = _ringShown && !chips;
    [_hints setHints:!_all.count ? @[@[@"B", @"Close"]] : chips ? @[@[@"↔", @"Game"], @[@"B", @"Close"], @[@"L R", @"Game"]] : @[@[@"A", @"View"], @[@"B", @"Close"], @[@"L R", @"Game"]]];
}
- (void)go:(HearthDir)d {
    if (!_ringShown) { _ringShown = YES; [self showFocus:NO]; return; }   // after a touch the first direction only shows where the focus is
    if (_onChips || !_shown.count) {
        if (d == HearthDirLeft || d == HearthDirRight) [self pickFilter:_filter + (d == HearthDirRight ? 1 : -1)];
        else if (d == HearthDirDown && _shown.count) { _onChips = NO; hearth_sound(HearthSoundMove); }
    } else {
        NSInteger n = hearth_grid_move(_cell, (NSInteger)_shown.count, _cols, d);
        if (n < 0) _onChips = YES; else if (n != _cell) _cell = n; else { [self showFocus:YES]; return; }
        hearth_sound(HearthSoundMove);
    }
    [self showFocus:YES];
}

#pragma mark - Viewer

- (void)openViewer:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_shown.count) return;
    if (_at < 0) hearth_sound(HearthSoundOpen);
    _at = i; _armed = NO; _viewer.hidden = NO; [self setInfo:YES];
    NSDictionary *it = _shown[(NSUInteger)i];
    _big.image = [UIImage imageWithContentsOfFile:it[@"path"]];
    _big.accessibilityLabel = [NSString stringWithFormat:@"Screenshot of %@, %@", it[@"title"], when(it[@"date"])];
    _caption.text = it[@"title"]; [self status:nil];
    [self disarm];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, _big);
}
- (void)closeViewer {
    if (_at < 0) return;
    hearth_sound(HearthSoundBack);
    _cell = _at; _at = -1; _viewer.hidden = YES; _onChips = NO; [self showFocus:NO];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
}
- (void)step:(NSInteger)d { if (_at + d >= 0 && _at + d < (NSInteger)_shown.count) { hearth_sound(HearthSoundMove); [self openViewer:_at + d]; } }
- (void)swiped:(UISwipeGestureRecognizer *)s { [self step:s.direction == UISwipeGestureRecognizerDirectionLeft ? 1 : -1]; }
- (void)setInfo:(BOOL)on { _card.alpha = on; _viewHints.alpha = on; _back.alpha = on; }
- (void)toggleInfo { [self setInfo:_card.alpha < 0.5]; }
- (void)status:(NSString *)text {   // a short note in place of the date (Saved to Photos, the delete question), back to the date after a while
    [_statusTimer invalidate]; _statusTimer = nil;
    NSDictionary *it = _at >= 0 ? _shown[(NSUInteger)_at] : nil;
    _detail.text = text ?: (it ? when(it[@"date"]) : nil); _detail.textColor = text ? DmUI.accentText : DmUI.sub;
    if (text) { UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, text); __weak HearthGalleryVC *w = self;
                _statusTimer = [NSTimer scheduledTimerWithTimeInterval:3 repeats:NO block:^(NSTimer *t) { (void)t; HearthGalleryVC *s = w; if (s && !s->_armed) [s status:nil]; }]; }
}
- (void)disarm {
    _armed = NO;
    UIButtonConfiguration *c = _del.configuration; c.title = @"Delete"; c.baseForegroundColor = DmUI.text; _del.configuration = c;
}
- (void)deletePressed {   // the first press asks, the second deletes
    if (_at < 0) return;
    if (!_armed) {
        _armed = YES; UIButtonConfiguration *c = _del.configuration; c.title = @"Delete?"; c.baseForegroundColor = DmUI.warn; _del.configuration = c;
        [self status:@"Press Delete again to delete this picture."]; return;
    }
    NSString *p = _shown[(NSUInteger)_at][@"path"], *why = nil, *next = _at + 1 < (NSInteger)_shown.count ? _shown[(NSUInteger)_at + 1][@"path"] : _at > 0 ? _shown[(NSUInteger)_at - 1][@"path"] : nil;
    [self disarm];
    if (!hearth_gallery_delete(documents(), p, &why)) { fprintf(stderr, "hearth: [RED] Gallery delete failed: %s\n", why.UTF8String); [self status:@"The picture was not deleted."]; return; }
    fprintf(stderr, "hearth: Gallery deleted %s\n", p.lastPathComponent.UTF8String);
    hearth_sound(HearthSoundClose); [thumbs() removeObjectForKey:p];
    [self reloadKeeping:next];
    if (!_shown.count) { _at = -1; _viewer.hidden = YES; [self showFocus:NO]; return; }
    _at = -1; [self openViewer:_cell];
}
- (void)share {
    if (_at < 0 || self.presentedViewController) return;
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:_shown[(NSUInteger)_at][@"path"]]] applicationActivities:nil];
    a.popoverPresentationController.sourceView = _share; a.popoverPresentationController.sourceRect = _share.bounds;
    __weak HearthGalleryVC *w = self; a.completionWithItemsHandler = ^(UIActivityType t, BOOL done, NSArray *r, NSError *e) { (void)t; (void)r; (void)e; HearthGalleryVC *s = w; if (s) { s->_baselined = NO; [s becomeFirstResponder]; } (void)done; };
    [self presentViewController:a animated:YES completion:nil];
}
- (void)saveToPhotos {   // add-only access: Hearth never reads the library
    if (_at < 0) return;
    NSURL *u = [NSURL fileURLWithPath:_shown[(NSUInteger)_at][@"path"]]; __weak HearthGalleryVC *w = self;
    void (^say)(NSString *) = ^(NSString *t) { dispatch_async(dispatch_get_main_queue(), ^{ [w status:t]; }); };
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus st) {
        if (st != PHAuthorizationStatusAuthorized && st != PHAuthorizationStatusLimited) { say(@"Hearth may not add to Photos. Allow it in the Settings app, under Hearth."); return; }
        [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{ [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:u]; } completionHandler:^(BOOL ok, NSError *e) {
            if (!ok) fprintf(stderr, "hearth: [RED] Save to Photos failed: %s\n", e.localizedDescription.UTF8String);
            say(ok ? @"Saved to Photos" : @"The picture was not saved to Photos.");
        }];
    }];
}

#pragma mark - Close

- (void)close {
    if (_closing) return;
    _closing = YES; [_repeat stop]; hearth_sound(HearthSoundBack);
    fprintf(stderr, "hearth: Gallery closed\n");
    void (^done)(void) = self.onClose;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.14 animations:^{ self.view.alpha = 0; } completion:^(BOOL f) { (void)f; if (done) done(); }];
}
- (void)back { if (_at >= 0) [self closeViewer]; else [self close]; }
- (BOOL)accessibilityPerformEscape { [self back]; return YES; }

#pragma mark - Controller and keyboard

- (void)padState:(uint64_t)m lx:(int32_t)lx ly:(int32_t)ly {
    if (self.presentedViewController) { _baselined = NO; return; }   // the share sheet is the system's: what is held when it goes does nothing until released
    HearthDir d = m & 1ull << DMB_UP || ly > 20000 ? HearthDirUp : m & 1ull << DMB_DOWN || ly < -20000 ? HearthDirDown : m & 1ull << DMB_LEFT || lx < -20000 ? HearthDirLeft : m & 1ull << DMB_RIGHT || lx > 20000 ? HearthDirRight : HearthDirNone;
    uint64_t want = m & (1ull << DMB_A | 1ull << DMB_B | 1ull << DMB_X | 1ull << DMB_Y | 1ull << DMB_PLUS | 1ull << DMB_L | 1ull << DMB_R | 1ull << DMB_ZL | 1ull << DMB_ZR);
    if (!_baselined) { _baselined = YES; _prev = want; if (d) [_repeat hold:d step:nil]; return; }
    uint64_t up = want & ~_prev; _prev = want;
    if (d != (HearthDir)_repeat.held) {
        [_repeat stop];
        if (d) { [self dir:d]; __weak HearthGalleryVC *w = self; [_repeat hold:d step:^NSTimeInterval { [w dir:d]; return DM_REPEAT_NEXT; }]; }
    }
    if (up & 1ull << DMB_A) [self accept];
    if (up & 1ull << DMB_B) [self back];
    if (_at >= 0) {
        if (up & 1ull << DMB_X) [self deletePressed];
        if (up & 1ull << DMB_Y) [self share];
        if (up & 1ull << DMB_PLUS) [self saveToPhotos];
    } else if (up & (1ull << DMB_L | 1ull << DMB_ZL | 1ull << DMB_R | 1ull << DMB_ZR)) [self pickFilter:_filter + (up & (1ull << DMB_R | 1ull << DMB_ZR) ? 1 : -1)];
}
- (void)dir:(HearthDir)d {
    if (_at < 0) { [self go:d]; return; }
    [self setInfo:YES];
    if (d == HearthDirLeft || d == HearthDirRight) [self step:d == HearthDirRight ? 1 : -1];
}
- (void)accept {
    if (_at >= 0) { [self toggleInfo]; return; }
    if (!_ringShown) { _ringShown = YES; [self showFocus:NO]; return; }   // after a touch, A first shows where the focus is
    if (_onChips || !_shown.count) { if (_shown.count) { _onChips = NO; [self showFocus:YES]; } return; }
    [self openViewer:_cell];
}
- (NSArray<UIKeyCommand *> *)keyCommands {
    NSMutableArray *r = [NSMutableArray array];
    for (NSArray *p in @[@[UIKeyInputUpArrow, @"keyUp"], @[UIKeyInputDownArrow, @"keyDown"], @[UIKeyInputLeftArrow, @"keyLeft"], @[UIKeyInputRightArrow, @"keyRight"], @[@"\r", @"accept"], @[UIKeyInputEscape, @"back"]]) {
        UIKeyCommand *c = [UIKeyCommand keyCommandWithInput:p[0] modifierFlags:0 action:NSSelectorFromString(p[1])]; c.wantsPriorityOverSystemBehavior = YES; [r addObject:c];
    }
    return r;
}
- (void)keyUp { [self dir:HearthDirUp]; }
- (void)keyDown { [self dir:HearthDirDown]; }
- (void)keyLeft { [self dir:HearthDirLeft]; }
- (void)keyRight { [self dir:HearthDirRight]; }
@end
