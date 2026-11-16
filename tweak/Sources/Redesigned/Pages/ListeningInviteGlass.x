// Invite Friends in the listening-activity drawer uses an Element_List cell
// wrapping an unnamed 56pt avatar plate and a separate plus icon. Scope the
// common cell pass to the specific InviteCarouselItemElement before touching it.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kInviteGlass;

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
    // The empty avatar's background covers the glass. The plus glyph is a
    // sibling of the avatar, so concealing the empty plate keeps the glyph.
    for (UIView *sub in disc.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"Encore_FaceKit"] &&
            [NSStringFromClass(sub.class) containsString:@"AvatarView"])
            SGRConceal(sub);
    }
    // Spotify's 16pt plus is at {20, 16.67} in the 56pt avatar: its
    // visual centre is three points too high, and too small for the glass.
    // Set it after the carousel item lays out so recycled cells are correct.
    for (UIView *sub in disc.subviews) {
        if (![NSStringFromClass(sub.class) isEqualToString:@"SPTEncoreIconView"]) continue;
        CGRect centered = CGRectMake(16, 16, 24, 24);
        if (!CGRectEqualToRect(sub.frame, centered)) sub.frame = centered;
    }
    SGRGlassFlatBox(disc, &kInviteGlass, YES);
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
