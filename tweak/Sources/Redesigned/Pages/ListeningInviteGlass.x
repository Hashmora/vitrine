// Invite Friends in the listening-activity drawer uses an Element_List cell
// wrapping an unnamed 56pt avatar plate and a separate plus icon. Scope the
// common cell pass to the specific InviteCarouselItemElement before touching it.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kInviteGlass;

static void dressInvite(UIView *cell) {
    if (!cell.window) return;
    UIView *inviteElement = nil;
    for (UIView *sub in cell.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"ListeningActivity_ElementsKit25InviteCarouselItemElement"]) {
            inviteElement = sub;
            break;
        }
    }
    if (!inviteElement) return;

    __block UIView *button = nil;
    SGForEachView(inviteElement, ^(UIView *v) {
        if (!button && [v.accessibilityLabel isEqualToString:@"Invite Friends"] &&
            [v isMemberOfClass:UIView.class]) button = v;
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
    SGRGlassFlatBox(disc, &kInviteGlass, NO);
    SGRUnclipUpTo(disc, ^BOOL(UIView *v) { return v == cell; });
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class cell = SGRSwiftClass(@"Element_List", @"CollectionViewCell");
    if (cell) SGRPassView(cell, ^(UIView *view) { dressInvite(view); });
}
