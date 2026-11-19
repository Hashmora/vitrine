#import "TabBarLens.h"
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRGlass.h"
#import "Redesigned/Kit/SGRTokens.h"

static char kLensPaneKey, kLensFilmKey;

// The raised lens differs from the capsule: almost no blur or colour lift in
// the middle, slightly reduced backdrop scale, and most of the refraction in
// the specular rim. The icons stay legible in the centre like on iOS 26.
// Apple keeps the content subtly smaller behind the lifted lens. The custom
// mesh permits 0.92 for a measurable, local backdrop reduction.
static const CGFloat kLensMagnification = 0.92;
static const CGFloat kLensHeldBlur = 0.08, kLensRestBlur = 2;
static const CGFloat kLensHeldBend = 1.14;

// The held bubble is this much wider than the pill (and taller by 2 * heldOutset, so it stands out of the capsule's
// rim, as the system's does), and may be dragged this far past the first and the last tab.
static const CGFloat kLensGrow = 16, kLensOverscroll = 8;
// Optical glass, black base, selected-colour mask and inverse white cutout
// must share precisely one outline even when two adjacent icons fit inside it.
// The held lens keeps one width across the full tab row: no gap-dependent growth.
// The softer magnification and the closer item centers keep glyphs visible through it.
// Signed deformation: rightward motion spreads the bubble and lowers its height;
// leftward motion narrows it and raises its height. When the finger stops, a slow
// spring briefly reverses that shape before relaxing. A signed velocity (rather
// than its absolute value) is essential for the two directions to feel distinct.
static const CGFloat kLensStretchSpeed = 800, kLensDirectionalStretch = 0.115;
static const CGFloat kLensMaxDeform = 0.17, kLensVolume = 0.90, kLensMaxLag = 0.09;
// The surface tension: once the edges are near their targets, they pull each other back to the bubble's width, with
// a damper of their own, so a stretched bubble draws in and gives a small bounce rather than ringing. It is off
// while the bubble is chasing a finger (the stretch is what shows the chase), and fades in over the last
// kLensTensionReach points of the middle's distance.
static const CGFloat kLensTension = 150, kLensTensionRatio = 0.53, kLensTensionReach = 30;
// Slower body response than the moving edges: deceleration in either direction
// kicks the squash *opposite* to its moving shape, with a small damped rebound.
// Acceleration gives a much gentler kick so the lens does not jitter while dragged.
static const CGFloat kLensSquashOmega = 7.1, kLensSquashRatio = 0.54, kLensSquashKick = 0.0055;
static const CGFloat kLensPoke = 0.8;

typedef struct { CGFloat k, c; } SGRSpring;   // unit mass

static SGRSpring spring(CGFloat stiffness, CGFloat ratio) {
    return (SGRSpring){stiffness, 2 * ratio * sqrt(stiffness)};
}

static void stepEdge(CGFloat *x, CGFloat *v, CGFloat target, SGRSpring s, CGFloat dt) {
    CGFloat a = -s.k * (*x - target) - s.c * (*v);
    *v += a * dt;
    *x += *v * dt;
}

static CGFloat rubber(CGFloat x, CGFloat lo, CGFloat hi) {
    if (hi < lo) return x;
    if (x < lo) return lo - MIN(kLensOverscroll, (lo - x) * 0.3);
    if (x > hi) return hi + MIN(kLensOverscroll, (x - hi) * 0.3);
    return x;
}

// CADisplayLink keeps its target, so the lens is held weakly by this and can go away.
@class SGRLegacyLens;
@interface SGRLensLink : NSObject
@property (nonatomic, weak) SGRLegacyLens *lens;
@end

@interface SGRLegacyLens ()
- (void)tick:(CADisplayLink *)link;
@end


@implementation SGRLensLink
- (void)tick:(CADisplayLink *)link {
    SGRLegacyLens *lens = self.lens;
    if (lens) [lens tick:link]; else [link invalidate];
}
@end

typedef struct { CGFloat L, R, vL, vR, lift, vLift, sq, vSq; } SGLensSample;
static const CGFloat kPlayStep = 1.0 / 120;

