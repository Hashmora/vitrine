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
// The order the user gave the DJ's rows (a drag on the page) is kept here (sOrder), over a copy of the rows the DJ has sent
// (sKept: the core's own future forgets the tracks it has been moved past). The page shows that order, and the player is
// held to it: when the core comes to a DJ track that is not the first of ours, it is skipped to the first of ours.
// A tap on a row passes the DJ's rows before it (they are hidden). The row of the "Up next" card has no swipe actions.
// The page takes a tap on one of the tracks for a row of the core's queue, which it is not, and gives no command; it
// is skipped to as the player's here.
#import <objc/runtime.h>
#import <objc/message.h>
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
// The uris of DJ tracks the user queued by hand (swipe, menu), in the order queued: the core may give such a track
// back with the context's provider instead of "queue", and it is still a hand-queued one, before the DJ's rows.
static NSMutableArray<NSString *> *sHandQueued;
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

// What the DJ's pages need: three segments of five and the narration between them, with room for the hand-queued.
static const int64_t kFutureCap = 80;
// How long the page keeps its rows while the core has no tracks to come.
static const NSTimeInterval kGapSeconds = 3;
// How long the core has to move to a track it was asked to skip back to.
static const NSTimeInterval kJumpSeconds = 1.5;
// How long a tap on a track behind a card is waited for to reach the card's voice.
static const NSTimeInterval kSkipVoiceSeconds = 10;

// A track of the DJ's to come: not the narration, a page marker or the delimiter that ends the pages.
static void logSelectors(NSString *name);
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
// The player's own card track by uid, kept so the card's row can stay while its voice plays.
static NSMutableDictionary<NSString *, SPTPlayerTrack *> *sCardTracks;

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
static void refreshReaders(void);

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
    [sNameAsked addObject:uri];
    NSString *address = [@"https://open.spotify.com/oembed?url=" stringByAppendingString:
        [[@"https://open.spotify.com/track/" stringByAppendingString:[uri componentsSeparatedByString:@":"].lastObject]
         stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:address];
    SGLog(@"[DEBUG-dj] name asked for %@ (%@)", uri, url ? @"sent" : @"bad url");
    if (!url) return;
    askArtist(uri);
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

static CGFloat otherRowsRadius(void) {
    for (UITableViewCell *cell in sQueueCells.allObjects) {
        UIView *row = descendant(cell.contentView, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"TrackRowQueue.Cell"]; });
        if (!row || (sCardTitle.length && [row.accessibilityLabel containsString:sCardTitle])) continue;
        UIView *art = descendant(row, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"Encore.ImageView"]; });
        UIView *image = art ? descendant(art, ^BOOL(UIView *view) { return [view isMemberOfClass:UIImageView.class] && view.tag != kAvatarTag; }) : nil;
        static BOOL logged;
        if (!logged && image && image.alpha > 0) {
            logged = YES;
            SGLog(@"queue: other row's art: radius %.1f, image radius %.1f, mask %@, clips %d/%d", art.layer.cornerRadius,
                  image.layer.cornerRadius, art.layer.mask ? NSStringFromClass([art.layer.mask class]) : @"none", art.clipsToBounds, image.clipsToBounds);
        }
        CGFloat radius = MAX(art.layer.cornerRadius, image.layer.cornerRadius);
        if (radius > 0) return radius;
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
        SGLog(@"queue: card avatar put in the row (art alpha %.2f, hidden %d, image alpha %.2f)", art.alpha, art.hidden, inner.alpha);
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
    UIView *row = descendant(cell.contentView, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"TrackRowQueue.Cell"] || [view.accessibilityIdentifier isEqualToString:@"TrackRowQueue.Header"]; });
    if (row) drawAvatarInRow(row);
}

// The "Now playing" row above the table is not a cell: while the DJ's voice plays it is the card, and it has the
// placeholder where the avatar goes. It is found in the page's view and drawn the same.
static void drawHeaderAvatar(UIView *page) {
    UIView *row = descendant(page, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"TrackRowQueue.Header"]; });
    if (row) drawAvatarInRow(row);
}

