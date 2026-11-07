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
// The DJ's "Up next" card is its own row, before the track it introduces; the track's row has no title (the core
// names it only when it plays) and no card cover. The card and its track have one uid, and the page's rows are told
// apart by it, so the card's row has a uid of its own (the track's with a suffix); the core is only ever given the
// player's own tracks, never these rows' copies.
//
// Between two segments the core has no tracks to come for a moment; the rows the page had stay for it (up to
// kGapSeconds) instead of going empty.
//
// The core keeps ten tracks behind the DJ's current one. The tracks the DJ has played are kept here whole (uri, uid,
// metadata), and a step back with none left behind in the state asks the core to skip to the one before the current
// by its uid, in the same session; if the core does not move, it is not asked again in that session.
//
// The core does not have the DJ's tracks in its queue, so what the page does to them (a swipe to remove, to queue or
// to play next, a drag) the core cannot do. A removed track is hidden here (sHidden, by its uid) and the player skips
// it if it still comes up; a track queued or played next by hand is the core's own queued track, and its DJ row is
// hidden so it shows once. The DJ's tracks are left out of the queue the core is given. Every command the page gives
// for the queue is logged (a drag in the DJ's segment is only logged: the core's order is not the page's to change).
//
// The page takes a tap on one of the tracks for a row of the core's queue, which it is not, and gives no command; it
// is skipped to as the player's here.
#import <objc/runtime.h>
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

static NSString *sSignature;

// The DJ's tracks to come as last made up (what the player said, then what was kept after it), what the queue is
// as it is put to the readers, and which of its tracks are the ones put in.
static NSArray<SPTPlayerTrack *> *sAhead = @[], *sQueue = @[], *sInjected = @[];
static id sAheadContext;
// The uids of the DJ's tracks the page removed or that were queued by hand (hidden from its rows), and the tracks
// (uri and uid) the player was already skipped past, once each.
static NSMutableSet<NSString *> *sHidden, *sSkipped;
// The page's readers of the queue, and the last queue they were given, to tell them again when a row is hidden.
static NSHashTable *sReaders;
static __weak id sLastPlayer, sLastQueue;

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

// The DJ's "Up next" card: a voice item (spotify:media:ID) with no segment of its own, followed by the track it
// introduces (the same uid), which carries the card's title and cover until the core has the track's own.
static BOOL isCard(NSArray<SPTPlayerTrack *> *future, NSUInteger i) {
    SPTPlayerTrack *track = future[i];
    return [SGURIString(track.URI) hasPrefix:@"spotify:media:"] && !track.metadata[@"segment"] && i + 1 < future.count &&
           [future[i + 1].UID isEqualToString:track.UID];
}

// The player's own track for each row that is a copy of it (by the copy's identity). The core is skipped to by these.
static NSMapTable<SPTPlayerTrack *, SPTPlayerTrack *> *sOriginals;
static NSString *const kCardSuffix = @"-card";
// The uids that had an "Up next" card in this session: their track stays a row without the card's title and cover
// after the card has gone (the voice has started), so the row's content does not change under the table.
static NSMutableSet<NSString *> *sCarded;
static NSMutableSet<NSString *> *sLoggedCards;

static SPTPlayerTrack *originalOf(SPTPlayerTrack *row) {
    return [sOriginals objectForKey:row] ?: row;
}

static SPTPlayerTrack *copyOf(SPTPlayerTrack *track, NSDictionary *metadata, NSString *uid) {
    SPTPlayerTrack *copy = [track copy];
    if (metadata) [copy setValue:metadata forKey:@"metadata"];
    if (uid) [copy setValue:uid forKey:@"UID"];
    if (!sOriginals) sOriginals = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
                                                        valueOptions:NSPointerFunctionsStrongMemory];
    [sOriginals setObject:track forKey:copy];
    return copy;
}

