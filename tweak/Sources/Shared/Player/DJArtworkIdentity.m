#import "DJArtworkIdentity.h"
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
static BOOL viewIdentifiesDJ(UIView *view, NSUInteger depth) {
    if (!view || depth > 8) return NO;
    // Accessibility fields are supplied by Spotify, not inferred from art or a
    // user-editable title. Never crawl outside the current card or its children.
    if (containsDJIdentity(view.accessibilityIdentifier) || containsDJIdentity(view.accessibilityLabel) ||
        containsDJIdentity(view.accessibilityValue) ||
        containsDJIdentity(view.accessibilityHint)) return YES;
    for (UIView *child in view.subviews) if (viewIdentifiesDJ(child, depth + 1)) return YES;
    return NO;
}
BOOL SGDJArtworkIsConfirmedCard(UIView *card) {
    if (!card || !djTitle(card.accessibilityLabel)) return NO;
    // Spotify labels its *own* DJ entry as a playlist in some Home/Recents
    // presentations. A generic playlist label must not veto an explicit
    // Spotify DJ URI or an unambiguous assistant identity in this card.
    BOOL confirmed = containsDJIdentity(card.accessibilityLabel) || viewIdentifiesDJ(card, 0);
    BOOL genericPlaylist = playlistLabel(card.accessibilityLabel) && !confirmed;
    // Still fail closed when neither the card nor a descendant identifies the
    // assistant. A user playlist named "DJ" must keep its original artwork.
    SGDJProbeArtworkDecision(confirmed, genericPlaylist);
    return confirmed;
}
