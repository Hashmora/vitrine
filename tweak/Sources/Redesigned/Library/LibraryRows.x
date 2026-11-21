// Library redesign: the rows of Your Library and of a folder inside it, and the cards of its grid.
//
// Tree (trees/clean/library/03.txt:30-73, 06.txt:28-40): every cell of the list is a
// YourLibrarySwipeableCollectionViewCellContainer holding either a 402x80 row -- id=Playlist.Row.Library,
// Album.Row.Library or Podcast.Row.Library, all three an AutoLayoutStackView {16, 8} 370x64 of
// id=Artwork.Row.Library 64x64 r=4 and, 12pt after it, the title over its kind and its owner -- or a
// 112.67x161.33 card, id=Components.UI.CardLibrary, over id=Components.UI.CardLibrary.Artwork r=4.
//
// Two things are changed, both of them the Music app's library. The artwork takes the Kit's radius for its
// size with continuous corners, Spotify's 4pt being the square corner of its own look; an artist's picture
// already carries a radius half its side and is left the circle it is (r=32 in the trees, 2 of the 90 rows
// recorded). And a hairline runs between the rows from the text's leading edge, which is where a library list
// draws one -- a layer rather than a view, since the rows are reused as fast as the list scrolls, with its
// actions off so a reused row does not slide its line into place.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Library.h"

// What a row leaves between its artwork and its text (03.txt:36 and :39: the artwork ends at 64, the text
// starts at 76), and where the hairline starts with it.
static const CGFloat kTextGap = 12;

static char kThumbKey, kCoverKey, kLineKey, kAddRowGlassKey;

// Spotify gives a cover a square corner and an artist's picture a circle. Only the square becomes the Kit's.
static void roundCorners(UIView *artwork, CGFloat radius) {
    if (!artwork) return;
    CGFloat side = MIN(artwork.bounds.size.width, artwork.bounds.size.height);
    CALayer *layer = artwork.layer;
    if (side < 1 || layer.cornerRadius >= side / 2 - 0.5) return;
    if (layer.cornerRadius != radius) layer.cornerRadius = radius;
    if (layer.cornerCurve != kCACornerCurveContinuous) layer.cornerCurve = kCACornerCurveContinuous;
    if (!layer.masksToBounds) layer.masksToBounds = YES;
}


static BOOL isLibraryActionRow(UIView *row) {
    NSString *identifier = row.accessibilityIdentifier;
    return [identifier isEqualToString:@"AddArtist.Row.Library"]
        || [identifier isEqualToString:@"AddPodcast.Row.Library"]
        || [identifier isEqualToString:@"AddEvent.Row.Library"]
        || [identifier isEqualToString:@"ImportMusic.Row.Library"];
}

static UIView *libraryActionRow(UIView *cell) {
    __block UIView *row = nil;
    SGForEachView(cell, ^(UIView *view) {
        if (!row && isLibraryActionRow(view)) row = view;
    });
    return row;
}

static UIView *actionFillInThumb(UIView *thumb) {
    for (UIView *child in thumb.subviews.reverseObjectEnumerator) {
        if (![child isMemberOfClass:UIView.class]) continue;
        if (fabs(child.bounds.size.width - thumb.bounds.size.width) > 1
            || fabs(child.bounds.size.height - thumb.bounds.size.height) > 1) continue;
        UIColor *color = child.backgroundColor;
        if (!color && !child.layer.backgroundColor) continue;
        CGFloat alpha = color ? CGColorGetAlpha(color.CGColor) : CGColorGetAlpha(child.layer.backgroundColor);
        if (alpha < 0.05) continue;
        return child;
    }
    return nil;
}

