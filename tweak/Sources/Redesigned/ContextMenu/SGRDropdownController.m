// Button dropdowns owned by Vitrine. UIKit UIMenu is only the source of commands.
// Geometry, sections, hit testing and submenus do not use _UIContextMenu*.
#import <objc/runtime.h>
#import <math.h>
#import "Core/SGCore.h"
#import "Core/SGLegacyGlass.h"
#import "Core/SGRuntime.h"
#import "Redesigned/Kit/SGRKit.h"
#import "SGRDropdownController.h"
#import "SGRDropdownDeferred.h"

static const CGFloat kWidth = 250, kRadius = 30, kInset = 10;
static const CGFloat kRow = 42, kSubtitle = 58, kQuick = 93, kQuickSingle = 77, kHeader = 62;
static const CGFloat kSectionGap = 11, kSubmenuSectionGap = 21, kBottomPadding = 10, kSubmenuDrop = 12;
static const CGFloat kPanelMaximum = 520;
static const CGFloat kNonTripleTopPadding = 12;
// Lightweight presentation transitions only. The touch-driven iOS 26 morph
// remains a separate task; never replay an open transition on a data refresh.
static const NSTimeInterval kOpenTime = 0.27, kSubmenuTime = 0.23, kDismissTime = 0.20;
static CGAffineTransform dropdownEnteringTransform(void) {
    return CGAffineTransformConcat(CGAffineTransformMakeScale(0.92, 0.92),
                                   CGAffineTransformMakeTranslation(0, 9));
}
static CGAffineTransform dropdownExitingTransform(void) {
    return CGAffineTransformConcat(CGAffineTransformMakeScale(0.95, 0.95),
                                   CGAffineTransformMakeTranslation(0, 5));
}
static char kOwnedGlassKey;
// Root and submenu use distinct video-fit geometry profiles.
// Neither is a recovered UIKit spring constant.
static const NSTimeInterval kPlayerMorphOpen = 0.54, kPlayerMorphMore = 0.52;
// A slow render callback must not skip the rounded preview altogether.
static const NSTimeInterval kPlayerRootMaxStep = 1.0/30.0;
static CGFloat morphMix(CGFloat a, CGFloat b, CGFloat t) { return a + (b-a)*t; }
static CGFloat morphClamp(CGFloat t) { return MAX(0, MIN(1, t)); }
static CGFloat morphSmooth(CGFloat t) { t = morphClamp(t); return t*t*(3-2*t); }
// Fast initial expansion with a softly damped tail. Normalized to exactly 1.
// This is a fitted approximation, not a recovered UIKit spring.
static CGFloat morphGeometry(CGFloat t) {
    t = morphClamp(t);
    const CGFloat w = 5.8;
    return (1-(1+w*t)*exp(-w*t))/(1-(1+w)*exp(-w));
}
// Stage 200: launch and release overlap. The long native preview hold is
// a simulator artefact, not part of the target morph. Keep the shape moving.
static const NSUInteger kPlayerMorphMeshSteps = 18;
static const CGFloat kPlayerLaunchEnd = 0.42;
static const CGFloat kPlayerReleaseStart = 0.36;
static CGFloat morphRelease(CGFloat t) {
    return morphGeometry((t-kPlayerReleaseStart)/(1-kPlayerReleaseStart));
}
static CGFloat morphLensRadius(CGSize size, CGFloat lens) {
    CGFloat halfSide = MIN(size.width, size.height) / 2.0;
    return MIN(halfSide, morphMix(kRadius, halfSide, morphClamp(lens)));
}
static CGRect morphFlightFrame(CGRect a, CGRect b, CGFloat t, CGFloat release) {
    CGFloat launch = morphGeometry(t/kPlayerLaunchEnd);
    CGFloat previewW = b.size.width * 0.98;
    CGFloat previewH = b.size.height * 1.035;
    CGFloat drop = MIN(86.0, b.size.height * 0.27);
    CGFloat px = CGRectGetMidX(b);
    CGFloat direction = CGRectGetMidY(a) > CGRectGetMidY(b) ? -1 : 1;
    CGFloat py = CGRectGetMidY(b) + direction*drop;
    CGFloat cx = morphMix(morphMix(CGRectGetMidX(a), px, launch), CGRectGetMidX(b), release);
    CGFloat cy = morphMix(morphMix(CGRectGetMidY(a), py, launch), CGRectGetMidY(b), release);
    CGFloat w = morphMix(morphMix(a.size.width, previewW, launch), b.size.width, release);
    CGFloat h = morphMix(morphMix(a.size.height, previewH, launch), b.size.height, release);
    // Small upward recoil near the end; zero at both endpoints.
    CGFloat tail = morphClamp((t-0.72)/0.28);
    cy -= direction * 4.0 * sin(M_PI * tail) * sin(M_PI * tail);
    return CGRectMake(cx-w/2, cy-h/2, w, h);
}

static CGRect morphRect(CGRect a, CGRect b, CGFloat t) {
    return CGRectMake(morphMix(a.origin.x,b.origin.x,t), morphMix(a.origin.y,b.origin.y,t),
                      morphMix(a.size.width,b.size.width,t), morphMix(a.size.height,b.size.height,t));
}

