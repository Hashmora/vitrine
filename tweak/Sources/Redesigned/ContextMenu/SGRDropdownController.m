// Button dropdowns owned by Vitrine. UIKit UIMenu is only the source of commands.
// Geometry, sections, hit testing and submenus do not use _UIContextMenu*.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "SGRDropdownController.h"
#import "SGRDropdownDeferred.h"

static const CGFloat kWidth = 250, kRadius = 30, kInset = 10;
static const CGFloat kRow = 42, kSubtitle = 58, kQuick = 93, kQuickSingle = 77, kHeader = 62;
static const CGFloat kSectionGap = 11, kSubmenuSectionGap = 21, kBottomPadding = 10, kSubmenuDrop = 12;
static const CGFloat kPanelMaximum = 520;
// Lightweight presentation transitions only. The touch-driven iOS 26 morph
// remains a separate task; never replay an open transition on a data refresh.
static const NSTimeInterval kOpenTime = 0.18, kSubmenuTime = 0.16, kDismissTime = 0.12;
static char kOwnedGlassKey;

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
@property (nonatomic, strong) NSMutableDictionary<NSValue *, NSArray<UIMenuElement *> *> *results;
@property (nonatomic, strong) NSMutableSet<NSValue *> *requested;
@property (nonatomic, copy) void (^didChange)(UIMenu *snapshot);
@property (nonatomic) BOOL cancelled;
- (instancetype)initWithMenu:(UIMenu *)menu;
- (UIMenu *)snapshot;
- (void)begin;
- (void)cancel;
@end

@implementation SGRDropdownResolution
- (instancetype)initWithMenu:(UIMenu *)menu {
    if ((self = [super init])) {
        self.source = menu;
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
            SGRDropdownDeferredRequest((UIDeferredMenuElement *)element, ^(NSArray<UIMenuElement *> *ready) {
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
- (void)begin { [self requestElements:self.source.children depth:0]; }
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

static CGFloat contentHeight(UIMenu *menu, BOOL withHeader) {
    CGFloat height = withHeader ? kHeader + 10 : 0;
    NSArray<NSArray<SGRDropdownItem *> *> *groups = groupsOf(menu);
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

@interface SGRDropdownPanel : UIView
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIView *body;
@property (nonatomic, strong) UIView *separator;
@property (nonatomic, strong) UIView *header;
@property (nonatomic, strong) UIView *tileGroup;
@property (nonatomic, strong) NSMutableArray<SGRDropdownPress *> *tileButtons;
@property (nonatomic, strong) UIMenu *menu;
@property (nonatomic, strong) SGRDropdownResolution *resolution;
@property (nonatomic) BOOL isSubmenu;
@property (nonatomic, copy) void (^choose)(UIMenuElement *element);
@property (nonatomic, copy) void (^back)(void);
@property (nonatomic) CGFloat actualHeight;
- (void)configure:(UIMenu *)menu title:(NSString *)title maxHeight:(CGFloat)maximum;
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
        self.scroll.showsVerticalScrollIndicator = NO;
        self.scroll.showsHorizontalScrollIndicator = NO;
        self.scroll.alwaysBounceVertical = NO;
        self.scroll.delaysContentTouches = NO;
        self.scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        self.scroll.backgroundColor = UIColor.clearColor;
        [self addSubview:self.scroll];
        self.body = [UIView new];
        self.body.backgroundColor = UIColor.clearColor;
        [self.scroll addSubview:self.body];
        self.tileButtons = [NSMutableArray array];
        self.layer.shadowOpacity = 0;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    UIView *glass = SGRGlassPaneIn(self, &kOwnedGlassKey, kRadius);
    // The owned pane is not UIKit's already-darkened context menu. Match the
    // opacity of the reference surface here, rather than letting the artwork
    // and the previous menu read sharply through the live glass material.
    if (glass) SGRDimSheetGlassTint(glass, [UIColor colorWithWhite:self.isSubmenu ? 0.16 : 0.11
                                                        alpha:self.isSubmenu ? 0.82 : 0.62]);
    self.scroll.frame = self.bounds;
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
        UIImageView *tick = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
        tick.tintColor = UIColor.whiteColor;
        tick.frame = CGRectMake(206, (h-20)/2, 18, 20);
        [press addSubview:tick];
    }
    [self.body addSubview:press];
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
    }
    // A continuous drag highlights the actual individual tile under the finger.
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragQuick:)];
    pan.cancelsTouchesInView = YES;
    [tileGroup addGestureRecognizer:pan];
}
- (void)dragQuick:(UIPanGestureRecognizer *)pan {
    CGPoint point = [pan locationInView:self.tileGroup];
    SGRDropdownPress *active = nil;
    for (SGRDropdownPress *tile in self.tileButtons) {
        BOOL inside = CGRectContainsPoint(tile.frame, point);
        tile.highlighted = inside;
        if (inside) active = tile;
    }
    if (pan.state == UIGestureRecognizerStateEnded && active) [active activate];
    if (pan.state == UIGestureRecognizerStateCancelled || pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateFailed) {
        for (SGRDropdownPress *tile in self.tileButtons) tile.highlighted = NO;
    }
}
- (void)configure:(UIMenu *)menu title:(NSString *)title maxHeight:(CGFloat)maximum {
    self.menu = menu;
    for (UIView *child in [self.body.subviews copy]) [child removeFromSuperview];
    [self.tileButtons removeAllObjects];
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
        [self.body addSubview:head];
        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(24, kHeader, kWidth-48, 1.0/UIScreen.mainScreen.scale)];
        line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.13];
        [self.body addSubview:line];
        y = kHeader+10;
    }
    NSArray<NSArray<SGRDropdownItem *> *> *groups = groupsOf(menu);
    for (NSUInteger i=0; i<groups.count; ++i) {
        NSArray<SGRDropdownItem *> *group = groups[i];
        CGFloat gap = gapBeforeGroup(groups, i, title.length > 0);
        if (gap > 0) {
            CGFloat lineY = y + (gap == kSubmenuSectionGap ? 10 :
                                 groups[i-1].firstObject.tile ? 0 : 5);
            UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(24, lineY, kWidth-48, 1.0/UIScreen.mainScreen.scale)];
            separator.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
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
    self.bounds = CGRectMake(0, 0, kWidth, self.actualHeight);
    [self setNeedsLayout];
}
- (void)backTapped { if (self.back) self.back(); }
@end

