// Invite Friends in the listening-activity drawer uses an Element_List cell
// wrapping an unnamed 56pt avatar plate and a separate plus icon. Scope the
// common cell pass to the specific InviteCarouselItemElement before touching it.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kInviteGlass, kInvitePlus;

static void dressInvite(UIView *host) {
    if (!host.window) return;
    // The cell and the generic ElementView have different immediate children.
    // Search only their small subtree for the named 72pt Invite Friends item.
    __block UIView *button = nil;
    SGForEachView(host, ^(UIView *v) {
        if (!button && [v.accessibilityLabel isEqualToString:@"Invite Friends"] &&
            [v isMemberOfClass:UIView.class] && v.bounds.size.width >= 70 &&
            v.bounds.size.width <= 74 && v.bounds.size.height >= 75 &&
            v.bounds.size.height <= 83) button = v;
    });
    UIView *disc = nil;
    for (UIView *v in button.subviews) {
        if ([v isMemberOfClass:UIView.class] && v.bounds.size.width >= 54 &&
            v.bounds.size.width <= 58 && fabs(v.bounds.size.width - v.bounds.size.height) < 1) {
            disc = v;
            break;
        }
    }
    if (!disc) return;
    // The ordinary activity/friend avatars sit four points below the top of
    // their cells, and their captions start at y=68. Spotify places Invite
    // Friends at y=0/y=64 instead. Align *both* pieces to the same baseline,
    // using absolute coordinates so repeated layout passes cannot drift.
    if (fabs(disc.frame.origin.y - 4) > 0.5) {
        CGRect frame = disc.frame;
        frame.origin.y = 4;
        disc.frame = frame;
    }
    for (UIView *sub in button.subviews) {
        if (![NSStringFromClass(sub.class) isEqualToString:@"SPTEncoreLabel"] ||
            ![sub.accessibilityLabel isEqualToString:@"Invite Friends"]) continue;
        if (fabs(sub.frame.origin.y - 68) > 0.5) {
            CGRect frame = sub.frame;
            frame.origin.y = 68;
            sub.frame = frame;
        }
    }
    SGRUnclipUpTo(button, ^BOOL(UIView *v) { return [v isKindOfClass:UICollectionView.class]; });
    // The empty avatar's background covers the glass. The plus glyph is a
    // sibling of the avatar, so concealing the empty plate keeps the glyph.
    for (UIView *sub in disc.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"Encore_FaceKit"] &&
            [NSStringFromClass(sub.class) containsString:@"AvatarView"])
            SGRConceal(sub);
    }
    // Spotify's 16pt Encore icon embeds its glyph in a 16pt drawing and
    // repositions it on subsequent layouts. Changing the view's frame does
    // not enlarge or centre the glyph. Hide that icon and draw a centred
    // system symbol above the glass; leave the tap target and label intact.
    for (UIView *sub in disc.subviews) {
        if ([NSStringFromClass(sub.class) isEqualToString:@"SPTEncoreIconView"])
            SGRConceal(sub);
    }
    SGRGlassFlatBox(disc, &kInviteGlass, YES);
    UIImageView *plus = objc_getAssociatedObject(disc, &kInvitePlus);
    if (!plus) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightMedium];
        plus = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"plus" withConfiguration:configuration]
                                              imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        plus.contentMode = UIViewContentModeCenter;
        plus.userInteractionEnabled = NO;
        plus.accessibilityElementsHidden = YES;
        objc_setAssociatedObject(disc, &kInvitePlus, plus, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    plus.tintColor = SGRPrimary();
    CGRect centered = CGRectMake(round((disc.bounds.size.width - 36) / 2),
                                round((disc.bounds.size.height - 36) / 2), 36, 36);
    if (!CGRectEqualToRect(plus.frame, centered)) plus.frame = centered;
    if (plus.superview != disc) [disc addSubview:plus];
    else [disc bringSubviewToFront:plus];
    disc.backgroundColor = UIColor.clearColor;
    disc.layer.backgroundColor = NULL;
    SGRHoldClear(disc);
    SGRUnclipUpTo(disc, ^BOOL(UIView *v) { return [v isKindOfClass:UICollectionView.class]; });
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class cell = SGRSwiftClass(@"Element_List", @"CollectionViewCell");
    if (cell) SGRPassView(cell, ^(UIView *view) { dressInvite(view); });
    // The Invite carousel item can become visible when the horizontal list
    // scrolls, without causing the outer collection cell another layout pass.
    Class item = NSClassFromString(@"_TtGC13Element_UIKit11ElementViewVV29ListeningActivity_ElementsKit25InviteCarouselItemElement5PropsVS2_5StateOS2_5Event_");
    if (item) SGRPassView(item, ^(UIView *view) { dressInvite(view); });
}
