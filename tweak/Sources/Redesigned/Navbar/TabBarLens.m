#import "TabBarLens.h"
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRGlass.h"
#import "Redesigned/Kit/SGRTokens.h"
#import <objc/runtime.h>

static char kLensGlyphDeghostKey;

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
static const CGFloat kLensGrow = 20, kLensOverscroll = 8;
// Keep the same 8pt optical limit on both outer ends.
static const CGFloat kLensLeftOverscroll = 8;
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
    if (x < lo) return lo - MIN(kLensLeftOverscroll, (lo - x) * 0.40);
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
// One immutable pose for a frame, projected once from the lens host into
// every optical sibling. The refraction shader, tint and inverse white mask
// must never independently convert the host center while the host is scaled.
typedef struct {
    CGPoint hostCenter;
    CGPoint tintCenter;
    CGPoint normalCenter;
    CGPoint glyphCenter;
    CGFloat sx, sy;
} SGLensGeometry;

@interface SGRLegacyLens (Geometry)
- (SGLensGeometry)geometryForSample:(SGLensSample)sample;
- (void)updateNormalCutoutWithGeometry:(SGLensGeometry)geometry;
- (void)updateOuterEdgeGuardWithGeometry:(SGLensGeometry)geometry;
@end

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
    // A sibling ABOVE the selected artwork. The glass itself stays behind
    // the glyphs for correct refraction, but the hairline reflection must not
    // be occluded by the tab bar's selected-content view.
    CALayer *_rimOverlay;
    CAGradientLayer *_longSpecular;
    CAShapeLayer *_specularMask;
    CAGradientLayer *_fingerHighlight;
    CGFloat _touchStartX, _touchAnchorX, _touchLastX;
    CFTimeInterval _touchDownTime;
    BOOL _needsQuickTapLift;
    NSUInteger _highlightGeneration;
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
    _glare.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.80].CGColor,
                      (id)[UIColor colorWithWhite:1 alpha:0.035].CGColor,
                      (id)[UIColor colorWithWhite:1 alpha:0.035].CGColor,
                      (id)[UIColor colorWithWhite:1 alpha:0.76].CGColor];
    // The opposite highlights taper along the capsule rather than stopping
    // at arbitrary hand-drawn horizontal segments.
    _glare.locations = @[@0, @0.46, @0.54, @1];
    _glareMask = [CAShapeLayer layer];
    _glareMask.fillColor = nil;
    _glareMask.strokeColor = UIColor.whiteColor.CGColor;
    _glareMask.lineWidth = 0.58;
    _glare.mask = _glareMask;
    _glare.opacity = 0;
    // Apple has a fine continuous edge PLUS a brighter directional streak.
    // The old diagonal gradient alone left two long sides almost black.
    _perimeter = [CAShapeLayer layer];
    _perimeter.name = @"Vitrine.LegacyLensFullPerimeter";
    _perimeter.fillColor = nil;
    _perimeter.strokeColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    _perimeter.lineWidth = 0.48;
    _perimeter.opacity = 0;
    _rimOverlay = [CALayer layer];
    _rimOverlay.name = @"Vitrine.LegacyLensAboveTabsRim";
    _rimOverlay.zPosition = 100;
    // The reflection remains above UIKit's artwork, but must not draw outside
    // the same capsule silhouette as the refracting glass.
    _rimOverlay.masksToBounds = YES;
    _rimOverlay.cornerCurve = kCACornerCurveCircular;
    [_rimOverlay addSublayer:_perimeter];
    [_rimOverlay addSublayer:_glare];
    // A second, narrower directional gradient on the EXACT SAME outline.
    // Unlike the old Bezier strokes, it cannot diverge from the glass shape.
    _longSpecular = [CAGradientLayer layer];
    _longSpecular.name = @"Vitrine.LegacyLensLongSpecular";
    _longSpecular.startPoint = CGPointMake(0, 0);
    _longSpecular.endPoint = CGPointMake(1, 1);
    _longSpecular.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.30].CGColor,
                             (id)[UIColor colorWithWhite:1 alpha:0.008].CGColor,
                             (id)[UIColor colorWithWhite:1 alpha:0.008].CGColor,
                             (id)[UIColor colorWithWhite:1 alpha:0.28].CGColor];
    _longSpecular.locations = @[@0, @0.42, @0.58, @1];
    _specularMask = [CAShapeLayer layer];
    _specularMask.fillColor = nil;
    _specularMask.strokeColor = UIColor.whiteColor.CGColor;
    _specularMask.lineWidth = 0.40;
    _longSpecular.mask = _specularMask;
    _longSpecular.opacity = 0;
    [_rimOverlay addSublayer:_longSpecular];
    // The press feedback follows the touch's highlighted state, as in
    // Telegram's GlassBarButtonComponent. Unlike its non-glass button scale,
    // this is a local luminance cue: the tab bar already animates its scale.
    _fingerHighlight = [CAGradientLayer layer];
    _fingerHighlight.name = @"Vitrine.LegacyLensFingerHighlight";
    _fingerHighlight.type = kCAGradientLayerRadial;
    _fingerHighlight.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.27].CGColor,
                                 (id)[UIColor colorWithWhite:1 alpha:0.10].CGColor,
                                 (id)UIColor.clearColor.CGColor];
    _fingerHighlight.locations = @[@0, @0.42, @1];
    _fingerHighlight.opacity = 0;
    _fingerHighlight.zPosition = 1;
    [self.layer addSublayer:_fingerHighlight];
    return self;
}

