// Sharing through Messages uses its own modal SPNavigationController, not a
// NavigationUI sheet. Reuse the queue's material on that sheet, then dress
// the searchable field and actions without changing their event targets.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kShareSearch, kShareRow, kShareInvite, kGroupName, kCancel;
static char kMoreAction, kCopyAction, kSearchAction;
static char kShareInnerPrepared, kShareOuterPrepared;

// These actions are not all in the same Encore hierarchy: some are icon
// buttons, and others are tappable ListRow backings. Select the actual hit
// control, not the text label, so the material and press animation follow it.
static UIView *actionWithText(UIView *label, UIView *root) {
    UIView *fallback = nil;
    for (UIView *v = label; v && v != root; v = v.superview) {
        if (v.bounds.size.width < 28 || v.bounds.size.height < 26 ||
            v.bounds.size.height > 78 || v.bounds.size.width > root.bounds.size.width) continue;
        NSString *type = NSStringFromClass(v.class);
        BOOL hit = [v isKindOfClass:UIControl.class] ||
            [type containsString:@"Interactable"] || [type containsString:@"BackingButton"] ||
            [type containsString:@"Button"] || [type containsString:@"ListRow"] ||
            [v.accessibilityIdentifier hasSuffix:@".Row"];
        if (hit) return v;
        if (!fallback && (v.gestureRecognizers.count > 0 ||
                          (v.isAccessibilityElement && (v.accessibilityTraits & UIAccessibilityTraitButton))))
            fallback = v;
    }
    return fallback;
}

static void glassNamedActions(UIView *root) {
    if (!root) return;
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    SGForEachView(root, ^(UIView *view) {
        NSString *name = nil;
        if ([view isKindOfClass:UILabel.class]) name = ((UILabel *)view).text;
        if (!name.length) name = view.accessibilityLabel;
        if (!name.length) return;
        NSString *lower = [name.lowercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        const void *key = NULL;
        if ([lower containsString:@"copy link"] || [lower isEqualToString:@"copy invite link"])
            key = &kCopyAction;
        else if ([lower isEqualToString:@"more"] || [lower hasPrefix:@"more options"])
            key = &kMoreAction;
        else if ([lower isEqualToString:@"search"] || [lower hasPrefix:@"search people"] ||
                 [lower hasPrefix:@"search for people"])
            key = &kSearchAction;
        if (!key) return;
        UIView *button = actionWithText(view, root);
        if (!button) return;
        NSValue *identity = [NSValue valueWithNonretainedObject:button];
        if ([seen containsObject:identity]) return;
        [seen addObject:identity];
        UIView *glass = SGRGlassFlatBox(button, key, NO);
        if (!glass) return;
        // Do not leave Encore's 100% opaque backing over the new glass.
        if (button.layer.backgroundColor && CGColorGetAlpha(button.layer.backgroundColor) > 0.15)
            button.layer.backgroundColor = NULL;
        if (button.backgroundColor && CGColorGetAlpha(button.backgroundColor.CGColor) > 0.15)
            button.backgroundColor = UIColor.clearColor;
        SGRUnclipUpTo(button, ^BOOL(UIView *ancestor) {
            return [ancestor isKindOfClass:UICollectionView.class] || ancestor == root;
        });
    });
}

// New message has a 48pt icon and a separate 402pt hit-test row for
// Create group and the signed-in user. The row is not meant to be glass:
// earlier named-action matching glassed the full 402pt button (and sometimes
// its outer ElementContentView). Keep only the icon/FaceStackView glass.
// Clean old backing views on reused cells without touching the native button,
// other list rows, or their actions.
static void removeWideGlassFromShareRow(UIView *row) {
    if (!row || row.bounds.size.width < 280) return;
    UIView *owner = row;
    for (NSUInteger depth = 0; owner && depth < 3; ++depth, owner = owner.superview) {
        NSArray<UIView *> *children = [owner.subviews copy];
        for (UIView *child in children) {
            NSString *type = NSStringFromClass(child.class);
            if (![type hasSuffix:@"LegacyGlassView"] &&
                ![type hasSuffix:@"SGGlassView"] &&
                ![type isEqualToString:@"SGLegacyGlassView"]) continue;
            if (child.bounds.size.width < 280 ||
                fabs(child.bounds.size.width - row.bounds.size.width) > 3) continue;
            [child removeFromSuperview];
        }
        if ([owner isKindOfClass:UICollectionViewCell.class]) break;
    }
}

static void glassAction(UIView *row, const void *key) {
    if (!row) return;
    __block UIView *box = nil;
    SGForEachView(row, ^(UIView *v) {
        if (![v isMemberOfClass:UIView.class] || fabs(v.bounds.size.width - 48) > 2 ||
            fabs(v.bounds.size.height - 48) > 2) return;
        __block BOOL icon = NO;
        SGForEachView(v, ^(UIView *child) {
            if ([NSStringFromClass(child.class) containsString:@"SPTEncoreIconView"] ||
                [child isKindOfClass:UIImageView.class]) icon = YES;
        });
        if (icon) box = v; // closest 48pt plate to the real glyph
    });
    // Do not dress the full-width InviteLink.Row as a 390pt glass capsule.
    // Its only intended lens is the 48pt icon; a row laid out before the
    // icon exists must simply be handled by a later pass.
    if (!box) return;
    SGRGlassFlatBox(box, key, NO);
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
    UIView *outer = SGRSheetPaneOf(root);
    if (outer && pane && pane != outer) {
        // The sheet owns one glass pane. In Round 7 the inner navigation
        // container's glass was torn down on EVERY viewDidLayoutSubviews,
        // restoring its solid fill in between frames: light/dark flashing.
        // Strip it once, and keep that same container permanently clear.
        if (!objc_getAssociatedObject(pane, &kShareInnerPrepared)) {
            SGRRemoveSheetGlass(pane);
            objc_setAssociatedObject(pane, &kShareInnerPrepared, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        pane.backgroundColor = UIColor.clearColor;
        pane.layer.backgroundColor = NULL;
        SGRHoldClear(pane);
        if (!objc_getAssociatedObject(outer, &kShareOuterPrepared)) {
            UIView *glass = SGRGlassSheetChrome(outer);
            if (glass) SGRDimSheetGlass(glass, 0.52);
            objc_setAssociatedObject(outer, &kShareOuterPrepared, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    // Never create a temporary glass pane on the navigation wrapper before
    // the actual NavigationUI sheet has been attached. The old fallback made
    // the first appearance alternate between the two material surfaces.
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
    glassNamedActions(root);
    // Only the icon discs are glass here; avoid 402pt selected-looking rows.
    UIView *create = SGRFindByIdentifier(root, @"CreateGroup.Row", &kShareRow);
    removeWideGlassFromShareRow(create);
    SGForEachView(root, ^(UIView *v) {
        if ([v.accessibilityIdentifier isEqualToString:@"User.Row.Chat"] &&
            [v.accessibilityLabel containsString:@"(you)"])
            removeWideGlassFromShareRow(v);
    });
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
    else if ([identifier containsString:@"ChatShare"] ||
             [identifier containsString:@"CopyLink"] || [identifier containsString:@"InviteLink"])
        glassNamedActions(view);
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class row = SGRSwiftClass(@"LegacyUI_ECMCoreKit", @"InteractableLayoutBackingButton");
    if (row) SGRPassView(row, ^(UIView *view) { dressEarlyShareAction(view); });
    SGRPassSwiftController(@"Campfire_SharePageImpl", @"ChatSharePageViewController", ^(UIViewController *c) { shareGlass(c); });
}
