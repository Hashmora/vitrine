// The four small editing drawers above the shared card are _UIPageSheet
// presentations, not NavigationUI sheets. Chrome the presented card itself.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static void editSheet(UIViewController *controller) {
    if (!controller.viewIfLoaded.window) return;
    UIView *sheet = controller.presentationController.presentedView;
    if (!sheet || sheet.bounds.size.width < 300) return;
    SGRGlassSheetView(sheet);
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    SGRPassSwiftController(@"Stickers_EnhancedShareCardPageImpl", @"ColorPickerViewController", ^(UIViewController *c) { editSheet(c); });
    SGRPassSwiftController(@"Stickers_EnhancedShareCardPageImpl", @"ImagePickerViewController", ^(UIViewController *c) { editSheet(c); });
}
