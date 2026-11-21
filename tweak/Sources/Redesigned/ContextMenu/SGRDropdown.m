// Shared dropdown renderer for button-originated UIKit menus.
// UIKit owns action dispatch and submenu navigation; this module owns the visual
// panel, row backgrounds and interactive highlight for every matching UIMenu.
// No third-party UI sources are embedded.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "SGRDropdown.h"
#import "Redesigned/ContextMenu/ContextMenu.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

static const CGFloat kDropdownPanelRadius = 30.0;
static const CGFloat kDropdownActionInset = 10.0;
static const CGFloat kDropdownHighlightRadius = 20.0;
// An 0.85 alpha film over the already darkened glass over-darkened the panel.
// This alpha controls a separate tint layer, not the final panel opacity.
static const CGFloat kDropdownGlassOverlayAlpha = 0.56;
static const NSTimeInterval kDropdownHighlightDuration = 0.16;
static char kDropdownHighlightKey, kDropdownStyledKey, kDropdownMenuRootKey, kDropdownSeparatorLineKey, kDropdownReferenceSizedKey;
static CFTimeInterval sg_lastMenuButtonAt;
static __weak UIWindow *sg_lastMenuButtonWindow;

// A direct touch on a UIKit control is the common entry point for UIButton.menu,
// UIBarButtonItem.menu and Spotify's own wrapped buttons. It is deliberately not
// triggered by a long press on a song/album card.
void SGRDropdownControlTouched(UIControl *control) {
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
BOOL SGRDropdownShouldStyle(UIView *list, BOOL vitrineButtonMenu) {
    UIView *root = menuRoot(list);
    if (!root || !list.window) return NO;
    if ([objc_getAssociatedObject(root, &kDropdownMenuRootKey) boolValue]) return YES;
    BOOL recent = sg_lastMenuButtonWindow && CACurrentMediaTime() - sg_lastMenuButtonAt < 1.5;
    if (recent && sg_lastMenuButtonWindow.windowScene && list.window.windowScene &&
        sg_lastMenuButtonWindow.windowScene != list.window.windowScene) recent = NO;
    if (!vitrineButtonMenu && !recent) return NO;
    objc_setAssociatedObject(root, &kDropdownMenuRootKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    UIView *highlight = objc_getAssociatedObject(collection, &kDropdownHighlightKey);
    if (!highlight) {
        highlight = [UIView new];
        highlight.accessibilityIdentifier = @"Vitrine.Dropdown.Selection";
        highlight.userInteractionEnabled = NO;
        highlight.accessibilityElementsHidden = YES;
        highlight.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
        highlight.layer.cornerCurve = kCACornerCurveContinuous;
        highlight.alpha = 0;
        objc_setAssociatedObject(collection, &kDropdownHighlightKey, highlight, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
        // The three quick actions at the top are three independent tiles,
        // not one full-width selectable row. Their highlights must never
        // escape the individual tile, even during a drag across the row.
        BOOL tile = frame.size.width < collection.bounds.size.width * 0.55;
        if (tile) {
            const CGFloat tileInset = 6.0;
            target = CGRectInset(frame, tileInset, tileInset);
        } else {
            target = CGRectMake(kDropdownActionInset, frame.origin.y,
                                MAX(0, collection.bounds.size.width - 2 * kDropdownActionInset), frame.size.height);
        }
    }
    BOOL shown = !CGRectIsEmpty(target);
    if (shown) {
        highlight.layer.cornerRadius = MIN(kDropdownHighlightRadius, target.size.height * 0.5);
        if (!animate || CGRectIsEmpty(highlight.frame) || highlight.alpha < 0.01) highlight.frame = target;
    }
    void (^apply)(void) = ^{
        if (shown) highlight.frame = target;
        highlight.alpha = shown ? 1 : 0;
    };
    if (animate && (shown || highlight.alpha > 0.01)) {
        [UIView animateWithDuration:kDropdownHighlightDuration delay:0
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

// The iOS 18 content view reserves room for its original TRAILING symbol.
// Moving that symbol to the leading edge (Stage 145) did not release the
// constraint on the text stack: a 250pt row still receives only ~101pt of
// text, whereas the same iOS 26 row receives 162pt. Dress the measured
// frames after the PRIVATE content view's final layout, without altering any
// collection-view cell or its touch rectangle.
static void setDropdownFrame(UIView *view, CGRect frame) {
    if (!view || CGRectEqualToRect(view.frame, frame)) return;
    view.frame = frame;
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

    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    for (UIView *view in textStack.arrangedSubviews)
        if ([view isKindOfClass:UILabel.class]) [labels addObject:(UILabel *)view];
    if (!labels.count) return;
    UIView *parent = cell.superview;
    while (parent && ![parent isKindOfClass:UICollectionView.class]) parent = parent.superview;
    BOOL referenceMenu = [objc_getAssociatedObject(parent, &kDropdownReferenceSizedKey) boolValue];

    if (cell.bounds.size.width < 130) {
        // iOS 26: 78pt tiles with 74pt captions. The older UIKit reserves
        // 10pt on each side of the caption and scales symbols down. The
        // original SF Symbol image has the reference geometry in its size.
        BOOL referenceTile = referenceMenu && fabs(cell.bounds.size.width - 78) < 1 &&
                             fabs(cell.bounds.size.height - 93) < 1;
        for (UIImageView *icon in icons) {
            if (referenceTile && icon.image && icon.bounds.size.width > 1 && icon.bounds.size.height > 1) {
                CGSize image = icon.image.size;
                CGFloat scaleX = image.width / icon.bounds.size.width;
                CGFloat scaleY = image.height / icon.bounds.size.height;
                if (image.width >= 16 && image.width <= 26 && image.height >= 15 && image.height <= 25 &&
                    scaleX >= 0.9 && scaleX <= 1.5 && scaleY >= 0.9 && scaleY <= 1.5) {
                    // Preserve the source image, not a separately drawn icon.
                    CGFloat centerY = image.height >= 21 ? 27 : image.width >= 23 ? 29 : 27.667;
                    CGAffineTransform t = CGAffineTransformMake(scaleX, 0, 0, scaleY,
                                                                cell.bounds.size.width * 0.5 - icon.center.x,
                                                                centerY - icon.center.y);
                    if (!CGAffineTransformEqualToTransform(icon.transform, t)) icon.transform = t;
                    continue;
                }
            }
            placeDropdownContent(icon, (cell.bounds.size.width - icon.bounds.size.width) * 0.5, 18.0);
        }
        for (UILabel *label in labels) {
            if (fabs(label.font.pointSize - 12.0) > 0.1)
                label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
        }
        if (referenceTile) {
            CGFloat labelHeight = [labels.firstObject.text containsString:@"\n"] ||
                                  labels.firstObject.bounds.size.height > 20 ? 30.333333 : 14.333333;
            // Keep the label and its stack equally wide. UIKit can relayout
            // them later; this pass re-applies the geometry idempotently.
            CGRect bounds = textStack.bounds;
            bounds.size = CGSizeMake(74.0, labelHeight);
            if (!CGRectEqualToRect(textStack.bounds, bounds)) textStack.bounds = bounds;
            placeDropdownContent(textStack, 2.0, 44.666667);
            setDropdownFrame(labels.firstObject, CGRectMake(0, 0, 74.0, labelHeight));
        } else {
            placeDropdownContent(textStack,
                                 (cell.bounds.size.width - textStack.bounds.size.width) * 0.5, 44.667);
        }
        return;
    }

    // The action glyph is leading and the smaller submenu chevron is trailing.
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

    BOOL referenceWidth = referenceMenu && fabs(cell.bounds.size.width - 250.0) < 1.0;
    if (referenceWidth && labels.count > 1 &&
        (fabs(cell.bounds.size.height - 80.0) < 1 || fabs(cell.bounds.size.height - 58.0) < 1)) {
        BOOL tall = cell.bounds.size.height > 70;
        CGFloat titleHeight = tall ? 42.333333 : 20.333333;
        CGFloat subtitleTop = tall ? 43.0 : 21.0;
        CGFloat stackHeight = tall ? 58.666667 : 36.666667;
        UILabel *title = labels.firstObject, *subtitle = labels.lastObject;
        if (title.numberOfLines != 2) title.numberOfLines = 2;
        if (fabs(title.preferredMaxLayoutWidth - 162.0) > 0.5) title.preferredMaxLayoutWidth = 162.0;
        if (fabs(subtitle.font.pointSize - 13.0) > 0.1)
            subtitle.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
        CGRect bounds = textStack.bounds;
        bounds.size = CGSizeMake(162.0, stackHeight);
        if (!CGRectEqualToRect(textStack.bounds, bounds)) textStack.bounds = bounds;
        placeDropdownContent(textStack, 60.0, 10.666667);
        setDropdownFrame(title, CGRectMake(0, 0, 162.0, titleHeight));
        setDropdownFrame(subtitle, CGRectMake(0, subtitleTop, 162.0, 15.666667));
    } else if (referenceWidth && labels.count == 1 && fabs(cell.bounds.size.height - 42.0) < 1) {
        CGRect bounds = textStack.bounds;
        bounds.size.height = 20.333333;
        if (!CGRectEqualToRect(textStack.bounds, bounds)) textStack.bounds = bounds;
        placeDropdownContent(textStack, 60.0, 10.666667);
        setDropdownFrame(labels.firstObject, CGRectMake(0, 0, labels.firstObject.bounds.size.width, 20.333333));
    } else {
        // Other button dropdowns retain their own measured line heights.
        placeDropdownContent(textStack, 60.0,
                             floor((cell.bounds.size.height - textStack.bounds.size.height) * 0.5));
        if (labels.count > 1) {
            UILabel *subtitle = labels.lastObject;
            if (fabs(subtitle.font.pointSize - 13.0) > 0.1)
                subtitle.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
        }
    }
}

// The cell's own layout hook runs before UIKit lays out its inner content
// view. Apply the stable translations again AFTER that inner layout too.
void SGRDropdownContentLaidOut(UIView *content) {
    if (!content.window || ![NSStringFromClass(content.class) isEqualToString:@"_UIContextMenuCellContentView"]) return;
    UICollectionViewCell *cell = (UICollectionViewCell *)content.superview;
    if (![cell isKindOfClass:UICollectionViewCell.class]) return;
    UIView *list = nil;
    for (UIView *view = cell; view && ![view isKindOfClass:UIWindow.class]; view = view.superview)
        if ([NSStringFromClass(view.class) isEqualToString:@"_UIContextMenuListView"]) { list = view; break; }
    if (!list || ![objc_getAssociatedObject(menuRoot(list), &kDropdownMenuRootKey) boolValue]) return;
    matchDropdownRowContent(cell);
}

// UIKit rows remain the interactive views with the real UIMenu actions. Make
// the stock grey/opaque row backgrounds transparent so the shared dropdown
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

void SGRDropdownCellLaidOut(UICollectionViewCell *cell) {
    if (!cell.window) return;
    UIView *list = nil;
    for (UIView *view = cell; view && ![view isKindOfClass:UIWindow.class]; view = view.superview) {
        if ([NSStringFromClass(view.class) isEqualToString:@"_UIContextMenuListView"]) {
            list = view;
            break;
        }
    }
    if (!list || ![objc_getAssociatedObject(menuRoot(list), &kDropdownMenuRootKey) boolValue]) return;
    styleCell(cell);
}

// A separator with an 18 pt
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
    UIView *line = objc_getAssociatedObject(separator, &kDropdownSeparatorLineKey);
    if (!line) {
        line = [UIView new];
        line.userInteractionEnabled = NO;
        line.accessibilityElementsHidden = YES;
        line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        line.accessibilityIdentifier = @"Vitrine.Dropdown.Separator";
        objc_setAssociatedObject(separator, &kDropdownSeparatorLineKey, line, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (line.superview != separator) [separator addSubview:line];
    CGFloat pixel = 1.0 / MAX(1.0, UIScreen.mainScreen.scale);
    CGRect frame = CGRectMake(18, (separator.bounds.size.height - pixel) * 0.5,
                              MAX(0, separator.bounds.size.width - 36), pixel);
    if (!CGRectEqualToRect(line.frame, frame)) line.frame = frame;
}

void SGRDropdownDress(UIView *list, UIView *platter, UIView *glass) {
    if (!list || !platter || !glass || !platter.window) return;
    CGFloat radius = MIN(kDropdownPanelRadius, platter.bounds.size.height * 0.5);
    platter.layer.cornerRadius = radius;
    platter.layer.cornerCurve = kCACornerCurveContinuous;
    platter.clipsToBounds = YES;
    if (glass.layer.cornerRadius != radius) SGShapeGlass(glass, radius, NO);

    // UIKit 18 keeps a 14pt cut-out/shadow outside the actual platter. With
    // our 30pt rounded silhouette the old cut-out shows as white, pointed
    // corners around a dark, rounded panel. Mask the *whole list* and remove
    // only that legacy cut-out, not the real content or our specular border.
    if (list.layer.cornerRadius != radius) list.layer.cornerRadius = radius;
    list.layer.cornerCurve = kCACornerCurveContinuous;
    if (!list.layer.masksToBounds) list.layer.masksToBounds = YES;
    for (UIView *child in list.subviews) {
        if ([NSStringFromClass(child.class) isEqualToString:@"_UICutoutShadowView"] && !child.hidden)
            child.hidden = YES;
    }

    // Use a translucent dark-grey fill over the existing glass.
    // Here the CABackdropLayer and an independent body already contribute
    // opacity, so an additional .85 tint makes the final composite too black.
    // Keep the same charcoal hue but lower only this OVERLAY's exposure.
    SGRDimSheetGlassTint(glass, [UIColor colorWithWhite:0.11 alpha:kDropdownGlassOverlayAlpha]);

    UICollectionView *collection = menuCollection(platter);
    if (collection) {
        collection.backgroundColor = UIColor.clearColor;
        collection.opaque = NO;
        // Dropdown action lists should not show a system scrollbar. The
        // native UICollectionView may still scroll when a menu is genuinely
        // taller than the viewport; suppress only its indicators, not scrolling.
        if (collection.showsVerticalScrollIndicator) collection.showsVerticalScrollIndicator = NO;
        if (collection.showsHorizontalScrollIndicator) collection.showsHorizontalScrollIndicator = NO;
        if (collection.backgroundView) collection.backgroundView.hidden = YES;
        for (UICollectionViewCell *cell in collection.visibleCells) styleCell(cell);
        SGForEachView(collection, ^(UIView *view) {
            if ([view isKindOfClass:UICollectionReusableView.class] &&
                ![view isKindOfClass:UICollectionViewCell.class]) styleSeparator(view);
        });
        updateHighlight(collection, NO);
    }
    if (![objc_getAssociatedObject(platter, &kDropdownStyledKey) boolValue]) {
        objc_setAssociatedObject(platter, &kDropdownStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGLog(@"dropdown: shared dropdown panel for UIKit button menu %@", NSStringFromCGRect(platter.bounds));
    }
}

// The player button menu has six native actions. The iOS 18 layout gives
// them a 265.7pt platter; the same actions on iOS 26 occupy 315pt. These
// reference metrics were measured with SG_DRIVER on both simulators, *not*
// inferred from an image. We adjust the real UIKit cells and their hit map,
// rather than stretch just the dark material or draw an inert duplicate menu.
// Other UIMenu shapes retain native heights until independently measured.
static char kDropdownReferenceBusyKey, kDropdownRefLine1Key, kDropdownRefLine2Key;
static char kDropdownMoreBusyKey, kDropdownMoreSizedKey, kDropdownMoreLinesKey, kDropdownMoreHeaderLineKey;

static NSUInteger menuItemCount(UICollectionView *collection) {
    NSUInteger count = 0;
    for (NSInteger section = 0; section < collection.numberOfSections; section++)
        count += [collection numberOfItemsInSection:section];
    return count;
}

static BOOL hasSubtitle(UICollectionViewCell *cell) {
    for (UIView *v in cell.contentView.subviews) {
        if (![v isKindOfClass:UIStackView.class]) continue;
        NSUInteger labels = 0;
        for (UIView *item in ((UIStackView *)v).arrangedSubviews)
            if ([item isKindOfClass:UILabel.class]) labels++;
        return labels >= 2;
    }
    return NO;
}

static void makeReferenceTitleWrap(UICollectionViewCell *cell) {
    for (UIView *v in cell.contentView.subviews) {
        if (![v isKindOfClass:UIStackView.class]) continue;
        for (UIView *item in ((UIStackView *)v).arrangedSubviews) {
            if (![item isKindOfClass:UILabel.class]) continue;
            UILabel *label = (UILabel *)item;
            if (label != ((UIStackView *)v).arrangedSubviews.firstObject) continue;
            if (label.numberOfLines != 2) label.numberOfLines = 2;
            if (fabs(label.preferredMaxLayoutWidth - 162.0) > 0.5) label.preferredMaxLayoutWidth = 162.0;
            if (label.lineBreakMode != NSLineBreakByWordWrapping) label.lineBreakMode = NSLineBreakByWordWrapping;
            break;
        }
    }
}

static void positionReferenceRow(UICollectionViewCell *cell, CGRect target) {
    if (!CGRectEqualToRect(cell.frame, target)) cell.frame = target;
    // Keep UICollectionViewCell's content view aligned with the adjusted
    // actual touch rectangle, rather than letting the old 64pt clip survive.
    if (!CGRectEqualToRect(cell.contentView.frame, cell.bounds)) cell.contentView.frame = cell.bounds;
    matchDropdownRowContent(cell);
}

static void referenceLine(UICollectionView *collection, const void *key, CGFloat y) {
    UIView *line = objc_getAssociatedObject(collection, key);
    if (!line) {
        line = [UIView new];
        line.userInteractionEnabled = NO;
        line.accessibilityElementsHidden = YES;
        line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        objc_setAssociatedObject(collection, key, line, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (line.superview != collection) [collection addSubview:line];
    CGFloat pixel = 1.0 / MAX(1, collection.window.screen.scale);
    CGRect target = CGRectMake(24, y, MAX(0, collection.bounds.size.width - 48), pixel);
    if (!CGRectEqualToRect(line.frame, target)) line.frame = target;
}


// UIKit 26 keeps the first menu as a separate, dimmed pane when More opens.
// iOS 18 normally shrinks the second list to the first one's height and shifts
// the underlying list down; the old port also faded the whole parent to zero.
// This adapter is scoped to *button-originated* menus. It keeps UIKit's
// original cell instances, actions, scroll gestures and submenu navigation.
static NSArray<UIView *> *submenuLists(UIView *menu) {
    NSMutableArray<UIView *> *lists = [NSMutableArray array];
    for (UIView *v in menu.subviews)
        if ([NSStringFromClass(v.class) isEqualToString:@"_UIContextMenuListView"])
            [lists addObject:v];
    return lists;
}

static UIView *submenuPlatter(UIView *list) {
    for (UIView *v in list.subviews)
        if ([v isMemberOfClass:UIView.class] && v.bounds.size.width >= 200)
            return v;
    return nil;
}

static NSArray<UICollectionViewCell *> *sortedMenuCells(UICollectionView *collection) {
    return [collection.visibleCells sortedArrayUsingComparator:^NSComparisonResult(UICollectionViewCell *a, UICollectionViewCell *b) {
        CGFloat ay = CGRectGetMinY(a.frame), by = CGRectGetMinY(b.frame);
        return ay < by ? NSOrderedAscending : ay > by ? NSOrderedDescending : NSOrderedSame;
    }];
}

static UIView *submenuTitleIn(UICollectionView *collection) {
    for (UIView *v in collection.subviews)
        if ([NSStringFromClass(v.class) isEqualToString:@"_UIContextMenuSubmenuTitleView"])
            return v;
    return nil;
}

static BOOL submenuTitleIs(UIView *header, NSString *expected) {
    if (!header) return NO;
    __block BOOL found = NO;
    SGForEachView(header, ^(UIView *v) {
        if ([v isKindOfClass:UILabel.class] && [((UILabel *)v).text isEqualToString:expected]) found = YES;
    });
    return found;
}

static void dressMoreHeader(UIView *header) {
    if (!header || header.bounds.size.width < 200) return;
    UIView *content = nil;
    for (UIView *v in header.subviews) {
        if ([NSStringFromClass(v.class) isEqualToString:@"_UIContextMenuCellContentView"]) content = v;
        // The opaque iOS 18 header strip must not sit above our one-piece
        // pane: use the same glass as the rows underneath.
        if ([v isKindOfClass:UIVisualEffectView.class] && !v.hidden) v.hidden = YES;
    }
    if (!content) return;
    UIImageView *chevron = nil, *ellipsis = nil;
    UIStackView *text = nil;
    for (UIView *v in content.subviews) {
        if ([v isKindOfClass:UIStackView.class]) text = (UIStackView *)v;
        if (![v isKindOfClass:UIImageView.class] || v.alpha < 0.05 || v.hidden) continue;
        UIImageView *icon = (UIImageView *)v;
        if (icon.bounds.size.width <= 16) chevron = icon;
        else if (icon.bounds.size.width >= 18) ellipsis = icon;
    }
    // iOS 26: ellipsis at the leading edge, title at x=60, disclosure at
    // the trailing edge. Move UIKit's original views rather than cloning.
    placeDropdownContent(ellipsis, 26, 21);
    placeDropdownContent(text, 60, 20.667);
    if (chevron) {
        static UIImage *down;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ down = [UIImage systemImageNamed:@"chevron.down"]; });
        // UIKit can replace the image during a later layout pass; keep
        // enforcing the shared trailing disclosure, not just its frame.
        if (down && chevron.image != down) chevron.image = down;
        placeDropdownContent(chevron, 213, 26.333);
    }
    for (UIView *v in header.subviews) {
        if (![NSStringFromClass(v.class) isEqualToString:@"_UIContextMenuSeparatorView"]) continue;
        if (!v.hidden) v.hidden = YES;  // a single inset rule replaces it
    }
}

void SGRDropdownSubmenuHeaderLaidOut(UIView *header) {
    if (!header.window || !SGBelowiOS26()) return;
    UIView *list = header.superview;
    while (list && ![NSStringFromClass(list.class) isEqualToString:@"_UIContextMenuListView"]) list = list.superview;
    if (!list || ![objc_getAssociatedObject(menuRoot(list), &kDropdownMenuRootKey) boolValue]) return;
    // A title inside a menu with no separate secondary list is not More.
    UIView *menu = list.superview;
    if (submenuLists(menu).count < 2) return;
    dressMoreHeader(header);
}

static void moreRowLines(UICollectionView *collection, NSArray<UICollectionViewCell *> *cells) {
    NSMutableArray<UIView *> *lines = objc_getAssociatedObject(collection, &kDropdownMoreLinesKey);
    if (!lines) {
        lines = [NSMutableArray array];
        objc_setAssociatedObject(collection, &kDropdownMoreLinesKey, lines, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat pixel = 1.0 / MAX(1.0, collection.window.screen.scale);
    // The native iOS 18 separators still sit at the old 43.67pt rhythm.
    // Hide only those on the reference-sized submenu and draw real rules at
    // the new action boundaries, without allowing them to receive touches.
    for (UIView *v in collection.subviews) {
        if ([v isKindOfClass:UICollectionReusableView.class] && ![v isKindOfClass:UICollectionViewCell.class])
            v.layer.opacity = 0;
    }
    for (NSUInteger i = 0; i < cells.count; i++) {
        UIView *line = nil;
        if (i < lines.count) line = lines[i];
        else {
            line = [UIView new];
            line.userInteractionEnabled = NO;
            line.accessibilityElementsHidden = YES;
            line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
            [lines addObject:line];
        }
        if (line.superview != collection) [collection addSubview:line];
        CGFloat y = CGRectGetMaxY(cells[i].frame);
        CGRect frame = CGRectMake(18, y - pixel * 0.5, MAX(0, collection.bounds.size.width - 36), pixel);
        if (!CGRectEqualToRect(line.frame, frame)) line.frame = frame;
        line.hidden = i == cells.count - 1;
    }
}

// Returns YES for a dropdown submenu handled by this adapter. This means
// the older hideUnder() animation must not run on the same two lists.
BOOL SGRDropdownMatchSubmenuGeometry(UIView *menu) {
    if (!menu.window || ![NSStringFromClass(menu.class) isEqualToString:@"_UIContextMenuView"]) return NO;
    NSArray<UIView *> *lists = submenuLists(menu);
    if (lists.count < 2) return NO;
    UIView *under = lists.firstObject;
    if (!SGRDropdownShouldStyle(under, SGRDropdownMenuIsOpenedFromButton())) return NO;
    UIView *front = lists.lastObject;
    UIView *platter = submenuPlatter(front);
    UICollectionView *collection = platter ? menuCollection(platter) : nil;
    if (!collection || menuItemCount(collection) == 0) return YES;
    if ([objc_getAssociatedObject(menu, &kDropdownMoreBusyKey) boolValue]) return YES;
    objc_setAssociatedObject(menu, &kDropdownMoreBusyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Keep the already-laid-out parent where it opened. The iOS 26 tree has
    // list alpha=1, but its *collection of actions* is dimmed to 0.5.
    if (under.alpha != 1) under.alpha = 1;
    UIView *underPlatter = submenuPlatter(under);
    UICollectionView *underCollection = underPlatter ? menuCollection(underPlatter) : nil;
    if (underCollection && fabs(underCollection.alpha - 0.5) > 0.01) underCollection.alpha = 0.5;
    CGRect parent = under.frame;
    if (fabs(parent.size.width - 242.5) < 2 && parent.size.height > 280) {
        parent.origin.x = 7.5;
        parent.origin.y = 0;
        parent.size.height = 305.55;
        if (!CGRectEqualToRect(parent, under.frame)) under.frame = parent;
    }

    NSUInteger count = menuItemCount(collection);
    UIView *header = submenuTitleIn(collection);
    BOOL measuredMore = count == 13 && fabs(collection.bounds.size.width - 250) < 2
                        && submenuTitleIs(header, @"More");
    CGFloat naturalBottom = 0;
    NSArray<UICollectionViewCell *> *cells = sortedMenuCells(collection);
    for (UICollectionViewCell *cell in cells)
        naturalBottom = MAX(naturalBottom, CGRectGetMaxY(cell.frame));
    CGFloat height = measuredMore ? 508.0 : MIN(508.0, MAX(front.bounds.size.height, naturalBottom + 10));
    if (height > 1) {
        CGRect root = menu.frame;
        root.size.height = height + 12;
        if (!CGRectEqualToRect(root, menu.frame)) menu.frame = root;
        CGRect target = front.frame;
        target.origin.x = 0;
        target.origin.y = 12;
        target.size.width = menu.bounds.size.width;
        target.size.height = height;
        if (!CGRectEqualToRect(target, front.frame)) front.frame = target;
        CGRect pane = platter.frame;
        pane.origin = CGPointZero;
        pane.size = target.size;
        if (!CGRectEqualToRect(pane, platter.frame)) platter.frame = pane;
    }
    if (front.alpha != 1) front.alpha = 1;
    if (collection.alpha != 1) collection.alpha = 1;

    // The 13-action Spotify More sheet has an independently measured 62pt
    // header + 10pt breathing room, 42pt rows, and a 64pt wrapping row.
    // Do not impose those heights on unrelated UIMenu contents.
    if (measuredMore && cells.count == 13) {
        if (header) {
            CGRect title = header.frame;
            title.origin.y = 0;
            title.size.height = 62;
            if (!CGRectEqualToRect(header.frame, title)) header.frame = title;
            dressMoreHeader(header);
        }
        CGFloat y = 72;
        for (UICollectionViewCell *cell in cells) {
            CGFloat rowHeight = cell.bounds.size.height > 55 ? 64 : 42;
            positionReferenceRow(cell, CGRectMake(0, y, 250, rowHeight));
            y += rowHeight;
        }
        // The real cells remain the hit-test targets, not visual copies.
        objc_setAssociatedObject(collection, &kDropdownReferenceSizedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (collection.contentSize.height < y)
            collection.contentSize = CGSizeMake(collection.contentSize.width, y);
        moreRowLines(collection, cells);
        referenceLine(collection, &kDropdownMoreHeaderLineKey, 62);
    }
    objc_setAssociatedObject(menu, &kDropdownMoreBusyKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

BOOL SGRDropdownReferenceHit(UICollectionView *collection, CGPoint point, NSIndexPath **index) {
    if (![objc_getAssociatedObject(collection, &kDropdownReferenceSizedKey) boolValue]) return NO;
    // A hit follows the visual cell positions, not UIKit 18's stale flow
    // layout attributes. Required for the action and highlight to agree.
    if (index) *index = nil;
    for (UICollectionViewCell *cell in collection.visibleCells) {
        if (!CGRectContainsPoint(cell.frame, point)) continue;
        NSIndexPath *found = [collection indexPathForCell:cell];
        if (found) { if (index) *index = found; return YES; }
    }
    // Do not fall back to UIKit's original indices in the inter-row gaps:
    // its cached 18.x positions could otherwise select the wrong action.
    return YES;
}

void SGRDropdownMatchReferenceGeometry(UIView *list) {
    if (!list.window || ![objc_getAssociatedObject(menuRoot(list), &kDropdownMenuRootKey) boolValue]) return;
    // menuRoot() deliberately returns the outermost context-menu container to
    // share one style marker across nested More lists. For sizing we need the
    // *inner* menu view, which actually owns the 250pt platter rectangle.
    UIView *root = nil;
    for (UIView *v = list; v && ![v isKindOfClass:UIWindow.class]; v = v.superview) {
        if ([NSStringFromClass(v.class) isEqualToString:@"_UIContextMenuView"]) { root = v; break; }
    }
    if (!root || [objc_getAssociatedObject(root, &kDropdownReferenceBusyKey) boolValue]) return;
    // Do not shrink the shared container back to 315pt when More has
    // expanded it to hold the overlay. The parent six cells were already
    // matched before the submenu was presented.
    if (submenuLists(root).count > 1) return;
    UIView *platter = nil;
    for (UIView *v in list.subviews)
        if ([v isMemberOfClass:UIView.class] && v.bounds.size.width > 200) { platter = v; break; }
    UICollectionView *collection = platter ? menuCollection(platter) : nil;
    if (!collection || fabs(collection.bounds.size.width - 250) > 2 || menuItemCount(collection) != 6) return;
    NSArray<UICollectionViewCell *> *cells = collection.visibleCells;
    if (cells.count != 6) return;
    NSMutableArray<UICollectionViewCell *> *tiles = [NSMutableArray array];
    NSMutableArray<UICollectionViewCell *> *rows = [NSMutableArray array];
    for (UICollectionViewCell *cell in cells) {
        if (cell.bounds.size.width < 130) [tiles addObject:cell];
        else [rows addObject:cell];
    }
    if (tiles.count != 3 || rows.count != 3) return;
    [tiles sortUsingComparator:^NSComparisonResult(UICollectionViewCell *a, UICollectionViewCell *b) {
        return CGRectGetMinX(a.frame) < CGRectGetMinX(b.frame) ? NSOrderedAscending :
               CGRectGetMinX(a.frame) > CGRectGetMinX(b.frame) ? NSOrderedDescending : NSOrderedSame;
    }];
    [rows sortUsingComparator:^NSComparisonResult(UICollectionViewCell *a, UICollectionViewCell *b) {
        return CGRectGetMinY(a.frame) < CGRectGetMinY(b.frame) ? NSOrderedAscending :
               CGRectGetMinY(a.frame) > CGRectGetMinY(b.frame) ? NSOrderedDescending : NSOrderedSame;
    }];
    // Only the measured quick-actions + two subtitles + More pattern. A
    // different six-item dropdown must not receive unrelated heights.
    if (!hasSubtitle(rows[0]) || !hasSubtitle(rows[1]) || hasSubtitle(rows[2])) return;

    objc_setAssociatedObject(root, &kDropdownReferenceBusyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    const CGFloat height = 315.0;
    CGRect frame = root.frame;
    frame.size.height = height;
    // The 18.x anchored panel leaves 8pt to the right; on the reference
    // 26.3 player it leaves 12pt. Anchor to the actual container width so
    // repeated layout passes cannot cumulatively drift the menu left.
    CGFloat containerWidth = root.superview.bounds.size.width;
    CGFloat rightGap = containerWidth - CGRectGetMaxX(frame);
    if (containerWidth > 300 && rightGap >= -0.5 && rightGap <= 20.0)
        frame.origin.x = containerWidth - frame.size.width - 12.0;
    if (!CGRectEqualToRect(root.frame, frame)) root.frame = frame;
    CGRect bounds = list.frame;
    bounds.size.height = height;
    if (!CGRectEqualToRect(list.frame, bounds)) list.frame = bounds;
    bounds = platter.frame;
    bounds.size.height = height;
    if (!CGRectEqualToRect(platter.frame, bounds)) platter.frame = bounds;

    for (NSUInteger i = 0; i < 3; i++)
        positionReferenceRow(tiles[i], CGRectMake(8 + 78 * i, 0, 78, 93));
    positionReferenceRow(rows[0], CGRectMake(0, 104, 250, 80));
    positionReferenceRow(rows[1], CGRectMake(0, 184, 250, 58));
    positionReferenceRow(rows[2], CGRectMake(0, 263, 250, 42));
    makeReferenceTitleWrap(rows[0]);

    // Native 8pt spacers are at the wrong positions. Keep them in the data
    // source but suppress only their paint; use the measured one-pixel lines.
    for (UIView *view in collection.subviews) {
        if (![view isKindOfClass:UICollectionReusableView.class] ||
            [view isKindOfClass:UICollectionViewCell.class]) continue;
        if (view.layer.opacity != 0) view.layer.opacity = 0;
    }
    referenceLine(collection, &kDropdownRefLine1Key, 93);
    referenceLine(collection, &kDropdownRefLine2Key, 252);
    CGSize content = collection.contentSize;
    if (content.height < height) collection.contentSize = CGSizeMake(content.width, height);
    objc_setAssociatedObject(collection, &kDropdownReferenceSizedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The reference marker is now active: refit labels and the top SF
    // Symbols in this same pass, without waiting for another UIKit relayout.
    for (UICollectionViewCell *cell in collection.visibleCells) matchDropdownRowContent(cell);
    objc_setAssociatedObject(root, &kDropdownReferenceBusyKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void SGRDropdownCellHighlightChanged(UICollectionViewCell *cell) {
    if (!cell.window) return;
    UIView *list = nil;
    for (UIView *view = cell; view && ![view isKindOfClass:UIWindow.class]; view = view.superview) {
        if ([NSStringFromClass(view.class) isEqualToString:@"_UIContextMenuListView"]) {
            list = view;
            break;
        }
    }
    if (!list || ![objc_getAssociatedObject(menuRoot(list), &kDropdownMenuRootKey) boolValue]) return;
    for (UIView *v = cell.superview; v && v != list; v = v.superview) {
        if ([v isKindOfClass:UICollectionView.class]) {
            updateHighlight((UICollectionView *)v, YES);
            return;
        }
    }
}
