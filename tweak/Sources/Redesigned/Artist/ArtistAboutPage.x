// Artist About: keep rank, listeners, biography and social links native.
// Only Artist details has a glass card; the navigation controls and title
// use the ordinary floating glass bar. iOS 26+ is untouched.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Pages/Pages.h"

static char kFactsGlass, kNavigationOldStandard, kNavigationOldScroll, kNavigationClear;

static void dressFacts(UIView *root) {
    UIView *facts = SGRFindByIdentifier(root, @"ArtistFactsView.Card", &kFactsGlass);
    if (!facts || facts.bounds.size.width < 1 || facts.bounds.size.height < 1) return;
    static char kFactsPane;
    facts.backgroundColor = UIColor.clearColor;
    facts.layer.backgroundColor = NULL;
    facts.layer.cornerRadius = 28;
    facts.layer.cornerCurve = kCACornerCurveContinuous;
    SGRGlassPaneIn(facts, &kFactsPane, 28);
}

static void clearAboutNavigation(UIViewController *page) {
    UINavigationBar *bar = page.navigationController.navigationBar;
    if (!bar || !page.isViewLoaded) return;
    if (!objc_getAssociatedObject(page, &kNavigationOldStandard)) {
        objc_setAssociatedObject(page, &kNavigationOldStandard, bar.standardAppearance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(page, &kNavigationOldScroll, bar.scrollEdgeAppearance ?: (id)NSNull.null,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UINavigationBarAppearance *clear = objc_getAssociatedObject(page, &kNavigationClear);
    if (!clear) {
        clear = [bar.standardAppearance copy] ?: [UINavigationBarAppearance new];
        [clear configureWithTransparentBackground];
        objc_setAssociatedObject(page, &kNavigationClear, clear, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (bar.standardAppearance != clear) bar.standardAppearance = clear;
    if (bar.scrollEdgeAppearance != clear) bar.scrollEdgeAppearance = clear;
    if (bar.compactAppearance != clear) bar.compactAppearance = clear;
    if (bar.compactScrollEdgeAppearance != clear) bar.compactScrollEdgeAppearance = clear;
    UIView *blur = SGRBarBlurOf(page.navigationController);
    if (blur) {
        if (!blur.layer.mask) blur.layer.mask = [CALayer layer];
        blur.userInteractionEnabled = NO;
    }
    UIView *backing = SGRChildNamed(bar, @"_UIBarBackground");
    if (backing) {
        backing.alpha = 0;
        backing.userInteractionEnabled = NO;
    }
}

static void dressAbout(UIViewController *page) {
    if (!page.viewIfLoaded.window) return;
    SGRDressBarPage(page);
    clearAboutNavigation(page);
    dressFacts(page.viewIfLoaded);
}

%hook SPTArtistAboutViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    // Prepare the transparent bar before the first displayed layout frame.
    clearAboutNavigation((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    dressAbout((UIViewController *)self);
}

- (void)viewWillDisappear:(BOOL)animated {
    UIViewController *page = (UIViewController *)self;
    UINavigationBar *bar = page.navigationController.navigationBar;
    UINavigationBarAppearance *standard = objc_getAssociatedObject(page, &kNavigationOldStandard);
    if (standard && bar) {
        bar.standardAppearance = standard;
        id scroll = objc_getAssociatedObject(page, &kNavigationOldScroll);
        bar.scrollEdgeAppearance = scroll == NSNull.null ? nil : scroll;
        bar.compactAppearance = standard;
        bar.compactScrollEdgeAppearance = standard;
        objc_setAssociatedObject(page, &kNavigationOldStandard, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(page, &kNavigationOldScroll, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(page, &kNavigationClear, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *backing = SGRChildNamed(bar, @"_UIBarBackground");
    if (backing) backing.alpha = 1;
    SGRUndressBarPage(page);
    %orig(animated);
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    %init;
}
