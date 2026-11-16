// Enhanced share-card editor: the 48pt navigation control at top left is an
// Encore tertiary button, independent from the app's UINavigationBar.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kEditorBack;

static void glassBack(UIViewController *controller) {
    UIView *root = controller.viewIfLoaded;
    if (!root.window) return;
    SGForEachView(root, ^(UIView *view) {
        if (![view.accessibilityIdentifier isEqualToString:@"Encore.Button.Tertiary"] ||
            fabs(view.bounds.size.width - 48) > 1 || fabs(view.bounds.size.height - 48) > 1) return;
        CGPoint origin = [view convertPoint:CGPointZero toView:root];
        if (origin.x > 50 || origin.y > 150) return;
        SGRUnclipUpTo(view, ^BOOL(UIView *v) { return v == root; });
        SGRGlassInside(view, &kEditorBack, 48);
    });
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    SGRPassSwiftController(@"Stickers_EnhancedShareCardPageImpl", @"EnhancedShareCardViewController", ^(UIViewController *c) { glassBack(c); });
}
