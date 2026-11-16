// The advertising web browser uses a separate SPNavigationController from the
// Settings web browser. Its Close/More and footer buttons are _UITAMICAdaptorView
// controls, not _UIButtonBarButton. Dress the actual buttons and keep the footer
// actions on one pane; never replace their targets or interfere with WKWebView.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kTopKey, kTopDimKey, kTitleKey, kTitleDimKey, kBottomKey, kBottomDimKey;

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
        UIView *lens = SGRGlassCapsuleInside(title, &kTitleKey,
                                              CGSizeMake(title.bounds.size.width, 44), NO);
        SGRDarkenGlass(lens, &kTitleDimKey, 22, 0.55);
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
    // The original browser content ends at 761pt, while its 83pt black
    // safe-area filler was hidden by the opaque toolbar. Let the actual web
    // page extend under our floating control pill, not a solid black bar.
    UIView *root = controller.viewIfLoaded;
    __block UIView *web = nil;
    SGForEachView(root, ^(UIView *candidate) {
        if (!web && [NSStringFromClass(candidate.class) isEqualToString:@"WKWebView"])
            web = candidate;
    });
    if (web && web.superview && root.bounds.size.height > 1) {
        // WKWebView lives one level below a 761pt host, not directly under
        // AdsInAppBrowserViewController's 844pt root. Enlarge both or the
        // original host masks off the page in the new safe-area region.
        UIView *host = web.superview;
        CGRect hostFrame = host.frame;
        hostFrame.size.height = root.bounds.size.height - hostFrame.origin.y;
        if (!CGRectEqualToRect(host.frame, hostFrame)) host.frame = hostFrame;
        CGRect full = web.frame;
        full.size.height = host.bounds.size.height - full.origin.y;
        if (!CGRectEqualToRect(web.frame, full)) web.frame = full;
    }
    for (UIView *v in nav.view.subviews) {
        if (![v isMemberOfClass:UIView.class] || v == root ||
            fabs(v.frame.origin.y - toolbar.frame.origin.y) > 2 ||
            fabs(v.bounds.size.width - nav.view.bounds.size.width) > 2 ||
            v.bounds.size.height < toolbar.bounds.size.height + 25) continue;
        if (SGIsBaseSurface(v.layer.backgroundColor)) {
            v.backgroundColor = UIColor.clearColor;
            v.layer.backgroundColor = NULL;
            SGRHoldClear(v);
        }
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
