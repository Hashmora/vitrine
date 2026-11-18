// Redesign: glass for the two Create menus, the same pane the queue, the ⋯ menu and the Connect picker have. Both
// draw the same three or four CreateMenuItemRows, but they are laid out differently, so each gets what fits it:
//
// - The tab bar's Create menu (CreateMenu_CreateMenuPageImpl) is a floating card, not a full sheet: the
//   sheet-view is 307 pt tall with no fill and reaches down over the tab bar, where the transparent
//   CreateMenu.ForwardingView hands touches to the Create tab that has turned into the close button. A pane
//   over the whole sheet-view would cover the tab bar, so the glass goes behind the card alone
//   (CreateMenu.ScrollView, #1F1F1F, r=16, inset 8 pt from the sides), and the card's own grey goes clear.
//   The pane is a sibling of the card rather than a subview of it, so it stays put when the card scrolls.
// - The Create playlist sheet from the Library's + (PlaylistCreation_SheetPageImpl) is an ordinary sheet:
//   id=sheet-view, #1F1F1F, full width, with the same rows in it. SGRGlassSheetChrome does all of it.
//
// The rows' icon circles (Encore.Box, #FFFFFF@0.14) are already translucent white and are left as they are.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static NSString *const kCardIdentifier = @"CreateMenu.ScrollView";
static char kCardKey, kCardGlassKey, kLegacyBarGlassKey;

static void glassCard(UIViewController *controller) {
    UIView *root = controller.viewIfLoaded;
    UIView *card = root ? SGRFindByIdentifier(root, kCardIdentifier, &kCardKey) : nil;
    UIView *host = card.superview;
    if (!host) return;
    CGFloat radius = card.layer.cornerRadius;
    UIView *glass = SGGlassFor(host, &kCardGlassKey);
    CGRect pane = card.frame;
    // Spotify's Create sheet has a transparent forwarding strip at the bottom,
    // over the tab bar's Create button. The menu glass must NOT fill that strip:
    // doing so produces an opaque, clipped rectangle over the legacy capsule.
    UIView *barGlass = root.window ? SGRFindByIdentifier(root.window, @"Vitrine.LegacyTabBarCapsule", &kLegacyBarGlassKey) : nil;
    if (barGlass && barGlass.window == root.window && !barGlass.hidden && barGlass.alpha > 0.01) {
        CGRect tabFrame = [barGlass convertRect:barGlass.bounds toView:host];
        CGFloat stop = CGRectGetMinY(tabFrame) - 2;
        if (CGRectGetMinY(pane) < stop && CGRectGetMaxY(pane) > stop) {
            pane.size.height = MAX(0, stop - CGRectGetMinY(pane));
        }
    }
    glass.hidden = pane.size.height < 1;
    if (!CGRectEqualToRect(glass.frame, pane)) glass.frame = pane;
    SGShapeGlass(glass, MIN(radius, pane.size.height / 2), NO);
    SGRThickenSheetGlass(glass, radius);
    if (SGIsVisibleColor(card.layer.backgroundColor)) card.backgroundColor = UIColor.clearColor;
}

static void glassSheet(UIViewController *controller) {
    UIView *root = controller.viewIfLoaded;
    if (root) SGRGlassSheetChrome(root);
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    // The rows are built after the first layout and Spotify paints its grey back on later passes.
    SGRPassControllersNamed(@[@"_TtC29CreateMenu_CreateMenuPageImpl24CreateMenuViewController"], ^(UIViewController *c) { glassCard(c); });
    SGRPassControllersNamed(@[@"_TtC30PlaylistCreation_SheetPageImpl35BICreatePlaylistSheetViewController"], ^(UIViewController *c) { glassSheet(c); });
}
