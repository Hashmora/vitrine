// Fill DJ's Home and Recents placeholders with Spotify's own DJ artwork.
// Verified on 9.1.90: Artwork.Row.Library > EncoreImageView; HomeCard and
// RecentsListRow > Encore.ImageView > UIImageView + PlaceholderView.
#import "Core/SGCore.h"

static UIImage *SGRDJCover;
static NSHashTable<UIView *> *SGRDJHolders;
static NSInteger const SGRDJCoverTag = 0x444a43;
static NSString *SGRDJCoverPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"SGR-DJ-cover-v2.png"];
}
static BOOL SGRDJLabel(NSString *label) {
    return [label isEqualToString:@"DJ"] || [label hasPrefix:@"DJ,"] || [label hasPrefix:@"DJ."];
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
        if (!cover) return;
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
    UIView *row = holder.superview;
    while (row && ![row.accessibilityIdentifier isEqualToString:@"Components.UI.HomeCard"] &&
           ![row.accessibilityIdentifier isEqualToString:@"Shortcut.Card.Home"] &&
           ![row.accessibilityIdentifier isEqualToString:@"Components.UI.RecentsListRow"]) row = row.superview;
    UIImageView *overlay = (UIImageView *)[holder viewWithTag:SGRDJCoverTag];
    if (!row || !SGRDJLabel(row.accessibilityLabel)) { [overlay removeFromSuperview]; return; }
    if (!SGRDJHolders) SGRDJHolders = [NSHashTable weakObjectsHashTable];
    [SGRDJHolders addObject:holder];
    if (!SGRDJCover) SGRDJCover = [UIImage imageWithContentsOfFile:SGRDJCoverPath()];
    if (!SGRDJCover) { SGRDJLoad(); return; }
    if (!overlay) {
        overlay = [UIImageView new];
        overlay.tag = SGRDJCoverTag;
        overlay.userInteractionEnabled = NO;
        overlay.accessibilityElementsHidden = YES;
        overlay.contentMode = UIViewContentModeScaleAspectFill;
        overlay.clipsToBounds = YES;
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [holder addSubview:overlay];
    }
    overlay.frame = holder.bounds;
    overlay.image = SGRDJCover;
    overlay.layer.cornerRadius = holder.layer.cornerRadius;
    [holder bringSubviewToFront:overlay];
}
%hook SGRDJCardImage
- (void)didMoveToWindow { %orig; SGRDJDraw((UIView *)self); }
- (void)layoutSubviews { %orig; SGRDJDraw((UIView *)self); }
%end
%ctor {
    if (!SGRedesignedUI()) return;
    %init(SGRDJCardImage = objc_getClass("_TtCE15Encore_MediaKitO16EncoreFoundation6Encore9ImageView"));
}
