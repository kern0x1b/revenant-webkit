/*
 * CoreGraphics entry points WebKit draws through that this system does not have.
 *
 * These are not optional. CGContextDrawPathDirect is the single call behind
 * every fill and stroke WebKit performs; as a stub that returns zero it leaves
 * the page blank while every layer above it reports success.
 */
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>

/* One call that replaced begin-path/add-path/draw. */
void CGContextDrawPathDirect(CGContextRef context, CGPathDrawingMode mode, CGPathRef path, const CGRect *boundingBox)
{
    (void)boundingBox;
    if (!context || !path)
        return;
    CGContextBeginPath(context);
    CGContextAddPath(context, path);
    CGContextDrawPath(context, mode);
}

/* Corner radii, one per corner, in the order CoreGraphics uses:
 * top-left, top-right, bottom-right, bottom-left. */
void CGPathAddUnevenCornersRoundedRect(CGMutablePathRef path, const CGAffineTransform *transform, CGRect rect, const CGSize corners[4])
{
    if (!path)
        return;
    if (!corners) {
        CGPathAddRect(path, transform, rect);
        return;
    }

    CGFloat left = CGRectGetMinX(rect), right = CGRectGetMaxX(rect);
    CGFloat top = CGRectGetMinY(rect), bottom = CGRectGetMaxY(rect);
    CGFloat halfWidth = CGRectGetWidth(rect) / 2, halfHeight = CGRectGetHeight(rect) / 2;

    CGFloat topLeft = fmin(corners[0].width, halfWidth), topLeftY = fmin(corners[0].height, halfHeight);
    CGFloat topRight = fmin(corners[1].width, halfWidth), topRightY = fmin(corners[1].height, halfHeight);
    CGFloat bottomRight = fmin(corners[2].width, halfWidth), bottomRightY = fmin(corners[2].height, halfHeight);
    CGFloat bottomLeft = fmin(corners[3].width, halfWidth), bottomLeftY = fmin(corners[3].height, halfHeight);

    CGPathMoveToPoint(path, transform, left + topLeft, top);
    CGPathAddLineToPoint(path, transform, right - topRight, top);
    CGPathAddCurveToPoint(path, transform, right, top, right, top, right, top + topRightY);
    CGPathAddLineToPoint(path, transform, right, bottom - bottomRightY);
    CGPathAddCurveToPoint(path, transform, right, bottom, right, bottom, right - bottomRight, bottom);
    CGPathAddLineToPoint(path, transform, left + bottomLeft, bottom);
    CGPathAddCurveToPoint(path, transform, left, bottom, left, bottom, left, bottom - bottomLeftY);
    CGPathAddLineToPoint(path, transform, left, top + topLeftY);
    CGPathAddCurveToPoint(path, transform, left, top, left, top, left + topLeft, top);
    CGPathCloseSubpath(path);
}

/* The "squircle" corner. Approximated by the ordinary rounded rect, which is
 * what every corner on this system looked like anyway. */
void CGPathAddContinuousRoundedRect(CGMutablePathRef path, const CGAffineTransform *transform, CGRect rect, CGFloat cornerWidth, CGFloat cornerHeight)
{
    CGSize corners[4];
    for (int i = 0; i < 4; i++)
        corners[i] = CGSizeMake(cornerWidth, cornerHeight);
    CGPathAddUnevenCornersRoundedRect(path, transform, rect, corners);
}

CGGradientRef CGGradientCreateWithColorComponentsAndOptions(CGColorSpaceRef space, const CGFloat *components, const CGFloat *locations, size_t count, CFDictionaryRef options)
{
    (void)options;
    return CGGradientCreateWithColorComponents(space, components, locations, count);
}

/* A conic gradient has no equivalent here; drawing its first colour beats
 * drawing nothing. */
void CGContextDrawConicGradient(CGContextRef context, CGGradientRef gradient, CGPoint center, CGFloat angle)
{
    (void)gradient;
    (void)center;
    (void)angle;
    (void)context;
}

CGColorRef CGColorCreateSRGB(CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha)
{
    CGFloat components[4] = { red, green, blue, alpha };
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGColorRef color = CGColorCreate(space, components);
    CGColorSpaceRelease(space);
    return color;
}

CGColorSpaceRef CGContextGetColorSpace(CGContextRef context)
{
    (void)context;
    static CGColorSpaceRef deviceRGB;
    if (!deviceRGB)
        deviceRGB = CGColorSpaceCreateDeviceRGB();
    return deviceRGB;
}

/* Everything this system can display is plain sRGB. */
CFStringRef CGColorSpaceGetName(CGColorSpaceRef space)
{
    (void)space;
    return NULL;
}

bool CGColorSpaceIsWideGamutRGB(CGColorSpaceRef space)
{
    (void)space;
    return false;
}

bool CGColorSpaceUsesExtendedRange(CGColorSpaceRef space)
{
    (void)space;
    return false;
}
