// Spotify's lower message bar (offline / slow connection / data saver) can
// appear after the legacy compact bar has already settled. Refresh the bar and
// the mini player again on the bar's own layouts so their final geometry follows
// the safe-area change immediately instead of waiting for another gesture.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Navbar/Navbar.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"

static char kPreviousBarGeometry;

static void refreshForMessageBar(UIView *bar) {
    if (!SGBelowiOS26()) return;
    CGRect frame = bar.window ? [bar convertRect:bar.bounds toView:bar.window] : CGRectNull;
    NSValue *previous = objc_getAssociatedObject(bar, &kPreviousBarGeometry);
    if (previous && CGRectEqualToRect(previous.CGRectValue, frame)) return;
    objc_setAssociatedObject(bar, &kPreviousBarGeometry, [NSValue valueWithCGRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // A message bar can appear or disappear without another TabBarView pass.
    dispatch_async(dispatch_get_main_queue(), ^{ SGRLegacyRefreshForMessageBar(); });
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class messageBar = NSClassFromString(@"LimitedExperienceIndicator_MessageBarRuntime.LimitedExperienceIndicatorBar");
    if (messageBar) SGRPassView(messageBar, ^(UIView *v) { refreshForMessageBar(v); });
}
