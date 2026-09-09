#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <string.h>

static void run(const char* what, CGColorSpaceRef cs, int viaLayer)
{
    unsigned char bits[4];
    memset(bits, 0, sizeof(bits));
    CGContextRef c = CGBitmapContextCreate(bits, 1, 1, 8, 4, cs, kCGImageAlphaPremultipliedFirst);
    if (!c) { printf("%-40s context refused\n", what); return; }

    CGContextRef target = c;
    CGLayerRef layer = NULL;
    if (viaLayer) {
        layer = CGLayerCreateWithContext(c, CGSizeMake(1, 1), NULL);
        if (!layer) { printf("%-40s no CGLayer\n", what); CGContextRelease(c); return; }
        target = CGLayerGetContext(layer);
    }

    CGContextSetRGBFillColor(target, 224/255.0, 160/255.0, 32/255.0, 1);
    CGContextFillRect(target, CGRectMake(0, 0, 1, 1));
    CGContextSetBlendMode(target, kCGBlendModeHue);
    CGContextBeginTransparencyLayer(target, NULL);
    CGContextSetBlendMode(target, kCGBlendModeNormal);
    CGContextSetRGBFillColor(target, 64/255.0, 128/255.0, 192/255.0, 1);
    CGContextFillRect(target, CGRectMake(0, 0, 1, 1));
    CGContextEndTransparencyLayer(target);

    if (layer) {
        CGContextDrawLayerAtPoint(c, CGPointZero, layer);
        CGLayerRelease(layer);
    }
    printf("%-40s %3d,%3d,%3d\n", what, bits[1], bits[2], bits[3]);
    CGContextRelease(c);
}

int main(void)
{
    CGColorSpaceRef device = CGColorSpaceCreateDeviceRGB();
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    run("device rgb, direct", device, 0);
    run("device rgb, through a CGLayer", device, 1);
    if (srgb) {
        run("sRGB, direct", srgb, 0);
        run("sRGB, through a CGLayer", srgb, 1);
        CGColorSpaceRelease(srgb);
    } else
        printf("no sRGB colour space on this system\n");
    CGColorSpaceRelease(device);
    return 0;
}
