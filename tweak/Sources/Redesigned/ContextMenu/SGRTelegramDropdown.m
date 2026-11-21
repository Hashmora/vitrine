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
static const NSTimeInterval kTGHighlightDuration = 0.16;
static char kTGHighlightKey, kTGStyledKey, kTGMenuRootKey, kTGTintKey;
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

static void tintPanel(UIView *platter, UIView *glass) {
    UIView *tint = objc_getAssociatedObject(platter, &kTGTintKey);
    if (!tint) {
        tint = [UIView new];
        tint.userInteractionEnabled = NO;
        tint.accessibilityElementsHidden = YES;
        tint.accessibilityIdentifier = @"Vitrine.TelegramDropdown.PanelTint";
        tint.backgroundColor = [UIColor colorWithWhite:1 alpha:0.025];
        tint.layer.cornerCurve = kCACornerCurveContinuous;
        objc_setAssociatedObject(platter, &kTGTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!CGRectEqualToRect(tint.frame, platter.bounds)) tint.frame = platter.bounds;
    CGFloat radius = MIN(kTGPanelRadius, platter.bounds.size.height * 0.5);
    tint.layer.cornerRadius = radius;
    if (tint.superview != platter) [platter insertSubview:tint aboveSubview:glass];
}

void SGRTelegramDressDropdown(UIView *list, UIView *platter, UIView *glass) {
    if (!list || !platter || !glass || !platter.window) return;
    CGFloat radius = MIN(kTGPanelRadius, platter.bounds.size.height * 0.5);
    platter.layer.cornerRadius = radius;
    platter.layer.cornerCurve = kCACornerCurveContinuous;
    platter.clipsToBounds = YES;
    if (glass.layer.cornerRadius != radius) SGShapeGlass(glass, radius, NO);
    SGRDimSheetGlass(glass, 0.28);
    tintPanel(platter, glass);

    UICollectionView *collection = menuCollection(platter);
    if (collection) {
        collection.backgroundColor = UIColor.clearColor;
        collection.opaque = NO;
        if (collection.backgroundView) collection.backgroundView.hidden = YES;
        for (UICollectionViewCell *cell in collection.visibleCells) styleCell(cell);
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
