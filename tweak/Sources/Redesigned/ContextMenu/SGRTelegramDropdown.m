// One shared Telegram-inspired dropdown renderer for button-originated UIKit menus.
// Telegram's ContextControllerActionsStackNode is not a UIKit system controller:
// UIKit owns action dispatch and submenu navigation; this module owns the visual
// panel, row backgrounds and interactive highlight for every matching UIMenu.
// No Telegram Swift/AsyncDisplayKit sources or proprietary APIs are embedded.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "SGRTelegramDropdown.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

static const CGFloat kTGPanelRadius = 30.0;
static const CGFloat kTGActionInset = 10.0;
static const CGFloat kTGHighlightRadius = 20.0;
// Stage 142 used Telegram's .85 *opaque legacy image* as an additional
// alpha film over Vitrine's already blurred and darkened panel. That stacks
// the opacities and produces a nearly black panel. The alpha here is for our
// *separate* tint layer, not for Telegram's precomposited image.
static const CGFloat kTGGlassOverlayAlpha = 0.56;
static const NSTimeInterval kTGHighlightDuration = 0.16;
static char kTGHighlightKey, kTGStyledKey, kTGMenuRootKey, kTGSeparatorLineKey;
static CFTimeInterval sg_lastMenuButtonAt;
static __weak UIWindow *sg_lastMenuButtonWindow;

// A direct touch on a UIKit control is the common entry point for UIButton.menu,
// UIBarButtonItem.menu and Spotify's own wrapped buttons. It is deliberately not
// triggered by a long press on a song/album card.
void SGRTelegramDropdownControlTouched(UIControl *control) {
    if (!control.window || !SGRedesignedUI() || !SGBelowiOS26()) return;
    sg_lastMenuButtonAt = CACurrentMediaTime();
    sg_lastMenuButtonWindow = control.window;
}

static UIView *menuRoot(UIView *list) {
    UIView *last = nil;
    for (UIView *view = list; view && ![view isKindOfClass:UIWindow.class]; view = view.superview) {
        NSString *name = NSStringFromClass(view.class);
        if ([name isEqualToString:@"_UIContextMenuView"] || [name hasSuffix:@"UIContextMenuContainerView"])
            last = view;
    }
    return last ?: list.superview;
}