// An underdamped, zero-velocity start. Taper the residual to zero so the
// last model update cannot introduce a discontinuity.
static CGFloat dropdownSpringProgress(CGFloat t, CGFloat damping, CGFloat frequency) {
    t = morphClamp(t);
    CGFloat residual = exp(-damping*t)*(cos(frequency*t)+(damping/frequency)*sin(frequency*t));
    return 1-residual*(1-morphSmooth((t-0.82)/0.18));
}
// Slower acceleration, with a visible but small spring tail. The previous
// 8.5 damping reached most of the height in the first few display callbacks.
static CGFloat dropdownSubmenuProgress(CGFloat t) {
    CGFloat g=dropdownSpringProgress(t,5.4,8.0);
    // Keep the rebound small without a hard clamp or a velocity jump.
    CGFloat over=MAX(0,g-1);
    return g-over+over/(1+over/0.04);
}
static CGRect dropdownSubmenuFrame(CGRect from, CGRect to, CGFloat t) {
    CGFloat g = dropdownSubmenuProgress(t);
    CGRect f = morphRect(from,to,g);
    f.size.width=MAX(1,f.size.width); f.size.height=MAX(1,f.size.height);
    return f;
}
static CGFloat dropdownSubmenuLens(CGFloat t) { return 0.22*(1-morphClamp(dropdownSubmenuProgress(t))); }
// Restore the Stage 205 centre/size separation, with earlier travel and
// a less persistent optical bubble near the anchor.
static CGRect dropdownCollapseFrame(CGRect from, CGRect to, CGFloat t, BOOL submenu) {
    if (submenu) {
        // On return the header moves a little beyond the source row, but
        // its height never shrinks below the actual row height.
        CGFloat g=dropdownSubmenuProgress(t), size=morphClamp(g);
        CGRect f=morphRect(from,to,size);
        f.origin.y+=(CGRectGetMidY(to)-CGRectGetMidY(from))*(g-size);
        return f;
    }
    // Shared Home-style return: lose the square corners while drawing the
    // glass toward the anchor, then let the compact lens catch up. Do not
    // fly through the oversized opening preview or leave a tiny dark dot.
    CGFloat shrink=morphGeometry(t), travel=morphGeometry(t/0.94);
    CGFloat w=morphMix(from.size.width,to.size.width,shrink);
    CGFloat h=morphMix(from.size.height,to.size.height,morphGeometry(t/0.86));
    CGFloat x=morphMix(CGRectGetMidX(from),CGRectGetMidX(to),travel);
    CGFloat y=morphMix(CGRectGetMidY(from),CGRectGetMidY(to),travel);
    return CGRectMake(x-w/2,y-h/2,w,h);
}
static CGFloat dropdownCloseLens(CGFloat initial, CGFloat t, BOOL submenu) {
    return morphMix(initial,submenu ? 0.12 : 1,morphSmooth(t/(submenu ? 1 : 0.55)));
}
static CGFloat dropdownHostedLens(CGFloat t) {
    CGFloat v = sin(M_PI*morphClamp(t));
    return 0.78*v*v;
}
// Keep blur on the contents, not on the backdrop; failure leaves the live view usable.
static void dropdownContentBlur(CALayer *layer, CGFloat radius) {
    if (!layer || SGRReduceTransparency()) return;
    @try {
        if (!layer.filters.count) {
            id filter = SGFilterOfType(@"gaussianBlur");
            if (!filter) return;
            [filter setValue:@(radius) forKey:@"inputRadius"];
            layer.filters = @[filter];
        } else [layer setValue:@(radius) forKeyPath:@"filters.gaussianBlur.inputRadius"];
    } @catch (__unused NSException *exception) {}
}
BOOL SGRDropdownPerformAction(UIMenuElement *element) {
    if ([element isKindOfClass:UIAction.class]) {
        UIButton *sender = [UIButton buttonWithType:UIButtonTypeCustom];
        [sender addAction:(UIAction *)element forControlEvents:UIControlEventPrimaryActionTriggered];
        [sender sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
        return YES;
    }
    if ([element isKindOfClass:UICommand.class]) {
        UICommand *command = (UICommand *)element;
        if (!command.action) return NO;
        return [UIApplication.sharedApplication sendAction:command.action to:nil from:command forEvent:nil];
    }
    return NO;
}

@interface SGRDropdownItem : NSObject
@property (nonatomic, strong) UIMenuElement *element;
@property (nonatomic) BOOL tile;
@end
@implementation SGRDropdownItem
@end

// Attributes belong to concrete actions/commands, not to the UIMenuElement base class.
// A submenu is a container, so it has no action attributes of its own.
static UIMenuElementAttributes dropdownAttributes(UIMenuElement *element) {
    if ([element isKindOfClass:UIAction.class]) return ((UIAction *)element).attributes;
    if ([element isKindOfClass:UICommand.class]) return ((UICommand *)element).attributes;
    return 0;
}

static BOOL isInline(UIMenu *menu) {
    return (menu.options & UIMenuOptionsDisplayInline) != 0;
}

static BOOL isQuick(UIMenu *menu) {
    return [menu.identifier isEqualToString:@"com.vitrine.systemmenu.quick"] ||
           (menu.preferredElementSize == UIMenuElementSizeMedium && menu.children.count >= 2 && menu.children.count <= 4);
}

static NSArray<NSArray<SGRDropdownItem *> *> *groupsOf(UIMenu *menu) {
    NSMutableArray<NSArray<SGRDropdownItem *> *> *groups = [NSMutableArray array];
    NSMutableArray<SGRDropdownItem *> *plain = [NSMutableArray array];
    for (UIMenuElement *element in menu.children) {
        if ([element isKindOfClass:UIDeferredMenuElement.class]) continue;
        if ([element isKindOfClass:UIMenu.class] && isInline((UIMenu *)element)) {
            if (plain.count) { [groups addObject:[plain copy]]; [plain removeAllObjects]; }
            UIMenu *section = (UIMenu *)element;
            if (isQuick(section)) {
                NSMutableArray<SGRDropdownItem *> *tiles = [NSMutableArray array];
                for (UIMenuElement *action in section.children) {
                    if ([action isKindOfClass:UIDeferredMenuElement.class]) continue;
                    SGRDropdownItem *item = [SGRDropdownItem new];
                    item.element = action;
                    item.tile = YES;
                    [tiles addObject:item];
                }
                if (tiles.count) [groups addObject:tiles];
            } else {
                NSArray<NSArray<SGRDropdownItem *> *> *children = groupsOf(section);
                [groups addObjectsFromArray:children];
            }
        } else {
            SGRDropdownItem *item = [SGRDropdownItem new];
            item.element = element;
            [plain addObject:item];
        }
    }
    if (plain.count) [groups addObject:[plain copy]];
    return groups;
}

// One resolution session belongs to one visible panel. The original menu is
// immutable; snapshots expand finished deferred providers without re-opening
// the panel or changing its command handlers. Submenus resolve on demand when
// pushed, not while their parent is displayed.
@interface SGRDropdownResolution : NSObject
@property (nonatomic, strong) UIMenu *source;
@property (nonatomic, weak) UIResponder *anchor;
@property (nonatomic, strong) NSMutableDictionary<NSValue *, NSArray<UIMenuElement *> *> *results;
@property (nonatomic, strong) NSMutableSet<NSValue *> *requested;
@property (nonatomic, copy) void (^didChange)(UIMenu *snapshot);
@property (nonatomic) BOOL cancelled;
@property (nonatomic) BOOL initialRequestsIssued;
- (BOOL)hasPending;
- (instancetype)initWithMenu:(UIMenu *)menu anchor:(UIResponder *)anchor;
- (UIMenu *)snapshot;
- (void)begin;
- (void)cancel;
@end

@implementation SGRDropdownResolution
- (instancetype)initWithMenu:(UIMenu *)menu anchor:(UIResponder *)anchor {
    if ((self = [super init])) {
        self.source = menu;
        self.anchor = anchor;
        self.results = [NSMutableDictionary dictionary];
        self.requested = [NSMutableSet set];
    }
    return self;
}
- (void)cancel {
    self.cancelled = YES;
    self.didChange = nil;
}
static UIAction *statusAction(NSString *title) {
    UIAction *action = [UIAction actionWithTitle:title image:nil
                                    identifier:@"Vitrine.Dropdown.DeferredStatus"
                                       handler:^(__kindof UIAction *_) {}];
    action.attributes = UIMenuElementAttributesDisabled;
    return action;
}
- (NSArray<UIMenuElement *> *)expanded:(NSArray<UIMenuElement *> *)elements depth:(NSUInteger)depth {
    if (depth > 16) return @[statusAction(@"Items unavailable")];
    NSMutableArray<UIMenuElement *> *output = [NSMutableArray array];
    for (UIMenuElement *element in elements) {
        if ([element isKindOfClass:UIDeferredMenuElement.class]) {
            NSArray<UIMenuElement *> *ready = self.results[[NSValue valueWithNonretainedObject:element]];
            if (ready) [output addObjectsFromArray:[self expanded:ready depth:depth + 1]];
            else [output addObject:statusAction(@"Loading…")];
        } else if ([element isKindOfClass:UIMenu.class] && isInline((UIMenu *)element)) {
            UIMenu *section = (UIMenu *)element;
            UIMenu *replacement = [section menuByReplacingChildren:[self expanded:section.children depth:depth + 1]];
            replacement.preferredElementSize = section.preferredElementSize;
            [output addObject:replacement];
        } else {
            [output addObject:element];
        }
    }
    return output;
}
- (UIMenu *)snapshot {
    NSArray<UIMenuElement *> *elements = [self expanded:self.source.children depth:0];
    if (!elements.count && self.source.children.count)
        elements = @[statusAction(@"No actions available")];
    UIMenu *replacement = [self.source menuByReplacingChildren:elements];
    replacement.preferredElementSize = self.source.preferredElementSize;
    return replacement;
}
- (void)requestElements:(NSArray<UIMenuElement *> *)elements depth:(NSUInteger)depth {
    if (self.cancelled || depth > 16) return;
    for (UIMenuElement *element in elements) {
        if ([element isKindOfClass:UIDeferredMenuElement.class]) {
            NSValue *key = [NSValue valueWithNonretainedObject:element];
            if ([self.requested containsObject:key]) continue;
            [self.requested addObject:key];
            __weak SGRDropdownResolution *weakSelf = self;
            SGRDropdownDeferredRequest((UIDeferredMenuElement *)element, self.anchor, ^(NSArray<UIMenuElement *> *ready) {
                SGRDropdownResolution *strongSelf = weakSelf;
                if (!strongSelf || strongSelf.cancelled) return;
                // A nested deferred provider may be returned by another provider.
                // Resolve it in this same session, without resetting the panel.
                strongSelf.results[key] = ready ?: @[statusAction(@"Unable to load options")];
                if (ready) [strongSelf requestElements:ready depth:depth + 1];
                if (strongSelf.didChange) strongSelf.didChange([strongSelf snapshot]);
            });
        } else if ([element isKindOfClass:UIMenu.class] && isInline((UIMenu *)element)) {
            [self requestElements:((UIMenu *)element).children depth:depth + 1];
        }
    }
}
- (BOOL)hasPending {
    // A synchronous provider must not reveal the panel before the complete
    // initial tree has been traversed (more deferred nodes may follow).
    return !self.initialRequestsIssued || self.requested.count > self.results.count;
}
- (void)begin {
    [self requestElements:self.source.children depth:0];
    self.initialRequestsIssued = YES;
}
@end

// Measure labels at the same width and font that the panel actually uses.
// English character counts are not a reliable proxy for the number of lines.
static BOOL needsWrappedTitle(UIMenuElement *element) {
    NSString *title = element.title;
    if (!title.length) return NO;
    UIFont *font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    CGRect size = [title boundingRectWithSize:CGSizeMake(162, CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                  attributes:@{ NSFontAttributeName: font } context:nil];
    return size.size.height > font.lineHeight * 1.4;
}

static CGFloat rowHeight(UIMenuElement *element) {
    if (element.subtitle.length) return needsWrappedTitle(element) ? 80 : kSubtitle;
    if (needsWrappedTitle(element)) return 64;
    return kRow;
}

// UIKit 26 keeps a single quick action in a 77pt cell, but a row of
// multiple actions has 93pt. The single Share measurement is 77pt on
// the same route where the old fixed 93pt box made our panel 16pt taller.
static CGFloat quickHeight(NSUInteger count) {
    return count == 1 ? kQuickSingle : kQuick;
}

// UIKit 26 leaves 11pt after the quick tile group, 21pt before a
// standalone submenu, and 10pt at the foot. Those gaps are part of the
// menu layout, not padding supplied by a screen-wide overlay.
static CGFloat gapBeforeGroup(NSArray<NSArray<SGRDropdownItem *> *> *groups, NSUInteger index, BOOL hasHeader) {
    if (!index || hasHeader) return 0;
    NSArray<SGRDropdownItem *> *group = groups[index];
    if (group.count == 1 && [group.firstObject.element isKindOfClass:UIMenu.class])
        return kSubmenuSectionGap;
    return kSectionGap;
}

static CGFloat topPadding(NSArray<NSArray<SGRDropdownItem *> *> *groups, BOOL withHeader) {
    if (withHeader) return 0; // The back/header row provides this spacing.
    NSArray<SGRDropdownItem *> *first = groups.firstObject;
    // The tight top-aligned geometry belongs only to the three-tile layout.
    // Standalone lists and one/two-action groups need breathing room.
    return (first.firstObject.tile && first.count == 3) ? 0 : kNonTripleTopPadding;
}

static CGFloat contentHeight(UIMenu *menu, BOOL withHeader) {
    CGFloat height = withHeader ? kHeader + 10 : 0;
    NSArray<NSArray<SGRDropdownItem *> *> *groups = groupsOf(menu);
    height += topPadding(groups, withHeader);
    for (NSUInteger i = 0; i < groups.count; ++i) {
        height += gapBeforeGroup(groups, i, withHeader);
        NSArray<SGRDropdownItem *> *group = groups[i];
        if (group.firstObject.tile) height += quickHeight(group.count);
        else for (SGRDropdownItem *item in group) height += rowHeight(item.element);
    }
    return height + kBottomPadding;
}

@interface SGRDropdownPress : UIControl
@property (nonatomic, strong) UIMenuElement *element;
@property (nonatomic, copy) void (^pick)(UIMenuElement *element);
@property (nonatomic, strong) UIView *highlight;
@property (nonatomic) BOOL isTile;
@end
@implementation SGRDropdownPress
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.isAccessibilityElement = YES;
        self.highlight = [UIView new];
        self.highlight.userInteractionEnabled = NO;
        self.highlight.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
        self.highlight.layer.cornerRadius = 15;
        self.highlight.layer.cornerCurve = kCACornerCurveContinuous;
        self.highlight.alpha = 0;
        [self insertSubview:self.highlight atIndex:0];
        [self addTarget:self action:@selector(activate) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.highlight.frame = CGRectInset(self.bounds, 2, 2);
    self.highlight.layer.cornerRadius = self.isTile ? 18 : MIN(20, CGRectGetHeight(self.highlight.bounds) / 2);
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.highlight.alpha = highlighted ? 1 : 0;
}
- (void)activate { if (self.enabled && self.pick) self.pick(self.element); }
@end

@interface SGRDropdownPanel : UIView <UIGestureRecognizerDelegate, UIScrollViewDelegate>
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIView *body;
@property (nonatomic, strong) UIView *scrollThumb;
@property (nonatomic, strong) UIView *separator;
@property (nonatomic, strong) UIView *header;
@property (nonatomic, strong) UIView *tileGroup;
@property (nonatomic, strong) NSMutableArray<SGRDropdownPress *> *tileButtons;
@property (nonatomic, strong) NSMutableArray<SGRDropdownPress *> *allButtons;
@property (nonatomic, strong) UIPanGestureRecognizer *selectionPan;
@property (nonatomic, strong) UISelectionFeedbackGenerator *selectionFeedback;
@property (nonatomic, weak) SGRDropdownPress *draggedPress;
@property (nonatomic) CGPoint dragStartOffset;
@property (nonatomic) BOOL dragIsScrolling;
@property (nonatomic) BOOL elasticDrag;
@property (nonatomic) BOOL elasticHorizontal;
@property (nonatomic) BOOL elasticEnabled;
@property (nonatomic) CGPoint elasticAnchor; // normalized point on the originating edge
@property (nonatomic) BOOL elasticReturning;
@property (nonatomic) NSUInteger elasticGeneration;
@property (nonatomic) CGAffineTransform elasticStartTransform;
@property (nonatomic, copy) void (^elasticSettled)(void);
- (BOOL)elasticInteractionActive;
- (void)settleElasticInteraction;
- (void)updateSurfaceLight:(CGPoint)point;
@property (nonatomic, strong) UILongPressGestureRecognizer *surfaceTouch;
@property (nonatomic, strong) CAGradientLayer *touchLight;
@property (nonatomic, strong) UIMenu *menu;
@property (nonatomic, strong) SGRDropdownResolution *resolution;
@property (nonatomic) BOOL isSubmenu;
// Only the Home filter has a compact leading selection indicator on iOS 26.
@property (nonatomic) BOOL homeFilterRoot;
@property (nonatomic) BOOL morphing;
@property (nonatomic) BOOL playerRootGlass;
@property (nonatomic) CGRect submenuSource;
@property (nonatomic) CGFloat stackOffset;
@property (nonatomic, weak) UIImageView *headerChevron;
- (void)setStackDisplacement:(CGFloat)offset;
- (void)setSubmenuReveal:(CGFloat)reveal sourceHeight:(CGFloat)sourceHeight;
@property (nonatomic) NSInteger morphContentBlurStep;
@property (nonatomic) CGFloat morphRootMaterialAmount;
@property (nonatomic, strong) NSArray *morphContentMeshes;
@property (nonatomic, strong) id morphOriginalContentMesh;
@property (nonatomic) NSInteger morphContentMeshIndex;
@property (nonatomic) NSUInteger morphContentMeshFrames;
@property (nonatomic) BOOL morphRefreshQueued;
@property (nonatomic) CGSize morphFinalSize;
@property (nonatomic) CGFloat morphLensAmount;
@property (nonatomic) NSInteger morphTintStep;
@property (nonatomic, strong) SGLegacyGlassView *morphGlass;
@property (nonatomic, strong) UIView *morphOutgoingContent;
@property (nonatomic) BOOL waitingForDeferred;
@property (nonatomic, copy) void (^choose)(UIMenuElement *element);
@property (nonatomic, copy) void (^back)(void);
@property (nonatomic) CGFloat actualHeight;
- (void)configure:(UIMenu *)menu title:(NSString *)title maxHeight:(CGFloat)maximum;
- (void)applyPlayerContentLens:(CGFloat)amount release:(CGFloat)release;
- (void)preparePlayerContentMeshes;
- (void)restorePlayerContentMesh;
- (void)resetElastic;
@end

@implementation SGRDropdownPanel
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.cornerRadius = kRadius;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.masksToBounds = YES;
        self.backgroundColor = UIColor.clearColor;
        self.accessibilityIdentifier = @"Vitrine.Dropdown.Panel";
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        self.scroll = [UIScrollView new];
        self.scroll.showsVerticalScrollIndicator = YES;
        self.scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
        self.scroll.showsHorizontalScrollIndicator = NO;
        self.scroll.alwaysBounceVertical = NO;
        self.scroll.delaysContentTouches = NO;
        self.scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        self.scroll.backgroundColor = UIColor.clearColor;
        self.scroll.delegate = self;
        [self addSubview:self.scroll];
        // Native indicators fade away. Keep a narrow, noninteractive thumb
        // visible whenever the menu is vertically clipped.
        self.scrollThumb = [UIView new];
        self.scrollThumb.backgroundColor = [UIColor colorWithWhite:1 alpha:0.48];
        self.scrollThumb.layer.cornerRadius = 1.5;
        self.scrollThumb.userInteractionEnabled = NO;
        [self addSubview:self.scrollThumb];
        self.body = [UIView new];
        self.body.backgroundColor = UIColor.clearColor;
        [self.scroll addSubview:self.body];
        self.tileButtons = [NSMutableArray array];
        self.allButtons = [NSMutableArray array];
        // Gesture lives on the entire scroll viewport, not just the quick
        // actions strip. Its pan may coexist with a real scrolling gesture.
        self.selectionPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragAcrossMenu:)];
        self.selectionPan.cancelsTouchesInView = YES;
        self.selectionPan.delegate = self;
        self.elasticEnabled = SGBelowiOS26() && SGUseLegacyGlass() && !UIAccessibilityIsReduceMotionEnabled();
        if (self.elasticEnabled) {
            [self addGestureRecognizer:self.selectionPan];
            self.surfaceTouch = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(flashSurface:)];
            self.surfaceTouch.minimumPressDuration = 0;
            self.surfaceTouch.allowableMovement = CGFLOAT_MAX;
            self.surfaceTouch.cancelsTouchesInView = NO;
            self.surfaceTouch.delaysTouchesBegan = NO;
            self.surfaceTouch.delaysTouchesEnded = NO;
            self.surfaceTouch.delegate = self;
            [self addGestureRecognizer:self.surfaceTouch];
            self.touchLight = [CAGradientLayer layer];
            self.touchLight.type = kCAGradientLayerRadial;
            self.touchLight.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.155].CGColor,
                                        (id)[UIColor colorWithWhite:1 alpha:0.085].CGColor,
                                        (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
            self.touchLight.locations = @[@0,@0.48,@1];
            self.touchLight.startPoint = CGPointMake(0.5,0.5);
            self.touchLight.endPoint = CGPointMake(1,1);
            self.touchLight.opacity = 0;
            self.touchLight.zPosition = 1000;
            [self.layer addSublayer:self.touchLight];
        } else [self.scroll addGestureRecognizer:self.selectionPan];
        self.selectionFeedback = [UISelectionFeedbackGenerator new];
        self.layer.shadowOpacity = 0;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.touchLight) {
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        // Preserve the local touch centre as bounds change; the large gradient
        // is clipped by the panel instead of squeezed into its bounds.
        CGFloat reach = MAX(205, MAX(self.bounds.size.width,self.bounds.size.height)*0.65);
        self.touchLight.bounds = CGRectMake(0,0,reach*2,reach*2);
        [CATransaction commit];
    }
    CGFloat radius = self.morphing ? morphLensRadius(self.bounds.size, self.morphLensAmount) : kRadius;
    if (self.layer.cornerRadius != radius) self.layer.cornerRadius = radius;
    if (self.morphing && self.morphGlass) {
        // Root flight changes the optical material while the same live
        // backdrop and directional rim follow the changing outline.
        SGLegacyGlassView *glass = self.morphGlass;
        if (!CGRectEqualToRect(glass.frame, self.bounds)) glass.frame = self.bounds;
        SGShapeGlass(glass, radius, NO);
        if (self.playerRootGlass) {
            SGRStylePlayerRootLegacyGlass(glass, radius, self.morphRootMaterialAmount);
        } else {
            // Submenu changes are principally geometry. Keep its backdrop
            // filters stable throughout the spring; the prepared mesh still
            // follows the rounded edges.
            NSInteger tintStep = self.isSubmenu ? 0 : (NSInteger)lround(8.0 * morphClamp(self.morphLensAmount));
            SGRThickenSheetGlassMorph(glass, radius, (CGFloat)tintStep / 8.0);
            if (self.morphTintStep != tintStep) {
                self.morphTintStep = tintStep;
                CGFloat lens = (CGFloat)tintStep / 8.0;
                CGFloat settledDim = self.isSubmenu ? 0.82 : 0.62;
                SGRDimSheetGlassTint(glass, [UIColor colorWithWhite:self.isSubmenu ? 0.16 : 0.11
                    alpha:settledDim - 0.42 * lens]);
            }
        }
        [glass layoutIfNeeded];
    } else if (self.playerRootGlass && SGUseLegacyGlass()) {
        // Do not call the ordinary sheet helper first: it would reset the
        // blur to 10pt on every settled layout and rebuild the filters twice.
        UIView *glass = SGGlassFor(self, &kOwnedGlassKey);
        glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        if (!CGRectEqualToRect(glass.frame, self.bounds)) glass.frame = self.bounds;
        SGShapeGlass(glass, radius, NO);
        SGRStylePlayerRootLegacyGlass(glass, radius, 1);
    } else {
        UIView *glass = SGRGlassPaneIn(self, &kOwnedGlassKey, radius);
        if (glass) SGRDimSheetGlassTint(glass, [UIColor colorWithWhite:self.isSubmenu ? 0.16 : 0.11
                                alpha:self.isSubmenu ? 0.82 : 0.62]);
    }
    if (SGBelowiOS26() && SGUseLegacyGlass()) {
        // No bright directional rim on dropdowns, including during mesh
        // updates. Keep the underlying refractive mesh and subtle hairline.
        UIView *glass = objc_getAssociatedObject(self, &kOwnedGlassKey);
        SGRSoftenLegacyDropdownRim(glass);
    }
    if (self.morphing) {
        // Keep the entire destination text layout stable. The moving pane
        // clips it; don't resize the scrolling viewport on every refresh.
        CGFloat dx = self.bounds.size.width-self.morphFinalSize.width;
        CGFloat dy = self.bounds.size.height-self.morphFinalSize.height;
        self.scroll.frame = CGRectMake(dx/2, self.isSubmenu ? 0 : dy/2,
                                       self.morphFinalSize.width, self.morphFinalSize.height);
    } else {
        self.scroll.frame = self.bounds;
        [self updateScrollThumb];
    }
}
// Private CALayer mesh support varies by OS. Probe the actual scroll layer,
// preserve its original state, and keep the existing affine fallback.
- (void)preparePlayerContentMeshes {
    self.morphContentMeshFrames = 0;
    self.morphContentMeshIndex = -1;
    CALayer *layer = self.scroll.layer;
    if (SGRReduceTransparency() || !SGLegacyGlassAvailable() ||
        ![layer respondsToSelector:NSSelectorFromString(@"setMeshTransform:")] ||
        ![layer respondsToSelector:NSSelectorFromString(@"meshTransform")]) return;
    @try {
        self.morphOriginalContentMesh = [layer valueForKey:@"meshTransform"];
        if (self.morphOriginalContentMesh) { self.morphOriginalContentMesh = nil; return; }
        NSMutableArray *meshes = [NSMutableArray arrayWithCapacity:12];
        for (NSUInteger i = 1; i <= 12; i++) {
            id mesh = SGLegacyPlayerContentMesh((CGFloat)i/12);
            if (!mesh) return;
            [meshes addObject:mesh];
        }
        self.morphContentMeshes = [meshes copy];
        // Probe before the animation; setting nil restores the original
        // layer. Successful KVC is not proof of compositor rendering.
        [layer setValue:meshes.lastObject forKey:@"meshTransform"];
        if (![layer valueForKey:@"meshTransform"]) {
            [self restorePlayerContentMesh];
            return;
        }
        [layer setValue:nil forKey:@"meshTransform"];
    } @catch (__unused NSException *exception) {
        [self restorePlayerContentMesh];
    }
}
- (void)restorePlayerContentMesh {
    if (self.morphContentMeshes.count) {
        @try { [self.scroll.layer setValue:self.morphOriginalContentMesh forKey:@"meshTransform"]; }
        @catch (__unused NSException *exception) {}
    }
    self.morphContentMeshes = nil;
    self.morphOriginalContentMesh = nil;
    self.morphContentMeshIndex = -1;
}
// Approximate the refractive displacement of the menu contents with a
// local affine derivative of a smooth radial field. Only individual glyphs
// and labels move; row layout, hit targets and the scroll viewport stay put.
// This is not a per-pixel warp: avoid an extra offscreen mesh/raster pass.
- (void)applyPlayerContentLens:(CGFloat)amount release:(CGFloat)release {
    amount = morphClamp(amount);
    release = morphClamp(release);
    BOOL meshActive = self.morphContentMeshes.count > 0;
    if (meshActive) {
        NSInteger index = (NSInteger)lround(amount*12);
        if (index != self.morphContentMeshIndex) {
            @try {
                id mesh = index > 0 ? self.morphContentMeshes[(NSUInteger)index-1] : self.morphOriginalContentMesh;
                [self.scroll.layer setValue:mesh forKey:@"meshTransform"];
                self.morphContentMeshIndex = index;
            } @catch (__unused NSException *exception) {
                [self restorePlayerContentMesh];
                meshActive = NO;
            }
        }
        if (meshActive && index > 0) self.morphContentMeshFrames++;
    }
    CGFloat hw = MAX(1, self.morphFinalSize.width/2);
    CGFloat hh = MAX(1, self.morphFinalSize.height/2);
    for (SGRDropdownPress *press in self.allButtons) {
        for (UIView *item in press.subviews) {
            if (![item isKindOfClass:UILabel.class] && ![item isKindOfClass:UIImageView.class]) continue;
            // Center is independent of the item's current affine transform.
            CGPoint p = [press convertPoint:item.center toView:self.body];
            CGFloat x = MAX(-1, MIN(1, (p.x-self.scroll.bounds.origin.x-hw)/hw));
            CGFloat y = MAX(-1, MIN(1, (p.y-self.scroll.bounds.origin.y-hh)/hh));
            // Native preview exposes the middle rows first. Suppress the
            // upper and lower glyphs while the rounded rim is still closed;
            // keep a continuous, position-dependent reveal during release.
            CGFloat edge = morphSmooth((fabs(y)-0.36)/0.48);
            CGFloat aperture = morphSmooth((release-0.18)/0.66);
            // The mesh itself carries the outer rows beyond the oval rim.
            // Don't hide them twice: native glyphs briefly bend into view.
            CGFloat opacity = 1-edge*(1-aperture)*(meshActive ? 0.32 : 0.96);
            if (item.alpha != opacity) item.alpha = opacity;
            CGAffineTransform next = CGAffineTransformIdentity;
            if (amount > 0 && !meshActive) {
                CGFloat r2 = x*x+y*y;
                // Bias the field toward the upper/lower edges. Keep the
                // central labels relatively stable while the quick actions
                // and More row stretch past the curved clipping boundary.
                CGFloat kx = 0.10*amount, ky = 0.30*amount;
                next = CGAffineTransformMake(1+kx*(3*x*x+y*y),
                    2*ky*x*y*hh/hw, 2*kx*x*y*hw/hh,
                    1+ky*(x*x+3*y*y), kx*x*r2*hw, ky*y*r2*hh);
            }
            if (!CGAffineTransformEqualToTransform(item.transform, next)) item.transform = next;
        }
    }
}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == self.scroll) [self updateScrollThumb];
}
- (void)updateScrollThumb {
    CGFloat visible = CGRectGetHeight(self.scroll.bounds);
    CGFloat total = self.scroll.contentSize.height;
    CGFloat overflow = total - visible;
    self.scrollThumb.hidden = !self.scroll.scrollEnabled || overflow < 1 || visible < 24;
    if (self.scrollThumb.hidden) return;
    CGFloat trackTop = 12, trackHeight = MAX(1, visible - 24);
    CGFloat thumbHeight = MIN(trackHeight, MAX(24, trackHeight * visible / MAX(total, 1)));
    CGFloat position = MIN(1, MAX(0, self.scroll.contentOffset.y / MAX(overflow, 1)));
    self.scrollThumb.frame = CGRectMake(CGRectGetWidth(self.bounds) - 6,
                                      trackTop + position * (trackHeight - thumbHeight),
                                      3, thumbHeight);
}
static UILabel *textLabel(NSString *title, UIFont *font, UIColor *color) {
    UILabel *label = [UILabel new];
    label.text = title;
    label.textColor = color;
    label.font = font;
    label.numberOfLines = 0;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    return label;
}
- (void)addRow:(SGRDropdownItem *)item at:(CGFloat)y {
    UIMenuElement *element = item.element;
    CGFloat h = rowHeight(element);
    SGRDropdownPress *press = [[SGRDropdownPress alloc] initWithFrame:CGRectMake(kInset, y, kWidth - 2*kInset, h)];
    press.element = element;
    press.pick = self.choose;
    BOOL enabled = !(dropdownAttributes(element) & UIMenuElementAttributesDisabled);
    press.enabled = enabled;
    press.accessibilityLabel = element.title;
    if ([element isKindOfClass:UIAction.class] &&
        [((UIAction *)element).identifier isEqualToString:@"Vitrine.Dropdown.DeferredStatus"])
        press.accessibilityIdentifier = @"Vitrine.Dropdown.DeferredStatus";
    if (element.subtitle.length) press.accessibilityValue = element.subtitle;
    UIColor *foreground = (dropdownAttributes(element) & UIMenuElementAttributesDestructive)
        ? [UIColor colorWithRed:1 green:0.36 blue:0.34 alpha:enabled ? 1 : 0.38]
        : [UIColor colorWithWhite:1 alpha:enabled ? 1 : 0.38];
    UIImageView *glyph = [[UIImageView alloc] initWithFrame:CGRectMake(14, (h-24)/2, 24, 24)];
    glyph.image = [element.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    glyph.tintColor = foreground;
    glyph.contentMode = UIViewContentModeScaleAspectFit;
    [press addSubview:glyph];
    // The reference's two-line Speed title is not a single, vertically
    // centred UIKit label. Reserve two lines above its secondary value.
    BOOL tallSubtitle = element.subtitle.length && h >= 79;
    BOOL wrapsTitle = !element.subtitle.length && h > kRow;
    CGFloat labelY = tallSubtitle ? 9 : (element.subtitle.length ? 9 : (wrapsTitle ? 10 : (h-22)/2));
    CGFloat labelHeight = tallSubtitle || wrapsTitle ? 44 : 23;
    CGFloat labelWidth = tallSubtitle ? 144 : 166;
    UILabel *name = textLabel(element.title, [UIFont systemFontOfSize:17 weight:UIFontWeightRegular], foreground);
    name.frame = CGRectMake(50, labelY, labelWidth, labelHeight);
    name.numberOfLines = tallSubtitle || wrapsTitle ? 2 : 1;
    [press addSubview:name];
    if (element.subtitle.length) {
        UILabel *detail = textLabel(element.subtitle, [UIFont systemFontOfSize:13], [UIColor colorWithWhite:1 alpha:enabled ? 0.65 : 0.32]);
        detail.frame = CGRectMake(50, tallSubtitle ? 54 : 32, 166, 18);
        detail.numberOfLines = 1;
        [press addSubview:detail];
    }
    if ([element isKindOfClass:UIMenu.class]) {
        UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        chevron.tintColor = [UIColor colorWithWhite:1 alpha:0.65];
        chevron.contentMode = UIViewContentModeScaleAspectFit;
        chevron.frame = CGRectMake(210, (h-16)/2, 9, 16);
        [press addSubview:chevron];
    } else if ([element isKindOfClass:UIAction.class] && ((UIAction *)element).state == UIMenuElementStateOn) {
        UIImageView *tick;
        if (self.homeFilterRoot) {
            // Keep the UIAction state intact (also for accessibility), but
            // match the native Home filter: small check in the leading icon slot.
            UIImageSymbolConfiguration *symbol =
                [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightMedium];
            tick = [[UIImageView alloc] initWithImage:
                [UIImage systemImageNamed:@"checkmark" withConfiguration:symbol]];
            tick.contentMode = UIViewContentModeCenter; // don't stretch 13pt to 24pt
            tick.frame = CGRectMake(14, (h-22)/2, 24, 22);
        } else {
            tick = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
            tick.frame = CGRectMake(206, (h-20)/2, 18, 20);
        }
        tick.tintColor = UIColor.whiteColor;
        [press addSubview:tick];
    }
    [self.body addSubview:press];
    [self.allButtons addObject:press];
}
- (void)addQuick:(NSArray<SGRDropdownItem *> *)items at:(CGFloat)y {
    if (!items.count) return;
    CGFloat height = quickHeight(items.count);
    BOOL single = items.count == 1;
    CGFloat tileWidth = (kWidth - 2*kInset)/items.count;
    UIView *tileGroup = [[UIView alloc] initWithFrame:CGRectMake(kInset, y, kWidth - 2*kInset, height)];
    tileGroup.accessibilityIdentifier = @"Vitrine.Dropdown.QuickActions";
    [self.body addSubview:tileGroup];
    self.tileGroup = tileGroup;
    for (NSUInteger i=0; i<items.count; i++) {
        UIMenuElement *element = items[i].element;
        SGRDropdownPress *press = [[SGRDropdownPress alloc] initWithFrame:CGRectMake(i*tileWidth, single ? 0 : 3,
                                                                                  tileWidth, single ? height : height-6)];
        press.element = element;
        press.pick = self.choose;
        press.accessibilityLabel = element.title;
        press.enabled = !(dropdownAttributes(element) & UIMenuElementAttributesDisabled);
        press.isTile = YES;
        UIImageView *image = [[UIImageView alloc] initWithFrame:CGRectMake((tileWidth-26)/2, single ? 16 : 14, 26, 26)];
        image.image = [element.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        image.tintColor = [UIColor colorWithWhite:1 alpha:press.enabled ? 1 : 0.4];
        image.contentMode = UIViewContentModeScaleAspectFit;
        [press addSubview:image];
        UILabel *title = textLabel(element.title, [UIFont systemFontOfSize:12 weight:UIFontWeightRegular], image.tintColor);
        title.textAlignment = NSTextAlignmentCenter;
        title.numberOfLines = 2;
        title.frame = CGRectMake(1, single ? 44 : 50, tileWidth-2, single ? 19 : 31);
        [press addSubview:title];
        [tileGroup addSubview:press];
        [self.tileButtons addObject:press];
        [self.allButtons addObject:press];
    }
}
- (BOOL)elasticInteractionActive {
    UIGestureRecognizerState state = self.surfaceTouch.state;
    return self.elasticDrag || self.elasticReturning || state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged;
}
- (void)settleElasticInteraction {
    if (![self elasticInteractionActive] && self.elasticSettled) self.elasticSettled();
}
- (void)updateSurfaceLight:(CGPoint)point {
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.touchLight.position = point;
    self.touchLight.opacity = 1;
    [CATransaction commit];
}
- (void)flashSurface:(UILongPressGestureRecognizer *)gesture {
    UIGestureRecognizerState state = gesture.state;
    if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged) {
        if (self.morphing) return;
        CGPoint point = [gesture locationInView:self];
        CGFloat prior = ((CALayer *)self.touchLight.presentationLayer ?: self.touchLight).opacity;
        [self updateSurfaceLight:point];
        if (state == UIGestureRecognizerStateBegan) {
#if SG_DRIVER
            SGLog(@"stage205 popup touch: begin point=%@",NSStringFromCGPoint(point));
#endif
            [self.touchLight removeAnimationForKey:@"Vitrine.TouchLight"];
            CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
            fade.fromValue = @(prior); fade.toValue = @1; fade.duration = 0.09;
            [self.touchLight addAnimation:fade forKey:@"Vitrine.TouchLight"];
        }
    } else if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled || state == UIGestureRecognizerStateFailed) {
#if SG_DRIVER
        SGLog(@"stage205 popup touch: end");
#endif
        if (self.elasticDrag) return; // the pan still owns this contact
        CGFloat prior = ((CALayer *)self.touchLight.presentationLayer ?: self.touchLight).opacity;
        [self.touchLight removeAnimationForKey:@"Vitrine.TouchLight"];
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        self.touchLight.opacity = 0;
        [CATransaction commit];
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @(prior); fade.toValue = @0; fade.duration = 0.22;
        [self.touchLight addAnimation:fade forKey:@"Vitrine.TouchLight"];
        [self settleElasticInteraction];
    }
}
- (void)resetElastic {
    if (!self.elasticEnabled) return;
    self.elasticGeneration++; self.elasticReturning = NO;
    [self.layer removeAnimationForKey:@"Vitrine.ElasticReturn"];
    [self.touchLight removeAllAnimations];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.touchLight.opacity = 0;
    [CATransaction commit];
    if (!self.elasticDrag && CGAffineTransformIsIdentity(self.transform) && ![self.layer animationForKey:@"transform"]) return;
    self.elasticDrag = NO;
    self.dragIsScrolling = YES; // suppress selection on the interrupted touch
    [self highlightPress:nil notify:NO];
    [self.layer removeAllAnimations];
    self.transform = CGAffineTransformIdentity;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    if (recognizer != self.selectionPan || !self.elasticEnabled) return YES;
    // Sliders, switches and hosted scrolling controls must retain their own gestures.
    for (UIView *view = touch.view; view && view != self; view = view.superview) {
        if ([view isKindOfClass:UIControl.class] && ![view isKindOfClass:SGRDropdownPress.class] &&
            ![view.accessibilityIdentifier isEqualToString:@"Vitrine.Dropdown.Back"]) return NO;
        if ([view isKindOfClass:UIScrollView.class] && view != self.scroll) return NO;
    }
    return !self.morphing;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer
 shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    if (recognizer == self.surfaceTouch || other == self.surfaceTouch) return YES;
    return (recognizer == self.selectionPan && other == self.scroll.panGestureRecognizer) ||
           (other == self.selectionPan && recognizer == self.scroll.panGestureRecognizer);
}
- (SGRDropdownPress *)pressAtScrollPoint:(CGPoint)point {
    // Coordinates are in the UIScrollView viewport (including contentOffset).
    // Group separators and header chrome do not activate a command.
    for (SGRDropdownPress *press in self.allButtons) {
        if (!press.enabled || press.hidden) continue;
        CGRect area = [press convertRect:press.bounds toView:self.scroll];
        if (CGRectContainsPoint(area, point)) return press;
    }
    return nil;
}
- (void)highlightPress:(SGRDropdownPress *)press notify:(BOOL)notify {
    if (self.draggedPress == press) return;
    self.draggedPress = press;
    for (SGRDropdownPress *button in self.allButtons) button.highlighted = (button == press);
    if (press && notify) {
        [self.selectionFeedback selectionChanged];
        [self.selectionFeedback prepare];
    }
}
- (void)dragAcrossMenu:(UIPanGestureRecognizer *)pan {
    UIGestureRecognizerState state = pan.state;
    if (state == UIGestureRecognizerStateBegan) {
        CGPoint offset = self.scroll.contentOffset;
        if (self.elasticEnabled && !self.scroll.hidden) offset.y = MAX(0,MIN(offset.y,MAX(0,self.scroll.contentSize.height-self.scroll.bounds.size.height)));
        self.dragStartOffset = offset;
        self.dragIsScrolling = NO;
        self.elasticDrag = NO;
        if (self.elasticEnabled) {
            BOOL interrupted = self.elasticReturning;
            CALayer *live = (CALayer *)self.layer.presentationLayer;
            CGAffineTransform current = live ? live.affineTransform : self.transform;
            self.elasticGeneration++; self.elasticReturning = NO;
            [self.layer removeAnimationForKey:@"Vitrine.ElasticReturn"];
            self.transform = current; self.elasticStartTransform = current;
            self.elasticDrag = interrupted; // even a cancelled second pan must settle
        }
        [self.selectionFeedback prepare];
    }
    if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged) {
        // On tall menus a moving scroll view wins; releasing a scroll must
        // never select a destructive command behind the finger.
        CGPoint movement = [pan translationInView:self.superview];
        CGFloat maxOffset = MAX(0,self.scroll.contentSize.height-self.scroll.bounds.size.height);
        BOOL atEdge = (movement.y > 0 && self.dragStartOffset.y <= 1) ||
                      (movement.y < 0 && self.dragStartOffset.y >= maxOffset-1);
        BOOL elasticIntent = self.elasticEnabled && (self.elasticDrag || atEdge || fabs(movement.x)>fabs(movement.y)*1.15);
        if (self.scroll.scrollEnabled && !self.scroll.hidden && !elasticIntent &&
            fabs(self.scroll.contentOffset.y - self.dragStartOffset.y) > 7) self.dragIsScrolling = YES;
        if (self.elasticEnabled && !self.dragIsScrolling) {
            CGPoint delta = [pan translationInView:self.superview];
            // Preserve vertical scrolling on long menus; horizontal pulls and
            // drags on a non-scrolling surface become elastic after 22pt.
            BOOL horizontal = fabs(delta.x) > fabs(delta.y)*1.15;
            if (self.elasticDrag || (hypot(delta.x,delta.y) > 22 &&
                (horizontal || atEdge || !self.scroll.scrollEnabled || self.scroll.hidden))) {
                if (!self.elasticDrag) self.elasticHorizontal = horizontal;
                self.elasticDrag = YES;
                if (!self.scroll.hidden && self.scroll.scrollEnabled) self.scroll.contentOffset = self.dragStartOffset;
                [self highlightPress:nil notify:NO];
                // Use the anchor-facing edge as the pivot. Opposite edges
                // carry the visible displacement, not the centre of the pane.
                CGFloat dx = delta.x/(1+fabs(delta.x)/104.0);
                CGFloat dy = delta.y/(1+fabs(delta.y)/104.0);
                CGFloat width = MAX(1,self.bounds.size.width), height = MAX(1,self.bounds.size.height);
                CGFloat sx, sy;
                if (self.elasticHorizontal) {
                    dy *= 0.08;
                    sx = 1 + MIN(0.20,fabs(dx)/width*0.72);
                    sy = 1 - MIN(0.09,fabs(dx)/width*0.28);
                } else {
                    dx *= 0.08;
                    // Native vertical drag is mostly displacement, with a
                    // small stretch; the tall More sheet barely narrows.
                    sx = 1 - MIN(self.isSubmenu ? 0.012 : 0.035,fabs(dy)/width*(self.isSubmenu ? 0.05 : 0.14));
                    sy = 1 + MIN(self.isSubmenu ? 0.040 : 0.055,fabs(dy)/height*(self.isSubmenu ? 0.36 : 0.32));
                }
                CGFloat px = (self.elasticAnchor.x-0.5)*width;
                CGFloat py = (self.elasticAnchor.y-0.5)*height;
                CGFloat tx = (1-sx)*px + dx*0.12;
                // More drifts a little to the right as it is pulled down;
                // keep its resting frame unchanged and spring back together.
                if (self.isSubmenu && !self.elasticHorizontal) tx += MAX(0,dy)*0.15;
                CGFloat ty = (1-sy)*py + dy*(self.elasticHorizontal ? 0.12 : (self.isSubmenu ? 0.79 : 0.30));
                CGFloat blend = morphSmooth(hypot(delta.x,delta.y)/45);
                CGAffineTransform base = self.elasticStartTransform;
                self.transform = CGAffineTransformMake(morphMix(base.a,sx,blend),0,0,morphMix(base.d,sy,blend),
                    morphMix(base.tx,tx,blend),morphMix(base.ty,ty,blend));
                [self updateSurfaceLight:[pan locationInView:self]];
                return;
            }
        }
        SGRDropdownPress *candidate = (self.dragIsScrolling || self.scroll.hidden) ? nil :
            [self pressAtScrollPoint:[pan locationInView:self.scroll]];
        [self highlightPress:candidate notify:!self.dragIsScrolling];
    }
    if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled ||
        state == UIGestureRecognizerStateFailed) {
        if (self.elasticDrag) {
#if SG_DRIVER
            SGLog(@"stage207 popup elastic: release sx=%.3f sy=%.3f tx=%.2f ty=%.2f anchor=%@ submenu=%d",self.transform.a,self.transform.d,self.transform.tx,self.transform.ty,NSStringFromCGPoint(self.elasticAnchor),self.isSubmenu);
#endif
            self.elasticDrag = NO;
            self.dragIsScrolling = NO;
            [self highlightPress:nil notify:NO];
            // Sample an underdamped return explicitly. Model is identity;
            // the presentation runs through a small overshoot, then settles.
            CGAffineTransform initial = self.transform;
            NSUInteger generation = ++self.elasticGeneration;
            self.elasticReturning = YES;
            NSMutableArray *values = [NSMutableArray arrayWithCapacity:61];
            for (NSUInteger i=0;i<=60;i++) {
                CGFloat t=(CGFloat)i/60, q=1-dropdownSpringProgress(t,5.8,8.0);
                CGAffineTransform v=CGAffineTransformMake(1+(initial.a-1)*q,0,0,1+(initial.d-1)*q,initial.tx*q,initial.ty*q);
                [values addObject:[NSValue valueWithCATransform3D:CATransform3DMakeAffineTransform(v)]];
            }
            CAKeyframeAnimation *spring=[CAKeyframeAnimation animationWithKeyPath:@"transform"];
            spring.values=values; spring.duration=0.68; spring.calculationMode=kCAAnimationLinear;
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            self.transform=CGAffineTransformIdentity;
            [self.layer addAnimation:spring forKey:@"Vitrine.ElasticReturn"];
            [CATransaction commit];
            // The light follows the pan even if the long press was cancelled.
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            self.touchLight.opacity=0; [CATransaction commit];
            CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];
            fade.fromValue=@1; fade.toValue=@0; fade.duration=0.23;
            [self.touchLight addAnimation:fade forKey:@"Vitrine.TouchLight"];
            __weak SGRDropdownPanel *weakSelf=self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.69*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                SGRDropdownPanel *strongSelf=weakSelf;
                if (!strongSelf || strongSelf.elasticGeneration!=generation) return;
                strongSelf.elasticReturning=NO;
#if SG_DRIVER
                SGLog(@"stage207 popup elastic: settled submenu=%d",strongSelf.isSubmenu);
#endif
                [strongSelf settleElasticInteraction];
            });
            return;
        }
        SGRDropdownPress *selection = self.dragIsScrolling || self.scroll.hidden || state != UIGestureRecognizerStateEnded ? nil :
            [self pressAtScrollPoint:[pan locationInView:self.scroll]];
        [self highlightPress:nil notify:NO];
        if (selection) [selection activate];
        self.dragIsScrolling = NO;
    }
}
- (void)configure:(UIMenu *)menu title:(NSString *)title maxHeight:(CGFloat)maximum {
    self.menu = menu;
    self.header = nil; self.headerChevron = nil;
    for (UIView *child in [self.body.subviews copy]) [child removeFromSuperview];
    [self.tileButtons removeAllObjects];
    [self.allButtons removeAllObjects];
    self.draggedPress = nil;
    self.tileGroup = nil;
    CGFloat y = 0;
    if (title.length) {
        UIControl *head = [[UIControl alloc] initWithFrame:CGRectMake(0, 0, kWidth, kHeader)];
        head.accessibilityIdentifier = @"Vitrine.Dropdown.Back";
        [head addTarget:self action:@selector(backTapped) forControlEvents:UIControlEventTouchUpInside];
        UIImageView *leading = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]];
        leading.tintColor = UIColor.whiteColor;
        leading.contentMode = UIViewContentModeScaleAspectFit;
        leading.frame = CGRectMake(25, 20, 22, 22);
        [head addSubview:leading];
        UIImageView *back = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"]];
        back.tintColor = UIColor.whiteColor;
        back.contentMode = UIViewContentModeScaleAspectFit;
        back.frame = CGRectMake(215, 25, 12, 12);
        [head addSubview:back];
        UILabel *label = textLabel(title, [UIFont systemFontOfSize:15 weight:UIFontWeightMedium], UIColor.whiteColor);
        label.numberOfLines = 1;
        label.frame = CGRectMake(60, 19, 145, 24);
        [head addSubview:label];
        if (self.elasticEnabled) {
            leading.image = [(menu.image ?: [UIImage systemImageNamed:@"ellipsis.circle"]) imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            leading.frame = CGRectMake(24,19,24,24);
            label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
            back.image = [UIImage systemImageNamed:@"chevron.right"];
            back.transform = CGAffineTransformMakeRotation(M_PI_2);
        }
        self.header = head; self.headerChevron = back;
        [self.body addSubview:head];
        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(24, kHeader, kWidth-48, 1.0/UIScreen.mainScreen.scale)];
        line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.19];
        [self.body addSubview:line];
        y = kHeader+10;
    }
    NSArray<NSArray<SGRDropdownItem *> *> *groups = groupsOf(menu);
    y += topPadding(groups, title.length > 0);
    for (NSUInteger i=0; i<groups.count; ++i) {
        NSArray<SGRDropdownItem *> *group = groups[i];
        CGFloat gap = gapBeforeGroup(groups, i, title.length > 0);
        if (gap > 0) {
            CGFloat lineY = y + (gap == kSubmenuSectionGap ? 10 :
                                 groups[i-1].firstObject.tile ? 0 : 5);
            UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(24, lineY, kWidth-48, 1.0/UIScreen.mainScreen.scale)];
            separator.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
            [self.body addSubview:separator];
            y += gap;
        }
        if (group.firstObject.tile) { [self addQuick:group at:y]; y += quickHeight(group.count); }
        else for (SGRDropdownItem *item in group) { [self addRow:item at:y]; y += rowHeight(item.element); }
    }
    y += kBottomPadding;
    self.body.frame = CGRectMake(0, 0, kWidth, y);
    self.scroll.contentSize = self.body.bounds.size;
    self.actualHeight = MIN(MAX(1, y), maximum);
    self.scroll.scrollEnabled = y > self.actualHeight + 0.5;
    [self updateScrollThumb];
    self.bounds = CGRectMake(0, 0, kWidth, self.actualHeight);
    [self setNeedsLayout];
}
- (void)setStackDisplacement:(CGFloat)offset {
    CGPoint centre=self.center;
    centre.x += offset-self.stackOffset;
    self.stackOffset=offset; self.center=centre;
}
- (void)setSubmenuReveal:(CGFloat)reveal sourceHeight:(CGFloat)sourceHeight {
    reveal=morphClamp(reveal);
    // Reveal the rows through the expanding aperture instead of fading in
    // the whole list together. The same rule clips the rows on return.
    CGFloat content=morphSmooth(reveal/0.30);
    for (UIView *child in self.body.subviews) {
        if (child != self.header) child.alpha=content;
    }
    self.header.alpha=1;
    self.header.transform=CGAffineTransformMakeTranslation(0,(sourceHeight-kHeader)*0.5*(1-reveal));
    self.headerChevron.transform=CGAffineTransformMakeRotation(M_PI_2*reveal);
}
- (void)backTapped { if (self.back) self.back(); }
@end

