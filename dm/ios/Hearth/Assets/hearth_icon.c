// Hearth's app icon, drawn as vector art with CoreGraphics (original; plan-hearth-p2.md section 7): a soft glowing hearth opening, an arch of warm amber light on a dark warm ground,
// with a hearthstone line under it. No red and no split rectangle. build_ipa.sh compiles and runs it for the asset catalog.
// Build and run: clang -O1 -o hearth_icon hearth_icon.c -framework CoreGraphics -framework ImageIO -framework CoreFoundation && ./hearth_icon icon.png [size]
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <stdio.h>
#include <stdlib.h>

static CGColorRef rgb(CGColorSpaceRef cs, unsigned hex, double a) {
    CGFloat c[4] = {((hex >> 16) & 255) / 255.0, ((hex >> 8) & 255) / 255.0, (hex & 255) / 255.0, a};
    return CGColorCreate(cs, c);
}
static CGGradientRef gradient(CGColorSpaceRef cs, const unsigned *hex, const double *alpha, const CGFloat *at, int n) {
    CGFloat comp[4 * 8];
    for (int i = 0; i < n; i++) { comp[4 * i] = ((hex[i] >> 16) & 255) / 255.0; comp[4 * i + 1] = ((hex[i] >> 8) & 255) / 255.0; comp[4 * i + 2] = (hex[i] & 255) / 255.0; comp[4 * i + 3] = alpha[i]; }
    return CGGradientCreateWithColorComponents(cs, comp, at, (size_t)n);
}
// An arch: straight sides from the floor to the spring line, then a half circle (all in units of the 1024 canvas)
static CGPathRef arch(double cx, double floor, double halfWidth, double spring) {
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, cx - halfWidth, floor);
    CGPathAddLineToPoint(p, NULL, cx - halfWidth, spring);
    CGPathAddArc(p, NULL, cx, spring, halfWidth, M_PI, 0, true);
    CGPathAddLineToPoint(p, NULL, cx + halfWidth, floor);
    CGPathCloseSubpath(p);
    return p;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: hearth_icon out.png [size]\n"); return 2; }
    int size = argc > 2 ? atoi(argv[2]) : 1024; if (size < 16 || size > 4096) { fprintf(stderr, "hearth_icon: size %d out of range\n", size); return 2; }
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef g = CGBitmapContextCreate(NULL, (size_t)size, (size_t)size, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    if (!g) { fprintf(stderr, "hearth_icon: no bitmap context\n"); return 1; }
    CGContextScaleCTM(g, size / 1024.0, size / 1024.0);   // drawn on a 1024 canvas, origin bottom left

    // Ground: a dark warm brown, a little lighter at the top
    { unsigned h[] = {0x2B1F18, 0x140D0A}; double a[] = {1, 1}; CGFloat at[] = {0, 1}; CGGradientRef gr = gradient(cs, h, a, at, 2);
      CGContextDrawLinearGradient(g, gr, CGPointMake(512, 1024), CGPointMake(512, 0), 0); CGGradientRelease(gr); }

    // The opening: its glow spills out first (a blurred fill), then the arch is filled with light, brightest low in the middle where the embers are
    CGPathRef outer = arch(512, 236, 214, 560);
    CGContextSaveGState(g);
    CGColorRef glow = rgb(cs, 0xFFB547, 0.75); CGContextSetShadowWithColor(g, CGSizeZero, 140, glow); CGColorRelease(glow);
    CGColorRef base = rgb(cs, 0x8A4A08, 1); CGContextSetFillColorWithColor(g, base); CGColorRelease(base);
    CGContextAddPath(g, outer); CGContextFillPath(g);
    CGContextRestoreGState(g);
    CGContextSaveGState(g);
    CGContextAddPath(g, outer); CGContextClip(g);
    { unsigned h[] = {0xFFF1CF, 0xFFC86A, 0xE58A1A, 0x7A3E06}; double a[] = {1, 1, 1, 1}; CGFloat at[] = {0, 0.28, 0.62, 1}; CGGradientRef gr = gradient(cs, h, a, at, 4);
      CGContextDrawRadialGradient(g, gr, CGPointMake(512, 300), 0, CGPointMake(512, 360), 520, kCGGradientDrawsAfterEndLocation); CGGradientRelease(gr); }
    CGContextRestoreGState(g);
    CGPathRelease(outer);

    // A darker inner arch gives the opening depth; a soft light still rises from its floor
    CGPathRef inner = arch(512, 236, 128, 520);
    CGContextSaveGState(g);
    CGContextAddPath(g, inner); CGContextClip(g);
    { unsigned h[] = {0xFFE0A0, 0xF09A2C, 0x5A2C06}; double a[] = {0.95, 0.9, 0.85}; CGFloat at[] = {0, 0.35, 1}; CGGradientRef gr = gradient(cs, h, a, at, 3);
      CGContextDrawRadialGradient(g, gr, CGPointMake(512, 250), 0, CGPointMake(512, 250), 360, kCGGradientDrawsAfterEndLocation); CGGradientRelease(gr); }
    CGContextRestoreGState(g);
    CGPathRelease(inner);

    // The hearthstone: a soft cream bar the light falls on
    CGColorRef stone = rgb(cs, 0xF3DCB8, 0.92); CGContextSetFillColorWithColor(g, stone); CGColorRelease(stone);
    CGPathRef bar = CGPathCreateWithRoundedRect(CGRectMake(250, 196, 524, 30), 15, 15, NULL); CGContextAddPath(g, bar); CGContextFillPath(g); CGPathRelease(bar);

    CGImageRef img = CGBitmapContextCreateImage(g);
    CFStringRef path = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, false);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    int ok = d != NULL;
    if (d) { CGImageDestinationAddImage(d, img, NULL); ok = CGImageDestinationFinalize(d); CFRelease(d); }
    CFRelease(url); CFRelease(path); CGImageRelease(img); CGContextRelease(g); CGColorSpaceRelease(cs);
    if (!ok) { fprintf(stderr, "hearth_icon: could not write %s\n", argv[1]); return 1; }
    return 0;
}