// Keep touch feedback independent of the lift spring. A quick tap can
// finish before the glass reaches full height; the light must still appear
// immediately and fade from its *current* value when the finger lifts.
- (void)setFingerHighlightPressed:(BOOL)pressed {
    ++_highlightGeneration;
    CGFloat from = _fingerHighlight.presentationLayer
        ? _fingerHighlight.presentationLayer.opacity : _fingerHighlight.opacity;
    CGFloat to = pressed ? 1.0 : 0.0;
    [_fingerHighlight removeAnimationForKey:@"vitrine.legacyFingerHighlight"];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fingerHighlight.opacity = to;
    [CATransaction commit];
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @(from);
    fade.toValue = @(to);
    fade.duration = pressed ? 0.065 : 0.14;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [_fingerHighlight addAnimation:fade forKey:@"vitrine.legacyFingerHighlight"];
}

- (BOOL)refracting { return _glassOn; }

- (void)dealloc {
    [_link invalidate];
}

static BOOL bubbles(void);

// The expanded tab-bar host animates its *sublayerTransform* (1.057x), not
// the individual views. UIKit convertPoint: from that host into one of its
// immediate children inverses the host scale, even though both the lens and
// the selected-content copy are siblings under the very same transform.
// As a result, nested glyph refraction and the tint/cutout masks drift towards
// the middle by (hostMidX - lensMidX) * (1 - 1/1.057) while pressed.
// For untransformed direct children, map their frame origins instead: this
// preserves the shared host coordinates and the same animation on every pane.
static CGPoint SGRLensPointInHostChild(UIView *host, UIView *child, CGPoint point) {
    if (!host || !child) return point;
    if (child.superview == host && CGAffineTransformIsIdentity(child.transform)) {
        return CGPointMake(point.x - CGRectGetMinX(child.frame) + CGRectGetMinX(child.bounds),
                           point.y - CGRectGetMinY(child.frame) + CGRectGetMinY(child.bounds));
    }
    return [host convertPoint:point toView:child];
}

// The UITabBar's bounds are not the rendered platter boundary. The visible
// capsule may be narrower or shifted while Spotify lays out the buttons.
// Sample its actual rectangle so refracting panes cannot see its outer rail.
static UIView *SGRLensPlatterInHost(UIView *host, UIView *fallback) {
    for (UIView *child in host.subviews)
        if ([child.accessibilityIdentifier isEqualToString:@"Vitrine.LegacyTabBarCapsule"])
            return child;
    return fallback;
}

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
        _glyphEdgePane.blurRadius = 0.16;
        _glyphEdgePane.magnification = 1.0;  // icon geometry is not scaled
        // Keep the rim sample close to the very same glyph. Excessive mesh
        // shift read like a separate offset / horizontally smeared green copy.
        _glyphEdgePane.lensScale = 0.86;
        _glyphEdgePane.lateralRefraction = YES;
        _glyphEdgePane.sharp = YES;
        _glyphEdgePane.rimless = YES;
        _glyphEdgePane.alpha = 0;
        _glyphEdgeMask = [CAGradientLayer layer];
        _glyphEdgeMask.masksToBounds = YES;
        _glyphEdgeMask.cornerCurve = kCACornerCurveCircular;
        _glyphEdgeMask.startPoint = CGPointMake(0, 0.5);
        _glyphEdgeMask.endPoint = CGPointMake(1, 0.5);
        // Replace the source pixels at the boundary with the actual backdrop
        // sample, fading to a clear aperture before reaching the glyph's
        // central strokes. A faint outer sample made two green outlines.
        _glyphEdgeMask.locations = @[@0, @0.09, @0.19, @0.25, @0.75, @0.81, @0.91, @1];
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
        _platterEdgePane.blurRadius = 0.48;
        _platterEdgePane.magnification = 1.0;
        _platterEdgePane.lensScale = 1.06;
        _platterEdgePane.lateralRefraction = YES;
        // Reach the top and bottom edges of the already reduced platter
        // without distorting the icons or the full-length straight rails.
        _platterEdgePane.lateralVerticalReach = 0.32;
        _platterEdgePane.sharp = YES;
        _platterEdgePane.rimless = YES;
        _platterEdgePane.alpha = 0;
        _platterEdgePane.layer.zPosition = 0;
        _platterEdgeMask = [CAGradientLayer layer];
        _platterEdgeMask.masksToBounds = YES;
        _platterEdgeMask.cornerCurve = kCACornerCurveCircular;
        _platterEdgeMask.startPoint = CGPointMake(0, 0.5);
        _platterEdgeMask.endPoint = CGPointMake(1, 0.5);
        // The reduced platter has a broader edge than individual glyphs.
        // Its refraction stays wide even when glyph reflection is narrowed.
        _platterEdgeMask.locations = @[@0, @0.10, @0.25, @0.39, @0.61, @0.75, @0.90, @1];
        _platterEdgePane.layer.mask = _platterEdgeMask;
        // Host-level sibling: inside the lifted lens the backdrop sampled
        // its own composite, not the 0.92x capsule in the actual tab host.
        // A sibling just above the main lens sees the reduced platter below
        // it, while remaining below the ordinary and accent glyph groups.
    }
    [self syncGlyphEdgeStack];
}

