// Sharing through Messages uses its own modal SPNavigationController, not a
// NavigationUI sheet. Reuse the queue's material on that sheet, then dress
// the searchable field and actions without changing their event targets.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kShareSearch, kShareRow, kShareInvite, kGroupName;

static void glassAction(UIView *row, const void *key) {
    if (!row) return;
    __block UIView *box = nil;
    SGForEachView(row, ^(UIView *v) {
        if (box || ![v isMemberOfClass:UIView.class] ||
            fabs(v.bounds.size.width - 48) > 1 || fabs(v.bounds.size.height - 48) > 1) return;
        if (SGRChildNamed(v, @"SPTEncoreIconView")) box = v;
    });
    if (!box) return;
    SGRGlassFlatBox(box, key, NO);
    SGRUnclipUpTo(box, ^BOOL(UIView *v) { return [v isKindOfClass:UICollectionView.class]; });
}

static void shareGlass(UIViewController *c) {
    UIView *root = c.viewIfLoaded;
    if (!root.window) return;
    UIView *pane = c.navigationController.presentationController.presentedView;
    if (!pane) pane = c.navigationController.view.superview;
    if (pane && pane.bounds.size.width >= 300 && pane.bounds.size.height < UIScreen.mainScreen.bounds.size.height)
        SGRGlassSheetView(pane);
    UIView *field = SGRFindByIdentifier(root, @"Components.ChatShareHeader.Private.SearchField", &kShareSearch);
    if (field && field.bounds.size.height > 1) {
        SGRGlassFlatBox(field, &kShareSearch, NO);
        SGRUnclipUpTo(field, ^BOOL(UIView *v) { return v == root; });
    }
    // The second step inserts a Group name Encore field between Search and the
    // contacts list. Its rectangular grey backdrop becomes a search-like pill.
    UIView *groupName = SGRFindByIdentifier(root, @"Components.UI.ChatGroupInputSharePage", &kGroupName);
    if (groupName && groupName.bounds.size.height > 1) {
        SGRGlassFlatBox(groupName, &kGroupName, NO);
        SGRUnclipUpTo(groupName, ^BOOL(UIView *v) { return v == root; });
        UIView *input = SGRChildNamed(groupName, @"EncoreTextField");
        if (input && input.layer.backgroundColor) input.backgroundColor = UIColor.clearColor;
    }
    glassAction(SGRFindByIdentifier(root, @"CreateGroup.Row", &kShareRow), &kShareRow);
    glassAction(SGRFindByIdentifier(root, @"InviteLink.Row", &kShareInvite), &kShareInvite);
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    SGRPassSwiftController(@"Campfire_SharePageImpl", @"ChatSharePageViewController", ^(UIViewController *c) { shareGlass(c); });
}