@implementation SGRLegacyLens {
    UIView *_rest;
    UIView *_pane;
    UIView *_film;
    // The same diagonal, masked glass glare as SGGlassThumbView.
    // The capsule-shaped mask follows this view's exact bounds and transform;
    // it never draws an independent oversize white stroke.
    CAGradientLayer *_glare;
    CAShapeLayer *_glareMask;
    CAShapeLayer *_perimeter;
    __weak UIView *_restAbove;
    CADisplayLink *_link;
    // The two edges: where they are, how fast they go and where they are going.
    CGFloat _L, _R, _vL, _vR, _tL, _tR;
    CGFloat _lift, _vLift, _liftTarget;
    // The squash spring and the speed it last saw (see kLensSquashKick).
    CGFloat _sq, _vSq, _prevSpeed;
    CGFloat _minCenter, _maxCenter;
    CALayer *_tintMask;
    CAShapeLayer *_normalCutout;
    // Only the outward crescent is attenuated at Home/Create: otherwise the
    // lens samples and bends the *capsule's* outside border. No change to the
    // center of the lens or to the inward refracting edge.
    CAGradientLayer *_outerEdgeGuard;
    // The edge-only backdrop belongs to the SelectedContentView itself: the
    // sampled pixels and the accent glyphs share the same coordinate system.
    // The 0.92x platter lens remains a separate surface underneath the tabs.
    SGLegacyGlassView *_glyphEdgePane;
    CAGradientLayer *_glyphEdgeMask;
    // Independent refraction of the 0.92x platter; never samples glyphs.
    SGLegacyGlassView *_platterEdgePane;
    CAGradientLayer *_platterEdgeMask;
    BOOL _glassOn;
    NSUInteger _pulseGeneration;
    // A bubble nobody holds is not run frame by frame on the main thread, which a tab loading under it would stall
    // (the glass froze for as long as the page took). Its whole run is worked out at once and handed to Core
    // Animation as keyframes: the same springs, played where the main thread cannot hold them up.
    NSData *_playback;            // SGLensSample[]
    CFTimeInterval _playStart;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.opaque = NO;
    // A single rounded clip is shared by all optical sublayers; no glow or
    // backdrop may leak past the visible lifted bubble.
    self.clipsToBounds = YES;
    self.layer.cornerCurve = kCACornerCurveCircular;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _heldOutset = 8;
    _rest = [UIView new];
    // Apple's resting selection is lighter than its surrounding dark platter.
    _rest.backgroundColor = [UIColor colorWithWhite:1 alpha:0.17];
    _rest.layer.cornerCurve = kCACornerCurveCircular;
    [self addSubview:_rest];
    _pane = SGGlassFor(self, &kLensPaneKey);
    _pane.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [UIView performWithoutAnimation:^{ SGRShowGlass(self->_pane, NO); }];
    _film = SGRGlassFilm(self, &kLensFilmKey, _pane, 0);
    _film.alpha = 0;
    // No large white overlay: glass highlights are limited to thin curves.
    _film.backgroundColor = UIColor.clearColor;
    _film.userInteractionEnabled = NO;
    _glare = [CAGradientLayer layer];
    _glare.name = @"Vitrine.LegacyLensDynamicGlare";
    _glare.startPoint = CGPointMake(0, 0);
    _glare.endPoint = CGPointMake(1, 1);
    // Match the thumb's directional highlight, not a static opaque border.
    _glare.colors = @[(id)[UIColor colorWithWhite:1 alpha:1.00].CGColor,
                      (id)[UIColor colorWithWhite:1 alpha:0.075].CGColor,
                      (id)[UIColor colorWithWhite:1 alpha:0.075].CGColor,
                      (id)[UIColor colorWithWhite:1 alpha:0.88].CGColor];
    _glare.locations = @[@0, @0.32, @0.68, @1];
    _glareMask = [CAShapeLayer layer];
    _glareMask.fillColor = nil;
    _glareMask.strokeColor = UIColor.whiteColor.CGColor;
    _glareMask.lineWidth = 1.12;
    _glare.mask = _glareMask;
    _glare.opacity = 0;
    // Apple has a fine continuous edge PLUS a brighter directional streak.
    // The old diagonal gradient alone left two long sides almost black.
    _perimeter = [CAShapeLayer layer];
    _perimeter.name = @"Vitrine.LegacyLensFullPerimeter";
    _perimeter.fillColor = nil;
    _perimeter.strokeColor = [UIColor colorWithWhite:1 alpha:0.36].CGColor;
    _perimeter.lineWidth = 0.85;
    _perimeter.opacity = 0;
    _perimeter.zPosition = 2;
    [self.layer addSublayer:_perimeter];
    _glare.zPosition = 3;
    [self.layer addSublayer:_glare];
    return self;
}

- (BOOL)refracting { return _glassOn; }

- (void)dealloc {
    [_link invalidate];
}

static BOOL bubbles(void);

- (void)ensureGlyphEdgePane {
    UIView *host = self.superview;
    if (!host || !bubbles()) return;
    if (!_glyphEdgePane) {
        _glyphEdgePane = [SGLegacyGlassView new];
        _glyphEdgePane.accessibilityElementsHidden = YES;
        _glyphEdgePane.userInteractionEnabled = NO;
        _glyphEdgePane.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        _glyphEdgePane.clipsToBounds = YES;
        _glyphEdgePane.layer.cornerCurve = kCACornerCurveCircular;
        _glyphEdgePane.capsule = YES;
        _glyphEdgePane.clear = YES;
        _glyphEdgePane.blurRadius = 0.32;
        _glyphEdgePane.magnification = 1.0;  // icon geometry is not scaled
        _glyphEdgePane.lensScale = 1.04;
        _glyphEdgePane.lateralRefraction = YES;
        _glyphEdgePane.sharp = YES;
        _glyphEdgePane.rimless = YES;
        _glyphEdgePane.alpha = 0;
        _glyphEdgeMask = [CAGradientLayer layer];
        _glyphEdgeMask.startPoint = CGPointMake(0, 0.5);
        _glyphEdgeMask.endPoint = CGPointMake(1, 0.5);
        _glyphEdgeMask.locations = @[@0, @0.09, @0.23, @0.35, @0.65, @0.77, @0.91, @1];
        _glyphEdgePane.layer.mask = _glyphEdgeMask;
    }
    if (!_platterEdgePane) {
        // This pane is BELOW both glyph groups, but ABOVE the primary
        // magnified glass. It bends the reduced tab-bar surface itself.
        _platterEdgePane = [SGLegacyGlassView new];
        _platterEdgePane.userInteractionEnabled = NO;
        _platterEdgePane.accessibilityElementsHidden = YES;
        _platterEdgePane.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        _platterEdgePane.capsule = YES;
        _platterEdgePane.clear = YES;
        _platterEdgePane.blurRadius = 0.25;
        _platterEdgePane.magnification = 1.0;
        _platterEdgePane.lensScale = 1.12;
        _platterEdgePane.lateralRefraction = YES;
        _platterEdgePane.sharp = YES;
        _platterEdgePane.rimless = YES;
        _platterEdgePane.alpha = 0;
        _platterEdgePane.layer.zPosition = 0;
        _platterEdgeMask = [CAGradientLayer layer];
        _platterEdgeMask.startPoint = CGPointMake(0, 0.5);
        _platterEdgeMask.endPoint = CGPointMake(1, 0.5);
        _platterEdgeMask.locations = _glyphEdgeMask.locations;
        _platterEdgePane.layer.mask = _platterEdgeMask;
        [self addSubview:_platterEdgePane];
    }
    [self syncGlyphEdgeStack];
}

