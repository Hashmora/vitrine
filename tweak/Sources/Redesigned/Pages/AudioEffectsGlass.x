// The mod's Audio effects page is SGDSPPage (not Spotify's SPTEqualizerViewController).
// Its own UITableView should stay untouched; only the page navigation is
// redressed below iOS 26 to match the other floating-glass settings pages.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static void dressDSP(UIViewController *page) {
    if (!page.viewIfLoaded.window) return;
    SGRDressBarPageBackOnly(page);
    UINavigationController *nav = page.navigationController;
    UIView *blur = SGRBarBlurOf(nav);
    if (blur) {
        if (!blur.layer.mask) blur.layer.mask = [CALayer layer];
        blur.userInteractionEnabled = NO;
    }
    UIView *background = SGRChildNamed(nav.navigationBar, @"_UIBarBackground");
    if (background && background.alpha != 0) background.alpha = 0;
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = NSClassFromString(@"SGDSPPage");
    if (page) SGRDressBarPagesWith(page, NO, ^(UIViewController *c) { dressDSP(c); });
}
