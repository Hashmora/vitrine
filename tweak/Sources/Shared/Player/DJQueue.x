// The AI DJ's queue on Spotify's own queue page. The DJ's session is one track playing, and the player's queue
// (SPTPlayerQueue) holds nothing of the DJ's after it, though the player's state knows the tracks that follow
// (SPTPlayerState.future: two in all, the person's hand-queued ones among them). Those, and the DJ's tracks that
// the state has said before and now has no room for, are put in the queue before each of its readers takes it,
// after the hand-queued tracks and in the DJ's order, so they draw the tracks as they draw any tracks to come:
// its rows, Spotify's. The readers are the queue page's own two observers (the page does not go through the Up
// next card's provider) and that provider.
//
// The two is the request's, not the core's: the player's subscription asks the core for the state with a cap on the
// tracks to come (ESPGetStateRequest.nextTracksCap), so the state's future is as long as that. It is raised here to what
// the core keeps ahead of the DJ, and the copy of the session that follows the DJ's last page is cut off.
//
// The page takes a tap on one of them for a row of the core's queue, which it is not, and gives no command; it is
// skipped to as the player's here. The queue is logged as each reader is told of it, and so are the commands the
// page gives the player, for the phone's log.
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

// What the state's future is made of, for the phone's log, when it changes: each entry's place, URI, provider and
// UID, the metadata keys that tell what it is (hidden, delimiter, page, segment), and every list in the state's own
// dictionary with its length, to see where the core stops giving tracks.
static void dumpFuture(SPTPlayerState *state) {
    static NSString *last;
    NSMutableString *signature = [NSMutableString string];
    for (SPTPlayerTrack *track in state.future) [signature appendFormat:@"%@|", track.UID];
    if ([signature isEqualToString:last]) return;
    last = [signature copy];
    NSArray<NSString *> *words = @[@"hidden", @"delimiter", @"page", @"segment", @"iteration", @"advancing", @"image", @"title", @"artist_name"];
    NSUInteger place = 0;
    for (SPTPlayerTrack *track in state.future) {
        NSMutableArray<NSString *> *flags = [NSMutableArray array];
        for (NSString *key in track.metadata) {
            for (NSString *word in words) {
                if ([key rangeOfString:word options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    [flags addObject:[NSString stringWithFormat:@"%@=%@", key, track.metadata[key]]];
                    break;
                }
            }
        }
        SGLog(@"future[%lu] %@ [%@] uid %@ %@", (unsigned long)place++, SGURIString(track.URI), track.provider, track.UID,
              [flags componentsJoinedByString:@" "]);
    }
    id dictionary = [state valueForKey:@"dictionary"];
    if ([dictionary isKindOfClass:[NSDictionary class]]) {
        NSMutableArray<NSString *> *lists = [NSMutableArray array];
        for (NSString *key in dictionary) {
            id value = dictionary[key];
            if ([value isKindOfClass:[NSArray class]]) [lists addObject:[NSString stringWithFormat:@"%@:%lu", key, (unsigned long)[value count]]];
        }
        SGLog(@"state dictionary: %lu keys, lists %@", (unsigned long)[dictionary count], [lists componentsJoinedByString:@" "]);
    }
}

static void lineUpTheFuture(id queue, NSString *reader) {
    SPTPlayerState *state = SGPlayerState();
    NSArray<SPTPlayerTrack *> *next = [queue valueForKey:@"nextTracks"];
    dumpFuture(state);
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
    sQueue = merged;
    sInjected = injected;
    if (injected.count) [queue setValue:merged forKey:@"nextTracks"];
    SGLog(@"queue (%@): context %@, playing %@, %lu next before, %lu now, state's future %lu", reader, SGURIString(state.contextURI),
          state.track.trackTitle, (unsigned long)next.count, (unsigned long)merged.count, (unsigned long)state.future.count);
    SGLog(@"queue (%@): future %lu raw, %lu of the DJ's, ahead %lu, first uid %@, last uid %@, current %@ uid %@", reader,
          (unsigned long)state.future.count, (unsigned long)future.count, (unsigned long)ahead.count, future.firstObject.UID,
          future.lastObject.UID, SGURIString(state.track.URI), state.track.UID);
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
// The state request the player's subscription makes of the core carries caps on the tracks before and after the current
// one. The future's cap is raised before the request goes; what it had is logged, for the phone's log.
- (void)getState:(id)request onResponse:(id)onResponse {
    Class requestClass = NSClassFromString(@"ESPGetStateRequest"), optional = NSClassFromString(@"ESPOptionalInt64");
    if (requestClass && optional && [request isKindOfClass:requestClass]) {
        id prev = [request valueForKey:@"prevTracksCap"], next = [request valueForKey:@"nextTracksCap"];
        SGLog(@"state request: caps %@ / %@ (previous / next)", [prev valueForKey:@"value"], [next valueForKey:@"value"]);
        if ([[next valueForKey:@"value"] longLongValue] < kFutureCap) {
            id cap = [[optional alloc] init];
            [cap setValue:@(kFutureCap) forKey:@"value"];
            [request setValue:cap forKey:@"nextTracksCap"];
            SGLog(@"state request: next cap raised to %lld", (long long)kFutureCap);
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
    // Crash reporters set their handler at launch; the log goes in front of whichever is last.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ installExceptionLog(); });
    SGRequireClasses(@[@"_TtC16Queue_UpNextImpl19UpNextTrackProvider", @"_TtC14Queue_ViewImpl22PlayerStateEventSource",
                       @"_TtC14Queue_ViewImpl20QueuedTracksObserver", @"_TtC14Queue_ViewImpl19QueueViewController",
                       @"ESPContextPlayerClientImpl", @"SPTEsperantoPlayer"]);
}
