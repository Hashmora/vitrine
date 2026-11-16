// The advertising web browser uses a separate SPNavigationController from the
// Settings web browser. Its Close/More and footer buttons are _UITAMICAdaptorView
// controls, not _UIButtonBarButton. Dress the actual buttons and keep the footer
// actions on one pane; never replace their targets or interfere with WKWebView.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kTopKey, kTitleKey, kBottomKey;

static void dressBrowser(UIViewController *controller) {
    if (!controller.viewIfLoaded.window) return;
    UINavigationController *nav = controller.navigationController;
    if (!nav) return;
    UINavigationBar *bar = nav.navigationBar;
    UIView *content = SGRChildNamed(bar, @"_UINavigationBarContentView");
    UIView *backing = SGRChildNamed(bar, @"_UIBarBackground");
    if (backing) backing.alpha = 0;
    UIView *blur = SGRBarBlurOf(nav);
    if (blur) blur.alpha = 0;
    bar.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    for (UIView *stack in content.subviews) {
        if (![NSStringFromClass(stack.class) isEqualToString:@"_UIButtonBarStackView"]) continue;
        for (UIView *adaptor in stack.subviews) {
            if (![NSStringFromClass(adaptor.class) isEqualToString:@"_UITAMICAdaptorView"]) continue;
            UIButton *button = SGRChildNamed(adaptor, @"UIButton");
            if (!button || button.bounds.size.width < 1) continue;
            SGRUnclipUpTo(button, ^BOOL(UIView *v) { return v.superview == bar; });
            SGRGlassInside(button, &kTopKey, 44);
        }
    }
    UIView *title = SGRChildNamed(content, @"_UINavigationBarTitleControl");
    if (title && title.bounds.size.width > 1) {
        SGRUnclipUpTo(title, ^BOOL(UIView *v) { return v.superview == bar; });
        SGRGlassCapsuleInside(title, &kTitleKey, CGSizeMake(title.bounds.size.width, 44), NO);
    }

    UIView *toolbar = SGRChildNamed(nav.view, @"UIToolbar");
    UIView *toolbarBacking = SGRChildNamed(toolbar, @"_UIBarBackground");
    if (toolbarBacking) toolbarBacking.alpha = 0;
    UIView *toolbarContent = SGRChildNamed(toolbar, @"_UIToolbarContentView");
    UIView *actions = SGRChildNamed(toolbarContent, @"_UIButtonBarStackView");
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (UIView *sub in actions.subviews) {
        if (![NSStringFromClass(sub.class) isEqualToString:@"_UITAMICAdaptorView"] || sub.bounds.size.width < 1) continue;
        [buttons addObject:sub];
    }
    if (buttons.count == 4) {
        SGRUnclipUpTo(actions, ^BOOL(UIView *v) { return v == toolbar; });
        SGRGlassGroupPill(actions, buttons, &kBottomKey, 56, 2);
    }
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"AdsPlatform_AdsInAppBrowserImpl", @"AdsInAppBrowserViewController");
    if (!page) return;
    SGRPassController(page, ^(UIViewController *c) {
        dressBrowser(c);
        __weak UIViewController *weakPage = c;
        UINavigationController *nav = c.navigationController;
        UIView *top = SGRChildNamed(nav.navigationBar, @"_UINavigationBarContentView");
        UIView *bottom = SGRChildNamed(SGRChildNamed(nav.view, @"UIToolbar"), @"_UIToolbarContentView");
        for (UIView *v in @[top ?: (id)NSNull.null, bottom ?: (id)NSNull.null]) {
            if (![v isKindOfClass:UIView.class]) continue;
            SGRWatchLayout(v, ^(UIView *laidOut) { if (weakPage.viewIfLoaded.window) dressBrowser(weakPage); });
        }
    });
}
