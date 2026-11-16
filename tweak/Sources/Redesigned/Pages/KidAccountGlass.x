// The introduction to managed accounts has only a trailing close button. This
// first step must not get a synthetic Back button or a title capsule.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kCloseGlass;

static void closeGlass(UIViewController *page) {
    UIView *content = SGRChildNamed(page.navigationController.navigationBar, @"_UINavigationBarContentView");
    UIView *stack = SGRBarStackButton(content, NO);
    UIView *button = SGRChildNamed(stack, @"_UIModernBarButton");
    if (!button || button.bounds.size.width < 1) return;
    SGRUnclipUpTo(button, ^BOOL(UIView *v) { return v.superview == page.navigationController.navigationBar; });
    SGRGlassInside(button, &kCloseGlass, 44);
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"GenAlphaAccountCreation_KidAccountCreationEducationPageImpl", @"KidAccountCreationEducationViewController");
    if (!page) return;
    SGRPassController(page, ^(UIViewController *controller) {
        closeGlass(controller);
        __weak UIViewController *weakController = controller;
        UIView *content = SGRChildNamed(controller.navigationController.navigationBar, @"_UINavigationBarContentView");
        SGRWatchLayout(content, ^(UIView *v) { closeGlass(weakController); });
    });
}

// Later wizard steps have Back, Close and an “N of 6” title. Use the normal
// glass navigation capsule but keep Close as an xmark, not an ellipsis.
static char kWizardClose;
static void wizardChrome(UIViewController *page) {
    if (!page.viewIfLoaded.window) return;
    SGRDressBarPageBackOnly(page);
    UIView *content = SGRChildNamed(page.navigationController.navigationBar, @"_UINavigationBarContentView");
    UIView *trailing = SGRBarStackButton(content, NO);
    UIView *button = SGRChildNamed(trailing, @"_UIModernBarButton");
    if (button.bounds.size.width > 1) {
        SGRUnclipUpTo(button, ^BOOL(UIView *v) { return v.superview == page.navigationController.navigationBar; });
        SGRGlassInside(button, &kWizardClose, 44);
    }
    // Spotify supplies a separate 91pt black opaque header to every wizard
    // subpage. Only that strip goes; the page's normal black canvas stays.
    CGFloat width = page.viewIfLoaded.bounds.size.width;
    SGForEachView(page.viewIfLoaded, ^(UIView *v) {
        if (fabs(v.bounds.size.width - width) > 1 || fabs(v.bounds.size.height - 91) > 1) return;
        if (fabs(v.frame.origin.y) > 1 || !v.clipsToBounds) return;
        if (v.backgroundColor && SGIsBaseSurface(v.layer.backgroundColor)) SGRHoldClear(v);
    });
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"GenAlphaAccountCreation_KidAccountCreationAgeVerificationPageImpl", @"KidAccountCreationAgeVerificationViewController");
    if (!page) return;
    SGRDressBarPagesWith(page, YES, ^(UIViewController *c) { wizardChrome(c); });
}
