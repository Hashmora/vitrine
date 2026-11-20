// Fill DJ's Home and Recents placeholders with Spotify's own DJ artwork.
// Verified on 9.1.90: Artwork.Row.Library > EncoreImageView; HomeCard and
// RecentsListRow > Encore.ImageView > UIImageView + PlaceholderView.
#import "Core/SGCore.h"
#import "Shared/Player/DJQueue.h"
#import "Shared/Player/DJArtworkIdentity.h"
#import "Core/SGDJProbe.h"
#import <objc/runtime.h>
#import "Redesigned/Kit/SGRKit.h"
#import "Home.h"

static UIImage *SGRDJCover;
static NSHashTable<UIView *> *SGRDJHolders;
static NSInteger const SGRDJCoverTag = 0x444a43;
#if SG_DRIVER
static char SGRDJDrawProbeKey;
#endif
static NSString *SGRDJCoverPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"SGR-DJ-cover-v2.png"];
}
static void SGRDJDraw(UIView *holder);
static NSDate *SGRDJAsked;
// The DJ's own 9.1.90 card supplies this public cover URL (DJQueue's recorded image_url).
// It fills a fresh cache without visiting Library or borrowing artwork from reused cells.
static void SGRDJLoad(void) {
    if (SGRDJAsked && -SGRDJAsked.timeIntervalSinceNow < 60) return;
    SGRDJAsked = [NSDate date];
    NSURL *url = [NSURL URLWithString:@"https://lexicon-assets.spotifycdn.com/Your-DJ-Cover-Art-300.png"];
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *cover = data.length && data.length < 8 * 1024 * 1024 ? [UIImage imageWithData:data] : nil;
        if (!cover) {
            SGDJ_TRACE(@"artwork.cover", (@{ @"loaded": @NO, @"redesigned": @(1) }));
            return;
        }
        SGDJ_TRACE(@"artwork.cover", (@{ @"loaded": @YES, @"redesigned": @(1) }));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (SGRDJCover) return;
            SGRDJCover = cover;
            NSString *path = SGRDJCoverPath();
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [data writeToFile:path atomically:YES]; });
            for (UIView *holder in SGRDJHolders.allObjects) SGRDJDraw(holder);
        });
    }] resume];
}
static void SGRDJDraw(UIView *holder) {
    UIView *row = SGDJArtworkEnclosingCard(holder);
    UIImageView *overlay = (UIImageView *)[holder viewWithTag:SGRDJCoverTag];
    BOOL confirmed = row && SGDJArtworkIsConfirmedCard(row);
    BOOL retry = NO;
    BOOL placeholderFallback = !confirmed && row && SGDJArtworkNeedsPlaceholder(row, holder, &retry);
    if (retry) {
        // Give Spotify's own artwork loader time to finish. A custom playlist
        // named DJ keeps its normal image if one arrives during this interval.
        __weak UIView *weakHolder = holder;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.85 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *current = weakHolder;
            if (current.window) SGRDJDraw(current);
        });
    }
#if SG_DRIVER
    NSString *drawing = [NSString stringWithFormat:@"%d-%d-%d-%d", !!row, confirmed,
                          placeholderFallback, !!SGRDJCover];
    if (![objc_getAssociatedObject(holder, &SGRDJDrawProbeKey) isEqualToString:drawing]) {
        objc_setAssociatedObject(holder, &SGRDJDrawProbeKey, drawing, OBJC_ASSOCIATION_COPY_NONATOMIC);
        SGDJ_TRACE(@"artwork.draw", (@{ @"card": @(!!row), @"confirmed": @(confirmed),
                 @"fallback": @(placeholderFallback), @"coverReady": @(!!SGRDJCover),
                 @"redesigned": @(1) }));
    }
#endif
    if (!confirmed && !placeholderFallback) {
        [overlay removeFromSuperview];
        SGDJArtworkTracePaint(holder, overlay, row, NO, !!SGRDJCover, YES);
        return;
    }
    if (!SGRDJHolders) SGRDJHolders = [NSHashTable weakObjectsHashTable];
    [SGRDJHolders addObject:holder];
    if (!SGRDJCover) SGRDJCover = [UIImage imageWithContentsOfFile:SGRDJCoverPath()];
    if (!SGRDJCover) {
        SGRDJLoad();
        SGDJArtworkTracePaint(holder, overlay, row, YES, NO, YES);
        return;
    }
    if (!overlay) {
        overlay = [UIImageView new];
        overlay.tag = SGRDJCoverTag;
        overlay.accessibilityIdentifier = @"SGR.DJArtwork";
        overlay.userInteractionEnabled = NO;
        overlay.accessibilityElementsHidden = YES;
        overlay.contentMode = UIViewContentModeScaleAspectFill;
        overlay.clipsToBounds = YES;
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [holder addSubview:overlay];
    }
    overlay.frame = holder.bounds;
    overlay.image = SGRDJCover;
    // Spotify's Home image holder starts square and often gets its radius only after a tap.
    // Match Home's cover/tile radius on the very first draw instead of inheriting that zero.
    NSString *kind = row.accessibilityIdentifier;
    CGFloat radius = 4;  // Recents uses the 4pt rounding baked into ordinary artwork.
    if ([kind isEqualToString:@"Components.UI.HomeCard"]) radius = SGRRadiusCover;
    else if ([kind isEqualToString:@"Shortcut.Card.Home"])
        radius = SGRHomeLook() ? SGRHomeTileRadius : SGRRadiusCover;
    overlay.layer.cornerRadius = MAX(radius, holder.layer.cornerRadius);
    overlay.layer.cornerCurve = kCACornerCurveContinuous;
    [holder bringSubviewToFront:overlay];
    SGDJArtworkTracePaint(holder, overlay, row, YES, YES, YES);
}
%hook SGRDJCardImage
- (void)didMoveToWindow {
    %orig;
    SGRDJDraw((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    SGRDJDraw((UIView *)self);
}
%end
%ctor {
    // DJ artwork is part of the DJ Queue feature, not a global image replacement.
    if (!SGRedesignedUI() || !SGEnabled(SGKeyDJQueue)) return;
    %init(SGRDJCardImage = objc_getClass("_TtCE15Encore_MediaKitO16EncoreFoundation6Encore9ImageView"));
}
