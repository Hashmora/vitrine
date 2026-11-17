#!/usr/bin/env python3
"""Exercise the production Pick attempt against a fake native signal player."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
source = (root / 'tweak/Sources/Shared/Player/DJPick.x').read_text()
production = source[source.index('static const NSTimeInterval'):source.index('%hook')]
prelude = r'''
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import "Protobuf.h"
#include <assert.h>
#define SGLog(...) do {} while (0)
#define SGKeyDJPickFallback @"spotifyglass.djpick.fallback"
static BOOL fallbackEnabled = YES;
static BOOL SGFlag(NSString *key, BOOL defaultOn) { return fallbackEnabled; }
@interface SPTPlayerTrack : NSObject
@property NSString *URI, *UID, *provider;
@property NSDictionary *metadata;
@end
@implementation SPTPlayerTrack @end
@interface SPTPlayerState : NSObject
@property NSString *contextURI;
@property SPTPlayerTrack *track;
@property BOOL isPaused;
@end
@implementation SPTPlayerState @end
@protocol SPTPlayer
- (SPTPlayerState *)state;
@end
static NSString *SGURIString(id uri) { return uri; }
static int ended, changedCount;
static void SGDJQueueFinishPick(BOOL changed) { ended++; changedCount += changed; }
static void DJPickWillSendSignal(id player, id signal);
@interface FakePlayer : NSObject <SPTPlayer>
@property SPTPlayerState *state;
@property NSUInteger requests;
@property NSString *lastSignal, *parameters;
- (id)signal:(id)signal parameters:(id)parameters options:(id)options loggingParams:(id)logging;
@end
@implementation FakePlayer
- (id)signal:(id)signal parameters:(id)parameters options:(id)options loggingParams:(id)logging {
    DJPickWillSendSignal(self, signal);
    self.requests++; self.lastSignal = signal; self.parameters = parameters;
    return nil;
}
@end
'''
tests = r'''
static int callbacks, errors;
static FakePlayer *player(void) {
    FakePlayer *p = [FakePlayer new];
    p.state = [SPTPlayerState new];
    p.state.contextURI = @"spotify:playlist:37i9dQZF1EYkqdzj48dyYq";
    p.state.track = [SPTPlayerTrack new];
    p.state.track.URI = @"spotify:track:old"; p.state.track.UID = @"old"; p.state.track.metadata = @{};
    return p;
}
static SGDJPickAttempt *attempt(FakePlayer *p) {
    callbacks = errors = ended = changedCount = 0;
    fallbackEnabled = YES;
    SGDJPickAttempt *a = [SGDJPickAttempt new];
    a.player = p; a.context = p.state.contextURI; a.URI = p.state.track.URI; a.UID = p.state.track.UID;
    a.page = p.state.track.metadata[@"page_instance_id"]; a.interaction = p.state.track.metadata[@"interaction_id"];
    a.started = 100; a.accepted = YES;
    a.completions = [NSMutableArray arrayWithObject:[^(NSError *error) { callbacks++; errors += error != nil; } copy]];
    sDJPickAttempt = a;
    return a;
}
int main(void) { @autoreleasepool {
    FakePlayer *p = player(); SGDJPickAttempt *a = attempt(p);
    [a pollAt:105.9]; assert(p.requests == 0 && callbacks == 0);
    [a pollAt:106]; [a pollAt:107]; [a pollAt:110];
    assert(p.requests == 1 && callbacks == 0 && !a.finished && sDJPickAttempt == a);
    assert([p.lastSignal isEqual:@"prompt"]);
    NSData *wire = [[NSData alloc] initWithBase64EncodedString:p.parameters options:0];
    NSArray *fields = SGPBParse(wire);
    assert([SGPBText(SGPBFirst(fields, 1)) isEqual:@"Surprise me with a new mix based on my taste."]);
    assert(SGPBFirst(fields, 2).varint == 3);
    p.state.track.URI = @"spotify:media:intro"; p.state.track.UID = @"list_intro_item";
    [a pollAt:111]; [a pollAt:112];
    assert(callbacks == 1 && errors == 0 && changedCount == 1 && ended == 1 && !sDJPickAttempt);

    p = player(); a = attempt(p);
    p.state.track.URI = @"spotify:media:native-intro";
    [a pollAt:101]; assert(callbacks == 1 && changedCount == 1 && p.requests == 0);

    p = player(); a = attempt(p);
    [a pollAt:106]; [a pollAt:127]; [a pollAt:128];
    assert(callbacks == 1 && errors == 1 && changedCount == 0 && p.requests == 1);

    p = player(); a = attempt(p);
    p.state.contextURI = @"spotify:album:other";
    [a pollAt:107]; assert(callbacks == 1 && errors == 1 && changedCount == 0 && p.requests == 0);

    p = player(); a = attempt(p);
    p.state.isPaused = YES;
    [a pollAt:107]; assert(callbacks == 1 && errors == 0 && changedCount == 0 && p.requests == 0);

    p = player(); a = attempt(p); a.paused = p.state.isPaused = YES;
    [a pollAt:106]; assert(p.requests == 1 && callbacks == 0); // may request while already paused
    [a finish:nil changed:NO];

    p = player(); a = attempt(p);
    DJPickWillSendSignal(p, @"prompt"); [a pollAt:108];
    assert(callbacks == 1 && changedCount == 0 && p.requests == 0);

    p = player(); a = attempt(p);
    DJPickWillSendSignal(player(), @"prompt"); DJPickWillSendSignal(p, @"speed-preview");
    assert(callbacks == 0 && sDJPickAttempt == a);
    [a finish:nil changed:NO];

    p = player(); a = attempt(p); a.accepted = NO;
    [a pollAt:107]; assert(p.requests == 0 && callbacks == 0);
    [a pollAt:113]; assert(errors == 1 && callbacks == 1 && changedCount == 0);

    p = player(); p.state.track.metadata = @{@"page_instance_id": @"old-page"}; a = attempt(p);
    p.state.track.URI = @"spotify:track:next-in-same-set"; p.state.track.UID = @"next";
    [a pollAt:101]; assert(callbacks == 0); // natural next inside the old set is not a successful Pick
    [a pollAt:106]; assert(p.requests == 1);
    p.state.track.metadata = @{@"page_instance_id": @"new-page"};
    [a pollAt:107]; assert(callbacks == 1 && changedCount == 1);

    p = player(); a = attempt(p);
    DJPickWillSkip(p); [a pollAt:108];
    assert(callbacks == 1 && changedCount == 0 && p.requests == 0);

    p = player(); a = attempt(p);
    p.state.track.URI = @"spotify:track:old-prepared-copy"; p.state.track.UID = @"qcopy"; p.state.track.provider = @"queue";
    [a pollAt:101]; assert(callbacks == 0); // an old hand-queued/prefetched song is not a new DJ set
    p.state.track.URI = @"spotify:media:intro"; p.state.track.UID = @"list_intro_item"; p.state.track.provider = @"context";
    [a pollAt:102]; assert(callbacks == 1 && changedCount == 1);

    p = player(); a = attempt(p); fallbackEnabled = NO;
    [a pollAt:106]; assert(callbacks == 1 && p.requests == 0 && changedCount == 0);

    p = player(); a = attempt(p); [a pollAt:106]; fallbackEnabled = NO;
    p.state.track.URI = @"spotify:media:already-sent-intro";
    [a pollAt:107]; assert(callbacks == 1 && p.requests == 1 && changedCount == 1);

    assert(DJPickContext([SPTPlayerState new]) == nil);
    puts("DJ Pick: native landing, single fallback, wire payload, timeout and cancellation: PASS");
} return 0; }
'''
with tempfile.TemporaryDirectory(prefix='vitrine-dj-pick-') as d:
    main = Path(d) / 'check.m'; exe = Path(d) / 'check'
    main.write_text(prelude + production + tests)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
                    '-I', str(root / 'tweak/Sources/Shared/AdBlock'), str(main),
                    str(root / 'tweak/Sources/Shared/AdBlock/Protobuf.m'), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
