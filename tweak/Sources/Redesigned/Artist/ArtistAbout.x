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

static char kAboutCardKey, kButtonGlassKey;

static CGFloat desiredButtonWidth(UIView *button) {
    __block UILabel *label = nil;
    SGForEachView(button, ^(UIView *view) {
        if (!label && [view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length)
            label = (UILabel *)view;
    });
    if (!label.text.length) return button.bounds.size.width;
    CGSize fit = [label sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    return MAX(72, ceil(fit.width) + 32);
}


// An Encore secondary button in the card (Follow): a ring drawn as a shape layer the size of its first subview. The
// ring goes and the button stands on a glass capsule, as Spotify's other outlined buttons do (Kit/SGRCallToAction.x).
static void dressButton(UIView *button) {
    UIView *face = button.subviews.firstObject;
    CGRect bounds = face.layer.bounds;
    if (!face || bounds.size.width < 1) return;
    if (button.backgroundColor != UIColor.clearColor) button.backgroundColor = UIColor.clearColor;
    if (button.layer.backgroundColor) button.layer.backgroundColor = NULL;
    if (face.backgroundColor != UIColor.clearColor) face.backgroundColor = UIColor.clearColor;
    if (face.layer.backgroundColor) face.layer.backgroundColor = NULL;
    for (CALayer *layer in face.layer.sublayers) {
        if (![layer isKindOfClass:CAShapeLayer.class] || !CGRectEqualToRect(layer.frame, bounds)) continue;
        CAShapeLayer *ring = (CAShapeLayer *)layer;
        if (ring.strokeColor && CGColorGetAlpha(ring.strokeColor) > 0) ring.strokeColor = UIColor.clearColor.CGColor;
        if (ring.fillColor && CGColorGetAlpha(ring.fillColor) > 0) ring.fillColor = UIColor.clearColor.CGColor;
    }
    CGFloat wanted = desiredButtonWidth(button);
    if (fabs(button.bounds.size.width - wanted) > 0.5) {
        CGRect frame = button.frame;
        frame.size.width = wanted;
        button.frame = frame;
        frame = face.frame;
        frame.size.width = wanted;
        face.frame = frame;
    }
    SGRGlassChip(button, face, NO, &kButtonGlassKey);
}

static void dressAbout(UIView *card) {
    if (!card.window || card.bounds.size.width < 1) return;
    SGRGlassPaneIn(card, &kAboutGlassKey, card.layer.cornerRadius > 0 ? card.layer.cornerRadius : 16);
    if (isCardGray(card.layer.backgroundColor)) card.backgroundColor = UIColor.clearColor;
    for (UIView *sub in card.subviews) {
        if (isCardGray(sub.layer.backgroundColor)) sub.backgroundColor = UIColor.clearColor;
    }
    SGForEachView(card, ^(UIView *v) {
        if ([NSStringFromClass(v.class) hasSuffix:@"Button9Secondary"]) dressButton(v);
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
