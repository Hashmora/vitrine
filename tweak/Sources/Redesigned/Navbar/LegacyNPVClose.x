// Keep the legacy mini player docked when a fullscreen NPV swipe is paused
// before the user's finger lifts. The NPV controller lays out as it moves,
// while Spotify's stock tab bar may still be temporarily hidden.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Navbar/Navbar.h"
#import "Shared/Player/PlayerEvents.h"

static void followClosingPlayer(void) {
    if (SGRLegacyTabBarMinimized() && !SGPlayerIsOpen()) SGRLegacyRefreshPlayerDock();
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    SGRPassSwiftController(@"NowPlaying_ScrollImpl", @"NPVScrollViewController", ^(UIViewController *controller) {
        if (controller.viewIfLoaded.window) followClosingPlayer();
    });
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:SGPlayerTransitionNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        if (!SGPlayerIsOpen()) dispatch_async(dispatch_get_main_queue(), ^{ followClosingPlayer(); });
    }];
    [center addObserverForName:SGPlayerTransitionEndedNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        followClosingPlayer();
    }];
}
