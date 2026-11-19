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

// A missing cover is not evidence of DJ identity. Before using the legacy
// placeholder path, reject any card whose metadata explicitly points to a
// *different* Spotify playlist. Only inspect strings already exposed by UIKit;
// never call undocumented model selectors from a layout hook.
static BOOL otherPlaylistURIInString(NSString *value) {
    if (!value.length) return NO;
    NSString *prefix = @"spotify:playlist:";
    NSRange scan = NSMakeRange(0, value.length);
    while (scan.length) {
        NSRange found = [value rangeOfString:prefix options:NSCaseInsensitiveSearch range:scan];
        if (found.location == NSNotFound) break;
        NSUInteger start = NSMaxRange(found), end = start;
        while (end < value.length) {
            unichar ch = [value characterAtIndex:end];
            if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                  (ch >= '0' && ch <= '9'))) break;
            ++end;
        }
        if (end > start) {
            NSString *uri = [value substringWithRange:NSMakeRange(found.location, end - found.location)];
            if ([uri caseInsensitiveCompare:kSpotifyDJURI] != NSOrderedSame) return YES;
        }
        if (end >= value.length) break;
        scan = NSMakeRange(MAX(end, NSMaxRange(found)), value.length - MAX(end, NSMaxRange(found)));
    }
    return NO;
}
static BOOL cardHasOtherPlaylistURI(UIView *view, NSUInteger depth) {
    if (!view || depth > 5) return NO;
    if (otherPlaylistURIInString(view.accessibilityIdentifier) ||
        otherPlaylistURIInString(view.accessibilityLabel) ||
        otherPlaylistURIInString(view.accessibilityValue) ||
        otherPlaylistURIInString(view.accessibilityHint)) return YES;
    for (UIView *sub in view.subviews) {
        if (cardHasOtherPlaylistURI(sub, depth + 1)) return YES;
    }
    return NO;
}
// Encore occasionally wraps its native artwork in another view. Check the
// image slot itself and nested image views, not just direct holder children;
// never replace a real cover even when the placeholder view still exists.
static BOOL hasNativeBitmap(UIView *view, NSUInteger depth, CGFloat minimumExtent, BOOL *foundSlot) {
    if (!view || depth > 3) return NO;
    NSString *identifier = view.accessibilityIdentifier;
    if ([identifier hasPrefix:@"SG.DJArtwork"] || [identifier hasPrefix:@"SGR.DJArtwork"]) return NO;
    if ([view isKindOfClass:UIImageView.class]) {
        UIImageView *slot = (UIImageView *)view;
        // Do not mistake a tiny placeholder symbol for the artwork bitmap.
        BOOL coverSize = MIN(slot.bounds.size.width, slot.bounds.size.height) >= minimumExtent;
        if (coverSize) {
            *foundSlot = YES;
            if (slot.image || slot.layer.contents) return YES;
        }
    }
    for (UIView *child in view.subviews) {
        if (hasNativeBitmap(child, depth + 1, minimumExtent, foundSlot)) return YES;
    }
    return NO;
}

