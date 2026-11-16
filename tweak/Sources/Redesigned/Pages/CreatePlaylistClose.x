// The create-playlist sheet has its own 48pt Cancel cross, not a nav bar.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kCancelSource, kCancelGlass;

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"PlaylistCreation_CreatePlaylistImpl", @"CreatePlaylistView");
    if (!page) return;
    SGRPassView(page, ^(UIView *root) {
        if (!root.window) return;
        UIView *button = SGRFindByIdentifier(root, @"cancel-button", &kCancelSource);
        if (button.bounds.size.width < 1) return;
        SGRUnclipUpTo(button, ^BOOL(UIView *v) { return v == root; });
        SGRGlassInside(button, &kCancelGlass, 44);
    });
}
