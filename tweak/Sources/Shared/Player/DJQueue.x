// The AI DJ's queue on Spotify's own queue page. The DJ's session is one track playing, and the player's queue
// (SPTPlayerQueue) holds nothing of the DJ's after it, though the player's state knows the tracks that follow
// (SPTPlayerState.future: the DJ's segment, five tracks and the voice between them). Those are put in the queue
// before each of its readers takes it, after the hand-queued tracks and in the DJ's order, so they draw the tracks
// as they draw any tracks to come: its rows, Spotify's. The readers are the queue page's own two observers (the page
// does not go through the Up next card's provider) and that provider.
//
// Only the DJ's session is touched (isDJSession): in any other context every hook here passes Spotify's own through.
// The switch is SGKeyDJQueue (DJQueue.h), on until switched off, read at launch.
//
// The player's subscription asks the core for the state with a cap on the tracks to come
// (ESPGetStateRequest.nextTracksCap), two at first; it is raised here so the state's future is the whole segment. The
// subscription is made once, at launch, before any context is known, so the cap is raised for every context: kFutureCap
// is what the DJ's segment needs and no more. The core gives no more than one segment whatever the cap (9.1.90: with a
// cap of 80 the DJ's future was its 4 tracks and 2 voices); the next segment is made when the core comes to the last
// track of this one. The core asks for it itself: the app gives it no context page then (no play, updateContext or
// updateContextPage, 9.1.90), so there is nothing here to ask it earlier with.
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
// The order the user gave the DJ's rows (a drag on the page) is kept here (sOrder), over a copy of the rows the DJ has sent
// (sKept: the core's own future forgets the tracks it has been moved past). The core does not take another order for
// them (a setQueue with the DJ's tracks rearranged leaves its future as it was, 9.1.90), so the page shows that order and
// the player is held to it: when the core comes to a DJ track that is not the first of ours, it is skipped to the first
// of ours. A track with an "Up next" card is skipped to through its voice, wherever the drag put it, so the voice plays.
// Spotify's now playing screens are shown the state with its future in the user's order (djLens), so the cover list
// moves forward to the track the skip goes to, though the core may have stepped back to it.
// The user's next is put in the core's queue as the track before it starts (queueAhead), so a track that ends by itself
// goes on to it and not to the core's own for a moment. A track played from the core's queue is a copy, which Spotify
// draws as queued by hand; the now playing screens are shown it as the DJ's track it stands for (sCopyOf).
// With nothing of the segment left but removed or played tracks, the player is paused just before the end, skipped
// to the segment's last and on to the next segment's first once it has come, then resumed (handOver).
// The order, what was removed or played, the voices heard and the copies are kept over a launch (SGKeyDJQueueSession).
// A tap on a row passes the DJ's rows before it (they are hidden). The row of the "Up next" card has no swipe actions.
// The page takes a tap on one of the tracks for a row of the core's queue, which it is not, and gives no command; it
// is skipped to as the player's here.
#import <objc/runtime.h>
#import <objc/message.h>
#import "Core/SGCore.h"
#import "Core/SGLog.h"
#import "PlayerState.h"
#import "DJQueue.h"

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
// The uid of a track the page was tapped on whose "Up next" card is ahead of it, and when: the core plays the card's
// voice first (the voice and the track have one uid), and the voice is skipped when the player comes to it.
static NSString *sSkipVoiceUID;
static NSDate *sSkipVoiceAsked;
// The page's readers of the queue, and the last queue they were given, to tell them again when a row is hidden.
static NSHashTable *sReaders;
// Held, not weak: the core lets go of its queue object before a name comes back from the network, and a weak one
// left refreshReaders with nothing to tell the readers ("no queue to refresh the rows with" in the log).
static id sLastPlayer, sLastQueue;
// The player to command: the one the queue's observers were told by, which is the one the app plays through.
// SGPlayer() is the first player to be given an observer and held weakly; it may be another instance, or gone, and a
// command to it does nothing without a word (taps on the page's tracks did nothing).
static id queuePlayer(void) {
    return sLastPlayer ?: SGPlayer();
}

// The DJ's segment (five tracks, a voice before the first and one after the last) with room for the hand-queued.
static const int64_t kFutureCap = 16;
// How long the page keeps its rows while the core has no tracks to come.
static const NSTimeInterval kGapSeconds = 3;
// How long the core has to move to a track it was asked to skip back to.
static const NSTimeInterval kJumpSeconds = 1.5;
// How long a tap on a track behind a card is waited for to reach the card's voice.
static const NSTimeInterval kSkipVoiceSeconds = 10;

// The DJ's session: its playlist, or (for a DJ under another uri) a playlist whose tracks carry the DJ's segment.
static NSString *const kDJContext = @"spotify:playlist:37i9dQZF1EYkqdzj48dyYq";
static BOOL isDJSession(SPTPlayerState *state) {
    NSString *context = SGURIString(state.contextURI);
    if ([context isEqualToString:kDJContext]) return YES;
    return [context hasPrefix:@"spotify:playlist:"] && state.track.metadata[@"segment"] != nil;
}

// A track of the DJ's to come (in the DJ's session): not the narration, a page marker or the delimiter that ends the pages.
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
// The player's own card track by uid, kept so the card's row can stay while its voice plays, and so a skip to its
// track goes through the voice.
static NSMutableDictionary<NSString *, SPTPlayerTrack *> *sCardTracks;
// The uids whose "Up next" voice the player has come to.
static NSMutableSet<NSString *> *sVoiced;

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
static NSMutableDictionary<NSString *, NSString *> *sArtists;
static NSMutableSet<NSString *> *sNameAsked;
// When a name was last asked and did not come (offline, a refusal): it is asked again only after kNameRetry, not at
// every rebuild of the rows.
static NSMutableDictionary<NSString *, NSDate *> *sNameFailed;
static const NSTimeInterval kNameRetry = 60;
static void refreshReaders(void);
static void saveSession(void);
static void scheduleHandOver(void);

// oEmbed gives the title and the cover but no artist. The artist is read from the track's public page, whose title
// is "<song> - song and lyrics by <artist> | Spotify"; it is put on the row when it comes, and the row has none until.
static void askArtist(NSString *uri) {
    NSURL *url = [NSURL URLWithString:[@"https://open.spotify.com/track/" stringByAppendingString:[uri componentsSeparatedByString:@":"].lastObject]];
    if (!url) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
   forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"en-US,en;q=0.9" forHTTPHeaderField:@"Accept-Language"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *html = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSString *artist = nil, *pageTitle = nil;
        NSRange open = html ? [html rangeOfString:@"<title>"] : NSMakeRange(NSNotFound, 0);
        NSRange close = html ? [html rangeOfString:@"</title>"] : NSMakeRange(NSNotFound, 0);
        if (open.location != NSNotFound && close.location != NSNotFound && close.location > NSMaxRange(open)) {
            pageTitle = [html substringWithRange:NSMakeRange(NSMaxRange(open), close.location - NSMaxRange(open))];
            NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^.* by (.+?) \\| Spotify$"
                options:NSRegularExpressionDotMatchesLineSeparators error:nil];
            NSTextCheckingResult *match = [pattern firstMatchInString:pageTitle options:0 range:NSMakeRange(0, pageTitle.length)];
            if (match) artist = [pageTitle substringWithRange:[match rangeAtIndex:1]];
        }
        artist = [[[[artist stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"]
                    stringByReplacingOccurrencesOfString:@"&#x27;" withString:@"'"]
                   stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""]
                  stringByReplacingOccurrencesOfString:@"&#39;" withString:@"'"];
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        SGLog(@"queue: artist of %@: %@", uri, artist.length ? artist : [NSString stringWithFormat:@"none (http %ld, %lu bytes, page title %@)",
              (long)status, (unsigned long)data.length, pageTitle ?: @"-"]);
        if (!artist.length) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!sArtists) sArtists = [NSMutableDictionary dictionary];
            sArtists[uri] = artist;
            sSignature = nil;
            refreshReaders();
        });
    }] resume];
}

static void askName(NSString *uri) {
    if (!uri.length) return;
    if (!sNameAsked) sNameAsked = [NSMutableSet set];
    if ([sNameAsked containsObject:uri]) return;
    NSDate *failed = sNameFailed[uri];
    if (failed && -failed.timeIntervalSinceNow < kNameRetry) return;
    [sNameAsked addObject:uri];
    NSString *address = [@"https://open.spotify.com/oembed?url=" stringByAppendingString:
        [[@"https://open.spotify.com/track/" stringByAppendingString:[uri componentsSeparatedByString:@":"].lastObject]
         stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:address];
    if (!url) return;
    if (!sArtists[uri]) askArtist(uri);
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *title = [json[@"title"] isKindOfClass:NSString.class] ? json[@"title"] : nil;
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        SGLog(@"queue: name of %@: %@", uri, title ?: [NSString stringWithFormat:@"none (http %ld, %lu bytes, %@)", (long)status,
              (unsigned long)data.length, error.localizedDescription ?: @"no error"]);
        if (!title.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [sNameAsked removeObject:uri];
                if (!sNameFailed) sNameFailed = [NSMutableDictionary dictionary];
                sNameFailed[uri] = [NSDate date];
            });
            return;
        }
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
        NSString *artist = sArtists[uri];
        if (artist.length) metadata[@"artist_name"] = artist;
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
// The avatar views put in rows, taken off when the DJ's session ends; and whether it is the DJ's session, as the queue
// was last made up, so the page's cells and table do nothing of this anywhere else.
static NSHashTable<UIView *> *sAvatarViews;
static BOOL sDJActive;

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

// The avatar in the cell of the card's row (the row whose accessibility label has the card's title): a view of ours in
// the row's art, over Spotify's own image view. Spotify sets its image view's alpha and image again when the row is
// selected or reloaded (the avatar went away on a tap on the card); a view of ours it does not touch stays. In any
// other row the view is taken off, as cells are reused.
static const NSInteger kAvatarTag = 0x5367;
// Spotify rounds the art of its rows; the avatar takes the corners of a row that is not the card's. Nothing else says
// what they are (the row's art has no radius on it until its image is set, which the card's never is).
static const CGFloat kFallbackRadius = 4;

static CGFloat sRowsRadius;
static CGFloat otherRowsRadius(void) {
    if (sRowsRadius > 0) return sRowsRadius;
    for (UITableViewCell *cell in sQueueCells.allObjects) {
        UIView *row = descendant(cell.contentView, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"TrackRowQueue.Cell"]; });
        if (!row || (sCardTitle.length && [row.accessibilityLabel containsString:sCardTitle])) continue;
        UIView *art = descendant(row, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"Encore.ImageView"]; });
        UIView *image = art ? descendant(art, ^BOOL(UIView *view) { return [view isMemberOfClass:UIImageView.class] && view.tag != kAvatarTag; }) : nil;
        CGFloat radius = MAX(art.layer.cornerRadius, image.layer.cornerRadius);
        if (radius > 0) return sRowsRadius = radius;
    }
    return 0;
}

static void drawAvatarInRow(UIView *row) {
    UIView *art = row ? descendant(row, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"Encore.ImageView"]; }) : nil;
    if (!art) return;
    UIImageView *mine = (UIImageView *)[art viewWithTag:kAvatarTag];
    BOOL isCard = sCardAvatar && sCardTitle.length && [row.accessibilityLabel containsString:sCardTitle];
    if (!isCard) {
        [mine removeFromSuperview];
        return;
    }
    UIImageView *inner = (UIImageView *)descendant(art, ^BOOL(UIView *view) { return [view isMemberOfClass:UIImageView.class] && view.tag != kAvatarTag; });
    if (!mine) {
        mine = [[UIImageView alloc] init];
        mine.tag = kAvatarTag;
        mine.contentMode = UIViewContentModeScaleAspectFill;
        mine.clipsToBounds = YES;
        mine.userInteractionEnabled = NO;
        mine.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [art addSubview:mine];
        if (!sAvatarViews) sAvatarViews = [NSHashTable weakObjectsHashTable];
        [sAvatarViews addObject:mine];
    }
    mine.frame = art.bounds;
    CGFloat radius = MAX(art.layer.cornerRadius, inner.layer.cornerRadius);
    if (radius <= 0) radius = otherRowsRadius();
    mine.layer.cornerRadius = radius > 0 ? radius : kFallbackRadius;
    mine.image = sCardAvatar;
    mine.alpha = 1;
    mine.hidden = NO;
    art.alpha = 1;
    art.hidden = NO;
    [art bringSubviewToFront:mine];
}

static void drawCardAvatar(UITableViewCell *cell) {
    if (!sDJActive || !sCardAvatar) return;
    UIView *row = descendant(cell.contentView, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"TrackRowQueue.Cell"] || [view.accessibilityIdentifier isEqualToString:@"TrackRowQueue.Header"]; });
    if (row) drawAvatarInRow(row);
}

// The "Now playing" row above the table is not a cell: while the DJ's voice plays it is the card, and it has the
// placeholder where the avatar goes. It is found in the page's view and drawn the same.
static void drawHeaderAvatar(UIView *page) {
    if (!sDJActive || !sCardAvatar) return;
    UIView *row = descendant(page, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"TrackRowQueue.Header"]; });
    if (row) drawAvatarInRow(row);
}

// The avatar is drawn now and again as the row settles: selecting, highlighting and reloading it all redo Spotify's own.
static void drawCardAvatarSoon(UITableViewCell *cell) {
    if (!sDJActive || !sCardAvatar) return;
    drawCardAvatar(cell);
    __weak UITableViewCell *weakCell = cell;
    for (NSNumber *delay in @[@0.05, @0.3, @0.8]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UITableViewCell *strongCell = weakCell;
            if (strongCell) drawCardAvatar(strongCell);
        });
    }
}

// The tracks the DJ has to come in the state's future, each "Up next" card as its own row before its track: they end
// at the delimiter, after which the core puts the whole session again as hidden stand-ins, and a track the list has
// already named is such a stand-in too.
// A track the core made for the queue: its provider is "queue", or (as a DJ track queued by hand comes back, with the
// context's provider) its uid starts with q, which a context's uids (hex) never do.
static BOOL isCoreQueued(SPTPlayerTrack *track) {
    return [track.provider isEqualToString:@"queue"] || [track.UID hasPrefix:@"q"];
}