// The optical crescents must share a render coordinate system with the
// selected artwork. A separate host-level pane sampled a partly clipped copy
// and made an offset reflection of the icon instead of bending its own edge.
- (void)syncGlyphEdgeStack {
    UIView *host = self.superview;
    if (!_glyphEdgePane || !host) return;
    UIView *target = _tintOverlay.superview == host ? _tintOverlay : host;
    if (_glyphEdgePane.superview != target) [target addSubview:_glyphEdgePane];
    if (target.subviews.lastObject != _glyphEdgePane) [target bringSubviewToFront:_glyphEdgePane];
}

- (void)updateGlyphEdgeMaskLeft:(CGFloat)left right:(CGFloat)right {
    if (!_glyphEdgeMask) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _glyphEdgeMask.frame = _glyphEdgePane.bounds;
    NSArray *colors = @[
        (id)[UIColor colorWithWhite:1 alpha:left].CGColor,
        (id)[UIColor colorWithWhite:1 alpha:left * 0.88].CGColor,
        (id)[UIColor colorWithWhite:1 alpha:left * 0.16].CGColor,
        (id)[UIColor clearColor].CGColor,
        (id)[UIColor clearColor].CGColor,
        (id)[UIColor colorWithWhite:1 alpha:right * 0.16].CGColor,
        (id)[UIColor colorWithWhite:1 alpha:right * 0.88].CGColor,
        (id)[UIColor colorWithWhite:1 alpha:right].CGColor
    ];
    _glyphEdgeMask.colors = colors;
    _platterEdgeMask.colors = colors;
    [CATransaction commit];
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    // The overlay is a sibling of this lens. It must not survive a bar being
    // removed or moved to another host during a Spotify navigation rebuild.
    if (!self.superview) [_glyphEdgePane removeFromSuperview];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat radius = bounds.size.height / 2;
    self.layer.cornerRadius = radius;
    _rest.frame = bounds;
    _rest.layer.cornerRadius = radius;
    if (!CGRectEqualToRect(_pane.frame, bounds)) _pane.frame = bounds;
    SGShapeGlass(_pane, radius, YES);
    SGRGlassFilm(self, &kLensFilmKey, _pane, radius);
    // Preserve the capsule's real size. Only the optical content shrinks;
    // no relayout of the UITabBarButtons happens when the finger presses.
    _film.alpha = 0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _glare.frame = bounds;
    _glareMask.frame = _glare.bounds;
    CGRect pathBounds = CGRectInset(_glare.bounds, 0.5, 0.5);
    CGPathRef outline = [UIBezierPath bezierPathWithRoundedRect:pathBounds
                                           cornerRadius:CGRectGetHeight(pathBounds) / 2].CGPath;
    _glareMask.path = outline;
    _perimeter.frame = bounds;
    _perimeter.path = outline;
    if (_platterEdgePane) {
        _platterEdgePane.frame = bounds;
        _platterEdgePane.layer.cornerRadius = radius;
        _platterEdgeMask.frame = bounds;
    }
    if (_glyphEdgePane) {
        if (!CGRectEqualToRect(_glyphEdgePane.bounds, bounds)) _glyphEdgePane.bounds = bounds;
        _glyphEdgePane.layer.cornerRadius = radius;
        _glyphEdgeMask.frame = bounds;
    }
    [CATransaction commit];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [self stop];
        [self dropPlayback];
        _touching = NO;
        _lift = _vLift = _liftTarget = 0;
        [self showGlass:NO animated:NO];
        [self snapToRest];
        [_glyphEdgePane removeFromSuperview];
    }
}

#pragma mark - what the bar tells it

- (void)setRestFrame:(CGRect)frame animated:(BOOL)animated {
    BOOL first = CGRectIsEmpty(_restFrame);
    BOOL resized = !CGSizeEqualToSize(_restFrame.size, frame.size);
    _restFrame = frame;
    if (resized) {
        [UIView performWithoutAnimation:^{
            self.bounds = (CGRect){CGPointZero, frame.size};
            [self setNeedsLayout];
        }];
    }
    // A finger has the bubble; where it goes on release is read from the rest frame then.
    if (_touching && !resized) return;
    CGFloat left = CGRectGetMinX(frame), right = CGRectGetMaxX(frame);
    if (first || resized || !animated || SGRReduceMotion() || !self.window) {
        [self snapToRest];
        return;
    }
    [self takeOverPlayback];
    _tL = left;
    _tR = right;
    // A tap on another tab also raises the native lens briefly. The gesture
    // path owns the lens during a real drag and never uses this pulse.
    if (bubbles() && fabs((left + right - _L - _R) / 2) > 8 && !_touching) {
        NSUInteger pulse = ++_pulseGeneration;
        _lift = MAX(_lift, 1);
        _vLift = 0;
        _liftTarget = 0;
        [self showGlass:YES animated:NO];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf && strongSelf->_pulseGeneration == pulse && !strongSelf->_touching)
                [strongSelf showGlass:NO animated:YES];
        });
    }
    [self playToTargets];
}