// The card as its own row, with a uid that is not its track's.
static SPTPlayerTrack *cardRow(SPTPlayerTrack *card) {
    return copyOf(card, nil, [card.UID stringByAppendingString:kCardSuffix]);
}

// The core names the track a card introduces only when it plays, so its name and cover are asked of Spotify's public
// oEmbed once (title and thumbnail, no artist) and put on its row when they come.
static NSMutableDictionary<NSString *, NSDictionary *> *sNamed;
static NSMutableSet<NSString *> *sNameAsked;
static void refreshReaders(void);

static void askName(NSString *uri) {
    if (!uri.length) return;
    if (!sNameAsked) sNameAsked = [NSMutableSet set];
    if ([sNameAsked containsObject:uri]) return;
    [sNameAsked addObject:uri];
    NSString *address = [@"https://open.spotify.com/oembed?url=" stringByAppendingString:
        [[@"https://open.spotify.com/track/" stringByAppendingString:[uri componentsSeparatedByString:@":"].lastObject]
         stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:address];
    SGLog(@"[DEBUG-dj] name asked for %@ (%@)", uri, url ? @"sent" : @"bad url");
    if (!url) return;
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *title = [json[@"title"] isKindOfClass:NSString.class] ? json[@"title"] : nil;
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        SGLog(@"queue: name of %@: %@", uri, title ?: [NSString stringWithFormat:@"none (http %ld, %lu bytes, %@)", (long)status,
              (unsigned long)data.length, error.localizedDescription ?: @"no error"]);
        if (!title.length) { dispatch_async(dispatch_get_main_queue(), ^{ [sNameAsked removeObject:uri]; }); return; }
        NSString *thumb = [json[@"thumbnail_url"] isKindOfClass:NSString.class] ? json[@"thumbnail_url"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!sNamed) sNamed = [NSMutableDictionary dictionary];
            sNamed[uri] = thumb ? @{@"title": title, @"image": thumb} : @{@"title": title};
            sSignature = nil;
            refreshReaders();
        });
    }] resume];
}

// The track a card introduces, as its own row: the card's title, artist and cover taken off, so the row shows the
// track and not the card (its own title is not known until it plays).
static SPTPlayerTrack *withoutCard(SPTPlayerTrack *track) {
    NSMutableDictionary *metadata = [track.metadata mutableCopy];
    for (NSString *key in track.metadata) {
        if ([key hasPrefix:@"title"] || [key hasPrefix:@"artist_name"] || [key hasPrefix:@"image"] || [key hasPrefix:@"thumbnail"]) [metadata removeObjectForKey:key];
    }
    NSString *uri = SGURIString(track.URI);
    NSDictionary *named = sNamed[uri];
    if (named) {
        metadata[@"title"] = named[@"title"];
        NSString *image = named[@"image"];
        if (image) for (NSString *key in @[@"image_url", @"image_small_url", @"image_large_url", @"image_xlarge_url", @"thumbnail_image_url"]) metadata[key] = image;
    } else {
        askName(uri);
    }
    return copyOf(track, metadata, nil);
}

// The uid a row has as the player's: the card's row has the suffix on it.
static NSString *baseUID(NSString *uid) {
    return [uid hasSuffix:kCardSuffix] ? [uid substringToIndex:uid.length - kCardSuffix.length] : uid;
}

// A track's metadata as one line of the log: each key with the start of its value.
static NSString *describeMeta(NSDictionary *metadata) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *key in [metadata.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *value = [NSString stringWithFormat:@"%@", metadata[key]];
        if (value.length > 48) value = [[value substringToIndex:48] stringByAppendingString:@"~"];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
    }
    return [parts componentsJoinedByString:@" "];
}

#pragma mark - the card's avatar

// The page leaves the DJ's avatar off the "Up next" card's row (a placeholder where its image is), so it is drawn here:
// the card's image_url is fetched once and put in the row's image view when the cell lays out.
static UIImage *sCardAvatar;
static NSString *sCardAvatarURL, *sCardTitle;
static NSHashTable<UITableViewCell *> *sQueueCells;