static NSArray<SPTPlayerTrack *> *djFuture(NSArray<SPTPlayerTrack *> *future) {
    NSMutableArray<SPTPlayerTrack *> *tracks = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    SPTPlayerTrack *card;
    for (NSUInteger i = 0; i < future.count; i++) {
        SPTPlayerTrack *track = future[i];
        if (isCoreQueued(track)) continue;
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
            if (!sCardTracks) sCardTracks = [NSMutableDictionary dictionary];
            sCardTracks[track.UID] = track;
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

#pragma mark - the order the user gave the DJ's rows

// The DJ's tracks as they have played, in the session's order, whole, for the steps back the core has no track for.
static NSMutableArray<SPTPlayerTrack *> *sPlayed;
// Whether the user has arranged the DJ's rows, the uids (base) of the groups (a card and its track, or a track) in
// their order, the rows of each as the DJ sent them, and a number that changes with the order, for the list's cache.
static BOOL sOrdered;
static NSMutableArray<NSString *> *sOrder;
static NSMutableDictionary<NSString *, NSArray<SPTPlayerTrack *> *> *sKept;
static NSUInteger sOrderVersion;
// The uids of DJ tracks the core came to that the user's order did not have first: they were skipped away from, not
// played, so they stay in the order (the core's own future has forgotten them).
static NSMutableSet<NSString *> *sBounced;
// When the player was last asked to step back (the previous button, or a replay here): an arrival at a track that has
// played, soon after, is the step back; any other is the track played again, as the newest.
static NSDate *sBackAsked;
// The uids of the DJ's tracks the user went past with a tap on a later row: hidden from the rows, but they are in the
// core's history and in sPlayed, so a step back (and the next after it) goes over them one by one. A track removed or
// played through the queue is not among them: a step back still goes past it.
static NSMutableSet<NSString *> *sPassed;
// The DJ track the next button was last sent back over the history to, and when: its arrival is the walk, not the core
// coming to a track that played.
static NSString *sWalkUID;
static NSDate *sWalkAt;
static NSTimer *sHeaderTimer;
static __weak UIViewController *sHeaderTimerPage;
static NSDate *sNativeQueueAt;
static __weak id sWrapper;
static SPTPlayerTrack *sSwipeRow;

static BOOL isCardRow(SPTPlayerTrack *row) {
    return [SGURIString(row.URI) hasPrefix:@"spotify:media:"];
}

// The uids of the DJ's tracks that played before this launch (sPlayed holds only this launch's, whole).
static NSMutableSet<NSString *> *sPlayedBefore;
// The queue page's table, for its Edit selection.
static __weak UITableView *sEditTable;

static BOOL wasPlayed(NSString *uid) {
    if ([sPlayedBefore containsObject:uid]) return YES;
    for (SPTPlayerTrack *played in sPlayed) if ([baseUID(played.UID) isEqualToString:uid]) return YES;
    return NO;
}

static NSMutableDictionary<NSString *, NSDictionary *> *sCopyOf;
static BOOL staysHidden(SPTPlayerTrack *track) {
    if (!isHidden(track) || [sPassed containsObject:baseUID(track.UID)]) return NO;
    // A context original hidden because its queue copy played remains a history entry.
    for (NSDictionary *copy in sCopyOf.allValues)
        if ([baseUID(copy[@"uid"]) isEqualToString:baseUID(track.UID)] &&
            [copy[@"uri"] isEqualToString:SGURIString(track.URI)]) return NO;
    return YES;
}

static NSUInteger playedIndex(NSString *uid) {
    for (NSUInteger i = 0; i < sPlayed.count; i++) if ([baseUID(sPlayed[i].UID) isEqualToString:uid]) return i;
    return NSNotFound;
}

// The player came to a track that has played, as a walk over the history and not as the core going back to it on its own:
// the one the next button was sent to, or the one that played right after the track the player was on.
static BOOL walkArrival(SPTPlayerTrack *track, NSString *leftUID) {
    NSString *uid = baseUID(track.UID);
    NSUInteger at = uid.length ? playedIndex(uid) : NSNotFound;
    if (at == NSNotFound) return NO;
    if (sWalkUID && sWalkAt && -sWalkAt.timeIntervalSinceNow < 4 && [sWalkUID isEqualToString:uid]) return YES;
    NSString *left = baseUID(leftUID);
    return at > 0 && left.length && [baseUID(sPlayed[at - 1].UID) isEqualToString:left];
}

static NSInteger placeOf(UITableView *table, NSIndexPath *path) {
    NSInteger place = path.row;
    for (NSInteger section = 0; section < path.section; section++) place += [table numberOfRowsInSection:section];
    return place;
}

// A track the user dragged from the hand-queued rows (the core's) into the DJ's: it is a row of the DJ's order now, by
// the uid (base) of its row, with the row and the core's own track it is made from. The core does not have it in its
// queue any more; it is put first in the core's queue when its turn in the order comes, and the row goes when it plays.
static NSMutableDictionary<NSString *, NSDictionary *> *sMoved;
static BOOL sPlayingMoved;

static NSDictionary *movedBySource(SPTPlayerTrack *track) {
    for (NSDictionary *entry in sMoved.allValues) {
        SPTPlayerTrack *src = entry[@"src"];
        if ([src.UID isEqualToString:track.UID] && [src.URI isEqual:track.URI]) return entry;
    }
    return nil;
}

// The DJ's session as the user left it (the order, what was removed, played or passed, the voices heard), kept in the
// defaults so a launch that goes on in the same session goes on with it. The core keeps the uids of the session's
// tracks over a launch; uids it no longer has match nothing and are let go.
static const NSUInteger kSavedMax = 300;
static id sPlayedContext;
static NSString *sSavedLine;

static NSArray<NSString *> *lastOf(id<NSFastEnumeration> uids) {
    NSMutableArray<NSString *> *all = [NSMutableArray array];
    for (NSString *uid in uids) if ([uid isKindOfClass:NSString.class] && uid.length) [all addObject:uid];
    return all.count > kSavedMax ? [all subarrayWithRange:NSMakeRange(all.count - kSavedMax, kSavedMax)] : all;
}

// The copies the core played in the DJ's place (q-uid -> the original's uid, uri, providers, title), below.
// Queue copies and their context original are one position in the user's history.
static NSString *historyUID(SPTPlayerTrack *track) {
    NSDictionary *copy = sCopyOf[track.UID];
    return baseUID(copy && [copy[@"uri"] isEqualToString:SGURIString(track.URI)] ? copy[@"uid"] : track.UID);
}
// The DJ track put in the core's queue ahead of its turn (below), and its uri as kept over a launch: the copy is still in
// the core's queue then, and was shown as a track queued by hand (above its own card) when it was not wanted any more.
static SPTPlayerTrack *sAheadQueued;
static NSString *sAheadBeforeLaunch;

static void saveSession(void) {
    if (!sDJActive || !sAheadContext) return;
    NSMutableArray<NSString *> *played = [NSMutableArray arrayWithArray:sPlayedBefore.allObjects];
    for (SPTPlayerTrack *t in sPlayed) if (t.UID.length) [played addObject:baseUID(t.UID)];
    NSDictionary *session = @{
        @"context": SGURIString(sAheadContext) ?: @"",
        @"ordered": @(sOrdered),
        @"order": lastOf(sOrder ?: @[]),
        @"hidden": lastOf(sHidden ?: [NSSet set]),
        @"played": lastOf(played),
        @"voiced": lastOf(sVoiced ?: [NSSet set]),
        @"copies": sCopyOf ?: @{},
        @"ahead": sAheadQueued ? SGURIString(sAheadQueued.URI) ?: @"" : @"",
    };
    NSString *line = [NSString stringWithFormat:@"%@", session];
    if ([line isEqualToString:sSavedLine]) return;
    sSavedLine = line;
    SGPrefsWriteUnmemoized(^{ [NSUserDefaults.standardUserDefaults setObject:session forKey:SGKeyDJQueueSession]; });
}

// Once a launch, at the first state of the DJ's session: what was kept of it, if it is the same session.
static void restoreSession(SPTPlayerState *state) {
    static BOOL done;
    if (done) return;
    done = YES;
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyDJQueueSession];
    NSString *context = SGURIString(state.contextURI);
    if (!saved || !context.length || ![saved[@"context"] isEqual:context]) return;
    NSSet *(^set)(NSString *) = ^NSSet *(NSString *key) { return [NSSet setWithArray:lastOf([saved[key] isKindOfClass:NSArray.class] ? saved[key] : @[])]; };
    sAheadContext = state.contextURI;
    sPlayedContext = state.contextURI;
    sPlayed = [NSMutableArray array];
    sHidden = [set(@"hidden") mutableCopy];
    sVoiced = [set(@"voiced") mutableCopy];
    sPlayedBefore = [set(@"played") mutableCopy];
    sOrder = [lastOf([saved[@"order"] isKindOfClass:NSArray.class] ? saved[@"order"] : @[]) mutableCopy];
    sOrdered = [saved[@"ordered"] boolValue] && sOrder.count;
    if ([saved[@"ahead"] isKindOfClass:NSString.class] && [saved[@"ahead"] length]) sAheadBeforeLaunch = saved[@"ahead"];
    if ([saved[@"copies"] isKindOfClass:NSDictionary.class]) {
        sCopyOf = [NSMutableDictionary dictionary];
        [(NSDictionary *)saved[@"copies"] enumerateKeysAndObjectsUsingBlock:^(id key, id info, BOOL *stop) {
            if ([key isKindOfClass:NSString.class] && [info isKindOfClass:NSDictionary.class] && [info[@"uid"] isKindOfClass:NSString.class] &&
                [info[@"uri"] isKindOfClass:NSString.class]) sCopyOf[key] = info;
        }];
    }
    sOrderVersion++;
    SGLog(@"queue: the DJ's session goes on from the last launch: %lu in the user's order%@, %lu hidden, %lu played", (unsigned long)sOrder.count,
          sOrdered ? @"" : @" (none arranged)", (unsigned long)sHidden.count, (unsigned long)sPlayedBefore.count);
    // A copy put in ahead before the launch is still in the core's queue: it is taken up again (queueAhead) once the
    // rows are made, not shown as a track queued by hand until the next track.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ refreshReaders(); });
}

static void forgetOrder(void) {
    [sMoved removeAllObjects];
    sOrdered = NO;
    [sOrder removeAllObjects];
    [sKept removeAllObjects];
    [sBounced removeAllObjects];
    sOrderVersion++;
}

// The DJ's rows in the user's order: the groups the core still names and the ones kept from before, without the ones
// that have played, are hidden or are playing now; what the core names that is new goes at the end.
// The group playing now stays in sOrder until it has played (it is only not a row): the queue's readers and the
// history observer hear of a state in either order, and enforceOrder holds the player to sOrder by it. Taken out here
// first, the core's arrival at a group the user had put later was not seen as one, and it played.
static NSMutableArray<SPTPlayerTrack *> *arrangedRows(NSArray<SPTPlayerTrack *> *shown, SPTPlayerState *state) {
    if (!sKept) sKept = [NSMutableDictionary dictionary];
    NSString *current = inDJ(state.track) ? baseUID(state.track.UID) : nil;
    NSMutableArray<NSString *> *seen = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray<SPTPlayerTrack *> *> *fresh = [NSMutableDictionary dictionary];
    for (SPTPlayerTrack *row in shown) {
        NSString *uid = baseUID(row.UID);
        if (!uid.length) continue;
        if (!fresh[uid]) { fresh[uid] = [NSMutableArray array]; [seen addObject:uid]; }
        [fresh[uid] addObject:row];
    }
    for (NSString *uid in seen) {
        if (wasPlayed(uid) || ([uid isEqualToString:current] && ![sBounced containsObject:uid])) continue;
        sKept[uid] = fresh[uid];
    }
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSString *uid in sOrder) if (sKept[uid] && ![order containsObject:uid]) [order addObject:uid];
    for (NSString *uid in seen) if (sKept[uid] && ![order containsObject:uid]) [order addObject:uid];
    for (NSString *uid in [sKept.allKeys copy]) {
        if (wasPlayed(uid) || [sHidden containsObject:uid]) {
            [sKept removeObjectForKey:uid];
            [order removeObject:uid];
        }
    }
    sOrder = order;
    NSMutableArray<SPTPlayerTrack *> *out = [NSMutableArray array];
    for (NSString *uid in order) {
        if ([uid isEqualToString:current] && ![sBounced containsObject:uid]) continue;
        [out addObjectsFromArray:sKept[uid]];
    }
    return out;
}

// The index of the track of the "Up next" card that is the first of the DJ's rows (the card is the row before it),
// -1 when the first of the DJ's rows is not a card. The card and its track are one: nothing is put above or between them.
static NSInteger topPairEnd(NSArray<SPTPlayerTrack *> *list) {
    for (NSUInteger i = 0; i < list.count; i++) {
        if (isCoreQueued(list[i])) continue;
        return isCardRow(list[i]) && i + 1 < list.count ? (NSInteger)i + 1 : -1;
    }
    return -1;
}

// A hand-queued row of the core's dragged into the DJ's rows: its row of the DJ's order (nil when the drag is not that:
// it stays among the hand-queued, or goes above the "Up next" card). The core's queue is given without it.
static void takeOutOfCoreQueue(SPTPlayerTrack *src) {
    id queue = sLastQueue, player = queuePlayer();
    if (!queue || !player) { SGLog(@"queue: moved %@: no queue or player to take it out of the core's queue", src.trackTitle); return; }
    NSMutableArray<SPTPlayerTrack *> *left = [NSMutableArray array];
    for (SPTPlayerTrack *t in [queue valueForKey:@"nextTracks"]) {
        if (!isCoreQueued(t) || ([t.UID isEqualToString:src.UID] && [t.URI isEqual:src.URI])) continue;
        [left addObject:t];
    }
    id copy = [queue copy];
    [copy setValue:left forKey:@"nextTracks"];
    SGLog(@"queue: moved %@ [%@]: the core's queue is set to its %lu hand-queued tracks without it", src.trackTitle, src.UID, (unsigned long)left.count);
    SEL setQueue = NSSelectorFromString(@"setQueue:options:loggingParams:");
    if (![player respondsToSelector:setQueue]) { SGLog(@"queue: moved %@: the player has no setQueue", src.trackTitle); return; }
    id result = ((id (*)(id, SEL, id, id, id))objc_msgSend)(player, setQueue, copy, nil, nil);
    SGLog(@"queue: moved %@: setQueue answered %@", src.trackTitle, result);
}

static SPTPlayerTrack *movedRowFor(NSArray<SPTPlayerTrack *> *list, NSInteger from, NSInteger to) {
    SPTPlayerTrack *src = list[from];
    if (!isCoreQueued(src)) return nil;
    NSInteger queued = 0;
    for (SPTPlayerTrack *t in list) { if (isCoreQueued(t)) queued++; else break; }
    // Still among the hand-queued: the page's own reorder.
    if (to < queued) return nil;
    NSInteger pairEnd = topPairEnd(list);
    if (pairEnd >= 0 && to < pairEnd) {
        SGLog(@"queue: moved %@: not taken above the Up next card", src.trackTitle);
        return nil;
    }
    NSString *uid = [@"m" stringByAppendingString:src.UID ?: @""];
    NSMutableDictionary *metadata = [src.metadata mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *instance = sInjected.firstObject.metadata[@"page_instance_id"];
    if (instance) metadata[@"page_instance_id"] = instance;
    SPTPlayerTrack *row = copyOf(src, metadata, uid);
    @try { [row setValue:@"context" forKey:@"provider"]; } @catch (NSException *e) { SGLog(@"queue: moved %@: no provider to set: %@", src.trackTitle, e.reason); }
    if (!sMoved) sMoved = [NSMutableDictionary dictionary];
    sMoved[uid] = @{@"row": row, @"src": src};
    SGLog(@"queue: moved %@ [%@] from the hand-queued into the DJ's rows as %@, at %ld", src.trackTitle, src.UID, uid, (long)to);
    takeOutOfCoreQueue(src);
    return row;
}

// A drag on the page: the row at `from` of the list it shows is now at `to`. A card is moved with its track, and a
// track with its card. Only the DJ's rows are arranged; NO when the drag was not one.
static BOOL arrangeByDrag(NSArray<SPTPlayerTrack *> *list, NSInteger from, NSInteger to) {
    NSInteger count = (NSInteger)list.count;
    if (from < 0 || to < 0 || from >= count || to >= count || from == to) return NO;
    SPTPlayerTrack *moved = list[from];
    if (indexIn(sInjected, moved) == NSNotFound) {
        SPTPlayerTrack *row = movedRowFor(list, from, to);
        if (!row) return NO;
        NSMutableArray<SPTPlayerTrack *> *swapped = [list mutableCopy];
        swapped[from] = row;
        list = swapped;
        moved = row;
        sInjected = [sInjected arrayByAddingObject:row];
    }
    // Above the "Up next" card (or between it and its track) goes nothing from below them, and the card is not moved.
    NSInteger pairEnd = topPairEnd(list);
    if (pairEnd >= 0 && (isCardRow(moved) || (from > pairEnd && to <= pairEnd))) {
        SGLog(@"queue: the drag of %@ above the Up next card is not taken", moved.trackTitle);
        return NO;
    }
    NSMutableArray<SPTPlayerTrack *> *after = [list mutableCopy];
    [after removeObjectAtIndex:from];
    [after insertObject:moved atIndex:to];
    NSString *group = baseUID(moved.UID);
    NSString *before = nil;
    for (NSInteger i = to + 1; i < (NSInteger)after.count && !before; i++) {
        if (indexIn(sInjected, after[i]) == NSNotFound) continue;
        NSString *uid = baseUID(after[i].UID);
        if (![uid isEqualToString:group]) before = uid;
    }
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (SPTPlayerTrack *row in list) {
        if (indexIn(sInjected, row) == NSNotFound) continue;
        NSString *uid = baseUID(row.UID);
        if (![uid isEqualToString:group] && ![order containsObject:uid]) [order addObject:uid];
    }
    NSUInteger at = before ? [order indexOfObject:before] : order.count;
    [order insertObject:group atIndex:at];
    sOrder = order;
    sOrdered = YES;
    sOrderVersion++;
    SGLog(@"queue: the DJ's rows are arranged by the drag, %@ [%@] from %ld to %ld, now %lu groups", moved.trackTitle, moved.UID,
          (long)from, (long)to, (unsigned long)order.count);
    return YES;
}

// The first of the DJ's tracks in the user's order that has not played: the player's own track.
static SPTPlayerTrack *wantedNext(void) {
    for (NSString *uid in sOrder) {
        if ([sHidden containsObject:uid] || wasPlayed(uid)) continue;
        for (SPTPlayerTrack *row in sKept[uid]) if (!isCardRow(row) && isDJTrack(row)) return originalOf(row);
    }
    return nil;
}

static NSString *trackKey(SPTPlayerTrack *track) {
    return [NSString stringWithFormat:@"%@|%@", SGURIString(track.URI), track.UID];
}

// The page's queue wrapper (the one its swipes go through), or one made for the player the queue's readers are told by.
static id queueWrapper(void) {
    id wrapper = sWrapper;
    if (wrapper) return wrapper;
    Class wrapperClass = NSClassFromString(@"SPTPlayerQueueWrapperImpl");
    SEL initWithPlayer = NSSelectorFromString(@"initWithPlayer:");
    if (![wrapperClass instancesRespondToSelector:initWithPlayer]) return nil;
    // init consumes its receiver, which ARC does not know through a cast objc_msgSend: both on void *, the result handed
    // to ARC once (AGENTS.md).
    void *fresh = ((void *(*)(Class, SEL))objc_msgSend)(wrapperClass, @selector(alloc));
    void *made = fresh ? ((void *(*)(void *, SEL, id))objc_msgSend)(fresh, initWithPlayer, queuePlayer()) : NULL;
    return made ? CFBridgingRelease(made) : nil;
}

// A moved track's turn: the core does not have it, so it is put first in the core's queue and the player goes next.
static BOOL queueMovedNext(SPTPlayerTrack *target) {
    if (!movedBySource(target)) return NO;
    id wrapper = queueWrapper();
    SEL playNext = @selector(queueTrackPlayNext:);
    if (![wrapper respondsToSelector:playNext]) {
        SGLog(@"queue: moved %@: no queue wrapper to put it first with, it plays when the core comes to it", target.trackTitle);
        return NO;
    }
    sPlayingMoved = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ sPlayingMoved = NO; });
    id result = ((id (*)(id, SEL, id))objc_msgSend)(wrapper, playNext, target);
    SGLog(@"queue: moved %@ [%@] is put first in the core's queue, it answered %@", target.trackTitle, target.UID, result);
    return YES;
}

