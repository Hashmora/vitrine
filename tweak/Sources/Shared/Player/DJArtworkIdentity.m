#import "DJArtworkIdentity.h"
#import <objc/runtime.h>
#import "Core/SGDJProbe.h"

static NSString *const kSpotifyDJURI = @"spotify:playlist:37i9dQZF1EYkqdzj48dyYq";

// A displayed title is a hint, not identity. In particular a playlist named
// DJ is usually exposed as "DJ, Playlist, ..." on Recents/shortcuts.
static BOOL djTitle(NSString *title) {
    return [title isEqualToString:@"DJ"] || [title hasPrefix:@"DJ,"] || [title hasPrefix:@"DJ."] ||
           [title hasPrefix:@"Your DJ"] || [title hasPrefix:@"AI DJ"];
}
static BOOL playlistLabel(NSString *label) {
    NSString *text = label.lowercaseString;
    return [text containsString:@", playlist"] || [text containsString:@". playlist"] ||
           [text containsString:@"playlist,"] || [text containsString:@"playlist."];
}
static BOOL containsDJIdentity(NSString *value) {
    if (!value.length) return NO;
    if ([value containsString:kSpotifyDJURI]) return YES;
    NSString *text = value.lowercaseString;
    // These describe Spotify's assistant, not a generic "DJ" playlist name.
    return [text containsString:@"your ai dj"] || [text containsString:@"spotify ai dj"] ||
           [text containsString:@"your personal dj"];
}
static BOOL editorialDJIdentity(NSString *value) {
    if (!value.length) return NO;
    NSString *text = value.lowercaseString;
    // Official DJ entries are sometimes published as *playlists* in Recents,
    // while the model URI never reaches UIKit accessibility fields. Do not
    // mistake the word "playlist" for proof that the card is user-created.
    // These are additional publisher/curation hints, not the DJ title alone.
    return [text containsString:@"made for you"] ||
           [text containsString:@"your own personal dj"] ||
           [text containsString:@"your own dj"] ||
           [text containsString:@"by spotify"] ||
           [text containsString:@"spotify's dj"];
}
static BOOL isDedicatedDJComponent(UIView *card) {
    // Unlike a title, Spotify's dedicated DJ Home component is not an
    // arbitrary playlist and cannot be impersonated by naming a playlist DJ.
    for (UIView *v = card, *stop = card.superview.superview.superview.superview; v && v != stop; v = v.superview) {
        NSString *name = NSStringFromClass(v.class);
        if ([name containsString:@"DJMDCView"] ||
            [name containsString:@"DJMDCElement"] ||
            [name containsString:@"Discovery_DJElementKit"]) return YES;
        // These hooks are used from an image under a known card: do not walk
        // outside the card into neighbouring, unrelated Home elements.
        if ([v isKindOfClass:UIWindow.class]) break;
    }
    return NO;
}
static BOOL viewIdentifiesDJ(UIView *view, NSUInteger depth) {
    if (!view || depth > 8) return NO;
    if (containsDJIdentity(view.accessibilityIdentifier) || containsDJIdentity(view.accessibilityLabel) ||
        containsDJIdentity(view.accessibilityValue) ||
        containsDJIdentity(view.accessibilityHint)) return YES;
    for (UIView *child in view.subviews) if (viewIdentifiesDJ(child, depth + 1)) return YES;
    return NO;
}
static BOOL viewHasEditorialDJIdentity(UIView *view, NSUInteger depth) {
    if (!view || depth > 6) return NO;
    if (editorialDJIdentity(view.accessibilityLabel) || editorialDJIdentity(view.accessibilityValue) ||
        editorialDJIdentity(view.accessibilityHint)) return YES;
    for (UIView *child in view.subviews) if (viewHasEditorialDJIdentity(child, depth + 1)) return YES;
    return NO;
}
@interface SGDJArtworkCardCache : NSObject
@property (nonatomic, weak) UIView *parent;
@property (nonatomic, weak) UIView *card;
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic) CFAbsoluteTime checkedAt;
@end
@implementation SGDJArtworkCardCache
@end
static char kArtworkCardCacheKey;
UIView *SGDJArtworkEnclosingCard(UIView *holder) {
    if (!holder) return nil;
    SGDJArtworkCardCache *cache = objc_getAssociatedObject(holder, &kArtworkCardCacheKey);
    UIView *parent = holder.superview;
    UIWindow *window = holder.window;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // If no card was found, allow the wrapper to finish mounting lazily.
    // Weak references prevent retaining recycled Spotify cells.
    if (cache && cache.parent == parent && cache.window == window &&
        (cache.card || now - cache.checkedAt < 0.25)) return cache.card;
    UIView *card = parent;
    while (card && ![card.accessibilityIdentifier isEqualToString:@"Components.UI.HomeCard"] &&
           ![card.accessibilityIdentifier isEqualToString:@"Shortcut.Card.Home"] &&
           ![card.accessibilityIdentifier isEqualToString:@"Components.UI.RecentsListRow"]) card = card.superview;
    if (!cache) {
        cache = [SGDJArtworkCardCache new];
        objc_setAssociatedObject(holder, &kArtworkCardCacheKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    cache.parent = parent;
    cache.window = window;
    cache.card = card;
    cache.checkedAt = now;
    return card;
}

static char kMissingArtCardKey, kMissingArtSinceKey;
#if SG_DRIVER
static char kArtworkProbeSignature, kMissingArtProbeKey;
#endif

// A 9.1.90 DJ entry may have the exact same accessible title as a playlist.
// Spotify sometimes draws its empty tile without an Encore PlaceholderView or
// UIImageView at the level we expected. Neither is a reliable prerequisite.
// Preserve loaded covers whenever the placeholder is gone. A visible
// PlaceholderView means Spotify still considers the artwork unresolved even
// if the image slot contains a temporary bitmap. Explicit DJ identity is
// handled separately in IsConfirmedCard.
static void sgScanArt(UIView *view, NSUInteger depth, BOOL *loaded, BOOL *placeholder) {
    if (!view || depth > 4) return;
    if ([view.accessibilityIdentifier hasPrefix:@"SG.DJArtwork"] ||
        [view.accessibilityIdentifier hasPrefix:@"SGR.DJArtwork"]) return;
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"Placeholder"] && !view.hidden && view.alpha > 0.01)
        *placeholder = YES;
    if ([view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image &&
        !view.hidden && view.alpha > 0.01) *loaded = YES;
    for (UIView *sub in view.subviews) sgScanArt(sub, depth + 1, loaded, placeholder);
}

// Compatibility fallback: show DJ cover only for known Spotify tile kinds,
// when their native art is still missing or an active placeholder is visible.
// Never require a particular PlaceholderView hierarchy: it differs between
// Home tiles and Recents rows. A user playlist DJ whose artwork is genuinely
// missing is visually ambiguous; a model URI is needed to distinguish it.
BOOL SGDJArtworkNeedsPlaceholder(UIView *card, UIView *holder, BOOL *retry) {
    if (retry) *retry = NO;
    BOOL candidate = card && holder && djTitle(card.accessibilityLabel) &&
        ([card.accessibilityIdentifier isEqualToString:@"Components.UI.RecentsListRow"] ||
         [card.accessibilityIdentifier isEqualToString:@"Components.UI.HomeCard"] ||
         [card.accessibilityIdentifier isEqualToString:@"Shortcut.Card.Home"]);
    BOOL nativeArtwork = NO, placeholder = NO;
    if (candidate) sgScanArt(holder, 0, &nativeArtwork, &placeholder);
    BOOL missing = candidate && (!nativeArtwork || placeholder);
    if (!missing) {
        objc_setAssociatedObject(holder, &kMissingArtCardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(holder, &kMissingArtSinceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSValue *previousCard = objc_getAssociatedObject(holder, &kMissingArtCardKey);
    NSNumber *firstSeen = objc_getAssociatedObject(holder, &kMissingArtSinceKey);
    if (missing && (!previousCard || previousCard.nonretainedObjectValue != card || !firstSeen)) {
        objc_setAssociatedObject(holder, &kMissingArtCardKey, [NSValue valueWithNonretainedObject:card], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(holder, &kMissingArtSinceKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        firstSeen = @(now);
        if (retry) *retry = YES;
    }
    BOOL useFallback = missing && firstSeen && now - firstSeen.doubleValue >= 0.8;
#if SG_DRIVER
    NSString *signature = [NSString stringWithFormat:@"%d-%d-%d-%d", candidate,
                           nativeArtwork, placeholder, useFallback];
    if (![objc_getAssociatedObject(holder, &kMissingArtProbeKey) isEqualToString:signature]) {
        objc_setAssociatedObject(holder, &kMissingArtProbeKey, signature, OBJC_ASSOCIATION_COPY_NONATOMIC);
        SGDJ_TRACE(@"artwork.placeholder", (@{ @"candidate": @(candidate),
             @"nativeArtwork": @(nativeArtwork), @"placeholder": @(placeholder),
             @"fallback": @(useFallback),
             @"history": @([card.accessibilityIdentifier isEqualToString:@"Components.UI.RecentsListRow"])}));
    }
#endif
    return useFallback;
}

BOOL SGDJArtworkIsConfirmedCard(UIView *card) {
    if (!card || !djTitle(card.accessibilityLabel)) return NO;
    BOOL explicitIdentity = containsDJIdentity(card.accessibilityLabel) || viewIdentifiesDJ(card, 0);
    BOOL dedicated = !explicitIdentity && isDedicatedDJComponent(card);
    BOOL editorial = !explicitIdentity && !dedicated &&
        (editorialDJIdentity(card.accessibilityLabel) || viewHasEditorialDJIdentity(card, 0));
    BOOL confirmed = explicitIdentity || dedicated || editorial;
    BOOL genericPlaylist = playlistLabel(card.accessibilityLabel) && !confirmed;
    SGDJProbeArtworkDecision(confirmed, genericPlaylist);

#if SG_DRIVER
    // Emit only boolean classifier reasons and hashed label change detection.
    // Never record title, account names, playlist URI or accessibility text.
    NSString *signature = [NSString stringWithFormat:@"%d/%d/%d/%d/%d/%lu", explicitIdentity,
                           dedicated, editorial, genericPlaylist, confirmed,
                           (unsigned long)card.accessibilityLabel.hash];
    if (![objc_getAssociatedObject(card, &kArtworkProbeSignature) isEqualToString:signature]) {
        objc_setAssociatedObject(card, &kArtworkProbeSignature, signature, OBJC_ASSOCIATION_COPY_NONATOMIC);
        SGDJ_TRACE(@"artwork.classifier", (@{
            @"explicit": @(explicitIdentity), @"dedicated": @(dedicated),
            @"editorial": @(editorial), @"genericPlaylist": @(genericPlaylist),
            @"confirmed": @(confirmed),
            @"history": @([card.accessibilityIdentifier isEqualToString:@"Components.UI.RecentsListRow"]),
            @"shortcut": @([card.accessibilityIdentifier isEqualToString:@"Shortcut.Card.Home"])
        }));
    }
#endif
    return confirmed;
}