// The avatar is drawn now and again as the row settles: selecting, highlighting and reloading it all redo Spotify's own.
static void drawCardAvatarSoon(UITableViewCell *cell) {
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
static NSTimer *sHeaderTimer;
static NSDate *sNativeQueueAt;
static __weak id sWrapper;
static SPTPlayerTrack *sSwipeRow;

static BOOL isCardRow(SPTPlayerTrack *row) {
    return [SGURIString(row.URI) hasPrefix:@"spotify:media:"];
}

static BOOL wasPlayed(NSString *uid) {
    for (SPTPlayerTrack *played in sPlayed) if ([baseUID(played.UID) isEqualToString:uid]) return YES;
    return NO;
}

static NSInteger placeOf(UITableView *table, NSIndexPath *path) {
    NSInteger place = path.row;
    for (NSInteger section = 0; section < path.section; section++) place += [table numberOfRowsInSection:section];
    return place;
}

static void forgetOrder(void) {
    sOrdered = NO;
    [sOrder removeAllObjects];
    [sKept removeAllObjects];
    [sBounced removeAllObjects];
    sOrderVersion++;
}

// The DJ's rows in the user's order: the groups the core still names and the ones kept from before, without the ones
// that have played, are hidden or are playing now; what the core names that is new goes at the end.
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
        if (wasPlayed(uid) || [sHidden containsObject:uid] || ([uid isEqualToString:current] && ![sBounced containsObject:uid])) {
            [sKept removeObjectForKey:uid];
            [order removeObject:uid];
        }
    }
    sOrder = order;
    NSMutableArray<SPTPlayerTrack *> *out = [NSMutableArray array];
    for (NSString *uid in order) [out addObjectsFromArray:sKept[uid]];
    return out;
}

// A drag on the page: the row at `from` of the list it shows is now at `to`. A card is moved with its track, and a
// track with its card. Only the DJ's rows are arranged; NO when the drag was not one.
static BOOL arrangeByDrag(NSArray<SPTPlayerTrack *> *list, NSInteger from, NSInteger to) {
    NSInteger count = (NSInteger)list.count;
    if (from < 0 || to < 0 || from >= count || to >= count || from == to) return NO;
    SPTPlayerTrack *moved = list[from];
    if (indexIn(sInjected, moved) == NSNotFound) return NO;
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

// A DJ track the core has already passed (its own order had it before the one it is on, the skips here went over it)
// is not skipped to as a next track: the core refuses, and the player is left waiting. It is a step back with that
// track, which the core keeps ten of behind the current one.
static BOOL behindCore(SPTPlayerTrack *target) {
    for (SPTPlayerTrack *t in SGPlayerState().reverse) {
        if ([t.UID isEqualToString:target.UID] && [t.URI isEqual:target.URI]) return YES;
    }
    return NO;
}

static NSString *trackKey(SPTPlayerTrack *track) {
    return [NSString stringWithFormat:@"%@|%@", SGURIString(track.URI), track.UID];
}

static id stepBackTo(SPTPlayerTrack *target) {
    id player = queuePlayer();
    SEL back = NSSelectorFromString(@"skipToPreviousTrackWithOptions:track:loggingParams:");
    if (![player respondsToSelector:back]) return nil;
    return ((id (*)(id, SEL, id, id, id))objc_msgSend)(player, back, nil, target, nil);
}

// The core decides by its own order whether a track is behind it, and its reverse list does not always have the
// ones it went over (a DJ card and its track skipped by a tap), so the direction is checked: when the player has not
// moved a moment after the skip, the other direction is asked once.
static void watchSkip(SPTPlayerTrack *target, NSString *was, BOOL wentBack) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *now = trackKey(SGPlayerState().track);
        if (![now isEqualToString:was]) return;
        SGLog(@"queue: the player did not move to %@ [%@], %@ instead", target.trackTitle, target.UID, wentBack ? @"a skip forward" : @"a step back");
        if (wentBack) [(id<SPTPlayer>)queuePlayer() skipToNextTrackWithOptions:nil track:target];
        else stepBackTo(target);
    });
}

static id skipToDJTrack(SPTPlayerTrack *target) {
    id player = queuePlayer();
    BOOL behind = behindCore(target);
    NSString *was = trackKey(SGPlayerState().track);
    id result;
    if (behind && [player respondsToSelector:NSSelectorFromString(@"skipToPreviousTrackWithOptions:track:loggingParams:")]) {
        SGLog(@"queue: %@ [%@] is behind the core's current track, a step back to it", target.trackTitle, target.UID);
        result = stepBackTo(target);
    } else {
        behind = NO;
        result = [(id<SPTPlayer>)player skipToNextTrackWithOptions:nil track:target];
    }
    watchSkip(target, was, behind);
    return result;
}

// The core has come to a DJ track of its own order. If the user's order has another first, the player is skipped to it
// (its card's voice is skipped on arrival, as for a tap). YES when that was asked, the track is not taken as played.
static BOOL enforceOrder(SPTPlayerState *state) {
    SPTPlayerTrack *current = state.track;
    NSString *uid = baseUID(current.UID);
    if (!sOrdered || !uid.length || !inDJ(current) || ![sOrder containsObject:uid]) return NO;
    SPTPlayerTrack *want = wantedNext();
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
    SGLog(@"queue: the player came to %@ [%@], the user's order has %@ [%@] first, skipping to it", current.trackTitle, current.UID,
          want.trackTitle, want.UID);
    dispatch_async(dispatch_get_main_queue(), ^{
        id result = skipToDJTrack(want);
        SGLog(@"queue: skip to the user's first %@ asked, it answered %@", SGURIString(want.URI), result);
    });
    return YES;
}

