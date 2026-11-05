// The AI DJ's queue on Spotify's own queue page. The DJ's session is one track playing, and the player's queue
// (SPTPlayerQueue) holds nothing of the DJ's after it, though the player's state knows the tracks that follow
// (SPTPlayerState.future: the DJ's segment, five tracks and the voice between them). Those are put in the queue
// before each of its readers takes it, after the hand-queued tracks and in the DJ's order, so they draw the tracks
// as they draw any tracks to come: its rows, Spotify's. The readers are the queue page's own two observers (the page
// does not go through the Up next card's provider) and that provider.
//
// The player's subscription asks the core for the state with a cap on the tracks to come
// (ESPGetStateRequest.nextTracksCap), two at first; it is raised here so the state's future is the whole segment.
// The core gives no more than that: the next segment is made when the last track of this one is reached.
//
// Between two segments the core has no tracks to come for a moment; the rows the page had stay for it (up to
// kGapSeconds) instead of going empty.
//
// The core keeps ten tracks behind the DJ's current one. The tracks the DJ has played are kept here whole (uri, uid,
// metadata), and a step back with none left behind in the state asks the core to skip to the one before the current
// by its uid, in the same session; if the core does not move, it is not asked again in that session.
//
// The page takes a tap on one of the tracks for a row of the core's queue, which it is not, and gives no command; it
// is skipped to as the player's here.
#import "Core/SGCore.h"
#import "Core/SGLog.h"
#import "PlayerState.h"

static BOOL sameTrack(SPTPlayerTrack *a, SPTPlayerTrack *b) {
    return [a.URI isEqual:b.URI] && [a.provider isEqualToString:b.provider];
}

static NSUInteger indexIn(NSArray<SPTPlayerTrack *> *tracks, SPTPlayerTrack *track) {
    for (NSUInteger i = 0; i < tracks.count; i++) if (sameTrack(tracks[i], track)) return i;
    return NSNotFound;
}

// The DJ's tracks to come as last made up (what the player said, then what was kept after it), what the queue is
// as it is put to the readers, and which of its tracks are the ones put in.
static NSArray<SPTPlayerTrack *> *sAhead = @[], *sQueue = @[], *sInjected = @[];
static id sAheadContext;

// What the DJ's pages need: three segments of five and the narration between them, with room for the hand-queued.
static const int64_t kFutureCap = 80;
// How long the page keeps its rows while the core has no tracks to come.
static const NSTimeInterval kGapSeconds = 3;
// How long the core has to move to a track it was asked to skip back to.
static const NSTimeInterval kJumpSeconds = 1.5;

// A track of the DJ's to come: not the narration, a page marker or the delimiter that ends the pages.
static BOOL isDJTrack(SPTPlayerTrack *track) {
    NSString *uri = SGURIString(track.URI);
    return [uri hasPrefix:@"spotify:track:"] || [uri hasPrefix:@"spotify:episode:"];
}

// The tracks the DJ has to come in the state's future: they end at the delimiter, after which the core puts the whole
// session again as hidden stand-ins, and a track the list has already named is such a stand-in too.
static NSArray<SPTPlayerTrack *> *djFuture(NSArray<SPTPlayerTrack *> *future) {
    NSMutableArray<SPTPlayerTrack *> *tracks = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (SPTPlayerTrack *track in future) {
        if ([track.provider isEqualToString:@"queue"]) continue;
        if ([SGURIString(track.URI) isEqualToString:@"spotify:delimiter"]) break;
        if (!isDJTrack(track)) continue;
        if (track.UID.length) {
            if ([seen containsObject:track.UID]) break;
            [seen addObject:track.UID];
        }
        [tracks addObject:track];
    }
    return tracks;
}

// Whether the track is the DJ's: its metadata names the session's page.
static BOOL inDJ(SPTPlayerTrack *track) {
    return track.metadata[@"page_instance_id"] != nil;
}

// When the core began to have no tracks to come, nil while it has some.
static NSDate *sGapSince;