// The first item of the core's own order still to come for the DJ: not queued by hand, not played, not hidden; a voice
// whose card has not played counts.
// It ends at the delimiter: after it the core names the whole session again as stand-ins, whose uids are not the
// tracks' (the segment's last track came up as its own next, and was queued after itself).
static SPTPlayerTrack *coreNextUnplayed(SPTPlayerState *state) {
    for (SPTPlayerTrack *t in state.future) {
        if (isCoreQueued(t)) continue;
        if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
        NSString *uid = baseUID(t.UID);
        BOOL voice = [SGURIString(t.URI) hasPrefix:@"spotify:media:"];
        if (!uid.length || (!voice && !isDJTrack(t)) || wasPlayed(uid) || [sHidden containsObject:uid]) continue;
        if (voice && [sVoiced containsObject:uid]) continue;
        return t;
    }
    return nil;
}

// Set while a skip of ours is asked, so the next hook does not take it for the user's next; and while a queue command of
// ours is given to the core, so a setQueue it makes is not taken for the page's list of rows.
static BOOL sAdvancing, sOwnQueueCommand;

static id skipForward(SPTPlayerTrack *to) {
    sAdvancing = YES;
    id result = to ? [(id<SPTPlayer>)queuePlayer() skipToNextTrackWithOptions:nil track:to]
                   : [(id<SPTPlayer>)queuePlayer() skipToNextTrackWithOptions:nil];
    sAdvancing = NO;
    return result;
}

// The DJ tracks played here from the core's queue, by the uid of the core's copy: the copy is the user's track of the DJ's,
// and the now playing screens are shown it as that (djLens), not as a track queued by hand.
// What is kept of the original is what that needs, and plain, so it is kept over a launch with the session (a launch
// during a copy showed it as a track queued by hand, "Playing Queue"): uri, uid, provider, its metadata's provider, title.
static void noteCopy(SPTPlayerTrack *copy, SPTPlayerTrack *original) {
    if (!copy.UID.length || !original.UID.length) return;
    if (!sCopyOf) sCopyOf = [NSMutableDictionary dictionary];
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"uri"] = SGURIString(original.URI) ?: @"";
    info[@"uid"] = original.UID;
    if (original.provider) info[@"provider"] = original.provider;
    if ([original.metadata[@"provider"] isKindOfClass:NSString.class]) info[@"mprovider"] = original.metadata[@"provider"];
    if (copy.trackTitle.length) info[@"title"] = copy.trackTitle;
    sCopyOf[copy.UID] = info;
    // Keep the same span as the saved session. A DJ session can outlive 50 tracks; evicting an internal copy that's
    // still in Spotify's future makes it look hand-queued and lets the original row play again beside it.
    while (sCopyOf.count > kSavedMax) [sCopyOf removeObjectForKey:sCopyOf.allKeys.firstObject];
}

// The DJ track put in the core's queue ahead of its turn (the player's own track; the core's copy has a q uid): when the
// track playing ends by itself, the core goes on to its queue first, so the user's next plays and not the core's own for
// a moment before a skip away from it. Kept while the user's order has it next; taken out of the core's queue when not.
static NSDate *sAheadAt;
// Set while advanceTo waits for a queued copy to reach the state: nothing is queued ahead meanwhile.
static BOOL sQueueWaiting;
// Set from a tap on a row until the player is sent on: the rows the tap hid are not taken for the user's order then.
static BOOL sTapPending;

static BOOL sameGroup(SPTPlayerTrack *a, SPTPlayerTrack *b) {
    return a && b && [historyUID(a) isEqualToString:historyUID(b)];
}

// The core's queued copy of `track` among the tracks queued by hand that come first in the future (the last such, the
// one put in latest), and whether any track queued by hand comes after it.
static SPTPlayerTrack *queuedCopyOf(SPTPlayerTrack *track, SPTPlayerState *state, BOOL *notLast) {
    NSString *uri = SGURIString(track.URI);
    SPTPlayerTrack *found = nil;
    BOOL after = NO;
    // Not only at the front: after a step back the core has the track it left before its queue (a copy put in ahead was
    // not found there, and a second one was put in).
    for (SPTPlayerTrack *t in state.future) {
        if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
        if (!isCoreQueued(t)) continue;
        if (uri.length && [SGURIString(t.URI) isEqualToString:uri]) { found = t; after = NO; }
        else if (found) after = YES;
    }
    if (notLast) *notLast = after;
    return found;
}

// Takes the core's latest queued copy of `uri` out of its queue: the core is given its queue without it (only tracks it
// queued, never the DJ's own).
// What was last taken out, and when: the core may already be going to it, and plays it.
static SPTPlayerTrack *sDropped;
static NSDate *sDroppedAt;

static void dropQueuedTries(NSString *uri, NSString *why, int tries);
static void dropQueued(NSString *uri, NSString *why) { dropQueuedTries(uri, why, 0); }
static void dropQueuedTries(NSString *uri, NSString *why, int tries) {
    id queue = sLastQueue, player = queuePlayer();
    SEL setQueue = NSSelectorFromString(@"setQueue:options:loggingParams:");
    if (!queue || ![player respondsToSelector:setQueue]) { SGLog(@"queue: %@ could not be taken out of the core's queue (%@)", uri, why); return; }
    // The whole list, as the page sends it for a removal, with that one copy left out: given only its queued tracks,
    // the core changed nothing (the copy played all the same).
    NSMutableArray<SPTPlayerTrack *> *left = [[queue valueForKey:@"nextTracks"] mutableCopy];
    NSInteger drop = -1;
    for (NSInteger i = 0; i < (NSInteger)left.count; i++) {
        if ([SGURIString(left[i].URI) isEqualToString:@"spotify:delimiter"]) break;
        if (!isCoreQueued(left[i])) continue;
        if ([SGURIString(left[i].URI) isEqualToString:uri]) drop = i;
    }
    if (drop < 0) {
        if (tries < 0) return;   // a check after a removal: the readers' queue has it gone already
        // Put in a moment ago, it may not have reached the queue the readers were told yet: looked for again.
        if (tries < 8) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (sAheadQueued && [SGURIString(sAheadQueued.URI) isEqualToString:uri]) return;   // wanted again meanwhile
                dropQueuedTries(uri, why, tries + 1);
            });
        } else {
            SGLog(@"queue: %@ is not in the core's queue to take out (%@)", uri, why);
        }
        return;
    }
    [left removeObjectAtIndex:drop];
    id copy = [queue copy];
    [copy setValue:left forKey:@"nextTracks"];
    sOwnQueueCommand = YES;
    id result = ((id (*)(id, SEL, id, id, id))objc_msgSend)(player, setQueue, copy, nil, nil);
    sOwnQueueCommand = NO;
    SGLog(@"queue: %@ is taken out of the core's queue (%@), it answered %@", uri, why, result);
    // Sent with the queue the readers were told last, which may be one from before the player moved on (a copy taken out
    // as the player came to the next track stayed, and showed as queued by hand): looked at again, and sent again with
    // the queue as it is then.
    if (tries >= 100) return;
    int checks = tries < 0 ? -tries : 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (sAheadQueued && [SGURIString(sAheadQueued.URI) isEqualToString:uri]) return;   // wanted again meanwhile
        BOOL there = NO;
        for (SPTPlayerTrack *t in SGPlayerState().future) {
            if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
            if (isCoreQueued(t) && [SGURIString(t.URI) isEqualToString:uri]) { there = YES; break; }
        }
        if (!there) return;
        if (checks >= 3) { SGLog(@"queue: %@ is still in the core's queue after %d tries (%@)", uri, checks + 1, why); return; }
        SGLog(@"queue: %@ is still in the core's queue, taken out again (%@)", uri, why);
        dropQueuedTries(uri, why, -(checks + 1));
    });
}

static id queueInCore(SPTPlayerTrack *track) {
    id wrapper = queueWrapper();
    SEL queueTrack = NSSelectorFromString(@"queueTrack:");
    if (![wrapper respondsToSelector:queueTrack]) return nil;
    // Only the track: the core takes no voice (spotify:media:) into its queue; asked to, it answered and did not
    // put it in (9.1.90), so a track whose card has not played loses its voice when it is played from the queue.
    sOwnQueueCommand = YES;
    id result = ((id (*)(id, SEL, id))objc_msgSend)(wrapper, queueTrack, track);
    sOwnQueueCommand = NO;
    return result ?: @YES;
}


// Puts the user's next in the core's queue before the track playing ends, or takes out the one put there that is not the
// next any more. Nothing is queued when the core comes to the user's next anyway (its voice then plays), on a voice, or for
// a track dragged in from the hand-queued ones (that one is put first when its turn comes).
// The DJ track a skip of ours was last sent to, and when: if the core plays a copy of it from its queue instead (one put
// in before a launch), the copy is that track, not one queued by hand.
static SPTPlayerTrack *sSkipTarget;
static NSDate *sSkipAt;
static id landAtSegmentEnd(SPTPlayerTrack *play);
static SPTPlayerTrack *playedAfter(SPTPlayerTrack *current);
static BOOL segmentSpent(SPTPlayerState *state);
static BOOL isUnspent(SPTPlayerTrack *t);
// Set from the pause before a hand-over to the next segment until the player resumes.
static BOOL sHandingOver;
static BOOL onlyThisLeft(SPTPlayerState *state, SPTPlayerTrack *target);

// `track` has an "Up next" card before it in the core's future that has not been heard (the DJ's words after a track
// have its uid too, and come after it).
static BOOL cardUnheard(SPTPlayerState *state, SPTPlayerTrack *track) {
    for (SPTPlayerTrack *t in state.future) {
        if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
        if (isCoreQueued(t) || !sameGroup(t, track)) continue;
        if (![SGURIString(t.URI) hasPrefix:@"spotify:media:"]) return NO;   // the track itself comes first
        return ![sVoiced containsObject:t.UID];
    }
    return NO;
}

static void queueAhead(void) {
    SPTPlayerState *state = SGPlayerState();
    if (!sDJActive || sAdvancing || sQueueWaiting || sTapPending || sHandingOver || !isDJSession(state)) return;
    SPTPlayerTrack *current = state.track, *want = nil;
    // On a voice (the DJ's words after a track, or a card's), a track about to be skipped or a moved one about to play,
    // what is put in stays as it is: the core may be on its way to it already (a copy taken out as the voice began
    // played all the same, and was put in again).
    if (!current || [SGURIString(current.URI) hasPrefix:@"spotify:media:"] || isHidden(current) || sPlayingMoved) return;
    // What the core plays when this track ends: its next item that is not the track's own (the DJ's words after a track
    // have its uid), past the tracks queued by hand.
    SPTPlayerTrack *coming = nil;
    for (SPTPlayerTrack *t in state.future) {
        if (isCoreQueued(t) || sameGroup(t, current)) continue;
        coming = t;
        break;
    }
    // The user's next, when the core would come to a track that played or was removed first (it sounded for a moment
    // before the skip past it). Only an order the user arranged needs a copy ahead: the core has no other way to play
    // it. Without one, the core's own next is skipped to directly (the next button, skipPastSpent just before the
    // track's end), so nothing is put in the queue, where Spotify draws it as a track queued by hand. Nor on a walk
    // back over the history: the core has those tracks to come, and the next button skips straight to the one that
    // played after this.
    if (sOrdered && !playedAfter(current)) want = wantedNext();
    if (want && (movedBySource(want) || sameGroup(want, current) || sameGroup(want, coming) ||
                 [SGURIString(current.URI) isEqualToString:SGURIString(want.URI)])) want = nil;
    // A track whose card has not played is left to the core, which plays the card's voice first. The card is looked for
    // in the whole future, not only as the core's next: that may be the DJ's words after the track playing, and the
    // card's track was put in ahead and played without its card.
    if (want && cardUnheard(state, want)) want = nil;
    // The copy put in before the launch: taken up when it is still the one wanted (below), taken out when not.
    if (sAheadBeforeLaunch && !sAheadQueued) {
        NSString *uri = sAheadBeforeLaunch;
        sAheadBeforeLaunch = nil;
        BOOL there = NO;
        for (SPTPlayerTrack *t in state.future) if (isCoreQueued(t) && [SGURIString(t.URI) isEqualToString:uri]) there = YES;
        if (there && ![SGURIString(want.URI) isEqualToString:uri]) {
            dropQueued(uri, @"put in ahead before the launch, not the user's next now");
            sSignature = nil;
        }
    }
    if (sAheadQueued && !sameGroup(sAheadQueued, want)) {
        sDropped = sAheadQueued;
        sDroppedAt = [NSDate date];
        dropQueued(SGURIString(sAheadQueued.URI), @"no longer the user's next");
        sAheadQueued = nil;
    }
    if (!want) return;
    BOOL notLast = NO;
    SPTPlayerTrack *copy = sAheadQueued ? queuedCopyOf(sAheadQueued, state, &notLast) : nil;
    // A track queued by hand after it is to play before the DJ's: it is put in again, behind that one.
    if (copy && notLast) {
        dropQueued(SGURIString(sAheadQueued.URI), @"a track was queued by hand after it");
        sAheadQueued = nil;
    }
    // Taken out by the page (Clear, a swipe) a while after it was put in: it is put in again.
    if (sAheadQueued && !copy && sAheadAt && -sAheadAt.timeIntervalSinceNow > 2) {
        SGLog(@"queue: %@, put in ahead, is no longer in the core's queue", sAheadQueued.trackTitle);
        sAheadQueued = nil;
    }
    if (sAheadQueued) return;
    // A copy of it the core has already (put back in its queue by a step back) is the one: no second is put in.
    SPTPlayerTrack *have = queuedCopyOf(want, state, &notLast);
    if (have && !notLast) {
        sAheadQueued = want;
        sAheadAt = [NSDate date];
        noteCopy(have, want);
        SGLog(@"queue: %@ [%@], the user's next, is in the core's queue already", want.trackTitle, want.UID);
        // Its copy is a row of the DJ's from now on, not one queued by hand.
        sSignature = nil;
        refreshReaders();
        return;
    }
    if (!queueInCore(want)) { SGLog(@"queue: no queue wrapper to put %@ in ahead with", want.trackTitle); return; }
    sAheadQueued = want;
    sAheadAt = [NSDate date];
    SGLog(@"queue: %@ [%@], the user's next, is put in the core's queue ahead of its turn", want.trackTitle, want.UID);
}