// Mark the actual menu, not a transient global "Vitrine menu open" flag.
// Once marked, all of its nested More/submenu lists remain styled even after
// the original button's touch and the source sheet have finished.
BOOL SGRTelegramDropdownShouldStyle(UIView *list, BOOL vitrineButtonMenu) {
    UIView *root = menuRoot(list);
    if (!root || !list.window) return NO;
    if ([objc_getAssociatedObject(root, &kTGMenuRootKey) boolValue]) return YES;
    BOOL recent = sg_lastMenuButtonWindow && CACurrentMediaTime() - sg_lastMenuButtonAt < 1.5;
    if (recent && sg_lastMenuButtonWindow.windowScene && list.window.windowScene &&
        sg_lastMenuButtonWindow.windowScene != list.window.windowScene) recent = NO;
    if (!vitrineButtonMenu && !recent) return NO;
    objc_setAssociatedObject(root, &kTGMenuRootKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static UICollectionView *menuCollection(UIView *platter) {
    __block UICollectionView *collection = nil;
    SGForEachView(platter, ^(UIView *view) {
        if (!collection && [view isKindOfClass:UICollectionView.class]) collection = (UICollectionView *)view;
    });
    return collection;
}

// The highlight belongs INSIDE the scrolling collection. In v1 it was behind
// the collection, which has its own opaque backgrounds on iOS 18, and could be
// covered by the stock menu even when the selection frame was correct.
static UIView *highlightFor(UICollectionView *collection) {
    UIView *highlight = objc_getAssociatedObject(collection, &kTGHighlightKey);
    if (!highlight) {
        highlight = [UIView new];
        highlight.accessibilityIdentifier = @"Vitrine.TelegramDropdown.Selection";
        highlight.userInteractionEnabled = NO;
        highlight.accessibilityElementsHidden = YES;
        highlight.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
        highlight.layer.cornerCurve = kCACornerCurveContinuous;
        highlight.alpha = 0;
        objc_setAssociatedObject(collection, &kTGHighlightKey, highlight, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (highlight.superview != collection) [collection insertSubview:highlight atIndex:0];
    else if (collection.subviews.firstObject != highlight) [collection sendSubviewToBack:highlight];
    return highlight;
}

static UICollectionViewCell *activeCell(UICollectionView *collection) {
    for (UICollectionViewCell *cell in collection.visibleCells) {
        if (cell.highlighted) return cell;
    }
    return nil;
}

static void updateHighlight(UICollectionView *collection, BOOL animate) {
    if (!collection) return;
    UIView *highlight = highlightFor(collection);
    UICollectionViewCell *cell = activeCell(collection);
    CGRect target = CGRectZero;
    if (cell && cell.window && cell.bounds.size.width > 10 && cell.bounds.size.height > 10) {
        CGRect frame = [cell convertRect:cell.bounds toView:collection];
        target = CGRectMake(kTGActionInset, frame.origin.y,
                            MAX(0, collection.bounds.size.width - 2 * kTGActionInset), frame.size.height);
    }
    BOOL shown = !CGRectIsEmpty(target);
    if (shown) {
        highlight.layer.cornerRadius = MIN(kTGHighlightRadius, target.size.height * 0.5);
        if (!animate || CGRectIsEmpty(highlight.frame) || highlight.alpha < 0.01) highlight.frame = target;
    }
    void (^apply)(void) = ^{
        if (shown) highlight.frame = target;
        highlight.alpha = shown ? 1 : 0;
    };
    if (animate && (shown || highlight.alpha > 0.01)) {
        [UIView animateWithDuration:kTGHighlightDuration delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:apply completion:nil];
    } else apply();
}

// UIKit 18 owns Auto Layout for these private content views, so assigning a
// frame during the outer cell's layout (Stage 144) is undone immediately by
// the content view's next constraint pass. A translation on the *original*
// icon and stack survives that pass, preserves their images/vibrancy, and does
// not replace any of UIKit's action or hit-testing views.
static void placeDropdownContent(UIView *view, CGFloat x, CGFloat y) {
    if (!view) return;
    // center and bounds describe the untransformed frame: unlike -frame,
    // they do not include a previous translation. Repeated calls are stable.
    CGFloat originalX = view.center.x - view.bounds.size.width * 0.5;
    CGFloat originalY = view.center.y - view.bounds.size.height * 0.5;
    CGAffineTransform transform = CGAffineTransformMakeTranslation(x - originalX, y - originalY);
    if (!CGAffineTransformEqualToTransform(view.transform, transform)) view.transform = transform;
}

static void matchDropdownRowContent(UICollectionViewCell *cell) {
    UIView *content = cell.contentView;
    if (!content || cell.bounds.size.width < 40 || cell.bounds.size.height < 30) return;

    NSMutableArray<UIImageView *> *icons = [NSMutableArray array];
    UIStackView *textStack = nil;
    for (UIView *child in content.subviews) {
        if ([child isKindOfClass:UIImageView.class] && !child.hidden) [icons addObject:(UIImageView *)child];
        if (!textStack && [child isKindOfClass:UIStackView.class]) textStack = (UIStackView *)child;
    }
    if (!textStack || icons.count == 0) return;

    if (cell.bounds.size.width < 130) {
        // Top quick actions remain tiles. On iOS 26 the symbol is centered
        // around y=27 and the caption begins at y=44.667.
        for (UIImageView *icon in icons)
            placeDropdownContent(icon, (cell.bounds.size.width - icon.bounds.size.width) * 0.5,
                                 18.0);
        placeDropdownContent(textStack, (cell.bounds.size.width - textStack.bounds.size.width) * 0.5,
                             44.667);
        for (UIView *v in textStack.arrangedSubviews) {
            if (![v isKindOfClass:UILabel.class]) continue;
            UILabel *label = (UILabel *)v;
            if (fabs(label.font.pointSize - 12.0) > 0.1)
                label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
        }
        return;
    }

    // On iOS 18 a regular action image sits at x=211, while on iOS 26 it
    // sits at x~26 and the text starts at x=60. More has two images: the
    // smaller chevron is trailing, the actual action glyph is leading.
    if (cell.bounds.size.width < 180) return;
    UIImageView *chevron = nil;
    UIImageView *action = nil;
    for (UIImageView *icon in icons) {
        if (icon.bounds.size.width < 15.0 && icons.count > 1) chevron = icon;
        else if (!action) action = icon;
    }
    if (!action) action = icons.firstObject;
    if (action)
        placeDropdownContent(action, 36.0 - action.bounds.size.width * 0.5,
                             floor((cell.bounds.size.height - action.bounds.size.height) * 0.5));
    if (chevron && chevron != action)
        placeDropdownContent(chevron, cell.bounds.size.width - 30.0 - chevron.bounds.size.width * 0.5,
                             floor((cell.bounds.size.height - chevron.bounds.size.height) * 0.5));

    placeDropdownContent(textStack, 60.0,
                         floor((cell.bounds.size.height - textStack.bounds.size.height) * 0.5));
    if (textStack.arrangedSubviews.count > 1) {
        for (UIView *v in textStack.arrangedSubviews) {
            if (![v isKindOfClass:UILabel.class]) continue;
            UILabel *label = (UILabel *)v;
            if (label == textStack.arrangedSubviews.lastObject &&
                fabs(label.font.pointSize - 13.0) > 0.1)
                label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
        }
    }
}

// The cell's own layout hook runs before UIKit lays out its inner content
// view. Apply the stable translations again AFTER that inner layout too.
void SGRTelegramDropdownContentLaidOut(UIView *content) {
    if (!content.window || ![NSStringFromClass(content.class) isEqualToString:@"_UIContextMenuCellContentView"]) return;
    UICollectionViewCell *cell = (UICollectionViewCell *)content.superview;
    if (![cell isKindOfClass:UICollectionViewCell.class]) return;
    UIView *list = nil;
    for (UIView *view = cell; view && ![view isKindOfClass:UIWindow.class]; view = view.superview)
        if ([NSStringFromClass(view.class) isEqualToString:@"_UIContextMenuListView"]) { list = view; break; }
    if (!list || ![objc_getAssociatedObject(menuRoot(list), &kTGMenuRootKey) boolValue]) return;
    matchDropdownRowContent(cell);
}

// UIKit rows remain the interactive views with the real UIMenu actions. Make
// the stock grey/opaque row backgrounds transparent so the shared Telegram
// panel and its inset highlight are what is actually visible.
static void styleCell(UICollectionViewCell *cell) {
    if (!cell) return;
    if (cell.backgroundColor) cell.backgroundColor = UIColor.clearColor;
    if (cell.contentView.backgroundColor) cell.contentView.backgroundColor = UIColor.clearColor;
    cell.opaque = NO;
    cell.contentView.opaque = NO;
    if (cell.backgroundView) cell.backgroundView.hidden = YES;
    if (cell.selectedBackgroundView) cell.selectedBackgroundView.hidden = YES;
    SGForEachView(cell.contentView, ^(UIView *child) {
        if (child == cell.contentView) return;
        NSString *name = NSStringFromClass(child.class);
        if ([name containsString:@"Separator"] && child.bounds.size.height <= 2.0) {
            child.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
            return;
        }
        // Only the full-width panel paint is removed. Icons, checks, title
        // labels, slider controls and submenu arrows are never modified.
        if ([child isMemberOfClass:UIView.class] &&
            child.bounds.size.width > cell.bounds.size.width * 0.75 &&
            child.bounds.size.height > cell.bounds.size.height * 0.75 &&
            child.backgroundColor) child.backgroundColor = UIColor.clearColor;
    });
    matchDropdownRowContent(cell);
}

void SGRTelegramDropdownCellLaidOut(UICollectionViewCell *cell) {
    if (!cell.window) return;
    UIView *list = nil;
    for (UIView *view = cell; view && ![view isKindOfClass:UIWindow.class]; view = view.superview) {
        if ([NSStringFromClass(view.class) isEqualToString:@"_UIContextMenuListView"]) {
            list = view;
            break;
        }
    }
    if (!list || ![objc_getAssociatedObject(menuRoot(list), &kTGMenuRootKey) boolValue]) return;
    styleCell(cell);
}

// Telegram's ContextControllerActionsListSeparatorItemNode: an 18 pt
// inset hairline centered in the existing UIKit spacer. Do not change
// reusable-view sizes: UIKit owns hit areas and the menu's content height.
static void styleSeparator(UIView *separator) {
    if (!separator || separator.bounds.size.width < 50 || separator.bounds.size.height > 21) return;
    if (![separator isKindOfClass:UICollectionReusableView.class] ||
        [separator isKindOfClass:UICollectionViewCell.class]) return;
    if (separator.backgroundColor != UIColor.clearColor) separator.backgroundColor = UIColor.clearColor;
    separator.opaque = NO;
    for (UIView *sub in separator.subviews) {
        if ([sub isKindOfClass:UIVisualEffectView.class]) sub.hidden = YES;
    }
    UIView *line = objc_getAssociatedObject(separator, &kTGSeparatorLineKey);
    if (!line) {
        line = [UIView new];
        line.userInteractionEnabled = NO;
        line.accessibilityElementsHidden = YES;
        line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        line.accessibilityIdentifier = @"Vitrine.TelegramDropdown.Separator";
        objc_setAssociatedObject(separator, &kTGSeparatorLineKey, line, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (line.superview != separator) [separator addSubview:line];
    CGFloat pixel = 1.0 / MAX(1.0, UIScreen.mainScreen.scale);
    CGRect frame = CGRectMake(18, (separator.bounds.size.height - pixel) * 0.5,
                              MAX(0, separator.bounds.size.width - 36), pixel);
    if (!CGRectEqualToRect(line.frame, frame)) line.frame = frame;
}

void SGRTelegramDressDropdown(UIView *list, UIView *platter, UIView *glass) {
    if (!list || !platter || !glass || !platter.window) return;
    CGFloat radius = MIN(kTGPanelRadius, platter.bounds.size.height * 0.5);
    platter.layer.cornerRadius = radius;
    platter.layer.cornerCurve = kCACornerCurveContinuous;
    platter.clipsToBounds = YES;
    if (glass.layer.cornerRadius != radius) SGShapeGlass(glass, radius, NO);

    // UIKit 18 keeps a 14pt cut-out/shadow outside the actual platter. With
    // our 30pt Telegram silhouette the old cut-out shows as white, pointed
    // corners around a dark, rounded panel. Mask the *whole list* and remove
    // only that legacy cut-out, not the real content or our specular border.
    if (list.layer.cornerRadius != radius) list.layer.cornerRadius = radius;
    list.layer.cornerCurve = kCACornerCurveContinuous;
    if (!list.layer.masksToBounds) list.layer.masksToBounds = YES;
    for (UIView *child in list.subviews) {
        if ([NSStringFromClass(child.class) isEqualToString:@"_UICutoutShadowView"] && !child.hidden)
            child.hidden = YES;
    }

    // Telegram renders a precomposited legacy panel with #1C1C1C @ .85.
    // Here the CABackdropLayer and an independent body already contribute
    // opacity, so an additional .85 tint makes the final composite too black.
    // Keep the same charcoal hue but lower only this OVERLAY's exposure.
    SGRDimSheetGlassTint(glass, [UIColor colorWithWhite:0.11 alpha:kTGGlassOverlayAlpha]);

    UICollectionView *collection = menuCollection(platter);
    if (collection) {
        collection.backgroundColor = UIColor.clearColor;
        collection.opaque = NO;
        if (collection.backgroundView) collection.backgroundView.hidden = YES;
        for (UICollectionViewCell *cell in collection.visibleCells) styleCell(cell);
        SGForEachView(collection, ^(UIView *view) {
            if ([view isKindOfClass:UICollectionReusableView.class] &&
                ![view isKindOfClass:UICollectionViewCell.class]) styleSeparator(view);
        });
        updateHighlight(collection, NO);
    }
    if (![objc_getAssociatedObject(platter, &kTGStyledKey) boolValue]) {
        objc_setAssociatedObject(platter, &kTGStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGLog(@"dropdown: shared Telegram panel for UIKit button menu %@", NSStringFromCGRect(platter.bounds));
    }
}

void SGRTelegramDropdownCellHighlightChanged(UICollectionViewCell *cell) {
    if (!cell.window) return;
    UIView *list = nil;
    for (UIView *view = cell; view && ![view isKindOfClass:UIWindow.class]; view = view.superview) {
        if ([NSStringFromClass(view.class) isEqualToString:@"_UIContextMenuListView"]) {
            list = view;
            break;
        }
    }
    if (!list || ![objc_getAssociatedObject(menuRoot(list), &kTGMenuRootKey) boolValue]) return;
    for (UIView *v = cell.superview; v && v != list; v = v.superview) {
        if ([v isKindOfClass:UICollectionView.class]) {
            updateHighlight((UICollectionView *)v, YES);
            return;
        }
    }
}