// Puts the DJ's tracks to come in `queue`. YES when the readers are to be left as they are: the core has none to come
// just now, and the rows the page had stay.
static BOOL lineUpTheFuture(id queue) {
    SPTPlayerState *state = SGPlayerState();
    NSArray<SPTPlayerTrack *> *next = [queue valueForKey:@"nextTracks"];
    NSArray<SPTPlayerTrack *> *future = djFuture(state.future);

    // The state's own, then what was kept after its last one. When hand-queued tracks fill the state's two it names
    // none of the DJ's, and what was kept stands. A list that does not go on from the kept one is the DJ's new.
    NSMutableArray<SPTPlayerTrack *> *ahead = [future mutableCopy];
    if ([state.contextURI isEqual:sAheadContext]) {
        if (!future.count) {
            [ahead addObjectsFromArray:sAhead];
        } else {
            NSUInteger at = indexIn(sAhead, future.lastObject);
            if (at != NSNotFound) [ahead addObjectsFromArray:[sAhead subarrayWithRange:NSMakeRange(at + 1, sAhead.count - at - 1)]];
        }
    }
    for (NSUInteger i = 0; i < ahead.count; i++) {
        if ([ahead[i].URI isEqual:state.track.URI]) {
            [ahead removeObjectsInRange:NSMakeRange(0, i + 1)];
            break;
        }
    }
    sAheadContext = state.contextURI;
    sAhead = ahead;

    // The hand-queued tracks, the DJ's, then whatever else the queue had.
    NSMutableArray<SPTPlayerTrack *> *queued = [NSMutableArray array], *rest = [NSMutableArray array], *injected = [NSMutableArray array];
    for (SPTPlayerTrack *track in next) {
        if ([track.provider isEqualToString:@"queue"]) [queued addObject:track];
        else if (indexIn(ahead, track) == NSNotFound) [rest addObject:track];
    }
    for (SPTPlayerTrack *track in ahead) if (indexIn(next, track) == NSNotFound) [injected addObject:track];
    NSMutableArray<SPTPlayerTrack *> *merged = [queued mutableCopy];
    [merged addObjectsFromArray:ahead];
    [merged addObjectsFromArray:rest];

    if (merged.count) {
        sGapSince = nil;
    } else if (sQueue.count && inDJ(state.track)) {
        if (!sGapSince) sGapSince = [NSDate date];
        if (-sGapSince.timeIntervalSinceNow < kGapSeconds) return YES;
    }
    sQueue = merged;
    sInjected = injected;
    if (injected.count) [queue setValue:merged forKey:@"nextTracks"];
    return NO;
}

%hook _TtC16Queue_UpNextImpl19UpNextTrackProvider
- (void)player:(id)player queueDidChange:(id)queue {
    if (lineUpTheFuture(queue)) return;
    %orig;
}
%end

%hook _TtC14Queue_ViewImpl22PlayerStateEventSource
- (void)player:(id)player queueDidChange:(id)queue {
    if (lineUpTheFuture(queue)) return;
    %orig;
}
%end

%hook _TtC14Queue_ViewImpl20QueuedTracksObserver
- (void)player:(id)player queueDidChange:(id)queue {
    if (lineUpTheFuture(queue)) return;
    %orig;
}
%end

%hook ESPContextPlayerClientImpl
// The state request the player's subscription makes of the core carries caps on the tracks before and after the current
// one. The future's cap is raised before the request goes.
- (void)getState:(id)request onResponse:(id)onResponse {
    Class requestClass = NSClassFromString(@"ESPGetStateRequest"), optional = NSClassFromString(@"ESPOptionalInt64");
    if (requestClass && optional && [request isKindOfClass:requestClass]) {
        long long was = [[[request valueForKey:@"nextTracksCap"] valueForKey:@"value"] longLongValue];
        if (was < kFutureCap) {
            id cap = [[optional alloc] init];
            [cap setValue:@(kFutureCap) forKey:@"value"];
            [request setValue:cap forKey:@"nextTracksCap"];
            SGLog(@"queue: next tracks cap %lld raised to %lld", was, (long long)kFutureCap);
        }
    }
    %orig;
}
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

// The DJ's tracks as they have played, in the session's order, whole, for the steps back the core has no track for.
static NSMutableArray<SPTPlayerTrack *> *sPlayed;
static id sPlayedContext;
// Set once the core did not move to a track it was asked to skip back to; no more asks in that session.
static BOOL sJumpRefused;

@interface SGDJHistory : NSObject <SGPlayerStateObserver>
@end

