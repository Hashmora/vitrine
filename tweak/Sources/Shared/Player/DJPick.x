// Spotify 9.1.90 acknowledges a `jump` signal before the playlist service
// answers it. That service can return HTTP 502 while the native completion
// still says success. Observe the actual landing; if it never comes, use the
// native suggested-prompt signal, which works in the same DJ session.
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Shared/AdBlock/Protobuf.h"
#import "DJQueue.h"
#import "DJPick.h"
#import "PlayerState.h"
#import <objc/message.h>
#import <objc/runtime.h>

static const NSTimeInterval kDJPickGrace = 6, kDJPromptTimeout = 20;
static NSString *DJPickContext(SPTPlayerState *state) {
    NSString *uri = SGURIString(state.contextURI);
    if ([uri isEqualToString:@"spotify:playlist:37i9dQZF1EYkqdzj48dyYq"] ||
        ([uri hasPrefix:@"spotify:playlist:"] && state.track.metadata[@"segment"])) return uri;
    return nil;
}
static NSString *DJPickPrompt(void) {
    // Native 9.1.90 suggested request: protobuf field 1 is the English text,
    // field 2 is 3 (suggested prompt), carried as base64 in ESPSignalRequest.
    NSData *body = SGPBSerialize(@[SGPBString(1, @"Surprise me with a new mix based on my taste."), SGPBVarint(2, 3)]);
    return [body base64EncodedStringWithOptions:0];
}
static NSError *DJPickError(NSString *detail) {
    return [NSError errorWithDomain:@"dev.vitrine.dj-pick" code:1 userInfo:@{NSLocalizedDescriptionKey: detail}];
}

@interface SGDJPickAttempt : NSObject
@property id player;
@property NSString *context, *URI, *UID, *page, *interaction;
@property NSTimeInterval started, promptAt;
@property BOOL accepted, prompted, finished, paused;
@property NSTimer *timer;
@property NSMutableArray *completions;
- (void)pollAt:(NSTimeInterval)now;
- (void)finish:(NSError *)error changed:(BOOL)changed;
@end
static SGDJPickAttempt *sDJPickAttempt;
static BOOL sDJPickSendingPrompt;

@implementation SGDJPickAttempt
- (void)finish:(NSError *)error changed:(BOOL)changed {
    if (self.finished) return;
    self.finished = YES;
    [self.timer invalidate]; self.timer = nil;
    if (sDJPickAttempt == self) sDJPickAttempt = nil;
    SGDJQueueFinishPick(changed);
    NSArray *callbacks = [self.completions copy];
    [self.completions removeAllObjects];
    for (void (^callback)(NSError *) in callbacks) callback(error);
}
- (void)pollAt:(NSTimeInterval)now {
    if (self.finished) return;
    // Disabling the setting cancels an unsent retry. A request already sent
    // still needs its landing tracked so the old custom order is cleared.
    if (!self.prompted && !SGEnabled(SGKeyDJPickFallback)) { [self finish:nil changed:NO]; return; }
    SPTPlayerState *state = [(id<SPTPlayer>)self.player state];
    if (![DJPickContext(state) isEqualToString:self.context]) {
        [self finish:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil] changed:NO];
        return;
    }
    BOOL same = [SGURIString(state.track.URI) isEqualToString:self.URI] &&
                [state.track.UID ?: @"" isEqualToString:self.UID];
    BOOL samePage = self.page.length && [state.track.metadata[@"page_instance_id"] isEqualToString:self.page];
    if (self.interaction.length && state.track.metadata[@"interaction_id"] &&
        ![state.track.metadata[@"interaction_id"] isEqualToString:self.interaction]) samePage = NO;
    BOOL queued = [state.track.provider isEqualToString:@"queue"] || [state.track.UID hasPrefix:@"q"];
    if (!same && !samePage && !queued) {
        SGLog(@"DJ pick: confirmed %@ landing on %@ [%@]", self.prompted ? @"prompt" : @"native", state.track.URI, state.track.UID);
        [self finish:nil changed:YES];
        return;
    }
    // Pausing while waiting cancels the automatic retry, rather than starting
    // another request after the user has stopped listening.
    if (!self.paused && state.isPaused) { [self finish:nil changed:NO]; return; }
    if (!self.accepted) {
        if (now - self.started > 12) [self finish:DJPickError(@"DJ did not acknowledge the request. Please try again.") changed:NO];
        return;
    }
    if (self.prompted) {
        if (now - self.promptAt > kDJPromptTimeout) [self finish:DJPickError(@"DJ did not start a new set. Please try again.") changed:NO];
        return;
    }
    if (now - self.started < kDJPickGrace) return;
    self.prompted = YES;
    self.promptAt = now;
    SGLog(@"DJ pick: native jump acknowledged without a landing; requesting one neutral suggested prompt");
    sDJPickSendingPrompt = YES;
    @try {
        ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(self.player,
            NSSelectorFromString(@"signal:parameters:options:loggingParams:"), @"prompt", DJPickPrompt(), nil, nil);
    } @finally { sDJPickSendingPrompt = NO; }
}
@end

