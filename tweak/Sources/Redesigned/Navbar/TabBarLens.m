#import "TabBarLens.h"
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRGlass.h"
#import "Redesigned/Kit/SGRTokens.h"

static char kLensPaneKey, kLensFilmKey;

// Slightly less central magnification exposes more of each neighboring tab inside the held lens. This lets
// the refraction pick up adjacent glyphs in the gaps without needing a wide horizontal bulge.
static const CGFloat kLensMagnification = 1.10;
// The held bubble does not blur what it shows: the panes' 2 pt blur, magnified with the icons, left them a smear.
static const CGFloat kLensHeldBlur = 0, kLensRestBlur = 2;
// Moderate edge bend draws nearby glyphs into the lens without smearing their centers.
static const CGFloat kLensHeldBend = 0.46;

// The held bubble is this much wider than the pill (and taller by 2 * heldOutset, so it stands out of the capsule's
// rim, as the system's does), and may be dragged this far past the first and the last tab.
static const CGFloat kLensGrow = 18, kLensOverscroll = 14;
// The held lens keeps one width across the full tab row: no gap-dependent growth.
// The softer magnification and the closer item centers keep glyphs visible through it.
// Signed deformation: rightward motion spreads the bubble and lowers its height;
// leftward motion narrows it and raises its height. When the finger stops, a slow
// spring briefly reverses that shape before relaxing. A signed velocity (rather
// than its absolute value) is essential for the two directions to feel distinct.
static const CGFloat kLensStretchSpeed = 1300, kLensDirectionalStretch = 0.14;
static const CGFloat kLensMaxDeform = 0.22, kLensVolume = 0.8, kLensMaxLag = 0.18;
// The surface tension: once the edges are near their targets, they pull each other back to the bubble's width, with
// a damper of their own, so a stretched bubble draws in and gives a small bounce rather than ringing. It is off
// while the bubble is chasing a finger (the stretch is what shows the chase), and fades in over the last
// kLensTensionReach points of the middle's distance.
static const CGFloat kLensTension = 210, kLensTensionRatio = 0.55, kLensTensionReach = 30;
// Slower body response than the moving edges: deceleration in either direction
// kicks the squash *opposite* to its moving shape, with a small damped rebound.
// Acceleration gives a much gentler kick so the lens does not jitter while dragged.
static const CGFloat kLensSquashOmega = 9, kLensSquashRatio = 0.48, kLensSquashKick = 0.004;
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
    // While the glass is up the bubble stands over the tabs, so its glass bends and magnifies their icons; at rest it is
    // back under them, below the view that was over it.
    __weak UIView *_restAbove;
    CADisplayLink *_link;
    // The two edges: where they are, how fast they go and where they are going.
    CGFloat _L, _R, _vL, _vR, _tL, _tR;
    CGFloat _lift, _vLift, _liftTarget;
    // The squash spring and the speed it last saw (see kLensSquashKick).
    CGFloat _sq, _vSq, _prevSpeed;
    CGFloat _minCenter, _maxCenter;
    CALayer *_tintMask;
    BOOL _glassOn;
    // A bubble nobody holds is not run frame by frame on the main thread, which a tab loading under it would stall
    // (the glass froze for as long as the page took). Its whole run is worked out at once and handed to Core
    // Animation as keyframes: the same springs, played where the main thread cannot hold them up.
    NSData *_playback;            // SGLensSample[]
    CFTimeInterval _playStart;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _heldOutset = 6;
    _rest = [UIView new];
    _rest.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _rest.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_rest];
    _pane = SGGlassFor(self, &kLensPaneKey);
    _pane.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [UIView performWithoutAnimation:^{ SGRShowGlass(self->_pane, NO); }];
    _film = SGRGlassFilm(self, &kLensFilmKey, _pane, 0);
    _film.alpha = 0;
    // Held, the bubble is fully transparent, as the Music app's: no film and no rim, only the glass.
    _film.backgroundColor = UIColor.clearColor;
    return self;
}

- (void)dealloc {
    [_link invalidate];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat radius = bounds.size.height / 2;
    _rest.frame = bounds;
    _rest.layer.cornerRadius = radius;
    if (!CGRectEqualToRect(_pane.frame, bounds)) _pane.frame = bounds;
    SGShapeGlass(_pane, radius, YES);
    SGRGlassFilm(self, &kLensFilmKey, _pane, radius);
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
    [self playToTargets];
}

// Whether a finger lifts the pill into the glass bubble. With the legacy glass off the bubble's pane is a plain dark blur,
// opaque, and held over the tabs it hid the icon under it: then the dark pill stays a pill, under the icons, and slides
// with the finger from tab to tab on the same springs, as it did before the bubble.
static BOOL bubbles(void) {
    return SGUseLegacyGlass();
}

