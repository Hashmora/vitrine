// The AI DJ's queue on Spotify's own queue page. The DJ's session is one track playing, and the player's queue
// (SPTPlayerQueue) holds nothing after it, though the player's state knows the two tracks that follow
// (SPTPlayerState.future, the most it knows of the DJ's list). When the queue has no next tracks and the state has
// some, those are put in the queue before each of its readers takes it, so they draw the tracks as they draw any
// tracks to come: its rows, its taps, Spotify's. The readers are the queue page's own two observers (the page does
// not go through the Up next card's provider) and that provider.
//
// The queue is logged as each reader is told of it, and so are the commands the page gives the player (what a
// tap, a swipe and a removal on a row come to), for the phone's log: the tracks put in are the state's, not the
// core's queue's, so the page's commands on them may not be ones the core takes.
#import "Core/SGCore.h"
#import "Core/SGLog.h"
#import "PlayerState.h"

static BOOL sameTrack(SPTPlayerTrack *a, SPTPlayerTrack *b) {
    return [a.URI isEqual:b.URI] && [a.provider isEqualToString:b.provider];
}

// The queue's next tracks, then the state's future tracks that are not among them (the person's own, which are in
// both, stay where the queue has them).
static void lineUpTheFuture(id queue, NSString *reader) {
    SPTPlayerState *state = SGPlayerState();
    NSArray<SPTPlayerTrack *> *next = [queue valueForKey:@"nextTracks"];
    NSMutableArray<SPTPlayerTrack *> *merged = next ? [next mutableCopy] : [NSMutableArray array];
    for (SPTPlayerTrack *track in state.future) {
        BOOL known = NO;
        for (SPTPlayerTrack *queued in next) known = known || sameTrack(queued, track);
        if (!known) [merged addObject:track];
    }
    if (merged.count > next.count) [queue setValue:merged forKey:@"nextTracks"];
    SGLog(@"queue (%@): context %@, playing %@, %lu next before, %lu now, state's future %lu", reader, SGURIString(state.contextURI),
          state.track.trackTitle, (unsigned long)next.count, (unsigned long)merged.count, (unsigned long)state.future.count);
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

%hook ESPContextPlayerClientImpl
- (void)addToQueue:(id)request onResponse:(id)onResponse {
    SGLog(@"queue command: addToQueue %@", request);
    %orig;
}
- (void)setQueue:(id)request onResponse:(id)onResponse {
    SGLog(@"queue command: setQueue %@", request);
    %orig;
}
- (void)playAsNextInQueue:(id)request onResponse:(id)onResponse {
    SGLog(@"queue command: playAsNextInQueue %@", request);
    %orig;
}
%end

%hook SPTEsperantoPlayer
- (id)skipToNextTrackWithOptions:(id)options track:(SPTPlayerTrack *)track {
    SGLog(@"queue command: skip to %@ [%@]", track.trackTitle, track.provider);
    return %orig;
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC16Queue_UpNextImpl19UpNextTrackProvider", @"_TtC14Queue_ViewImpl22PlayerStateEventSource",
                       @"_TtC14Queue_ViewImpl20QueuedTracksObserver", @"ESPContextPlayerClientImpl",
                       @"SPTEsperantoPlayer"]);
}
