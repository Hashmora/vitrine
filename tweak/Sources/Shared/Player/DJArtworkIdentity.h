// Identify the actual Spotify AI DJ card, not a user playlist called "DJ".
#import <UIKit/UIKit.h>
BOOL SGDJArtworkIsConfirmedCard(UIView *card);

// A conservative fallback for the Spotify 9.1.90 DJ tile whose artwork is
// absent from the native Encore image view. Never replace an existing bitmap.
// Returns YES only after the same card has kept its placeholder for 0.8 s.
// *retry requests one delayed redraw while a placeholder is first observed.
BOOL SGDJArtworkNeedsPlaceholder(UIView *card, UIView *holder, BOOL *retry);
