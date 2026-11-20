// Identify the actual Spotify AI DJ card, not a user playlist called "DJ".
#import <UIKit/UIKit.h>
BOOL SGDJArtworkIsConfirmedCard(UIView *card);

// Conservative fallback for an unresolved Spotify DJ cover: never override
// an existing native bitmap (UIImageView or layer contents), even while Encore
// keeps PlaceholderView mounted. An artless user playlist called DJ remains
// ambiguous until its model URI is available. *retry requests one redraw.
BOOL SGDJArtworkNeedsPlaceholder(UIView *card, UIView *holder, BOOL *retry);

// Cache the nearest Home/Recents card, invalidating it when the image holder
// moves under a different card even if the immediate parent stays unchanged.
UIView *SGDJArtworkEnclosingCard(UIView *holder);
