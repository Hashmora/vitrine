// Vitrine's UIKit implementation of the Telegram-style glass drop-down surface.
// Visual geometry is based on Telegram iOS ContextControllerActionsStackNode:
// 30pt panel corners, 10pt action insets, and a 20pt rounded highlight.
// This does not embed Telegram's Swift/AsyncDisplayKit/GlassBackgroundComponent
// sources or their dependencies, nor does it change UIMenu actions/submenus.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "SGRTelegramDropdown.h"
#import <objc/runtime.h>

static const CGFloat kTGPanelRadius = 30.0;
static const CGFloat kTGActionInset = 10.0;
static const CGFloat kTGHighlightRadius = 20.0;
static const NSTimeInterval kTGHighlightDuration = 0.16;
static char kTGHighlightKey;
static char kTGStyledKey;

// UIKit keeps its own collection rows and their targets. Our shape is a
// pass-through sibling under the list; a drag still reaches UIKit unmodified.
static UIView *highlightFor(UIView *platter) {
    UIView *highlight = objc_getAssociatedObject(platter, &kTGHighlightKey);
    if (!highlight) {
        highlight = [UIView new];
        highlight.userInteractionEnabled = NO;
        highlight.accessibilityElementsHidden = YES;
        highlight.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        highlight.layer.cornerCurve = kCACornerCurveContinuous;
        highlight.alpha = 0;
        objc_setAssociatedObject(platter, &kTGHighlightKey, highlight, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Keep the highlight above the material yet below UIKit's action cells.
    if (highlight.superview != platter) [platter insertSubview:highlight atIndex:MIN((NSUInteger)1, platter.subviews.count)];
    return highlight;
}

static UICollectionView *menuCollection(UIView *platter) {
    __block UICollectionView *collection = nil;
    SGForEachView(platter, ^(UIView *view) {
        if (!collection && [view isKindOfClass:UICollectionView.class]) collection = (UICollectionView *)view;
    });
    return collection;
}

static UICollectionViewCell *activeCell(UICollectionView *collection) {
    for (UICollectionViewCell *cell in collection.visibleCells) {
        if (cell.highlighted) return cell;
    }
    return nil;
}

static void updateHighlight(UIView *platter, BOOL animate) {
    UIView *highlight = highlightFor(platter);
    UICollectionView *collection = menuCollection(platter);
    UICollectionViewCell *cell = collection ? activeCell(collection) : nil;
    CGRect target = CGRectZero;
    if (cell && cell.window && cell.bounds.size.width > 10 && cell.bounds.size.height > 10) {
        CGRect bounds = [cell convertRect:cell.bounds toView:platter];
        CGFloat x = kTGActionInset;
        target = CGRectMake(x, CGRectGetMinY(bounds),
                            MAX(0, platter.bounds.size.width - x * 2), bounds.size.height);
        // A first pass can still have a collection with incorrect geometry.
        if (CGRectGetMaxY(target) > platter.bounds.size.height + 2 || target.origin.y < -2) target = CGRectZero;
    }
    BOOL shown = !CGRectIsEmpty(target);
    if (shown) {
        highlight.layer.cornerRadius = MIN(kTGHighlightRadius, target.size.height * 0.5);
        if (!animate || CGRectIsEmpty(highlight.frame) || highlight.alpha == 0) highlight.frame = target;
    }
    void (^apply)(void) = ^{
        if (shown) highlight.frame = target;
        highlight.alpha = shown ? 1.0 : 0.0;
    };
    if (animate && highlight.superview && (shown || highlight.alpha > 0.001)) {
        [UIView animateWithDuration:kTGHighlightDuration delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:apply completion:nil];
    } else apply();
}

// The menu's original cutout is 14pt on iOS 18. Clip only the content host to
// the new radius and leave UIKit's placement, touch regions and shadow owner
// alone. Submenus get the same shape, without manipulating their navigation.
void SGRTelegramDressDropdown(UIView *list, UIView *platter, UIView *glass) {
    if (!list || !platter || !glass || !platter.window) return;
    CGFloat radius = MIN(kTGPanelRadius, platter.bounds.size.height * 0.5);
    if (platter.layer.cornerRadius != radius) platter.layer.cornerRadius = radius;
    if (platter.layer.cornerCurve != kCACornerCurveContinuous) platter.layer.cornerCurve = kCACornerCurveContinuous;
    if (!platter.clipsToBounds) platter.clipsToBounds = YES;
    if (glass.layer.cornerRadius != radius) SGShapeGlass(glass, radius, NO);
    // Telegram's panel tint is less black than Spotify's base sheet. Retain
    // Vitrine's material/refraction; this only controls the surface exposure.
    SGRDimSheetGlass(glass, 0.34);
    UIView *selection = highlightFor(platter);
    if (selection.superview == platter) {
        UICollectionView *collection = menuCollection(platter);
        if (collection && collection.superview == platter)
            [platter insertSubview:selection belowSubview:collection];
    }
    // UIKit does all actual selection/deselection; we mirror its live row.
    // Stage 1 intentionally keeps Telegram's eased 160ms selection response.
    updateHighlight(platter, NO);
    if (!objc_getAssociatedObject(platter, &kTGStyledKey)) {
        objc_setAssociatedObject(platter, &kTGStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGLog(@"dropdown port: Telegram-style action surface %.0fpt, %@", radius, NSStringFromCGRect(platter.bounds));
    }
}

void SGRTelegramDropdownCellHighlightChanged(UICollectionViewCell *cell) {
    if (!cell.window) return;
    UIView *list = nil;
    for (UIView *v = cell; v && ![v isKindOfClass:UIWindow.class]; v = v.superview) {
        if ([NSStringFromClass(v.class) isEqualToString:@"_UIContextMenuListView"]) { list = v; break; }
    }
    if (!list) return;
    for (UIView *view = cell; view && view != list; view = view.superview) {
        if (objc_getAssociatedObject(view, &kTGStyledKey)) {
            updateHighlight(view, YES);
            break;
        }
    }
}