// The optical crescents must share a render coordinate system with the
// selected artwork. A separate host-level pane sampled a partly clipped copy
// and made an offset reflection of the icon instead of bending its own edge.
- (void)syncGlyphEdgeStack {
    UIView *host = self.superview;
    if (!host) return;
    if (_platterEdgePane) {
        // UIKit may reorder siblings on late tab layout: restore the optical
        // sibling between the main scaled glass and both glyph groups.
        [host insertSubview:_platterEdgePane aboveSubview:self];
    }
    if (!_glyphEdgePane) return;
    // This edge-only refractor samples green selected glyphs, so it must be
    // clipped by the SAME animated mask as those glyphs. A host-level fallback
    // is not safe: it bypasses SelectedContentView's live capsule mask and
    // exposes displaced green pixels outside the bubble at the end tabs.
    UIView *target = (_tintOverlay && _tintOverlay.superview == host) ? _tintOverlay : nil;
    if (!target) {
        [_glyphEdgePane removeFromSuperview];
        return;
    }
    if (_glyphEdgePane.superview != target) [target addSubview:_glyphEdgePane];
    if (target.subviews.lastObject != _glyphEdgePane) [target bringSubviewToFront:_glyphEdgePane];
}

// There is ONE green UIImageView for each tab. The rim backdrop bends pixels
// sampled from that exact view, but those original pixels must not also remain
// fully opaque directly under the bent rim; otherwise the icon appears twice.
// Attenuate ONLY the static pixels where a moving side crescent overlaps a
// glyph. The unbent centre is unchanged, and the source is restored at rest.
- (void)clearGlyphSourceMasks {
    for (UIView *view in _tintOverlay.subviews) {
        if (![view isKindOfClass:UIImageView.class]) continue;
        CALayer *mask = objc_getAssociatedObject(view, &kLensGlyphDeghostKey);
        if (mask && view.layer.mask == mask) view.layer.mask = nil;
    }
}

// Do not punch transparent slots into the ONLY sharp accent glyph.  The
// earlier de-ghost gradient darkened a 6pt strip of that very glyph to 8%
// opacity; the black "seam" was this mask, not an Apple refraction edge.
// The opaque portions of the edge-only backdrop now replace, rather than
// erase, those pixels; its central aperture leaves the sharp glyph intact.
- (void)updateGlyphSourceMasksAt:(CGPoint)center sx:(CGFloat)sx {
    (void)center;
    (void)sx;
    [self clearGlyphSourceMasks];
}

- (void)updateGlyphEdgeMaskLeft:(CGFloat)left right:(CGFloat)right {
    if (!_glyphEdgeMask) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _glyphEdgeMask.frame = _glyphEdgePane.bounds;
    _glyphEdgeMask.cornerRadius = CGRectGetHeight(_glyphEdgePane.bounds) / 2;
    _platterEdgeMask.frame = _platterEdgePane.bounds;
    _platterEdgeMask.cornerRadius = CGRectGetHeight(_platterEdgePane.bounds) / 2;
    NSArray *colors = @[
        (id)[UIColor colorWithWhite:1 alpha:left].CGColor,
        (id)[UIColor colorWithWhite:1 alpha:left].CGColor,
        (id)[UIColor colorWithWhite:1 alpha:left * 0.55].CGColor,
        (id)[UIColor clearColor].CGColor,
        (id)[UIColor clearColor].CGColor,
        (id)[UIColor colorWithWhite:1 alpha:right * 0.55].CGColor,
        (id)[UIColor colorWithWhite:1 alpha:right].CGColor,
        (id)[UIColor colorWithWhite:1 alpha:right].CGColor
    ];
    _glyphEdgeMask.colors = colors;
    _platterEdgeMask.colors = colors;
    [CATransaction commit];
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    // Keep the *reflection* above the UIKit icon groups. Its geometry is
    // synced separately, but its mask uses the exact same local lens path.
    [_rimOverlay removeFromSuperlayer];
    if (self.superview) [self.superview.layer addSublayer:_rimOverlay];
    [self applyPose];
    // The overlay is a sibling of this lens. It must not survive a bar being
    // removed or moved to another host during a Spotify navigation rebuild.
    if (!self.superview) {
        [_glyphEdgePane removeFromSuperview];
        [_platterEdgePane removeFromSuperview];
    }
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
    // One shared optical outline: all three components sit at the same
    // radius as the glass's capsule, inset only half a pixel to retain the
    // antialiasing inside the edge. There is NO independent white stripe.
    CGRect pathBounds = CGRectInset(bounds, 0.50, 0.50);
    UIBezierPath *opticalPath = [UIBezierPath bezierPathWithRoundedRect:pathBounds
                                            cornerRadius:CGRectGetHeight(pathBounds) / 2];
    CGPathRef outline = opticalPath.CGPath;
    _rimOverlay.bounds = bounds;
    _rimOverlay.cornerRadius = radius;
    _glareMask.path = outline;
    _perimeter.frame = bounds;
    _perimeter.path = outline;
    _longSpecular.frame = bounds;
    _specularMask.frame = bounds;
    _specularMask.path = outline;
    _fingerHighlight.frame = bounds;
    if (_platterEdgePane) {
        if (!CGRectEqualToRect(_platterEdgePane.bounds, bounds)) _platterEdgePane.bounds = bounds;
        _platterEdgePane.layer.cornerRadius = radius;
        _platterEdgeMask.frame = bounds;
        _platterEdgeMask.cornerRadius = radius;
    }
    if (_glyphEdgePane) {
        if (!CGRectEqualToRect(_glyphEdgePane.bounds, bounds)) _glyphEdgePane.bounds = bounds;
        _glyphEdgePane.layer.cornerRadius = radius;
        _glyphEdgeMask.frame = bounds;
        _glyphEdgeMask.cornerRadius = radius;
    }
    [CATransaction commit];
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    _rimOverlay.hidden = hidden;
}

