// The AI DJ's queue on Spotify's own queue page. The page shows the DJ's session as the one track playing; the
// player's queue (SPTPlayerQueue, what the page's UpNextTrackProvider is told of in -player:queueDidChange:) is
// not that short, and a track the person adds by hand is in it. What the page leaves out it may leave out on
// the player's word, SPTPlayerRestrictions.disallowViewingQueue, so that is answered no and the page draws the
// queue as it does for any playlist, its rows, its reordering and its taps Spotify's.
//
// What the player and the page say is logged on every change of the queue, for the phone's log: it is how to
// tell whether the page took the restriction as the reason, or the player's queue itself holds only the track
// playing (then the DJ's own list of tracks to come is the next thing to look for).
#import "Core/SGCore.h"
#import "Core/SGLog.h"
#import "PlayerState.h"

%hook SPTPlayerRestrictions
- (BOOL)disallowViewingQueue {
    return NO;
}
- (NSSet *)disallowViewingQueueReasons {
    return [NSSet set];
}
%end

static NSString *titles(NSArray *tracks) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (SPTPlayerTrack *track in tracks) [out addObject:[NSString stringWithFormat:@"%@ [%@]", track.trackTitle, track.provider]];
    return [out componentsJoinedByString:@"; "];
}

%hook _TtC16Queue_UpNextImpl19UpNextTrackProvider
- (void)player:(id)player queueDidChange:(id)queue {
    SPTPlayerState *state = SGPlayerState();
    NSArray *next = [queue valueForKey:@"nextTracks"], *previous = [queue valueForKey:@"prevTracks"];
    SGLog(@"queue: context %@, playing %@, %lu next (%@), %lu before, state's future %lu (%@)", SGURIString(state.contextURI),
          state.track.trackTitle, (unsigned long)next.count, titles(next), (unsigned long)previous.count,
          (unsigned long)state.future.count, titles(state.future));
    %orig;
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"SPTPlayerRestrictions", @"_TtC16Queue_UpNextImpl19UpNextTrackProvider"]);
}