// Whether a finger lifts the pill into the glass bubble. With the legacy glass off the bubble's pane is a plain dark blur,
// opaque, and held over the tabs it hid the icon under it: then the dark pill stays a pill, under the icons, and slides
// with the finger from tab to tab on the same springs, as it did before the bubble.
static BOOL bubbles(void) {
    return SGUseLegacyGlass();
}

// An inverted copy of the coloured lens mask clips *only* the white UITabBar
// while it is being refracted. Without it, the clear backdrop samples white
// glyphs underneath green glyphs and produces a white halo at the side rims.
// The tab's original contents return unmasked as soon as the lens drops.
- (void)setNormalContent:(UIView *)normalContent {
    if (_normalContent == normalContent) return;
    if (_normalContent.layer.mask == _normalCutout) _normalContent.layer.mask = nil;
    _normalContent = normalContent;
    if (!normalContent) { _normalCutout = nil; [self updateOuterEdgeGuard]; return; }
    if (!_normalCutout) {
        _normalCutout = [CAShapeLayer layer];
        _normalCutout.fillColor = UIColor.whiteColor.CGColor;
        _normalCutout.fillRule = kCAFillRuleEvenOdd;
    }
    [self updateNormalCutout];
    [self updateOuterEdgeGuard];
}

- (CGFloat)tintScaleXForState:(SGLensSample)st opticalScaleX:(CGFloat)sx {
    (void)st;
    // Both the inverse white mask and the accent must cover EXACTLY the
    // same geometry. The former 1.3% overdraw made a dark/green seam.
    return sx;
}

- (CGPathRef)newNormalCutoutPathAt:(CGPoint)center sx:(CGFloat)sx sy:(CGFloat)sy {
    UIView *bar = _normalContent;
    if (!bar || !self.superview) return nil;
    CGPoint inside = [self.superview convertPoint:center toView:bar];
    CGFloat width = self.bounds.size.width * sx;
    CGFloat height = self.bounds.size.height * sy;
    CGRect hole = CGRectMake(inside.x - width / 2, inside.y - height / 2, width, height);
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRect(path, NULL, bar.bounds);
    CGPathAddRoundedRect(path, NULL, hole, height / 2, height / 2);
    // Never restore a rectangular white Create region inside the lens.
    // Its exact live glyph is instead mirrored by the selected-color view.
    return path;
}

