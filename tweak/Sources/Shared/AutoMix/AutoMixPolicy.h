// How long the blend between two songs should be, from what is known of the pair. No Spotify, no UIKit: the
// harness (harness/automix/policy_test.m) builds this file alone and checks it on the Mac.
#import <Foundation/Foundation.h>

// Milliseconds of blend for the change from a song `durationSeconds` long into the next one, given the length
// the person chose (`baseMilliseconds`). 0 means no blend (crossfade off, the songs meet gaplessly).
//   episode    either side is a podcast episode or an audiobook chapter: never blended.
//   continues  the next song follows this one on the same album (a live album, a concept album): left gapless.
//   too short  a song under four blend lengths gets a quarter of its length, at least a second.
// `reason` (optional) gets the rule that decided, for the log.
NSInteger SGAutoMixPolicyBlend(double durationSeconds, NSInteger baseMilliseconds, BOOL continues, BOOL episode,
                               NSString **reason);

// Whether `next` follows `current` on one album: the context is that album, or both name the same non-empty album.
BOOL SGAutoMixPolicyContinues(NSString *contextURI, NSString *currentAlbum, NSString *nextAlbum);
