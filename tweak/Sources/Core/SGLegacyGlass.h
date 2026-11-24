// The pre-iOS 26 stand-in for UIGlassEffect: a CABackdropLayer, blurred and saturated, displaced by a
// mesh so its edges refract the way real glass does. Geometry and filter values are ported from
// third-party GPLv2 glass and mesh references; the implementation is original.
//
// CABackdropLayer and CAMutableMeshTransform are private API Apple can remove at any point, so the
// whole thing sits behind SGLegacyGlassAvailable() and the "legacy glass" switch (SGKeyLegacyGlass),
// and every call fails soft to a plain blur. Callers go through SGUseLegacyGlass() (SGGlass.h), which
// combines both.
#import <UIKit/UIKit.h>

// NO on iOS 26+ (UIGlassEffect is used there) and wherever the private classes turn out not to exist.
// Cached after the first call.
BOOL SGLegacyGlassAvailable(void);

// One pane per call site, like UIVisualEffectView. It keeps its own backdrop layer and mesh sized to
// its bounds, so a pane resized by autoresizing or Auto Layout follows with no help from the caller.
@interface SGLegacyGlassView : UIView

// Where a caller puts its own content, like UIVisualEffectView.contentView: the backdrop and the mesh
// live behind it.
@property (nonatomic, strong, readonly) UIView *contentView;

// Corner radius of the glass. Ignored while `capsule` is set, which rounds to half the shorter side.
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL capsule;

// How far the backdrop is blurred, 2 by default: enough to soften an edge, and so little that a small
// control over text shows the text. A big pane (a sheet) sets more, or the page under it takes the eye.
@property (nonatomic) CGFloat blurRadius;

// Whether the pane wears the glass as it first was: YES for a big pane (a shorter side of 100 pt and more: the queue, the
// sheets, the menus, the dialogs), with the classic lens, bent hard over a thin band at the edge, and its diagonal glare.
// The measured lens of the small controls spreads over a wide band with a faint rim, which on a sheet read as a blur.
@property (nonatomic, readonly) BOOL classic;

// How much bigger what is behind the glass shows through it, about the middle, 1 by default. The tab bar's held bubble
// sets more, as the system's magnifies the tabs under it.
@property (nonatomic) CGFloat magnification;

// How much of the lens's bend the pane takes, 1 by default; the tab bar's held bubble takes less, its icons smeared at
// the rim under the whole of it.
@property (nonatomic) CGFloat lensScale;

// Clear glass, the system's .clear as a held control's thumb wears it: what is behind keeps its own colours (no
// saturation; the panes' boost turned a switch's green track into a neon blob under its thumb) and is barely blurred
// (adaptive_liquid_glass's clearDark: saturation 0.96, blur sigma 1.23). NO by default.
@property (nonatomic) BOOL clear;

// The backdrop at the screen's scale rather than at 1x, so what shows through is as sharp as the screen (the tab bar's
// held bubble, whose magnified icons came out pixelated). NO by default: it costs nine times the pixels on a 3x screen.
@property (nonatomic) BOOL sharp;

// No light along the rim: for a pane whose owner draws its own (a held switch's lens, lit on two arcs only). NO by default.
@property (nonatomic) BOOL rimless;

// Opt-in for a single prepared menu transition. Retain its warm mesh while
// following the moving bounds/rim; rebuild exactly once when it settles.
@property (nonatomic) BOOL geometryTransitionActive;
// Root-player morph only: prepare optical keyframes before the display link.
// Each index addresses a single live backdrop, never a second glass pane.
- (void)prepareGeometryTransitionSizes:(NSArray<NSValue *> *)sizes
                                 radii:(NSArray<NSNumber *> *)radii
                        compactAmounts:(NSArray<NSNumber *> *)compactAmounts;
- (void)applyGeometryTransitionMeshAtIndex:(NSUInteger)index;

// Lateral refractive crescents for the Legacy tab lens only. The upper and
// lower edge and the central channel stay unwarped; other panes are unchanged.
@property (nonatomic) BOOL lateralRefraction;
// Extra vertical displacement near the LEFT/RIGHT crescents, for the tab
// platter's top/bottom border. Zero by default (sheets/controls unchanged).
@property (nonatomic) CGFloat lateralVerticalReach;

// Suppress backdrop refraction at an outside edge of a split/compact tab
// circle, like the full tab lens's outer-edge guard. This masks ONLY the
// sampled backdrop, not the black content, circle rim or specular highlights.
// No guard is applied until explicitly requested by a caller.
- (void)setBackdropOuterEdgeGuardLeft:(BOOL)left right:(BOOL)right;

@end

// Unified three-part directional rim: same diagonal glare, fine perimeter and
// long specular on all Legacy panes, their films, and detached compact controls.
// The host-layer variant supports shapes whose backdrop is hidden temporarily.
void SGLegacyGlassSpecular(CALayer *host, CGRect bounds, CGFloat radius);
void SGLegacyGlassClassicSpecular(CALayer *host, CGRect bounds, CGFloat radius);
void SGLegacyGlassSetSpecularHidden(CALayer *host, BOOL hidden);