// Keep the outer edge of the floating capsule undistorted. At the first
// and last tabs the 116pt lifted lens slightly crosses the platter's edge;
// its outermost refraction would otherwise bend the capsule boundary.
// Suppress only the outward ~18% of the optical pane, progressively over
// the final 24pt of travel. The inner crescent remains fully refractive.
- (void)updateOuterEdgeGuard {
    UIView *bar = _normalContent;
    if (!_glassOn || !bar || !self.superview || CGRectIsEmpty(_restFrame)) {
        if (_pane.layer.mask == _outerEdgeGuard) _pane.layer.mask = nil;
        [self updateGlyphEdgeMaskLeft:1 right:1];
        return;
    }
    CGPoint center; CGFloat sx, sy;
    [self getPose:[self state] center:&center sx:&sx sy:&sy];
    CGRect barInHost = [bar convertRect:bar.bounds toView:self.superview];
    CGFloat halfWidth = self.bounds.size.width * sx / 2;
    // The first and last centers have about -4pt of external overlap on the
    // measured Apple layout. Leave a small border-safe band beyond that.
    CGFloat leftClearance = center.x - halfWidth - CGRectGetMinX(barInHost);
    CGFloat rightClearance = CGRectGetMaxX(barInHost) - center.x - halfWidth;
    // Preserve almost all of the outward optical band at both endpoints.
    // Stage 26 reduced these alphas to zero, so the scaled platter edge
    // appeared completely unbent at Home and Create.
    CGFloat leftAlpha = MAX(0.94, MIN(1, (leftClearance - 6) / 24));
    CGFloat rightAlpha = MAX(0.94, MIN(1, (rightClearance - 6) / 24));
    // Both the 0.92x platter lens and the 1x icon-edge lens obey the same
    // outer-edge guard at Home / Create.
    [self updateGlyphEdgeMaskLeft:leftAlpha right:rightAlpha];
    if (leftAlpha >= 0.999 && rightAlpha >= 0.999) {
        if (_pane.layer.mask == _outerEdgeGuard) _pane.layer.mask = nil;
        return;
    }
    if (!_outerEdgeGuard) {
        _outerEdgeGuard = [CAGradientLayer layer];
        _outerEdgeGuard.startPoint = CGPointMake(0, 0.5);
        _outerEdgeGuard.endPoint = CGPointMake(1, 0.5);
        _outerEdgeGuard.locations = @[@0, @0.22, @0.78, @1];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _outerEdgeGuard.frame = _pane.bounds;
    _outerEdgeGuard.colors = @[(id)[UIColor colorWithWhite:1 alpha:leftAlpha].CGColor,
                               (id)UIColor.whiteColor.CGColor,
                               (id)UIColor.whiteColor.CGColor,
                               (id)[UIColor colorWithWhite:1 alpha:rightAlpha].CGColor];
    if (_pane.layer.mask != _outerEdgeGuard) _pane.layer.mask = _outerEdgeGuard;
    [CATransaction commit];
}

- (void)updateNormalCutout {
    UIView *bar = _normalContent;
    if (!bar) return;
    if (!_glassOn || !self.superview || !self.tintOverlay || self.hidden) {
        if (bar.layer.mask == _normalCutout) bar.layer.mask = nil;
        return;
    }
    // Do not disturb UIKit-owned transition masks (such as compacting).
    if (bar.layer.mask && bar.layer.mask != _normalCutout) return;
    CGPoint center;
    CGFloat sx, sy;
    SGLensSample st = [self state];
    [self getPose:st center:&center sx:&sx sy:&sy];
    CGPathRef path = [self newNormalCutoutPathAt:center sx:sx sy:sy];
    if (!path) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _normalCutout.frame = bar.bounds;
    _normalCutout.path = path;
    bar.layer.mask = _normalCutout;
    [CATransaction commit];
    CGPathRelease(path);
}

// The mask is in the same host coordinates as the lens. Its *shape* follows both
// the moving spring and the layer keyframe playback after the finger is released.
- (void)setTintOverlay:(UIView *)tintOverlay {
    if (_tintOverlay == tintOverlay) {
        [self updateNormalCutout];
        if (tintOverlay) {
            [self syncGlyphEdgeStack];
            [self applyPose];
        }
        return;
    }
    _tintOverlay.layer.mask = nil;
    _tintOverlay = tintOverlay;
    if (!tintOverlay) { _tintMask = nil; [self syncGlyphEdgeStack]; [self updateNormalCutout]; return; }
    _tintMask = [CALayer layer];
    _tintMask.backgroundColor = UIColor.whiteColor.CGColor;
    _tintMask.cornerCurve = kCACornerCurveCircular;
    _tintMask.masksToBounds = YES;
    tintOverlay.layer.mask = _tintMask;
    [self syncGlyphEdgeStack];
    [self applyPose];
}

- (void)beginTouchAtX:(CGFloat)x minCenter:(CGFloat)minCenter maxCenter:(CGFloat)maxCenter {
    // Reduce Motion: the pill stays a pill and moves with the selection, as it did.
    if (CGRectIsEmpty(_restFrame) || self.hidden || SGRReduceMotion()) return;
    ++_pulseGeneration;
    [self takeOverPlayback];
    _touching = YES;
    _minCenter = minCenter;
    _maxCenter = maxCenter;
    if (bubbles()) {
        _liftTarget = 1;
        _vSq -= kLensPoke;
        [self showGlass:YES animated:YES];
    }
    [self moveTouchToX:x];
}

- (void)moveTouchToX:(CGFloat)x {
    if (!_touching) return;
    CGFloat center = rubber(x, _minCenter, _maxCenter);
    CGFloat width = _restFrame.size.width + (bubbles() ? kLensGrow : 0);
    _tL = center - width / 2;
    _tR = center + width / 2;
    [self start];
}

- (void)endTouch {
    if (!_touching) return;
    _touching = NO;
    _liftTarget = 0;
    _tL = CGRectGetMinX(_restFrame);
    _tR = CGRectGetMaxX(_restFrame);
    if (bubbles()) _vSq += kLensPoke * 0.6;
    // The glass goes back to the pill while the bubble is still on its way to the tab.
    [self showGlass:NO animated:YES];
    [self playToTargets];
}

- (void)flush {
    if (_playback) [CATransaction flush];
}

#pragma mark - look

// The bubble's glass and the pill trade places by effect and by alpha, never by an alpha over the glass
// (SGRShowGlass).
- (void)showGlass:(BOOL)on animated:(BOOL)animated {
    if (_glassOn == on) return;
    _glassOn = on;
    if (on) [self ensureGlyphEdgePane];
    // While raised, the pane must actually sit above the tab artwork: a
    // CABackdropLayer only refracts layers *behind* it. At rest it goes back
    // under the white icons and titles.
    [self standOverTabs:on];
    // The outer (glyph) pane must have the right geometry on the first held
    // frame, not only after the first CADisplayLink tick.
    if (on) [self applyPose];
    [self updateNormalCutout];
    [self updateOuterEdgeGuard];
    if ([_pane isKindOfClass:SGLegacyGlassView.class]) {
        SGLegacyGlassView *glass = (SGLegacyGlassView *)_pane;
        // The capsule has a coloured/darkened glass surface. The lens does not:
        // it samples an almost sharp backdrop with refraction confined to the rim.
        glass.clear = on;
        glass.magnification = on ? kLensMagnification : 1;
        glass.blurRadius = on ? kLensHeldBlur : kLensRestBlur;
        glass.lensScale = on ? kLensHeldBend : 1;
        glass.sharp = on;
        glass.rimless = on;
        glass.lateralRefraction = on;
    }
    void (^change)(void) = ^{
        SGRShowGlass(self->_pane, on);
        self->_film.alpha = 0;
        // Dark, nearly clear center against the darker tab platter; unlike
        // a white film, the side shading never washes out the green glyphs.
        self->_rest.alpha = on ? 0.12 : 1;
        self->_glare.opacity = on ? 1 : 0;
        self->_perimeter.opacity = on ? 1 : 0;
        // Do not refract white artwork again when Tabs in the accent is off.
        self->_glyphEdgePane.alpha = (on && self->_tintOverlay) ? 1 : 0;
        self->_platterEdgePane.alpha = on ? 1 : 0;
    };
    if (animated) SGRAnimate(on ? SGRMotionRespond : SGRMotionFade, change, nil);
    else [UIView performWithoutAnimation:change];
}

// The raised backdrop must include the tab icons and titles in its sample.
// Keep their true coordinates in the underlying bar, then return the resting
// pill to its original stacking order on release.
- (void)standOverTabs:(BOOL)over {
    UIView *host = self.superview;
    if (!host) return;
    if (over) {
        NSUInteger at = [host.subviews indexOfObject:self];
        if (at == NSNotFound) return;
        _restAbove = at + 1 < host.subviews.count ? host.subviews[at + 1] : nil;
        // The pane must sample the *platter*, not the tab glyphs. The
        // original bar and its selected-colour mirror stay ABOVE the optical
        // glass, so magnification and tint can only alter the capsule behind
        // the symbols. The inverse mask already hides white artwork inside
        // the selected region while the tinted group supplies sharp glyphs.
        [host bringSubviewToFront:self];
        if (_normalContent.superview == host) [host bringSubviewToFront:_normalContent];
        if (_tintOverlay.superview == host) [host bringSubviewToFront:_tintOverlay];
        // This separately masked edge-only pane samples the green artwork
        // with magnification 1; the whole 0.92x pane stays below the icons.
        [self syncGlyphEdgeStack];
    } else {
        UIView *above = _restAbove;
        _restAbove = nil;
        if (above.superview == host) [host insertSubview:self belowSubview:above];
        // The resting glass is a dark underlay; selected artwork remains sharp.
        if (_tintOverlay.superview == host) [host bringSubviewToFront:_tintOverlay];
    }
}

// Where the bubble is for the state it is in: the middle, and how wide and how tall it looks. Its size is fixed (the
// pill's); the look is a transform, so no frame of glass is laid out again while it moves.
- (void)getPose:(SGLensSample)st center:(CGPoint *)center sx:(CGFloat *)sx sy:(CGFloat *)sy {
    CGFloat baseWidth = MAX(1, self.bounds.size.width), baseHeight = MAX(1, self.bounds.size.height);
    CGFloat nominal = MAX(1, _restFrame.size.width + kLensGrow * st.lift);
    CGFloat width = MIN(MAX(baseHeight * 0.8, st.R - st.L), nominal * (1 + kLensMaxLag));
    CGFloat signedSpeed = (st.vL + st.vR) / 2;
    CGFloat stretch = kLensDirectionalStretch * tanh(signedSpeed / kLensStretchSpeed);
    // During ordinary taps the selection travels even after the finger lifts.
    // Carry the signed squash into that travel, rather than requiring a held
    // finger for the deformation to appear.
    CGFloat glide = MIN(0.7, fabs(signedSpeed) / 850 * 0.7);
    CGFloat motionWeight = MAX(MAX(0, st.lift), glide);
    CGFloat d = MAX(-kLensMaxDeform, MIN(kLensMaxDeform, (st.sq + stretch) * motionWeight));
    CGFloat held = 1 + 2 * _heldOutset / baseHeight * st.lift;
    *sx = width * (1 + d) / baseWidth;
    *sy = held * (1 - kLensVolume * d);
    *center = CGPointMake((st.L + st.R) / 2, CGRectGetMidY(_restFrame));
}

- (SGLensSample)state {
    return (SGLensSample){_L, _R, _vL, _vR, _lift, _vLift, _sq, _vSq};
}

// The tint mask belongs to a copy inside the UITabBar. Its position must
// use that bar's coordinates, not the surrounding host's coordinates.
- (CGPoint)tintPointForHostPoint:(CGPoint)point {
    if (!_tintOverlay || !self.superview) return point;
    return [self.superview convertPoint:point toView:_tintOverlay];
}

- (void)applyPose {
    if (CGRectIsEmpty(_restFrame)) return;
    CGPoint center;
    CGFloat sx, sy;
    [self getPose:[self state] center:&center sx:&sx sy:&sy];
    [UIView performWithoutAnimation:^{
        self.center = center;
        self.transform = CGAffineTransformMakeScale(sx, sy);
    }];
    // The glare follows the signed motion of the glass, just like the thumb's
    // moving light, rather than staying a fixed white outline on the screen.
    CGFloat motion = tanh((_vL + _vR) / 1800);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _glare.startPoint = CGPointMake(MAX(0, MIN(1, 0.10 + motion * 0.18)), 0);
    _glare.endPoint = CGPointMake(MAX(0, MIN(1, 0.90 + motion * 0.18)), 1);
    [CATransaction commit];
    if (_tintMask) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _tintMask.bounds = (CGRect){CGPointZero, self.bounds.size};
        _tintMask.cornerRadius = self.bounds.size.height / 2;
        _tintMask.position = [self tintPointForHostPoint:center];
        _tintMask.transform = CATransform3DMakeScale(
            [self tintScaleXForState:[self state] opticalScaleX:sx], sy, 1);
        [CATransaction commit];
    }
    if (_glyphEdgePane && _glyphEdgePane.superview) {
        UIView *edgeHost = _glyphEdgePane.superview;
        CGPoint edgeCenter = [self.superview convertPoint:center toView:edgeHost];
        [UIView performWithoutAnimation:^{
            if (!CGRectEqualToRect(self->_glyphEdgePane.bounds, self.bounds)) self->_glyphEdgePane.bounds = self.bounds;
            self->_glyphEdgePane.center = edgeCenter;
            self->_glyphEdgePane.transform = CGAffineTransformMakeScale(sx, sy);
        }];
    }
    [self updateNormalCutout];
    [self updateOuterEdgeGuard];
}

