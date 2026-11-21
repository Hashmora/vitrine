// Single directional specular profile for iOS < 26 Legacy Liquid Glass.
// The very same three strokes were first used on the compact leading circle:
// bright diagonal glare, fine perimeter and soft long specular.  The common
// SGLegacyGlassView material, films, tab lenses and host-backed compact circles
// all use this source of truth; refraction/blur are intentionally separate.
#pragma once
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

static inline void SGLegacyConfigureDirectionalRim(CAGradientLayer *glare,
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

static inline void SGLegacyLayoutDirectionalRim(CGRect bounds, CGFloat radius,
                                                 CAGradientLayer *glare,
                                                 CAShapeLayer *glareMask,
                                                 CAShapeLayer *perimeter,
                                                 CAGradientLayer *specular,
                                                 CAShapeLayer *specularMask) {
    CGRect strokeBounds = CGRectInset(bounds, 0.50, 0.50);
    CGFloat strokeRadius = MAX(0, MIN(radius - 0.5,
                                      MIN(CGRectGetWidth(strokeBounds), CGRectGetHeight(strokeBounds)) / 2));
    CGPathRef path = [UIBezierPath bezierPathWithRoundedRect:strokeBounds
                                               cornerRadius:strokeRadius].CGPath;
    glare.frame = bounds;
    glareMask.frame = glare.bounds;
    glareMask.path = path;
    perimeter.frame = bounds;
    perimeter.path = path;
    specular.frame = bounds;
    specularMask.frame = specular.bounds;
    specularMask.path = path;
}
