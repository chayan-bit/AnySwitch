// Users' pictures and pickers (HearthAvatar.h)
#import "HearthAvatar.h"
#import "HearthDialog.h"
#import "HearthLaunch.h"
#import "DmSettings.h"
#import <PhotosUI/PhotosUI.h>

#define AVATAR_EDGE 256.0   // pixels of avatar.jpg
#define AVATAR_JPEG 0.85    // keeps a photo well under the console's 128 KiB profile image limit (from memory, unverified)

HearthUsers *hearth_users(void) {
    static HearthUsers *us; static dispatch_once_t once;
    dispatch_once(&once, ^{ us = [[HearthUsers alloc] initWithDocuments:hearth_library().documentsDir firstName:[DmSettings.systemStore valueForKey:@"DM_NICK"]]; });
    return us;
}

static UIColor *colour(NSString *name) {
    NSDictionary *c = @{@"amber": @0xE8A33D, @"teal": @0x2E9C95, @"rose": @0xD9577A, @"violet": @0x7D63D8, @"lime": @0x7DAF3B, @"sky": @0x3D8FE0, @"coral": @0xE5694C, @"slate": @0x5E6E7E};
    unsigned v = [c[name] unsignedIntValue] ?: 0xE8A33D;
    return [UIColor colorWithRed:((v >> 16) & 0xff) / 255.0 green:((v >> 8) & 0xff) / 255.0 blue:(v & 0xff) / 255.0 alpha:1];
}
static NSArray<NSDictionary *> *art_choices(void) {
    NSArray *p = @[@[@"person.fill", @"amber"], @[@"star.fill", @"teal"], @[@"leaf.fill", @"lime"], @[@"flame.fill", @"coral"], @[@"moon.fill", @"violet"], @[@"bolt.fill", @"sky"], @[@"heart.fill", @"rose"], @[@"pawprint.fill", @"slate"]];
    NSMutableArray *out = [NSMutableArray array];
    for (NSArray *a in p) [out addObject:@{@"kind": @"art", @"symbol": a[0], @"colour": a[1]}];
    return out;
}
// A symbol in white on its colour, filling the square (the pickers clip it to a circle, as the console does)
static UIImage *draw_art(NSDictionary *art, CGFloat edge) {
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat]; f.scale = 1; f.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(edge, edge) format:f] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [colour(art[@"colour"]) setFill]; UIRectFill(CGRectMake(0, 0, edge, edge));
        UIImage *s = [[UIImage systemImageNamed:art[@"symbol"] ?: @"person.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:edge * 0.48 weight:UIImageSymbolWeightSemibold]]
                      imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGSize z = s.size; [s drawInRect:CGRectMake((edge - z.width) / 2, (edge - z.height) / 2, z.width, z.height)];
    }];
}
static UIImage *square(UIImage *img, CGFloat edge) {   // centre crop to a square, scaled to edge pixels
    CGSize z = img.size; CGFloat s = MIN(z.width, z.height); if (s <= 0) return nil;
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat]; f.scale = 1; f.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(edge, edge) format:f] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        CGFloat k = edge / s; [img drawInRect:CGRectMake((edge - z.width * k) / 2, (edge - z.height * k) / 2, z.width * k, z.height * k)];
    }];
}
static BOOL write_jpeg(UIImage *img, NSString *path) {
    NSData *d = UIImageJPEGRepresentation(img, AVATAR_JPEG);
    BOOL ok = d && [d writeToFile:path atomically:YES];
    if (!ok) NSLog(@"hearth: [RED] the picture %@ could not be written", path);
    return ok;
}

UIImage *hearth_avatar_image(HearthUser *u) {
    UIImage *img = [UIImage imageWithContentsOfFile:[hearth_users() avatarPathOf:u]];
    return img ?: draw_art([u.avatar[@"kind"] isEqual:@"art"] ? u.avatar : art_choices()[0], AVATAR_EDGE);
}
void hearth_avatar_ensure(void) {
    HearthUsers *us = hearth_users();
    for (HearthUser *u in us.users) {
        NSString *p = [us avatarPathOf:u];
        if (![NSFileManager.defaultManager fileExistsAtPath:p]) write_jpeg(hearth_avatar_image(u), p);
    }
}

