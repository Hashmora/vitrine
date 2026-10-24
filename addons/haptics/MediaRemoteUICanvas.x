// Vitrine Addon in MediaRemoteUI, the lock screen's Canvas below iOS 26: MediaRemoteUI draws the lock screen's player
// and, when its cover is tapped, the large cover over the lock screen, in a window of its own
// (MediaRemoteUI.SecureWindow, full screen) holding MediaRemoteUI.CoverSheetBackgroundView: an MTKView for the coloured
// field and the large MRUArtworkView, 352pt on a 414pt phone (the phone's tree, 2026-10-24). The player's own small
// cover is in its other window, and the system takes it away as the large one opens.
//
// While the large cover is open, Spotify's switch is on (kSGRelayLockArtOn) and SpringBoard has shared the song's clip
// (kSGRelayLockClipShared, SGLockSharedClipPath), the large cover is hidden and the clip shown full screen in its place,
// over the field (LockClipView.h), and SpringBoard is told (kSGRelayLockShowing) to hide the widgets under the clock.
// A clip that comes later takes the cover's place as it comes; with none the system's cover stays as it is, and closed,
// everything of the system's comes back. The clip holds still while the song is paused.
//
// MediaRemoteUI gives the large cover its alpha back as it animates (the phone, 2026-10-25: the cover stayed over the clip
// until the screen had gone off and on a few times), so a hidden cover keeps alpha 0 whatever it is set to, and gets the
// last alpha MediaRemoteUI asked for back. A tap that closes the large cover (the field's own, heard alongside it) gives
// the cover back at once, for MediaRemoteUI to shrink it into the player as it does with no clip, and fades the clip out
// over it: hidden, the cover had nothing to shrink and the clip went at once.
//
// A song with no clip gets its still cover the same way, the screen's width across on the bands of its edges' colours,
// while Spotify is what plays: the cover from MediaRemote's now playing info, as the lock screen's own player has it.
// While the screen is dark the clip is not read or decoded (com.apple.springboard.hasBlankedScreen), and lit it starts
// over on a new display layer.
//
// Only the large cover's view and the cover itself are hooked, as they lay out, come and go and take an alpha.
//
// Threading: main thread.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <notify.h>
#import "LockClipView.h"
#import "../../tweak/Sources/Shared/Haptics/SGHapticRelay.h"

typedef void (*SGMRIsPlaying)(dispatch_queue_t queue, void (^handler)(Boolean playing));
typedef void (*SGMRRegister)(dispatch_queue_t queue);
typedef void (*SGMRGetInfo)(dispatch_queue_t queue, void (^handler)(CFDictionaryRef info));
typedef void (*SGMRGetApp)(dispatch_queue_t queue, void (^handler)(CFStringRef bundle));

static const NSTimeInterval kFade = 0.35;

static SGMRIsPlaying sg_isPlaying;
static SGMRGetInfo sg_getInfo;
static SGMRGetApp sg_getApp;
static BOOL sg_on, sg_playing = YES, sg_showing, sg_blank;
static UIImage *sg_cover;   // Spotify's song's still cover, nil for none or for another app
static NSData *sg_coverData;
static NSURL *sg_clip;   // this process's own copy of the shared clip, nil for none
static __weak UIView *sg_field;   // the large cover's CoverSheetBackgroundView, while it is open
static char kClipKey, kTapKey, kHiddenKey, kWantedKey, kClosedKey;
static BOOL sg_settingAlpha;   // the alpha set here, not MediaRemoteUI's to remember

@interface SGVFieldTap : NSObject <UIGestureRecognizerDelegate>
@end

static void closing(UIView *field);

@implementation SGVFieldTap
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
- (void)tapped:(UITapGestureRecognizer *)tap {
    closing(tap.view);
}
@end

// The large cover hidden or given back: alpha 0 held while hidden, the alpha MediaRemoteUI last asked for after.
static void hideArtwork(UIView *artwork, BOOL hidden, BOOL animated) {
    if (!artwork || !!objc_getAssociatedObject(artwork, &kHiddenKey) == hidden) return;
    NSNumber *wanted = objc_getAssociatedObject(artwork, &kWantedKey);
    objc_setAssociatedObject(artwork, &kHiddenKey, hidden ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat alpha = hidden ? 0 : (wanted ? wanted.doubleValue : 1);
    sg_settingAlpha = YES;
    [UIView animateWithDuration:animated ? kFade : 0 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ artwork.alpha = alpha; } completion:nil];
    sg_settingAlpha = NO;
}