// The DJ track that played right after `current`, when the player has been taken back over played tracks; nil at the
// newest one.
static SPTPlayerTrack *playedAfter(SPTPlayerTrack *current) {
    NSString *uid = baseUID(current.UID);
    for (NSUInteger i = 0; i + 1 < sPlayed.count; i++) {
        if ([baseUID(sPlayed[i].UID) isEqualToString:uid]) return originalOf(sPlayed[i + 1]);
    }
    return nil;
}

// The next button while the user's order is on: the core would go to its own next DJ track, which would sound for a
// moment before enforceOrder skips away from it. The skip is asked for the user's first track at once instead, so the
// tracks passed over are never played and stay in the order. nil when the core's next is to be left alone.
static SPTPlayerTrack *redirectedNext(void) {
    SPTPlayerState *state = SGPlayerState();
    SPTPlayerTrack *current = state.track;
    if (!sOrdered || !current || !inDJ(current) || [SGURIString(current.URI) hasPrefix:@"spotify:media:"]) return nil;
    // Gone back over tracks that have played, the next one is the one that played after this, not the user's first
    // new track: the new part of the order is reached once the played ones are.
    SPTPlayerTrack *replay = playedAfter(current);
    SPTPlayerTrack *want = replay ?: wantedNext();
    if (!want || [baseUID(want.UID) isEqualToString:baseUID(current.UID)]) return nil;
    // A track queued by hand comes first, and the core's own next is the one to be left alone when it is the user's
    // first too (the core goes to it, and its voice plays).
    SPTPlayerTrack *coreNext = SGPlayerState().future.firstObject;
    if (!replay && coreNext && (isCoreQueued(coreNext) || [baseUID(coreNext.UID) isEqualToString:baseUID(want.UID)])) return nil;
    // The voice that introduces the track plays: only a tap on a row passes it.
    sSkipVoiceUID = nil;
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
    [sig appendFormat:@"|o%lu", (unsigned long)sOrderVersion];
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
        [sCardTracks removeAllObjects];
        [sHandQueued removeAllObjects];
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
    if (sOrdered) shown = arrangedRows(shown, state);
    // The hand-queued tracks, the DJ's, then whatever else the queue had.
    NSMutableArray<SPTPlayerTrack *> *queued = [NSMutableArray array], *rest = [NSMutableArray array], *injected = [NSMutableArray array];
    // The core's queue names the session again after the delimiter (stand-ins, some with another provider than the
    // ones the state named) and, after a track is queued by hand, the DJ's tracks once more: a track of the DJ's that
    // `ahead` already holds, by uri, or one already taken, is not a row of its own.
    NSMutableSet<NSString *> *aheadURIs = [NSMutableSet set], *restKeys = [NSMutableSet set];
    for (SPTPlayerTrack *track in ahead) [aheadURIs addObject:SGURIString(track.URI)];
    // A hand-queued DJ track is taken once as it plays (its DJ row is hidden, so what plays of it is the queued one).
    if (state.track && [sHandQueued containsObject:SGURIString(state.track.URI)]) {
        [sHandQueued removeObject:SGURIString(state.track.URI)];
    }
    NSMutableArray<NSString *> *handLeft = [sHandQueued mutableCopy];
    for (SPTPlayerTrack *track in next) {
        NSString *uriString = SGURIString(track.URI);
        if (isCoreQueued(track)) { [queued addObject:track]; [handLeft removeObject:uriString]; continue; }
        if ([handLeft containsObject:uriString]) {
            // The core's own copy of a DJ track the user queued: a hand-queued track, whichever provider it names.
            [handLeft removeObject:uriString];
            [queued addObject:track];
            continue;
        }
        if (indexIn(ahead, track) != NSNotFound) continue;
        NSString *uri = SGURIString(track.URI);
        if ([uri isEqualToString:@"spotify:delimiter"]) continue;
        if (isDJTrack(track) && [aheadURIs containsObject:uri]) continue;
        NSString *key = [NSString stringWithFormat:@"%@|%@", uri, track.UID ?: @""];
        if (track.UID.length && [restKeys containsObject:key]) continue;
        [restKeys addObject:key];
        [rest addObject:track];
    }
    for (SPTPlayerTrack *track in shown) if (indexIn(next, track) == NSNotFound) [injected addObject:track];
    NSMutableArray<SPTPlayerTrack *> *merged = [NSMutableArray array];
    // One row per track (uri, uid, provider): the same track twice in a row of lists is a repeat, not a second row.
    NSMutableSet<NSString *> *taken = [NSMutableSet set];
    NSUInteger repeats = 0;
    for (NSArray<SPTPlayerTrack *> *group in @[queued, shown, rest]) {
        for (SPTPlayerTrack *track in group) {
            if (track.UID.length) {
                NSString *key = [NSString stringWithFormat:@"%@|%@|%@", SGURIString(track.URI), track.UID, track.provider];
                if ([taken containsObject:key]) { repeats++; continue; }
                [taken addObject:key];
            }
            [merged addObject:track];
        }
    }
    if (repeats) SGLog(@"[DEBUG-dj] queue: %lu repeated rows left out (queued %lu, shown %lu, rest %lu, ahead %lu, core %lu)",
                       (unsigned long)repeats, (unsigned long)queued.count, (unsigned long)shown.count,
                       (unsigned long)rest.count, (unsigned long)ahead.count, (unsigned long)next.count);
    [injected filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SPTPlayerTrack *t, id _) { return [merged containsObject:t]; }]];

    if (merged.count) {
        sGapSince = nil;
    } else if (sQueue.count && inDJ(state.track)) {
        if (!sGapSince) sGapSince = [NSDate date];
        if (-sGapSince.timeIntervalSinceNow < kGapSeconds) return YES;
    }
    sQueue = merged;
    sInjected = injected;
    if (injected.count) {
        static BOOL dumped;
        if (!dumped) {
            dumped = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                logSelectors(@"_TtC14Queue_ViewImpl19QueueViewController");
                logSelectors(@"_TtC14Queue_ViewImpl38QueueTableViewDataSourceImplementation");
                logSelectors(@"SPTPlayerQueueWrapperImpl");
            });
        }
    }
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

