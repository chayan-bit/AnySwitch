// Screenshots of the game's own picture (HearthCapture.h)
#import "HearthCapture.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#define JPEG_QUALITY 0.9

static double ms_since(CFTimeInterval t0) { return (CACurrentMediaTime() - t0) * 1000; }

void hearth_capture(UIView *view, CGRect content, NSString *dir, void (^done)(NSString *path, double grabMs, double encodeMs)) {
    CFTimeInterval t0 = CACurrentMediaTime();
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat]; f.opaque = YES; f.scale = view.window.screen.scale ?: UIScreen.mainScreen.scale;
    UIImage *img = [[[UIGraphicsImageRenderer alloc] initWithSize:content.size format:f] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        (void)c; [view drawViewHierarchyInRect:CGRectOffset(view.bounds, -content.origin.x, -content.origin.y) afterScreenUpdates:NO];   // the screen as last shown: no extra frame is forced
    }];
    double grab = ms_since(t0);
    NSDateFormatter *df = [NSDateFormatter new]; df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; df.dateFormat = @"yyyyMMdd-HHmmss-SSS";
    NSString *path = [dir stringByAppendingPathComponent:[[df stringFromDate:NSDate.date] stringByAppendingPathExtension:@"jpg"]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CFTimeInterval t1 = CACurrentMediaTime(); BOOL ok = NO;
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        CGImageDestinationRef d = img.CGImage ? CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], (__bridge CFStringRef)UTTypeJPEG.identifier, 1, NULL) : NULL;
        if (d) { CGImageDestinationAddImage(d, img.CGImage, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @(JPEG_QUALITY)}); ok = CGImageDestinationFinalize(d); CFRelease(d); }
        double enc = ms_since(t1);
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(ok ? path : nil, grab, enc); });
    });
}
