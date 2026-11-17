// Releases (Creator_ReleasesPageImpl), redesigned UI on iOS before 26.
// The page has a standard SPNavigationBar and a separate black 48pt filter
// strip. Its chips are EncoreConsumerMobile_BaseKit.FilterChipView, not the
// Encore_ChipsKit chips used by Recents and the other playlists.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kReleasesFilters, kReleasesChipGlass;

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

static void dressReleases(UIViewController *page) {
    UIView *root = page.viewIfLoaded;
    if (!root) return;
    // The navigation page bar's existing implementation pins Back and the
    // title on glass, and suppresses its system opaque/blurred strip.
    SGRDressBarPage(page);
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
    });
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"Creator_ReleasesPageImpl", @"ReleasesViewController");
    if (page) SGRDressBarPagesWith(page, YES, ^(UIViewController *c) { dressReleases(c); });
    Class chip = SGRSwiftClass(@"EncoreConsumerMobile_BaseKit", @"FilterChipView");
    if (chip) SGRPassView(chip, ^(UIView *view) { glassReleaseChip(view); });
}