// The drag handle of a row is UIKit's UITableViewCellReorderControl, a view of the cell itself, 44 by 44, right of the
// content (x = the content's width, centred on the row). On rows the page made late it stays at {0, 0}, over the
// cover. It is put where the other rows have it.
static void placeReorderHandle(UITableViewCell *cell) {
    UIView *control = nil;
    for (UIView *view in cell.subviews) {
        if ([NSStringFromClass(view.class) isEqualToString:@"UITableViewCellReorderControl"]) { control = view; break; }
    }
    if (!control || control.hidden || cell.bounds.size.width < 100) return;
    CGFloat width = cell.bounds.size.width, height = cell.bounds.size.height;
    CGFloat content = cell.contentView.frame.size.width;
    CGFloat x = (content > 0 && content < width) ? CGRectGetMaxX(cell.contentView.frame) : width - 60;
    CGRect want = CGRectMake(x, (height - control.frame.size.height) / 2, control.frame.size.width, control.frame.size.height);
    if (control.frame.origin.x >= width / 2 || control.frame.size.width <= 0) return;
    static int logged;
    if (logged < 12) {
        logged++;
        SGLog(@"[DEBUG-dj] reorder handle at x %.0f y %.0f in a row %.0f wide, put at x %.0f y %.0f", control.frame.origin.x,
              control.frame.origin.y, width, want.origin.x, want.origin.y);
    }
    control.frame = want;
}