// Goes forward to `target`, a DJ track, as any next goes (the now playing screens move on to it):
// - the core comes to it next anyway, past what has played or is hidden: a skip to it, through its voice when
//   `voiceFirst` and its card has not played (a skip forward lands on the first item with the uid, the voice);
// - else it is queued (the core's own copy, a uid of its own) and the player goes on to it there. The core keeps its
//   place before the DJ's tracks it has not come to, so a card the user put later still has its voice when its turn
//   comes; the DJ's row of the track is hidden, and its own copy passed when the core comes to it. A play next does not
//   do: the core takes a context track it is given in a setQueue for the context's, and goes on without it (9.1.90).
// The core is never stepped back to a track of the DJ's: the now playing screens draw a step back backwards, and it
// lands on the track after a voice, the voice never played (9.1.90).
// `target`'s item in the core's future (its voice first when it has one that has not been heard), when everything the core
// has before it is spent: played, removed, passed or a voice heard. The core can be skipped straight to it.
static SPTPlayerTrack *reachableInFuture(SPTPlayerState *state, SPTPlayerTrack *target) {
    for (SPTPlayerTrack *t in state.future) {
        if (isCoreQueued(t)) continue;
        if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
        BOOL voice = [SGURIString(t.URI) hasPrefix:@"spotify:media:"];
        if (sameGroup(t, target)) {
            if (voice && [sVoiced containsObject:t.UID]) continue;   // its voice was heard: the track itself
            return t;
        }
        if (isUnspent(t)) return nil;
    }
    return nil;
}

static id advanceTo(SPTPlayerTrack *target, BOOL voiceFirst) {
    if (queueMovedNext(target)) return skipForward(nil);
    SPTPlayerState *state = SGPlayerState();
    SPTPlayerTrack *next = coreNextUnplayed(state);
    BOOL aheadThere = sameGroup(sAheadQueued, target) && queuedCopyOf(sAheadQueued, state, NULL);
    // A track the core has still to come, with only tracks that played, were removed or were passed before it (a step
    // back and then forward again): skipped to as it is, not put in the queue.
    if (!aheadThere && !(next && sameGroup(next, target))) {
        SPTPlayerTrack *reach = reachableInFuture(state, target);
        if (reach) next = reach;
    }
    // The last of the segment that has not played, with ones that played or were removed after it in the core's order:
    // gone to directly, the core is not on its last track and makes no next segment until it has played through those.
    if (!aheadThere && onlyThisLeft(state, target)) {
        if (sAheadQueued) dropQueued(SGURIString(sAheadQueued.URI), @"the segment's last is played");
        sAheadQueued = nil;
        id landed = landAtSegmentEnd(target);
        if (landed) return landed;
    }
    sSkipTarget = target;
    sSkipAt = [NSDate date];
    if (next && !aheadThere && [baseUID(next.UID) isEqualToString:baseUID(target.UID)]) {
        // A copy put in ahead is not wanted when the core goes to the track itself.
        if (sAheadQueued) {
            sDropped = sAheadQueued;
            sDroppedAt = [NSDate date];
            dropQueued(SGURIString(sAheadQueued.URI), @"the core goes to the track itself");
            sAheadQueued = nil;
        }
        BOOL voice = [SGURIString(next.URI) hasPrefix:@"spotify:media:"];
        SGLog(@"queue: on to %@%@ [%@], the core's next", voice && voiceFirst ? @"the voice of " : @"", target.trackTitle, target.UID);
        return skipForward(voice && !voiceFirst ? target : next);
    }
    // Already put in ahead of its turn: the player goes on to that copy. Another one put in ahead goes out first.
    id result = nil;
    BOOL ahead = sameGroup(sAheadQueued, target);
    if (sAheadQueued && !ahead) dropQueued(SGURIString(sAheadQueued.URI), @"another track is played");
    sAheadQueued = nil;
    if (ahead) {
        SGLog(@"queue: %@ [%@] is played from the core's queue, where it was put ahead", target.trackTitle, target.UID);
        result = @YES;
    } else {
        SGLog(@"queue: %@ [%@] is played through the core's queue (the core has %@ [%@] first)", target.trackTitle, target.UID,
              next.trackTitle ?: SGURIString(next.URI), next.UID);
        result = queueInCore(target);
        if (!result) {
            SGLog(@"queue: no queue wrapper to queue %@ with, a skip to it", target.trackTitle);
            return skipForward(target);
        }
    }
    hideTrack(target, @"played through the queue");
    refreshReaders();
    // The queued copy reaches the state a moment later: the player goes on once the core has it to come.
    NSString *uri = SGURIString(target.URI);
    __block int tries = 0;
    __block void (^wait)(void);
    sQueueWaiting = YES;
    void (^go)(void) = ^{
        BOOL there = NO;
        SPTPlayerTrack *copy = nil;
        for (SPTPlayerTrack *t in SGPlayerState().future) {
            if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
            if (!isCoreQueued(t)) continue;
            if ([SGURIString(t.URI) isEqualToString:uri]) copy = t;   // the last, the one just put in
        }
        if (copy) { there = YES; noteCopy(copy, target); }
        if (!there && ++tries < 30) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), wait);
            return;
        }
        wait = nil;
        sQueueWaiting = NO;
        if (!there) SGLog(@"queue: %@ did not come first in the core's queue, the player goes on anyway", target.trackTitle);
        // To that copy, not to the first of the core's queue: a copy put in ahead for another track may still be there
        // (taking it out had not come through, and a tap played it in place of the tapped track).
        skipForward(copy);
    };
    wait = go;
    dispatch_async(dispatch_get_main_queue(), wait);
    return result;
}

// The core has come to a DJ track of its own order. If the user's order has another first, the player is skipped to it
// (its card's voice is skipped on arrival, as for a tap). YES when that was asked, the track is not taken as played.
// Gone on from a track the user's order had last, the core comes back to the tracks it was skipped past, which have
// played: the player goes on to the first that has not.
// `arrived`: the state is the player's coming to this track, not a pause, a resume or a load on the same one.
static BOOL enforceOrder(SPTPlayerState *state, BOOL arrived, BOOL walking) {
    SPTPlayerTrack *current = state.track;
    NSString *uid = baseUID(current.UID);
    if (!sOrdered || !uid.length || !inDJ(current)) return NO;
    BOOL steppedBack = sBackAsked && -sBackAsked.timeIntervalSinceNow < 4;
    // A walk over the history (a step back, the next after it, a track going on to the one that played after it) is the
    // user's, not the core coming back to tracks it was skipped past.
    if (walking || steppedBack) return NO;
    BOOL replay = arrived && isDJTrack(current) && wasPlayed(uid) && !steppedBack;
    if (!replay && ![sOrder containsObject:uid]) return NO;
    SPTPlayerTrack *want = wantedNext();
    if (replay && !want) want = coreNextUnplayed(state);
    if (!want || [baseUID(want.UID) isEqualToString:uid]) return NO;
    static NSString *lastKey;
    static NSDate *lastAt;
    NSString *key = [NSString stringWithFormat:@"%@>%@", uid, want.UID];
    if ([key isEqualToString:lastKey] && lastAt && -lastAt.timeIntervalSinceNow < 3) return NO;
    lastKey = key;
    lastAt = [NSDate date];
    if (!sBounced) sBounced = [NSMutableSet set];
    [sBounced addObject:uid];
    sSkipVoiceUID = nil;
    SGLog(@"queue: the player came to %@ [%@]%@, the user's order has %@ [%@] first, skipping to it", current.trackTitle, current.UID,
          replay ? @", which played" : @"", want.trackTitle, want.UID);
    dispatch_async(dispatch_get_main_queue(), ^{ advanceTo(want, YES); });
    return YES;
}

// The DJ track that played right after `current`, when the player has been taken back over played tracks; nil at the
// newest one.
static SPTPlayerTrack *playedAfter(SPTPlayerTrack *current) {
    NSString *uid = historyUID(current);
    for (NSUInteger i = 0; i + 1 < sPlayed.count; i++) {
        if (![baseUID(sPlayed[i].UID) isEqualToString:uid]) continue;
        // Not the removed ones it went past (the segment's last a hand-over lands on); the ones the user passed with a tap are
        // part of the way, one by one.
        for (NSUInteger j = i + 1; j < sPlayed.count; j++) if (!staysHidden(sPlayed[j])) return originalOf(sPlayed[j]);
        return nil;
    }
    return nil;
}

// The next button while the user's order is on: the core would go to its own next DJ track, which would sound for a
// moment before enforceOrder skips away from it. The skip is asked for the user's first track at once instead, so the
// tracks passed over are never played and stay in the order. Past the user's order (or with none), the core's own next
// that has not played and was not removed, when the core would come to others first: they are passed in one skip, not
// played for a moment each. nil when the core's next is to be left alone.
static SPTPlayerTrack *redirectedNext(void) {
    SPTPlayerState *state = SGPlayerState();
    SPTPlayerTrack *current = state.track;
    // On a track queued by hand (or one played here through the queue), the user's order still says what comes after.
    if (sPlayingMoved || !current || !(inDJ(current) || isCoreQueued(current)) ||
        [SGURIString(current.URI) hasPrefix:@"spotify:media:"]) return nil;
    // Gone back over tracks that have played, the next one is the one that played after this, not the user's first
    // new track: the new part of the order is reached once the played ones are.
    SPTPlayerTrack *replay = playedAfter(current);
    SPTPlayerTrack *want = replay ?: (sOrdered ? wantedNext() : nil);
    if (!want) {
        SPTPlayerTrack *coreNext = state.future.firstObject, *next = coreNextUnplayed(state);
        if (!next || !coreNext || isCoreQueued(coreNext) || [trackKey(next) isEqualToString:trackKey(coreNext)]) return nil;
        SGLog(@"queue: next pressed on %@, the core's next that has not played is %@ [%@], skipping to it", current.trackTitle,
              next.trackTitle ?: SGURIString(next.URI), next.UID);
        return next;
    }
    if ([baseUID(want.UID) isEqualToString:baseUID(current.UID)]) return nil;
    // A track queued by hand comes first, and the core's own next is the one to be left alone when it is the user's
    // first too (the core goes to it, and its voice plays).
    SPTPlayerTrack *coreNext = SGPlayerState().future.firstObject;
    if (!replay && coreNext && (isCoreQueued(coreNext) || [baseUID(coreNext.UID) isEqualToString:baseUID(want.UID)])) return nil;
    // The voice that introduces the track plays (the skip goes through it): only a tap on a track's row passes it.
    sSkipVoiceUID = nil;
    if (replay) {
        sWalkUID = baseUID(want.UID);
        sWalkAt = [NSDate date];
    }
    SGLog(@"queue: next pressed on %@, %@ %@ [%@], skipping to it at once", current.trackTitle,
          replay ? @"it played before" : @"the user's order has", want.trackTitle, want.UID);
    return want;
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
        for (id<SGQueueReader> reader in sReaders.allObjects) [reader player:player queueDidChange:queue];
        // What the now playing screens show of the tracks to come follows the page's rows.
        SGRetellPlayerState();
        queueAhead();
        saveSession();
        scheduleHandOver();
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
    [sig appendFormat:@"|o%lu", (unsigned long)sOrderVersion];
    return sig;
}

// Puts the DJ's tracks to come in `queue`. YES when the readers are to be left as they are: the core has none to come
// just now, and the rows the page had stay.
// The queue the readers are given is a copy of the core's with the DJ's rows in it, in `forward`: the core's own queue
// object is not changed, the page may keep it and read it again later.
// A DJ track playing from the core's queue (a copy, sCopyOf), as the DJ's: its uid and provider, without the queue's
// marks (is_queued, queued_by), so the player and the queue page draw no queue badge and keep the DJ's header. Nil for
// any other track.
static SPTPlayerTrack *asDJTrack(SPTPlayerTrack *playing) {
    NSDictionary *original = playing.UID.length ? sCopyOf[playing.UID] : nil;
    if (!original || ![original[@"uri"] isEqualToString:SGURIString(playing.URI)]) return nil;
    NSMutableDictionary *metadata = [playing.metadata mutableCopy] ?: [NSMutableDictionary dictionary];
    [metadata removeObjectForKey:@"is_queued"];
    [metadata removeObjectForKey:@"queued_by"];
    NSString *provider = original[@"mprovider"];
    if (provider) metadata[@"provider"] = provider; else [metadata removeObjectForKey:@"provider"];
    @try {
        SPTPlayerTrack *asDJ = [playing copy];
        [asDJ setValue:metadata forKey:@"metadata"];
        [asDJ setValue:original[@"uid"] forKey:@"UID"];
        if (original[@"provider"]) [asDJ setValue:original[@"provider"] forKey:@"provider"];
        return asDJ;
    } @catch (NSException *exception) {
        SGLog(@"queue: the playing copy cannot be shown as the DJ's (%@)", exception.reason);
        return nil;
    }
}

// The queue the readers are given: `rows` to come when there are any, and its playing track as the DJ's when it is a
// copy (the page draws its now playing row from the queue, not from the player's state: the badge stayed there).
static id queueWith(id queue, NSArray<SPTPlayerTrack *> *rows) {
    SPTPlayerTrack *asDJ = asDJTrack([queue valueForKey:@"track"]);
    if (!rows && !asDJ) return queue;
    id copy = [queue copy];
    if (!copy) { SGLog(@"queue: the queue cannot be copied, the page gets the core's"); return queue; }
    if (rows) [copy setValue:rows forKey:@"nextTracks"];
    if (asDJ) [copy setValue:asDJ forKey:@"track"];
    return copy;
}

static BOOL lineUpTheFutureFor(id reader, id player, id queue, id *forward);

// Out of the DJ's session: nothing of it is left for the page, its cells or the player to act on.
static void leaveDJ(void) {
    if (!sDJActive) return;
    if (sAheadQueued) dropQueued(SGURIString(sAheadQueued.URI), @"the DJ's session ended");
    sAheadQueued = nil;
    sDJActive = NO;
    sInjected = @[];
    sQueue = @[];
    sAhead = @[];
    sAheadContext = nil;
    sCachedMerged = nil;
    sSignature = nil;
    sForwardFor = nil;
    sForward = nil;
    sGapSince = nil;
    sCardAvatar = nil;
    sCardAvatarURL = nil;
    sCardTitle = nil;
    for (UIView *view in sAvatarViews.allObjects) [view removeFromSuperview];
    [sAvatarViews removeAllObjects];
    forgetOrder();
    SGLog(@"queue: out of the DJ's session, the queue is Spotify's");
}

