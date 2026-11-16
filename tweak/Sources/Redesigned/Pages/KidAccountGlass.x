// The introduction to managed accounts has only a trailing close button. This
// first step must not get a synthetic Back button or a title capsule.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kClosePinned;

static void closeGlass(UIViewController *page) {
    if (!page.viewIfLoaded.window) return;
    UIView *content = SGRChildNamed(page.navigationController.navigationBar, @"_UINavigationBarContentView");
    UIView *stack = SGRBarStackButton(content, NO);
    // In this particular wizard introduction UIKit compresses the Close
    // _UIModernBarButton to 0pt at x=391. Its 44pt inset glass then ends up
    // half outside the screen. Mirror the real bar control at x=330 instead.
    UIView *source = SGRChildNamed(stack, @"_UIButtonBarButton");
    if (!source) return;
    // Pin inside the navigation content itself (44pt high), rather than the
    // page below the interactive navigation bar, which would eat its taps.
    SGRMirrorButton *close = objc_getAssociatedObject(content, &kClosePinned);
    if (!close) {
        close = [[SGRMirrorButton alloc] initWithFrame:CGRectZero];
        close.ownGlyph = YES;
        close.fallbackGlyph = [UIImage systemImageNamed:@"xmark"];
        close.glyphColor = SGRPrimary();
        objc_setAssociatedObject(content, &kClosePinned, close, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGRect frame = CGRectMake(content.bounds.size.width - 16 - 44, 0, 44, 44);
    if (!CGRectEqualToRect(close.frame, frame)) close.frame = frame;
    if (close.superview != content) [content addSubview:close];
    else [content bringSubviewToFront:close];
    content.clipsToBounds = NO;
    [close feedFrom:source];
    if (source.alpha != 0) source.alpha = 0;
    source.userInteractionEnabled = NO;
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
    SGRPassControllerGoing(page, ^(UIViewController *controller) {
        UIView *content = SGRChildNamed(controller.navigationController.navigationBar, @"_UINavigationBarContentView");
        UIView *stack = SGRBarStackButton(content, NO);
        UIView *source = SGRChildNamed(stack, @"_UIButtonBarButton");
        source.alpha = 1;
        source.userInteractionEnabled = YES;
        [(UIView *)objc_getAssociatedObject(content, &kClosePinned) removeFromSuperview];
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
        if (v.backgroundColor && SGIsBaseSurface(v.layer.backgroundColor)) {
            // HoldClear protects later repaints; it does not clear the color
            // already in the layer at the time the page first opens.
            v.backgroundColor = UIColor.clearColor;
            v.layer.backgroundColor = NULL;
            SGRHoldClear(v);
        }
    });
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"GenAlphaAccountCreation_KidAccountCreationAgeVerificationPageImpl", @"KidAccountCreationAgeVerificationViewController");
    if (!page) return;
    SGRDressBarPagesWith(page, YES, ^(UIViewController *c) { wizardChrome(c); });
}
