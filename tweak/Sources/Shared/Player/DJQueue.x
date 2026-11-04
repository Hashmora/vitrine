// The AI DJ's queue on Spotify's own queue page. The DJ's session is one track playing, and the player's queue
// (SPTPlayerQueue, what the page's UpNextTrackProvider is told of in -player:queueDidChange:) holds nothing after
// it, though the player's state knows the two tracks that follow (SPTPlayerState.future, the most it knows of the
// DJ's list). When the queue has no next tracks and the state has some, those are put in the queue before the page
// reads it, so the page draws them as it draws any tracks to come: its rows, its taps, Spotify's.
//
// The queue is logged as the player reports it, for the phone's log.
#import "Core/SGCore.h"
#import "Core/SGLog.h"
#import "PlayerState.h"

%hook _TtC16Queue_UpNextImpl19UpNextTrackProvider
- (void)player:(id)player queueDidChange:(id)queue {
    SPTPlayerState *state = SGPlayerState();
    NSArray *next = [queue valueForKey:@"nextTracks"];
    if (!next.count && state.future.count) [queue setValue:[state.future copy] forKey:@"nextTracks"];
    SGLog(@"queue: context %@, playing %@, %lu next before, %lu now, state's future %lu", SGURIString(state.contextURI),
          state.track.trackTitle, (unsigned long)next.count, (unsigned long)[[queue valueForKey:@"nextTracks"] count],
          (unsigned long)state.future.count);
    %orig;
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC16Queue_UpNextImpl19UpNextTrackProvider"]);
}
