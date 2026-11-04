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

static BOOL has(NSArray<SPTPlayerTrack *> *tracks, SPTPlayerTrack *track) {
    for (SPTPlayerTrack *other in tracks) if (sameTrack(other, track)) return YES;
    return NO;
}

// The DJ's tracks to come as the player last said them, and which of them are put in the queue on the page. The
// player's future holds two tracks in all, the person's hand-queued ones among them, so a track the DJ had sent
// as the second is gone from it when one is queued: this keeps it, until it has played or the DJ's list is another.
static NSArray<SPTPlayerTrack *> *sAhead = @[], *sInjected = @[];
static id sAheadContext;

// The queue's next tracks, then the DJ's tracks to come that are not among them (the person's own, which are in
// both, stay where the queue has them).
static void lineUpTheFuture(id queue, NSString *reader) {
    SPTPlayerState *state = SGPlayerState();
    NSArray<SPTPlayerTrack *> *next = [queue valueForKey:@"nextTracks"];
    NSMutableArray<SPTPlayerTrack *> *future = [NSMutableArray array];
    for (SPTPlayerTrack *track in state.future) if (![track.provider isEqualToString:@"queue"]) [future addObject:track];

    NSMutableArray<SPTPlayerTrack *> *ahead = [sAhead mutableCopy];
    BOOL overlaps = NO;
    for (SPTPlayerTrack *track in future) overlaps = overlaps || has(ahead, track);
    if (![state.contextURI isEqual:sAheadContext] || !overlaps) [ahead removeAllObjects];
    sAheadContext = state.contextURI;
    for (NSUInteger i = 0; i < ahead.count; i++) {
        if ([ahead[i].URI isEqual:state.track.URI]) {
            [ahead removeObjectsInRange:NSMakeRange(0, i + 1)];
            break;
        }
    }
    for (SPTPlayerTrack *track in future) if (!has(ahead, track)) [ahead addObject:track];
    sAhead = ahead;

    NSMutableArray<SPTPlayerTrack *> *merged = next ? [next mutableCopy] : [NSMutableArray array];
    NSMutableArray<SPTPlayerTrack *> *injected = [NSMutableArray array];
    for (SPTPlayerTrack *track in ahead) {
        if (!has(next, track)) {
            [merged addObject:track];
            [injected addObject:track];
        }
    }
    sInjected = injected;
    if (injected.count) [queue setValue:merged forKey:@"nextTracks"];
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

// A tap on one of the tracks put in. The page takes it for a row of the core's queue, which it is not, and gives no
// command; they are the last rows of the table (the DJ has nothing after them), and are skipped to as the player's.
%hook _TtC14Queue_ViewImpl19QueueViewController
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger section = tableView.numberOfSections - 1;
    NSInteger first = [tableView numberOfRowsInSection:section] - (NSInteger)sInjected.count;
    if (sInjected.count && first >= 0 && indexPath.section == section && indexPath.row >= first) {
        SPTPlayerTrack *track = sInjected[indexPath.row - first];
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        SGLog(@"queue page: tap on %@, skipped to", track.trackTitle);
        [(id<SPTPlayer>)SGPlayer() skipToNextTrackWithOptions:nil track:track];
        return;
    }
    %orig;
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC16Queue_UpNextImpl19UpNextTrackProvider", @"_TtC14Queue_ViewImpl22PlayerStateEventSource",
                       @"_TtC14Queue_ViewImpl20QueuedTracksObserver", @"_TtC14Queue_ViewImpl19QueueViewController",
                       @"ESPContextPlayerClientImpl", @"SPTEsperantoPlayer"]);
}