static BOOL lineUpTheFuture(id reader, id player, id queue, id *forward) {
    *forward = queue;
    if (!isDJSession(SGPlayerState())) {
        if (sAheadQueued && queue) sLastQueue = queue;
        leaveDJ();
        return NO;
    }
    sDJActive = YES;
    restoreSession(SGPlayerState());
    if (queue && queue == sForwardFor && sForward && [signatureOf(SGPlayerState(), [queue valueForKey:@"nextTracks"]) isEqualToString:sSignature]) {
        if (!sReaders) sReaders = [NSHashTable weakObjectsHashTable];
        [sReaders addObject:reader];
        *forward = sForward;
        return NO;
    }
    BOOL keep = lineUpTheFutureFor(reader, player, queue, forward);
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
    NSArray<SPTPlayerTrack *> *future = djFuture(state.future);

    // The state's own, then what was kept after its last one. When hand-queued tracks fill the state's two it names
    // none of the DJ's, and what was kept stands. A list that does not go on from the kept one is the DJ's new.
    NSMutableArray<SPTPlayerTrack *> *ahead = [future mutableCopy];
    if (![state.contextURI isEqual:sAheadContext]) {
        [sHidden removeAllObjects];
        [sSkipped removeAllObjects];
        [sCarded removeAllObjects];
        [sLoggedCards removeAllObjects];
        [sCardTracks removeAllObjects];
        [sVoiced removeAllObjects];
        [sPlayedBefore removeAllObjects];
        forgetOrder();
    }
    if ([state.contextURI isEqual:sAheadContext]) {
        if (!future.count) {
            [ahead addObjectsFromArray:sAhead];
        } else {
            NSUInteger at = indexIn(sAhead, future.lastObject);
            if (at != NSNotFound) [ahead addObjectsFromArray:[sAhead subarrayWithRange:NSMakeRange(at + 1, sAhead.count - at - 1)]];
        }
    }
    // Up to the track playing; a copy of a DJ track playing from the core's queue is not the core's place among them
    // (cut there, the tracks the core has before its original went: a card moved down was gone after a launch).
    for (NSUInteger i = 0; i < ahead.count && !isCoreQueued(state.track); i++) {
        if ([ahead[i].URI isEqual:state.track.URI]) {
            [ahead removeObjectsInRange:NSMakeRange(0, i + 1)];
            break;
        }
    }
    sAheadContext = state.contextURI;
    sAhead = ahead;
    // What the page shows of them: not the ones it removed, nor the ones queued by hand.
    NSMutableArray<SPTPlayerTrack *> *shown = [NSMutableArray array];
    // A track of the DJ's that played before the launch is not a row again: the core restores its place before it (the
    // track was played from its queue), and the next the mod puts in skips it, so it showed as a row that never played.
    NSString *playingUID = baseUID(state.track.UID);
    for (SPTPlayerTrack *track in ahead) {
        if (isHidden(track)) continue;
        NSString *uid = baseUID(track.UID);
        if (uid.length && ![uid isEqualToString:playingUID] && [sPlayedBefore containsObject:uid] && isDJTrack(track) &&
            ![SGURIString(track.URI) hasPrefix:@"spotify:media:"]) continue;
        [shown addObject:track];
    }
    for (NSDictionary *entry in sMoved.allValues) if (!isHidden(entry[@"row"])) [shown addObject:entry[@"row"]];
    if (sOrdered) shown = arrangedRows(shown, state);
    // The hand-queued tracks, the DJ's, then whatever else the queue had.
    NSMutableArray<SPTPlayerTrack *> *queued = [NSMutableArray array], *rest = [NSMutableArray array], *injected = [NSMutableArray array];
    // The core's queue names the session again after the delimiter (stand-ins, some with another provider than the
    // ones the state named) and, after a track is queued by hand, the DJ's tracks once more: a track of the DJ's that
    // `ahead` already holds, by uri, or one already taken, is not a row of its own.
    NSMutableSet<NSString *> *aheadURIs = [NSMutableSet set], *restKeys = [NSMutableSet set];
    for (SPTPlayerTrack *track in ahead) [aheadURIs addObject:SGURIString(track.URI)];
    // A track queued by hand is the core's (isCoreQueued: its provider is "queue", or its uid starts with q when it is a
    // DJ track queued again), whichever provider the core gives it.
    NSString *playing = trackKey(state.track);
    // The user's next, put in the core's queue ahead of its turn, shows as the DJ's row it is, not as one queued by hand.
    SPTPlayerTrack *aheadCopy = sAheadQueued ? queuedCopyOf(sAheadQueued, state, NULL) : nil;
    for (SPTPlayerTrack *track in next) {
        if (aheadCopy && [trackKey(track) isEqualToString:trackKey(aheadCopy)]) continue;
        if ([trackKey(track) isEqualToString:playing]) continue;     // a queue from before the player came to it
        if (isCoreQueued(track) && movedBySource(track)) continue;   // taken into the DJ's rows, the core is being told
        if (isCoreQueued(track)) {
            // Copies we made to enforce the DJ's order are implementation details, not hand-queued rows. The core
            // can keep one in its future after it plays or after the user's order changes; sAheadQueued then no longer
            // identifies it, but sCopyOf still does. A copy queued by the user has no sCopyOf entry and stays visible.
            if (track.UID.length && sCopyOf[track.UID]) continue;
            [queued addObject:track];
            continue;
        }
        // Spotify repeats the DJ's tracks later in the same queue. A hidden original can reappear there after its
        // internal queued copy was played; don't put that original back beside the copy in the visible queue.
        if (isHidden(track)) continue;
        if (indexIn(ahead, track) != NSNotFound) continue;
        NSString *uri = SGURIString(track.URI);
        if ([uri isEqualToString:@"spotify:delimiter"]) continue;
        if (isDJTrack(track) && [aheadURIs containsObject:uri]) continue;
        NSString *key = [NSString stringWithFormat:@"%@|%@", uri, track.UID ?: @""];
        if (track.UID.length && [restKeys containsObject:key]) continue;
        [restKeys addObject:key];
        [rest addObject:track];
    }
    // A row is the DJ's unless the core's queue has that very track (uri and uid): a copy the core queued of it has the
    // context's provider too, and taken for it, the row was not the DJ's (gone from the order at the next drag).
    NSMutableSet<NSString *> *nextKeys = [NSMutableSet set];
    for (SPTPlayerTrack *track in next) [nextKeys addObject:trackKey(track)];
    for (SPTPlayerTrack *track in shown) if (![nextKeys containsObject:trackKey(track)]) [injected addObject:track];
    NSMutableArray<SPTPlayerTrack *> *merged = [NSMutableArray array];
    // One row per track (uri, uid, provider): the same track twice in a row of lists is a repeat, not a second row.
    NSMutableSet<NSString *> *taken = [NSMutableSet set];
    for (NSArray<SPTPlayerTrack *> *group in @[queued, shown, rest]) {
        for (SPTPlayerTrack *track in group) {
            if (track.UID.length) {
                NSString *key = [NSString stringWithFormat:@"%@|%@|%@", SGURIString(track.URI), track.UID, track.provider];
                if ([taken containsObject:key]) continue;
                [taken addObject:key];
            }
            [merged addObject:track];
        }
    }
    [injected filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SPTPlayerTrack *t, id _) { return [merged containsObject:t]; }]];

    if (merged.count) {
        sGapSince = nil;
    } else if (sQueue.count && inDJ(state.track)) {
        if (!sGapSince) {
            sGapSince = [NSDate date];
            // Told again once the wait is over: with no change of the core's after it, the page kept the rows (and the
            // track playing) it had before, a copy put in ahead among them, until it was opened again.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kGapSeconds + 0.1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (sGapSince) { sSignature = nil; refreshReaders(); }
            });
        }
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
    // The first rows of a launch: a copy put in ahead before it is taken up, the queue the readers were told is known now.
    static BOOL firstRows;
    if (!firstRows && injected.count) {
        firstRows = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ queueAhead(); });
    }
    *forward = queueWith(queue, ahead.count ? merged : nil);
    return NO;
}

// A key of an esperanto track, nil when its class has none: the tracks of a setQueue are ESPProvidedTrack, which has no
// uri key (valueForKey: threw NSUnknownKeyException and the app crashed when a queued track was removed).
static id espValue(id track, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        if ([track respondsToSelector:NSSelectorFromString(key)]) return [track valueForKey:key];
    }
    return nil;
}
static NSString *espURI(id track) { return espValue(track, @[@"uri", @"URI", @"trackUri", @"trackURI"]); }
static NSString *espUID(id track) { return espValue(track, @[@"uid", @"UID"]); }

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
    if (!sDJActive || !queueSource || ![(id)self.dataSource isKindOfClass:queueSource]) {
        %orig;
        return;
    }
    if (sReloadQueued) return;
    sReloadQueued = YES;
    __weak UITableView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        sReloadQueued = NO;
        [weakSelf reloadData];
    });
}
%end

// The drag handle of a row is UIKit's UITableViewCellReorderControl, a view of the cell itself, right of the content.
// On rows the page made late it stays at {0, 0}, over the cover, and on a row the page reloads mid-change UIKit can
// leave it stretched at the far right ({355, 0, 27, 64} beside {342, 10, 44, 44}). Every handle is given the frame of
// one UIKit laid out the usual way, a square right of the content; until one is known, a late handle goes to the right
// edge of the content.
static CGRect sHandleFrame = {{-1, 0}, {0, 0}};
static __weak UIView *sUIKitHandle;
static __weak UIView *sQueuePageView;
static void alignHeaderPlay(UIView *page);
static void placeReorderHandle(UITableViewCell *cell) {
    UIView *control = nil;
    for (UIView *view in cell.subviews) {
        if ([NSStringFromClass(view.class) isEqualToString:@"UITableViewCellReorderControl"]) { control = view; break; }
    }
    if (!control || control.hidden || cell.bounds.size.width < 100 || control.frame.size.width <= 0) return;
    CGFloat width = cell.bounds.size.width, height = cell.bounds.size.height;
    CGRect frame = control.frame;
    BOOL usual = frame.origin.x >= width / 2 && fabs(frame.size.width - frame.size.height) < 1 && frame.size.height < height;
    if (usual && control != sUIKitHandle && (sHandleFrame.origin.x < 0 || fabs(frame.origin.x - sHandleFrame.origin.x) > 0.5)) {
        BOOL first = sHandleFrame.origin.x < 0;
        sHandleFrame = frame;
        sUIKitHandle = control;
        // The handles are made anew each time the queue opens, after the page's own layout pass: the ▶ goes to their
        // column in the same pass, before the page is on screen.
        if (first || sQueuePageView) alignHeaderPlay(sQueuePageView);
    } else if (usual && !sUIKitHandle) {
        sUIKitHandle = control;
    }
    CGRect want;
    if (sHandleFrame.origin.x >= 0) {
        want = CGRectMake(sHandleFrame.origin.x, (height - sHandleFrame.size.height) / 2, sHandleFrame.size.width, sHandleFrame.size.height);
    } else if (frame.origin.x < width / 2) {
        CGFloat content = cell.contentView.frame.size.width;
        CGFloat x = (content > 0 && content < width) ? CGRectGetMaxX(cell.contentView.frame) - 3 : width - 60;
        want = CGRectMake(x, (height - frame.size.height) / 2, frame.size.width, frame.size.height);
    } else {
        return;
    }
    if (CGRectEqualToRect(CGRectIntegral(want), CGRectIntegral(frame))) return;
    control.frame = want;
}

// The "Now playing" row has no handle, so Spotify lays it out the table's full width and its ▶ sits against the
// sheet's edge, right of the handles' column. It is moved to that column's middle with a transform, which Auto
// Layout leaves alone.
static void alignHeaderPlay(UIView *page) {
    UIView *handle = sUIKitHandle;
    if (!page || !handle.window) return;
    UIView *row = descendant(page, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"TrackRowQueue.Header"]; });
    UIView *play = row ? descendant(row.superview ?: row, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"header-play-button"]; }) : nil;
    if (!play.superview || play.window != handle.window) return;
    CGFloat want = [handle.superview convertPoint:handle.center toView:play.superview].x;
    CGFloat dx = want - play.center.x;
    if (fabs(dx) > 60) return;
    if (fabs(play.transform.tx - dx) > 0.5) {
        [UIView performWithoutAnimation:^{ play.transform = CGAffineTransformMakeTranslation(dx, 0); }];
    }
    // Spotify lays the title out up to where the button was, so moved left the button sat over the text and the text
    // showed past it: the row's text fades out before the button.
    UIView *content = descendant(row, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"Track.Row.Content"]; });
    if (!content || content.bounds.size.width <= 0) return;
    CGFloat cut = [play.superview convertRect:play.frame toView:content].origin.x - 8;
    CGFloat width = content.bounds.size.width, fade = 16;
    CAGradientLayer *mask = [content.layer.mask isKindOfClass:CAGradientLayer.class] && [content.layer.mask.name isEqualToString:@"SGQueuePlayFade"] ?
        (CAGradientLayer *)content.layer.mask : nil;
    if (cut >= width) {
        if (mask) content.layer.mask = nil;
        return;
    }
    if (!mask) {
        if (content.layer.mask) return;   // a mask of Spotify's own is left alone
        mask = [CAGradientLayer layer];
        mask.name = @"SGQueuePlayFade";
        mask.startPoint = CGPointMake(0, 0.5);
        mask.endPoint = CGPointMake(1, 0.5);
        mask.colors = @[(id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor, (id)UIColor.clearColor.CGColor];
        content.layer.mask = mask;
    }
    CGFloat end = MAX(0, cut) / width, start = MAX(0, cut - fade) / width;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = content.bounds;
    mask.locations = @[@0, @(start), @(end), @1];
    [CATransaction commit];
}

// Spotify lays the button out again on its own (a play state change rebuilds it): it is put back in the column in
// that pass, not at the page's next tick.
// The "Now playing" row is the new track's as soon as the player is on it: its avatar and ▶ are put in then and as
// the row settles, not at the page's next tick.
static void drawHeaderSoon(void) {
    for (NSNumber *delay in @[@0.05, @0.3, @0.8]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *page = sQueuePageView;
            if (!page.window || !sDJActive) return;
            drawHeaderAvatar(page);
            alignHeaderPlay(page);
        });
    }
}

%hook _TtC28EncoreConsumerMobile_BaseKit14PlayButtonView
- (void)layoutSubviews {
    %orig;
    UIView *button = (UIView *)self;
    if (!sDJActive || !sQueuePageView || button.window != sQueuePageView.window) return;
    if (![button.accessibilityIdentifier isEqualToString:@"header-play-button"]) return;
    alignHeaderPlay(sQueuePageView);
}
%end

%hook _TtC14Queue_ViewImpl9QueueCell
- (void)layoutSubviews {
    %orig;
    if (!sDJActive) return;
    placeReorderHandle((UITableViewCell *)(id)self);
    // The hooked class is declared here without its superclass, so it is taken as the table cell it is.
    UITableViewCell *cellSelf = (UITableViewCell *)(id)self;
    if (!sQueueCells) sQueueCells = [NSHashTable weakObjectsHashTable];
    [sQueueCells addObject:cellSelf];
    drawCardAvatar(cellSelf);
    // The row's own image view, and the handle, may be set again a moment after the layout.
    __weak UITableViewCell *weakSelf = cellSelf;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UITableViewCell *cell = weakSelf;
        if (cell) { drawCardAvatar(cell); placeReorderHandle(cell); }
    });
}
- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    %orig;
    drawCardAvatarSoon((UITableViewCell *)(id)self);
}
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    drawCardAvatarSoon((UITableViewCell *)(id)self);
}
%end

// The DJ's rows ticked in Edit (their trackKey): Edit's Remove sends the core its queue with none of the DJ's rows in it
// (it builds it from the core's own), so which of them were removed is told only by what was ticked. Spotify keeps the
// ticks itself (the table has one row selected at a time), so they are followed here, tap by tap.
static NSMutableOrderedSet<NSString *> *sPicked;

// What Edit's Remove last took out, and when: the toast's Undo puts the rows back in the page and ticks them again, and
// sends the core nothing.
static NSArray<SPTPlayerTrack *> *sEditRemoved;
static NSDate *sEditRemovedAt;

// Whether the queue page is in its Edit: the table is always editing (that is how it shows the reorder handles), so
// it is told by Edit's close button, which shows only then.
static BOOL queueInEdit(UIView *page) {
    return page && descendant(page, ^BOOL(UIView *view) {
        return [view.accessibilityIdentifier isEqualToString:@"queue-close-edit-button"] && !view.hidden && view.alpha > 0.01;
    }) != nil;
}

%hook UIControl
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    %orig;
    if (!sDJActive || !sEditTable) return;
    NSString *name = self.accessibilityIdentifier;
    if ([name isEqualToString:@"queue-edit-toolbar-clear-selection"]) [sPicked removeAllObjects];
    // Edit's Move up: the DJ's rows ticked go first among the DJ's (after the "Up next" card on top and its track, which
    // nothing goes above), as a drag puts them.
    if ([name isEqualToString:@"queue-edit-toolbar-move-up"] && sPicked.count) {
        NSArray<SPTPlayerTrack *> *list = [sQueue copy];
        NSInteger pairEnd = topPairEnd(list);
        NSString *top = pairEnd >= 0 ? baseUID(list[pairEnd].UID) : nil;
        NSMutableArray<NSString *> *picked = [NSMutableArray array], *rest = [NSMutableArray array];
        for (SPTPlayerTrack *row in list) {
            if (indexIn(sInjected, row) == NSNotFound) continue;
            NSString *uid = baseUID(row.UID);
            if ([picked containsObject:uid] || [rest containsObject:uid] || [uid isEqualToString:top]) continue;
            [([sPicked containsObject:trackKey(row)] ? picked : rest) addObject:uid];
        }
        NSMutableArray<NSString *> *order = [NSMutableArray array];
        if (top) [order addObject:top];
        [order addObjectsFromArray:picked];
        [order addObjectsFromArray:rest];
        if (picked.count) {
            sOrder = order;
            sOrdered = YES;
            sOrderVersion++;
            SGLog(@"queue: Move up puts %lu of the DJ's rows first, now %lu groups", (unsigned long)picked.count, (unsigned long)order.count);
            [sPicked removeAllObjects];   // the page unticks them
            sSignature = nil;
            refreshReaders();
        }
    }
    // Edit's Remove: the DJ's rows ticked go (the core is sent the rest of its own queue, or nothing when it has none).
    if ([name isEqualToString:@"queue-edit-toolbar-remove"] && sPicked.count) {
        NSMutableArray<SPTPlayerTrack *> *removed = [NSMutableArray array];
        for (SPTPlayerTrack *row in [sInjected copy]) {
            if (![sPicked containsObject:trackKey(row)] || isHidden(row)) continue;
            hideTrack(row, @"removed in Edit");
            [removed addObject:row];
        }
        sEditRemoved = removed;
        sEditRemovedAt = [NSDate date];
        [sPicked removeAllObjects];
        sSignature = nil;
        refreshReaders();
    }
    if ([name isEqualToString:@"SPTSnackbarTextButton"] && sEditRemoved.count && sEditRemovedAt && -sEditRemovedAt.timeIntervalSinceNow < 10) {
        if (!sPicked) sPicked = [NSMutableOrderedSet orderedSet];
        for (SPTPlayerTrack *row in sEditRemoved) {
            [sHidden removeObject:baseUID(row.UID)];
            [sPicked addObject:trackKey(row)];
        }
        SGLog(@"queue: Undo puts back %lu of the DJ's rows removed in Edit", (unsigned long)sEditRemoved.count);
        sEditRemoved = nil;
        sSignature = nil;
        refreshReaders();
    }
}
%end