@interface SGRDropdownPresentation : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIViewController *root;
@property (nonatomic, weak) UIView *anchor;
@property (nonatomic, strong) UIMenu *rootMenu;
@property (nonatomic, strong) UIViewController *embedded;
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
- (void)showContent:(UIViewController *)controller preferredSize:(CGSize)size;
- (void)loadMenu:(UIMenu *)menu intoPanel:(SGRDropdownPanel *)panel title:(NSString *)title maximum:(CGFloat)maximum;
- (void)reflowPanel:(SGRDropdownPanel *)panel;
@end

@implementation SGRDropdownPresentation
- (BOOL)start:(UIMenu *)menu from:(UIView *)anchor finish:(SGRDropdownFinish)finish {
    if (!anchor.window.windowScene || !menu) return NO;
    self.anchor = anchor;
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
    SGRDropdownResolution *probe = [[SGRDropdownResolution alloc] initWithMenu:menu];
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
- (CGFloat)minimumSubmenuTop {
    CGFloat bottom = [self submenuStackBottom];
    return MIN(bottom - 1, MAX(62, CGRectGetMinY(self.origin) + kSubmenuDrop));
}
- (CGFloat)submenuYForHeight:(CGFloat)height {
    return MAX([self minimumSubmenuTop], [self submenuStackBottom] - height);
}
- (CGFloat)submenuAvailableHeight {
    return MAX(1, [self submenuStackBottom] - [self minimumSubmenuTop]);
}
- (void)outsideTapped { [self dismiss:nil]; }
- (void)backTapped { [self popMenu]; }
- (void)popMenu {
    if (self.closing || self.popping) return;
    if (self.panels.count < 2) { [self dismiss:nil]; return; }
    self.popping = YES;
    SGRDropdownPanel *top = self.panels.lastObject;
    SGRDropdownPanel *under = self.panels[self.panels.count - 2];
    // Do not let a late provider change the outgoing submenu during its fade.
    [top.resolution cancel];
    top.userInteractionEnabled = NO;
    [UIView animateWithDuration:kSubmenuTime delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                     animations:^{
        top.alpha = 0;
        top.transform = CGAffineTransformMakeScale(0.98, 0.98);
        under.alpha = 1;
    } completion:^(__unused BOOL finished) {
        if (self.panels.lastObject == top) {
            [top.resolution cancel];
            [top removeFromSuperview];
            [self.panels removeLastObject];
            [self.menuIDs removeLastObject];
        }
        self.popping = NO;
    }];
}
- (void)choose:(UIMenuElement *)element {
    if (self.closing || self.popping) return;
    if ([element isKindOfClass:UIMenu.class]) { [self pushMenu:(UIMenu *)element title:element.title]; return; }
    if (dropdownAttributes(element) & UIMenuElementAttributesDisabled) return;
    [self dismiss:element];
}
// A deferred completion changes the existing panel's content in-place. The
// resolution belongs to that panel and is invalidated on update/dismiss/back;
// late callbacks must never reconstruct a dismissed or replaced menu.
- (void)loadMenu:(UIMenu *)menu intoPanel:(SGRDropdownPanel *)panel title:(NSString *)title maximum:(CGFloat)maximum {
    [panel.resolution cancel];
    SGRDropdownResolution *resolution = [[SGRDropdownResolution alloc] initWithMenu:menu];
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
        CGPoint offset = livePanel.scroll.contentOffset;
        [livePanel configure:snapshot title:title maxHeight:maximum];
        [strongSelf reflowPanel:livePanel];
        CGFloat maxOffset = MAX(0, livePanel.scroll.contentSize.height - livePanel.bounds.size.height);
        livePanel.scroll.contentOffset = CGPointMake(offset.x, MIN(offset.y, maxOffset));
    };
}
- (void)reflowPanel:(SGRDropdownPanel *)panel {
    CGRect frame = panel.frame;
    frame.size.height = panel.actualHeight;
    if (panel == self.panels.firstObject) {
        CGFloat top = MAX(62, self.window.safeAreaInsets.top);
        CGFloat bottom = CGRectGetHeight(self.window.bounds) - self.window.safeAreaInsets.bottom - 12;
        // Grow toward the top when async data arrives near the screen's foot;
        // do not hide actions outside the window or replay the opening motion.
        CGFloat y = MIN(self.origin.origin.y, MAX(top, bottom - panel.actualHeight));
        self.origin = CGRectMake(self.origin.origin.x, y, kWidth, panel.actualHeight);
        frame.origin.y = y;
    } else {
        frame.origin.y = [self submenuYForHeight:panel.actualHeight];
    }
    panel.frame = frame;
    for (SGRDropdownPanel *other in self.panels) {
        if (other == panel || other == self.panels.firstObject) continue;
        CGRect next = other.frame;
        next.origin.y = [self submenuYForHeight:other.actualHeight];
        other.frame = next;
    }
}
- (void)pushMenu:(UIMenu *)menu title:(NSString *)title {
    if (self.closing || self.popping || self.panels.count >= 8) return;
    SGRDropdownPanel *parent = self.panels.lastObject;
    SGRDropdownPanel *panel = [[SGRDropdownPanel alloc] initWithFrame:CGRectZero];
    panel.isSubmenu = title.length > 0;
    __weak SGRDropdownPresentation *weakSelf = self;
    panel.choose = ^(UIMenuElement *element) { [weakSelf choose:element]; };
    panel.back = ^{ [weakSelf popMenu]; };
    // The root retains its anchor. Submenus share a lower edge with the
    // reference's 520pt menu stack; shorter menus begin farther down while
    // long menus use the available height and scroll internally.
    CGFloat maximum = parent ? [self submenuAvailableHeight] :
        MAX(1, CGRectGetHeight(self.root.view.bounds) - self.window.safeAreaInsets.bottom - 12
            - MAX(62, self.window.safeAreaInsets.top));
    [self loadMenu:menu intoPanel:panel title:title maximum:MIN(kPanelMaximum, maximum)];
    CGFloat y = parent ? [self submenuYForHeight:panel.actualHeight] : self.origin.origin.y;
    CGRect frame = CGRectMake(self.origin.origin.x, y, kWidth, panel.actualHeight);
    panel.frame = frame;
    [self.root.view addSubview:panel];
    [self.panels addObject:panel];
    [self.menuIDs addObject:menu.identifier ?: menu.title ?: @""];
    [panel.resolution begin];
    // The first pane arrives only once. Submenus are separate surfaces above
    // the parent; refreshing UIMenu data must never restart this transition.
    panel.alpha = 0;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    [UIView animateWithDuration:parent ? kSubmenuTime : kOpenTime delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{
        panel.alpha = 1;
        panel.transform = CGAffineTransformIdentity;
        if (parent) parent.alpha = 0.5;
    } completion:nil];
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
- (void)showContent:(UIViewController *)controller preferredSize:(CGSize)size {
    if (!controller || !self.window || !self.panels.count) return;
    SGRDropdownPanel *panel = self.panels.firstObject;
    panel.scroll.hidden = YES;
    CGFloat width = MIN(MAX(200, size.width), CGRectGetWidth(self.root.view.bounds)-24);
    CGFloat height = MIN(MAX(120, size.height), MIN(kPanelMaximum, CGRectGetHeight(self.root.view.bounds)-100));
    CGRect position = CGRectMake(CGRectGetMaxX(self.origin)-width, self.origin.origin.y, width, height);
    position.origin.x = MAX(12, position.origin.x);
    CGFloat below = CGRectGetHeight(self.root.view.bounds)-self.window.safeAreaInsets.bottom-12;
    if (CGRectGetMaxY(position)>below) position.origin.y=MAX(62,below-height);
    panel.frame = position;
    self.embedded = controller;
    [self.root addChildViewController:controller];
    controller.view.frame = panel.bounds;
    controller.view.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    controller.view.backgroundColor = UIColor.clearColor;
    [panel addSubview:controller.view];
    [controller didMoveToParentViewController:self.root];
    // An embedded control is sized after its empty UIMenu shell is made. Stop
    // that shell's transition and open the real, final-sized surface just once.
    [panel.layer removeAllAnimations];
    panel.alpha = 0;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    [UIView animateWithDuration:kOpenTime delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{
        panel.alpha = 1;
        panel.transform = CGAffineTransformIdentity;
    } completion:nil];
}
- (void)update:(UIMenu *)menu {
    if (!menu || !self.window || self.closing || self.popping) return;
    self.rootMenu = menu;
    SGRDropdownPanel *first = self.panels.firstObject;
    CGPoint offset = first.scroll.contentOffset;
    CGFloat bottom = CGRectGetHeight(self.window.bounds) - self.window.safeAreaInsets.bottom - 12;
    [self loadMenu:menu intoPanel:first title:nil maximum:MIN(kPanelMaximum, MAX(1, bottom-self.origin.origin.y))];
    [first.resolution begin];
    first.frame = CGRectMake(self.origin.origin.x, self.origin.origin.y, kWidth, first.actualHeight);
    first.scroll.contentOffset = offset;
    if (self.panels.count < 2) return;
    for (NSUInteger i=1; i<self.panels.count; ++i) {
        UIMenu *sub = matchingSubmenu(menu, self.menuIDs[i]);
        if (!sub) continue;
        SGRDropdownPanel *panel = self.panels[i];
        CGPoint prior = panel.scroll.contentOffset;
        [self loadMenu:sub intoPanel:panel title:sub.title maximum:MIN(kPanelMaximum, [self submenuAvailableHeight])];
        [panel.resolution begin];
        CGRect frame = panel.frame;
        frame.origin.y = [self submenuYForHeight:panel.actualHeight];
        frame.size.height = panel.actualHeight;
        panel.frame = frame;
        panel.scroll.contentOffset = prior;
    }
}
- (void)finishDismiss:(UIMenuElement *)element {
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
    [UIView animateWithDuration:kDismissTime delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                     animations:^{ surface.alpha = 0; }
                     completion:^(__unused BOOL finished) { [self finishDismiss:element]; }];
}
@end

static SGRDropdownPresentation *sg_currentDropdown;
BOOL SGRDropdownPresent(UIView *anchor, UIMenu *menu, SGRDropdownFinish finished) {
    if (!anchor.window || !menu) return NO;
    // If Spotify supplied a responder-chain or pre-hook provider with no
    // accessible block, never steal the native presentation and show a blank.
    if (!SGRDropdownDeferredMenuSupported(menu)) return NO;
    if (sg_currentDropdown) {
        if (sg_currentDropdown.anchor == anchor && sg_currentDropdown.window && !sg_currentDropdown.closing) return YES;
        // Replacing an existing menu is immediate: no dying overlay above the
        // next window, and no delayed callback into a new menu session.
        [sg_currentDropdown finishDismiss:nil];
        sg_currentDropdown = nil;
    }
    SGRDropdownPresentation *showing = [SGRDropdownPresentation new];
    __weak SGRDropdownPresentation *weakShowing = showing;
    if (![showing start:menu from:anchor finish:^(UIMenuElement *element) {
        if (sg_currentDropdown == weakShowing) sg_currentDropdown = nil;
        if (finished) finished(element);
    }]) return NO;
    sg_currentDropdown = showing;
    return YES;
}
void SGRDropdownUpdate(UIView *anchor, UIMenu *menu) {
    if (sg_currentDropdown.anchor == anchor && SGRDropdownDeferredMenuSupported(menu))
        [sg_currentDropdown update:menu];
}
BOOL SGRDropdownIsPresentingFrom(UIView *anchor) {
    return anchor && sg_currentDropdown.anchor == anchor && sg_currentDropdown.window;
}
void SGRDropdownDismissFrom(UIView *anchor) {
    if (SGRDropdownIsPresentingFrom(anchor)) [sg_currentDropdown dismiss:nil];
}

BOOL SGRDropdownPresentContent(UIView *anchor, UIViewController *content, CGSize preferredSize) {
    if (!anchor.window || !content) return NO;
    if (sg_currentDropdown) {
        [sg_currentDropdown finishDismiss:nil];
        sg_currentDropdown = nil;
    }
    UIMenu *empty = [UIMenu menuWithChildren:@[]];
    if (!SGRDropdownPresent(anchor, empty, nil)) return NO;
    [sg_currentDropdown showContent:content preferredSize:preferredSize];
    return YES;
}
void SGRDropdownDismissActive(void) {
    [sg_currentDropdown dismiss:nil];
}
