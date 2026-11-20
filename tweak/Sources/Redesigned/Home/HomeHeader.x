// Home redesign: the header the way the Music app has it. The filter pills (All, Music, Podcasts) go and
// a large title takes their place at the leading edge; the avatar that opens the side drawer moves to the
// trailing edge; the scrim Spotify lays behind the header goes too, the soft scroll edge (Kit/SGREdgeEffect.x)
// being what keeps the page scrolling under it soft; the title itself scrolls away (followScroll), or stays
// with the feed's hard edge under it (keepTitle).
//
// Tree (trees/clean/home/10.txt:3018-3051): FunkisViewController's view holds a 402x112 UIView around
// Reprise_LiquidGlassKit LiquidGlass.GradientView (the scrim) and, at {0, 62}, an
// ElementView<HomeHeaderElement> 402x50 holding HomeHeaderView > UIStackView {0, 8} 402x34 of two arranged
// views: ListeningActivity_ElementsKit.AdaptiveFaceContainer {16, 0} 32x34 (the avatar, an EncoreButton in 9.1.90,
// id=Components.UI.SideDrawerButton) and LiquidGlass.LeadingFadeMaskView {48, 1} 354x32 around
// Home_PillUIKit.PillScrollView.
//
// The avatar moves by the stack's layout direction rather than by a frame of ours. Right to left, the stack
// lays its first view out at the trailing edge itself on every pass, whatever width the face container
// takes when friends listening show beside the avatar; its leading margin, 16pt, is the one Spotify gives
// the header in a right to left language. The pills stay in the stack with no alpha rather than hidden,
// the way the redesign takes any view out of a stack Spotify arranges (Kit/SGRRestyle.h).
//
// The title is Spotify's own name for the tab, read off its tab bar item (id=TabBar.Item.Home, 10.txt:3100),
// so it follows the app's language.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Home.h"

// Tries at finding the tab's name before settling for the English one: a miss walks the window.
static const NSUInteger kTitleTries = 8;

static char kTitleKey, kTabKey, kPillGlassKey, kGlassKey, kButtonsKey, kConnectKey, kTintKey, kWatchKey;
// The title row's pill: a glass capsule around the filter button and the avatar, 44pt tall, as the reference has
// it; the menu drives Spotify's own filter chips, hidden in the stack, and offers the device picker when Spotify
// has one (a now playing bar) and the large shelf's Show all while its heading is gone (HomeTopPicks.x).
static const CGFloat kPillHeight = 44, kPillButton = 44, kPillPad = 6;
// The page's color behind the title (SGRHomeSetPageTint), fading to black over this height.
static const CGFloat kTintHeight = 480;

// The pill's buttons sit above Spotify's stack, which would take every touch in the header otherwise; a touch
// outside a button goes through to the avatar under them.
@interface SGRHomePillButtons : UIView
@property (nonatomic, strong) UIButton *filter;
@end
@implementation SGRHomePillButtons
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
@end

@interface SGRHomeTintView : UIView
@end
@implementation SGRHomeTintView
+ (Class)layerClass {
    return CAGradientLayer.class;
}
@end
static NSString *sg_tabName;

static void vanish(UIView *view) {
    if (!view) return;
    if (view.alpha != 0) view.alpha = 0;
    view.userInteractionEnabled = NO;
    view.accessibilityElementsHidden = YES;
}

static UIView *childNamed(UIView *host, NSString *marker) {
    for (UIView *sub in host.subviews) {
        if ([NSStringFromClass(sub.class) containsString:marker]) return sub;
    }
    return nil;
}

static NSString *tabName(UIWindow *window) {
    if (sg_tabName || !window) return sg_tabName ?: @"Home";
    static NSUInteger tries;
    if (tries >= kTitleTries) return @"Home";
    tries++;
    UIView *item = SGRFindByIdentifier(window, @"TabBar.Item.Home", &kTabKey);
    __block NSString *name = nil;
    if (item) SGForEachView(item, ^(UIView *v) {
        if (!name && [v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length) name = ((UILabel *)v).text;
    });
    if (!name) {
        if (tries == kTitleTries) SGLog(@"redesign home: the Home tab's name not found, the title stays English");
        return @"Home";
    }
    sg_tabName = [name copy];
    SGLog(@"redesign home: title \"%@\" from the tab bar", sg_tabName);
    return sg_tabName;
}

static UILabel *titleIn(UIView *header) {
    UILabel *title = objc_getAssociatedObject(header, &kTitleKey);
    if (!title) {
        title = [UILabel new];
        title.textColor = SGRPrimary();
        title.accessibilityTraits = UIAccessibilityTraitHeader;
        title.adjustsFontSizeToFitWidth = YES;
        title.minimumScaleFactor = 0.6;
        title.userInteractionEnabled = NO;
        objc_setAssociatedObject(header, &kTitleKey, title, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (title.superview != header) [header addSubview:title];
    return title;
}

// The header's views, found once: the page lays out again as it appears, and the walk names classes.
static __weak UIView *sg_header;
static __weak UIStackView *sg_stack;
static __weak UIView *sg_scrim;
static UIControl *connectButton(UIView *window);

#pragma mark - the pill

// Spotify's filter chips (All, Music, Podcasts, Audiobooks), controls in the stack's hidden pill scroller, in
// their order there.
static NSArray<UIControl *> *chips(UIStackView *stack) {
    NSMutableArray<UIControl *> *found = [NSMutableArray array];
    SGForEachView(stack, ^(UIView *v) {
        if ([v.accessibilityIdentifier hasPrefix:@"home-feed-"] && [v isKindOfClass:UIControl.class]) [found addObject:(UIControl *)v];
    });
    return [found sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat xa = [a convertRect:a.bounds toView:stack].origin.x, xb = [b convertRect:b.bounds toView:stack].origin.x;
        return xa < xb ? NSOrderedAscending : xa > xb ? NSOrderedDescending : NSOrderedSame;
    }];
}

// The chip in effect: selected, or drawn solid with its glass hidden (home-feed-default, trees 2026-10-11).
static BOOL chosen(UIControl *chip) {
    if (chip.selected) return YES;
    __block BOOL solid = NO;
    SGForEachView(chip, ^(UIView *v) {
        if ([NSStringFromClass(v.class) containsString:@"ChipGlassView"] && v.hidden) solid = YES;
    });
    return solid;
}

static NSArray<UIMenuElement *> *menuElements(void) {
    NSMutableArray<UIMenuElement *> *elements = [NSMutableArray array];
    NSMutableArray<UIMenuElement *> *filters = [NSMutableArray array];
    for (UIControl *chip in chips(sg_stack)) {
        __weak UIControl *weakChip = chip;
        UIAction *action = [UIAction actionWithTitle:chip.accessibilityLabel ?: @"" image:nil identifier:nil handler:^(UIAction *a) {
            if (weakChip) SGRActivate(weakChip);
        }];
        action.state = chosen(chip) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [filters addObject:action];
    }
    if (filters.count) [elements addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:filters]];
    NSMutableArray<UIMenuElement *> *more = [NSMutableArray array];
    UIControl *connect = connectButton(sg_header.window);
    if (connect) {
        __weak UIControl *weakConnect = connect;
        [more addObject:[UIAction actionWithTitle:@"Devices" image:[UIImage systemImageNamed:@"hifispeaker"] identifier:nil handler:^(UIAction *a) {
            if (weakConnect) SGRActivate(weakConnect);
        }]];
    }
    NSString *title = nil;
    UIControl *showAll = SGRHomeTopPicksShowAll(&title);
    if (showAll) {
        __weak UIControl *weakShowAll = showAll;
        [more addObject:[UIAction actionWithTitle:title.length ? [NSString stringWithFormat:@"Show all · %@", title] : @"Show all"
                                            image:[UIImage systemImageNamed:@"rectangle.stack"] identifier:nil handler:^(UIAction *a) {
            if (weakShowAll) SGRActivate(weakShowAll);
        }]];
    }
    if (more.count) [elements addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:more]];
    return elements;
}