void hearth_pick_user(UIViewController *over, NSString *title, HearthUser *preferred, void (^done)(HearthUser *u)) {
    NSArray<HearthUser *> *list = hearth_users().users;
    NSMutableArray *names = [NSMutableArray array], *imgs = [NSMutableArray array];
    for (HearthUser *u in list) { [names addObject:u.name]; [imgs addObject:hearth_avatar_image(u)]; }
    [names addObject:@"Cancel"]; [imgs addObject:NSNull.null];
    NSInteger focus = preferred ? (NSInteger)[list indexOfObject:preferred] : 0; if (focus == NSNotFound) focus = 0;
    hearth_dialog_tiles(over, title, nil, names, imgs, focus, (NSInteger)list.count, ^(NSInteger i) {
        HearthUser *u = i >= 0 && i < (NSInteger)list.count ? list[(NSUInteger)i] : nil;
        fprintf(stderr, "hearth: user picked: %s\n", u ? u.uid.UTF8String : "none (cancelled)");
        done(u);
    });
}

// The photo library through the system picker (no permission needed: it runs outside the app and hands over only the chosen photo)
@interface HearthPhotoPick : NSObject <PHPickerViewControllerDelegate>
@property (nonatomic, copy) void (^done)(UIImage *img);
@end
@implementation HearthPhotoPick
- (void)picker:(PHPickerViewController *)p didFinishPicking:(NSArray<PHPickerResult *> *)results {
    void (^done)(UIImage *) = self.done; self.done = nil;
    NSItemProvider *ip = results.firstObject.itemProvider;
    [p dismissViewControllerAnimated:YES completion:^{
        if (![ip canLoadObjectOfClass:UIImage.class]) { done(nil); return; }
        [ip loadObjectOfClass:UIImage.class completionHandler:^(id obj, NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{ done([obj isKindOfClass:UIImage.class] ? obj : nil); if (e) NSLog(@"hearth: the photo could not be read: %@", e.localizedDescription); });
        }];
    }];
}
@end

void hearth_choose_avatar(UIViewController *over, HearthUser *u, void (^done)(BOOL changed)) {
    NSArray<NSDictionary *> *arts = art_choices();
    NSMutableArray *names = [NSMutableArray array], *imgs = [NSMutableArray array];
    for (NSDictionary *a in arts) { [names addObject:@""]; [imgs addObject:draw_art(a, AVATAR_EDGE)]; }
    [names addObject:@"Photo"]; [imgs addObject:[[UIImage systemImageNamed:@"photo.on.rectangle"] imageWithTintColor:UIColor.grayColor renderingMode:UIImageRenderingModeAlwaysOriginal]];
    [names addObject:@"Cancel"]; [imgs addObject:NSNull.null];
    NSUInteger cur = [arts indexOfObject:u.avatar]; NSInteger focus = cur == NSNotFound ? 0 : (NSInteger)cur, cancel = (NSInteger)names.count - 1;
    hearth_dialog_tiles(over, [NSString stringWithFormat:@"A picture for %@", u.name], nil, names, imgs, focus, cancel, ^(NSInteger i) {
        HearthUsers *us = hearth_users();
        if (i == cancel || i < 0) { done(NO); return; }
        if (i < (NSInteger)arts.count) {
            NSDictionary *a = arts[(NSUInteger)i];
            BOOL ok = write_jpeg(draw_art(a, AVATAR_EDGE), [us avatarPathOf:u]); if (ok) [us setAvatar:a of:u];
            fprintf(stderr, "hearth: %s's picture: %s\n", u.uid.UTF8String, [a[@"symbol"] UTF8String]); done(ok); return;
        }
        static HearthPhotoPick *pick; pick = [HearthPhotoPick new];   // kept while the picker is up (its delegate is weak)
        pick.done = ^(UIImage *img) {
            UIImage *sq = img ? square(img, AVATAR_EDGE) : nil;
            BOOL ok = sq && write_jpeg(sq, [us avatarPathOf:u]); if (ok) [us setAvatar:@{@"kind": @"photo"} of:u];
            fprintf(stderr, "hearth: %s's picture: %s\n", u.uid.UTF8String, ok ? "a photo" : "no photo chosen");
            pick = nil; done(ok);
        };
        PHPickerConfiguration *cfg = [PHPickerConfiguration new]; cfg.filter = PHPickerFilter.imagesFilter; cfg.selectionLimit = 1;
        PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg]; p.delegate = pick;
        UIViewController *top = over; while (top.presentedViewController) top = top.presentedViewController;
        [top presentViewController:p animated:YES completion:nil];
    });
}
