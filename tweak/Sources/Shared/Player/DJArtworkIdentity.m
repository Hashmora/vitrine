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
        ((cache.card && [holder isDescendantOfView:cache.card]) ||
         (!cache.card && now - cache.checkedAt < 0.25))) return cache.card;
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

// This is a short-lived state of one Encore image holder, never a global
// decision that every playlist called DJ is Spotify's DJ.
@interface SGDJArtworkPlaceholderState : NSObject
@property (nonatomic, weak) UIView *card;
@property (nonatomic, weak) UIImage *nativeImage;
@property (nonatomic) CFAbsoluteTime firstMissing;
@property (nonatomic) BOOL fallbackActive;
@end
@implementation SGDJArtworkPlaceholderState
@end
static char kMissingArtStateKey;
#if SG_DRIVER
static char kArtworkProbeSignature, kMissingArtProbeKey;
#endif

// Keep the source bitmap's identity, not just the fact that UIImageView.image
// is non-nil: Encore can hide its placeholder view while leaving the same
// temporary bitmap in the image slot. This must not erase our overlay.
static void sgScanArt(UIView *view, NSUInteger depth, UIImage **image, BOOL *placeholder) {
    if (!view || depth > 4) return;
    if ([view.accessibilityIdentifier hasPrefix:@"SG.DJArtwork"] ||
        [view.accessibilityIdentifier hasPrefix:@"SGR.DJArtwork"]) return;
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"Placeholder"] && !view.hidden && view.alpha > 0.01)
        *placeholder = YES;
    if ([view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image &&
        !view.hidden && view.alpha > 0.01 && !*image) *image = ((UIImageView *)view).image;
    for (UIView *sub in view.subviews) sgScanArt(sub, depth + 1, image, placeholder);
}