// Spotify's device picker button, in the now playing bar (Components.ConnectButtonOutputSwitcher > UIButton,
// trees 2026-10-11); nil without a bar.
static UIControl *connectButton(UIView *window) {
    UIView *holder = window ? SGRFindByIdentifier(window, @"Components.ConnectButtonOutputSwitcher", &kConnectKey) : nil;
    __block UIControl *button = [holder isKindOfClass:UIControl.class] ? (UIControl *)holder : nil;
    if (!button) SGForEachView(holder, ^(UIView *v) {
        if (!button && [v isKindOfClass:UIControl.class]) button = (UIControl *)v;
    });
    return button;
}

static UIButton *pillButton(NSString *symbol, NSString *label) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
    button.tintColor = SGRPrimary();
    button.accessibilityLabel = label;
    // The menu takes the appearance of its button; outside Spotify's navigation stacks that is the system's.
    button.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    return button;
}

static SGRHomePillButtons *buttonsIn(UIView *header) {
    SGRHomePillButtons *buttons = objc_getAssociatedObject(header, &kButtonsKey);
    if (!buttons) {
        buttons = [SGRHomePillButtons new];
        buttons.filter = pillButton(@"line.3.horizontal.decrease", @"Filter Home");
        buttons.filter.menu = [UIMenu menuWithChildren:@[[UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
            completion(menuElements());
        }]]];
        buttons.filter.showsMenuAsPrimaryAction = YES;
        [buttons addSubview:buttons.filter];
        objc_setAssociatedObject(header, &kButtonsKey, buttons, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (buttons.superview != header) [header addSubview:buttons];
    else if (header.subviews.lastObject != buttons) [header bringSubviewToFront:buttons];
    return buttons;
}

static UIView *glassIn(UIView *header) {
    UIView *glass = objc_getAssociatedObject(header, &kGlassKey);
    if (!glass) {
        glass = [UIView new];
        glass.userInteractionEnabled = NO;
        objc_setAssociatedObject(header, &kGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != header) [header insertSubview:glass atIndex:0];
    else if (header.subviews.firstObject != glass) [header sendSubviewToBack:glass];
    return glass;
}

// Lays the pill out around the avatar, which stays Spotify's in its stack; the pill's leading edge.
// The stack's place in the header with no transform on it (its center and bounds, which a transform leaves
// alone): Spotify animates the stack in with a transform, and the one pass this ran in on a 440pt phone saw the
// stack's frame half a width to the left, with no pass after to put the pill right.
static CGRect untransformed(UIView *view) {
    CGSize size = view.bounds.size;
    return CGRectMake(view.center.x - size.width / 2, view.center.y - size.height / 2, size.width, size.height);
}

// The avatar's place, by its center and bounds too: it carries the scroll's transform (followScroll), unless kept.
static CGRect facePlace(UIStackView *stack, UIView *face) {
    CGRect place = untransformed(stack);
    return CGRectOffset(untransformed(face), place.origin.x - stack.bounds.origin.x, place.origin.y - stack.bounds.origin.y);
}

// A view placed by bounds and center, which the scroll's transform leaves alone.
static void place(UIView *view, CGRect frame) {
    CGRect bounds = (CGRect){CGPointZero, frame.size};
    CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    if (!CGRectEqualToRect(view.bounds, bounds)) view.bounds = bounds;
    if (!CGPointEqualToPoint(view.center, center)) view.center = center;
}

// New Music Friday: the Friday ring follows the accent sampled from Spotify's live banner (or the current first card until the banner is available). A layer of the pill's glass holder, cut to a capsule's outline. It goes and comes back with the
// pill's material as the title row scrolls away (riseGlass), and its turn is taken off the rest of the week and under
// Reduce Motion, so the next layout stops it after midnight or as Reduce Motion goes on. A turn of 6 s needs no more
// than 30 frames a second.
static char kFridayKey;
static const CGFloat kFridayRing = 1.5;
static const CFTimeInterval kFridayTurn = 6;

static BOOL sg_glassShown = YES;
static UIColor *sg_pageTint;
static UIColor *sg_fridayAccent;
static __weak UIImage *sg_fridayAccentImage;
static NSUInteger sg_fridayAccentPriority; // 2: Friday banner; 1: NMF cover card.
static char kFridayPaletteKey;

// Spotify's PillView is a Swift view, not necessarily a UIControl. Resolve the
// real colored Music chip from the header tree instead of relying on the menu's
// UIControl-only selection helper.
static UIColor *selectedMusicAccent(void);
static BOOL musicFilterSelected(void);

static BOOL isFriday(void) {
    return [NSCalendar.currentCalendar component:NSCalendarUnitWeekday fromDate:NSDate.date] == 6;
}

// The ring's turn, on only while it can be seen: a ring faded out with the material keeps no endless animation going
// under a page scrolled down, nor under Reduce Motion.
static void turnRing(CALayer *ring, BOOL on) {
    CALayer *colors = ring.sublayers.firstObject;
    if (!colors) return;
    if (!on || SGRReduceMotion()) {
        [colors removeAnimationForKey:@"turn"];
        return;
    }
    if ([colors animationForKey:@"turn"]) return;
    CABasicAnimation *turn = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    turn.fromValue = @0;
    turn.toValue = @(2 * M_PI);
    turn.duration = kFridayTurn;
    turn.repeatCount = HUGE_VALF;
    turn.removedOnCompletion = NO;
    turn.preferredFrameRateRange = CAFrameRateRangeMake(10, 30, 30);
    [colors addAnimation:turn forKey:@"turn"];
}

static void layoutFriday(UIView *holder, CGSize size) {
    CALayer *ring = objc_getAssociatedObject(holder, &kFridayKey);
    BOOL friday = isFriday() && size.width > 1;
    if (!friday) {
        [ring.sublayers.firstObject removeAnimationForKey:@"turn"];
        ring.hidden = YES;
        return;
    }
    CAGradientLayer *colors;
    if (!ring) {
        ring = [CALayer layer];
        colors = [CAGradientLayer layer];
        colors.type = kCAGradientLayerConic;
        colors.startPoint = CGPointMake(0.5, 0.5);
        colors.endPoint = CGPointMake(0.5, 0);
        [ring addSublayer:colors];
        CAShapeLayer *outline = [CAShapeLayer layer];
        outline.fillColor = nil;
        outline.strokeColor = UIColor.whiteColor.CGColor;
        outline.lineWidth = kFridayRing;
        ring.mask = outline;
        ring.zPosition = 101;
        UILabel *title = sg_header ? objc_getAssociatedObject(sg_header, &kTitleKey) : nil;
        ring.opacity = title ? title.alpha : 1;
        objc_setAssociatedObject(holder, &kFridayKey, ring, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    colors = (CAGradientLayer *)ring.sublayers.firstObject;
    // No fixed Friday palette: use the same sampled banner accent as Music's
    // background. Until the banner is loaded use Home's first-card tint.
    // The selected Spotify Music pill already carries NMF's live accent
    // (for example #A2D0FA). Read it directly even before artwork sampling
    // finishes, so the ring never briefly falls back to white.
    UIColor *nativeAccent = selectedMusicAccent();
    UIColor *base = nativeAccent ?: (sg_fridayAccent ?: sg_pageTint);
    if (!base) base = UIColor.whiteColor;
    UIColor *previous = objc_getAssociatedObject(ring, &kFridayPaletteKey);
    if (![previous isEqual:base]) {
        CGFloat hue = 0, saturation = 0, brightness = 0, alpha = 0;
        if (![base getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha]) {
            hue = 0; saturation = 0; brightness = 1;
        }
        CGFloat bright = MAX(0.66, brightness), vivid = saturation > 0.08 ? MAX(0.42, saturation) : 0;
        UIColor *primary = [base colorWithAlphaComponent:1];
        UIColor *light = [UIColor colorWithHue:hue saturation:vivid * 0.55 brightness:MIN(1, bright * 1.16) alpha:1];
        UIColor *deep = [UIColor colorWithHue:hue saturation:vivid brightness:MAX(0.42, bright * 0.74) alpha:1];
        // A conic light/shade sweep of one hue, not a pink-violet rainbow.
        colors.colors = @[(id)primary.CGColor, (id)light.CGColor,
                          (id)primary.CGColor, (id)deep.CGColor, (id)primary.CGColor];
        objc_setAssociatedObject(ring, &kFridayPaletteKey, base, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (ring.superlayer != holder.layer) [holder.layer addSublayer:ring];
    ring.hidden = NO;
    CGRect bounds = (CGRect){CGPointZero, size};
    if (!CGRectEqualToRect(ring.frame, bounds)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        ring.frame = bounds;
        // Square and wider than the pill, so it covers the outline whichever way it has turned.
        CGFloat side = hypot(size.width, size.height);
        colors.bounds = CGRectMake(0, 0, side, side);
        colors.position = CGPointMake(size.width / 2, size.height / 2);
        CAShapeLayer *outline = (CAShapeLayer *)ring.mask;
        outline.frame = bounds;
        CGRect line = CGRectInset(bounds, kFridayRing / 2, kFridayRing / 2);
        outline.path = [UIBezierPath bezierPathWithRoundedRect:line cornerRadius:line.size.height / 2].CGPath;
        [CATransaction commit];
    }
    turnRing(ring, ring.opacity > 0.01f);
}

static CGFloat layoutPill(UIView *header, UIStackView *stack, UIView *face) {
    SGRHomePillButtons *buttons = buttonsIn(header);
    UIView *glass = glassIn(header);
    CGRect faceFrame = face ? facePlace(stack, face) : CGRectZero;
    CGFloat width = kPillPad + kPillButton + (face ? faceFrame.size.width + kPillPad * 2 : kPillPad);
    CGFloat maxX = face ? CGRectGetMaxX(faceFrame) + kPillPad : header.bounds.size.width - SGRSideMargin;
    CGFloat midY = face ? CGRectGetMidY(faceFrame) : CGRectGetMidY(untransformed(stack));
    CGRect pill = CGRectMake(round(maxX - width), round(midY - kPillHeight / 2), width, kPillHeight);
    place(glass, pill);
    place(buttons, pill);
    CGRect filter = CGRectMake(kPillPad, 0, kPillButton, kPillHeight);
    if (!CGRectEqualToRect(buttons.filter.frame, filter)) buttons.filter.frame = filter;
    SGRGlassCapsuleInside(glass, &kPillGlassKey, pill.size, NO);
    layoutFriday(glass, pill.size);
    return CGRectGetMinX(pill);
}

#pragma mark - the page's color

static __weak SGRHomeTintView *sg_tintView;
static char kFridayImageKey, kFridayColorKey, kMusicCardImageKey, kMusicCardColorKey;

static void paintTint(SGRHomeTintView *tint, BOOL animated) {
    CAGradientLayer *layer = (CAGradientLayer *)tint.layer;
    UIColor *friday = tint.superview ? objc_getAssociatedObject(tint.superview, &kFridayColorKey) : nil;
    UIColor *musicCard = tint.superview ? objc_getAssociatedObject(tint.superview, &kMusicCardColorKey) : nil;
    // Use exactly the same live Music accent as the Friday rim. Do not wait
    // for the banner's asynchronous UIImage or the banner-specific callback.
    UIColor *liveMusic = isFriday() ? selectedMusicAccent() : nil;
    UIColor *top = liveMusic ?: (friday ?: (musicCard ?: (sg_pageTint ?: UIColor.blackColor)));
    NSArray *colors = @[(id)top.CGColor, (id)[top colorWithAlphaComponent:0].CGColor];
    if ([layer.colors isEqualToArray:colors]) return;
    if (animated && tint.window) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"colors"];
        fade.fromValue = layer.colors;
        fade.duration = SGRCrossfade;
        [layer addAnimation:fade forKey:@"colors"];
    }
    layer.colors = colors;
}

// A selected Spotify Music chip is visibly tinted; the nonselected chip is
// neutral gray (#333333 in the Stage 55 tree). Its native Swift PillView may
// not be a UIControl, and `chosen` also looks for an older ChipGlassView that
// is absent from this version of Spotify. Read the view's actual paint.
static UIColor *selectedMusicAccent(void) {
    if (!sg_stack) return nil;
    __block UIColor *accent = nil;
    SGForEachView(sg_stack, ^(UIView *view) {
        if (accent || ![view.accessibilityIdentifier isEqualToString:@"home-feed-music-chip"]) return;
        UIColor *color = view.backgroundColor;
        if (!color && view.layer.backgroundColor)
            color = [UIColor colorWithCGColor:view.layer.backgroundColor];
        CGFloat hue = 0, saturation = 0, brightness = 0, alpha = 0;
        // A neutral/inactive pill must not tint Home or a non-Music feed.
        if ([color getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha] &&
            saturation > 0.16 && brightness > 0.32 && alpha > 0.4)
            accent = color;
    });
    return accent;
}

static BOOL musicFilterSelected(void) {
    // The visible colored native pill is the authoritative selection state.
    if (selectedMusicAccent()) return YES;
    // Keep support for Spotify variants where PillView really is a control.
    for (UIControl *chip in chips(sg_stack))
        if ([chip.accessibilityIdentifier isEqualToString:@"home-feed-music-chip"])
            return chosen(chip);
    return NO;
}

static void repaintFridayRing(void) {
    UIView *glass = sg_header ? objc_getAssociatedObject(sg_header, &kGlassKey) : nil;
    if (glass && glass.bounds.size.width > 1 && isFriday()) layoutFriday(glass, glass.bounds.size);
}

// The cover sampling path is already asynchronous and cached. Prioritize the
// actual Friday logo over a carousel cover; an older async result must never
// replace the accent of a newer image/page.
static void sampleFridayAccent(UIImage *image, NSUInteger priority) {
    if (!image || !isFriday() || !SGBelowiOS26() || !SGUseLegacyGlass() ||
        priority < sg_fridayAccentPriority) return;
    if (sg_fridayAccentImage == image && priority == sg_fridayAccentPriority) return;
    sg_fridayAccentImage = image;
    sg_fridayAccentPriority = priority;
    SGRHomeTintForCover(image, ^(UIColor *color) {
        if (!color || sg_fridayAccentImage != image || sg_fridayAccentPriority != priority) return;
        sg_fridayAccent = color;
        repaintFridayRing();
    });
}

void SGRHomeSetPageTint(UIColor *color) {
    if (color == sg_pageTint || [color isEqual:sg_pageTint]) return;
    sg_pageTint = color;
    if (sg_tintView) paintTint(sg_tintView, YES);
    if (!sg_fridayAccent) repaintFridayRing();
}

// Music's full-bleed Friday banner isn't a large Top Picks shelf. Without a
// page-specific tint its new HomePageView gets a black-to-transparent layer.
// Use the *existing* async cover-color sampler and keep the result on Music's
// own page: returning to the unfiltered Home must not inherit the banner tint.
void SGRHomeTintFridayBanner(UIView *banner, UIImage *image) {
    if (!SGBelowiOS26() || !SGUseLegacyGlass() || !banner || !image) return;
    UIView *page = banner;
    while (page && ![page.accessibilityIdentifier hasPrefix:@"HomePageView-"]) page = page.superview;
    if (!page) return;
    BOOL sameImage = objc_getAssociatedObject(page, &kFridayImageKey) == image;
    UIColor *nativeAccent = isFriday() ? selectedMusicAccent() : nil;
    if (sameImage && (!nativeAccent || [nativeAccent isEqual:objc_getAssociatedObject(page, &kFridayColorKey)])) return;
    objc_setAssociatedObject(page, &kFridayImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (nativeAccent) {
        // Source of truth: Spotify's current Music filter, which follows NMF.
        sg_fridayAccent = nativeAccent;
        sg_fridayAccentPriority = 3;
        repaintFridayRing();
        objc_setAssociatedObject(page, &kFridayColorKey, nativeAccent, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (sg_tintView.superview == page) paintTint(sg_tintView, YES);
        return;
    }
    sampleFridayAccent(image, 2);
    objc_setAssociatedObject(page, &kFridayColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakPage = page;
    SGRHomeTintForCover(image, ^(UIColor *color) {
        UIView *strongPage = weakPage;
        if (!strongPage || objc_getAssociatedObject(strongPage, &kFridayImageKey) != image || !color) return;
        objc_setAssociatedObject(strongPage, &kFridayColorKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (sg_tintView.superview == strongPage) paintTint(sg_tintView, YES);
    });
}

// The filter's HomePageView is replaced by Spotify when entering Music; the
// header controller survives. Find the *current* page under this controller,
// not the superview of our last (weak) tint, which belongs to the old filter.
// Restrict the walk to the shallow container/header levels: a Home feed can
// contain thousands of descendants and must never be scanned each layout.
static UIView *homePageNear(UIView *view, NSUInteger depth) {
    if (!view) return nil;
    if ([view.accessibilityIdentifier hasPrefix:@"HomePageView-"]) return view;
    if (!depth) return nil;
    for (UIView *sub in view.subviews) {
        UIView *found = homePageNear(sub, depth - 1);
        if (found) return found;
    }
    return nil;
}

// The gradient at the back of the page's view (HomePageView, which holds the feed), the feed's own black cleared so
// it shows through behind the title and the first shelf; the shelves clear theirs (HomeSections.x).
static void layoutTint(UIView *view) {
    __block UIView *page = nil;
    // A Music/Home filter transition can replace HomePageView without laying
    // out the retained Funkis controller again. Never choose the last tint's
    // old superview before resolving the page currently attached to `view`.
    if (SGBelowiOS26() && SGUseLegacyGlass()) page = homePageNear(view, 10);
    if (!page) SGForEachView(view, ^(UIView *v) {
        if (!page && [v.accessibilityIdentifier hasPrefix:@"HomePageView-"] && v.window) page = v;
    });
    if (!page && sg_tintView.superview && [sg_tintView.superview isDescendantOfView:view]
        && sg_tintView.superview.window == view.window) page = sg_tintView.superview;
    if (!page) return;
    SGRHomeTintView *tint = objc_getAssociatedObject(page, &kTintKey);
    if (!tint) {
        tint = [SGRHomeTintView new];
        tint.userInteractionEnabled = NO;
        objc_setAssociatedObject(page, &kTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Both pointers must follow the new HomePageView; before Stage 59 the
    // stale pointer stopped the gradient being created for Music and Home.
    sg_tintView = tint;
    if (tint.superview != page) [page insertSubview:tint atIndex:0];
    paintTint(tint, NO);
    CGRect frame = CGRectMake(0, 0, page.bounds.size.width, kTintHeight);
    if (!CGRectEqualToRect(tint.frame, frame)) tint.frame = frame;
    BOOL bannerVisible = NO;
    __block UIImage *musicCover = nil;
    for (UIView *sub in page.subviews) {
        if (![sub isKindOfClass:UICollectionView.class]) continue;
        if (![sub.backgroundColor isEqual:UIColor.clearColor]) sub.backgroundColor = UIColor.clearColor;
        // On the Friday Music filter the visible full-bleed banner has no
        // accessibilityLabel on its UIImageView in Stage 55, although the
        // earlier section classifier sometimes saw one. Read the *visible*
        // banner image directly, once per image, as a reliable fallback.
        if (!SGBelowiOS26() || !SGUseLegacyGlass()) continue;
        UICollectionView *collection = (UICollectionView *)sub;
        NSArray<UICollectionViewCell *> *cells = [collection.visibleCells sortedArrayUsingComparator:^NSComparisonResult(UICollectionViewCell *a, UICollectionViewCell *b) {
            return [[collection indexPathForCell:a] compare:[collection indexPathForCell:b]];
        }];
        for (UICollectionViewCell *cell in cells) {
            if (cell.hidden || cell.contentView.hidden) continue;
            UIView *root = cell.contentView.subviews.firstObject.subviews.firstObject;
            if (musicFilterSelected() && !musicCover &&
                ![NSStringFromClass(root.class) containsString:@"Discovery_BannerKit.FullBleedBannerElementView"]) {
                SGForEachView(cell.contentView, ^(UIView *v) {
                    if (!musicCover && [v isKindOfClass:UIImageView.class] &&
                        v.bounds.size.width >= 90 && ((UIImageView *)v).image)
                        musicCover = ((UIImageView *)v).image;
                });
            }
            // On Friday, Home itself may show the NMF carousel cover before
            // Music's logo banner has loaded. Use it only as a temporary ring
            // accent; never give Home the banner-specific background override.
            if (isFriday() && sg_fridayAccentPriority < 2 && !sg_fridayAccentImage) {
                __block UIImage *cover = nil;
                SGForEachView(cell.contentView, ^(UIView *v) {
                    if (cover || ![v.accessibilityLabel hasPrefix:@"New Music Friday"]) return;
                    SGForEachView(v, ^(UIView *child) {
                        if (!cover && [child isKindOfClass:UIImageView.class])
                            cover = ((UIImageView *)child).image;
                    });
                });
                if (cover) sampleFridayAccent(cover, 1);
            }
            if (![NSStringFromClass(root.class) containsString:@"Discovery_BannerKit.FullBleedBannerElementView"]
                || cell.hidden || cell.contentView.hidden) continue;
            // Unlike Home shelves, this full-bleed banner is wrapped by an
            // opaque section. Clear only its backgrounds, not the image or
            // artwork, so Music's page-level color can reach the top edge.
            if (musicFilterSelected()) {
                for (UIView *wrapper = root; wrapper && wrapper != collection; wrapper = wrapper.superview) {
                    wrapper.opaque = NO;
                    if (![wrapper.backgroundColor isEqual:UIColor.clearColor])
                        wrapper.backgroundColor = UIColor.clearColor;
                }
            }
            __block UIImageView *bannerImage = nil;
            SGForEachView(root, ^(UIView *part) {
                if (!bannerImage && [part isKindOfClass:UIImageView.class] &&
                    part.bounds.size.width >= 100 && ((UIImageView *)part).image)
                    bannerImage = (UIImageView *)part;
            });
            if (bannerImage) {
                bannerVisible = YES;
                SGRHomeTintFridayBanner(root, bannerImage.image);
            }
            break;
        }
    }
    // On an ordinary Music day there is no Friday banner. Sample that page's
    // first card instead of borrowing Home's last tint (which can be stale).
    if (!bannerVisible && musicFilterSelected() && musicCover) {
        if (objc_getAssociatedObject(page, &kMusicCardImageKey) != musicCover) {
            objc_setAssociatedObject(page, &kMusicCardImageKey, musicCover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(page, &kMusicCardColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak UIView *weakPage = page;
            SGRHomeTintForCover(musicCover, ^(UIColor *color) {
                UIView *strongPage = weakPage;
                if (!strongPage || !color || objc_getAssociatedObject(strongPage, &kMusicCardImageKey) != musicCover) return;
                objc_setAssociatedObject(strongPage, &kMusicCardColorKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (sg_tintView.superview == strongPage) paintTint(sg_tintView, YES);
            });
        }
        // Filter data may replace the existing page without replacing its
        // identity. Clear its old Friday override only at the top of the feed;
        // scrolling the Friday banner offscreen must never clear its color.
        UIScrollView *feed = nil;
        for (UIView *v in page.subviews) if ([v isKindOfClass:UIScrollView.class]) { feed = (UIScrollView *)v; break; }
        if (feed && feed.contentOffset.y <= -feed.adjustedContentInset.top + 12) {
            objc_setAssociatedObject(page, &kFridayColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        paintTint(tint, YES);
    }
}

static BOOL findHeader(UIView *view) {
    if (sg_stack && [sg_stack isDescendantOfView:view]) return YES;
    for (UIView *wrapper in view.subviews) {
        UIView *scrim = childNamed(wrapper, @"GradientView");
        if (scrim) sg_scrim = scrim;
    }
    UIView *header = childNamed(childNamed(view, @"HomeHeaderElement"), @"HomeHeaderView");
    for (UIView *sub in header.subviews) {
        if ([sub isKindOfClass:UIStackView.class]) sg_stack = (UIStackView *)sub;
    }
    sg_header = header;
    if (sg_stack) return YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign home: header stack not found, header left as Spotify's"); });
    return NO;
}

// The title row scrolls away with the page, as the Music app's large title and avatar do: the title, the glass pill
// and Spotify's avatar rise with what is under them and fade over the title's height, so the page never passes
// under them. Kept in place instead (keepTitle), the page passes under them over a hard edge.
static __weak UIView *sg_face;
static void rise(UIView *part, CGAffineTransform transform, CGFloat alpha) {
    if (!CGAffineTransformEqualToTransform(part.transform, transform)) part.transform = transform;
    if (part.alpha != alpha) part.alpha = alpha;
}

// The pill's glass takes no alpha (SGRGlass.h): it rises with the row, and its material goes off once the row is
// half faded and comes back with it.
static const NSTimeInterval kGlassFade = 0.15;
// When the material's last change ends: until then the glass keeps rising after the row has faded.
static CFTimeInterval sg_glassFadeEnds;
static void riseGlass(UIView *glass, CGAffineTransform transform, CGFloat alpha) {
    if (!glass) return;
    if (!CGAffineTransformEqualToTransform(glass.transform, transform)) glass.transform = transform;
    BOOL shown = alpha > 0.5;
    UIView *shape = objc_getAssociatedObject(glass, &kPillGlassKey);
    if (!shape || shown == sg_glassShown) return;
    sg_glassShown = shown;
    sg_glassFadeEnds = CACurrentMediaTime() + kGlassFade;
    [UIView animateWithDuration:kGlassFade animations:^{ SGRShowGlass(shape, shown); }];
    // Only the glass material uses this 0.5 cutoff. The Friday rim is part of
    // the header artwork and must fade with its title/buttons instead.
}

static void insetFeed(UIScrollView *feed);

static void followScroll(UIScrollView *scroll) {
    insetFeed(scroll);
    UILabel *title = sg_header ? objc_getAssociatedObject(sg_header, &kTitleKey) : nil;
    if (!title || !scroll) return;
    CGFloat scrolled = MAX(0, scroll.contentOffset.y + scroll.adjustedContentInset.top), faded = MAX(1, title.bounds.size.height);
    CGFloat alpha = 1 - MIN(1, scrolled / faded);
    // Past the title's height the row has faded out, so it stops rising there and nothing is written again until it
    // comes back; the glass keeps rising while its material is still going off.
    CGAffineTransform up = CGAffineTransformMakeTranslation(0, -MIN(scrolled, faded));
    BOOL glassFading = CACurrentMediaTime() < sg_glassFadeEnds || (alpha > 0.5) != sg_glassShown;
    rise(title, up, alpha);
    UIView *glass = objc_getAssociatedObject(sg_header, &kGlassKey);
    riseGlass(glass, glassFading ? CGAffineTransformMakeTranslation(0, -scrolled) : up, alpha);
    CALayer *ring = objc_getAssociatedObject(glass, &kFridayKey);
    if (ring && !ring.hidden) {
        // Same exact scroll alpha as the Home title and the filter/avatar
        // buttons. Disable implicit CA fading: scrolling is already sampled
        // per frame; an additional layer animation would lag or finish early.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        ring.opacity = alpha;
        [CATransaction commit];
        turnRing(ring, alpha > 0.01f);
    }
    rise(objc_getAssociatedObject(sg_header, &kButtonsKey), up, alpha);
    if ([sg_face isDescendantOfView:sg_header]) rise(sg_face, up, alpha);
}

// The feed: the page's outermost scroll view taller than the pills, found once. Not the tallest: a shelf can grow taller
// than the page, and a shelf's offset never moves the title. Followed by an observer that lives as long as it does.
static char kFollowerKey, kEdgeKey;
static __weak UIScrollView *sg_feed;
static void insetFeed(UIScrollView *feed);
static __weak UIView *sg_pageView;
// Kept in place (SGRKeyHomeKeepTitle), the row stays and no observer is added: the header instead shapes the feed's
// top edge effect, hard rather than the redesign's soft one (too faint under a large title, as Apple's guidelines
// say of text outside glass), which then darkens the page under the title and the pill as under a navigation bar.
static BOOL keepTitle(void) {
    static int state = -1;
    // Below iOS 26 there is no edge effect to put under it, and the scrim is gone: the title scrolls away there.
    if (state < 0) state = SGRedesignAvailable() && SGHidden(SGRKeyHomeKeepTitle) ? 1 : 0;
    return state == 1;
}

static void shapeEdge(UIScrollView *feed) {
    SGRHardTopEdge(feed);
    if (@available(iOS 26.0, *)) {
        UIView *header = sg_header;
        if (!header) return;
        UIScrollEdgeElementContainerInteraction *edge = objc_getAssociatedObject(header, &kEdgeKey);
        if (!edge) {
            edge = [UIScrollEdgeElementContainerInteraction new];
            edge.edge = UIRectEdgeTop;
            [header addInteraction:edge];
            objc_setAssociatedObject(header, &kEdgeKey, edge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (edge.scrollView != feed) edge.scrollView = feed;
    }
}

static void followFeed(UIScrollView *feed) {
    sg_feed = feed;
    insetFeed(feed);
    if (keepTitle()) {
        shapeEdge(feed);
        return;
    }
    SGRFollowOffset(feed, &kFollowerKey, ^(UIScrollView *scroll) { followScroll(scroll); });
    followScroll(feed);
}

static void follow(UIView *view) {
    __block UIScrollView *feed = sg_feed;
    if (![feed isDescendantOfView:view]) feed = nil;
    if (!feed) SGForEachView(view, ^(UIView *v) {
        if (!feed && [v isKindOfClass:UIScrollView.class] && v.bounds.size.height > 300) feed = (UIScrollView *)v;
    });
    if (feed) followFeed(feed);
}

static void layoutHeader(UIViewController *page);

// The feed under the header. Spotify stacks it below the header (the header element's bottom to the feed's container's
// top, 98pt down on a 414pt phone) in a container that clips, and paints the header black: once the title row had
// scrolled away, the top of the page was an empty black band 98pt tall with the feed cut off under it in a straight
// line. The Music app's page runs under its header to the top of the screen. So, below iOS 26, the container's top is
// tied to the page's own, the header's black goes, and the feed is pushed down inside by what the container rose
// (insetFeed), so nothing moves at rest.
static char kLiftedKey, kExtraKey, kWrittenKey;
// Where the feed's first content stood, from the top of the page, before the container rose: the container's old top
// and the feed's safe area then.
static CGFloat sg_firstTop;

// Room between the header's row (the title and the pill) and the first row of cards, which sat right under it.
static const CGFloat kFeedGap = 12;

// The feed's top inset is Spotify's own plus what keeps its first content at sg_firstTop under the safe area it has
// now. The safe area changes after the container rises (8pt became 56pt, and a lift worked out once left Home 48pt
// low), so it is worked out again on every pass and every scroll; Spotify's own part is what the inset holds less what
// was added last, unless Spotify has set the inset again since (it is no longer the value written here): then all of
// it is Spotify's, as LibraryHeader.x's raiseList reads it.
static void insetFeed(UIScrollView *feed) {
    if (sg_firstTop <= 0 || !feed) return;
    // Setting the inset makes UIKit move the offset at once, which the follower hears (SGRFollowOffset) and answers
    // with followScroll, so this is entered again before it has finished: that inner pass is left to the outer one.
    static BOOL inside;
    if (inside) return;
    inside = YES;
    CGFloat extra = MAX(0, sg_firstTop - feed.safeAreaInsets.top) + kFeedGap;
    CGFloat added = [objc_getAssociatedObject(feed, &kExtraKey) doubleValue];
    NSNumber *written = objc_getAssociatedObject(feed, &kWrittenKey);
    UIEdgeInsets inset = feed.contentInset;
    BOOL ours = written && fabs(inset.top - written.doubleValue) < 0.5;
    if (!ours) added = 0;
    if (ours && fabs(extra - added) < 0.5) {
        inside = NO;
        return;
    }
    BOOL atRest = feed.contentOffset.y <= -feed.adjustedContentInset.top + 1;
    inset.top += extra - added;
    // What is written is noted before it is written, so that a pass that does run inside the write reads it as ours.
    objc_setAssociatedObject(feed, &kExtraKey, @(extra), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(feed, &kWrittenKey, @(inset.top), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    feed.contentInset = inset;
    if (atRest) feed.contentOffset = CGPointMake(feed.contentOffset.x, -feed.adjustedContentInset.top);
    inside = NO;
}

// The header element's black: Spotify paints it again as the page scrolls, after any pass of ours, and on its layer
// rather than through the view's setter, so a hook of the setter left the band there. The repaint hook holds the
// element's fill clear instead (SGRHoldClear).
static void keepHeaderClear(UIView *element) {
    static __weak UIView *held;
    if (held != element) {
        held = element;
        SGRHoldClear(element);
        // And every element of its class, made later: Home builds its header again with the feed and paints the new one
        // black as it makes it, before a pass of the page has found it (the element at y 48, 414x50, #000000@1.00 over
        // the feed as it scrolled, gone once its fill was taken off).
        SGRHoldClearClass(object_getClass(element));
        SGLog(@"redesign home: the header's fill is held clear");
    }
    // The view's own colour as well as its layer's: a view keeps the colour it was given and puts it back on its layer.
    if (element.backgroundColor) element.backgroundColor = nil;
    if (SGIsVisibleColor(element.layer.backgroundColor)) element.layer.backgroundColor = NULL;
}

static char kFeedLiftConstraintKey, kHomeReflowPendingKey, kHomeReflowTriesKey;
static void liftFeed(UIView *element) {
    // The layout callback can be re-entered while a constraint is activated.
    static BOOL lifting;
    if (lifting || !element) return;
    UIView *page = element.superview;
    if (!SGBelowiOS26() || !page) return;
    if ([NSStringFromClass(element.class) containsString:@"HomeHeaderElement"]) keepHeaderClear(element);

    // Stage 55 captured y=0 before selecting Friday Music but y=112 for
    // Music AND the returning Home, with the header still at y=62. Spotify
    // replaces the feed container while retaining the same header element.
    // The old `kLiftedKey` short-circuit therefore skipped the new container.
    UIView *home = homePageNear(page, 7);
    UIView *container = home;
    while (container && container.superview && container.superview != page) container = container.superview;
    if (!container || container.superview != page) return;
    UIScrollView *feed = nil;
    for (UIView *sub in home.subviews) {
        if ([sub isKindOfClass:UIScrollView.class] && sub.bounds.size.height > 200) {
            feed = (UIScrollView *)sub;
            break;
        }
    }
    if (!feed) return;
    if (feed != sg_feed) sg_feed = feed;

    NSLayoutConstraint *below = nil, *activeTop = nil;
    for (NSLayoutConstraint *c in page.constraints) {
        if (!c.active) continue;
        // Auto Layout can store an equality in either direction. Stage 59
        // only recognized container.top = header.bottom, but the new Friday
        // hosting wrapper may install header.bottom = container.top.
        BOOL forward = c.firstItem == container && c.firstAttribute == NSLayoutAttributeTop;
        BOOL reverse = c.secondItem == container && c.secondAttribute == NSLayoutAttributeTop;
        if (forward && c.secondItem == page && c.secondAttribute == NSLayoutAttributeTop) activeTop = c;
        if (reverse && c.firstItem == page && c.firstAttribute == NSLayoutAttributeTop) activeTop = c;
        if ((forward && c.secondItem == element && c.secondAttribute == NSLayoutAttributeBottom) ||
            (reverse && c.firstItem == element && c.firstAttribute == NSLayoutAttributeBottom)) below = c;
    }
    CGFloat top = CGRectGetMinY(container.frame);
    if (activeTop && fabs(top) < 1.0) {
        insetFeed(feed);
        return;
    }
    // The latest Stage 55 tree gives a second, concrete identity check: the
    // replacement feed container starts at exactly header.bottom (112pt),
    // while the original Home has already been lifted to zero. This covers
    // a SwiftUI-recreated tie not present in `page.constraints` yet.
    BOOL atHeaderBottom = top > 20 && fabs(top - CGRectGetMaxY(element.frame)) < 3.0;
    BOOL previouslyLifted = objc_getAssociatedObject(element, &kLiftedKey) != nil ||
                            objc_getAssociatedObject(container, &kFeedLiftConstraintKey) != nil;
    if (!below && !previouslyLifted && !atHeaderBottom) return;
    if (sg_firstTop <= 0) {
        CGFloat before = CGRectGetMinY(container.frame);
        sg_firstTop = before + feed.safeAreaInsets.top;
    }
    lifting = YES;
    if (below) below.active = NO;
    if (activeTop) activeTop.active = NO; // stale top constraint, no longer governing the current hosting wrapper
    NSLayoutConstraint *lift = [container.topAnchor constraintEqualToAnchor:page.topAnchor];
    lift.active = YES;
    objc_setAssociatedObject(container, &kFeedLiftConstraintKey, lift, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(element, &kLiftedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [page layoutIfNeeded];
    if (container.clipsToBounds) container.clipsToBounds = NO;
    insetFeed(feed);
    SGLog(@"redesign home: %@ feed container %.1fpt -> %.1fpt; first content %.0fpt",
          previouslyLifted ? @"re-lifted" : @"lifted", top, CGRectGetMinY(container.frame), sg_firstTop);
    lifting = NO;
}

// The page's own pass can run before Spotify has sized its header at all (the header's view 0 by 0, its stack still
// a width to the left and centered on the origin: seen on a 440pt phone, with no pass of the page after, which
// left the pill beside the title). While the header has no size, this comes back a little later, for a few seconds
// at most, until it has one.
static const NSUInteger kHeaderWaits = 30;
static const NSTimeInterval kHeaderWait = 0.1;
static void layoutHeaderOnceSized(UIViewController *page, UIView *header) {
    // findHeader answers YES on the stack alone, so the header can be gone while the stack is not.
    if (!header) return;
    if (!CGRectIsEmpty(header.bounds)) {
        // Sized: a later spell without a size gets its waits again.
        if (objc_getAssociatedObject(header, &kWatchKey)) objc_setAssociatedObject(header, &kWatchKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    NSUInteger waits = [objc_getAssociatedObject(header, &kWatchKey) unsignedIntegerValue];
    if (waits >= kHeaderWaits) return;
    objc_setAssociatedObject(header, &kWatchKey, @(waits + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakPage = page;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHeaderWait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongPage = weakPage;
        if (strongPage) layoutHeader(strongPage);
    });
}

static void layoutHeader(UIViewController *page) {
    UIView *view = page.viewIfLoaded;
    if (!view || !findHeader(view)) return;
    sg_pageView = view;
    UIView *header = sg_header;
    liftFeed(header.superview);
    UIStackView *stack = sg_stack;
    vanish(sg_scrim);
    layoutHeaderOnceSized(page, header);

    UIView *face = nil;
    for (UIView *part in stack.arrangedSubviews) {
        if (SGRIsAvatar(part) && !face) face = part;
        else vanish(part);
    }
    // A face that stopped being the avatar drops the scroll's transform and fade.
    if (sg_face && sg_face != face) rise(sg_face, CGAffineTransformIdentity, 1);
    sg_face = face;
    // Brought back if an earlier pass took it for a pill (vanish). Its alpha is otherwise the scroll's (followScroll).
    if (!face.userInteractionEnabled && face.accessibilityElementsHidden) {
        face.alpha = 1;
        face.userInteractionEnabled = YES;
        face.accessibilityElementsHidden = NO;
    }
    if (stack.semanticContentAttribute != UISemanticContentAttributeForceRightToLeft) {
        stack.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
        [stack setNeedsLayout];
    }
    [stack layoutIfNeeded];
    // With the Home look off, the avatar stands alone in the stack and the title ends before it; it rises and fades
    // with the title either way.
    CGFloat pillLeading = face ? CGRectGetMinX(facePlace(stack, face)) : header.bounds.size.width - SGRSideMargin + SGRGrid;
    if (SGRHomeLook()) {
        pillLeading = layoutPill(header, stack, face);
        layoutTint(view);
    }

    UILabel *title = titleIn(header);
    NSString *text = tabName(header.window);
    if (![title.text isEqualToString:text]) {
        title.text = text;
        title.accessibilityLabel = text;
    }
    UIFont *font = SGRFont(UIFontTextStyleLargeTitle, UIFontWeightBold, UIContentSizeCategoryLarge);
    if (![title.font isEqual:font]) title.font = font;

    CGFloat trailing = pillLeading - SGRGrid;
    CGFloat height = ceil(font.lineHeight);
    CGRect frame = CGRectMake(SGRSideMargin, round(CGRectGetMidY(untransformed(stack)) - height / 2), MAX(0, trailing - SGRSideMargin), height);
    place(title, frame);
    follow(view);

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"redesign home: header %@, avatar %@ in the stack %@, title %@, scrim %@", NSStringFromCGRect(header.frame),
              face ? NSStringFromCGRect(face.frame) : @"not found", NSStringFromCGRect(stack.frame), NSStringFromCGRect(frame),
              sg_scrim ? @"found" : @"not found");
    });
}

// The feed can come after the header's last pass (its page loads while the header is laid out, a few seconds on
// a slow account), and the page's view has no pass of its own after; a feed that replaces another (a filter) comes
// while the old one is still in the window. The feed's own controller hands it the follower on each of its passes.

// The Home_Evo page finishes loading *after* FunkisViewController's own
// viewDidLayoutSubviews. Stage 55 showed that no later Funkis layout occurred
// after selecting Music or returning to Home. Schedule one guarded repair on
// the next main-queue turn, when SwiftUI has completed this page's layout.
// Only pages with a missing tint or a feed at header.bottom need the pass.
static void scheduleHomeReflowForLoadedPage(UIView *loadedView) {
    UIView *root = sg_pageView;
    UIView *element = sg_header.superview;
    if (!root || !root.window || !element || !loadedView ||
        ![loadedView isDescendantOfView:root] || ![element isDescendantOfView:root] ||
        !SGBelowiOS26() || !SGUseLegacyGlass()) return;
    UIView *page = homePageNear(root, 10);
    if (!page || !page.window) return;
    UIView *container = page;
    while (container && container.superview && container.superview != element.superview)
        container = container.superview;
    BOOL displaced = container && container.superview == element.superview &&
                     CGRectGetMinY(container.frame) > 2;
    BOOL missingTint = ![objc_getAssociatedObject(page, &kTintKey) isKindOfClass:SGRHomeTintView.class] ||
                       ((UIView *)objc_getAssociatedObject(page, &kTintKey)).superview != page;
    if (!displaced && !missingTint) {
        // The selected pill's accent may arrive after the page's first
        // layout. Its background can change without a new Funkis pass, so
        // refresh the existing gradient on this page's own layout pass.
        SGRHomeTintView *tint = objc_getAssociatedObject(page, &kTintKey);
        if (tint.superview == page && isFriday() && selectedMusicAccent()) {
            paintTint(tint, YES);
            repaintFridayRing();
        }
        objc_setAssociatedObject(page, &kHomeReflowTriesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if ([objc_getAssociatedObject(page, &kHomeReflowTriesKey) integerValue] >= 3 ||
        objc_getAssociatedObject(page, &kHomeReflowPendingKey)) return;
    objc_setAssociatedObject(page, &kHomeReflowPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakPage = page;
    __weak UIView *weakRoot = root;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *current = weakPage, *host = weakRoot;
        if (!current) return;
        objc_setAssociatedObject(current, &kHomeReflowPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!host.window || sg_pageView != host || ![current isDescendantOfView:host]) return;
        NSInteger attempts = [objc_getAssociatedObject(current, &kHomeReflowTriesKey) integerValue];
        objc_setAssociatedObject(current, &kHomeReflowTriesKey, @(attempts + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        liftFeed(sg_header.superview);
        layoutTint(host);
    });
}

%hook _TtC16Home_EvoPageImpl33EvoLoadableResourceViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *view = ((UIViewController *)self).viewIfLoaded;
    if (!sg_pageView || !view.window || ![view isDescendantOfView:sg_pageView]) return;
    scheduleHomeReflowForLoadedPage(view);
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:UICollectionView.class]) {
            if (sub != sg_feed) followFeed((UIScrollView *)sub);
            break;
        }
    }
}
%end

%hook _TtC19Home_FunkisPageImpl20FunkisViewController
- (void)viewDidLayoutSubviews {
    %orig;
    CFTimeInterval began = SGRHomeProbeBegin();
    layoutHeader((UIViewController *)self);
    SGRHomeProbeEnd(SGRHomeProbeHeader, began);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    [((UIViewController *)self).viewIfLoaded setNeedsLayout];
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC19Home_FunkisPageImpl20FunkisViewController",
        @"_TtC16Home_EvoPageImpl33EvoLoadableResourceViewController",
        @"_TtC29ListeningActivity_ElementsKit21AdaptiveFaceContainer",
    ]);
}