static void loadCardAvatar(NSString *url) {
    if (!url.length || [url isEqualToString:sCardAvatarURL]) return;
    sCardAvatarURL = url;
    NSURL *address = [NSURL URLWithString:url];
    if (!address) return;
    [[[NSURLSession sharedSession] dataTaskWithURL:address completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
        SGLog(@"queue: card avatar %@: %@", url, image ? @"loaded" : (error.localizedDescription ?: @"no image"));
        if (!image) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            sCardAvatar = image;
            for (UITableViewCell *cell in sQueueCells.allObjects) [cell setNeedsLayout];
        });
    }] resume];
}

static UIView *descendant(UIView *root, BOOL (^match)(UIView *)) {
    for (UIView *view in root.subviews) {
        if (match(view)) return view;
        UIView *found = descendant(view, match);
        if (found) return found;
    }
    return nil;
}

// The avatar in the cell of the card's row (the row whose accessibility label has the card's title), over the
// placeholder.
static void drawCardAvatar(UITableViewCell *cell) {
    if (!sCardAvatar || !sCardTitle.length) return;
    UIView *row = descendant(cell.contentView, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"TrackRowQueue.Cell"]; });
    if (!row || ![row.accessibilityLabel containsString:sCardTitle]) return;
    UIView *art = descendant(row, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"Encore.ImageView"]; });
    UIImageView *image = art ? (UIImageView *)descendant(art, ^BOOL(UIView *view) { return [view isMemberOfClass:UIImageView.class]; }) : nil;
    if (!image) return;
    if (image.image != sCardAvatar) {
        image.image = sCardAvatar;
        image.contentMode = UIViewContentModeScaleAspectFill;
        image.clipsToBounds = YES;
        SGLog(@"queue: card avatar drawn in the row (alpha was %.2f, hidden %d)", image.alpha, image.hidden);
    }
    // The row's image view waits at alpha 0 for a picture Spotify never loads for the card; it is shown with the picture.
    image.alpha = 1;
    image.hidden = NO;
    UIView *placeholder = descendant(art, ^BOOL(UIView *view) { return [NSStringFromClass(view.class) containsString:@"PlaceholderView"]; });
    placeholder.hidden = YES;
}

// The tracks the DJ has to come in the state's future, each "Up next" card as its own row before its track: they end
// at the delimiter, after which the core puts the whole session again as hidden stand-ins, and a track the list has
// already named is such a stand-in too.
static NSArray<SPTPlayerTrack *> *djFuture(NSArray<SPTPlayerTrack *> *future) {
    NSMutableArray<SPTPlayerTrack *> *tracks = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    SPTPlayerTrack *card;
    for (NSUInteger i = 0; i < future.count; i++) {
        SPTPlayerTrack *track = future[i];
        if ([track.provider isEqualToString:@"queue"]) continue;
        if ([SGURIString(track.URI) isEqualToString:@"spotify:delimiter"]) break;
        BOOL isTheCard = isCard(future, i);
        if (!isTheCard && !isDJTrack(track)) continue;
        if (track.UID.length) {
            NSString *key = [SGURIString(track.URI) stringByAppendingString:track.UID];
            if ([seen containsObject:key]) break;
            [seen addObject:key];
        }
        if (isTheCard) {
            if (!sCarded) sCarded = [NSMutableSet set];
            [sCarded addObject:track.UID];
            if (!sLoggedCards) sLoggedCards = [NSMutableSet set];
            if (![sLoggedCards containsObject:track.UID]) {
                [sLoggedCards addObject:track.UID];
                SGLog(@"queue: card %@ [%@] metadata: %@", SGURIString(track.URI), track.UID, describeMeta(track.metadata));
                SGLog(@"queue: its track %@ [%@] metadata: %@", SGURIString(future[i + 1].URI), future[i + 1].UID, describeMeta(future[i + 1].metadata));
            }
            card = track;
            sCardTitle = track.metadata[@"title"];
            loadCardAvatar(track.metadata[@"image_url"]);
            track = cardRow(track);
        } else if (!track.metadata[@"segment"] && ((card && [card.UID isEqualToString:track.UID]) || [sCarded containsObject:track.UID])) {
            // The card's track: with the card before it, and after the card has gone, the same row.
            track = withoutCard(track);
        }
        if (!isTheCard) card = nil;
        [tracks addObject:track];
    }
    return tracks;
}