// The large cover in the field: the field's MRUArtworkView.
static UIView *artworkIn(UIView *field) {
    Class artwork = NSClassFromString(@"MRUArtworkView");
    for (UIView *sub in field.subviews) if (artwork && [sub isKindOfClass:artwork]) return sub;
    return nil;
}

static void tellShowing(BOOL showing) {
    if (sg_showing == showing) return;
    sg_showing = showing;
    notify_post(showing ? kSGRelayLockShowing : kSGRelayLockNotShowing);
}

static void apply(void) {
    UIView *field = sg_field;
    if (!field.window) {
        tellShowing(NO);
        return;
    }
    UIView *artwork = artworkIn(field);
    // Closed by a tap, the field stays the system's until it is shown again.
    BOOL on = sg_on && (sg_clip || sg_cover) && artwork && !objc_getAssociatedObject(field, &kClosedKey);
    SGVLockClip *clip = objc_getAssociatedObject(field, &kClipKey);
    if (!clip && on) {
        clip = [[SGVLockClip alloc] initWithFrame:field.bounds];
        clip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        clip.alpha = 0;
        objc_setAssociatedObject(field, &kClipKey, clip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (clip) {
        // Over the field and the large cover, so a cover MediaRemoteUI shows for a moment stays under it.
        if (clip.superview != field || field.subviews.lastObject != clip) [field addSubview:clip];
        if (!CGRectEqualToRect(clip.frame, field.bounds)) clip.frame = field.bounds;
    }
    if (on && !objc_getAssociatedObject(field, &kTapKey)) {
        SGVFieldTap *handler = [SGVFieldTap new];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:handler action:@selector(tapped:)];
        tap.delegate = handler;
        tap.cancelsTouchesInView = NO;
        tap.delaysTouchesEnded = NO;
        [field addGestureRecognizer:tap];
        objc_setAssociatedObject(field, &kTapKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    tellShowing(on);
    hideArtwork(artwork, on, YES);
    BOOL shown = clip.alpha > 0.99;
    [UIView animateWithDuration:shown == on ? 0 : kFade delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        clip.alpha = on ? 1 : 0;
    } completion:^(BOOL finished) {
        if (!(sg_on && sg_clip && artworkIn(field)) || objc_getAssociatedObject(field, &kClosedKey)) [clip playClip:nil];
    }];
    if (on) {
        [clip setSuspended:sg_blank];
        [clip showCover:sg_cover];
        [clip playClip:sg_clip];
        [clip setPlaying:sg_playing];
    }
}

// The large cover closing on a tap: the cover back at once, for MediaRemoteUI to shrink it, the clip fading over it.
static void closing(UIView *field) {
    SGVLockClip *clip = objc_getAssociatedObject(field, &kClipKey);
    if (!clip || clip.alpha < 0.01) return;
    objc_setAssociatedObject(field, &kClosedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    hideArtwork(artworkIn(field), NO, NO);
    tellShowing(NO);
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ clip.alpha = 0; } completion:nil];
}

// The shared clip copied into this process's own temporary folder under a new name, so the clip view takes a new file.
static void readShared(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    if (sg_clip) [files removeItemAtURL:sg_clip error:nil];
    sg_clip = nil;
    NSString *shared = SGLockSharedClipPath();
    NSURL *copy = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"vitrine-lockclip-%u.mp4", arc4random()]]];
    NSError *error = nil;
    if ([files copyItemAtURL:[NSURL fileURLWithPath:shared] toURL:copy error:&error]) sg_clip = copy;
    else NSLog(@"[vitrine-addon] MediaRemoteUI cannot read the shared clip: %@", error.localizedDescription);
    apply();
}

// Spotify's still cover from the now playing info, read again as the info changes; another app's is not taken.
static void readCover(void) {
    if (!sg_getInfo || !sg_getApp) return;
    sg_getApp(dispatch_get_main_queue(), ^(CFStringRef bundle) {
        if (![(__bridge NSString *)bundle isEqualToString:@"com.spotify.client"]) {
            BOOL had = sg_cover != nil;
            sg_cover = nil;
            sg_coverData = nil;
            if (had) apply();
            return;
        }
        sg_getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
            NSData *data = [(__bridge NSDictionary *)info objectForKey:@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            if (data == sg_coverData || [data isEqualToData:sg_coverData]) return;
            sg_coverData = data;
            sg_cover = data ? [UIImage imageWithData:data] : nil;
            apply();
        });
    });
}

