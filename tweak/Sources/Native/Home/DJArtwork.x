// Fill DJ's Home and Recents placeholders with Spotify's own DJ artwork.
// Verified on 9.1.90: Artwork.Row.Library > EncoreImageView; HomeCard and
// RecentsListRow > Encore.ImageView > UIImageView + PlaceholderView.
#import "Core/SGCore.h"
#import "Shared/Player/DJQueue.h"
#import "Shared/Player/DJArtworkIdentity.h"

static UIImage *SGDJCover;
static NSHashTable<UIView *> *SGDJHolders;
static NSInteger const SGDJCoverTag = 0x444a43;
static NSString *SGDJCoverPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"SG-DJ-cover-v2.png"];
}
static void SGDJDraw(UIView *holder);
static NSDate *SGDJAsked;
// The DJ's own 9.1.90 card supplies this public cover URL (DJQueue's recorded image_url).
// It fills a fresh cache without visiting Library or borrowing artwork from reused cells.
static void SGDJLoad(void) {
    if (SGDJAsked && -SGDJAsked.timeIntervalSinceNow < 60) return;
    SGDJAsked = [NSDate date];
    NSURL *url = [NSURL URLWithString:@"https://lexicon-assets.spotifycdn.com/Your-DJ-Cover-Art-300.png"];
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *cover = data.length && data.length < 8 * 1024 * 1024 ? [UIImage imageWithData:data] : nil;
        if (!cover) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (SGDJCover) return;
            SGDJCover = cover;
            NSString *path = SGDJCoverPath();
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [data writeToFile:path atomically:YES]; });
            for (UIView *holder in SGDJHolders.allObjects) SGDJDraw(holder);
        });
    }] resume];
}
static void SGDJDraw(UIView *holder) {
    UIView *row = holder.superview;
    while (row && ![row.accessibilityIdentifier isEqualToString:@"Components.UI.HomeCard"] &&
           ![row.accessibilityIdentifier isEqualToString:@"Shortcut.Card.Home"] &&
           ![row.accessibilityIdentifier isEqualToString:@"Components.UI.RecentsListRow"]) row = row.superview;
    UIImageView *overlay = (UIImageView *)[holder viewWithTag:SGDJCoverTag];
    if (!row || !SGDJArtworkIsConfirmedCard(row)) { [overlay removeFromSuperview]; return; }
    if (!SGDJHolders) SGDJHolders = [NSHashTable weakObjectsHashTable];
    [SGDJHolders addObject:holder];
    if (!SGDJCover) SGDJCover = [UIImage imageWithContentsOfFile:SGDJCoverPath()];
    if (!SGDJCover) { SGDJLoad(); return; }
    if (!overlay) {
        overlay = [UIImageView new];
        overlay.tag = SGDJCoverTag;
        overlay.accessibilityIdentifier = @"SG.DJArtwork";
        overlay.userInteractionEnabled = NO;
        overlay.accessibilityElementsHidden = YES;
        overlay.contentMode = UIViewContentModeScaleAspectFill;
        overlay.clipsToBounds = YES;
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [holder addSubview:overlay];
    }
    overlay.frame = holder.bounds;
    overlay.image = SGDJCover;
    // Spotify's Home holders can have radius zero until their card is first tapped.
    // Other covers already have 4pt corners baked into their artwork; the DJ bitmap does not.
    // Keep the corner radius from Spotify when it is larger, but never draw a square DJ cover.
    overlay.layer.cornerRadius = MAX(4, holder.layer.cornerRadius);
    [holder bringSubviewToFront:overlay];
}
%hook SGDJCardImage
- (void)didMoveToWindow {
    %orig;
    SGDJDraw((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    SGDJDraw((UIView *)self);
}
%end
%ctor {
    // DJ artwork is part of the DJ Queue feature, not a global image replacement.
    if (!SGNativeUI() || !SGEnabled(SGKeyDJQueue)) return;
    %init(SGDJCardImage = objc_getClass("_TtCE15Encore_MediaKitO16EncoreFoundation6Encore9ImageView"));
}