- (void)setAlpha:(CGFloat)alpha {
    [super setAlpha:alpha];
    // This rim is a host sibling, so UIView alpha does not propagate to it.
    // Mirror invisibility during navbar compacting and page transitions.
    _rimOverlay.opacity = alpha;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) [self applyPose];
    if (!self.window) {
        [self stop];
        [self dropPlayback];
        _touching = NO;
        [_fingerHighlight removeAnimationForKey:@"vitrine.legacyFingerHighlight"];
        _fingerHighlight.opacity = 0;
        _lift = _vLift = _liftTarget = 0;
        [self showGlass:NO animated:NO];
        [self snapToRest];
        [_glyphEdgePane removeFromSuperview];
        [_platterEdgePane removeFromSuperview];
    }
}

#pragma mark - what the bar tells it

// The landing is a *pose* event, not the end of the spring's residual
// velocity. In particular, the squash spring can keep ringing imperceptibly
// after the glass is back over the resting tab. Hold until the post-peak pose
// is in the slot, then schedule the material swap for that sample time.
- (void)dropGlassAfterPlayback {
    if (!_glassOn || _touching || _liftTarget > 0.001) return;
    NSUInteger generation = _pulseGeneration;
    NSUInteger count = _playback.length / sizeof(SGLensSample);
    const SGLensSample *samples = _playback.bytes;
    NSTimeInterval duration = count > 1 ? (count - 1) * kPlayStep : 0.10;
    if (count > 1) {
        // Quick taps can still be ascending after touch-up. Never drop the
        // lens until *after* its maximum height in the precomputed playback.
        NSUInteger peak = 0;
        for (NSUInteger i = 1; i < count; i++) {
            if (samples[i].lift > samples[peak].lift) peak = i;
        }
        CGPoint finalCenter;
        CGFloat finalSX, finalSY;
        [self getPose:samples[count - 1] center:&finalCenter sx:&finalSX sy:&finalSY];
        CGFloat baseWidth = MAX(1, CGRectGetWidth(self.bounds));
        CGFloat baseHeight = MAX(1, CGRectGetHeight(self.bounds));
        for (NSUInteger i = peak + 1; i < count; i++) {
            CGPoint center;
            CGFloat sx, sy;
            [self getPose:samples[i] center:&center sx:&sx sy:&sy];
            // The substrate must already have reached its full opacity by
            // the time we retire the glass. Do not cut away the material while
            // it is still visibly raised, even if the X spring has arrived.
            if (samples[i].lift > 0.08) continue;
            // Screen-visible position, width and height, not raw spring
            // velocities. Ignore tiny oscillations after the visual landing.
            if (fabs(center.x - finalCenter.x) > 1.5 ||
                fabs(sx - finalSX) * baseWidth > 1.7 ||
                fabs(sy - finalSY) * baseHeight > 1.5) continue;
            // Confirm two subsequent frames also stay in the slot to avoid
            // a premature swap during a transient overshoot.
            BOOL staysDocked = YES;
            for (NSUInteger j = i + 1; j < MIN(count, i + 3); j++) {
                CGPoint nextCenter;
                CGFloat nextSX, nextSY;
                [self getPose:samples[j] center:&nextCenter sx:&nextSX sy:&nextSY];
                if (fabs(nextCenter.x - finalCenter.x) > 1.5 ||
                    fabs(nextSX - finalSX) * baseWidth > 1.7 ||
                    fabs(nextSY - finalSY) * baseHeight > 1.5) {
                    staysDocked = NO;
                    break;
                }
            }
            if (!staysDocked) continue;
            duration = i * kPlayStep;
            break;
        }
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_pulseGeneration != generation || strongSelf->_touching ||
            strongSelf->_liftTarget > 0.001) return;
        // Retire only the glass material. Do NOT cancel the render-server
        // spring: its remaining directional shape belongs to the pale
        // underlay as well. Cancelling lens.x/sx/sy here was the visible snap
        // from moving bubble to static selection; the model is already at rest
        // and the playback finishes on its own.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [strongSelf showGlass:NO animated:NO];
        [CATransaction commit];
    });
    // Let the substrate finish the *same* keyframed spring before removing
    // animations. A new finger/selection increments generation and owns it.
    NSTimeInterval finishAt = MAX(duration, (count > 1 ? (count - 1) * kPlayStep : duration));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((finishAt + kPlayStep) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_pulseGeneration != generation || strongSelf->_touching) return;
        [strongSelf dropPlayback];
        [strongSelf applyPose];
    });
}

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
    ++_pulseGeneration; // invalidate any previous material-drop timer
    _tL = left;
    _tR = right;
    // A programmatic / non-held tab change gets the SAME full up-and-down
    // pulse as a short touch. Previously forcing lift=1 jumped instantly to
    // the raised height and skipped the visible rising half of the gesture.
    if (bubbles() && fabs((left + right - _L - _R) / 2) > 8 && !_touching) {
        _needsQuickTapLift = YES;
        _liftTarget = 0;
        [self showGlass:YES animated:NO];
    }
    [self playToTargets];
    [self dropGlassAfterPlayback];
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

