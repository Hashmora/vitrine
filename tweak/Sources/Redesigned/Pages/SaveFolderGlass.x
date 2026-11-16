// "New folder" in Save in: its row's plus is a 48pt grey square, unlike
// PlaylistAddSongs.x's grey Add songs square. Make it the same round glass.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kNewRow, kPlusGlass, kHeader, kBack, kBackGlass;

static void dressFolderRoot(UIView *root) {
    if (!root.window) return;
    UIView *row = SGRFindByIdentifier(root, @"NewPlaylist.Row.AddToPlaylist", &kNewRow);
    __block UIView *box = nil;
    if (row) SGForEachView(row, ^(UIView *v) {
        if (box || ![v isMemberOfClass:UIView.class] || v.bounds.size.width != 48 || v.bounds.size.height != 48) return;
        if (SGRChildNamed(v, @"SPTEncoreIconView")) box = v;
    });
    if (box) {
        SGRGlassFlatBox(box, &kPlusGlass, NO);
        SGRUnclipUpTo(box, ^BOOL(UIView *v) {
            return [NSStringFromClass(v.class) containsString:@"ListRow"];
        });
    }
    // The title and Back share a stack. Move both, not the scrollable rows,
    // and style the Back button from its own header view's layout pass.
    UIView *heading = SGRFindByIdentifier(root, @"Components.UI.SavedInHeaderAddToPlaylist", &kHeader);
    __block BOOL newFolder = NO;
    SGForEachView(heading, ^(UIView *v) {
        if ([v isKindOfClass:UILabel.class] && [((UILabel *)v).text isEqualToString:@"New folder"] && !v.hidden) newFolder = YES;
    });
    if (newFolder && heading) {
        if (heading.transform.ty != 24) heading.transform = CGAffineTransformMakeTranslation(0, 24);
        UIView *back = SGRFindByIdentifier(heading, @"SavedInHeaderAddToPlaylist.back", &kBack);
        if (back && back.bounds.size.width > 1) {
            SGRUnclipUpTo(back, ^BOOL(UIView *v) { return v == heading; });
            SGRGlassInside(back, &kBackGlass, 36);
        }
    }
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"PlaylistCuration_AddToPlaylistImpl", @"ATPContainerViewController");
    if (page) SGRPassController(page, ^(UIViewController *c) { dressFolderRoot(c.viewIfLoaded); });
    // ATPMainView is made after the controller's first appearance and does
    // not always cause another controller layout until the user drags it.
    Class main = SGRSwiftClass(@"PlaylistCuration_AddToPlaylistImpl", @"ATPMainView");
    if (main) SGRPassView(main, ^(UIView *v) { dressFolderRoot(v); });
}