// A one-time look at what the player's state and its tracks offer about the DJ's pages (names with "page" in them):
// the core hands the player one page of five, and the others may be somewhere the state can be asked for.
static void probePages(SPTPlayerState *state) {
    static BOOL probed;
    if (probed || !state.future.count) return;
    probed = YES;
    NSMutableArray<id> *samples = [NSMutableArray arrayWithObject:state];
    if (state.future.firstObject) [samples addObject:state.future.firstObject];
    for (id sample in samples) {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        unsigned int count = 0;
        Method *methods = class_copyMethodList([sample class], &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if ([name.lowercaseString containsString:@"page"] || [name.lowercaseString containsString:@"context"]) [names addObject:name];
        }
        free(methods);
        SGLog(@"[DEBUG-dj] pages: %@ offers %@", NSStringFromClass([sample class]), names.count ? [names componentsJoinedByString:@" "] : @"nothing about pages");
    }
    SGLog(@"[DEBUG-dj] pages: the state's future is %lu items, %lu of them the DJ's", (unsigned long)state.future.count,
          (unsigned long)djFuture(state.future).count);
}

// Whether the track is the DJ's: its metadata names the session's page.
static BOOL inDJ(SPTPlayerTrack *track) {
    return track.metadata[@"page_instance_id"] != nil;
}

static BOOL isHidden(SPTPlayerTrack *track) {
    return track.UID.length && [sHidden containsObject:baseUID(track.UID)];
}

// The DJ's track on the page's rows that a command names: by uri and uid, or by the uri alone when it has no uid.
static SPTPlayerTrack *injectedNamed(NSString *uri, NSString *uid) {
    for (SPTPlayerTrack *track in sInjected) {
        if (![SGURIString(track.URI) isEqualToString:uri]) continue;
        if (!uid.length || [track.UID isEqualToString:uid]) return track;
    }
    return nil;
}

static void hideTrack(SPTPlayerTrack *track, NSString *why) {
    if (!track.UID.length) return;
    if (!sHidden) sHidden = [NSMutableSet set];
    [sHidden addObject:baseUID(track.UID)];
    SGLog(@"queue: %@ is hidden from the DJ's rows (%@) [%@]", track.trackTitle, why, track.UID);
}

// The readers are told the queue again, through the hooks, so the rows go at once and not at the core's next change.
@protocol SGQueueReader <NSObject>
- (void)player:(id)player queueDidChange:(id)queue;
@end

// The queue the core gave last and what the readers were given for it: every reader of one queue gets the very same
// object, as each gets the core's own, so the page's table and its cells are made from one list.
static __weak id sForwardFor;
static id sForward;

static void refreshReaders(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id player = sLastPlayer, queue = sLastQueue;
        if (!player || !queue) { SGLog(@"queue: no queue to refresh the rows with"); return; }
        sForwardFor = nil;
        SGLog(@"[DEBUG-dj] refresh: %lu readers told again", (unsigned long)sReaders.allObjects.count);
        for (id<SGQueueReader> reader in sReaders.allObjects) [reader player:player queueDidChange:queue];
    });
}

// When the core began to have no tracks to come, nil while it has some.
static NSDate *sGapSince;

// What the last list was made from, and the list: the same input gives the readers the same rows (the same objects),
// whichever of them is asked first.
static NSArray<SPTPlayerTrack *> *sCachedMerged;