- (CGPathRef)newNormalCutoutPathForGeometry:(SGLensGeometry)geometry {
    UIView *bar = _normalContent;
    if (!bar || !self.superview) return nil;
    CGFloat width = self.bounds.size.width * geometry.sx;
    CGFloat height = self.bounds.size.height * geometry.sy;
    CGRect hole = CGRectMake(geometry.normalCenter.x - width / 2,
                             geometry.normalCenter.y - height / 2, width, height);
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
// Suppress the outward sampling band before the shader reaches the platter
// rail. The center and internal tab boundaries retain their refraction.
- (void)updateOuterEdgeGuard {
    SGLensGeometry geometry = {0};
    if (self.superview && !CGRectIsEmpty(_restFrame))
        geometry = [self geometryForSample:[self state]];
    [self updateOuterEdgeGuardWithGeometry:geometry];
}

- (void)updateOuterEdgeGuardWithGeometry:(SGLensGeometry)geometry {
    UIView *bar = SGRLensPlatterInHost(self.superview, _normalContent);
    if (!_glassOn || !bar || !self.superview || CGRectIsEmpty(_restFrame)) {
        if (_pane.layer.mask == _outerEdgeGuard) _pane.layer.mask = nil;
        [self updateGlyphEdgeMaskLeft:1 right:1];
        return;
    }
    CGRect barInHost = [bar convertRect:bar.bounds toView:self.superview];
    CGFloat halfWidth = self.bounds.size.width * geometry.sx / 2;
    // Clearances are measured from the rendered capsule, not UITabBar bounds;
    // the two can differ during layout and at the edge tabs.
    CGFloat leftClearance = geometry.hostCenter.x - halfWidth - CGRectGetMinX(barInHost);
    CGFloat rightClearance = CGRectGetMaxX(barInHost) - geometry.hostCenter.x - halfWidth;
    // Protect only whichever outward end approaches the capsule rail.
    // Interior tab boundaries still use the normal refraction strength.
    // The shader samples beyond the visible edge. Leave a protected band
    // before the outer rail, then fade into the undistorted center. This also
    // gates the icon-sampling pane: no displaced icon can protrude past the rim.
    // Internal tab boundaries retain their refraction.
    CGFloat leftAlpha = MAX(0, MIN(1, (leftClearance - 20) / 18));
    CGFloat rightAlpha = MAX(0, MIN(1, (rightClearance - 20) / 18));
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
        _outerEdgeGuard.masksToBounds = YES;
        _outerEdgeGuard.cornerCurve = kCACornerCurveCircular;
        // Hold the outward edge clear before the refraction blend begins.
        _outerEdgeGuard.locations = @[@0, @0.13, @0.35, @0.65, @0.87, @1];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _outerEdgeGuard.frame = _pane.bounds;
    _outerEdgeGuard.cornerRadius = CGRectGetHeight(_pane.bounds) / 2;
    _outerEdgeGuard.colors = @[(id)[UIColor colorWithWhite:1 alpha:leftAlpha].CGColor,
                               (id)[UIColor colorWithWhite:1 alpha:leftAlpha].CGColor,
                               (id)UIColor.whiteColor.CGColor,
                               (id)UIColor.whiteColor.CGColor,
                               (id)[UIColor colorWithWhite:1 alpha:rightAlpha].CGColor,
                               (id)[UIColor colorWithWhite:1 alpha:rightAlpha].CGColor];
    if (_pane.layer.mask != _outerEdgeGuard) _pane.layer.mask = _outerEdgeGuard;
    [CATransaction commit];
}

- (void)updateNormalCutout {
    SGLensGeometry geometry = {0};
    if (self.superview && !CGRectIsEmpty(_restFrame))
        geometry = [self geometryForSample:[self state]];
    [self updateNormalCutoutWithGeometry:geometry];
}

- (void)updateNormalCutoutWithGeometry:(SGLensGeometry)geometry {
    UIView *bar = _normalContent;
    if (!bar) return;
    if (!_glassOn || !self.superview || !self.tintOverlay || self.hidden || CGRectIsEmpty(_restFrame)) {
        if (bar.layer.mask == _normalCutout) bar.layer.mask = nil;
        return;
    }
    // Do not disturb UIKit-owned transition masks (such as compacting).
    if (bar.layer.mask && bar.layer.mask != _normalCutout) return;
    CGPathRef path = [self newNormalCutoutPathForGeometry:geometry];
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
    [self clearGlyphSourceMasks];
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
    // The first lifted frame is over the ICON CENTER, not the off-center
    // landing position. Only the subsequent horizontal finger delta moves it.
    _touchStartX = x;
    _touchLastX = x;
    _touchDownTime = CACurrentMediaTime();
    _touchAnchorX = CGRectGetMidX(_restFrame);
    if (bubbles()) {
        _liftTarget = 1;
        _vSq -= kLensPoke;
        // A tap may last less than the material fade. Show glass immediately;
        // the physical height is still animated by the lens spring.
        [self showGlass:YES animated:NO];
    }
    [self moveTouchToX:x];
    // Touch-down drives the local highlight directly, rather than waiting
    // for the lifted-lens spring to reach a visible fraction of its height.
    [self applyPose];
    [self setFingerHighlightPressed:bubbles()];
}

// The recognizer and the glass MUST choose a hovered tab using the same
// anchored position. With off-centre touches, raw finger X can cross an item
// boundary while the bubble is still over the previous item's glyph.
- (CGFloat)trackingCenterForFingerX:(CGFloat)x {
    if (!_touching) return x;
    return rubber(_touchAnchorX + (x - _touchStartX), _minCenter, _maxCenter);
}

- (void)moveTouchToX:(CGFloat)x {
    if (!_touching) return;
    _touchLastX = x;
    CGFloat center = [self trackingCenterForFingerX:x];
    CGFloat width = _restFrame.size.width + (bubbles() ? kLensGrow : 0);
    _tL = center - width / 2;
    _tR = center + width / 2;
    [self start];
}

- (void)endTouch {
    if (!_touching) return;
    // A quick tap can end before the 120Hz link has drawn even one lifted
    // frame. Continue the press spring up to its full height in render-server
    // keyframes, THEN release it, instead of cancelling the rise at touch-up.
    BOOL quickTap = bubbles() && !SGRReduceMotion() &&
        CACurrentMediaTime() - _touchDownTime < 0.18 && _lift < 0.96;
    _touching = NO;
    if (quickTap) {
        NSUInteger generation = _highlightGeneration;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.13 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_touching ||
                strongSelf->_highlightGeneration != generation) return;
            [strongSelf setFingerHighlightPressed:NO];
        });
    } else {
        [self setFingerHighlightPressed:NO];
    }
    ++_pulseGeneration;
    _needsQuickTapLift = quickTap;
    _liftTarget = 0;
    _tL = CGRectGetMinX(_restFrame);
    _tR = CGRectGetMaxX(_restFrame);
    if (bubbles()) _vSq += kLensPoke * 0.6;
    // Keep the clear material above the glyphs until the return spring has
    // reached its target. Early cross-fade exposed the white resting pill
    // through the raised lens and caused the release flash.
    [self playToTargets];
    [self dropGlassAfterPlayback];
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
        // The raised lens draws its own directional rim. The resting pill
        // uses _rest, not the default SGLegacyGlass specular. Re-enabling
        // that extra rim while the pane is disappearing can expose a bright
        // ring exactly during the glass-to-platter handoff.
        glass.rimless = YES;
        glass.lateralRefraction = on;
        glass.lateralVerticalReach = on ? 0.24 : 0;
    }
    void (^change)(void) = ^{
        SGRShowGlass(self->_pane, on);
        self->_film.alpha = 0;
        // Dark, nearly clear center against the darker tab platter; unlike
        // a white film, the side shading never washes out the green glyphs.
        self->_rest.alpha = on ? 0.12 : 1;
        self->_glare.opacity = on ? 1 : 0;
        self->_perimeter.opacity = on ? 1 : 0;
        self->_longSpecular.opacity = on ? 1 : 0;
        // Do not refract white artwork again when Tabs in the accent is off.
        self->_glyphEdgePane.alpha = (on && self->_tintOverlay) ? 1 : 0;
        self->_platterEdgePane.alpha = on ? 1 : 0;
    };
    if (!on) [self clearGlyphSourceMasks];
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
    CGPoint pose = CGPointMake((st.L + st.R) / 2, CGRectGetMidY(_restFrame));
    // Never move the lens outwards merely because an edge tab was pressed.
    // Its center comes from the finger/selection springs. Only cap an actual
    // excursion to the existing 8pt drag allowance, accounting for its size.
    if (st.lift > 0.001 && _normalContent && self.superview) {
        UIView *surface = SGRLensPlatterInHost(self.superview, _normalContent);
        CGRect platter = [surface convertRect:surface.bounds toView:self.superview];
        CGFloat half = baseWidth * *sx / 2;
        CGFloat minX = CGRectGetMinX(platter) - kLensLeftOverscroll + half;
        CGFloat maxX = CGRectGetMaxX(platter) + kLensOverscroll - half;
        if (maxX >= minX) pose.x = MAX(minX, MIN(maxX, pose.x));
    }
    *center = pose;
}

