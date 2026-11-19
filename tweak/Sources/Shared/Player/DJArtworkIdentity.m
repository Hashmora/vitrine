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
#if SG_DRIVER
static char kArtworkProbeSignature;
#endif
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
