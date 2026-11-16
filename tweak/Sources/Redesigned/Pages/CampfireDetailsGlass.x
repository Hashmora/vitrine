// The Chat details navigation header is managed by PageBar, but its trailing
// action is Settings (not an ellipsis). Mirror that real action with a gear.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kSettings, kEdit, kAddMember;

static void glassDetails(UIViewController *page) {
    UIView *root = page.viewIfLoaded;
    if (!root.window) return;
    SGRDressBarPageBackOnly(page);
    UIView *content = SGRChildNamed(page.navigationController.navigationBar, @"_UINavigationBarContentView");
    UIView *settings = SGRBarStackButton(content, NO);
    if (settings && settings.bounds.size.width > 1)
        SGRPinnedTrailing(root, &kSettings, settings, 0, [UIImage systemImageNamed:@"gearshape"]);

    SGForEachView(root, ^(UIView *v) {
        if ([v.accessibilityLabel isEqualToString:@"Edit"] &&
            [v.accessibilityIdentifier isEqualToString:@"Encore.Button.Secondary"])
            SGRGlassEncoreButton(v, &kEdit, NO);
        if (![v.accessibilityLabel isEqualToString:@"Manage people"]) return;
        UIView *plus = SGRChildNamed(v, @"FacepileIconView");
        if (plus && plus.bounds.size.width > 1) {
            SGRGlassInside(plus, &kAddMember, plus.bounds.size.width);
            SGRUnclipUpTo(plus, ^BOOL(UIView *ancestor) { return [ancestor isKindOfClass:UICollectionView.class]; });
        }
    });
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    SGRPassSwiftController(@"Campfire_ChatDetailsPageImpl", @"ChatDetailsViewController", ^(UIViewController *c) { glassDetails(c); });
}