%hook ESPContextPlayerClientImpl
// The state request the player's subscription makes of the core carries caps on the tracks before and after the current
// one. The future's cap is raised before the request goes.
- (void)getState:(id)request onResponse:(id)onResponse {
    Class requestClass = NSClassFromString(@"ESPGetStateRequest"), optional = NSClassFromString(@"ESPOptionalInt64");
    if (requestClass && optional && [request isKindOfClass:requestClass]) {
        // A message field the request does not have reads as an empty one (value 0): no cap, which is left alone.
        BOOL has = ![request respondsToSelector:NSSelectorFromString(@"hasNextTracksCap")] || [[request valueForKey:@"hasNextTracksCap"] boolValue];
        long long was = has ? [[[request valueForKey:@"nextTracksCap"] valueForKey:@"value"] longLongValue] : 0;
        if (has && was < kFutureCap) {
            id cap = [[optional alloc] init];
            [cap setValue:@(kFutureCap) forKey:@"value"];
            [request setValue:cap forKey:@"nextTracksCap"];
            SGLog(@"queue: next tracks cap %lld raised to %lld", was, (long long)kFutureCap);
        }
        // The tracks behind too: with two, a step back from a new segment found only the removed or played ones the
        // hand-over went past, and nothing to go back to.
        BOOL hasPrev = ![request respondsToSelector:NSSelectorFromString(@"hasPrevTracksCap")] || [[request valueForKey:@"hasPrevTracksCap"] boolValue];
        long long prev = hasPrev ? [[[request valueForKey:@"prevTracksCap"] valueForKey:@"value"] longLongValue] : 0;
        if (hasPrev && prev < kFutureCap) {
            id cap = [[optional alloc] init];
            [cap setValue:@(kFutureCap) forKey:@"value"];
            [request setValue:cap forKey:@"prevTracksCap"];
            static BOOL logged;
            if (!logged) { logged = YES; SGLog(@"queue: previous tracks cap %lld raised to %lld", prev, (long long)kFutureCap); }
        }
    }
    %orig;
}
// A DJ row that is queued by hand stays where it is: the queued track is one more, a hand-queued one that plays next,
// and the DJ's own row of it plays again at its place. The core's copy has its own uid (it starts with q).
- (void)setQueue:(id)request onResponse:(id)onResponse {
    if (sOwnQueueCommand) {
        %orig;
        return;
    }
    sNativeQueueAt = [NSDate date];
    if (!sDJActive || !sInjected.count) {
        %orig;
        return;
    }
    NSMutableArray *tracks = [request valueForKey:@"nextTracksArray"];
    NSMutableArray *djs = [NSMutableArray array];
    NSMutableSet<NSString *> *sent = [NSMutableSet set];
    for (id track in tracks) {
        if (!injectedNamed(espURI(track), espUID(track))) continue;
        [djs addObject:track];
        // A row named by its uri alone (an esperanto track with no uid key) is the DJ's, but no uid says which one is sent.
        NSString *uid = espUID(track);
        if (uid.length) [sent addObject:uid];
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
        SPTPlayerTrack *dj = injectedNamed(espURI(track), nil);
        if (dj) { hideTrack(dj, @"played next by hand"); hid = YES; }
    }
    if (hid) refreshReaders();
    %orig;
}
%end

// When the page last gave the core a queue command of its own, and the page's queue wrapper: a swipe on a DJ row that
// the page did not act on is done here (the page's swipe does nothing for those rows).

static void swipeDJRow(SPTPlayerTrack *row, CGFloat x) {
    NSDate *at = [NSDate date];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (sNativeQueueAt && [sNativeQueueAt timeIntervalSinceDate:at] >= 0) {
            SGLog(@"queue page: the page acted on the swipe of %@ itself", row.trackTitle);
            return;
        }
        if (x > 0) {
            SPTPlayerTrack *own = originalOf(row);
            id wrapper = sWrapper;
            if (!wrapper) wrapper = queueWrapper();
            SGLog(@"queue page: swipe adds %@ [%@] to the queue, the DJ's row stays (wrapper %@)", row.trackTitle, own.UID, [wrapper class]);
            id result = [wrapper respondsToSelector:NSSelectorFromString(@"queueTrack:")] ? ((id (*)(id, SEL, id))objc_msgSend)(wrapper, NSSelectorFromString(@"queueTrack:"), own) : nil;
            SGLog(@"queue page: the swipe's queue answered %@", result);
        } else {
            hideTrack(row, @"removed by a swipe");
            refreshReaders();
        }
    });
}

// The page's own queue commands before they reach the client: what its swipe actions and its drag call.
%hook SPTPlayerQueueWrapperImpl
- (id)queueTrackInternal:(SPTPlayerTrack *)track options:(id)options loggingParams:(id)params {
    sWrapper = self;
    sNativeQueueAt = [NSDate date];
    if (track && indexIn(sInjected, track) != NSNotFound && !isCardRow(track)) {
        // A DJ row: its copy is not the core's track. The core queues the player's own, as one more track among the
        // hand-queued ones before the DJ's. The DJ's row of it is hidden by the addToQueue that follows.
        SPTPlayerTrack *own = originalOf(track);
        SGLog(@"queue page: queue track %@ given to the core as its own %@ [%@], the DJ's row stays", track.trackTitle, SGURIString(own.URI), own.UID);
        return %orig(own, options, params);
    }
    return %orig;
}
- (id)queueTracksInternal:(NSArray<SPTPlayerTrack *> *)tracks options:(id)options loggingParams:(id)params {
    sNativeQueueAt = [NSDate date];
    return %orig;
}
- (id)queueTrackPlayNext:(SPTPlayerTrack *)track {
    sNativeQueueAt = [NSDate date];
    return %orig;
}
%end

%hook _TtC14Queue_ViewImpl38QueueTableViewDataSourceImplementation
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    if (!sDJActive || !sInjected.count) {
        %orig;
        return;
    }
    NSArray<SPTPlayerTrack *> *list = [sQueue copy];
    %orig;
    BOOL arranged = arrangeByDrag(list, placeOf(tableView, from), placeOf(tableView, to));
    if (!arranged) SGLog(@"queue page: the drag moved no DJ row, the page's rows are given again");
    // Once the drop is over, the page is given the list again: ours, or the one it had if the drag was not ours.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ refreshReaders(); });
}
%end

%hook SPTEsperantoPlayer
- (id)skipToNextTrackWithOptions:(id)options track:(SPTPlayerTrack *)track loggingParams:(id)params {
    if (!track && sDJActive && !sAdvancing && !sHandingOver && segmentSpent(SGPlayerState())) {
        id landed = landAtSegmentEnd(nil);
        if (landed) return landed;
    }
    if (!track && sDJActive && !sAdvancing) {
        SPTPlayerTrack *want = redirectedNext();
        if (want) return advanceTo(want, YES) ?: %orig;
    }
    return %orig;
}
%end

// Set once the core did not move to a track it was asked to skip back to; no more asks in that session.
static BOOL sJumpRefused;

// After the DJ's voice the cover list of the full player is to show the track's cover where the voice's blue cell was:
// both are the same uid, so Spotify sometimes keeps the voice's cell (the DJ's logo over the track) until a swipe makes
// the cell reused. A voice cell that is still showing while the player is on a track is reloaded out of the list.
static void freeStuckVoiceCell(void) {
    NSString *uri = SGURIString(SGPlayerState().track.URI);
    if (![uri hasPrefix:@"spotify:track:"] && ![uri hasPrefix:@"spotify:episode:"]) return;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    for (UIWindow *window in windows) {
        UIView *list = descendant(window, ^BOOL(UIView *view) { return [NSStringFromClass(view.class) hasSuffix:@"AccessibleCollectionView"]; });
        UIView *voice = list ? descendant(list, ^BOOL(UIView *view) {
            return [NSStringFromClass(view.class) hasSuffix:@"DJMContentLayerCell"] && !view.hidden && view.alpha > 0.01;
        }) : nil;
        if (!voice || ![list isKindOfClass:UICollectionView.class]) continue;
        SGLog(@"queue: the DJ's voice cell still shows on %@, the cover list is reloaded", uri);
        UICollectionView *collection = (UICollectionView *)list;
        [collection reloadData];
        [collection layoutIfNeeded];
    }
}

// While the DJ's voice plays, its cell in the cover list draws the DJ's circle (a VisualizationView). After a card was
// moved, the cell sometimes came up as the current one without it, only the blue background (9.1.90): the list is
// reloaded, which makes the cell again as the current one, with the circle.
static void drawVoiceCircle(void) {
    if (![SGURIString(SGPlayerState().track.URI) hasPrefix:@"spotify:media:"]) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIView *list = descendant(window, ^BOOL(UIView *view) { return [NSStringFromClass(view.class) hasSuffix:@"AccessibleCollectionView"]; });
            if (![list isKindOfClass:UICollectionView.class]) continue;
            UICollectionView *collection = (UICollectionView *)list;
            CGFloat x = collection.contentOffset.x;
            UIView *cell = nil;
            for (UIView *view in collection.subviews) {
                if ([NSStringFromClass(view.class) hasSuffix:@"DJMContentLayerCell"] && !view.hidden && fabs(view.frame.origin.x - x) < 1) { cell = view; break; }
            }
            if (!cell) continue;
            UIView *circle = descendant(cell, ^BOOL(UIView *view) { return [NSStringFromClass(view.class) hasSuffix:@"VisualizationView"] && !view.hidden && view.alpha > 0.01; });
            if (circle) continue;
            SGLog(@"queue: the DJ's voice cell has no circle, the cover list is reloaded");
            [collection reloadData];
            [collection layoutIfNeeded];
        }
    }
}

static NSString *sVoiceCheckedFor;
static void freeStuckVoiceCellSoon(SPTPlayerTrack *track) {
    NSString *key = trackKey(track);
    if ([key isEqualToString:sVoiceCheckedFor] || ![SGURIString(track.URI) hasPrefix:@"spotify:track:"]) return;
    sVoiceCheckedFor = key;
    for (NSNumber *delay in @[@0.6, @1.5, @3]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ freeStuckVoiceCell(); });
    }
}

// The last item of the DJ's segment in the core's future (before the delimiter), not one queued by hand.
static SPTPlayerTrack *lastOfSegment(SPTPlayerState *state) {
    SPTPlayerTrack *last = nil;
    for (SPTPlayerTrack *t in state.future) {
        if (isCoreQueued(t)) continue;
        if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
        if (isDJTrack(t) || [SGURIString(t.URI) hasPrefix:@"spotify:media:"]) last = t;
    }
    return last;
}

// On the segment's last track, hidden: once the next segment's first item is in the future (the core asks for it as it
// comes to the last track, a second on the simulator), the player goes on to it; after kSegmentWait, on anyway.
static const NSTimeInterval kSegmentWait = 6;
static void awaitNextSegment(NSString *onKey) {
    __block int tries = 0;
    __block void (^poll)(void);
    void (^check)(void) = ^{
        SPTPlayerState *now = SGPlayerState();
        if (![trackKey(now.track) isEqualToString:onKey]) { poll = nil; return; }
        SPTPlayerTrack *to = coreNextUnplayed(now);
        if (!to && ++tries < (int)(kSegmentWait / 0.25)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), poll);
            return;
        }
        poll = nil;
        SGLog(@"queue: %@", to ? [NSString stringWithFormat:@"the next segment came, on to %@", SGURIString(to.URI)] : @"no next segment came, the player goes on");
        skipForward(to);
    };
    poll = check;
    dispatch_async(dispatch_get_main_queue(), poll);
}

// The hand-over to the next segment when nothing of this one is left to play but tracks that played or were removed: the
// core makes the next segment only once it is on this one's last track, and on the way it would play each of those for a
// moment. Just before the track playing ends, the player is paused, sent to the segment's last track, and, once the next
// segment has come, on to its first item and resumed: nothing that played or was removed sounds.
static NSTimer *sHandOverTimer;
static const NSTimeInterval kHandOverLead = 0.7;

// An item of the segment still to play: a DJ track that has not played and was not removed, or a voice not heard.
static BOOL isUnspent(SPTPlayerTrack *t) {
    NSString *uid = baseUID(t.UID);
    BOOL voice = [SGURIString(t.URI) hasPrefix:@"spotify:media:"];
    if (!uid.length || (!voice && !isDJTrack(t)) || wasPlayed(uid) || [sHidden containsObject:uid]) return NO;
    return !(voice && [sVoiced containsObject:uid]);
}

// Nothing of the segment left: no track queued by hand, nothing of the user's order, nothing of the core's that has not
// played and was not removed, and something the core would still come to (else it is on the last track already).
static BOOL segmentSpent(SPTPlayerState *state) {
    BOOL onVoice = [SGURIString(state.track.URI) hasPrefix:@"spotify:media:"];
    // A card's voice has its track still to come; the DJ's words after a track end it, and are let play.
    if (!sDJActive || !isDJSession(state) || (onVoice && sCardTracks[state.track.UID])) return NO;
    for (SPTPlayerTrack *t in state.future) if (isCoreQueued(t)) return NO;
    if (sOrdered && wantedNext()) return NO;
    // The DJ's words after the track playing have its uid: they are its own, not something of the segment left.
    for (SPTPlayerTrack *t in state.future) {
        if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
        if (sameGroup(t, state.track)) {
            if (!onVoice && [SGURIString(t.URI) hasPrefix:@"spotify:media:"]) return NO;   // the DJ's words after it are to come
            continue;
        }
        if (isUnspent(t)) return NO;
    }
    SPTPlayerTrack *last = lastOfSegment(state);
    return last && !sameGroup(last, state.track);
}

// `target` is all the segment has left to play, its card (if any) has been heard, and the core has items after it that
// played or were removed: a tap on the segment's last row after a launch left the core before a track the tap passed,
// and no next segment came.
static BOOL onlyThisLeft(SPTPlayerState *state, SPTPlayerTrack *target) {
    if (!sDJActive || !isDJSession(state) || !target) return NO;
    BOOL seen = NO, after = NO;
    for (SPTPlayerTrack *t in state.future) {
        // The copy put in ahead for another track is taken out on the way (a tap with one in the core's queue went
        // straight to the last row, the core still had a passed track after it, and no next segment came).
        if (isCoreQueued(t) && sAheadQueued && [SGURIString(t.URI) isEqualToString:SGURIString(sAheadQueued.URI)] &&
            !sameGroup(sAheadQueued, target)) continue;
        if (isCoreQueued(t)) return NO;
        if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
        if (sameGroup(t, target)) {
            // Its card before it, not heard yet: played from the queue, it would be lost.
            if (!seen && [SGURIString(t.URI) hasPrefix:@"spotify:media:"] && isUnspent(t)) return NO;
            if (![SGURIString(t.URI) hasPrefix:@"spotify:media:"]) seen = YES;
            continue;
        }
        if (isUnspent(t)) return NO;
        if (seen) after = YES;
    }
    SPTPlayerTrack *last = lastOfSegment(state);
    return seen && after && last && !sameGroup(last, state.track);
}

