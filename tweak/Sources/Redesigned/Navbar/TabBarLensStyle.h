// Shared held-glass optics for the full Legacy tab selection lens and the two
// isolated compact tab circles. Keep geometry and rim styling in one place;
// their gesture/selection behaviour intentionally remains independent.
#pragma once
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#define SGRLegacyHeldMagnification 0.92
#define SGRLegacyHeldBlur 0.08
#define SGRLegacyHeldBend 1.14
#define SGRLegacyHeldVerticalReach 0.24

// A single pose constructor for the full tab lens (dx=0, its spring supplies
// sx/sy) and the compact circles (horizontal finger travel + subtle stretch).
// Return a view transform, never separately animate a parallel rim layer.
static inline CGAffineTransform SGRLegacyGlassPoseTransform(CGFloat dx,
                                                            CGFloat sx,
                                                            CGFloat sy) {
    return CGAffineTransformScale(CGAffineTransformMakeTranslation(dx, 0), sx, sy);
}

static inline void SGRLegacyConfigureDirectionalRim(CAGradientLayer *glare,
                                                     CAShapeLayer *glareMask,
                                                     CAShapeLayer *perimeter,
                                                     CAGradientLayer *specular,
                                                     CAShapeLayer *specularMask) {
    glare.startPoint = CGPointMake(0, 0);
    glare.endPoint = CGPointMake(1, 1);
    glare.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.80].CGColor,
                     (id)[UIColor colorWithWhite:1 alpha:0.035].CGColor,
                     (id)[UIColor colorWithWhite:1 alpha:0.035].CGColor,
                     (id)[UIColor colorWithWhite:1 alpha:0.76].CGColor];
    glare.locations = @[@0, @0.46, @0.54, @1];
    glareMask.fillColor = nil;
    glareMask.strokeColor = UIColor.whiteColor.CGColor;
    glareMask.lineWidth = 0.58;
    glare.mask = glareMask;

    perimeter.fillColor = nil;
    perimeter.strokeColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    perimeter.lineWidth = 0.48;

    specular.startPoint = CGPointMake(0, 0);
    specular.endPoint = CGPointMake(1, 1);
    specular.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.30].CGColor,
                        (id)[UIColor colorWithWhite:1 alpha:0.008].CGColor,
                        (id)[UIColor colorWithWhite:1 alpha:0.008].CGColor,
                        (id)[UIColor colorWithWhite:1 alpha:0.28].CGColor];
    specular.locations = @[@0, @0.42, @0.58, @1];
    specularMask.fillColor = nil;
    specularMask.strokeColor = UIColor.whiteColor.CGColor;
    specularMask.lineWidth = 0.40;
    specular.mask = specularMask;
}

static inline void SGRLegacyLayoutDirectionalRim(CGRect bounds,
                                                  CAGradientLayer *glare,
                                                  CAShapeLayer *glareMask,
                                                  CAShapeLayer *perimeter,
                                                  CAGradientLayer *specular,
                                                  CAShapeLayer *specularMask) {
    CGRect strokeBounds = CGRectInset(bounds, 0.50, 0.50);
    CGPathRef path = [UIBezierPath bezierPathWithRoundedRect:strokeBounds
                                        cornerRadius:CGRectGetHeight(strokeBounds) / 2].CGPath;
    glare.frame = bounds;
    glareMask.frame = glare.bounds;
    glareMask.path = path;
    perimeter.frame = bounds;
    perimeter.path = path;
    specular.frame = bounds;
    specularMask.frame = specular.bounds;
    specularMask.path = path;
}