// A line that tells whether the state, the core's queue or what was hidden has changed since the last list.
static NSString *signatureOf(SPTPlayerState *state, NSArray<SPTPlayerTrack *> *next) {
    NSMutableString *sig = [NSMutableString stringWithFormat:@"%@|%@|%@|", state.contextURI, SGURIString(state.track.URI), state.track.UID];
    for (SPTPlayerTrack *t in state.future) [sig appendFormat:@"%@/%@/%@;", SGURIString(t.URI), t.UID, t.provider];
    [sig appendString:@"|"];
    for (SPTPlayerTrack *t in next) [sig appendFormat:@"%@/%@/%@;", SGURIString(t.URI), t.UID, t.provider];
    [sig appendString:@"|"];
    for (NSString *uid in [sHidden.allObjects sortedArrayUsingSelector:@selector(compare:)]) [sig appendFormat:@"%@,", uid];
    return sig;
}

// Puts the DJ's tracks to come in `queue`. YES when the readers are to be left as they are: the core has none to come
// just now, and the rows the page had stay.
// The queue the readers are given is a copy of the core's with the DJ's rows in it, in `forward`: the core's own queue
// object is not changed, the page may keep it and read it again later.
static id queueWith(id queue, NSArray<SPTPlayerTrack *> *rows) {
    id copy = [queue copy];
    if (!copy) { SGLog(@"queue: the queue cannot be copied, the page gets the core's"); return queue; }
    [copy setValue:rows forKey:@"nextTracks"];
    return copy;
}

static BOOL lineUpTheFutureFor(id reader, id player, id queue, id *forward);

static BOOL lineUpTheFuture(id reader, id player, id queue, id *forward) {
    if (queue && queue == sForwardFor && sForward) {
        if (!sReaders) sReaders = [NSHashTable weakObjectsHashTable];
        [sReaders addObject:reader];
        *forward = sForward;
        SGLog(@"[DEBUG-dj] %@ given the same queue (%lu rows)", NSStringFromClass([reader class]),
              (unsigned long)[[sForward valueForKey:@"nextTracks"] count]);
        return NO;
    }
    BOOL keep = lineUpTheFutureFor(reader, player, queue, forward);
    SGLog(@"[DEBUG-dj] %@ given %lu rows%@ (core %lu)", NSStringFromClass([reader class]),
          (unsigned long)[[*forward valueForKey:@"nextTracks"] count], keep ? @", kept the old ones" : @"",
          (unsigned long)[[queue valueForKey:@"nextTracks"] count]);
    if (!keep) {
        sForwardFor = queue;
        sForward = *forward;
    }
    return keep;
}

