// Button dropdowns owned by Vitrine. UIKit UIMenu is only the source of commands.
// Geometry, sections, hit testing and submenus do not use _UIContextMenu*.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "SGRDropdownController.h"

static const CGFloat kWidth = 250, kRadius = 30, kInset = 10;
static const CGFloat kRow = 42, kSubtitle = 58, kQuick = 93, kHeader = 62;
static const CGFloat kPanelMaximum = 520;
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

static CGFloat rowHeight(UIMenuElement *element) {
    if (element.subtitle.length) return [element.title isEqualToString:@"Speed, Pitch & Reverb"] ? 80 : kSubtitle;
    if (element.title.length > 33) return 64;
    return kRow;
}

static CGFloat contentHeight(UIMenu *menu, BOOL withHeader) {
    CGFloat height = withHeader ? kHeader + 10 : 0;
    NSArray<NSArray<SGRDropdownItem *> *> *groups = groupsOf(menu);
    for (NSUInteger i = 0; i < groups.count; ++i) {
        NSArray<SGRDropdownItem *> *group = groups[i];
        if (i) height += 1;
        if (group.firstObject.tile) height += kQuick;
        else for (SGRDropdownItem *item in group) height += rowHeight(item.element);
    }
    return height;
}

@interface SGRDropdownPress : UIControl
@property (nonatomic, strong) UIMenuElement *element;
@property (nonatomic, copy) void (^pick)(UIMenuElement *element);
@property (nonatomic, strong) UIView *highlight;
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
    if (glass) SGRDimSheetGlassTint(glass, [UIColor colorWithWhite:0.11
                                                        alpha:self.isSubmenu ? 0.83 : 0.76]);
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
    if (element.subtitle.length) press.accessibilityValue = element.subtitle;
    UIColor *foreground = (dropdownAttributes(element) & UIMenuElementAttributesDestructive)
        ? [UIColor colorWithRed:1 green:0.36 blue:0.34 alpha:enabled ? 1 : 0.38]
        : [UIColor colorWithWhite:1 alpha:enabled ? 1 : 0.38];
    UIImageView *glyph = [[UIImageView alloc] initWithFrame:CGRectMake(14, (h-21)/2, 21, 21)];
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
    UILabel *name = textLabel(element.title, [UIFont systemFontOfSize:16 weight:UIFontWeightRegular], foreground);
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
    CGFloat tileWidth = (kWidth - 2*kInset)/items.count;
    UIView *tileGroup = [[UIView alloc] initWithFrame:CGRectMake(kInset, y, kWidth - 2*kInset, kQuick)];
    tileGroup.accessibilityIdentifier = @"Vitrine.Dropdown.QuickActions";
    [self.body addSubview:tileGroup];
    self.tileGroup = tileGroup;
    for (NSUInteger i=0; i<items.count; i++) {
        UIMenuElement *element = items[i].element;
        SGRDropdownPress *press = [[SGRDropdownPress alloc] initWithFrame:CGRectMake(i*tileWidth, 3, tileWidth, kQuick-6)];
        press.element = element;
        press.pick = self.choose;
        press.accessibilityLabel = element.title;
        press.enabled = !(dropdownAttributes(element) & UIMenuElementAttributesDisabled);
        press.highlight.layer.cornerRadius = 18;
        UIImageView *image = [[UIImageView alloc] initWithFrame:CGRectMake((tileWidth-26)/2, 14, 26, 26)];
        image.image = [element.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        image.tintColor = [UIColor colorWithWhite:1 alpha:press.enabled ? 1 : 0.4];
        image.contentMode = UIViewContentModeScaleAspectFit;
        [press addSubview:image];
        UILabel *title = textLabel(element.title, [UIFont systemFontOfSize:12 weight:UIFontWeightRegular], image.tintColor);
        title.textAlignment = NSTextAlignmentCenter;
        title.numberOfLines = 2;
        title.frame = CGRectMake(1, 50, tileWidth-2, 31);
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
        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(18, kHeader, kWidth-36, 1.0/UIScreen.mainScreen.scale)];
        line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.13];
        [self.body addSubview:line];
        y = kHeader+10;
    }
    NSArray<NSArray<SGRDropdownItem *> *> *groups = groupsOf(menu);
    for (NSUInteger i=0; i<groups.count; ++i) {
        NSArray<SGRDropdownItem *> *group = groups[i];
        if (i) {
            UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(18, y, kWidth-36, 1.0/UIScreen.mainScreen.scale)];
            separator.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
            [self.body addSubview:separator];
            y += 1;
        }
        if (group.firstObject.tile) { [self addQuick:group at:y]; y += kQuick; }
        else for (SGRDropdownItem *item in group) { [self addRow:item at:y]; y += rowHeight(item.element); }
    }
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
- (BOOL)start:(UIMenu *)menu from:(UIView *)anchor finish:(SGRDropdownFinish)finish;
- (void)update:(UIMenu *)menu;
- (void)dismiss:(UIMenuElement *)element;
- (void)pushMenu:(UIMenu *)menu title:(NSString *)title;
- (void)popMenu;
- (void)showContent:(UIViewController *)controller preferredSize:(CGSize)size;
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
    CGFloat top = MAX(62, self.window.safeAreaInsets.top+8);
    CGFloat y = CGRectGetMinY(from) <= top + 24 ? top : CGRectGetMinY(from);
    CGFloat available = CGRectGetHeight(self.window.bounds)-self.window.safeAreaInsets.bottom-12;
    CGFloat wanted = MIN(kPanelMaximum, contentHeight(menu, NO));
    if (y+wanted > available) y = MAX(top, available-wanted);
    self.origin = CGRectMake(x, y, kWidth, wanted);
    [self pushMenu:menu title:nil];
    return YES;
}
- (void)outsideTapped { [self dismiss:nil]; }
- (void)backTapped { [self popMenu]; }
- (void)popMenu {
    if (self.panels.count < 2) { [self dismiss:nil]; return; }
    SGRDropdownPanel *top = self.panels.lastObject;
    [top removeFromSuperview];
    [self.panels removeLastObject];
    [self.menuIDs removeLastObject];
    self.panels.lastObject.alpha = 1;
}
- (void)choose:(UIMenuElement *)element {
    if ([element isKindOfClass:UIMenu.class]) { [self pushMenu:(UIMenu *)element title:element.title]; return; }
    if (dropdownAttributes(element) & UIMenuElementAttributesDisabled) return;
    [self dismiss:element];
}
- (void)pushMenu:(UIMenu *)menu title:(NSString *)title {
    if (self.panels.count >= 8) return;
    SGRDropdownPanel *parent = self.panels.lastObject;
    if (parent) parent.alpha = 0.5;
    SGRDropdownPanel *panel = [[SGRDropdownPanel alloc] initWithFrame:CGRectZero];
    panel.isSubmenu = title.length > 0;
    __weak SGRDropdownPresentation *weakSelf = self;
    panel.choose = ^(UIMenuElement *element) { [weakSelf choose:element]; };
    panel.back = ^{ [weakSelf popMenu]; };
    CGFloat available = CGRectGetHeight(self.root.view.bounds) - MAX(62, self.window.safeAreaInsets.top+8) - self.window.safeAreaInsets.bottom - 12;
    [panel configure:menu title:title maxHeight:MIN(kPanelMaximum, available)];
    CGRect frame = CGRectMake(self.origin.origin.x, self.origin.origin.y, kWidth, panel.actualHeight);
    if (CGRectGetMaxY(frame) > CGRectGetHeight(self.root.view.bounds)-self.window.safeAreaInsets.bottom-12)
        frame.origin.y = MAX(62, CGRectGetHeight(self.root.view.bounds)-self.window.safeAreaInsets.bottom-12-frame.size.height);
    panel.frame = frame;
    [self.root.view addSubview:panel];
    [self.panels addObject:panel];
    [self.menuIDs addObject:menu.identifier ?: menu.title ?: @""];
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
}
- (void)update:(UIMenu *)menu {
    if (!menu || !self.window) return;
    self.rootMenu = menu;
    SGRDropdownPanel *first = self.panels.firstObject;
    CGPoint offset = first.scroll.contentOffset;
    [first configure:menu title:nil maxHeight:MIN(kPanelMaximum, CGRectGetHeight(self.window.bounds)-100)];
    first.frame = CGRectMake(self.origin.origin.x, self.origin.origin.y, kWidth, first.actualHeight);
    first.scroll.contentOffset = offset;
    if (self.panels.count < 2) return;
    for (NSUInteger i=1; i<self.panels.count; ++i) {
        UIMenu *sub = matchingSubmenu(menu, self.menuIDs[i]);
        if (!sub) continue;
        SGRDropdownPanel *panel = self.panels[i];
        CGPoint prior = panel.scroll.contentOffset;
        [panel configure:sub title:sub.title maxHeight:MIN(kPanelMaximum, CGRectGetHeight(self.window.bounds)-100)];
        CGRect frame = panel.frame;
        frame.size.height = panel.actualHeight;
        panel.frame = frame;
        panel.scroll.contentOffset = prior;
    }
}
- (void)dismiss:(UIMenuElement *)element {
    if (!self.window) return;
    SGRDropdownFinish finish = self.finish;
    self.finish = nil;
    self.window.hidden = YES;
    self.window.rootViewController = nil;
    self.window = nil;
    [self.panels removeAllObjects];
    self.root = nil;
    if (finish) finish(element);
}
@end

