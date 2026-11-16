// Sharing through Messages uses its own modal SPNavigationController, not a
// NavigationUI sheet. Reuse the queue's material on that sheet, then dress
// the searchable field and actions without changing their event targets.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kShareSearch, kShareRow, kShareInvite, kGroupName, kCancel;

static void glassAction(UIView *row, const void *key) {
    if (!row) return;
    __block UIView *box = nil;
    SGForEachView(row, ^(UIView *v) {
        if (box || ![v isMemberOfClass:UIView.class] ||
            fabs(v.bounds.size.width - 48) > 1 || fabs(v.bounds.size.height - 48) > 1) return;
        if (SGRChildNamed(v, @"SPTEncoreIconView")) box = v;
    });
    if (!box) return;
    // Prepare the actual 48pt icon plate before the list cell first appears.
    // Its #2A2A2A paint otherwise flashes on the first presentation frame.
    SGRGlassFlatBox(box, key, YES);
    box.backgroundColor = UIColor.clearColor;
    box.layer.backgroundColor = NULL;
    SGRHoldClear(box);
    SGRUnclipUpTo(box, ^BOOL(UIView *v) { return [v isKindOfClass:UICollectionView.class]; });
}

static void shareGlass(UIViewController *c) {
    UIView *root = c.viewIfLoaded;
    if (!root) return;
    // The modal's view is available in viewWillAppear:, before the first
    // visible frame. Dress it then; requiring window caused a grey flash.
    UIView *pane = c.navigationController.presentationController.presentedView;
    if (!pane) pane = c.navigationController.view.superview;
    if (pane && pane.bounds.size.width >= 300 && pane.bounds.size.height < UIScreen.mainScreen.bounds.size.height) {
        UIView *sheetGlass = SGRGlassSheetView(pane);
        // Undimmed panels over the conversation are washed out on light art.
        // Keep the same queue sheet but give it a readable dark material.
        if (sheetGlass) SGRDimSheetGlass(sheetGlass, 0.52);
    }
    // This modal owns an SPNavigationBar and a separate blurred backing strip;
    // hiding _UIBarBackground alone leaves that strip visible.
    UIView *blur = SGRBarBlurOf(c.navigationController);
    UINavigationBar *bar = c.navigationController.navigationBar;
    // In these shallow sheets the navigation row hugs the very top curve.
    // Move the WHOLE row (Cancel and centred heading together) below that
    // curve; never extend Cancel's glass beyond the sheet's upper corner.
    CGAffineTransform lower = CGAffineTransformMakeTranslation(0, 12);
    if (bar && !CGAffineTransformEqualToTransform(bar.transform, lower))
        bar.transform = lower;
    // In the modal's SPNavigationController the blur sometimes lives beside
    // the bar, deeper than the ordinary page-bar lookup searches.
    for (UIView *sibling in bar.superview.subviews) {
        if (![sibling isMemberOfClass:UIView.class] ||
            sibling.bounds.size.height < 44 || sibling.bounds.size.height > 100 ||
            fabs(sibling.bounds.size.width - bar.bounds.size.width) > 2) continue;
        for (UIView *inner in sibling.subviews) {
            if ([inner isKindOfClass:UIVisualEffectView.class]) {
                blur = sibling;
                break;
            }
        }
        if (blur == sibling) break;
    }
    if (blur) {
        if (!blur.layer.mask) blur.layer.mask = [CALayer layer];
        if (blur.alpha != 0) blur.alpha = 0;
        blur.userInteractionEnabled = NO;
    }
    UIView *opaqueBar = SGRChildNamed(bar, @"_UIBarBackground");
    if (opaqueBar && opaqueBar.alpha != 0) opaqueBar.alpha = 0;
    UIView *field = SGRFindByIdentifier(root, @"Components.ChatShareHeader.Private.SearchField", &kShareSearch);
    if (field && field.bounds.size.height > 1) {
        SGRGlassFillBox(field, &kShareSearch, YES);
        field.backgroundColor = UIColor.clearColor;
        field.layer.backgroundColor = NULL;
        SGRHoldClear(field);
        SGRUnclipUpTo(field, ^BOOL(UIView *v) { return v == root; });
    }
    // The second step inserts a Group name Encore field between Search and the
    // contacts list. Its rectangular grey backdrop becomes a search-like pill.
    UIView *groupName = SGRFindByIdentifier(root, @"Components.UI.ChatGroupInputSharePage", &kGroupName);
    if (groupName && groupName.bounds.size.height > 1) {
        SGRGlassFillBox(groupName, &kGroupName, YES);
        groupName.backgroundColor = UIColor.clearColor;
        groupName.layer.backgroundColor = NULL;
        SGRHoldClear(groupName);
        SGRUnclipUpTo(groupName, ^BOOL(UIView *v) { return v == root; });
        // The real EncoreTextField is a private mangled Swift subclass, not
        // named "EncoreTextField" exactly. Clear its inset background too.
        SGForEachView(groupName, ^(UIView *sub) {
            if ([NSStringFromClass(sub.class) hasSuffix:@"EncoreTextField"]) {
                sub.backgroundColor = UIColor.clearColor;
                sub.layer.backgroundColor = NULL;
                SGRHoldClear(sub);
            }
        });
        // Unlike the field, this is a 48pt solid band spanning the whole
        // modal. It otherwise shows as a dark rectangle behind the capsule.
        UIView *band = groupName.superview.superview;
        if ([band isMemberOfClass:UIView.class] &&
            fabs(band.bounds.size.width - root.bounds.size.width) < 2 &&
            band.bounds.size.height >= 40 && band.bounds.size.height <= 56) {
            band.backgroundColor = UIColor.clearColor;
            band.layer.backgroundColor = NULL;
            SGRHoldClear(band);
        }
    }
    glassAction(SGRFindByIdentifier(root, @"CreateGroup.Row", &kShareRow), &kShareRow);
    glassAction(SGRFindByIdentifier(root, @"InviteLink.Row", &kShareInvite), &kShareInvite);
    // In Add people the Cancel navigation action is an Encore tertiary text
    // button, not the standard UIKit back control.
    UIView *content = SGRChildNamed(bar, @"_UINavigationBarContentView");
    UIView *cancel = SGRBarStackButton(content, YES);
    if ([cancel.accessibilityLabel isEqualToString:@"Cancel"] && cancel.bounds.size.height > 1) {
        SGRUnclipUpTo(cancel, ^BOOL(UIView *v) { return v.superview == bar; });
        cancel.backgroundColor = UIColor.clearColor;
        cancel.layer.backgroundColor = NULL;
        SGRHoldClear(cancel);
        UIView *glass = SGRGlassCapsuleInside(cancel, &kCancel,
            CGSizeMake(MAX(64, cancel.bounds.size.width + 16), 44), NO);
        if (glass) SGRGlassSetFilm(glass, YES, 22);
    }
}

// The share actions are reused list cells. Dress their actual backing buttons on
// the first layout, not after the share controller eventually lays out again.
static void dressEarlyShareAction(UIView *view) {
    NSString *identifier = view.accessibilityIdentifier;
    if ([identifier isEqualToString:@"CreateGroup.Row"])
        glassAction(view, &kShareRow);
    else if ([identifier isEqualToString:@"InviteLink.Row"])
        glassAction(view, &kShareInvite);
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class row = SGRSwiftClass(@"LegacyUI_ECMCoreKit", @"InteractableLayoutBackingButton");
    if (row) SGRPassView(row, ^(UIView *view) { dressEarlyShareAction(view); });
    SGRPassSwiftController(@"Campfire_SharePageImpl", @"ChatSharePageViewController", ^(UIViewController *c) { shareGlass(c); });
}