@implementation SGDJHistory
- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (![state.contextURI isEqual:sPlayedContext]) {
        sPlayedContext = state.contextURI;
        sPlayed = [NSMutableArray array];
        sJumpRefused = NO;
    }
    SPTPlayerTrack *track = state.track;
    if (!isDJTrack(track) || !inDJ(track) || !track.UID.length) return;
    for (SPTPlayerTrack *played in sPlayed) if ([played.UID isEqualToString:track.UID]) return;
    [sPlayed addObject:track];
}
@end

// The track the DJ played before the one the player is on (or is introducing: the voice has its song's uid), nil
// when none was kept.
static SPTPlayerTrack *playedBefore(SPTPlayerState *state) {
    NSUInteger at = sPlayed.count;
    for (NSUInteger i = 0; i < sPlayed.count; i++) {
        if ([sPlayed[i].UID isEqualToString:state.track.UID]) { at = i; break; }
    }
    return at > 0 ? sPlayed[at - 1] : nil;
}

%hook SPTEsperantoPlayer
// Every step back of Spotify's ends here, `track` nil for the plain one. With nothing behind the current track in
// the state, the core has run out of the ten it keeps, and the one the DJ played before is asked for by its uid.
- (id)skipToPreviousTrackWithOptions:(id)options track:(SPTPlayerTrack *)track loggingParams:(id)params {
    SPTPlayerState *state = SGPlayerState();
    SPTPlayerTrack *target = track || sJumpRefused || state.reverse.count || !inDJ(state.track) ? nil : playedBefore(state);
    if (!target) return %orig;
    NSString *was = state.track.UID;
    SGLog(@"queue: step back past the core's ten, to %@ [%@]", target.trackTitle, target.UID);
    id result = %orig(options, target, params);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kJumpSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![SGPlayerState().track.UID isEqualToString:was]) {
            SGLog(@"queue: the core went back to %@", SGPlayerState().track.trackTitle);
            return;
        }
        sJumpRefused = YES;
        SGLog(@"queue: the core did not go back to %@, the plain step back instead", target.trackTitle);
        [(id<SPTPlayer>)SGPlayer() skipToPreviousTrackWithOptions:options];
    });
    return result;
}
%end

// The table's rows are the queue's tracks in order, over its sections (the hand-queued ones, the DJ's, an empty
// one), so a row's place in the table is its track's in the queue.
%hook _TtC14Queue_ViewImpl19QueueViewController
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger place = indexPath.row;
    for (NSInteger section = 0; section < indexPath.section; section++) place += [tableView numberOfRowsInSection:section];
    SPTPlayerTrack *track = place < (NSInteger)sQueue.count ? sQueue[place] : nil;
    SGLog(@"queue page: tap on section %ld row %ld, place %ld of %lu: %@", (long)indexPath.section, (long)indexPath.row, (long)place,
          (unsigned long)sQueue.count, track.trackTitle);
    if (track && indexIn(sInjected, track) != NSNotFound) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [(id<SPTPlayer>)SGPlayer() skipToNextTrackWithOptions:nil track:track];
        return;
    }
    %orig;
}
%end

// The reason of an exception nothing catches: Spotify's crash reporter keeps it out of the .ips, so it goes to the
// phone's log before the app aborts.
static NSUncaughtExceptionHandler *sPreviousHandler;
static void logUncaught(NSException *exception) {
    NSArray<NSString *> *stack = exception.callStackSymbols;
    SGLog(@"uncaught exception %@: %@", exception.name, exception.reason);
    for (NSUInteger i = 0; i < stack.count && i < 14; i++) SGLog(@"uncaught exception frame %lu: %@", (unsigned long)i, stack[i]);
    if (sPreviousHandler) sPreviousHandler(exception);
}

static void installExceptionLog(void) {
    if (NSGetUncaughtExceptionHandler() == &logUncaught) return;
    sPreviousHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&logUncaught);
}

%ctor {
    %init;
    installExceptionLog();
    static SGDJHistory *history;
    history = [[SGDJHistory alloc] init];
    SGAddPlayerStateObserver(history);
    // Crash reporters set their handler at launch; the log goes in front of whichever is last.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ installExceptionLog(); });
    SGRequireClasses(@[@"_TtC16Queue_UpNextImpl19UpNextTrackProvider", @"_TtC14Queue_ViewImpl22PlayerStateEventSource",
                       @"_TtC14Queue_ViewImpl20QueuedTracksObserver", @"_TtC14Queue_ViewImpl19QueueViewController",
                       @"ESPContextPlayerClientImpl", @"SPTEsperantoPlayer"]);
}
