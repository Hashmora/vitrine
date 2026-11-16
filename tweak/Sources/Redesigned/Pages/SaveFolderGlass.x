// "New folder" in Save in: its row's plus is a 48pt grey square, unlike
// PlaylistAddSongs.x's grey Add songs square. Make it the same round glass.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kNewRow, kPlusGlass, kHeader;

static void dressFolder(UIViewController *controller) {
    UIView *root = controller.viewIfLoaded;
    if (!root.window) return;
    UIView *row = SGRFindByIdentifier(root, @"NewPlaylist.Row.AddToPlaylist", &kNewRow);
    if (!row) return;
    __block UIView *box = nil;
    SGForEachView(row, ^(UIView *v) {
        if (box || ![v isMemberOfClass:UIView.class] || v.bounds.size.width != 48 || v.bounds.size.height != 48) return;
        if (SGRChildNamed(v, @"SPTEncoreIconView")) box = v;
    });
    if (box) {
        SGRGlassFlatBox(box, &kPlusGlass, NO);
        SGRUnclipUpTo(box, ^BOOL(UIView *v) {
            return [NSStringFromClass(v.class) containsString:@"ListRow"];
        });
    }
    // The heading sits directly under the navigation sheet's grabber; leave
    // ten more points above it without moving the table's scrollable rows.
    UIView *heading = SGRFindByIdentifier(root, @"Components.UI.SavedInHeaderAddToPlaylist", &kHeader);
    __block BOOL newFolder = NO;
    SGForEachView(heading, ^(UIView *v) {
        if ([v isKindOfClass:UILabel.class] && [((UILabel *)v).text isEqualToString:@"New folder"] && !v.hidden) newFolder = YES;
    });
    if (newFolder && heading && heading.transform.ty != 10) heading.transform = CGAffineTransformMakeTranslation(0, 10);
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"PlaylistCuration_AddToPlaylistImpl", @"ATPContainerViewController");
    if (page) SGRPassController(page, ^(UIViewController *c) { dressFolder(c); });
}