%hook _TtC14Queue_ViewImpl9QueueCell
- (void)layoutSubviews {
    %orig;
    placeReorderHandle((UITableViewCell *)(id)self);
    // The hooked class is declared here without its superclass, so it is taken as the table cell it is.
    UITableViewCell *cellSelf = (UITableViewCell *)(id)self;
    if (!sQueueCells) sQueueCells = [NSHashTable weakObjectsHashTable];
    [sQueueCells addObject:cellSelf];
    drawCardAvatar(cellSelf);
    // The row's own image view may be set again a moment after the layout.
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

// What a context the app gives the core holds: its pages, the tracks on each and where the next one is. The DJ's
// session is handed over as pages (five tracks each); whether the app gives the core all of them or one is in the log.
static void logContext(NSString *where, id context) {
    if (![context respondsToSelector:@selector(pagesArray)]) return;
    NSArray *pages = [context valueForKey:@"pagesArray"];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (id page in pages) {
        NSArray *tracks = [page valueForKey:@"tracksArray"];
        NSString *next = [page valueForKey:@"nextPageURL"];
        [parts addObject:[NSString stringWithFormat:@"%lu tracks, next %@", (unsigned long)tracks.count, next.length ? next : @"none"]];
    }
    SGLog(@"[DEBUG-dj] context via %@: %@ (%lu pages) %@", where, [context valueForKey:@"uri"], (unsigned long)pages.count,
          [parts componentsJoinedByString:@" | "]);
}

static void logPage(NSString *where, id page) {
    if (![page respondsToSelector:@selector(tracksArray)]) return;
    NSString *next = [page valueForKey:@"nextPageURL"];
    SGLog(@"[DEBUG-dj] context page via %@: %lu tracks, next %@", where, (unsigned long)[[page valueForKey:@"tracksArray"] count],
          next.length ? next : @"none");
}

// The app-side context (SPTPlayerContext): its uri, pages, and on each page the tracks and where the next one is.
static void logPlayerContext(NSString *where, id context) {
    if (!context) { SGLog(@"[DEBUG-dj] context via %@: nil", where); return; }
    if (![context respondsToSelector:@selector(pages)]) {
        SGLog(@"[DEBUG-dj] context via %@: %@ (not a context)", where, NSStringFromClass([context class]));
        return;
    }
    NSArray *pages = [context valueForKey:@"pages"];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (id page in pages) {
        NSArray *tracks = [page respondsToSelector:@selector(tracks)] ? [page valueForKey:@"tracks"] : nil;
        id next = [page respondsToSelector:@selector(nextPageURL)] ? [page valueForKey:@"nextPageURL"] : nil;
        id url = [page respondsToSelector:@selector(pageURL)] ? [page valueForKey:@"pageURL"] : nil;
        [parts addObject:[NSString stringWithFormat:@"%lu tracks, page %@, next %@", (unsigned long)tracks.count, url ?: @"none", next ?: @"none"]];
    }
    SGLog(@"[DEBUG-dj] context via %@: %@ url %@ (%lu pages) %@", where, [context valueForKey:@"URI"], [context valueForKey:@"URL"],
          (unsigned long)pages.count, [parts componentsJoinedByString:@" | "]);
}

// The ways the app starts a context in the player. One of them is how the DJ starts; each says so in the log.
%hook SPTEsperantoPlayer
- (id)playContext:(id)context options:(id)options {
    logPlayerContext(@"SPTPlayer playContext:options:", context);
    return %orig;
}
- (id)playContext:(id)context options:(id)options loggingParams:(id)params {
    logPlayerContext(@"SPTPlayer playContext:options:loggingParams:", context);
    return %orig;
}
- (id)playContext:(id)context options:(id)options viewURI:(id)viewURI {
    logPlayerContext(@"SPTPlayer playContext:options:viewURI:", context);
    return %orig;
}
- (id)playContext:(id)context options:(id)options loggingParams:(id)params viewURI:(id)viewURI {
    logPlayerContext(@"SPTPlayer playContext:options:loggingParams:viewURI:", context);
    return %orig;
}
- (id)playContext:(id)context options:(id)options externalReferrer:(id)referrer {
    logPlayerContext(@"SPTPlayer playContext:options:externalReferrer:", context);
    return %orig;
}
- (id)playContext:(id)context options:(id)options origin:(id)origin {
    logPlayerContext(@"SPTPlayer playContext:options:origin:", context);
    return %orig;
}
- (id)playContext:(id)context options:(id)options loggingParams:(id)params origin:(id)origin {
    logPlayerContext(@"SPTPlayer playContext:options:loggingParams:origin:", context);
    return %orig;
}
- (id)preparePlaybackOfContext:(id)context options:(id)options viewURI:(id)viewURI {
    logPlayerContext(@"SPTPlayer preparePlaybackOfContext:", context);
    return %orig;
}
- (id)preparePlaybackOfContext:(id)context options:(id)options viewURI:(id)viewURI playOrigin:(id)origin {
    logPlayerContext(@"SPTPlayer preparePlaybackOfContext:playOrigin:", context);
    return %orig;
}
%end

// A context made from one page url (the core then fetches the pages itself) or from tracks, wherever it is made.
%hook SPTPlayerContext
+ (id)contextWithPageURL:(id)url {
    id context = %orig;
    SGLog(@"[DEBUG-dj] context made with a page url: %@", url);
    return context;
}
+ (id)contextWithTracks:(id)tracks {
    id context = %orig;
    SGLog(@"[DEBUG-dj] context made with %lu tracks", (unsigned long)[tracks count]);
    return context;
}
+ (id)contextWithDictionary:(id)dictionary {
    id context = %orig;
    if ([[dictionary description] containsString:@"page_instance_id"] || [[dictionary description] containsString:@"dj"])
        logPlayerContext(@"contextWithDictionary", context);
    return context;
}
%end

%hook ESPContextPlayerClientImpl
- (void)playPrepared:(id)request onResponse:(id)onResponse {
    SGLog(@"[DEBUG-dj] playPrepared: session %@", [request valueForKey:@"sessionId"]);
    %orig;
}
- (void)preparePlay:(id)request onResponse:(id)onResponse {
    logContext(@"preparePlay", [request valueForKey:@"context"]);
    %orig;
}
- (void)play:(id)request onResponse:(id)onResponse {
    logContext(@"play", [[request valueForKey:@"preparePlayRequest"] valueForKey:@"context"]);
    %orig;
}
- (void)updateContext:(id)request onResponse:(id)onResponse {
    logContext(@"updateContext", [request valueForKey:@"context"]);
    %orig;
}
- (void)updateContextPage:(id)request onResponse:(id)onResponse {
    logPage(@"updateContextPage", [request valueForKey:@"contextPage"]);
    %orig;
}
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
    // A DJ row that is queued is moved, not copied: the queued track is the hand-queued one, and the DJ's own row of it
    // is hidden, or the core plays the track twice (the queued one, then the DJ's, one after the other).
    if (dj && !isCardRow(dj)) {
        hideTrack(dj, @"queued by hand");
        if (!sHandQueued) sHandQueued = [NSMutableArray array];
        [sHandQueued addObject:SGURIString(dj.URI)];
        SGLog(@"queue command: addToQueue: the DJ's row %@ is moved to the hand-queued tracks", dj.trackTitle);
        refreshReaders();
    } else {
        SGLog(@"queue command: addToQueue: not one of the DJ's rows");
    }
    %orig;
}
- (void)setQueue:(id)request onResponse:(id)onResponse {
    sNativeQueueAt = [NSDate date];
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

// What the page may do to the queue is asked of the player's restrictions; each answer is logged when it first comes or
// changes, to tell whether the DJ's session forbids the removing and the reordering the page does not do.
static void logRestriction(NSString *what, BOOL answer) {
    static NSMutableDictionary<NSString *, NSNumber *> *last;
    if (!last) last = [NSMutableDictionary dictionary];
    if (last[what] && last[what].boolValue == answer) return;
    last[what] = @(answer);
    SGLog(@"queue: restriction %@: %@", what, answer ? @"forbidden" : @"allowed");
}

%hook SPTPlayerRestrictions
- (BOOL)disallowRemovingFromNextTracks { BOOL answer = %orig; logRestriction(@"removing from next tracks", answer); return answer; }
- (BOOL)disallowRemovingFromContextTracks { BOOL answer = %orig; logRestriction(@"removing from context tracks", answer); return answer; }
- (BOOL)disallowReorderingInNextTracks { BOOL answer = %orig; logRestriction(@"reordering in next tracks", answer); return answer; }
- (BOOL)disallowReorderingInContextTracks { BOOL answer = %orig; logRestriction(@"reordering in context tracks", answer); return answer; }
- (BOOL)disallowSetQueue { BOOL answer = %orig; logRestriction(@"set queue", answer); return answer; }
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
            if (!wrapper) {
                id fresh = [NSClassFromString(@"SPTPlayerQueueWrapperImpl") alloc];
                wrapper = ((id (*)(id, SEL, id))objc_msgSend)(fresh, NSSelectorFromString(@"initWithPlayer:"), queuePlayer());
            }
            SGLog(@"queue page: swipe adds %@ [%@] to the queue, the DJ's row moves to it (wrapper %@)", row.trackTitle, own.UID, [wrapper class]);
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
    SGLog(@"queue page: queue track %@ [%@] %@", track.trackTitle, track.UID, SGURIString(track.URI));
    if (track && indexIn(sInjected, track) != NSNotFound && !isCardRow(track)) {
        // A DJ row: its copy is not the core's track. The core queues the player's own, as one more track among the
        // hand-queued ones before the DJ's. The DJ's row of it is hidden by the addToQueue that follows.
        SPTPlayerTrack *own = originalOf(track);
        SGLog(@"queue page: queue track %@ given to the core as its own %@ [%@], the DJ's row is hidden after", track.trackTitle, SGURIString(own.URI), own.UID);
        return %orig(own, options, params);
    }
    return %orig;
}
- (id)queueTracksInternal:(NSArray<SPTPlayerTrack *> *)tracks options:(id)options loggingParams:(id)params {
    sNativeQueueAt = [NSDate date];
    SGLog(@"queue page: queue %lu tracks, first %@", (unsigned long)tracks.count, SGURIString(tracks.firstObject.URI));
    return %orig;
}
- (id)queueTrackPlayNext:(SPTPlayerTrack *)track {
    sNativeQueueAt = [NSDate date];
    SGLog(@"queue page: play next %@ [%@] %@", track.trackTitle, track.UID, SGURIString(track.URI));
    return %orig;
}
%end