- (SGLensSample)state {
    return (SGLensSample){_L, _R, _vL, _vR, _lift, _vLift, _sq, _vSq};
}

// Only this function projects a spring pose into the host's optical children.
// Both the interactive CADisplayLink and render-server release keyframes
// consume these exact values. The geometry is a value, never a live layer.
- (SGLensGeometry)geometryForSample:(SGLensSample)sample {
    SGLensGeometry geometry = {0};
    [self getPose:sample center:&geometry.hostCenter sx:&geometry.sx sy:&geometry.sy];
    UIView *host = self.superview;
    geometry.tintCenter = SGRLensPointInHostChild(host, _tintOverlay, geometry.hostCenter);
    geometry.normalCenter = SGRLensPointInHostChild(host, _normalContent, geometry.hostCenter);
    geometry.glyphCenter = SGRLensPointInHostChild(host, _glyphEdgePane.superview, geometry.hostCenter);
    return geometry;
}

- (void)applyPose {
    if (CGRectIsEmpty(_restFrame)) return;
    SGLensGeometry geometry = [self geometryForSample:[self state]];
    CGPoint center = geometry.hostCenter;
    CGFloat sx = geometry.sx, sy = geometry.sy;
    [UIView performWithoutAnimation:^{
        self.center = center;
        self.transform = CGAffineTransformMakeScale(sx, sy);
    }];
    // Same pose as the glass, but over UIKit's selected-content masks.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _rimOverlay.position = center;
    _rimOverlay.transform = CATransform3DMakeScale(sx, sy, 1);
    _rimOverlay.hidden = self.hidden;
    [CATransaction commit];
    // The glare follows the signed motion of the glass, just like the thumb's
    // moving light, rather than staying a fixed white outline on the screen.
    CGFloat motion = tanh((_vL + _vR) / 1800);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _glare.startPoint = CGPointMake(MAX(0, MIN(1, 0.10 + motion * 0.18)), 0);
    _glare.endPoint = CGPointMake(MAX(0, MIN(1, 0.90 + motion * 0.18)), 1);
    [CATransaction commit];
    // The patch follows the actual finger rather than the lens's lagged
    // spring center. Its brightness is local and never persists at rest.
    if (_touching) {
        CGFloat localX = self.bounds.size.width / 2 + (_touchLastX - center.x) / MAX(0.1, sx);
        CGFloat unitX = MAX(0.15, MIN(0.85, localX / MAX(1, self.bounds.size.width)));
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _fingerHighlight.startPoint = CGPointMake(unitX, 0.5);
        // Narrow enough to be a local fingertip reflection, not a washed-out
        // white film across the lifted glass.
        _fingerHighlight.endPoint = CGPointMake(unitX + 0.23, 0.5);
        [CATransaction commit];
    }
    // Opacity is owned solely by setFingerHighlightPressed: display-link
    // frames must not override the touch-down / touch-up animation.
    [self updateGlyphSourceMasksAt:center sx:sx];
    if (_tintMask) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _tintMask.bounds = (CGRect){CGPointZero, self.bounds.size};
        _tintMask.cornerRadius = self.bounds.size.height / 2;
        _tintMask.position = geometry.tintCenter;
        _tintMask.transform = CATransform3DMakeScale(sx, sy, 1);
        [CATransaction commit];
    }
    if (_platterEdgePane && _platterEdgePane.superview) {
        [UIView performWithoutAnimation:^{
            if (!CGRectEqualToRect(self->_platterEdgePane.bounds, self.bounds)) self->_platterEdgePane.bounds = self.bounds;
            self->_platterEdgePane.center = center;
            self->_platterEdgePane.transform = CGAffineTransformMakeScale(sx, sy);
        }];
    }
    if (_glyphEdgePane && _glyphEdgePane.superview) {
        CGPoint edgeCenter = geometry.glyphCenter;
        [UIView performWithoutAnimation:^{
            if (!CGRectEqualToRect(self->_glyphEdgePane.bounds, self.bounds)) self->_glyphEdgePane.bounds = self.bounds;
            self->_glyphEdgePane.center = edgeCenter;
            self->_glyphEdgePane.transform = CGAffineTransformMakeScale(sx, sy);
        }];
    }
    [self updateNormalCutoutWithGeometry:geometry];
    [self updateOuterEdgeGuardWithGeometry:geometry];
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
    // Make a released selection move a touch more leisurely than the live
    // finger-following spring. The held drag stays 1:1 and responsive.
    BOOL freeFlight = !_touching && fabs(dir) > 2;
    SGRSpring front = spring(freeFlight ? 570 : 625, 0.83);
    SGRSpring back = spring(freeFlight ? 190 : 205, 0.72);
    SGRSpring even = spring(freeFlight ? 275 : 295, 0.78);
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
    [_rimOverlay removeAnimationForKey:@"lens.x"];
    [_rimOverlay removeAnimationForKey:@"lens.sx"];
    [_rimOverlay removeAnimationForKey:@"lens.sy"];
    [_platterEdgePane.layer removeAnimationForKey:@"lens.x"];
    [_platterEdgePane.layer removeAnimationForKey:@"lens.sx"];
    [_platterEdgePane.layer removeAnimationForKey:@"lens.sy"];
    [_glyphEdgePane.layer removeAnimationForKey:@"lens.x"];
    [_glyphEdgePane.layer removeAnimationForKey:@"lens.sx"];
    [_glyphEdgePane.layer removeAnimationForKey:@"lens.sy"];
    [_tintMask removeAnimationForKey:@"lens.x"];
    [_tintMask removeAnimationForKey:@"lens.sx"];
    [_tintMask removeAnimationForKey:@"lens.sy"];
    [_normalCutout removeAnimationForKey:@"lens.cutout"];
    // Geometry and material are sampled from the same spring clock.
    // Remove them together when a new finger takes over or the run ends.
    [_rest.layer removeAnimationForKey:@"lens.material"];
    [_pane.layer removeAnimationForKey:@"lens.material"];
    [_glare removeAnimationForKey:@"lens.material"];
    [_perimeter removeAnimationForKey:@"lens.material"];
    [_longSpecular removeAnimationForKey:@"lens.material"];
    [_platterEdgePane.layer removeAnimationForKey:@"lens.material"];
    [_glyphEdgePane.layer removeAnimationForKey:@"lens.material"];
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
    // CA playback's model material is its end state. If another finger takes
    // over mid-fade, return to live raised glass before drawing that finger's
    // geometry, rather than briefly flashing the model's resting substrate.
    if (_glassOn) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _rest.layer.opacity = 0.12;
        _pane.layer.opacity = 1;
        _glare.opacity = 1;
        _perimeter.opacity = 1;
        _longSpecular.opacity = 1;
        _platterEdgePane.layer.opacity = 1;
        _glyphEdgePane.layer.opacity = _tintOverlay ? 1 : 0;
        [CATransaction commit];
    }
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
    if (_needsQuickTapLift) {
        _needsQuickTapLift = NO;
        // On a short tap keep the upward spring going until the eye has seen
        // the full 70pt-ish held bubble. The recorded movement stays smooth:
        // no jump to lift=1, and the tab's horizontal spring keeps running.
        _liftTarget = 1;
        for (int i = 0; i < 26; i++) {
            [self advance:kPlayStep];
            SGLensSample raised = [self state];
            [samples appendBytes:&raised length:sizeof(raised)];
            if (i >= 17 && _lift >= 0.98) break;
        }
        _liftTarget = 0;
    }
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
    NSMutableArray<NSNumber *> *glyphXs = [NSMutableArray arrayWithCapacity:count];
    // Record one pose per keyframe, then share it with every optical track.
    // In particular glyphXs and maskXs must not convert the host scale again.
    NSMutableData *geometries = [NSMutableData dataWithCapacity:count * sizeof(SGLensGeometry)];
    for (NSUInteger i = 0; i < count; i++) {
        SGLensGeometry geometry = [self geometryForSample:all[i]];
        [geometries appendBytes:&geometry length:sizeof(geometry)];
        [xs addObject:@(geometry.hostCenter.x)];
        [maskXs addObject:@(geometry.tintCenter.x)];
        [glyphXs addObject:@(geometry.glyphCenter.x)];
        [sxs addObject:@(geometry.sx)];
        [sys addObject:@(geometry.sy)];
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
    // A second, identically clocked transform for the rim above all tabs;
    // otherwise the light lags behind the render-server glass after release.
    if (_rimOverlay.superlayer) {
        for (NSString *key in @[@"lens.x", @"lens.sx", @"lens.sy"]) {
            CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:
                [key isEqualToString:@"lens.x"] ? @"position.x" :
                ([key isEqualToString:@"lens.sx"] ? @"transform.scale.x" : @"transform.scale.y")];
            a.values = [key isEqualToString:@"lens.x"] ? xs : ([key isEqualToString:@"lens.sx"] ? sxs : sys);
            a.duration = duration;
            a.calculationMode = kCAAnimationLinear;
            [_rimOverlay addAnimation:a forKey:key];
        }
    }
    if (_platterEdgePane && _platterEdgePane.superview == self.superview) {
        for (NSString *key in @[@"lens.x", @"lens.sx", @"lens.sy"]) {
            NSString *path = [key isEqualToString:@"lens.x"] ? @"position.x" :
                             ([key isEqualToString:@"lens.sx"] ? @"transform.scale.x" : @"transform.scale.y");
            CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:path];
            a.values = [key isEqualToString:@"lens.x"] ? xs : ([key isEqualToString:@"lens.sx"] ? sxs : sys);
            a.duration = duration;
            a.calculationMode = kCAAnimationLinear;
            [_platterEdgePane.layer addAnimation:a forKey:key];
        }
    }
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
        edgeRun(@"lens.x", @"position.x", glyphXs);
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
        maskRun(@"lens.sx", @"transform.scale.x", sxs);
        maskRun(@"lens.sy", @"transform.scale.y", sys);
    }
    // Give the resting substrate the SAME position/squash keyframes as the
    // raised bubble (it is a child of this lens), but cross-fade its material
    // during the final portion of the lift. The old single-frame showGlass:NO
    // jumped straight from a refracting lens to a flat, fully opaque pill.
    // Short taps must first complete their upward spring before fading.
    if (_glassOn && !SGRReduceMotion()) {
        NSUInteger peak = 0;
        for (NSUInteger i = 1; i < count; i++)
            if (all[i].lift > all[peak].lift) peak = i;
        NSMutableArray<NSNumber *> *substrate = [NSMutableArray arrayWithCapacity:count];
        NSMutableArray<NSNumber *> *optical = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; i++) {
            CGFloat blend = 0;
            if (i > peak) {
                CGFloat descent = MIN(1, MAX(0, (0.60 - MAX(0, all[i].lift)) / 0.52));
                blend = descent * descent * (3 - 2 * descent);
            }
            [substrate addObject:@(0.12 + 0.88 * blend)];
            [optical addObject:@(1 - blend)];
        }
        void (^material)(CALayer *, NSArray<NSNumber *> *) = ^(CALayer *layer, NSArray<NSNumber *> *values) {
            if (!layer) return;
            CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
            a.values = values;
            a.duration = duration;
            a.calculationMode = kCAAnimationLinear;
            [layer addAnimation:a forKey:@"lens.material"];
        };
        material(_rest.layer, substrate);
        material(_pane.layer, optical);
        material(_platterEdgePane.layer, optical);
        material(_glyphEdgePane.layer, optical);
        material(_glare, optical);
        material(_perimeter, optical);
        material(_longSpecular, optical);
        // Model state MUST equal the last keyframe. If page loading stalls
        // the main queue at touchdown/release, Core Animation still finishes
        // on the settled substrate instead of snapping back to a glass rim.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _rest.layer.opacity = 1;
        _pane.layer.opacity = 0;
        _platterEdgePane.layer.opacity = 0;
        _glyphEdgePane.layer.opacity = 0;
        _glare.opacity = 0;
        _perimeter.opacity = 0;
        _longSpecular.opacity = 0;
        [CATransaction commit];
    }
    // Keep the white cutout on the same render-server path as the green
    // selected group; otherwise a loading tab freezes the hole in the backdrop.
    if (_glassOn && _normalContent && _normalContent.layer.mask == _normalCutout) {
        NSMutableArray *paths = [NSMutableArray arrayWithCapacity:count];
        const SGLensGeometry *poses = geometries.bytes;
        for (NSUInteger i = 0; i < count; i++) {
            CGPathRef path = [self newNormalCutoutPathForGeometry:poses[i]];
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