- (void)snapToRest {
    [self stop];
    [self dropPlayback];
    if (CGRectIsEmpty(_restFrame)) return;
    _L = _tL = CGRectGetMinX(_restFrame);
    _R = _tR = CGRectGetMaxX(_restFrame);
    _vL = _vR = 0;
    _sq = _vSq = _prevSpeed = 0;
    if (!_touching) _lift = _vLift = _liftTarget = 0;
    [self applyPose];
}

#pragma mark - springs

- (void)start {
    if (_link || !self.window) {
        if (!self.window) [self snapToRest];
        return;
    }
    SGRLensLink *proxy = [SGRLensLink new];
    proxy.lens = self;
    _link = [CADisplayLink displayLinkWithTarget:proxy selector:@selector(tick:)];
    // A link capped at 60 Hz would pull the player's 120 Hz transitions down with it (AGENTS.md).
    _link.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)stop {
    [_link invalidate];
    _link = nil;
}

// One step of the springs towards the targets. The edge in front of the move is the stiff one, the one behind it the
// loose one; standing still they are alike. How far the bubble stretches on the run is the difference of how far
// each edge trails a target going at speed v, (c / k) * v, so the stretch is the front being stiffer and better
// damped than the back: a stiffer, tighter front and a looser back draw a drop, while loosening or softening both
// only makes it wobble.
- (void)advance:(CGFloat)h {
    CGFloat dir = (_tL + _tR) / 2 - (_L + _R) / 2;
    BOOL moving = fabs(dir) > 0.75;
    // Slightly lazier travel for short and long taps; directional drag still
    // gets the tighter leading / softer trailing edge.
    SGRSpring front = spring(625, 0.83), back = spring(205, 0.72), even = spring(295, 0.78);
    SGRSpring forL = !moving ? even : (dir < 0 ? front : back);
    SGRSpring forR = !moving ? even : (dir > 0 ? front : back);
    SGSpring lift = _liftTarget > 0.5 ? SGGlassLiftOn : SGGlassLiftOff;   // the press's own
    // The edges' pull on each other, as a spring and a damper on the width (each edge takes half of the force, so
    // the damper is set for a pair of unit masses).
    CGFloat reach = MIN(1, MAX(0, 1 - fabs(dir) / kLensTensionReach));
    if (reach > 0) {
        CGFloat damper = kLensTensionRatio * sqrt(2 * kLensTension);
        CGFloat pull = reach * (kLensTension * ((_R - _L) - (_tR - _tL)) + damper * (_vR - _vL));
        _vL += pull * h;
        _vR -= pull * h;
    }
    stepEdge(&_L, &_vL, _tL, forL, h);
    stepEdge(&_R, &_vR, _tR, forR, h);
    // Keep the velocity signed: slowing to a stop from a rightward swipe produces
    // a taller rebound, and stopping a leftward swipe produces a flatter one.
    CGFloat signedSpeed = (_vL + _vR) / 2;
    CGFloat delta = signedSpeed - _prevSpeed;
    BOOL slowing = fabs(signedSpeed) < fabs(_prevSpeed);
    _vSq += kLensSquashKick * (slowing ? delta : delta * 0.28);
    _prevSpeed = signedSpeed;
    CGFloat sqa = -kLensSquashOmega * kLensSquashOmega * _sq - 2 * kLensSquashRatio * kLensSquashOmega * _vSq;
    _vSq += sqa * h;
    _sq = MAX(-kLensMaxDeform, MIN(kLensMaxDeform, _sq + _vSq * h));
    CGFloat a = (-lift.stiffness * (_lift - _liftTarget) - lift.damping * _vLift) / lift.mass;
    _vLift += a * h;
    _lift += _vLift * h;
}