static char kMissingArtCardKey, kMissingArtSinceKey, kMissingArtLabelKey;
#if SG_DRIVER
static char kArtworkProbeSignature, kMissingArtProbeKey;
#endif
// Spotify's official DJ can be exposed as a plain "DJ, Playlist" card in
// Recents with no URI, publisher or DJ component reachable from UIKit. Avoid
// restoring the old title-only override: a user playlist named DJ has the
// same title, but its loaded UIImageView must never be covered by our art.
// Only the empty Encore placeholder can use this compatibility path. If
// Spotify omits both URI and cover, two different playlist models can still
// have identical UIKit trees; the compatibility path cannot prove ownership.
BOOL SGDJArtworkNeedsPlaceholder(UIView *card, UIView *holder, BOOL *retry) {
    if (retry) *retry = NO;
    BOOL candidate = card && holder && djTitle(card.accessibilityLabel) &&
        playlistLabel(card.accessibilityLabel) &&
        ([card.accessibilityIdentifier isEqualToString:@"Components.UI.RecentsListRow"] ||
         [card.accessibilityIdentifier isEqualToString:@"Components.UI.HomeCard"] ||
         [card.accessibilityIdentifier isEqualToString:@"Shortcut.Card.Home"]);
    BOOL nativeArtwork = NO, foundBitmapSlot = NO, placeholder = NO;
    if (candidate) {
        CGFloat coverExtent = MAX(8, MIN(holder.bounds.size.width, holder.bounds.size.height) * 0.6);
        nativeArtwork = hasNativeBitmap(holder, 0, coverExtent, &foundBitmapSlot);
        for (UIView *sub in holder.subviews) {
            if ([NSStringFromClass(sub.class) containsString:@"Placeholder"] && !sub.hidden && sub.alpha > 0.01)
                placeholder = YES;
        }
    }
    // Evaluate the potentially costly URI lookup only for a truly empty tile.
    BOOL missing = candidate && foundBitmapSlot && !nativeArtwork && placeholder &&
        !cardHasOtherPlaylistURI(card, 0);
    if (!missing) {
        objc_setAssociatedObject(holder, &kMissingArtCardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(holder, &kMissingArtSinceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(holder, &kMissingArtLabelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSValue *previousCard = objc_getAssociatedObject(holder, &kMissingArtCardKey);
    NSNumber *firstSeen = objc_getAssociatedObject(holder, &kMissingArtSinceKey);
    NSString *previousLabel = objc_getAssociatedObject(holder, &kMissingArtLabelKey);
    // A Recents cell can be reused for another playlist without replacing the
    // underlying UIView. Do not inherit its 0.8 s placeholder deadline.
    if (missing && (!previousCard || previousCard.nonretainedObjectValue != card || !firstSeen ||
                    ![previousLabel isEqualToString:card.accessibilityLabel])) {
        objc_setAssociatedObject(holder, &kMissingArtCardKey, [NSValue valueWithNonretainedObject:card], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(holder, &kMissingArtSinceKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(holder, &kMissingArtLabelKey, card.accessibilityLabel, OBJC_ASSOCIATION_COPY_NONATOMIC);
        firstSeen = @(now);
        if (retry) *retry = YES;
    }
    BOOL useFallback = missing && firstSeen && now - firstSeen.doubleValue >= 0.8;
#if SG_DRIVER
    NSString *signature = [NSString stringWithFormat:@"%d-%d-%d-%d-%d", candidate, foundBitmapSlot,
                           nativeArtwork, placeholder, useFallback];
    if (![objc_getAssociatedObject(holder, &kMissingArtProbeKey) isEqualToString:signature]) {
        objc_setAssociatedObject(holder, &kMissingArtProbeKey, signature, OBJC_ASSOCIATION_COPY_NONATOMIC);
        SGDJ_TRACE(@"artwork.placeholder", (@{@"candidate": @(candidate), @"bitmapSlot": @(foundBitmapSlot),
             @"nativeArtwork": @(nativeArtwork), @"placeholder": @(placeholder), @"fallback": @(useFallback),
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
    // Even editorial text in an embedded element must not override a card
    // explicitly pointing to a *different* Spotify playlist model.
    BOOL foreignPlaylist = confirmed && cardHasOtherPlaylistURI(card, 0);
    if (foreignPlaylist) confirmed = NO;
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
            @"editorial": @(editorial), @"foreignPlaylist": @(foreignPlaylist),
            @"genericPlaylist": @(genericPlaylist),
            @"confirmed": @(confirmed),
            @"history": @([card.accessibilityIdentifier isEqualToString:@"Components.UI.RecentsListRow"]),
            @"shortcut": @([card.accessibilityIdentifier isEqualToString:@"Shortcut.Card.Home"])
        }));
    }
#endif
    return confirmed;
}