// The core makes the next segment only once it is on this one's last track, and on the way it would play for a moment
// each track after the one playing that played or was removed. The player is paused, sent to the segment's last track,
// and once the next segment has come, on to its first item (or to `play`, put in the core's queue first) and resumed:
// nothing that played or was removed sounds. Nil when it could not be done.
static id landAtSegmentEnd(SPTPlayerTrack *play) {
    SPTPlayerState *state = SGPlayerState();
    SPTPlayerTrack *last = lastOfSegment(state);
    if (sHandingOver || !last || sameGroup(last, state.track)) return nil;
    sHandingOver = YES;
    if (play) {
        if (!queueInCore(play)) { sHandingOver = NO; return nil; }
        hideTrack(play, @"played through the queue");
        refreshReaders();
    }
    id<SPTPlayer> player = (id<SPTPlayer>)queuePlayer();
    SGLog(@"queue: nothing of the segment is left to play%@: paused, on to its last %@ for the next segment",
          play ? [NSString stringWithFormat:@" but %@", play.trackTitle] : @"", SGURIString(last.URI));
    [player pause:nil];
    id result = skipForward(last);
    NSString *from = trackKey(state.track), *uri = SGURIString(play.URI);
    __block int tries = 0;
    __block void (^poll)(void);
    void (^check)(void) = ^{
        SPTPlayerState *now = SGPlayerState();
        BOOL moved = ![trackKey(now.track) isEqualToString:from];
        SPTPlayerTrack *to = moved ? coreNextUnplayed(now) : nil;
        SPTPlayerTrack *copy = nil;
        if (play) for (SPTPlayerTrack *t in now.future) {
            if (!isCoreQueued(t)) break;
            if ([SGURIString(t.URI) isEqualToString:uri]) { copy = t; break; }
        }
        if ((!to || (play && !copy)) && ++tries < (int)(kSegmentWait / 0.2)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), poll);
            return;
        }
        poll = nil;
        if (copy) noteCopy(copy, play);
        SGLog(@"queue: %@", to ? [NSString stringWithFormat:@"the next segment came, on to %@ and resumed", play ? play.trackTitle : SGURIString(to.URI)]
                              : @"no next segment came, resumed");
        if (play) skipForward(copy);
        else if (to) skipForward(to);
        [player resume:nil];
        sHandingOver = NO;
    };
    poll = check;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), poll);
    return result ?: @YES;
}

// The player is on the segment's last item (its last track, or the DJ's words after it) and the core has nothing more to
// come yet. The next segment is made once the core is on this last track; when it has not come by the end of the track,
// the core went back over the tracks that had played, and one of them sounded for a moment before it was skipped away
// from. The player is paused just before the end instead, and goes on once the next segment has come.
static BOOL atSegmentEnd(SPTPlayerState *state) {
    SPTPlayerTrack *cur = state.track;
    if (!sDJActive || sHandingOver || sAdvancing || !isDJSession(state) || !cur.UID.length || isCoreQueued(cur) || !inDJ(cur)) return NO;
    BOOL onVoice = [SGURIString(cur.URI) hasPrefix:@"spotify:media:"];
    // A voice before its track (a card's) has the track still to come; the DJ's words after a track have played it.
    if (onVoice && !wasPlayed(baseUID(cur.UID))) return NO;
    for (SPTPlayerTrack *t in state.future) if (isCoreQueued(t)) return NO;
    if (sOrdered && wantedNext()) return NO;
    SPTPlayerTrack *last = lastOfSegment(state);
    if (!last || !sameGroup(last, cur)) return NO;
    if (!onVoice && [SGURIString(last.URI) hasPrefix:@"spotify:media:"]) return NO;   // the DJ's words after it are to come
    return coreNextUnplayed(state) == nil;
}

static void holdAtEnd(void) {
    SPTPlayerState *state = SGPlayerState();
    if (sHandingOver || !atSegmentEnd(state)) return;
    sHandingOver = YES;
    id<SPTPlayer> player = (id<SPTPlayer>)queuePlayer();
    NSString *from = trackKey(state.track);
    SGLog(@"queue: the player is at the end of the segment's last item %@ and the next segment has not come: paused until it does",
          state.track.trackTitle ?: SGURIString(state.track.URI));
    [player pause:nil];
    __block int tries = 0;
    __block void (^poll)(void);
    void (^check)(void) = ^{
        SPTPlayerState *now = SGPlayerState();
        BOOL moved = ![trackKey(now.track) isEqualToString:from];
        SPTPlayerTrack *to = moved ? nil : coreNextUnplayed(now);
        if (!moved && !to && ++tries < (int)(kSegmentWait / 0.2)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), poll);
            return;
        }
        poll = nil;
        if (!moved) {
            SGLog(@"queue: %@", to ? [NSString stringWithFormat:@"the next segment came, on to %@ and resumed", SGURIString(to.URI)]
                                  : @"no next segment came, the player goes on and resumes");
            skipForward(to);
        }
        [player resume:nil];
        sHandingOver = NO;
    };
    poll = check;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), poll);
}

// With no order of the user's: the core's next item is a track that was removed (or played through the queue) and a
// track to play comes after it. The core would play the removed one for a moment before it is skipped away from, and a
// copy of the next put in its queue ahead (which Spotify draws as queued by hand) is no answer: the player is skipped
// to the track that comes, in one skip, just before the end. nil when the core's next is to be left alone.
static SPTPlayerTrack *skipPastSpent(SPTPlayerState *state) {
    SPTPlayerTrack *cur = state.track;
    if (!sDJActive || sOrdered || sHandingOver || sAdvancing || sPlayingMoved || !isDJSession(state) || !cur.UID.length ||
        isCoreQueued(cur) || !inDJ(cur) || isHidden(cur)) return nil;
    BOOL onVoice = [SGURIString(cur.URI) hasPrefix:@"spotify:media:"];
    if (onVoice && !wasPlayed(baseUID(cur.UID))) return nil;   // a card's voice: its track is to come
    for (SPTPlayerTrack *t in state.future) if (isCoreQueued(t)) return nil;
    SPTPlayerTrack *coming = nil;
    for (SPTPlayerTrack *t in state.future) {
        if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
        if (sameGroup(t, cur)) {
            if (!onVoice && [SGURIString(t.URI) hasPrefix:@"spotify:media:"]) return nil;   // the DJ's words after it are to come
            continue;
        }
        coming = t;
        break;
    }
    if (!coming || !staysHidden(coming)) return nil;
    SPTPlayerTrack *next = coreNextUnplayed(state);
    return next && !sameGroup(next, coming) ? next : nil;
}

static BOOL needsHandOver(SPTPlayerState *state) {
    return segmentSpent(state) || atSegmentEnd(state) || skipPastSpent(state) != nil;
}

static void handOver(void) {
    if (sHandingOver) return;
    SPTPlayerState *state = SGPlayerState();
    if (segmentSpent(state)) { landAtSegmentEnd(nil); return; }
    if (atSegmentEnd(state)) { holdAtEnd(); return; }
    SPTPlayerTrack *to = skipPastSpent(state);
    if (to) {
        SGLog(@"queue: %@ is about to end and the core's next was removed or played: on to %@ [%@] in one skip", state.track.trackTitle,
              to.trackTitle ?: SGURIString(to.URI), to.UID);
        skipForward(to);
    }
}

// Looked at again whenever the player comes to a track, plays or pauses; while nothing of the segment is left, the time to
// the track's end is watched (a seek tells the state's observers nothing).
static void scheduleHandOver(void) {
    if (sHandOverTimer.isValid && needsHandOver(SGPlayerState())) return;
    [sHandOverTimer invalidate];
    sHandOverTimer = nil;
    if (sHandingOver || !needsHandOver(SGPlayerState())) return;
    sHandOverTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        SPTPlayerState *now = SGPlayerState();
        if (sHandingOver || !needsHandOver(now)) { [timer invalidate]; if (sHandOverTimer == timer) sHandOverTimer = nil; return; }
        if (now.isPaused || now.duration <= 0) return;
        double speed = now.playbackSpeed > 0 ? now.playbackSpeed : 1;
        if ((now.duration - now.position) / speed > kHandOverLead) return;
        [timer invalidate];
        if (sHandOverTimer == timer) sHandOverTimer = nil;
        handOver();
    }];
}

@interface SGDJHistory : NSObject <SGPlayerStateObserver>
@end

@implementation SGDJHistory
- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (isDJSession(state)) restoreSession(state);
    if (![state.contextURI isEqual:sPlayedContext]) {
        sPlayedContext = state.contextURI;
        sPlayed = [NSMutableArray array];
        sJumpRefused = NO;
    }
    if (!isDJSession(state)) return;
    SPTPlayerTrack *track = state.track;
    static NSString *lastKey, *lastUID;
    // The first state of a launch is the session going on where it was, not the player coming to the track.
    BOOL arrived = lastKey && ![trackKey(track) isEqualToString:lastKey];
    NSString *leftUID = arrived ? lastUID : nil;
    lastUID = track.UID;
    // A walk over the history: the next button's replay, or the track that played right after the one that was playing.
    SPTPlayerTrack *historyTrack = asDJTrack(track) ?: track;
    NSString *historyLeft = sCopyOf[leftUID][@"uid"] ?: leftUID;
    BOOL walking = arrived && walkArrival(historyTrack, historyLeft);
    // A step back from a DJ track played from the core's queue: it has not played for the user any more, its row comes
    // back first in their order (before, it was gone from the page, and a next went past it).
    NSDictionary *backFrom = leftUID ? sCopyOf[leftUID] : nil;
    if (backFrom && sBackAsked && -sBackAsked.timeIntervalSinceNow < 4) {
        NSString *uid = baseUID(backFrom[@"uid"]);
        [sHidden removeObject:uid];
        for (NSString *key in [sSkipped copy]) if ([key hasSuffix:uid]) [sSkipped removeObject:key];
        if (!sOrder) sOrder = [NSMutableArray array];
        [sOrder removeObject:uid];
        [sOrder insertObject:uid atIndex:0];
        sOrdered = YES;
        sOrderVersion++;
        SGLog(@"queue: back from %@, played from the core's queue: its row is the user's next again", backFrom[@"title"] ?: uid);
    }
    lastKey = trackKey(track);
    // After the rows and the queue put in ahead have settled for this state.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ scheduleHandOver(); });
    if (arrived) {
        SGLog(@"queue: the player is on %@ [%@] at %.1f s", SGURIString(track.URI), track.UID, state.position);
        // The core tells the page of a queued track it has come to only with its next queue: the rows are made again now.
        refreshReaders();
        drawHeaderSoon();
    }
    if (arrived && [SGURIString(track.URI) hasPrefix:@"spotify:media:"]) {
        for (NSNumber *delay in @[@0.8, @1.6]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ drawVoiceCircle(); });
        }
    }
    if ([SGURIString(track.URI) hasPrefix:@"spotify:media:"] && track.UID.length && sCardTracks[track.UID]) {
        if (!sVoiced) sVoiced = [NSMutableSet set];
        [sVoiced addObject:track.UID];
    }
    if (inDJ(track)) freeStuckVoiceCellSoon(track);
    NSDictionary *movedPlaying = track.UID.length && isCoreQueued(track) ? movedBySource(track) : nil;
    BOOL droppedLate = sDropped && sDroppedAt && -sDroppedAt.timeIntervalSinceNow < 5;
    SPTPlayerTrack *put = sAheadQueued ?: (droppedLate ? sDropped : nil);
    // A skip of ours to a DJ track that the core took to a copy of it in its queue (put in ahead before a launch).
    if (arrived && isCoreQueued(track) && track.UID.length && !sCopyOf[track.UID] && !put && sSkipTarget && sSkipAt &&
        -sSkipAt.timeIntervalSinceNow < 3 && [SGURIString(track.URI) isEqualToString:SGURIString(sSkipTarget.URI)]) {
        SGLog(@"queue: %@, skipped to, plays from the core's queue: shown as the DJ's", track.trackTitle);
        noteCopy(track, sSkipTarget);
        sSignature = nil;
        refreshReaders();
    }
    // A copy known from before a launch (sCopyOf is kept): its DJ track has played now, the core's own is passed.
    NSString *copied = isCoreQueued(track) ? sCopyOf[track.UID][@"uid"] : nil;
    if (arrived && copied.length && !put && ![sHidden containsObject:baseUID(copied)]) {
        if (!sHidden) sHidden = [NSMutableSet set];
        [sHidden addObject:baseUID(copied)];
        SGLog(@"queue: %@ plays from the core's queue, its DJ track [%@] is passed", track.trackTitle, copied);
        sSignature = nil;
        refreshReaders();
    }
    if (put && arrived && isCoreQueued(track) && [SGURIString(track.URI) isEqualToString:SGURIString(put.URI)]) {
        // By the player's own track: its row is no longer among the page's once the core's copy of it plays.
        SGLog(@"queue: %@, put in ahead, is playing from the core's queue", track.trackTitle);
        noteCopy(track, put);
        hideTrack(put, @"played through the queue");
        sAheadQueued = nil;
        sDropped = nil;
        refreshReaders();
    }
    if (movedPlaying) {
        SPTPlayerTrack *row = movedPlaying[@"row"];
        SGLog(@"queue: moved %@ is playing, its row is taken out of the DJ's order", track.trackTitle);
        hideTrack(row, @"moved track played");
        [sMoved removeObjectForKey:baseUID(row.UID)];
        sOrderVersion++;
        sPlayingMoved = NO;
        refreshReaders();
    }
    // A track tapped on the page that has the DJ's card ahead of it: the core plays the voice first (it has the track's
    // uid), and the voice is skipped, so the tap lands on the track.
    if (sSkipVoiceUID && track.UID.length) {
        BOOL stale = !sSkipVoiceAsked || -sSkipVoiceAsked.timeIntervalSinceNow > kSkipVoiceSeconds;
        if (!stale && [track.UID isEqualToString:sSkipVoiceUID] && [SGURIString(track.URI) hasPrefix:@"spotify:media:"]) {
            sSkipVoiceUID = nil;
            SGLog(@"queue: the DJ's voice before the tapped track %@ is skipped", track.UID);
            [(id<SPTPlayer>)queuePlayer() skipToNextTrackWithOptions:nil];
            return;
        }
        if (stale || ([track.UID isEqualToString:sSkipVoiceUID] && isDJTrack(track))) sSkipVoiceUID = nil;
    }
    // A DJ track the page removed (or queued by hand) that the player has come to: its voice, then the track itself,
    // are skipped, once each.
    // Come to by a step back that found nothing else behind: back to the track it came from, not on past it (the
    // tracks after a hidden one count as played once they were).
    // A paused landing used only to make the next segment is not a listened-to track.
    // Keep it out of the history and out of order enforcement.
    if (sHandingOver && state.isPaused) return;
    BOOL backAsked = sBackAsked && -sBackAsked.timeIntervalSinceNow < 4;
    // A track the user passed with a tap, come to by a step back or as a walk over the history, is played: it is one of
    // the way back, not a track the core came to that was removed or played through the queue.
    BOOL passedWalk = isHidden(track) && playedIndex(historyUID(track)) != NSNotFound && arrived && (backAsked || walking);
    if (isHidden(track) && !passedWalk && !sHandingOver && arrived && backAsked) {
        SPTPlayerTrack *to = nil;
        for (SPTPlayerTrack *t in state.future) {
            if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
            if (isCoreQueued(t) || isHidden(t)) continue;
            to = t;
            break;
        }
        if (to) {
            SGLog(@"queue: a step back came to the removed or played %@, back to %@", track.trackTitle, to.trackTitle ?: SGURIString(to.URI));
            skipForward(to);
            return;
        }
    }
    if (isHidden(track) && !passedWalk && !sHandingOver) {
        NSString *key = [SGURIString(track.URI) stringByAppendingString:track.UID];
        if (!sSkipped) sSkipped = [NSMutableSet set];
        if (![sSkipped containsObject:key]) {
            [sSkipped addObject:key];
            // Past it and any other the core would come to that played or was removed, in one skip.
            SPTPlayerTrack *to = coreNextUnplayed(state);
            if (!to) {
                // Nothing of the segment is left to play: the core makes the next segment only once it is on the
                // segment's last track, so it goes there in one skip (not through each removed or played track), and on
                // from there once the next segment has come.
                SPTPlayerTrack *last = lastOfSegment(state);
                if (last && !sameGroup(last, track)) {
                    SGLog(@"queue: the player is on a hidden track %@, nothing of the segment is left: on to its last, %@", track.trackTitle, SGURIString(last.URI));
                    skipForward(last);
                } else {
                    SGLog(@"queue: the player is on the segment's last track %@, hidden: on once the next segment comes", track.trackTitle);
                    awaitNextSegment(trackKey(track));
                }
                return;
            }
            SGLog(@"queue: the player is on a hidden track %@ %@, skipping it to %@", track.trackTitle, SGURIString(track.URI), SGURIString(to.URI));
            skipForward(to);
            return;
        }
    }
    // The core has come to a DJ track of its own order that the user's order does not have first.
    if (enforceOrder(state, arrived, walking)) return;
    // noteCopy above may only have learned this copy on its first arrival.
    track = asDJTrack(state.track) ?: state.track;
    if (!isDJTrack(track) || (!inDJ(track) && !sCopyOf[state.track.UID]) || !track.UID.length) return;
    NSUInteger at = NSNotFound;
    for (NSUInteger i = 0; i < sPlayed.count; i++) if ([sPlayed[i].UID isEqualToString:track.UID]) { at = i; break; }
    if (at == NSNotFound) {
        [sPlayed addObject:track];
        return;
    }
    BOOL steppedBack = sBackAsked && -sBackAsked.timeIntervalSinceNow < 4;
    if (!steppedBack && !walking && at + 1 != sPlayed.count) {
        // The core went on to a track that played (its own order has it after this one): it is the newest now, or "next"
        // on it would go back to the track that played after it, and the two would take turns.
        [sPlayed removeObjectAtIndex:at];
        [sPlayed addObject:track];
        SGLog(@"queue: %@ played again, as the newest of the played", track.trackTitle);
    }
}
@end

