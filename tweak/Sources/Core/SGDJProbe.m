#import "SGDJProbe.h"

#if SG_DRIVER
#import <stdatomic.h>
#import <stdlib.h>
#import <dispatch/dispatch.h>

// No files, network, UIKit or Spotify calls on the observed paths. The driver
// reads a bounded, in-memory event ring while the app stays in the foreground.
// Never store track names, URIs, account IDs, access tokens or metadata here.
static dispatch_queue_t probeQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.spotifyglass.dj.probe", DISPATCH_QUEUE_SERIAL); });
    return queue;
}
static NSMutableArray<NSDictionary *> *sEvents;
static uint64_t sLast, sTrimmed;
static atomic_uint_fast64_t sArtCandidates, sArtConfirmed, sArtPlaylists;
static const NSUInteger kMaxEvents = 768;

void SGDJProbeRecord(NSString *kind, NSDictionary<NSString *, id> *data) {
    if (!kind.length) return;
    NSString *label = [kind copy];
    NSDictionary *fields = [data copy] ?: @{};
    NSTimeInterval at = NSDate.date.timeIntervalSince1970;
    dispatch_async(probeQueue(), ^{
        if (!sEvents) sEvents = [NSMutableArray arrayWithCapacity:kMaxEvents];
        [sEvents addObject:@{ @"seq": @(++sLast), @"t": @(at), @"event": label, @"data": fields }];
        if (sEvents.count > kMaxEvents) {
            NSUInteger excess = sEvents.count - kMaxEvents;
            [sEvents removeObjectsInRange:NSMakeRange(0, excess)];
            sTrimmed += excess;
        }
    });
}

NSString *SGDJProbeTag(NSString *identifier) {
    if (!identifier.length) return @"-";
    static uint64_t salt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ arc4random_buf(&salt, sizeof(salt)); });
    uint64_t hash = 14695981039346656037ULL ^ salt;
    const unsigned char *s = (const unsigned char *)identifier.UTF8String;
    for (; *s; ++s) { hash ^= *s; hash *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"%08llx", (unsigned long long)(hash & 0xffffffffULL)];
}

void SGDJProbeArtworkDecision(BOOL confirmed, BOOL playlist) {
    atomic_fetch_add_explicit(&sArtCandidates, 1, memory_order_relaxed);
    if (confirmed) atomic_fetch_add_explicit(&sArtConfirmed, 1, memory_order_relaxed);
    if (playlist) atomic_fetch_add_explicit(&sArtPlaylists, 1, memory_order_relaxed);
}

NSDictionary *SGDJProbeRead(uint64_t since, NSUInteger maxEvents) {
    __block NSDictionary *result;
    NSUInteger cap = MIN(MAX(maxEvents, (NSUInteger)1), (NSUInteger)512);
    dispatch_sync(probeQueue(), ^{
        NSMutableArray *recent = [NSMutableArray array];
        for (NSDictionary *entry in sEvents) {
            if ([entry[@"seq"] unsignedLongLongValue] <= since) continue;
            [recent addObject:entry];
            if (recent.count == cap) break;
        }
        uint64_t earliest = sEvents.count ? [sEvents.firstObject[@"seq"] unsignedLongLongValue] : sLast + 1;
        result = @{ @"events": recent, @"last": @(sLast), @"trimmed": @(sTrimmed),
                    @"lostBefore": @(since + 1 < earliest ? earliest - since - 1 : 0),
                    @"artCandidates": @(atomic_load_explicit(&sArtCandidates, memory_order_relaxed)),
                    @"artConfirmed": @(atomic_load_explicit(&sArtConfirmed, memory_order_relaxed)),
                    @"artPlaylistLabels": @(atomic_load_explicit(&sArtPlaylists, memory_order_relaxed)) };
    });
    return result;
}
#endif
