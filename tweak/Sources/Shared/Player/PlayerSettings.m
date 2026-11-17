// The player's settings that do not depend on the look: the lock screen widget's flags.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "PlayerSettings.h"
#import "DJQueue.h"
#import "DJPick.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/Lyrics/Lyrics.h"

// Widget first: the line in place of the artist (on the Lyrics page too, the same switch) and Like and dislike,
// the one lock screen control a song gets, which the Artwork section's star takes the place of
// (Shared/AnimatedArtwork/LockScreenStar.x locks the flag off). Spotify's flags for podcasts, audiobooks and its
// own lock screen artwork stay on the All flags page: the Artwork section is the mod's.
UIViewController *SGLockScreenWidgetPage(void) {
    SGModRow *likes = SGFlagRow(@"Like and dislike buttons", @"ios-feature-lockscreen.like_dislike_enabled");
    likes.subtitle = @"Off and locked while Switch with the star is on: the star takes their place";
    return [[SGModPage alloc] initWithTitle:@"Lock screen" intro:SGRestartNote sections:@[
        SGSection(@"Widget", @[SGLockScreenLyricsRow(), SGLockScreenTranslationRow(), likes]),
        SGSection(@"Artwork", SGLockScreenMotionRows()),
    ] footer:nil];
}

SGModSection *SGDJSettingsSection(void) {
    return SGNotedSection(@"DJ", @[
        SGSwitchRow(@"DJ queue", @"The DJ's next songs in the queue", SGKeyDJQueue),
        SGSwitchRow(@"New DJ set button", @"Show the button in the DJ queue", SGKeyDJQueuePickButton),
        SGSwitchRow(@"Neutral request fallback", @"For New DJ set and Let DJ pick", SGKeyDJPickFallback),
    ], @"DJ queue shows the songs the DJ has picked next, where you can reorder and remove them. Its switch applies after restarting Spotify. "
       @"The button and fallback switches apply immediately. If Pick does not advance within 6 seconds, fallback sends this English request once: "
       @"“Surprise me with a new mix based on my taste.” It also applies to the native Let DJ pick button, even when the queue button is hidden.");
}
