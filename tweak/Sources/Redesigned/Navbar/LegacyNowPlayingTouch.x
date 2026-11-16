// Only the iOS < 26 redesigned tab bar: remember a touch that started on
// the mini player while another finger scrolls a page. Detect this from
// UIWindow's existing touch events rather than adding a competing gesture
// recognizer to Spotify's player (which would steal its taps and swipes).
#import "Core/SGCore.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"
#import "Navbar.h"

static NSHashTable<UITouch *> *sg_playerTouches;

BOOL SGRLegacyNowPlayingHeld(void) {
    return sg_playerTouches.count != 0;
}

%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        if (!sg_playerTouches) sg_playerTouches = [NSHashTable weakObjectsHashTable];
        CGRect player = SGRNowPlayingCardFrameIn((UIView *)self, NULL);
        for (UITouch *touch in event.allTouches) {
            if (touch.window != (UIWindow *)self) continue;
            if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                [sg_playerTouches removeObject:touch];
            } else if (touch.phase == UITouchPhaseBegan && !CGRectIsNull(player) &&
                       CGRectContainsPoint(player, [touch locationInView:(UIView *)self])) {
                [sg_playerTouches addObject:touch];
            }
        }
    }
    %orig;
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    %init;
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
                                                     object:nil queue:nil usingBlock:^(NSNotification *note) {
        [sg_playerTouches removeAllObjects];
    }];
}