static BOOL lineUpTheFutureFor(id reader, id player, id queue, id *forward) {
    if (!sReaders) sReaders = [NSHashTable weakObjectsHashTable];
    [sReaders addObject:reader];
    sLastPlayer = player;
    sLastQueue = queue;
    *forward = queue;
    SPTPlayerState *state = SGPlayerState();
    NSArray<SPTPlayerTrack *> *next = [queue valueForKey:@"nextTracks"];
    NSString *signature = signatureOf(state, next);
    if (sCachedMerged.count && [signature isEqualToString:sSignature]) {
        *forward = queueWith(queue, sCachedMerged);
        return NO;
    }
    probePages(state);
    NSArray<SPTPlayerTrack *> *future = djFuture(state.future);

    // The state's own, then what was kept after its last one. When hand-queued tracks fill the state's two it names
    // none of the DJ's, and what was kept stands. A list that does not go on from the kept one is the DJ's new.
    NSMutableArray<SPTPlayerTrack *> *ahead = [future mutableCopy];
    if (![state.contextURI isEqual:sAheadContext]) {
        [sHidden removeAllObjects];
        [sSkipped removeAllObjects];
        [sCarded removeAllObjects];
        [sLoggedCards removeAllObjects];
    }
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
    // What the page shows of them: not the ones it removed, nor the ones queued by hand.
    NSMutableArray<SPTPlayerTrack *> *shown = [NSMutableArray array];
    for (SPTPlayerTrack *track in ahead) if (!isHidden(track)) [shown addObject:track];

    // The hand-queued tracks, the DJ's, then whatever else the queue had.
    NSMutableArray<SPTPlayerTrack *> *queued = [NSMutableArray array], *rest = [NSMutableArray array], *injected = [NSMutableArray array];
    for (SPTPlayerTrack *track in next) {
        if ([track.provider isEqualToString:@"queue"]) [queued addObject:track];
        else if (indexIn(ahead, track) == NSNotFound) [rest addObject:track];
    }
    for (SPTPlayerTrack *track in shown) if (indexIn(next, track) == NSNotFound) [injected addObject:track];
    NSMutableArray<SPTPlayerTrack *> *merged = [queued mutableCopy];
    [merged addObjectsFromArray:shown];
    [merged addObjectsFromArray:rest];

    if (merged.count) {
        sGapSince = nil;
    } else if (sQueue.count && inDJ(state.track)) {
        if (!sGapSince) sGapSince = [NSDate date];
        if (-sGapSince.timeIntervalSinceNow < kGapSeconds) return YES;
    }
    sQueue = merged;
    sInjected = injected;
    if (injected.count) {
        NSMutableArray<NSString *> *rows = [NSMutableArray array];
        for (SPTPlayerTrack *row in merged) [rows addObject:[NSString stringWithFormat:@"%@/%@", [SGURIString(row.URI) componentsSeparatedByString:@":"].lastObject, row.UID]];
        NSString *line = [rows componentsJoinedByString:@" "];
        static NSString *sLastRows;
        if (![line isEqualToString:sLastRows]) { sLastRows = line; SGLog(@"queue: rows (%lu, %lu the DJ's): %@", (unsigned long)merged.count, (unsigned long)injected.count, line); }
    }
    sSignature = signature;
    sCachedMerged = merged;
    if (ahead.count) *forward = queueWith(queue, merged);
    return NO;
}

// An ESPContextTrack as a line of the log.
static NSString *describeEsp(id track) {
    return [NSString stringWithFormat:@"%@ [%@]", [track valueForKey:@"uri"], [track valueForKey:@"uid"]];
}

%hook _TtC16Queue_UpNextImpl19UpNextTrackProvider
- (void)player:(id)player queueDidChange:(id)queue {
    id forward = queue;
    if (lineUpTheFuture(self, player, queue, &forward)) return;
    %orig(player, forward);
}
%end

%hook _TtC14Queue_ViewImpl22PlayerStateEventSource
- (void)player:(id)player queueDidChange:(id)queue {
    id forward = queue;
    if (lineUpTheFuture(self, player, queue, &forward)) return;
    %orig(player, forward);
}
%end

%hook _TtC14Queue_ViewImpl20QueuedTracksObserver
- (void)player:(id)player queueDidChange:(id)queue {
    id forward = queue;
    if (lineUpTheFuture(self, player, queue, &forward)) return;
    %orig(player, forward);
}
%end

// The queue table's diffable data source reconfigures a row by asking the page's cell provider for it again, and the
// provider reads the page's own list, which can already be the next one: the snapshot had five rows and the provider four
// (the skip to a later DJ track took the first away), so for the fifth it gave a bare UITableViewCell and UIKit aborted
// ("returned a different cell ... than the cell being reconfigured", path 1-4, on the phone). The queue table is never
// reconfigured: it is loaded again once the update is in, which takes whatever cell the provider gives.
static BOOL sReloadQueued;
%hook UITableView
- (void)reconfigureRowsAtIndexPaths:(NSArray<NSIndexPath *> *)paths {
    static Class queueSource;
    if (!queueSource) queueSource = NSClassFromString(@"_TtC14Queue_ViewImpl38QueueTableViewDataSourceImplementation");
    id<UITableViewDataSource> source = self.dataSource;
    if (!queueSource || ![(id)source isKindOfClass:queueSource]) {
        %orig;
        return;
    }
    NSMutableArray<NSString *> *places = [NSMutableArray array];
    for (NSIndexPath *path in paths) [places addObject:[NSString stringWithFormat:@"%ld-%ld/%ld", (long)path.section, (long)path.row,
        (long)[source tableView:self numberOfRowsInSection:path.section]]];
    SGLog(@"[DEBUG-dj] reconfigure of %@ left to a reload (our list %lu rows)", [places componentsJoinedByString:@" "], (unsigned long)sQueue.count);
    if (sReloadQueued) return;
    sReloadQueued = YES;
    __weak UITableView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        sReloadQueued = NO;
        [weakSelf reloadData];
    });
}
%end

