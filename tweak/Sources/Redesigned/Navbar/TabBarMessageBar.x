// Spotify's lower message bar (offline / slow connection / data saver) can
// appear after the legacy compact bar has already settled. Refresh the bar and
// the mini player again on the bar's own layouts so their final geometry follows
// the safe-area change immediately instead of waiting for another gesture.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Navbar/Navbar.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"

static void refreshForMessageBar(UIView *bar) {
    if (!bar.window || !SGBelowiOS26()) return;
    SGRRefreshTabBar();
    dispatch_async(dispatch_get_main_queue(), ^{
        SGRRefreshTabBar();
        SGRNowPlayingBarFollowTabBar();
    });
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class messageBar = NSClassFromString(@"LimitedExperienceIndicator_MessageBarRuntime.LimitedExperienceIndicatorBar");
    if (messageBar) SGRPassView(messageBar, ^(UIView *v) { refreshForMessageBar(v); });
}
