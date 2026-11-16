// The chat's navigation bar uses a custom _UITAMICAdaptorView for Back, not
// UIKit's normal _UIButtonBarButton. Mirror that existing control rather than
// sending an unconditional pop, so its own navigation handler is retained.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static void dressChatHeader(UIViewController *page) {
    UIView *root = page.viewIfLoaded;
    if (!root.window) return;
    SGRDressBarPageBackOnly(page);

    UIView *content = SGRChildNamed(page.navigationController.navigationBar, @"_UINavigationBarContentView");
    UIView *leading = SGRBarStackButton(content, YES);
    UIView *adapter = [NSStringFromClass(leading.class) isEqualToString:@"_UITAMICAdaptorView"] ? leading : nil;
    UIView *back = SGRChildNamed(adapter, @"UIButton");
    if (back && back.bounds.size.width > 1) {
        SGRPinnedBackOf(root, back);
        // The mirror is above the shared bar; its original adaptor must not
        // paint an opaque system button underneath the new circle.
        SGRConceal(adapter);
    }
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class chat = SGRSwiftClass(@"Campfire_ChatPageImpl", @"ChatPageViewController");
    if (chat) SGRDressBarPagesWith(chat, YES, ^(UIViewController *page) { dressChatHeader(page); });
}