// Spotify 9.1.90 presents some DJ cards with an accessible "DJ, Playlist"
// label and no exposed model URI. For that ambiguous case, fall back only if
// the native art was actually unresolved for 0.8 s. If Encore then removes
// its PlaceholderView but keeps the *same* temporary UIImage, retain the
// overlay. Drop it when a different source image arrives (or the card is
// reused), so a user playlist's eventual cover takes precedence.
// A playlist named DJ with permanently absent artwork remains ambiguous.
BOOL SGDJArtworkNeedsPlaceholder(UIView *card, UIView *holder, BOOL *retry) {
    if (retry) *retry = NO;
    if (!holder) return NO;
    BOOL candidate = card && djTitle(card.accessibilityLabel) &&
        ([card.accessibilityIdentifier isEqualToString:@"Components.UI.RecentsListRow"] ||
         [card.accessibilityIdentifier isEqualToString:@"Components.UI.HomeCard"] ||
         [card.accessibilityIdentifier isEqualToString:@"Shortcut.Card.Home"]);
    SGDJArtworkPlaceholderState *state = objc_getAssociatedObject(holder, &kMissingArtStateKey);
    if (!candidate) {
        if (state) objc_setAssociatedObject(holder, &kMissingArtStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return NO;
    }
    if (!state || state.card != card) {
        state = [SGDJArtworkPlaceholderState new];
        state.card = card;
        objc_setAssociatedObject(holder, &kMissingArtStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIImage *nativeImage = nil;
    BOOL placeholder = NO;
    sgScanArt(holder, 0, &nativeImage, &placeholder);
    BOOL missing = !nativeImage || placeholder;
    // The image pointer is weakly observed: Spotify owns its lifecycle.
    // A different bitmap without PlaceholderView means Spotify resolved art.
    BOOL unchangedTemporary = !missing && state.firstMissing > 0 &&
        nativeImage == state.nativeImage && nativeImage != nil;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (missing) {
        if (state.firstMissing <= 0) {
            state.firstMissing = now;
            state.nativeImage = nativeImage;
            if (retry) *retry = YES;
        }
    } else if (!unchangedTemporary) {
        state.firstMissing = 0;
        state.fallbackActive = NO;
        state.nativeImage = nil;
    }
    // The 0.8 s grace period continues if Encore hides its placeholder but
    // leaves the same bitmap in place. Do not reset it on that transient swap.
    if (state.firstMissing > 0 && now - state.firstMissing >= 0.8 &&
        (missing || unchangedTemporary)) state.fallbackActive = YES;
    BOOL held = unchangedTemporary && state.fallbackActive;
    BOOL useFallback = state.fallbackActive && (missing || unchangedTemporary);
#if SG_DRIVER
    NSString *signature = [NSString stringWithFormat:@"%d-%d-%d-%d-%d", candidate,
                           !!nativeImage, placeholder, useFallback, held];
    if (![objc_getAssociatedObject(holder, &kMissingArtProbeKey) isEqualToString:signature]) {
        objc_setAssociatedObject(holder, &kMissingArtProbeKey, signature, OBJC_ASSOCIATION_COPY_NONATOMIC);
        SGDJ_TRACE(@"artwork.placeholder", (@{ @"candidate": @(candidate),
             @"nativeArtwork": @(!!nativeImage), @"placeholder": @(placeholder),
             @"fallback": @(useFallback), @"held": @(held),
             @"holderSlot": @((unsigned long)(SGDJProbeTag([NSString stringWithFormat:@"%p", holder]).hash % 100000)),
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

#if SG_DRIVER
static char kArtworkPaintProbeKey;
void SGDJArtworkTracePaint(UIView *holder, UIImageView *overlay, UIView *card,
                           BOOL requested, BOOL coverReady, BOOL redesigned) {
    // Trace only DJ-titled rows, without titles or Spotify URI values.
    if (!holder || !card || !djTitle(card.accessibilityLabel)) return;
    BOOL attached = overlay && overlay.superview == holder;
    BOOL drawn = attached && overlay.image && !overlay.hidden && overlay.alpha > 0.01;
    BOOL front = attached && holder.subviews.lastObject == overlay;
    BOOL onWindow = !!holder.window;
    BOOL visible = drawn && front && onWindow;
    if (visible) {
        for (UIView *view = holder; view; view = view.superview) {
            if (view.hidden || view.alpha <= 0.01) { visible = NO; break; }
        }
        if (visible) {
            CGRect boundsInWindow = [holder convertRect:holder.bounds toView:holder.window];
            visible = boundsInWindow.size.width >= 4 && boundsInWindow.size.height >= 4 &&
                CGRectIntersectsRect(boundsInWindow, holder.window.bounds);
        }
    }
    NSUInteger width = (NSUInteger)MAX(0, holder.bounds.size.width);
    NSUInteger height = (NSUInteger)MAX(0, holder.bounds.size.height);
    NSString *signature = [NSString stringWithFormat:@"%p-%d-%d-%d-%d-%d-%d-%lu-%lu",
        card, requested, coverReady, drawn, front, onWindow, visible,
        (unsigned long)width, (unsigned long)height];
    if ([objc_getAssociatedObject(holder, &kArtworkPaintProbeKey) isEqualToString:signature]) return;
    objc_setAssociatedObject(holder, &kArtworkPaintProbeKey, signature, OBJC_ASSOCIATION_COPY_NONATOMIC);
    SGDJ_TRACE(@"artwork.draw", (@{
        @"outcome": @YES,
        @"holderSlot": @((unsigned long)(SGDJProbeTag([NSString stringWithFormat:@"%p", holder]).hash % 100000)),
        @"requested": @(requested), @"coverReady": @(coverReady),
        @"drawn": @(drawn), @"front": @(front), @"onWindow": @(onWindow),
        @"visible": @(visible), @"width": @(width), @"height": @(height),
        @"history": @([card.accessibilityIdentifier isEqualToString:@"Components.UI.RecentsListRow"]),
        @"redesigned": @(redesigned)
    }));
}
#endif
