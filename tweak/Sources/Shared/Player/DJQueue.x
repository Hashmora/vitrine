// The AI DJ's queue on Spotify's own queue page. The DJ's session is one track playing, and the player's queue
// (SPTPlayerQueue) holds nothing after it, though the player's state knows the two tracks that follow
// (SPTPlayerState.future, the most it knows of the DJ's list). When the queue has no next tracks and the state has
// some, those are put in the queue before each of its readers takes it, so they draw the tracks as they draw any
// tracks to come: its rows, its taps, Spotify's. The readers are the queue page's own two observers (the page does
// not go through the Up next card's provider) and that provider.
//
// The queue is logged as each reader is told of it, for the phone's log.
#import "Core/SGCore.h"
#import "Core/SGLog.h"
#import "PlayerState.h"

static void lineUpTheFuture(id queue, NSString *reader) {
    SPTPlayerState *state = SGPlayerState();
    NSUInteger before = [[queue valueForKey:@"nextTracks"] count];
    if (!before && state.future.count) [queue setValue:[state.future copy] forKey:@"nextTracks"];
    SGLog(@"queue (%@): context %@, playing %@, %lu next before, %lu now, state's future %lu", reader, SGURIString(state.contextURI),
          state.track.trackTitle, (unsigned long)before, (unsigned long)[[queue valueForKey:@"nextTracks"] count],
          (unsigned long)state.future.count);
}

%hook _TtC16Queue_UpNextImpl19UpNextTrackProvider
- (void)player:(id)player queueDidChange:(id)queue {
    lineUpTheFuture(queue, @"up next card");
    %orig;
}
%end

%hook _TtC14Queue_ViewImpl22PlayerStateEventSource
- (void)player:(id)player queueDidChange:(id)queue {
    lineUpTheFuture(queue, @"page state");
    %orig;
}
%end

%hook _TtC14Queue_ViewImpl20QueuedTracksObserver
- (void)player:(id)player queueDidChange:(id)queue {
    lineUpTheFuture(queue, @"page queued");
    %orig;
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC16Queue_UpNextImpl19UpNextTrackProvider", @"_TtC14Queue_ViewImpl22PlayerStateEventSource",
                       @"_TtC14Queue_ViewImpl20QueuedTracksObserver"]);
}