static void readPlaying(void) {
    if (!sg_isPlaying) return;
    sg_isPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
        sg_playing = playing;
        SGVLockClip *clip = sg_field ? objc_getAssociatedObject(sg_field, &kClipKey) : nil;
        [clip setPlaying:playing];
    });
}

%hook _TtC13MediaRemoteUI24CoverSheetBackgroundView
- (void)didMoveToWindow {
    %orig;
    UIView *field = (UIView *)self;
    if (field.window) {
        sg_field = field;
        objc_setAssociatedObject(field, &kClosedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    apply();
}

- (void)layoutSubviews {
    %orig;
    UIView *field = (UIView *)self;
    sg_field = field;
    // A field closed by a tap and kept, hidden, for the next time: it is the clip's again as it is shown.
    UIWindow *window = field.window;
    if (field.hidden || field.alpha < 0.01 || !window || window.hidden || window.alpha < 0.01)
        objc_setAssociatedObject(field, &kClosedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (sg_on || sg_showing) apply();
}
%end

%group SGVArtwork
%hook MRUArtworkView
- (void)setAlpha:(CGFloat)alpha {
    if (!sg_settingAlpha) objc_setAssociatedObject(self, &kWantedKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(objc_getAssociatedObject(self, &kHiddenKey) ? 0 : alpha);
}
%end
%end

static void listen(const char *name, void (^handler)(void)) {
    int token;
    notify_register_dispatch(name, &token, dispatch_get_main_queue(), ^(int t) { handler(); });
}

%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.MediaRemoteUI"]) return;
    if (@available(iOS 26.0, *)) return;
    if (!objc_getClass("_TtC13MediaRemoteUI24CoverSheetBackgroundView")) {
        NSLog(@"[vitrine-addon] MediaRemoteUI has no CoverSheetBackgroundView, the lock screen's Canvas is off");
        return;
    }
    void *remote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    sg_isPlaying = remote ? (SGMRIsPlaying)dlsym(remote, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") : NULL;
    SGMRRegister registerFor = remote ? (SGMRRegister)dlsym(remote, "MRMediaRemoteRegisterForNowPlayingNotifications") : NULL;
    sg_getInfo = remote ? (SGMRGetInfo)dlsym(remote, "MRMediaRemoteGetNowPlayingInfo") : NULL;
    sg_getApp = remote ? (SGMRGetApp)dlsym(remote, "MRMediaRemoteGetNowPlayingApplicationDisplayID") : NULL;
    %init;
    if (objc_getClass("MRUArtworkView")) %init(SGVArtwork);
    if (registerFor) registerFor(dispatch_get_main_queue());
    [NSNotificationCenter.defaultCenter addObserverForName:@"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification" object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{ readPlaying(); });
    }];
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification", @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{ readCover(); });
        }];
    }
    readPlaying();
    readCover();
    static int blankToken;
    notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &blankToken, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 0;
        notify_get_state(t, &state);
        sg_blank = state != 0;
        SGVLockClip *clip = sg_field ? objc_getAssociatedObject(sg_field, &kClipKey) : nil;
        [clip setSuspended:sg_blank];
    });
    listen(kSGRelayLockArtOn, ^{ sg_on = YES; apply(); });
    listen(kSGRelayLockArtOff, ^{ sg_on = NO; apply(); });
    listen(kSGRelayLockClipShared, ^{ readShared(); });
    listen(kSGRelayLockClipNone, ^{
        if (sg_clip) [NSFileManager.defaultManager removeItemAtURL:sg_clip error:nil];
        sg_clip = nil;
        apply();
    });
    // The switch and the clip as they are now: Spotify answers SpringBoard's pong to this ping with the switch, and a
    // clip already shared is in the shared caches.
    notify_post(kSGRelayPing);
    if ([NSFileManager.defaultManager fileExistsAtPath:SGLockSharedClipPath()]) readShared();
    NSLog(@"[vitrine-addon] MediaRemoteUI ready for the lock screen's Canvas");
}
