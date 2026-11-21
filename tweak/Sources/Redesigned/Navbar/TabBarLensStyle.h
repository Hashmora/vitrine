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

#import "Core/SGLegacyGlassRim.h"

static inline void SGRLegacyConfigureDirectionalRim(CAGradientLayer *glare,
                                                     CAShapeLayer *glareMask,
                                                     CAShapeLayer *perimeter,
                                                     CAGradientLayer *specular,
                                                     CAShapeLayer *specularMask) {
    SGLegacyConfigureDirectionalRim(glare, glareMask, perimeter, specular, specularMask);
}

static inline void SGRLegacyLayoutDirectionalRim(CGRect bounds,
                                                  CAGradientLayer *glare,
                                                  CAShapeLayer *glareMask,
                                                  CAShapeLayer *perimeter,
                                                  CAGradientLayer *specular,
                                                  CAShapeLayer *specularMask) {
    SGLegacyLayoutDirectionalRim(bounds, CGRectGetHeight(bounds) / 2,
                                 glare, glareMask, perimeter, specular, specularMask);
}