%hook _TtC14Queue_ViewImpl9QueueCell
- (void)layoutSubviews {
    %orig;
    // The hooked class is declared here without its superclass, so it is taken as the table cell it is.
    UITableViewCell *cellSelf = (UITableViewCell *)(id)self;
    if (!sQueueCells) sQueueCells = [NSHashTable weakObjectsHashTable];
    [sQueueCells addObject:cellSelf];
    drawCardAvatar(cellSelf);
    // The row's own image view may be set again a moment after the layout.
    __weak UITableViewCell *weakSelf = cellSelf;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UITableViewCell *cell = weakSelf;
        if (cell) drawCardAvatar(cell);
    });
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
    id track = [request valueForKey:@"track"];
    SGLog(@"queue command: addToQueue %@", describeEsp(track));
    SPTPlayerTrack *dj = injectedNamed([track valueForKey:@"uri"], nil);
    if (dj) {
        hideTrack(dj, @"queued by hand");
        refreshReaders();
    } else {
        SGLog(@"queue command: addToQueue: not one of the DJ's rows");
    }
    %orig;
}
- (void)setQueue:(id)request onResponse:(id)onResponse {
    NSMutableArray *tracks = [request valueForKey:@"nextTracksArray"];
    NSMutableArray *djs = [NSMutableArray array];
    NSMutableSet<NSString *> *sent = [NSMutableSet set];
    for (id track in tracks) {
        SGLog(@"queue command: setQueue track %@", describeEsp(track));
        if (injectedNamed([track valueForKey:@"uri"], [track valueForKey:@"uid"])) {
            [djs addObject:track];
            [sent addObject:[track valueForKey:@"uid"]];
        }
    }
    SGLog(@"queue command: setQueue %lu next tracks, %lu of the DJ's rows, %lu rows shown", (unsigned long)tracks.count,
          (unsigned long)djs.count, (unsigned long)sInjected.count);
    if (djs.count) {
        // The page sent the whole list with the DJ's rows in it: the ones it left out are the ones it removed. None
        // of them is the core's, so they are not given to it.
        for (SPTPlayerTrack *row in [sInjected copy]) {
            if (![sent containsObject:row.UID]) hideTrack(row, @"removed in the page");
        }
        [tracks removeObjectsInArray:djs];
        refreshReaders();
    } else if (sInjected.count) {
        SGLog(@"queue command: setQueue has none of the DJ's rows, not taken for a removal");
    }
    %orig;
}
- (void)playAsNextInQueue:(id)request onResponse:(id)onResponse {
    BOOL hid = NO;
    for (id track in [request valueForKey:@"tracksArray"]) {
        SGLog(@"queue command: playAsNextInQueue %@", describeEsp(track));
        SPTPlayerTrack *dj = injectedNamed([track valueForKey:@"uri"], nil);
        if (dj) { hideTrack(dj, @"played next by hand"); hid = YES; }
    }
    if (hid) refreshReaders();
    %orig;
}
%end