%hook _TtC14Queue_ViewImpl38QueueTableViewDataSourceImplementation
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    SGLog(@"queue page: drag section %ld row %ld to section %ld row %ld (%lu rows shown)", (long)from.section, (long)from.row,
          (long)to.section, (long)to.row, (unsigned long)sQueue.count);
    NSArray<SPTPlayerTrack *> *list = [sQueue copy];
    %orig;
    BOOL arranged = arrangeByDrag(list, placeOf(tableView, from), placeOf(tableView, to));
    if (!arranged) SGLog(@"queue page: the drag moved no DJ row, the page's rows are given again");
    // Once the drop is over, the page is given the list again: ours, or the one it had if the drag was not ours.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ refreshReaders(); });
}
%end

%hook SPTEsperantoPlayer
- (id)skipToNextTrackWithOptions:(id)options track:(SPTPlayerTrack *)track {
    SGLog(@"queue command: skip to %@ [%@]", track.trackTitle, track.provider);
    return %orig;
}
- (id)setQueue:(id)queue options:(id)options loggingParams:(id)params {
    SGLog(@"queue command: player setQueue, %lu next tracks", (unsigned long)([queue respondsToSelector:@selector(nextTracks)] ? [[queue valueForKey:@"nextTracks"] count] : 0));
    return %orig;
}
- (id)skipToNextTrackWithOptions:(id)options track:(SPTPlayerTrack *)track loggingParams:(id)params {
    SGLog(@"queue command: skip to (with logging params) %@ [%@] %@", track.trackTitle, track.provider, SGURIString(track.URI));
    if (!track) {
        SPTPlayerTrack *want = redirectedNext();
        if (want) {
            NSString *was = SGPlayerState().track.UID;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SPTPlayerTrack *now = SGPlayerState().track;
                SGLog(@"queue: 2 s after the next to %@ the player is on %@ [%@]%@", want.trackTitle, now.trackTitle, now.UID,
                      [now.UID isEqualToString:was] ? @", it did not move" : @"");
            });
            NSString *startedOn = trackKey(SGPlayerState().track);
            if (behindCore(want)) {
                SGLog(@"queue: %@ is behind the core's current track, a step back to it", want.trackTitle);
                id result = ((id (*)(id, SEL, id, id, id))objc_msgSend)(self, @selector(skipToPreviousTrackWithOptions:track:loggingParams:), options, want, params);
                watchSkip(want, startedOn, YES);
                return result;
            }
            id result = %orig(options, want, params);
            watchSkip(want, startedOn, NO);
            return result;
        }
    }
    return %orig;
}
%end