static SGRDropdownPresentation *sg_currentDropdown;
BOOL SGRDropdownPresent(UIView *anchor, UIMenu *menu, SGRDropdownFinish finished) {
    if (!anchor.window || !menu) return NO;
    if (sg_currentDropdown) {
        if (sg_currentDropdown.anchor == anchor) return YES;
        [sg_currentDropdown dismiss:nil];
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
    if (sg_currentDropdown.anchor == anchor) [sg_currentDropdown update:menu];
}
BOOL SGRDropdownIsPresentingFrom(UIView *anchor) {
    return anchor && sg_currentDropdown.anchor == anchor && sg_currentDropdown.window;
}
void SGRDropdownDismissFrom(UIView *anchor) {
    if (SGRDropdownIsPresentingFrom(anchor)) [sg_currentDropdown dismiss:nil];
}

BOOL SGRDropdownPresentContent(UIView *anchor, UIViewController *content, CGSize preferredSize) {
    if (!anchor.window || !content) return NO;
    if (sg_currentDropdown) [sg_currentDropdown dismiss:nil];
    UIMenu *empty = [UIMenu menuWithChildren:@[]];
    if (!SGRDropdownPresent(anchor, empty, nil)) return NO;
    [sg_currentDropdown showContent:content preferredSize:preferredSize];
    return YES;
}
void SGRDropdownDismissActive(void) {
    [sg_currentDropdown dismiss:nil];
}