@class SGRDropdownPresentation;
static __weak SGRDropdownPresentation *sg_hostedTransition;
@interface SGRDropdownPresentation : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIViewController *root;
@property (nonatomic, weak) UIView *anchor;
@property (nonatomic) BOOL homeFilterAnchor;
@property (nonatomic) BOOL legacyMorph;
@property (nonatomic) BOOL playerMaterial;
@property (nonatomic) BOOL deferInitialOpen;
@property (nonatomic) BOOL morphPopping;
@property (nonatomic) CGFloat closeInitialLens;
@property (nonatomic) CGFloat closeInitialAlpha;
@property (nonatomic) CGFloat closeInitialContentAlpha;
@property (nonatomic) CGFloat closeInitialMaterial;
@property (nonatomic) CGFloat closeHostedAlpha;
@property (nonatomic) BOOL morphHosted;
@property (nonatomic, strong) UIView *hostedIncoming;
@property (nonatomic, strong) NSArray *hostedOriginalFilters;
@property (nonatomic, strong) NSArray *hostedMeshes;
@property (nonatomic, strong) id hostedOriginalMesh;
@property (nonatomic) NSInteger hostedMeshIndex;
@property (nonatomic) BOOL hostedMeshProbed;
@property (nonatomic, strong) CADisplayLink *morphLink;
@property (nonatomic, weak) SGRDropdownPanel *morphPanel;
@property (nonatomic) CGRect morphFrom;
@property (nonatomic) CGRect morphTo;
@property (nonatomic) CFTimeInterval morphLastFrame;
@property (nonatomic) NSTimeInterval morphElapsed;
@property (nonatomic) NSTimeInterval morphDuration;
@property (nonatomic) BOOL morphFromParent;
@property (nonatomic) BOOL morphReversing;
@property (nonatomic, strong) UIMenuElement *reverseSelection;
@property (nonatomic) BOOL hostedTransitioning;
#if SG_DRIVER
@property (nonatomic) CFTimeInterval rootMorphSetupAt;
@property (nonatomic) CFTimeInterval rootMorphFirstTick;
@property (nonatomic) NSUInteger rootMorphTicks;
@property (nonatomic) NSUInteger rootMorphCappedTicks;
@property (nonatomic) NSTimeInterval rootMorphMaxDelta;
@property (nonatomic) NSUInteger rootMorphPreviewTicks;
#endif
@property (nonatomic, strong) UIMenu *morphPendingRoot;
@property (nonatomic, strong) UIMenu *rootMenu;
@property (nonatomic, strong) UIViewController *embedded;
@property (nonatomic) BOOL embeddedFollowsContentSize;
@property (nonatomic, copy) SGRDropdownFinish finish;
@property (nonatomic, strong) NSMutableArray<SGRDropdownPanel *> *panels;
@property (nonatomic, strong) NSMutableArray<NSString *> *menuIDs;
@property (nonatomic) CGRect origin;
@property (nonatomic) BOOL closing;
@property (nonatomic) BOOL popping;
- (void)finishDismiss:(UIMenuElement *)element;
- (BOOL)start:(UIMenu *)menu from:(UIView *)anchor finish:(SGRDropdownFinish)finish;
- (void)update:(UIMenu *)menu;
- (void)dismiss:(UIMenuElement *)element;
- (void)pushMenu:(UIMenu *)menu title:(NSString *)title;
- (void)popMenu;
- (void)showContent:(UIViewController *)controller preferredSize:(CGSize)size expanding:(BOOL)expanding;
- (void)refreshContentSize:(UIViewController *)controller;
- (CGRect)embeddedFrameForSize:(CGSize)size;
- (void)loadMenu:(UIMenu *)menu intoPanel:(SGRDropdownPanel *)panel title:(NSString *)title maximum:(CGFloat)maximum;
- (void)reflowPanel:(SGRDropdownPanel *)panel;
- (CGFloat)homeFilterYForHeight:(CGFloat)height;
- (void)animatePanelAppearance:(SGRDropdownPanel *)panel over:(SGRDropdownPanel *)parent;
- (void)finishPlayerMorph;
- (BOOL)beginCollapse:(SGRDropdownPanel *)panel to:(CGRect)destination popping:(BOOL)popping selection:(UIMenuElement *)selection;
- (CGRect)currentAnchorFrame;
- (void)finishHostedOptics;
- (void)applyStackParent:(SGRDropdownPanel *)parent child:(SGRDropdownPanel *)child offset:(CGFloat)offset rowAlpha:(CGFloat)rowAlpha;
- (void)restoreStackAppearance;
- (void)tickPlayerMorph:(CADisplayLink *)link;
- (BOOL)transitionToContent:(UIViewController *)controller preferredSize:(CGSize)size expanding:(BOOL)expanding;
@end