- (BOOL)settled {
    return fabs(_L - _tL) < 0.1 && fabs(_R - _tR) < 0.1 && fabs(_vL) < 5 && fabs(_vR) < 5
        && fabs(_lift - _liftTarget) < 0.003 && fabs(_vLift) < 0.05 && fabs(_sq) < 0.002 && fabs(_vSq) < 0.05;
}

- (void)tick:(CADisplayLink *)link {
    CFTimeInterval dt = MIN(MAX(link.targetTimestamp - link.timestamp, 1.0 / 240), 1.0 / 30);
    int steps = dt > 1.0 / 90 ? 2 : 1;
    for (int i = 0; i < steps; i++) [self advance:dt / steps];
    [self applyPose];
    if ([self settled]) {
        _L = _tL;
        _R = _tR;
        _vL = _vR = _vLift = 0;
        _sq = _vSq = _prevSpeed = 0;
        _lift = _liftTarget;
        [self applyPose];
        [self stop];
    }
}

#pragma mark - playback

- (void)dropPlayback {
    if (!_playback) return;
    _playback = nil;
    [self.layer removeAnimationForKey:@"lens.x"];
    [self.layer removeAnimationForKey:@"lens.sx"];
    [self.layer removeAnimationForKey:@"lens.sy"];
    [_glyphEdgePane.layer removeAnimationForKey:@"lens.x"];
    [_glyphEdgePane.layer removeAnimationForKey:@"lens.sx"];
    [_glyphEdgePane.layer removeAnimationForKey:@"lens.sy"];
    [_tintMask removeAnimationForKey:@"lens.x"];
    [_tintMask removeAnimationForKey:@"lens.sx"];
    [_tintMask removeAnimationForKey:@"lens.sy"];
    [_normalCutout removeAnimationForKey:@"lens.cutout"];
}