// The page's own queue commands before they reach the client: what its swipe actions and its drag call.
%hook SPTPlayerQueueWrapperImpl
- (id)queueTrackInternal:(SPTPlayerTrack *)track options:(id)options loggingParams:(id)params {
    SGLog(@"queue page: queue track %@ [%@] %@", track.trackTitle, track.UID, SGURIString(track.URI));
    return %orig;
}
- (id)queueTracksInternal:(NSArray<SPTPlayerTrack *> *)tracks options:(id)options loggingParams:(id)params {
    SGLog(@"queue page: queue %lu tracks, first %@", (unsigned long)tracks.count, SGURIString(tracks.firstObject.URI));
    return %orig;
}
- (id)queueTrackPlayNext:(SPTPlayerTrack *)track {
    SGLog(@"queue page: play next %@ [%@] %@", track.trackTitle, track.UID, SGURIString(track.URI));
    return %orig;
}
%end

%hook _TtC14Queue_ViewImpl38QueueTableViewDataSourceImplementation
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    SGLog(@"queue page: drag section %ld row %ld to section %ld row %ld (%lu rows shown)", (long)from.section, (long)from.row,
          (long)to.section, (long)to.row, (unsigned long)sQueue.count);
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
    // A DJ track the page removed (or queued by hand) that the player has come to: its voice, then the track itself,
    // are skipped, once each.
    if (isHidden(track)) {
        NSString *key = [SGURIString(track.URI) stringByAppendingString:track.UID];
        if (!sSkipped) sSkipped = [NSMutableSet set];
        if (![sSkipped containsObject:key]) {
            [sSkipped addObject:key];
            SGLog(@"queue: the player is on a hidden track %@ %@, skipping it", track.trackTitle, SGURIString(track.URI));
            [(id<SPTPlayer>)SGPlayer() skipToNextTrackWithOptions:nil];
            return;
        }
    }
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
        // The "Up next" card is the voice item (spotify:media:), which the core is never skipped to: the row after it
        // is the track it introduces, and that one is. The core is given the player's own track, not the row's copy.
        SPTPlayerTrack *row = track;
        if ([SGURIString(track.URI) hasPrefix:@"spotify:media:"]) {
            SPTPlayerTrack *introduced = place + 1 < (NSInteger)sQueue.count ? sQueue[place + 1] : nil;
            row = introduced && [originalOf(introduced).UID isEqualToString:originalOf(track).UID] ? introduced : nil;
        }
        SPTPlayerTrack *target = row ? originalOf(row) : nil;
        if (!target) {
            SGLog(@"queue page: the card %@ has no track after it to skip to", track.UID);
            return;
        }
        SGLog(@"queue page: skip to %@ [%@], from row %@ [%@]", SGURIString(target.URI), target.UID, SGURIString(track.URI), track.UID);
        // The skip changes the queue, and the page reloads its table for it: it is made once this tap has returned,
        // not inside the table's own selection.
        dispatch_async(dispatch_get_main_queue(), ^{
            [(id<SPTPlayer>)SGPlayer() skipToNextTrackWithOptions:nil track:target];
        });
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
    SGLog(@"queue: DJ queue hooks are on");
    installExceptionLog();
    static SGDJHistory *history;
    history = [[SGDJHistory alloc] init];
    SGAddPlayerStateObserver(history);
    // Crash reporters set their handler at launch; the log goes in front of whichever is last.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ installExceptionLog(); });
    SGRequireClasses(@[@"_TtC16Queue_UpNextImpl19UpNextTrackProvider", @"_TtC14Queue_ViewImpl22PlayerStateEventSource",
                       @"_TtC14Queue_ViewImpl20QueuedTracksObserver", @"_TtC14Queue_ViewImpl19QueueViewController",
                       @"ESPContextPlayerClientImpl", @"SPTEsperantoPlayer", @"SPTPlayerQueueWrapperImpl", @"_TtC14Queue_ViewImpl9QueueCell",
                       @"_TtC14Queue_ViewImpl38QueueTableViewDataSourceImplementation"]);
}