@implementation SGRDropdownPresentation
- (BOOL)start:(UIMenu *)menu from:(UIView *)anchor finish:(SGRDropdownFinish)finish {
    if (!anchor.window.windowScene || !menu) return NO;
    self.anchor = anchor;
    self.homeFilterAnchor = [anchor.accessibilityLabel isEqualToString:@"Filter Home"];
    self.legacyMorph = SGBelowiOS26() && SGUseLegacyGlass() && !UIAccessibilityIsReduceMotionEnabled();
    // All owned Legacy root dropdowns use the same lens geometry. This flag
    // now selects only the player-specific settled material, not the path.
    self.playerMaterial = self.legacyMorph && [menu.identifier isEqualToString:@"com.vitrine.systemmenu.top"];
    self.rootMenu = menu;
    self.finish = finish;
    self.panels = [NSMutableArray array];
    self.menuIDs = [NSMutableArray array];
    self.window = [[UIWindow alloc] initWithWindowScene:anchor.window.windowScene];
    self.window.frame = anchor.window.bounds;
    self.window.windowLevel = UIWindowLevelAlert + 1;
    self.window.backgroundColor = UIColor.clearColor;
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.root = [UIViewController new];
    self.root.view = [[UIView alloc] initWithFrame:self.window.bounds];
    self.root.view.backgroundColor = UIColor.clearColor;
    self.window.rootViewController = self.root;
    UIControl *outside = [[UIControl alloc] initWithFrame:self.root.view.bounds];
    outside.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [outside addTarget:self action:@selector(outsideTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.root.view addSubview:outside];
    self.window.hidden = NO;
    CGRect from = [anchor convertRect:anchor.bounds toView:nil];
    CGFloat width = CGRectGetWidth(self.window.bounds);
    CGFloat x = MIN(width-kWidth-12, MAX(12, CGRectGetMaxX(from)-kWidth));
    CGFloat top = MAX(62, self.window.safeAreaInsets.top);
    CGFloat y = CGRectGetMinY(from) <= top + 24 ? top : CGRectGetMinY(from);
    CGFloat available = CGRectGetHeight(self.window.bounds)-self.window.safeAreaInsets.bottom-12;
    // Deferred-only menus must reserve a loading row before their callbacks
    // arrive; otherwise UIKit buttons near the bottom anchor a 10pt panel.
    SGRDropdownResolution *probe = [[SGRDropdownResolution alloc] initWithMenu:menu anchor:self.anchor];
    CGFloat wanted = MIN(kPanelMaximum, contentHeight([probe snapshot], NO));
    if (y+wanted > available) y = MAX(top, available-wanted);
    self.origin = CGRectMake(x, y, kWidth, wanted);
    [self pushMenu:menu title:nil];
    return YES;
}
// A submenu keeps the same lower edge as the menu stack, rather than a
// constant offset from its parent top. On the measured iOS 26 player menu,
// a 418pt More panel begins at y=164, while a 508pt More begins at y=74:
// both end at y=582 (root y=62 + max stack height 520).
- (CGFloat)submenuStackBottom {
    CGFloat safeBottom = CGRectGetHeight(self.root.view.bounds) - self.window.safeAreaInsets.bottom - 12;
    return MIN(safeBottom, CGRectGetMinY(self.origin) + kPanelMaximum);
}
- (CGFloat)minimumSubmenuTop:(UIMenu *)menu {
    CGFloat bottom = [self submenuStackBottom];
    BOOL playerMore = self.legacyMorph && [menu.identifier isEqualToString:@"com.vitrine.systemmenu.more"];
    // The native tall More reaches the same top edge as its parent. The
    // parent peeks out on the right as it shifts back, not via a 24pt cap.
    return MIN(bottom - 1, MAX(62, CGRectGetMinY(self.origin) + (playerMore ? 0 : kSubmenuDrop)));
}
- (CGFloat)submenuYForHeight:(CGFloat)height menu:(UIMenu *)menu {
    return MAX([self minimumSubmenuTop:menu], [self submenuStackBottom] - height);
}
- (CGFloat)submenuAvailableHeight:(UIMenu *)menu {
    return MAX(1, [self submenuStackBottom] - [self minimumSubmenuTop:menu]);
}
- (void)applyStackParent:(SGRDropdownPanel *)parent child:(SGRDropdownPanel *)child offset:(CGFloat)offset rowAlpha:(CGFloat)rowAlpha {
    if (!self.legacyMorph || !parent || !child) return;
    [parent setStackDisplacement:offset];
    for (SGRDropdownPress *press in parent.allButtons) {
        UIMenuElement *item=press.element;
        if ([item isKindOfClass:UIMenu.class] && [((UIMenu *)item).identifier isEqual:child.menu.identifier] && [item.title isEqual:child.menu.title]) {
            // A row returning to the parent is not a pressed control. A
            // cancelled UIKit touch can otherwise leave its grey overlay.
            [press setHighlighted:NO];
            [press.highlight.layer removeAllAnimations];
            press.highlight.alpha=0;
            press.alpha=rowAlpha; break;
        }
    }
}
- (void)restoreStackAppearance {
    if (!self.legacyMorph) return;
    for (NSUInteger i=1;i<self.panels.count;i++) {
        SGRDropdownPanel *child=self.panels[i];
        if (!child.waitingForDeferred) [self applyStackParent:self.panels[i-1] child:child offset:8 rowAlpha:0];
    }
}
- (void)outsideTapped { [self dismiss:nil]; }
- (void)backTapped { [self popMenu]; }
- (void)popMenu {
    if (self.closing || self.popping) return;
    if (self.panels.count < 2) { [self dismiss:nil]; return; }
    self.popping = YES;
    SGRDropdownPanel *top = self.panels.lastObject;
    SGRDropdownPanel *under = self.panels[self.panels.count - 2];
    [top.resolution cancel];
    top.userInteractionEnabled = NO;
    [top resetElastic];
    [under resetElastic];
    if (self.legacyMorph) {
        CGRect source = top.submenuSource;
        for (SGRDropdownPress *press in under.allButtons) {
            UIMenuElement *item = press.element;
            if ([item isKindOfClass:UIMenu.class] && [((UIMenu *)item).identifier isEqual:top.menu.identifier] && [item.title isEqual:top.menu.title]) {
                source = CGRectOffset([press convertRect:press.bounds toView:self.root.view],-under.stackOffset,0); break;
            }
        }
        if ([self beginCollapse:top to:source popping:YES selection:nil]) return;
        [self applyStackParent:under child:top offset:0 rowAlpha:1];
    }
    [self finishPlayerMorph];
    [UIView animateWithDuration:kSubmenuTime delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                     animations:^{
        top.alpha = 0;
        if (self.legacyMorph) {
            CGFloat h = MIN(64,top.bounds.size.height);
            CGFloat y = CGRectGetMinY(top.frame);
            top.bounds = CGRectMake(0,0,top.bounds.size.width*0.86,h);
            top.center = CGPointMake(CGRectGetMidX(under.frame),y+h/2);
            [top layoutIfNeeded];
        } else top.transform = dropdownExitingTransform();
        under.alpha = 1;
        under.transform = CGAffineTransformIdentity;
    } completion:^(__unused BOOL finished) {
        if (self.panels.lastObject == top) {
            [top.resolution cancel];
            [top removeFromSuperview];
            [self.panels removeLastObject];
            [self.menuIDs removeLastObject];
        }
        if (self.legacyMorph && !self.closing) under.userInteractionEnabled = YES;
        self.popping = NO;
    }];
}
- (void)choose:(UIMenuElement *)element {
    if (self.closing || self.popping || self.hostedTransitioning) return;
    if ([element isKindOfClass:UIMenu.class]) { [self pushMenu:(UIMenu *)element title:element.title]; return; }
    if (dropdownAttributes(element) & UIMenuElementAttributesDisabled) return;
    if (self.legacyMorph && self.panels.count == 1 && [element isKindOfClass:UIAction.class] &&
        ([element.title isEqualToString:@"Speed, Pitch & Reverb"] || [element.title isEqualToString:@"Lyrics Source"])) {
        // These owned actions synchronously request hosted content. Reuse the
        // presentation before its finish callback destroys the original glass.
        sg_hostedTransition = self;
        SGRDropdownPerformAction(element);
        sg_hostedTransition = nil;
        if (self.embedded) return;
        [self dismiss:nil]; // action already fired; never fire it twice
        return;
    }
    [self dismiss:element];
}
// A deferred completion changes the existing panel's content in-place. The
// resolution belongs to that panel and is invalidated on update/dismiss/back;
// late callbacks must never reconstruct a dismissed or replaced menu.
- (void)loadMenu:(UIMenu *)menu intoPanel:(SGRDropdownPanel *)panel title:(NSString *)title maximum:(CGFloat)maximum {
    [panel.resolution cancel];
    SGRDropdownResolution *resolution = [[SGRDropdownResolution alloc] initWithMenu:menu anchor:self.anchor];
    panel.resolution = resolution;
    [panel configure:[resolution snapshot] title:title maxHeight:maximum];
    __weak SGRDropdownPresentation *weakSelf = self;
    __weak SGRDropdownPanel *weakPanel = panel;
    __weak SGRDropdownResolution *weakResolution = resolution;
    resolution.didChange = ^(UIMenu *snapshot) {
        SGRDropdownPresentation *strongSelf = weakSelf;
        SGRDropdownPanel *livePanel = weakPanel;
        if (!strongSelf || !strongSelf.window || strongSelf.closing || !livePanel ||
            livePanel.resolution != weakResolution || ![strongSelf.panels containsObject:livePanel]) return;
        if (strongSelf.legacyMorph && strongSelf.embedded) return;
        BOOL interacting = NO;
        for (SGRDropdownPanel *other in strongSelf.panels) if ([other elasticInteractionActive]) { interacting=YES; break; }
        if (strongSelf.morphLink || interacting) {
            // Keep geometry stable while the live surface is moving. Rebuild
            // from the latest provider snapshot after the transition.
            livePanel.morphRefreshQueued = YES;
            return;
        }
        [livePanel resetElastic];
        CGPoint offset = livePanel.scroll.contentOffset;
        [livePanel configure:snapshot title:title maxHeight:maximum];
        [strongSelf reflowPanel:livePanel];
        [strongSelf restoreStackAppearance];
        // Deferred items should not flash a temporary Loading row when the
        // provider resolves within the short invisible preparation window.
        if (livePanel.waitingForDeferred && ![livePanel.resolution hasPending]) {
            livePanel.waitingForDeferred = NO;
            SGRDropdownPanel *under = nil;
            NSUInteger index = [strongSelf.panels indexOfObject:livePanel];
            if (index != NSNotFound && index > 0) under = strongSelf.panels[index-1];
            [strongSelf animatePanelAppearance:livePanel over:under];
        }
        CGFloat maxOffset = MAX(0, livePanel.scroll.contentSize.height - livePanel.bounds.size.height);
        livePanel.scroll.contentOffset = CGPointMake(offset.x, MIN(offset.y, maxOffset));
    };
}
// Home filter lives in Spotify's moving header. Resolve its CURRENT button
// origin in the overlay window on each data refresh; the generic origin is
// only a snapshot of the initial deferred (often one-row) menu.
- (CGFloat)homeFilterYForHeight:(CGFloat)height {
    CGFloat top = MAX(62, self.window.safeAreaInsets.top);
    CGFloat bottom = CGRectGetHeight(self.root.view.bounds) - self.window.safeAreaInsets.bottom - 12;
    CGFloat wanted = self.origin.origin.y;
    if (self.anchor.window) {
        CGRect inSourceWindow = [self.anchor convertRect:self.anchor.bounds toView:nil];
        CGRect inOverlay = [self.window convertRect:inSourceWindow fromWindow:self.anchor.window];
        if (!CGRectIsNull(inOverlay) && !CGRectIsEmpty(inOverlay)) wanted = CGRectGetMinY(inOverlay);
    }
    // Prefer exact top-edge alignment; only move up if the panel physically
    // cannot fit below the button within the safe viewport.
    CGFloat y = MIN(MAX(wanted, top), MAX(top, bottom - height));
    CGFloat scale = UIScreen.mainScreen.scale;
    return round(y * scale) / scale;
}
- (void)reflowPanel:(SGRDropdownPanel *)panel {
    if (panel == self.panels.firstObject && self.homeFilterAnchor) {
        CGFloat y = [self homeFilterYForHeight:panel.actualHeight];
        self.origin = CGRectMake(self.origin.origin.x, y, kWidth, panel.actualHeight);
        // `frame` is undefined under the opening scale transform. Configure
        // already set bounds: move only the center to prevent a reflow jump.
        panel.center = CGPointMake(CGRectGetMidX(self.origin)+panel.stackOffset, y + panel.actualHeight/2);
    } else {
        CGRect frame = panel.frame;
        frame.size.height = panel.actualHeight;
        if (self.legacyMorph) frame.origin.x=self.origin.origin.x+panel.stackOffset;
        if (panel == self.panels.firstObject) {
            CGFloat top = MAX(62, self.window.safeAreaInsets.top);
            CGFloat bottom = CGRectGetHeight(self.window.bounds) - self.window.safeAreaInsets.bottom - 12;
            // Grow toward the top when async data arrives near the screen's foot;
            // do not hide actions outside the window or replay the opening motion.
            CGFloat y = MIN(self.origin.origin.y, MAX(top, bottom - panel.actualHeight));
            self.origin = CGRectMake(self.origin.origin.x, y, kWidth, panel.actualHeight);
            frame.origin.y = y;
        } else {
            frame.origin.y = [self submenuYForHeight:panel.actualHeight menu:panel.menu];
        }
        panel.frame = frame;
    }
    for (SGRDropdownPanel *other in self.panels) {
        if (other == panel || other == self.panels.firstObject || [other elasticInteractionActive]) continue;
        [other resetElastic];
        CGRect next = other.frame;
        if (self.legacyMorph) next.origin.x=self.origin.origin.x+other.stackOffset;
        next.origin.y = [self submenuYForHeight:other.actualHeight menu:other.menu];
        other.frame = next;
    }
}
- (void)pushMenu:(UIMenu *)menu title:(NSString *)title {
    if (self.closing || self.popping || self.panels.count >= 8) return;
    [self finishPlayerMorph];
    SGRDropdownPanel *parent = self.panels.lastObject;
    SGRDropdownPanel *panel = [[SGRDropdownPanel alloc] initWithFrame:CGRectZero];
    panel.isSubmenu = title.length > 0;
    if (self.legacyMorph && parent) {
        for (SGRDropdownPress *press in parent.allButtons) {
            UIMenuElement *item = press.element;
            if (item == menu || ([item isKindOfClass:UIMenu.class] &&
                [((UIMenu *)item).identifier isEqual:menu.identifier] && [item.title isEqual:menu.title])) {
                panel.submenuSource = [press convertRect:press.bounds toView:self.root.view];
                break;
            }
        }
    }
    panel.homeFilterRoot = !parent && self.homeFilterAnchor;
    __weak SGRDropdownPresentation *weakSelf = self;
    panel.choose = ^(UIMenuElement *element) { [weakSelf choose:element]; };
    panel.back = ^{ [weakSelf popMenu]; };
    // The root retains its anchor. Submenus share a lower edge with the
    // reference's 520pt menu stack; shorter menus begin farther down while
    // long menus use the available height and scroll internally.
    CGFloat maximum = parent ? [self submenuAvailableHeight:menu] :
        MAX(1, CGRectGetHeight(self.root.view.bounds) - self.window.safeAreaInsets.bottom - 12
            - MAX(62, self.window.safeAreaInsets.top));
    [self loadMenu:menu intoPanel:panel title:title maximum:MIN(kPanelMaximum, maximum)];
    CGFloat y = parent ? [self submenuYForHeight:panel.actualHeight menu:panel.menu] : self.origin.origin.y;
    CGRect frame = CGRectMake(self.origin.origin.x, y, kWidth, panel.actualHeight);
    panel.frame = frame;
    if (self.legacyMorph) {
        CGRect a = [self currentAnchorFrame];
        // Use the actual originating button, not the panel's centre. More
        // inherits the same attached edge as its root presentation.
        CGFloat fx = (CGRectGetMidX(a)-CGRectGetMinX(frame))/MAX(1,frame.size.width);
        CGFloat fy = (CGRectGetMidY(a)-CGRectGetMinY(frame))/MAX(1,frame.size.height);
        panel.elasticAnchor = CGPointMake(fx < 0.5 ? 0 : 1, fy < 0.5 ? 0 : 1);
        __weak SGRDropdownPanel *weakPanel=panel;
        panel.elasticSettled=^{
            SGRDropdownPresentation *owner=weakSelf; SGRDropdownPanel *live=weakPanel;
            if (!owner || !live || owner.closing || owner.morphLink || ![owner.panels containsObject:live]) return;
            for (SGRDropdownPanel *other in owner.panels) if ([other elasticInteractionActive]) return;
            UIMenu *pending=owner.morphPendingRoot; owner.morphPendingRoot=nil;
            if (pending) { [owner update:pending]; return; }
            for (SGRDropdownPanel *other in [owner.panels copy]) if (other.morphRefreshQueued) {
                other.morphRefreshQueued=NO;
                SGRDropdownResolution *resolution=other.resolution;
                if (resolution.didChange) resolution.didChange([resolution snapshot]);
            }
        };
    }
    if (self.legacyMorph && parent) parent.userInteractionEnabled = NO;
    [self.root.view addSubview:panel];
    [self.panels addObject:panel];
    [self.menuIDs addObject:menu.identifier ?: menu.title ?: @""];
    if (panel.homeFilterRoot) [self reflowPanel:panel];
    panel.alpha = 0;
    panel.transform = self.legacyMorph ? CGAffineTransformIdentity : dropdownEnteringTransform();
    panel.waitingForDeferred = YES;
    [panel.resolution begin];
    if (![panel.resolution hasPending]) {
        panel.waitingForDeferred = NO;
        if (!self.deferInitialOpen || parent) [self animatePanelAppearance:panel over:parent];
    } else {
        // Briefly hold the *whole* panel, not an empty or Loading shell.
        // A slow provider still gets an accessible loading state after 0.8s.
        __weak SGRDropdownPresentation *weakSelf = self;
        __weak SGRDropdownPanel *weakPanel = panel;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SGRDropdownPresentation *strongSelf = weakSelf;
            SGRDropdownPanel *livePanel = weakPanel;
            if (!strongSelf || !livePanel || strongSelf.closing || !strongSelf.window ||
                !livePanel.waitingForDeferred || ![strongSelf.panels containsObject:livePanel]) return;
            livePanel.waitingForDeferred = NO;
            SGRDropdownPanel *under = nil;
            NSUInteger index = [strongSelf.panels indexOfObject:livePanel];
            if (index != NSNotFound && index > 0) under = strongSelf.panels[index - 1];
            [strongSelf animatePanelAppearance:livePanel over:under];
        });
    }
}
- (void)animatePanelAppearance:(SGRDropdownPanel *)panel over:(SGRDropdownPanel *)parent {
    if ((self.closing && !self.morphReversing) || !self.window || ![self.panels containsObject:panel]) return;
    // Only the first reveal animates; deferred refreshes are in-place.
    if (self.legacyMorph) {
        if (self.morphPanel == panel && self.morphLink) return;
        [self finishPlayerMorph];
        CGRect target = panel.frame;
        CGRect source = target;
        if (parent) {
            // Grow from the selected row, never from the future header.
            source = panel.submenuSource;
            for (SGRDropdownPress *press in parent.allButtons) {
                UIMenuElement *item=press.element;
                if ([item isKindOfClass:UIMenu.class] && [((UIMenu *)item).identifier isEqual:panel.menu.identifier] && [item.title isEqual:panel.menu.title]) {
                    source=[press convertRect:press.bounds toView:self.root.view]; break;
                }
            }
            if (CGRectIsEmpty(source)) source = CGRectMake(CGRectGetMidX(parent.frame)-22,CGRectGetMidY(parent.frame)-22,44,44);
            panel.submenuSource = source;
#if SG_DRIVER
            SGLog(@"stage205 popup submenu: source=%@ target=%@",NSStringFromCGRect(source),NSStringFromCGRect(target));
#endif
        }
        else if (self.anchor.window) {
            CGRect windowRect = [self.anchor convertRect:self.anchor.bounds toView:self.anchor.window];
            CGRect overlayRect = [self.window convertRect:windowRect fromWindow:self.anchor.window];
            source = [self.root.view convertRect:overlayRect fromView:self.window];
        }
        if (!CGRectIsEmpty(source) && !CGRectIsNull(source) && !CGRectIsInfinite(source) &&
            !CGRectEqualToRect(source, target)) {
            self.morphPanel = panel;
            self.morphFrom = source;
            self.morphTo = target;
            self.morphDuration = parent ? kPlayerMorphMore : (self.morphReversing ? 0.34 : kPlayerMorphOpen);
            self.morphFromParent = parent != nil;
            panel.playerRootGlass = self.playerMaterial && parent == nil;
#if SG_DRIVER
            if (!parent) {
                self.rootMorphSetupAt = CACurrentMediaTime();
                self.rootMorphFirstTick = 0;
                self.rootMorphTicks = 0;
                self.rootMorphCappedTicks = 0;
                self.rootMorphMaxDelta = 0;
                self.rootMorphPreviewTicks = 0;
                panel.morphContentMeshFrames = 0;
            }
#endif
            panel.transform = CGAffineTransformIdentity;
            // Construct the full-size glass once before the visible transition.
            // The layout at the small starting rect must not switch to a
            // different mesh family or trigger a costly first-frame build.
            [panel setNeedsLayout];
            [panel layoutIfNeeded];
            UIView *glass = objc_getAssociatedObject(panel, &kOwnedGlassKey);
            if ([glass isKindOfClass:SGLegacyGlassView.class]) {
                panel.morphGlass = (SGLegacyGlassView *)glass;
                [panel.morphGlass layoutIfNeeded];
                panel.morphGlass.geometryTransitionActive = YES;
                {
                    NSMutableArray<NSValue *> *sizes = [NSMutableArray array];
                    NSMutableArray<NSNumber *> *radii = [NSMutableArray array];
                    NSMutableArray<NSNumber *> *amounts = [NSMutableArray array];
                    for (NSUInteger i = 0; i <= kPlayerMorphMeshSteps; i++) {
                        CGFloat t = (CGFloat)i/kPlayerMorphMeshSteps;
                        BOOL flight = !parent && !self.embedded;
                        CGFloat release = flight ? morphRelease(t) : morphGeometry(t);
                        CGFloat lens = parent ? dropdownSubmenuLens(t) : 1-release;
                        CGSize size = parent ? dropdownSubmenuFrame(source,target,t).size : (flight ? morphFlightFrame(source,target,t,release).size : morphRect(source,target,release).size);
                        [sizes addObject:[NSValue valueWithCGSize:size]];
                        [radii addObject:@(morphLensRadius(size,lens))];
                        [amounts addObject:@(0.42*lens)];
                    }
                    [panel.morphGlass prepareGeometryTransitionSizes:sizes radii:radii compactAmounts:amounts];
                    [panel.morphGlass applyGeometryTransitionMeshAtIndex:self.morphReversing ? kPlayerMorphMeshSteps : 0];
                }
            }
            panel.morphing = YES;
            panel.morphFinalSize = target.size;
            panel.morphLensAmount = parent ? dropdownSubmenuLens(0) : 1.0;
            panel.morphTintStep = -1;
            panel.morphRootMaterialAmount = self.morphReversing ? 1 : 0;
            panel.userInteractionEnabled = NO;
            if (parent) {
                parent.alpha = 1;
                parent.userInteractionEnabled = NO;
                [self applyStackParent:parent child:panel offset:0 rowAlpha:1];
                [panel setSubmenuReveal:0 sourceHeight:source.size.height];
            }
            panel.scroll.alpha = parent || self.morphReversing ? 1 : 0;
            // Submenu never consumes the content mesh in its frame loop.
            // Do not allocate/probe 12 unused meshes before the first frame.
            if (!parent) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                [panel preparePlayerContentMeshes];
                [panel applyPlayerContentLens:0 release:self.morphReversing ? 1 : 0];
                [CATransaction commit];
            }
            if (!parent && !SGRReduceTransparency()) {
                // Blur just the existing content, never the live backdrop.
                // Same CAFilter approach as PlayerMotion; fail soft if absent.
                @try {
                    id filter = SGFilterOfType(@"gaussianBlur");
                    if (filter) {
                        NSNumber *initialBlur = self.morphReversing ? @0 : (parent ? @3 : @8);
                        [filter setValue:initialBlur forKey:@"inputRadius"];
                        panel.scroll.layer.filters = @[filter];
                        panel.morphContentBlurStep = self.morphReversing ? 0 : (parent ? 3 : 8);
                    }
                } @catch (NSException *exception) {
                    panel.scroll.layer.filters = nil;
                }
            }
            panel.scrollThumb.alpha = 0;
            // The root surface is visible at the anchor; a submenu first
            // hands off the visible source row before revealing its glass.
            panel.alpha = parent ? 0 : 1;
            panel.frame = self.morphReversing ? target : source;
            [panel setNeedsLayout];
            [panel layoutIfNeeded];
            self.morphLastFrame = 0;
            self.morphElapsed = 0;
            self.morphLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tickPlayerMorph:)];
            [self.morphLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
            return;
        }
    }
    if (self.morphReversing) return;
    [UIView animateWithDuration:parent ? kSubmenuTime : kOpenTime delay:0
          usingSpringWithDamping:0.88 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{
        panel.alpha = 1;
        panel.transform = CGAffineTransformIdentity;
        if (parent) parent.alpha = 0.55;
    } completion:nil];
}
- (CGRect)currentAnchorFrame {
    if (!self.anchor.window || !self.window) return CGRectZero;
    CGRect rect = [self.anchor convertRect:self.anchor.bounds toView:self.anchor.window];
    return [self.root.view convertRect:[self.window convertRect:rect fromWindow:self.anchor.window] fromView:self.window];
}
- (BOOL)beginCollapse:(SGRDropdownPanel *)panel to:(CGRect)destination popping:(BOOL)popping selection:(UIMenuElement *)selection {
    if (!panel || CGRectIsEmpty(destination) || CGRectIsNull(destination) || CGRectIsInfinite(destination)) return NO;
    // Capture the actual model geometry before cancelling any active link.
    // In particular do not settle an interrupted open to its full-size end.
    CGRect from = panel.frame;
    CGFloat lens = panel.morphing ? panel.morphLensAmount : 0;
    CGFloat alpha = panel.alpha, contentAlpha = panel.scroll.alpha;
    CGFloat material = panel.morphing ? panel.morphRootMaterialAmount : 1;
    [self.morphLink invalidate]; self.morphLink = nil;
    [self finishHostedOptics];
    [panel.morphOutgoingContent removeFromSuperview]; panel.morphOutgoingContent = nil;
    self.morphPanel = panel;
    self.morphReversing = YES; self.morphPopping = popping; self.morphFromParent = popping;
    self.reverseSelection = selection;
    self.morphFrom = from; self.morphTo = destination;
    self.closeInitialLens = lens; self.closeInitialAlpha = alpha;
    self.closeInitialContentAlpha = contentAlpha; self.closeInitialMaterial = material;
    self.closeHostedAlpha = self.embedded.view.alpha;
    self.morphElapsed = 0; self.morphLastFrame = 0; self.morphDuration = popping ? 0.52 : 0.34;
    panel.userInteractionEnabled = NO;
    if (self.embedded) self.embedded.view.autoresizingMask = UIViewAutoresizingNone;
    if (!panel.morphing) panel.morphFinalSize = from.size;
    [panel setNeedsLayout]; [panel layoutIfNeeded];
    UIView *glass = objc_getAssociatedObject(panel,&kOwnedGlassKey);
    if ([glass isKindOfClass:SGLegacyGlassView.class]) {
        panel.morphGlass = (SGLegacyGlassView *)glass;
        panel.morphGlass.geometryTransitionActive = YES;
        NSMutableArray *sizes = [NSMutableArray array], *radii = [NSMutableArray array], *amounts = [NSMutableArray array];
        for (NSUInteger i=0;i<=kPlayerMorphMeshSteps;i++) {
            CGFloat t=(CGFloat)i/kPlayerMorphMeshSteps;
            CGSize size=dropdownCollapseFrame(from,destination,t,popping).size;
            CGFloat l=dropdownCloseLens(lens,t,popping);
            [sizes addObject:[NSValue valueWithCGSize:size]];
            [radii addObject:@(morphLensRadius(size,l))]; [amounts addObject:@(0.42*l)];
        }
        [panel.morphGlass prepareGeometryTransitionSizes:sizes radii:radii compactAmounts:amounts];
        [panel.morphGlass applyGeometryTransitionMeshAtIndex:0];
    }
    panel.morphing = YES;
    panel.morphLensAmount = lens;
    if (!popping && !panel.morphContentMeshes.count) [panel preparePlayerContentMeshes];
    self.morphLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tickPlayerMorph:)];
    [self.morphLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    return YES;
}
- (void)tickPlayerMorph:(CADisplayLink *)link {
    SGRDropdownPanel *panel = self.morphPanel;
    if (!panel || !self.window || (self.closing && !self.morphReversing)) { [self finishPlayerMorph]; return; }
    // Start at the first callback. Stage 198's unbounded elapsed clock
    // could consume the entire launch on a late callback. Bound each step
    // so the geometry cannot jump straight from the anchor to the menu.
    CFTimeInterval now = link.timestamp;
    NSTimeInterval delta = self.morphLastFrame > 0 ? MAX(0, now-self.morphLastFrame) : 0;
    // No 67ms jumps across the row handoff or the Home-style collapse.
    // Hosted settings keep their separate short transition budget.
    NSTimeInterval maxStep = self.morphHosted ? 1.0/15.0 : kPlayerRootMaxStep;
    self.morphElapsed += MIN(maxStep, delta);
    self.morphLastFrame = now;
    CGFloat progress = morphClamp(self.morphElapsed/self.morphDuration);
    CGFloat t = progress;
    if (self.morphReversing) {
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        panel.morphLensAmount = dropdownCloseLens(self.closeInitialLens,t,self.morphPopping);
        panel.morphRootMaterialAmount = self.closeInitialMaterial*(1-morphSmooth(t));
        panel.frame = dropdownCollapseFrame(self.morphFrom,self.morphTo,t,self.morphPopping);
        [panel.morphGlass applyGeometryTransitionMeshAtIndex:(NSUInteger)lround(t*kPlayerMorphMeshSteps)];
        // The row is already unpressed before it reaches the parent.
        // Crossfade the glass and the source row throughout the landing,
        // rather than leaving a bright grey capsule at the end.
        CGFloat landing=morphSmooth((t-0.56)/0.40);
        if (self.morphPopping) {
            CGFloat reveal=1-morphClamp(dropdownSubmenuProgress(t));
            panel.scroll.alpha=1;
            [panel setSubmenuReveal:reveal sourceHeight:self.morphTo.size.height];
            if (self.panels.count>1)
                [self applyStackParent:self.panels[self.panels.count-2] child:panel offset:8*reveal rowAlpha:landing];
        } else {
            panel.scroll.alpha=self.closeInitialContentAlpha*(1-morphSmooth(t/0.43));
            [panel applyPlayerContentLens:panel.morphLensAmount release:1-panel.morphLensAmount];
            NSInteger blur=(NSInteger)lround(7*morphSmooth(t/0.52));
            if (panel.morphContentBlurStep!=blur || !panel.scroll.layer.filters.count) {
                panel.morphContentBlurStep=blur;
                dropdownContentBlur(panel.scroll.layer,blur);
            }
        }
        if (self.embedded && panel == self.panels.firstObject) {
            self.embedded.view.alpha = self.closeHostedAlpha*(1-morphSmooth((t-0.10)/0.78));
            self.embedded.view.center = CGPointMake(CGRectGetMidX(panel.bounds),CGRectGetMidY(panel.bounds));
        }
        panel.alpha = self.closeInitialAlpha*(1-(self.morphPopping ? landing : morphSmooth((t-0.22)/0.78)));
        panel.scrollThumb.alpha = 0;
        [panel setNeedsLayout]; [panel layoutIfNeeded];
        [CATransaction commit];
        if (t >= 1) {
#if SG_DRIVER
            SGLog(@"stage205 popup collapse: pop=%d from=%@ to=%@",self.morphPopping,NSStringFromCGRect(self.morphFrom),NSStringFromCGRect(self.morphTo));
            self.rootMorphSetupAt = 0;
#endif
            if (self.morphPopping) {
                [self.morphLink invalidate]; self.morphLink = nil; self.morphPanel = nil;
                self.morphPopping = NO; self.morphReversing = NO;
                if (self.panels.count>1) [self applyStackParent:self.panels[self.panels.count-2] child:panel offset:0 rowAlpha:1];
                [panel removeFromSuperview];
                if (self.panels.lastObject == panel) { [self.panels removeLastObject]; [self.menuIDs removeLastObject]; }
                SGRDropdownPanel *under = self.panels.lastObject;
                under.alpha = 1; under.userInteractionEnabled = YES; self.popping = NO;
                UIMenu *pendingRoot = self.morphPendingRoot; self.morphPendingRoot = nil;
                if (pendingRoot) [self update:pendingRoot];
                for (SGRDropdownPanel *visible in [self.panels copy]) {
                    if (!visible.morphRefreshQueued) continue;
                    visible.morphRefreshQueued = NO;
                    SGRDropdownResolution *resolution = visible.resolution;
                    if (resolution.didChange) resolution.didChange([resolution snapshot]);
                }
            } else [self finishDismiss:self.reverseSelection];
        }
        return;
    }
    if (self.morphHosted) {
        CGFloat lens = dropdownHostedLens(t);
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        panel.morphLensAmount = lens;
        panel.morphRootMaterialAmount = 1-0.35*lens;
        panel.frame = morphRect(self.morphFrom,self.morphTo,morphSmooth(t));
        [panel.morphGlass applyGeometryTransitionMeshAtIndex:(NSUInteger)lround(t*kPlayerMorphMeshSteps)];
        UIView *old = panel.morphOutgoingContent, *incoming = self.hostedIncoming;
        old.center = CGPointMake(CGRectGetMidX(panel.bounds),CGRectGetMidY(panel.bounds));
        incoming.center = CGPointMake(CGRectGetMidX(panel.bounds),CGRectGetMidY(panel.bounds));
        old.alpha = 1-morphSmooth(t/0.58);
        incoming.alpha = morphSmooth((t-0.16)/0.74);
        NSInteger blur = (NSInteger)lround(7*lens);
        if (panel.morphContentBlurStep != blur) {
            panel.morphContentBlurStep = blur;
            dropdownContentBlur(old.layer,blur);
            if (!self.hostedOriginalFilters.count) dropdownContentBlur(incoming.layer,blur);
        }
        NSInteger idx = (NSInteger)lround(lens*12);
        if (idx != self.hostedMeshIndex && self.hostedMeshes.count == 12) {
            @try {
                [incoming.layer setValue:idx ? self.hostedMeshes[(NSUInteger)idx-1] : self.hostedOriginalMesh forKey:@"meshTransform"];
                [old.layer setValue:idx ? self.hostedMeshes[(NSUInteger)idx-1] : nil forKey:@"meshTransform"];
                self.hostedMeshIndex = idx;
            } @catch (__unused NSException *exception) { self.hostedMeshes = nil; }
        }
        [panel setNeedsLayout]; [panel layoutIfNeeded];
        [CATransaction commit];
        if (t >= 1) {
#if SG_DRIVER
            SGLog(@"stage206 popup hosted: completed=1 elapsed_ms=%.1f class=%@",self.morphElapsed*1000,NSStringFromClass(self.embedded.class));
#endif
            [self finishPlayerMorph];
        }
        return;
    }
#if SG_DRIVER
    if (!self.morphFromParent) {
        if (self.rootMorphTicks == 0) self.rootMorphFirstTick = CACurrentMediaTime();
        self.rootMorphTicks++;
        self.rootMorphMaxDelta = MAX(self.rootMorphMaxDelta, delta);
        if (delta > maxStep + 0.001) self.rootMorphCappedTicks++;
        if (t >= kPlayerReleaseStart && t <= kPlayerLaunchEnd) self.rootMorphPreviewTicks++;
    }
#endif
    CGFloat g = morphGeometry(t);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // More uses row-anchored vertical expansion without the root preview.
    // Root grows into a rounded preview before lifting and squaring off.
    BOOL flight = !self.morphFromParent && !self.embedded;
    CGFloat unfold = self.morphFromParent ? morphClamp(dropdownSubmenuProgress(t)) : (flight ? morphRelease(t) : g);
    panel.morphLensAmount = self.morphFromParent ? dropdownSubmenuLens(t) : 1.0-unfold;
    if (!flight) {
        panel.frame = self.morphFromParent ? dropdownSubmenuFrame(self.morphFrom,self.morphTo,t) : morphRect(self.morphFrom, self.morphTo, g);
        [panel.morphGlass applyGeometryTransitionMeshAtIndex:(NSUInteger)lround(t*kPlayerMorphMeshSteps)];
    } else {
        CGRect frame = morphFlightFrame(self.morphFrom, self.morphTo, t, unfold);
        // Keep the large rounded preview upright, as in the native capture.
        panel.bounds = (CGRect){CGPointZero, frame.size};
        panel.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        [panel.morphGlass applyGeometryTransitionMeshAtIndex:(NSUInteger)lround(t*kPlayerMorphMeshSteps)];
    }
    {
        BOOL filtered = panel.scroll.layer.filters.count > 0;
        CGFloat launch = flight ? morphGeometry(t/kPlayerLaunchEnd) : g;
        panel.morphRootMaterialAmount = morphSmooth((t-0.04)/0.36);
        panel.scroll.alpha = self.morphFromParent ? 1 :
            (filtered ? morphSmooth(t/0.24) * morphMix(0.88, 1, unfold) : morphSmooth((t-0.16)/0.58));
        if (self.morphFromParent && self.panels.count>1) {
            [panel setSubmenuReveal:unfold sourceHeight:self.morphFrom.size.height];
            CGFloat handoff=morphSmooth(t/0.23);
            panel.alpha=handoff;
            [self applyStackParent:self.panels[self.panels.count-2] child:panel offset:8*dropdownSubmenuProgress(t) rowAlpha:1-handoff];
        }
        // Softer centre and stronger rim displacement while the lens opens.
        // Remove all transforms on completion, including interrupted reveals.
        // The centre focuses ahead of the perimeter. Preserve the
        // edge stretch further into release instead of fading all optical
        // effects by the same linear factor.
        CGFloat edgeRelease = morphSmooth((unfold-0.18)/0.82);
        if (!self.morphFromParent) [panel applyPlayerContentLens:launch*(1-edgeRelease) release:unfold];
        NSInteger blurStep = (NSInteger)lround((self.morphFromParent ? 3 : morphMix(8, 7, launch))*pow(1-unfold, 0.90));
        if (filtered && panel.morphContentBlurStep != blurStep) {
            panel.morphContentBlurStep = blurStep;
            @try {
                [panel.scroll.layer setValue:@(blurStep) forKeyPath:@"filters.gaussianBlur.inputRadius"];
            } @catch (NSException *exception) {
                panel.scroll.layer.filters = nil;
            }
        }
    }
    if (self.embedded) {
        self.embedded.view.alpha = morphSmooth((t-0.18)/0.82);
        self.embedded.view.center = CGPointMake(CGRectGetMidX(panel.bounds),CGRectGetMidY(panel.bounds));
    }
    panel.morphOutgoingContent.alpha = 1-morphSmooth(t/0.30);
    panel.scrollThumb.alpha = 0;
    [panel setNeedsLayout];
    [panel layoutIfNeeded];
    [CATransaction commit];
    if (progress >= 1) [self finishPlayerMorph];
}
- (void)finishPlayerMorph {
    [self.morphLink invalidate];
    self.morphLink = nil;
    SGRDropdownPanel *panel = self.morphPanel;
    if (!panel) return;
    BOOL wasHosted = self.morphHosted;
#if SG_DRIVER
    if (!self.morphFromParent && self.rootMorphSetupAt > 0) {
        CFTimeInterval ended = CACurrentMediaTime();
        SGLog(@"stage204 player root: reverse=%d completed=%d setup_ms=%.1f wall_ms=%.1f elapsed_ms=%.1f ticks=%lu capped=%lu max_delta_ms=%.1f overlap_ticks=%lu content_mesh_frames=%lu",
              self.morphReversing, self.morphElapsed >= self.morphDuration,
              self.rootMorphFirstTick > 0 ? (self.rootMorphFirstTick-self.rootMorphSetupAt)*1000 : -1.0,
              self.rootMorphFirstTick > 0 ? (ended-self.rootMorphFirstTick)*1000 : -1.0,
              self.morphElapsed*1000, (unsigned long)self.rootMorphTicks,
              (unsigned long)self.rootMorphCappedTicks, self.rootMorphMaxDelta*1000,
              (unsigned long)self.rootMorphPreviewTicks, (unsigned long)panel.morphContentMeshFrames);
        self.rootMorphSetupAt = 0;
    } else if (self.morphFromParent) {
        SGLog(@"stage204 player more: completed=%d parent_visible=%d",self.morphElapsed >= self.morphDuration,self.panels.firstObject.alpha > 0.01);
    }
#endif
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    panel.transform = CGAffineTransformIdentity;
    panel.frame = self.morphTo;
    panel.morphing = NO;
    panel.morphLensAmount = 0;
    panel.morphTintStep = 0;
    panel.morphGlass.geometryTransitionActive = NO;
    panel.morphGlass = nil;
    [panel restorePlayerContentMesh];
    [panel applyPlayerContentLens:0 release:1];
    panel.scroll.layer.filters = nil;
    panel.alpha = 1;
    panel.scroll.alpha = 1;
    if (self.morphFromParent && self.legacyMorph) {
        [panel setSubmenuReveal:1 sourceHeight:self.morphFrom.size.height];
        [self restoreStackAppearance];
    }
    panel.scrollThumb.alpha = self.embedded ? 0 : 1;
    [self finishHostedOptics];
    self.morphPanel = nil;
    if (self.embedded) { self.embedded.view.alpha = 1; self.embedded.view.frame = panel.bounds;
        self.embedded.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; }
    [panel.morphOutgoingContent removeFromSuperview];
    panel.morphOutgoingContent = nil;
    panel.userInteractionEnabled = YES;
    [panel setNeedsLayout];
    [panel layoutIfNeeded];
    [CATransaction commit];
    UIMenu *pendingRoot = self.morphPendingRoot;
    self.morphPendingRoot = nil;
    if (self.closing || !self.window) return;
    if (wasHosted) [self refreshContentSize:self.embedded];
    if (pendingRoot) [self update:pendingRoot];
    for (SGRDropdownPanel *visible in [self.panels copy]) {
        if (!visible.morphRefreshQueued) continue;
        visible.morphRefreshQueued = NO;
        SGRDropdownResolution *resolution = visible.resolution;
        if (resolution.didChange) resolution.didChange([resolution snapshot]);
    }
}
static UIMenu *matchingSubmenu(UIMenu *root, NSString *identifier) {
    for (UIMenuElement *element in root.children) {
        if (![element isKindOfClass:UIMenu.class]) continue;
        UIMenu *child = (UIMenu *)element;
        if ([child.identifier isEqualToString:identifier]) return child;
        UIMenu *nested = matchingSubmenu(child, identifier);
        if (nested) return nested;
    }
    return nil;
}
// A hosted lyrics source list is measured from the actual provider rows, not
// the 520pt menu-stack limit. The screen's safe viewport is the only cap;
// ordinary dropdown menus and embedded fixed-size controls retain their own
// existing limits.
- (CGRect)embeddedFrameForSize:(CGSize)size {
    CGFloat top = MAX(62, self.window.safeAreaInsets.top + 12);
    CGFloat bottom = CGRectGetHeight(self.root.view.bounds) - self.window.safeAreaInsets.bottom - 12;
    CGFloat available = MAX(1, bottom - top);
    CGFloat cap = self.embeddedFollowsContentSize ? available : MIN(kPanelMaximum, available);
    CGFloat height = MIN(MAX(1, size.height), cap);
    CGFloat width = MIN(MAX(200, size.width), MAX(1, CGRectGetWidth(self.root.view.bounds) - 24));
    CGFloat x = MAX(12, MIN(CGRectGetWidth(self.root.view.bounds) - width - 12,
                            CGRectGetMaxX(self.origin) - width));
    CGFloat y = MIN(MAX(top, CGRectGetMinY(self.origin)), MAX(top, bottom - height));
    return CGRectMake(x, y, width, height);
}
- (void)refreshContentSize:(UIViewController *)controller {
    if (self.hostedTransitioning || !self.embeddedFollowsContentSize || self.embedded != controller ||
        !self.window || self.closing || !self.panels.count) return;
    SGRDropdownPanel *panel = self.panels.firstObject;
    if ([panel elasticInteractionActive]) return;
    CGRect next = [self embeddedFrameForSize:controller.preferredContentSize];
    if (CGRectEqualToRect(next, panel.frame)) return;
    [panel resetElastic];
    [UIView animateWithDuration:0.18 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        panel.frame = next;
        controller.view.frame = panel.bounds;
    } completion:nil];
}
- (void)finishHostedOptics {
    if (!self.morphHosted) return;
    UIView *incoming = self.hostedIncoming;
    incoming.layer.filters = self.hostedOriginalFilters;
    if (self.hostedMeshProbed) {
        @try { [incoming.layer setValue:self.hostedOriginalMesh forKey:@"meshTransform"]; } @catch (__unused NSException *exception) {}
    }
    self.hostedMeshProbed = NO;
    incoming.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.morphPanel.morphOutgoingContent removeFromSuperview];
    self.hostedIncoming = nil; self.hostedMeshes = nil; self.hostedOriginalMesh = nil;
    self.hostedOriginalFilters = nil; self.morphHosted = NO; self.hostedTransitioning = NO;
}
- (BOOL)transitionToContent:(UIViewController *)controller preferredSize:(CGSize)size expanding:(BOOL)expanding {
    if (!self.legacyMorph || self.closing || self.embedded || !self.window || !controller || self.panels.count != 1) return NO;
    [self finishPlayerMorph];
    SGRDropdownPanel *panel = self.panels.firstObject;
    [panel resetElastic]; [panel.resolution cancel];
    panel.userInteractionEnabled = NO;
    self.hostedTransitioning = YES;
    CGRect from = panel.frame;
    UIView *old = [panel.scroll snapshotViewAfterScreenUpdates:NO];
    old.frame = panel.bounds; old.userInteractionEnabled = NO;
    if (old) [panel addSubview:old];
    panel.morphOutgoingContent = old;
    UIView *content = controller.view;
    CGSize measured = controller.preferredContentSize;
    if (measured.width <= 0) measured.width = size.width;
    if (measured.height <= 0) measured.height = size.height;
    CGRect target = [self embeddedFrameForSize:measured];
    self.embedded = controller; self.embeddedFollowsContentSize = expanding;
    panel.scroll.hidden = YES; panel.scrollThumb.hidden = YES;
    [self.root addChildViewController:controller];
    content.bounds = (CGRect){CGPointZero,target.size};
    content.center = CGPointMake(CGRectGetMidX(panel.bounds),CGRectGetMidY(panel.bounds));
    content.autoresizingMask = UIViewAutoresizingNone;
    content.backgroundColor = UIColor.clearColor; content.alpha = 0;
    [panel addSubview:content]; [controller didMoveToParentViewController:self.root];
    [content layoutIfNeeded];
    self.hostedIncoming = content;
    self.hostedOriginalFilters = content.layer.filters;
    self.hostedMeshIndex = -1;
    if (!SGRReduceTransparency() && [content.layer respondsToSelector:NSSelectorFromString(@"setMeshTransform:")]) {
        @try {
            self.hostedOriginalMesh = [content.layer valueForKey:@"meshTransform"];
            self.hostedMeshProbed = YES;
            NSMutableArray *meshes = [NSMutableArray array];
            for (NSUInteger i=1;i<=12;i++) {
                id mesh = SGLegacyPlayerContentMesh((CGFloat)i/12);
                if (!mesh) break;
                [meshes addObject:mesh];
            }
            if (meshes.count == 12) self.hostedMeshes = meshes;
        } @catch (__unused NSException *exception) { self.hostedMeshes = nil; }
    }
    self.morphPanel = panel; self.morphFrom = from; self.morphTo = target;
    self.morphHosted = YES; self.morphFromParent = NO;
    self.morphDuration = 0.29; self.morphElapsed = 0; self.morphLastFrame = 0;
    UIView *glass = objc_getAssociatedObject(panel,&kOwnedGlassKey);
    if ([glass isKindOfClass:SGLegacyGlassView.class]) {
        panel.morphGlass = (SGLegacyGlassView *)glass;
        panel.morphGlass.geometryTransitionActive = YES;
        NSMutableArray *sizes = [NSMutableArray array], *radii = [NSMutableArray array], *amounts = [NSMutableArray array];
        for (NSUInteger i=0;i<=kPlayerMorphMeshSteps;i++) {
            CGFloat t = (CGFloat)i/kPlayerMorphMeshSteps, lens = dropdownHostedLens(t);
            CGSize size = morphRect(from,target,morphSmooth(t)).size;
            [sizes addObject:[NSValue valueWithCGSize:size]];
            [radii addObject:@(morphLensRadius(size,lens))]; [amounts addObject:@(0.42*lens)];
        }
        [panel.morphGlass prepareGeometryTransitionSizes:sizes radii:radii compactAmounts:amounts];
        [panel.morphGlass applyGeometryTransitionMeshAtIndex:0];
    }
    panel.morphing = YES; panel.morphFinalSize = target.size; panel.morphLensAmount = 0;
    panel.morphContentBlurStep = -1;
    self.morphLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tickPlayerMorph:)];
    [self.morphLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    return YES;
}
- (void)showContent:(UIViewController *)controller preferredSize:(CGSize)size expanding:(BOOL)expanding {
    if (!controller || !self.window || !self.panels.count) return;
    [self finishPlayerMorph];
    SGRDropdownPanel *panel = self.panels.firstObject;
    panel.scroll.hidden = YES;
    // Accessing the view runs viewDidLoad: the lyrics provider can rebuild the
    // table and replace the temporary 200pt preferred size before first reveal.
    UIView *contentView = controller.view;
    CGSize measured = controller.preferredContentSize;
    if (measured.width <= 0) measured.width = size.width;
    if (measured.height <= 0) measured.height = size.height;
    self.embeddedFollowsContentSize = expanding;
    self.embedded = controller;
    panel.frame = [self embeddedFrameForSize:measured];
    [self.root addChildViewController:controller];
    contentView.frame = panel.bounds;
    contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    contentView.backgroundColor = UIColor.clearColor;
    [panel addSubview:contentView];
    [controller didMoveToParentViewController:self.root];
    [panel.layer removeAllAnimations];
    panel.alpha = 0;
    if (self.legacyMorph) {
        panel.transform = CGAffineTransformIdentity;
        contentView.alpha = 0;
        contentView.autoresizingMask = UIViewAutoresizingNone;
        [self animatePanelAppearance:panel over:nil];
        return;
    }
    panel.transform = dropdownEnteringTransform();
    [UIView animateWithDuration:kOpenTime delay:0
          usingSpringWithDamping:0.88 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{
        panel.alpha = 1;
        panel.transform = CGAffineTransformIdentity;
    } completion:nil];
}
- (void)update:(UIMenu *)menu {
    if (!menu || !self.window || self.closing || self.popping || (self.legacyMorph && self.embedded)) return;
    if (self.morphLink) { self.morphPendingRoot = menu; return; }
    for (SGRDropdownPanel *panel in self.panels) if ([panel elasticInteractionActive]) { self.morphPendingRoot=menu; return; }
    for (SGRDropdownPanel *panel in self.panels) [panel resetElastic];
    self.rootMenu = menu;
    SGRDropdownPanel *first = self.panels.firstObject;
    CGPoint offset = first.scroll.contentOffset;
    CGFloat bottom = CGRectGetHeight(self.window.bounds) - self.window.safeAreaInsets.bottom - 12;
    [self loadMenu:menu intoPanel:first title:nil maximum:MIN(kPanelMaximum, MAX(1, bottom-self.origin.origin.y))];
    [first.resolution begin];
    if (self.homeFilterAnchor) [self reflowPanel:first];
    else first.frame = CGRectMake(self.origin.origin.x+first.stackOffset, self.origin.origin.y, kWidth, first.actualHeight);
    first.scroll.contentOffset = offset;
    if (self.panels.count < 2) return;
    for (NSUInteger i=1; i<self.panels.count; ++i) {
        UIMenu *sub = matchingSubmenu(menu, self.menuIDs[i]);
        if (!sub) continue;
        SGRDropdownPanel *panel = self.panels[i];
        CGPoint prior = panel.scroll.contentOffset;
        [self loadMenu:sub intoPanel:panel title:sub.title maximum:MIN(kPanelMaximum, [self submenuAvailableHeight:sub])];
        [panel.resolution begin];
        CGRect frame = panel.frame;
        if (self.legacyMorph) frame.origin.x=self.origin.origin.x+panel.stackOffset;
        frame.origin.y = [self submenuYForHeight:panel.actualHeight menu:panel.menu];
        frame.size.height = panel.actualHeight;
        panel.frame = frame;
        panel.scroll.contentOffset = prior;
    }
    [self restoreStackAppearance];
}
- (void)finishDismiss:(UIMenuElement *)element {
    self.closing = YES;
    self.reverseSelection = nil;
    // Hide first; never restore an opening end frame while dismissing.
    self.window.hidden = YES;
    [self.morphLink invalidate]; self.morphLink = nil;
    [self finishHostedOptics];
    self.morphPanel = nil;
    self.morphReversing = NO; self.morphPopping = NO;
    if (!self.window) return;
    SGRDropdownFinish finish = self.finish;
    self.finish = nil;
    self.window.hidden = YES;
    self.window.rootViewController = nil;
    self.window = nil;
    for (SGRDropdownPanel *panel in self.panels) [panel.resolution cancel];
    [self.panels removeAllObjects];
    self.root = nil;
    if (finish) finish(element);
}
- (void)dismiss:(UIMenuElement *)element {
    if (!self.window || self.closing) return;
    self.closing = YES;
    for (SGRDropdownPanel *panel in self.panels) [panel.resolution cancel];
    UIView *surface = self.root.view;
    surface.userInteractionEnabled = NO;
    if (self.legacyMorph && self.anchor.window && self.panels.count) {
        SGRDropdownPanel *front = self.panels.lastObject;
        for (SGRDropdownPanel *panel in self.panels) {
            [panel resetElastic];
            if (panel != front) [UIView animateWithDuration:0.20 animations:^{ panel.alpha = 0; }];
        }
        if ([self beginCollapse:front to:[self currentAnchorFrame] popping:NO selection:element]) return;
    }
    [self finishPlayerMorph];
    [UIView animateWithDuration:kDismissTime delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                     animations:^{
        surface.alpha = 0;
        for (SGRDropdownPanel *panel in self.panels) {
            panel.alpha = 0;
            panel.transform = dropdownExitingTransform();
        }
    } completion:^(__unused BOOL finished) { [self finishDismiss:element]; }];
}
@end