static void DJPickWillSendSignal(id player, id signal) {
    if (NSThread.isMainThread && !sDJPickSendingPrompt && [signal isEqual:@"prompt"] && sDJPickAttempt.player == player)
        [sDJPickAttempt finish:nil changed:NO];
}

static void DJPickWillSkip(id player) {
    if (NSThread.isMainThread && sDJPickAttempt.player == player) [sDJPickAttempt finish:nil changed:NO];
}

%hook _TtC16Endless_AIDJImpl17CompositeJumpable
- (void)jumpWithCompletion:(void (^)(NSError *))completion {
    if (!SGEnabled(SGKeyDJPickFallback)) { %orig; return; }
    // These are 9.1.90's native ivar and selector. Older implementations and
    // sessions without prompt support retain their original behavior.
    Ivar fallbackField = class_getInstanceVariable(object_getClass(self), "fallback");
    id fallback = fallbackField ? object_getIvar(self, fallbackField) : nil;
    Ivar field = fallback ? class_getInstanceVariable(object_getClass(fallback), "player") : NULL;
    id player = field ? object_getIvar(fallback, field) : nil;
    SEL signal = NSSelectorFromString(@"signal:parameters:options:loggingParams:");
    SPTPlayerState *state = [player respondsToSelector:@selector(state)] ? [(id<SPTPlayer>)player state] : nil;
    SEL signals = NSSelectorFromString(@"signals");
    id supported = [state respondsToSelector:signals] ? ((id (*)(id, SEL))objc_msgSend)(state, signals) : nil;
    NSString *context = DJPickContext(state);
    // The request sheet invokes the same native object from a worker queue;
    // the queue button invokes it on main. Serialize both before touching the
    // attempt, its timer or the queue UI. Do not synchronously wait for main.
    if (!NSThread.isMainThread && context && [player respondsToSelector:signal] &&
        [supported respondsToSelector:@selector(containsObject:)] && [supported containsObject:@"prompt"]) {
        id jumper = (id)self;
        dispatch_async(dispatch_get_main_queue(), ^{
            ((void (*)(id, SEL, id))objc_msgSend)(jumper, NSSelectorFromString(@"jumpWithCompletion:"), completion);
        });
        return;
    }
    if (!context || ![player respondsToSelector:signal] ||
        ![supported respondsToSelector:@selector(containsObject:)] || ![supported containsObject:@"prompt"]) {
        if (context) SGLog(@"DJ pick: preserving native implementation (main=%d, prompt=%d)", NSThread.isMainThread, [supported respondsToSelector:@selector(containsObject:)] && [supported containsObject:@"prompt"]);
        %orig; return;
    }
    if (sDJPickAttempt) {
        if (sDJPickAttempt.player == player && [sDJPickAttempt.context isEqualToString:context]) {
            if (completion) [sDJPickAttempt.completions addObject:[completion copy]];
            return;
        }
        [sDJPickAttempt finish:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil] changed:NO];
    }
    SGDJPickAttempt *attempt = [SGDJPickAttempt new];
    attempt.player = player;
    attempt.context = context;
    attempt.URI = SGURIString(state.track.URI) ?: @"";
    attempt.UID = state.track.UID ?: @"";
    attempt.page = state.track.metadata[@"page_instance_id"];
    attempt.interaction = state.track.metadata[@"interaction_id"];
    attempt.paused = state.isPaused;
    attempt.started = CACurrentMediaTime();
    attempt.completions = [NSMutableArray array];
    if (completion) [attempt.completions addObject:[completion copy]];
    sDJPickAttempt = attempt;
    SGDJQueueBeginPick();
    __weak SGDJPickAttempt *weak = attempt;
    attempt.timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        SGDJPickAttempt *strong = weak;
        if (!strong) { [timer invalidate]; return; }
        [strong pollAt:CACurrentMediaTime()];
    }];
    [NSRunLoop.mainRunLoop addTimer:attempt.timer forMode:NSRunLoopCommonModes];
    %orig(^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (attempt.finished) return;
            if (error) { [attempt finish:error changed:NO]; return; }
            attempt.accepted = YES;
            SGLog(@"DJ pick: local jump acknowledged; waiting for an actual landing");
            [attempt pollAt:CACurrentMediaTime()];
        });
    });
}
%end

%hook SPTEsperantoPlayer
- (id)signal:(id)signal parameters:(id)parameters options:(id)options loggingParams:(id)logging {
    // An explicit text/suggested request replaces a pending Pick. Its own
    // request is sent once; a delayed timer must not send another on top of it.
    DJPickWillSendSignal(self, signal);
    return %orig;
}
- (id)skipToNextTrackWithOptions:(id)options track:(SPTPlayerTrack *)track loggingParams:(id)logging {
    DJPickWillSkip(self);
    return %orig;
}
- (id)skipToPreviousTrackWithOptions:(id)options track:(SPTPlayerTrack *)track loggingParams:(id)logging {
    DJPickWillSkip(self);
    return %orig;
}
%end

%ctor { %init; }
