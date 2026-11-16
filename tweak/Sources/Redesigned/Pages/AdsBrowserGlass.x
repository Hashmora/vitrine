// The advertising web browser uses a separate SPNavigationController from the
// Settings web browser. Its Close/More and footer buttons are _UITAMICAdaptorView
// controls, not _UIButtonBarButton. Dress the actual buttons and keep the footer
// actions on one pane; never replace their targets or interfere with WKWebView.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kTopKey, kTopDimKey, kTitleKey, kBottomKey, kBottomDimKey, kFooterKey;

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
            UIView *button = SGRChildNamed(adaptor, @"UIButton");
            if (!button || button.bounds.size.width < 1) continue;
            SGRUnclipUpTo(button, ^BOOL(UIView *v) { return v.superview == bar; });
            UIView *lens = SGRGlassInside(button, &kTopKey, 44);
            // The web page behind these buttons is often white. Keep the white
            // glyphs readable rather than making the buttons transparent.
            SGRDarkenGlass(lens, &kTopDimKey, 22, 0.65);
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
        // The four buttons are 60pt apart. GlassGroupPill only collects
        // neighbours within 16pt, so it previously dressed Refresh alone.
        UIView *lens = SGRGlassCapsuleInside(actions, &kBottomKey,
                            CGSizeMake(actions.bounds.size.width, 54), NO);
        SGRDarkenGlass(lens, &kBottomDimKey, 27, 0.45);
    }
    // The advertising browser presents above the app's tabs. Its original
    // opaque toolbar hid them; after clearing it the tabs shone through the
    // footer. Cover only this browser's footer, behind the floating capsule.
    if (toolbar.superview == nav.view) {
        UIView *footer = objc_getAssociatedObject(nav.view, &kFooterKey);
        if (!footer) {
            footer = [UIView new];
            footer.userInteractionEnabled = NO;
            footer.backgroundColor = UIColor.blackColor;
            objc_setAssociatedObject(nav.view, &kFooterKey, footer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CGRect at = [nav.view convertRect:toolbar.bounds fromView:toolbar];
        CGRect frame = CGRectMake(0, CGRectGetMinY(at), nav.view.bounds.size.width,
                                  MAX(0, nav.view.bounds.size.height - CGRectGetMinY(at)));
        if (!CGRectEqualToRect(footer.frame, frame)) footer.frame = frame;
        if (footer.superview != nav.view) [nav.view insertSubview:footer belowSubview:toolbar];
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