// The DJ's tracks as they have played, in the session's order, whole, for the steps back the core has no track for.
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
    if (isHidden(track)) {
        NSString *key = [SGURIString(track.URI) stringByAppendingString:track.UID];
        if (!sSkipped) sSkipped = [NSMutableSet set];
        if (![sSkipped containsObject:key]) {
            [sSkipped addObject:key];
            SGLog(@"queue: the player is on a hidden track %@ %@, skipping it", track.trackTitle, SGURIString(track.URI));
            [(id<SPTPlayer>)queuePlayer() skipToNextTrackWithOptions:nil];
            return;
        }
    }
    // The core has come to a DJ track of its own order that the user's order does not have first.
    if (enforceOrder(state)) return;
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
        UIView *view = gesture.view;
        UITableView *table = [view isKindOfClass:UITableView.class] ? (UITableView *)view
            : (UITableView *)descendant(view, ^BOOL(UIView *candidate) { return [candidate isKindOfClass:UITableView.class]; });
        NSIndexPath *path = table ? [table indexPathForRowAtPoint:[gesture locationInView:table]] : nil;
        if (path) {
            NSInteger place = placeOf(table, path);
            SPTPlayerTrack *row = place < (NSInteger)sQueue.count ? sQueue[place] : nil;
            blocked = row && isCardRow(row) && indexIn(sInjected, row) != NSNotFound;
            sSwipeRow = row && !blocked && indexIn(sInjected, row) != NSNotFound ? row : nil;
        } else {
            sSwipeRow = nil;
        }
        if (path) SGLog(@"queue page: swipe begins on section %ld row %ld, place %ld, the DJ's row: %d", (long)path.section, (long)path.row,
                        (long)placeOf(table, path), (int)(placeOf(table, path) < (NSInteger)sQueue.count && indexIn(sInjected, sQueue[placeOf(table, path)]) != NSNotFound));
        if (blocked) {
            SGLog(@"queue page: swipe on the card's row is cancelled");
            gesture.enabled = NO;
            gesture.enabled = YES;
            return;
        }
    }
    if (gesture.state == UIGestureRecognizerStateEnded) {
        CGFloat x = [gesture translationInView:gesture.view].x;
        SGLog(@"queue page: swipe ends at %.0f", x);
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
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // The header's row is rebuilt without the page laying out, so it is looked at again while the page is on screen.
    [sHeaderTimer invalidate];
    __weak UIViewController *page = (UIViewController *)(id)self;
    sHeaderTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *timer) {
        UIViewController *strong = page;
        if (!strong) { [timer invalidate]; return; }
        drawHeaderAvatar(strong.view);
    }];
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    [sHeaderTimer invalidate];
    sHeaderTimer = nil;
}
- (void)tableView:(UITableView *)tableView didEndReorderingRowAtIndexPath:(NSIndexPath *)indexPath {
    SGLog(@"queue page: reordering ended on section %ld row %ld", (long)indexPath.section, (long)indexPath.row);
    %orig;
}
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
        if (target && sOrdered) {
            // A tap passes the rows before it: they are not played any more, whichever order the core has them in.
            NSString *tapped = baseUID(target.UID);
            for (NSInteger i = 0; i < place; i++) {
                SPTPlayerTrack *before = sQueue[i];
                if (indexIn(sInjected, before) == NSNotFound) continue;
                NSString *uid = baseUID(before.UID);
                if (![uid isEqualToString:tapped] && ![sHidden containsObject:uid]) hideTrack(before, @"passed by a tap");
            }
        }
        if (!target) {
            SGLog(@"queue page: the card %@ has no track after it to skip to", track.UID);
            return;
        }
        SGLog(@"queue page: skip to %@ [%@], from row %@ [%@], through %@ (SGPlayer %@)", SGURIString(target.URI), target.UID,
              SGURIString(track.URI), track.UID, [queuePlayer() class], SGPlayer() ? @"there" : @"gone");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SPTPlayerTrack *now = SGPlayerState().track;
            SGLog(@"queue page: 4 s after the skip to %@ the player is on %@ [%@]", SGURIString(target.URI), SGURIString(now.URI), now.UID);
        });
        if ([SGURIString(track.URI) hasPrefix:@"spotify:media:"] || ![sCarded containsObject:target.UID]) {
            sSkipVoiceUID = nil;
        } else {
            sSkipVoiceUID = target.UID;
            sSkipVoiceAsked = [NSDate date];
        }
        // The skip changes the queue, and the page reloads its table for it: it is made once this tap has returned,
        // not inside the table's own selection.
        dispatch_async(dispatch_get_main_queue(), ^{
            id result = skipToDJTrack(target);
            SGLog(@"queue page: skip to %@ asked of %@, it answered %@", SGURIString(target.URI), [queuePlayer() class], result);
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

// What the page can be told to remove or queue is not known from here: the selectors of its classes that name a removal,
// a swipe or a queueing are logged once, to hook the right ones.
static void logSelectors(NSString *name) {
    Class cls = NSClassFromString(name);
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (; cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *sel = NSStringFromSelector(method_getName(methods[i]));
            if ([sel rangeOfString:@"remov" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [sel rangeOfString:@"delet" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [sel rangeOfString:@"swipe" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [sel rangeOfString:@"commit" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [sel rangeOfString:@"queue" options:NSCaseInsensitiveSearch].location != NSNotFound) [found addObject:sel];
        }
        free(methods);
        break;
    }
    SGLog(@"queue: selectors of %@: %@", name, [found componentsJoinedByString:@" "]);
}

// The DJ's "Up next" card is not moved by hand: it goes with its track and is only there while the voice is to play.
// Only that row says no. Every other row is movable as the page has it: the data source is a diffable one that may not
// answer for itself, and its answer must not take the handle away from the tracks.
static BOOL (*sOrigCanMove)(id, SEL, UITableView *, NSIndexPath *);
static BOOL canMoveRow(id self, SEL _cmd, UITableView *table, NSIndexPath *path) {
    NSInteger place = placeOf(table, path);
    SPTPlayerTrack *row = place >= 0 && place < (NSInteger)sQueue.count ? sQueue[place] : nil;
    BOOL card = row && isCardRow(row) && indexIn(sInjected, row) != NSNotFound;
    static int logged;
    if (logged < 30) {
        logged++;
        SGLog(@"[DEBUG-dj] canMoveRow section %ld row %ld, place %ld of %lu, card: %d, the page's own answer: %@", (long)path.section,
              (long)path.row, (long)place, (unsigned long)sQueue.count, (int)card,
              sOrigCanMove ? (sOrigCanMove(self, _cmd, table, path) ? @"yes" : @"no") : @"none");
    }
    return !card;
}

%ctor {
    %init;
    {
        Class source = NSClassFromString(@"_TtC14Queue_ViewImpl38QueueTableViewDataSourceImplementation");
        SEL canMove = @selector(tableView:canMoveRowAtIndexPath:);
        Method existing = source ? class_getInstanceMethod(source, canMove) : NULL;
        if (source) {
            sOrigCanMove = existing ? (BOOL (*)(id, SEL, UITableView *, NSIndexPath *))method_getImplementation(existing) : NULL;
            class_replaceMethod(source, canMove, (IMP)canMoveRow, "c@:@@");
        }
    }
    SGLog(@"queue: DJ queue hooks are on");
    installExceptionLog();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        logSelectors(@"_TtC14Queue_ViewImpl19QueueViewController");
        logSelectors(@"_TtC14Queue_ViewImpl38QueueTableViewDataSourceImplementation");
        logSelectors(@"SPTPlayerQueueWrapperImpl");
    });
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