static SGRDropdownPresentation *sg_currentDropdown;
static BOOL sgrDropdownPresentInternal(UIView *anchor, UIMenu *menu, SGRDropdownFinish finished, BOOL hosted) {
    if (!anchor.window || !menu) return NO;
    // If Spotify supplied a responder-chain or pre-hook provider with no
    // accessible block, never steal the native presentation and show a blank.
    if (!SGRDropdownDeferredMenuSupported(menu, anchor)) return NO;
    if (sg_currentDropdown) {
        if (sg_currentDropdown.anchor == anchor && sg_currentDropdown.window && !sg_currentDropdown.closing) return YES;
        // Replacing an existing menu is immediate: no dying overlay above the
        // next window, and no delayed callback into a new menu session.
        [sg_currentDropdown finishDismiss:nil];
        sg_currentDropdown = nil;
    }
    SGRDropdownPresentation *showing = [SGRDropdownPresentation new];
    showing.deferInitialOpen = hosted && SGBelowiOS26() && SGUseLegacyGlass() && !UIAccessibilityIsReduceMotionEnabled();
    __weak SGRDropdownPresentation *weakShowing = showing;
    if (![showing start:menu from:anchor finish:^(UIMenuElement *element) {
        if (sg_currentDropdown == weakShowing) sg_currentDropdown = nil;
        if (finished) finished(element);
    }]) return NO;
    sg_currentDropdown = showing;
    return YES;
}
BOOL SGRDropdownPresent(UIView *anchor, UIMenu *menu, SGRDropdownFinish finished) {
    return sgrDropdownPresentInternal(anchor,menu,finished,NO);
}
void SGRDropdownUpdate(UIView *anchor, UIMenu *menu) {
    if (sg_currentDropdown.anchor == anchor && SGRDropdownDeferredMenuSupported(menu, anchor))
        [sg_currentDropdown update:menu];
}
BOOL SGRDropdownIsPresentingFrom(UIView *anchor) {
    return anchor && sg_currentDropdown.anchor == anchor && sg_currentDropdown.window;
}
void SGRDropdownDismissFrom(UIView *anchor) {
    if (SGRDropdownIsPresentingFrom(anchor)) [sg_currentDropdown dismiss:nil];
}