static void glassLibraryAction(UIView *cell) {
    UIView *row = libraryActionRow(cell);
    if (!row || !row.window) return;
    UIView *thumb = SGRFindByIdentifier(row, @"Artwork.Row.Library", &kThumbKey);
    if (!thumb || fabs(thumb.bounds.size.width - 64) > 2 || fabs(thumb.bounds.size.height - 64) > 2) return;

    UIView *fill = actionFillInThumb(thumb);
    // Spotify's solid placeholder sits ABOVE the glass. Stage 133 added the
    // lens below it but did not clear the old #1F1F1F paint: it was invisible.
    // Keep the plus/import UIImageView, only remove the opaque backgrounds.
    for (UIView *sub in thumb.subviews) {
        if (sub == fill || [NSStringFromClass(sub.class) hasSuffix:@"EncoreImageView"]) {
            if (sub.backgroundColor) sub.backgroundColor = UIColor.clearColor;
            if (sub.layer.backgroundColor) sub.layer.backgroundColor = NULL;
            if (sub.opaque) sub.opaque = NO;
            if (sub.layer.opaque) sub.layer.opaque = NO;
        }
    }
    if (thumb.opaque) thumb.opaque = NO;
    if (thumb.layer.opaque) thumb.layer.opaque = NO;
    if (fill) SGRHoldClear(fill);

    UIView *glass = SGGlassFor(thumb, &kAddRowGlassKey);
    if (!glass) return;
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if (!CGRectEqualToRect(glass.frame, thumb.bounds)) glass.frame = thumb.bounds;
    CGFloat radius = thumb.layer.cornerRadius > 0 ? thumb.layer.cornerRadius
                                                  : MIN(thumb.bounds.size.width, thumb.bounds.size.height) / 2;
    SGShapeGlass(glass, radius, NO);
    if (glass.layer.borderWidth > 0) glass.layer.borderWidth = 0;
    SGRGlassSetFilm(glass, YES, radius);
    // Keep the lens at the back of the holder, behind the native glyph.
    // UIKit can reorder subviews during reuse; restore that order on layout.
    if (glass.superview != thumb || thumb.subviews.firstObject != glass)
        [thumb insertSubview:glass atIndex:0];
    if (SGUseLegacyGlass()) SGRUnclipUpTo(thumb, ^BOOL(UIView *v) { return v == cell; });
}

// The line under a row, from its text's leading edge to the trailing edge of the page. A cell holding a card
// has none, and one reused from a row into a card loses the line it was left with.
static void hairline(UIView *cell, UIView *thumb) {
    CALayer *line = objc_getAssociatedObject(cell, &kLineKey);
    CGSize size = cell.bounds.size;
    CGRect artwork = thumb ? SGFrameIn(thumb, cell) : CGRectZero;
    BOOL wanted = thumb && size.width > 300 && size.height <= 120 && artwork.size.width > 1;
    if (!wanted) {
        if (line && !line.hidden) line.hidden = YES;
        return;
    }
    if (!line) {
        line = [CALayer layer];
        line.backgroundColor = SGRHairline().CGColor;
        objc_setAssociatedObject(cell, &kLineKey, line, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (line.superlayer != cell.layer) [cell.layer addSublayer:line];

    CGFloat thickness = 1.0 / MAX(1, cell.window.screen.scale ?: UIScreen.mainScreen.scale);
    CGFloat leading = CGRectGetMaxX(artwork) + kTextGap;
    CGRect frame = CGRectMake(leading, size.height - thickness, MAX(0, size.width - leading), thickness);
    if (line.hidden || !CGRectEqualToRect(line.frame, frame)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        line.hidden = NO;
        line.frame = frame;
        [CATransaction commit];
    }
}

static void style(UIView *cell) {
    UIView *thumb = SGRFindByIdentifier(cell, @"Artwork.Row.Library", &kThumbKey);
    if (thumb) roundCorners(thumb, SGRRadiusThumb);
    else roundCorners(SGRFindByIdentifier(cell, @"Components.UI.CardLibrary.Artwork", &kCoverKey), SGRRadiusCover);
    hairline(cell, thumb);
    glassLibraryAction(cell);

    // The first cell that held an artwork, so the line says what was found rather than what had not loaded yet.
    static BOOL logged;
    if (!logged && thumb && thumb.bounds.size.width > 1) {
        logged = YES;
        SGLog(@"redesign library: rows styled, first cell %@, thumbnail %@ at r=%.1f",
              NSStringFromCGSize(cell.bounds.size), NSStringFromCGSize(thumb.bounds.size), thumb.layer.cornerRadius);
    }
}

%hook _TtC21YourLibrary_CommonKit47YourLibrarySwipeableCollectionViewCellContainer
- (void)layoutSubviews {
    %orig;
    style((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC21YourLibrary_CommonKit47YourLibrarySwipeableCollectionViewCellContainer"]);
}