// What Spotify's now playing screens are shown of the state: its future in the user's order, without what the page
// removed or what has played, so the cover list's next cover is the track the player goes to and a skip to it moves the
// list forward, though the core may step back to it. The mod's own observers, and everything here, read the core's.
static SPTPlayerState *djLens(SPTPlayerState *state) {
    if (!sDJActive || (!sOrdered && !sHidden.count) || !NSThread.isMainThread || !isDJSession(state)) return state;
    NSArray<SPTPlayerTrack *> *raw = state.future;
    NSMutableArray<SPTPlayerTrack *> *future = [NSMutableArray array];
    NSMutableSet<NSString *> *placed = [NSMutableSet set];
    for (SPTPlayerTrack *t in raw) {
        if (!isCoreQueued(t)) break;
        [future addObject:t];
        [placed addObject:trackKey(t)];
    }
    NSString *current = baseUID(state.track.UID);
    BOOL onVoice = [SGURIString(state.track.URI) hasPrefix:@"spotify:media:"];
    if (sOrdered) {
        for (NSString *uid in sOrder) {
            if (wasPlayed(uid) || [sHidden containsObject:uid]) continue;
            BOOL playing = [uid isEqualToString:current];
            if (playing && !onVoice) continue;
            // Its copy in the core's queue, at the end of the queued tracks, stands for it.
            if (sameGroup(sAheadQueued, sKept[uid].firstObject) && queuedCopyOf(sAheadQueued, state, NULL)) continue;
            for (SPTPlayerTrack *row in sKept[uid]) {
                SPTPlayerTrack *own = originalOf(row);
                if (isCardRow(row) && (playing || [sVoiced containsObject:uid])) continue;
                if ([placed containsObject:trackKey(own)]) continue;
                [future addObject:own];
                [placed addObject:trackKey(own)];
            }
        }
    }
    for (SPTPlayerTrack *t in raw) {
        if ([placed containsObject:trackKey(t)]) continue;
        NSString *uid = baseUID(t.UID);
        BOOL voice = [SGURIString(t.URI) hasPrefix:@"spotify:media:"];
        if (!isCoreQueued(t) && uid.length && (isHidden(t) || (isDJTrack(t) && wasPlayed(uid)) || (voice && [sVoiced containsObject:uid]))) continue;
        [future addObject:t];
        [placed addObject:trackKey(t)];
    }
    // A DJ track playing from the core's queue is shown as the DJ's: its uid and provider, without the queue's marks
    // (is_queued, queued_by), so the player draws no queue badge and keeps the DJ's header and footer.
    SPTPlayerTrack *asDJ = asDJTrack(state.track);
    if (!asDJ && [future isEqualToArray:raw]) return state;
    static BOOL told;
    if (!told) { told = YES; SGLog(@"queue: the now playing screens are shown the user's order (%lu to come)", (unsigned long)future.count); }
    static BOOL refused;
    if (refused || ![state conformsToProtocol:@protocol(NSCopying)]) {
        if (!refused) SGLog(@"queue: the player's state cannot be copied, the now playing screens get the core's order");
        refused = YES;
        return state;
    }
    @try {
        SPTPlayerState *shown = [(id<NSCopying>)state copyWithZone:nil];
        [shown setValue:future forKey:@"future"];
        if (asDJ) [shown setValue:asDJ forKey:@"track"];
        return shown;
    } @catch (NSException *exception) {
        refused = YES;
        SGLog(@"queue: the player's state took no other future (%@), the now playing screens get the core's order", exception.reason);
        return state;
    }
}

// The track the DJ played before the one the player is on (or is introducing: the voice has its song's uid), nil
// when none was kept.
// The newest track the DJ played before the current one that is not hidden, a track and not the current one's.
static SPTPlayerTrack *playedBefore(SPTPlayerState *state) {
    NSUInteger at = playedIndex(historyUID(state.track));
    if (at == NSNotFound) at = sPlayed.count;
    while (at > 0) {
        SPTPlayerTrack *candidate = sPlayed[--at];
        if (!isDJTrack(candidate) || staysHidden(candidate) || sameGroup(candidate, state.track)) continue;
        // Prefer the actual instance still held by the core, including a queue copy.
        for (SPTPlayerTrack *past in state.reverse.reverseObjectEnumerator)
            if (sameGroup(past, candidate)) return past;
        return candidate;
    }
    return nil;
}

%hook SPTEsperantoPlayer
// Every step back of Spotify's ends here, `track` nil for the plain one. With nothing behind the current track in
// the state, the core has run out of the ten it keeps, and the one the DJ played before is asked for by its uid.
- (id)skipToPreviousTrackWithOptions:(id)options track:(SPTPlayerTrack *)track loggingParams:(id)params {
    sBackAsked = [NSDate date];
    SPTPlayerState *state = SGPlayerState();
    // Keep Spotify's restart-current-track behavior after its first three seconds.
    SPTPlayerTrack *target = !track && isDJSession(state) && state.position < 3 ? playedBefore(state) : nil;
    if (!target) return %orig;
    NSString *was = state.track.UID;
    SGLog(@"queue: previous in the DJ history: %@ [%@]", target.trackTitle, target.UID);
    id result = %orig(options, target, params);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kJumpSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![SGPlayerState().track.UID isEqualToString:was]) {
            SGLog(@"queue: the core went back to %@", SGPlayerState().track.trackTitle);
            return;
        }
        sJumpRefused = YES;
        SGLog(@"queue: the core did not go back to %@, the plain step back instead", target.trackTitle);
        [(id<SPTPlayer>)queuePlayer() skipToPreviousTrackWithOptions:options];
    });
    return result;
}
%end

// The table's rows are the queue's tracks in order, over its sections (the hand-queued ones, the DJ's, an empty
// one), so a row's place in the table is its track's in the queue.
%hook _TtC14Queue_ViewImpl19QueueViewController
// The page's swipe actions on a row (add to queue, remove) are one horizontal pan. The row of the DJ's "Up next" card
// has none: the pan is cancelled when it begins on that row.
- (void)onSwipePanGestureWithGesture:(UIPanGestureRecognizer *)gesture {
    static BOOL blocked;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        blocked = NO;
        sSwipeRow = nil;
    }
    if (gesture.state == UIGestureRecognizerStateBegan && sDJActive && sInjected.count) {
        UIView *view = gesture.view;
        UITableView *table = [view isKindOfClass:UITableView.class] ? (UITableView *)view
            : (UITableView *)descendant(view, ^BOOL(UIView *candidate) { return [candidate isKindOfClass:UITableView.class]; });
        NSIndexPath *path = table ? [table indexPathForRowAtPoint:[gesture locationInView:table]] : nil;
        if (path) {
            NSInteger place = placeOf(table, path);
            SPTPlayerTrack *row = place < (NSInteger)sQueue.count ? sQueue[place] : nil;
            blocked = row && isCardRow(row) && indexIn(sInjected, row) != NSNotFound;
            sSwipeRow = row && !blocked && indexIn(sInjected, row) != NSNotFound ? row : nil;
        }
        if (blocked) {
            SGLog(@"queue page: swipe on the card's row is cancelled");
            gesture.enabled = NO;
            gesture.enabled = YES;
            return;
        }
    }
    if (gesture.state == UIGestureRecognizerStateEnded) {
        CGFloat x = [gesture translationInView:gesture.view].x;
        if (sSwipeRow && fabs(x) >= 110) swipeDJRow(sSwipeRow, x);
        sSwipeRow = nil;
    }
    if (blocked) {
        if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled ||
            gesture.state == UIGestureRecognizerStateFailed) blocked = NO;
        return;
    }
    %orig;
}
- (void)viewDidLayoutSubviews {
    %orig;
    drawHeaderAvatar(((UIViewController *)(id)self).view);
    sQueuePageView = ((UIViewController *)(id)self).view;
    if (sDJActive) alignHeaderPlay(((UIViewController *)(id)self).view);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // The header's row is rebuilt without the page laying out, so it is looked at again while the page is on screen.
    [sHeaderTimer invalidate];
    sHeaderTimer = nil;
    if (!sDJActive) return;
    __weak UIViewController *page = (UIViewController *)(id)self;
    sHeaderTimerPage = page;
    sHeaderTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        UIViewController *strong = page;
        if (!strong || !sDJActive) { [timer invalidate]; return; }
        drawHeaderAvatar(strong.view);
        alignHeaderPlay(strong.view);
    }];
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    // Only the page the timer is for stops it: a queue page going away after a new one has appeared (the queue closed
    // and opened again) stopped the new page's, and the card's avatar was not drawn in its "Now playing" row.
    if (sHeaderTimerPage && sHeaderTimerPage != (UIViewController *)(id)self) return;
    [sHeaderTimer invalidate];
    sHeaderTimer = nil;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger place = indexPath.row;
    for (NSInteger section = 0; section < indexPath.section; section++) place += [tableView numberOfRowsInSection:section];
    SPTPlayerTrack *track = place < (NSInteger)sQueue.count ? sQueue[place] : nil;
    // In Edit, a tap selects the row (the circle on its left), as on Spotify's own rows: it plays nothing.
    sEditTable = tableView;
    if (queueInEdit(((UIViewController *)(id)self).view)) {
        %orig;
        // The table keeps one row selected and the page draws its own ticks: each tap on a row ticks it or unticks it.
        if (track && indexIn(sInjected, track) != NSNotFound) {
            if (!sPicked) sPicked = [NSMutableOrderedSet orderedSet];
            NSString *key = trackKey(track);
            if ([sPicked containsObject:key]) [sPicked removeObject:key]; else [sPicked addObject:key];
        }
        return;
    }
    [sPicked removeAllObjects];
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
        if (target) {
            // A tap passes the rows before it: they are not played any more, whichever order the core has them in. With
            // them hidden, the core goes on to the tapped track in one skip when it has nothing else before it (the
            // rows of the page are then the core's own after it, and its next segment comes when it is the last); only
            // tracks the user put after it that the core has before it keep it on its place, and it is played through the
            // queue. Left shown, a tap with no order of the user's queued the track and the page's rows stayed as they were.
            NSString *tapped = baseUID(target.UID);
            for (NSInteger i = 0; i < place; i++) {
                SPTPlayerTrack *before = sQueue[i];
                if (indexIn(sInjected, before) == NSNotFound) continue;
                NSString *uid = baseUID(before.UID);
                if ([uid isEqualToString:tapped]) continue;
                BOOL fresh = ![sHidden containsObject:uid];
                if (fresh) hideTrack(before, @"passed by a tap");
                // Passed, not removed: they stay in the history, so a step back goes over them (5-4-3-2-1). A card and
                // its track have one uid: the card's row makes it passed, the track's row puts it in the history.
                if (fresh || [sPassed containsObject:uid]) {
                    if (!sPassed) sPassed = [NSMutableSet set];
                    [sPassed addObject:uid];
                    SPTPlayerTrack *own = originalOf(before);
                    if (!isCardRow(before) && isDJTrack(own) && playedIndex(uid) == NSNotFound && ![sPlayedBefore containsObject:uid]) [sPlayed addObject:own];
                }
            }
        }
        if (!target) {
            SGLog(@"queue page: the card %@ has no track after it to skip to", track.UID);
            return;
        }
        // A tap on the card plays its voice, then its track; a tap on the track goes to the track, its voice skipped.
        BOOL onCard = [SGURIString(track.URI) hasPrefix:@"spotify:media:"];
        if (onCard || ![sCarded containsObject:target.UID]) {
            sSkipVoiceUID = nil;
        } else {
            sSkipVoiceUID = target.UID;
            sSkipVoiceAsked = [NSDate date];
        }
        // The skip changes the queue, and the page reloads its table for it: it is made once this tap has returned,
        // not inside the table's own selection, after the now playing screens are told the rows the tap passed.
        sTapPending = YES;
        refreshReaders();
        dispatch_async(dispatch_get_main_queue(), ^{
            sTapPending = NO;
            advanceTo(target, onCard);
        });
        return;
    }
    %orig;
}
%end

static NSIndexPath *pathForPlace(UITableView *table, NSInteger place) {
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        NSInteger rows = [table numberOfRowsInSection:section];
        if (place < rows) return [NSIndexPath indexPathForRow:place inSection:section];
        place -= rows;
    }
    return nil;
}

// While a row is dragged, the place it would be dropped at: a row from below the "Up next" card and its track is not
// let go above them (the table shows it stay below).
static NSIndexPath *(*sOrigTarget)(id, SEL, UITableView *, NSIndexPath *, NSIndexPath *);
static NSIndexPath *targetRow(id self, SEL _cmd, UITableView *table, NSIndexPath *from, NSIndexPath *proposed) {
    NSIndexPath *result = sOrigTarget ? sOrigTarget(self, _cmd, table, from, proposed) : proposed;
    if (!sDJActive || !sInjected.count) return result;
    NSInteger pairEnd = topPairEnd(sQueue);
    if (pairEnd < 0 || !result) return result;
    NSInteger fromPlace = placeOf(table, from), toPlace = placeOf(table, result);
    if (fromPlace > pairEnd && toPlace <= pairEnd) {
        NSIndexPath *held = pathForPlace(table, pairEnd + 1);
        if (held) return held;
    }
    return result;
}

// Every row of the queue page is movable, as Spotify has them (a handle on each, in and out of Edit), but the DJ's card.
// The data source's own method is not asked: it is the diffable superclass's, which says no for every row, though UIKit
// shows Spotify's rows movable without the mod (9.1.90, Liked Songs: a handle on each with the switch off).
static BOOL canMoveRow(id self, SEL _cmd, UITableView *table, NSIndexPath *path) {
    if (!sDJActive || !sInjected.count) return YES;
    NSInteger place = placeOf(table, path);
    SPTPlayerTrack *row = place >= 0 && place < (NSInteger)sQueue.count ? sQueue[place] : nil;
    return !(row && indexIn(sInjected, row) != NSNotFound && isCardRow(row));
}

%ctor {
    if (!SGEnabled(SGKeyDJQueue)) return;
    %init;
    {
        Class source = NSClassFromString(@"_TtC14Queue_ViewImpl38QueueTableViewDataSourceImplementation");
        if (source) class_replaceMethod(source, @selector(tableView:canMoveRowAtIndexPath:), (IMP)canMoveRow, "c@:@@");
        Class delegate = NSClassFromString(@"_TtC14Queue_ViewImpl19QueueViewController");
        SEL target = @selector(tableView:targetIndexPathForMoveFromRowAtIndexPath:toProposedIndexPath:);
        Method current = delegate ? class_getInstanceMethod(delegate, target) : NULL;
        if (delegate) {
            sOrigTarget = current ? (NSIndexPath *(*)(id, SEL, UITableView *, NSIndexPath *, NSIndexPath *))method_getImplementation(current) : NULL;
            class_replaceMethod(delegate, target, (IMP)targetRow, "@@:@@@");
        }
    }
    static SGDJHistory *history;
    history = [[SGDJHistory alloc] init];
    SGAddPlayerStateObserver(history);
    SGSetPlayerStateLens(djLens);
    SGRequireClasses(@[@"_TtC16Queue_UpNextImpl19UpNextTrackProvider", @"_TtC14Queue_ViewImpl22PlayerStateEventSource",
                       @"_TtC14Queue_ViewImpl20QueuedTracksObserver", @"_TtC14Queue_ViewImpl19QueueViewController",
                       @"ESPContextPlayerClientImpl", @"SPTEsperantoPlayer", @"SPTPlayerQueueWrapperImpl", @"_TtC14Queue_ViewImpl9QueueCell", @"_TtC28EncoreConsumerMobile_BaseKit14PlayButtonView",
                       @"_TtC14Queue_ViewImpl38QueueTableViewDataSourceImplementation"]);
}