// A finger down, or a new place to go, while a run is playing: the springs carry on from where the run is now.
- (void)takeOverPlayback {
    if (!_playback) return;
    NSUInteger count = _playback.length / sizeof(SGLensSample);
    NSUInteger index = MIN(count - 1, (NSUInteger)MAX(0, (CACurrentMediaTime() - _playStart) / kPlayStep));
    SGLensSample st = ((const SGLensSample *)_playback.bytes)[index];
    [self dropPlayback];
    _L = st.L; _R = st.R; _vL = st.vL; _vR = st.vR; _lift = st.lift; _vLift = st.vLift;
    _sq = st.sq; _vSq = st.vSq;
    _prevSpeed = (st.vL + st.vR) / 2;
    [self applyPose];
}

// Runs the springs from where they are to their targets without a display link, and plays the run on the layer.
- (void)playToTargets {
    [self stop];
    if (CGRectIsEmpty(_restFrame)) return;
    if (!self.window) {
        [self snapToRest];
        return;
    }
    NSMutableData *samples = [NSMutableData data];
    SGLensSample first = [self state];
    [samples appendBytes:&first length:sizeof(first)];
    // Settles inside a second and a half; the bound is for a spring that never would.
    for (int i = 0; i < 300 && ![self settled]; i++) {
        [self advance:kPlayStep];
        SGLensSample st = [self state];
        [samples appendBytes:&st length:sizeof(st)];
    }
    _L = _tL;
    _R = _tR;
    _vL = _vR = _vLift = 0;
    _sq = _vSq = _prevSpeed = 0;
    _lift = _liftTarget;
    SGLensSample last = [self state];
    [samples appendBytes:&last length:sizeof(last)];

    NSUInteger count = samples.length / sizeof(SGLensSample);
    const SGLensSample *all = samples.bytes;
    NSMutableArray<NSNumber *> *xs = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *sxs = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *sys = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *maskXs = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *maskSxs = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        CGPoint center;
        CGFloat sx, sy;
        [self getPose:all[i] center:&center sx:&sx sy:&sy];
        [xs addObject:@(center.x)];
        [maskXs addObject:@([self tintPointForHostPoint:center].x)];
        [maskSxs addObject:@([self tintScaleXForState:all[i] opticalScaleX:sx])];
        [sxs addObject:@(sx)];
        [sys addObject:@(sy)];
    }
    [self dropPlayback];
    // The model goes to where the run ends, so nothing jumps when the animations are done.
    [self applyPose];
    CFTimeInterval duration = (count - 1) * kPlayStep;
    void (^add)(NSString *, NSString *, NSArray *) = ^(NSString *key, NSString *path, NSArray *values) {
        CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:path];
        a.values = values;
        a.duration = duration;
        a.calculationMode = kCAAnimationLinear;
        [self.layer addAnimation:a forKey:key];
    };
    add(@"lens.x", @"position.x", xs);
    add(@"lens.sx", @"transform.scale.x", sxs);
    add(@"lens.sy", @"transform.scale.y", sys);
    // Stage 26 moved this pane INSIDE SelectedContentView. The old
    // equality check silently skipped its render-server release animation.
    if (_glyphEdgePane && _glyphEdgePane.superview && self.superview) {
        void (^edgeRun)(NSString *, NSString *, NSArray *) = ^(NSString *key, NSString *path, NSArray *values) {
            CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:path];
            a.values = values;
            a.duration = duration;
            a.calculationMode = kCAAnimationLinear;
            [self->_glyphEdgePane.layer addAnimation:a forKey:key];
        };
        NSMutableArray<NSNumber *> *edgeXs = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; i++) {
            CGPoint hostCenter;
            CGFloat xScale, yScale;
            [self getPose:all[i] center:&hostCenter sx:&xScale sy:&yScale];
            CGPoint localCenter = [self.superview convertPoint:hostCenter toView:self->_glyphEdgePane.superview];
            [edgeXs addObject:@(localCenter.x)];
        }
        edgeRun(@"lens.x", @"position.x", edgeXs);
        edgeRun(@"lens.sx", @"transform.scale.x", sxs);
        edgeRun(@"lens.sy", @"transform.scale.y", sys);
    }
    // Core Animation runs the released lens on the render server; match that
    // playback on the accent mask, instead of leaving the color behind at release.
    if (_tintMask) {
        void (^maskRun)(NSString *, NSString *, NSArray *) = ^(NSString *key, NSString *path, NSArray *values) {
            CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:path];
            a.values = values;
            a.duration = duration;
            a.calculationMode = kCAAnimationLinear;
            [_tintMask addAnimation:a forKey:key];
        };
        maskRun(@"lens.x", @"position.x", maskXs);
        maskRun(@"lens.sx", @"transform.scale.x", maskSxs);
        maskRun(@"lens.sy", @"transform.scale.y", sys);
    }
    // Keep the white cutout on the same render-server path as the green
    // selected group; otherwise a loading tab freezes the hole in the backdrop.
    if (_glassOn && _normalContent && _normalContent.layer.mask == _normalCutout) {
        NSMutableArray *paths = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; i++) {
            CGPoint center; CGFloat sx, sy;
            [self getPose:all[i] center:&center sx:&sx sy:&sy];
            CGPathRef path = [self newNormalCutoutPathAt:center sx:sx sy:sy];
            if (path) [paths addObject:CFBridgingRelease(path)];
        }
        if (paths.count == count) {
            CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:@"path"];
            animation.values = paths;
            animation.duration = duration;
            animation.calculationMode = kCAAnimationLinear;
            [_normalCutout addAnimation:animation forKey:@"lens.cutout"];
        }
    }
    _playback = samples;
    _playStart = CACurrentMediaTime();
}

@end
