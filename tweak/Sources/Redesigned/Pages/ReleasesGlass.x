// Releases (Creator_ReleasesPageImpl), redesigned UI on iOS before 26.
// The page has a standard SPNavigationBar and a separate black 48pt filter
// strip. Its chips are EncoreConsumerMobile_BaseKit.FilterChipView, not the
// Encore_ChipsKit chips used by Recents and the other playlists.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kReleasesFilters, kReleasesChipGlass, kReleasesClearGlass;
static char kReleasesScrollKey, kReleasesScrollOffsetKey;

static BOOL inReleasesFilters(UIView *view) {
    BOOL inChips = NO;
    for (UIView *v = view; v; v = v.superview) {
        if ([v.accessibilityIdentifier isEqualToString:@"Components.UI.FilterChips"]) inChips = YES;
        if (inChips && [NSStringFromClass(v.class) containsString:@"Creator_ReleasesPageImpl"] &&
            [NSStringFromClass(v.class) containsString:@"FiltersElement"]) return YES;
    }
    return NO;
}

static void glassReleaseChip(UIView *chip) {
    if (!chip.window || !inReleasesFilters(chip) || chip.bounds.size.width < 1) return;
    UIView *fill = nil;
    for (UIView *sub in chip.subviews) {
        if ([sub isMemberOfClass:UIView.class] && sub.bounds.size.width > 1) {
            fill = sub;
            break;
        }
    }
    CGColorRef paint = fill.layer.backgroundColor;
    BOOL selected = paint && CGColorGetAlpha(paint) > 0.3;
    SGRGlassChip(chip, fill, selected, &kReleasesChipGlass);
    if (SGUseLegacyGlass()) SGRUnclipUpTo(chip.superview, ^BOOL(UIView *v) {
        return [v.accessibilityIdentifier isEqualToString:@"Components.UI.FilterChips"];
    });
}

// The selected-chip clear action is a distinct 32pt Swift ClearChipView.
// Its white 14% disc is separate from FilterChipView's fill.
static void glassReleaseClearChip(UIView *clear) {
    if (!clear.window || !inReleasesFilters(clear) || clear.bounds.size.width < 1) return;
    UIView *fill = clear.subviews.firstObject;
    if (!fill) return;
    SGRGlassChip(clear, fill, NO, &kReleasesClearGlass);
    fill.backgroundColor = UIColor.clearColor;
    fill.layer.backgroundColor = NULL;
    SGRHoldClear(fill);
}

static void clearReleaseNavigation(UIViewController *page) {
    UINavigationController *navigation = page.navigationController;
    if (!navigation) return;
    // Unlike the title capsule and Back, Spotify's full-width 91pt
    // _UIBarBackground and the separate controller blur must be invisible.
    UIView *blur = SGRBarBlurOf(navigation);
    if (blur) {
        blur.alpha = 0;
        blur.userInteractionEnabled = NO;
        if (!blur.layer.mask) blur.layer.mask = [CALayer layer];
    }
    UIView *backing = SGRChildNamed(navigation.navigationBar, @"_UIBarBackground");
    if (backing) { backing.alpha = 0; backing.userInteractionEnabled = NO; }
}

// Clearing the navigation blur alone left a black 139pt empty band: Spotify's
// collection was *below* both the 91pt navigation and the 48pt chips row.
// Move its viewport behind the floating controls but compensate its content
// offset AND inset, so the first release retains exactly its former position.
// As the user scrolls, artwork/rows can now actually move under the glass.
static void letReleasesScrollUnderHeader(UIView *root) {
    static char kCollectionKey;
    UIView *candidate = SGRFindByIdentifier(root, @"Releases.Page.CollectionView", &kCollectionKey);
    if (![candidate isKindOfClass:UICollectionView.class]) return;
    UICollectionView *list = (UICollectionView *)candidate;
    CGFloat top = CGRectGetMinY(list.frame);
    NSNumber *saved = objc_getAssociatedObject(list, &kReleasesScrollKey);
    if (!saved && (top < 100 || top > 200)) return;
    if (!saved) {
        objc_setAssociatedObject(list, &kReleasesScrollKey, @(top), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGFloat beforeOffset = list.contentOffset.y;
        UIEdgeInsets inset = list.contentInset;
        inset.top += top;
        [UIView performWithoutAnimation:^{
            list.contentInset = inset;
            list.contentOffset = CGPointMake(list.contentOffset.x, beforeOffset - top);
        }];
        objc_setAssociatedObject(list, &kReleasesScrollOffsetKey, @(inset.top), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat height = saved ? saved.doubleValue : top;
    if (list.frame.origin.y > 0.5) {
        CGRect frame = list.frame;
        frame.origin.y = 0;
        frame.size.height += height;
        list.frame = frame;
    }
}

static void dressReleases(UIViewController *page) {
    UIView *root = page.viewIfLoaded;
    if (!root) return;
    // The navigation page bar's existing implementation pins Back and the
    // title on glass, and suppresses its system opaque/blurred strip.
    SGRDressBarPage(page);
    clearReleaseNavigation(page);
    letReleasesScrollUnderHeader(root);
    UIView *filters = SGRFindByIdentifier(root, @"Components.UI.FilterChips", &kReleasesFilters);
    if (!filters) return;
    // The black backing belongs to the parent Swift FiltersElement, not to
    // the chip collection itself. Remove that backing without altering rows.
    UIView *stripe = filters.superview;
    if (stripe && [NSStringFromClass(stripe.class) containsString:@"FiltersElement"]) {
        stripe.backgroundColor = UIColor.clearColor;
        stripe.layer.backgroundColor = NULL;
        SGRHoldClear(stripe);
    }
    filters.backgroundColor = UIColor.clearColor;
    filters.layer.backgroundColor = NULL;
    SGForEachView(filters, ^(UIView *v) {
        if ([NSStringFromClass(v.class) isEqualToString:@"EncoreConsumerMobile_BaseKit.FilterChipView"])
            glassReleaseChip(v);
        else if ([NSStringFromClass(v.class) containsString:@"ClearChipView"])
            glassReleaseClearChip(v);
    });
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"Creator_ReleasesPageImpl", @"ReleasesViewController");
    if (page) SGRDressBarPagesWith(page, YES, ^(UIViewController *c) { dressReleases(c); });
    Class chip = SGRSwiftClass(@"EncoreConsumerMobile_BaseKit", @"FilterChipView");
    if (chip) SGRPassView(chip, ^(UIView *view) { glassReleaseChip(view); });
    // Swift's private hash in ClearChipView changes with releases; find the
    // exact class by name from the current view tree at runtime.
    Class clear = NSClassFromString(@"_TtC28EncoreConsumerMobile_BaseKitP33_0DE25E4485417E35B7827869974977D613ClearChipView");
    if (clear) SGRPassView(clear, ^(UIView *view) { glassReleaseClearChip(view); });
}