// The mask is in the same host coordinates as the lens. Its *shape* follows both
// the moving spring and the layer keyframe playback after the finger is released.
- (void)setTintOverlay:(UIView *)tintOverlay {
    if (_tintOverlay == tintOverlay) return;
    _tintOverlay.layer.mask = nil;
    _tintOverlay = tintOverlay;
    if (!tintOverlay) { _tintMask = nil; return; }
    _tintMask = [CALayer layer];
    _tintMask.backgroundColor = UIColor.whiteColor.CGColor;
    _tintMask.cornerCurve = kCACornerCurveContinuous;
    _tintMask.masksToBounds = YES;
    tintOverlay.layer.mask = _tintMask;
    [self applyPose];
}

- (void)beginTouchAtX:(CGFloat)x minCenter:(CGFloat)minCenter maxCenter:(CGFloat)maxCenter {
    // Reduce Motion: the pill stays a pill and moves with the selection, as it did.
    if (CGRectIsEmpty(_restFrame) || self.hidden || SGRReduceMotion()) return;
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
    // Over the tabs while the glass is up; back under them as soon as it goes, so the pill coming back draws under the
    // icon, never over it while the glass fades.
    [self standOverTabs:on];
    if ([_pane isKindOfClass:SGLegacyGlassView.class]) {
        SGLegacyGlassView *glass = (SGLegacyGlassView *)_pane;
        glass.magnification = on ? kLensMagnification : 1;
        glass.blurRadius = on ? kLensHeldBlur : kLensRestBlur;
        glass.lensScale = on ? kLensHeldBend : 1;
        glass.sharp = on;
    }
    void (^change)(void) = ^{
        SGRShowGlass(self->_pane, on);
        self->_film.alpha = on ? 1 : 0;
        self->_rest.alpha = on ? 0 : 1;
    };
    if (animated) SGRAnimate(on ? SGRMotionRespond : SGRMotionFade, change, nil);
    else [UIView performWithoutAnimation:change];
}

// Over every sibling (the tabs), or back under the one that was over it.
- (void)standOverTabs:(BOOL)over {
    UIView *host = self.superview;
    if (!host) return;
    if (over) {
        NSUInteger at = [host.subviews indexOfObject:self];
        if (at == NSNotFound || at + 1 >= host.subviews.count) return;
        _restAbove = host.subviews[at + 1];
        [host bringSubviewToFront:self];
        return;
    }
    UIView *above = _restAbove;
    _restAbove = nil;
    if (above.superview == host) [host insertSubview:self belowSubview:above];
}

// Where the bubble is for the state it is in: the middle, and how wide and how tall it looks. Its size is fixed (the
// pill's); the look is a transform, so no frame of glass is laid out again while it moves.
- (void)getPose:(SGLensSample)st center:(CGPoint *)center sx:(CGFloat *)sx sy:(CGFloat *)sy {
    CGFloat baseWidth = MAX(1, self.bounds.size.width), baseHeight = MAX(1, self.bounds.size.height);
    CGFloat nominal = MAX(1, _restFrame.size.width + kLensGrow * st.lift);
    CGFloat width = MIN(MAX(baseHeight * 0.8, st.R - st.L), nominal * (1 + kLensMaxLag));
    CGFloat signedSpeed = (st.vL + st.vR) / 2;
    CGFloat stretch = kLensDirectionalStretch * tanh(signedSpeed / kLensStretchSpeed);
    CGFloat d = MAX(-kLensMaxDeform, MIN(kLensMaxDeform, (st.sq + stretch) * st.lift));
    CGFloat held = 1 + 2 * _heldOutset / baseHeight * st.lift;
    *sx = width * (1 + d) / baseWidth;
    *sy = held * (1 - kLensVolume * d);
    *center = CGPointMake((st.L + st.R) / 2, CGRectGetMidY(_restFrame));
}

- (SGLensSample)state {
    return (SGLensSample){_L, _R, _vL, _vR, _lift, _vLift, _sq, _vSq};
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
    if (_tintMask) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _tintMask.bounds = (CGRect){CGPointZero, self.bounds.size};
        _tintMask.cornerRadius = self.bounds.size.height / 2;
        _tintMask.position = center;
        _tintMask.transform = CATransform3DMakeScale(sx, sy, 1);
        [CATransaction commit];
    }
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
    SGRSpring front = spring(1300, 0.82), back = spring(460, 0.68), even = spring(720, 0.77);
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
    [_tintMask removeAnimationForKey:@"lens.x"];
    [_tintMask removeAnimationForKey:@"lens.sx"];
    [_tintMask removeAnimationForKey:@"lens.sy"];
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
    for (NSUInteger i = 0; i < count; i++) {
        CGPoint center;
        CGFloat sx, sy;
        [self getPose:all[i] center:&center sx:&sx sy:&sy];
        [xs addObject:@(center.x)];
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
        maskRun(@"lens.x", @"position.x", xs);
        maskRun(@"lens.sx", @"transform.scale.x", sxs);
        maskRun(@"lens.sy", @"transform.scale.y", sys);
    }
    _playback = samples;
    _playStart = CACurrentMediaTime();
}

@end
