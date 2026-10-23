// Screenshots of the game's own picture (HearthCapture.h)
#import "HearthCapture.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#define JPEG_QUALITY 0.9

static double ms_since(CFTimeInterval t0) { return (CACurrentMediaTime() - t0) * 1000; }

static BOOL write_jpeg(CGImageRef img, NSString *path) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    CGImageDestinationRef d = img ? CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], (__bridge CFStringRef)UTTypeJPEG.identifier, 1, NULL) : NULL;
    if (!d) return NO;
    CGImageDestinationAddImage(d, img, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @(JPEG_QUALITY)});
    BOOL ok = CGImageDestinationFinalize(d); CFRelease(d);
    return ok;
}

void hearth_capture_rgba(NSData *rgba, int w, int h, NSString *path, void (^done)(NSString *path)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = NO;
        if (w > 0 && h > 0 && rgba.length >= (NSUInteger)w * h * 4) {
            CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGImageRef img = CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs, kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast, dp, NULL, false, kCGRenderingIntentDefault);
            ok = write_jpeg(img, path);
            CGImageRelease(img); CGColorSpaceRelease(cs); CGDataProviderRelease(dp);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(ok ? path : nil); });
    });
}

void hearth_capture(UIView *view, CGRect content, NSString *path, void (^done)(NSString *path, double grabMs, double encodeMs)) {
    CFTimeInterval t0 = CACurrentMediaTime();
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat]; f.opaque = YES; f.scale = view.window.screen.scale ?: UIScreen.mainScreen.scale;
    UIImage *img = [[[UIGraphicsImageRenderer alloc] initWithSize:content.size format:f] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        (void)c; [view drawViewHierarchyInRect:CGRectOffset(view.bounds, -content.origin.x, -content.origin.y) afterScreenUpdates:NO];   // the screen as last shown: no extra frame is forced
    }];
    double grab = ms_since(t0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CFTimeInterval t1 = CACurrentMediaTime(); BOOL ok = write_jpeg(img.CGImage, path);
        double enc = ms_since(t1);
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(ok ? path : nil, grab, enc); });
    });
}
