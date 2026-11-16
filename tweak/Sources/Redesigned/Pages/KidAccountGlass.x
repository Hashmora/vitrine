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
