// Artist redesign: the About card on glass. Spotify draws it as a card painted #282828 with its corners at 16, the
// biography's part of it painted the same again, a gray block on the artist's field. Here both paints go and the
// card is a pane of the sheets' glass with the same corners; the picture at its top stays.
//
// Tree: Creator_ECMKit.CreatorBiographyCardLayout (a private class) 382x452.5, r=16, clips, bg #282828, holding the
// picture and, at its foot, a plain UIView 382x166 bg #282828 with the rank, the name, Follow, the listeners and the
// biography.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Artist.h"

static char kAboutGlassKey;

// Spotify's card gray: an opaque neutral between #202020 and #303030.
static BOOL isCardGray(CGColorRef color) {
    if (!color || CGColorGetAlpha(color) < 0.95 || CGColorGetNumberOfComponents(color) < 3) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    return c[0] > 0.12 && c[0] < 0.19 && fabs(c[0] - c[1]) < 0.01 && fabs(c[1] - c[2]) < 0.01;
}

static char kAboutCardKey, kButtonGlassKey, kInfoPaneKey, kInfoDimKey;

// An Encore secondary button in the card (Follow): a ring drawn as a shape layer the size of its first subview. The
// ring goes and the button stands on a glass capsule, as Spotify's other outlined buttons do (Kit/SGRCallToAction.x).
static void dressButton(UIView *button) {
    UIView *face = button.subviews.firstObject;
    if (!face || face.bounds.size.width < 1 || button.bounds.size.width < 1) return;
    // Spotify owns the Follow/Following width. Keep the pane in the button's
    // own bounds, not in the secondary button's old face frame.
    button.backgroundColor = UIColor.clearColor;
    button.layer.backgroundColor = NULL;
    face.backgroundColor = UIColor.clearColor;
    face.layer.backgroundColor = NULL;
    button.layer.borderWidth = 0;
    face.layer.borderWidth = 0;
    for (CALayer *layer in face.layer.sublayers) {
        NSString *type = NSStringFromClass(layer.class);
        if ([type containsString:@"BackgroundLayer"]) {
            layer.opacity = 0; // Encore's original gray plate and offset ring
        } else if ([layer isKindOfClass:CAShapeLayer.class] &&
                   layer.bounds.size.width >= face.bounds.size.width * 0.65) {
            CAShapeLayer *ring = (CAShapeLayer *)layer;
            if (ring.strokeColor) ring.strokeColor = UIColor.clearColor.CGColor;
        }
    }
    // The glass key is per actual button. SGRGlassCapsuleInside resizes it
    // on every Follow/Following change, with no manual width mutation.
    SGRGlassCapsuleInside(button, &kButtonGlassKey, button.bounds.size, NO);
    SGRUnclipUpTo(button, ^BOOL(UIView *v) {
        // Stop BEFORE the outer card. Unclipping the BiographyCardLayout itself
        // lost its 16pt rounded corners after toggling Follow.
        return [NSStringFromClass(v.superview.class) hasSuffix:@"CreatorBiographyCardLayout"];
    });
}

static BOOL onArtistCard(UIView *button) {
    for (UIView *v = button.superview; v; v = v.superview) {
        if ([NSStringFromClass(v.class) hasSuffix:@"CreatorBiographyCardLayout"]) return YES;
        if ([v isKindOfClass:UICollectionView.class]) break;
    }
    return NO;
}

static void dressAbout(UIView *card) {
    if (!card.window || card.bounds.size.width < 1) return;
    // Photo and caption are different sibling views. Put glass ONLY under
    // the short caption at the bottom, not behind the full photo/card.
    UIView *info = nil;
    for (UIView *sub in card.subviews) {
        if (![sub isMemberOfClass:UIView.class]) continue;
        if (sub.bounds.size.width < card.bounds.size.width - 2 || sub.bounds.size.height < 75) continue;
        if (sub.frame.origin.y < card.bounds.size.height * 0.45) continue;
        if (!isCardGray(sub.layer.backgroundColor)) continue;
        info = sub;
        break;
    }
    if (!info) return;
    // Preserve the card's native 16pt outer rounding. The info plate gets
    // its own *top* rounded corners where it meets the artist's photo.
    if (isCardGray(card.layer.backgroundColor)) card.backgroundColor = UIColor.clearColor;
    info.backgroundColor = UIColor.clearColor;
    info.layer.backgroundColor = NULL;
    info.layer.cornerRadius = 22;
    info.layer.cornerCurve = kCACornerCurveContinuous;
    UIView *glass = SGRGlassPaneIn(info, &kInfoPaneKey, 22);
    if (glass) SGRDarkenGlass(glass, &kInfoDimKey, 22, 0.35);
    SGForEachView(info, ^(UIView *v) {
        if ([NSStringFromClass(v.class) hasSuffix:@"Button9Secondary"] &&
            [v.accessibilityIdentifier isEqualToString:@"Curation.FollowButtonElementKit.FollowButton"])
            dressButton(v);
    });
}

// Found by name in the cell the artist's list lays out (ArtistSections.x), which knows the About cell by its
// identifier: a class pass on the card's private class does not run.
void SGRArtistDressAbout(UIView *cell) {
    // Below iOS 26 only: on iOS 26 the card keeps Spotify's grey, as on main.
    if (!SGBelowiOS26()) return;
    // The card is 452pt tall; a shorter cell is never it, and is not walked on every pass of the scroll.
    if (cell.bounds.size.height < 300) return;
    UIView *card = objc_getAssociatedObject(cell, &kAboutCardKey);
    if (!card || ![card isDescendantOfView:cell]) {
        card = nil;
        __block UIView *found = nil;
        SGForEachView(cell, ^(UIView *v) {
            if (!found && [NSStringFromClass(v.class) hasSuffix:@"CreatorBiographyCardLayout"]) found = v;
        });
        card = found;
        objc_setAssociatedObject(cell, &kAboutCardKey, card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (card) dressAbout(card);
}

// The Follow control can repaint its ring without laying out the enclosing
// About cell. Reapply on the button's own pass, immediately on each toggle.
%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class secondary = NSClassFromString(@"_TtCCE16Encore_ButtonKitO16EncoreFoundation6Encore6Button9Secondary");
    if (secondary) SGRPassView(secondary, ^(UIView *v) {
        if (onArtistCard(v)) dressButton(v);
    });
}
