// Identify the actual Spotify AI DJ card, not a user playlist called "DJ".
#import <UIKit/UIKit.h>
BOOL SGDJArtworkIsConfirmedCard(UIView *card);

// A conservative fallback for a Spotify 9.1.90 DJ tile whose native artwork
// remains unresolved. Delay the override for 0.8 s, tolerate temporary removal
// of Encore's placeholder without a source-image change, and remove the
// override when Spotify supplies a new native image or reuses the cell.
// A playlist named DJ with permanently missing art remains ambiguous without
// its model URI, and must be checked before merging.
// *retry requests one delayed redraw on first observation.
BOOL SGDJArtworkNeedsPlaceholder(UIView *card, UIView *holder, BOOL *retry);

// Cache the nearest Home/Recents card, invalidating it when the image holder
// moves under a different card even if the immediate parent stays unchanged.
UIView *SGDJArtworkEnclosingCard(UIView *holder);

// Read-only, redacted overlay geometry probe, compiled out of release builds.
#if SG_DRIVER
void SGDJArtworkTracePaint(UIView *holder, UIImageView *overlay, UIView *card,
                           BOOL requested, BOOL coverReady, BOOL redesigned);
#else
#define SGDJArtworkTracePaint(holder, overlay, card, requested, coverReady, redesigned) do {} while (0)
#endif