static BOOL sgrDropdownPresentHostedContent(UIView *anchor, UIViewController *content,
                                            CGSize preferredSize, BOOL expanding) {
    if (!anchor.window || !content) return NO;
    if (sg_hostedTransition && sg_hostedTransition == sg_currentDropdown &&
        [sg_currentDropdown transitionToContent:content preferredSize:preferredSize expanding:expanding]) return YES;
    if (sg_currentDropdown) {
        [sg_currentDropdown finishDismiss:nil];
        sg_currentDropdown = nil;
    }
    UIMenu *empty = [UIMenu menuWithChildren:@[]];
    if (!sgrDropdownPresentInternal(anchor, empty, nil, YES)) return NO;
    [sg_currentDropdown showContent:content preferredSize:preferredSize expanding:expanding];
    return YES;
}
BOOL SGRDropdownPresentContent(UIView *anchor, UIViewController *content, CGSize preferredSize) {
    return sgrDropdownPresentHostedContent(anchor, content, preferredSize, NO);
}
BOOL SGRDropdownPresentAdaptiveContent(UIView *anchor, UIViewController *content, CGSize preferredSize) {
    return sgrDropdownPresentHostedContent(anchor, content, preferredSize, YES);
}
void SGRDropdownRefreshContentSize(UIViewController *content) {
    [sg_currentDropdown refreshContentSize:content];
}
void SGRDropdownDismissActive(void) {
    [sg_currentDropdown dismiss:nil];
}
