// Vitrine Addon in SpringBoard, the lock screen's Canvas below iOS 26: SpringBoard's share of it. The lock screen's
// player and its large cover are drawn by MediaRemoteUI, which only shows in SpringBoard's lock screen as a scene of its
// own (the cover sheet has neither, MediaRemoteUI has both), so the clip is put in the
// large cover's place there (MediaRemoteUICanvas.x). Here:
//
//   the clip    Spotify's for the song (kSGRelayLockClip), read through the data container of the now playing app and
//               copied to the jailbreak's shared caches (SGLockSharedClipPath), where MediaRemoteUI, sandboxed, can read
//               it; MediaRemoteUI is told by kSGRelayLockClipShared. kSGRelayLockClipNone comes from Spotify to both.
//   the widgets the row under the clock (CSProminentEmptyElementView) hidden while
//               MediaRemoteUI shows the clip (kSGRelayLockShowing), and given back as it stops.
//   the lyrics  Spotify's lines for the song (kSGRelayLockLyrics), shared the same way (SGLockSharedLyricsPath,
//               kSGRelayLockLyricsShared); and the choice between them and the Canvas that MediaRemoteUI's button makes,
//               kept in the add-on's own preferences for the next song and the next boot, and told MediaRemoteUI again
//               as it asks (kSGRelayLockModeAsk) and as SpringBoard starts.
//
// Nothing is walked or hooked on the lock screen's layout: the widgets' row is looked for only as it is to be hidden.
//
// Threading: the notifications and MediaRemote's answers come on the main queue.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <notify.h>
#import "../../tweak/Sources/Shared/Haptics/SGHapticRelay.h"

@interface CSCoverSheetViewController : UIViewController
@end

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSURL *dataContainerURL;
@end

typedef void (*SGMRGetApp)(dispatch_queue_t queue, void (^handler)(CFStringRef bundle));

static const NSTimeInterval kFade = 0.35;

static SGMRGetApp sg_getApp;
static __weak UIView *sg_sheet;   // the cover sheet's view
static NSHashTable<UIView *> *sg_hidden;

// The widgets' row under the clock, wherever the cover sheet keeps it.
static void collectRows(UIView *root, NSMutableArray<UIView *> *rows, int depth) {
    if (depth > 30) return;
    for (UIView *sub in root.subviews) {
        if ([NSStringFromClass(sub.class) isEqualToString:@"CSProminentEmptyElementView"]) {
            [rows addObject:sub];
            continue;
        }
        collectRows(sub, rows, depth + 1);
    }
}

static void hideWidgets(BOOL away) {
    if (!sg_hidden) sg_hidden = [NSHashTable weakObjectsHashTable];
    NSArray<UIView *> *views = sg_hidden.allObjects;
    if (away) {
        NSMutableArray<UIView *> *rows = [NSMutableArray array];
        if (sg_sheet) collectRows(sg_sheet, rows, 0);
        for (UIView *row in rows) [sg_hidden addObject:row];
        views = rows;
    } else {
        [sg_hidden removeAllObjects];
    }
    for (UIView *view in views) {
        [UIView animateWithDuration:kFade delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ view.alpha = away ? 0 : 1; } completion:nil];
    }
}

// A file of the now playing app's caches into the jailbreak's shared caches, for MediaRemoteUI: copied beside it and
// moved over the last one, so a reader of the last one keeps its own file; `shared` posted once it is there.
static void share(NSString *name, NSString *sharedPath, const char *shared) {
    if (!sg_getApp) return;
    sg_getApp(dispatch_get_main_queue(), ^(CFStringRef bundle) {
        NSString *identifier = (__bridge NSString *)bundle;
        Class proxies = NSClassFromString(@"LSApplicationProxy");
        NSURL *container = identifier.length && proxies ? [[proxies applicationProxyForIdentifier:identifier] dataContainerURL] : nil;
        NSURL *source = [container URLByAppendingPathComponent:[@"Library/Caches/" stringByAppendingString:name]];
        NSFileManager *files = NSFileManager.defaultManager;
        if (!source || ![files fileExistsAtPath:source.path]) {
            NSLog(@"[vitrine-addon] no %@ in %@", name, identifier);
            return;
        }
        NSURL *target = [NSURL fileURLWithPath:sharedPath];
        [files createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *staging = [target URLByAppendingPathExtension:@"part"];
        [files removeItemAtURL:staging error:nil];
        NSError *error = nil;
        BOOL done = [files copyItemAtURL:source toURL:staging error:&error];
        if (done) {
            [files removeItemAtURL:target error:nil];
            done = [files moveItemAtURL:staging toURL:target error:&error];
        }
        if (!done) {
            NSLog(@"[vitrine-addon] %@ not shared: %@", name, error.localizedDescription);
            return;
        }
        notify_post(shared);
    });
}

static NSString *const kLyricsPickedKey = @"lockLyricsPicked";

static NSUserDefaults *addonDefaults(void) {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.vitrine.addon"]; });
    return defaults;
}

static void tellPicked(void) {
    notify_post([addonDefaults() boolForKey:kLyricsPickedKey] ? kSGRelayLockModeLyrics : kSGRelayLockModeCanvas);
}

%hook CSCoverSheetViewController
- (void)viewDidLoad {
    %orig;
    sg_sheet = ((UIViewController *)self).view;
}
%end

%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    if (@available(iOS 26.0, *)) return;
    void *remote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    sg_getApp = remote ? (SGMRGetApp)dlsym(remote, "MRMediaRemoteGetNowPlayingApplicationDisplayID") : NULL;
    %init;
    int clipToken, noneToken, showingToken, hiddenToken;
    notify_register_dispatch(kSGRelayLockClip, &clipToken, dispatch_get_main_queue(), ^(int t) {
        share(@kSGLockClipName, SGLockSharedClipPath(), kSGRelayLockClipShared);
    });
    int lyricsToken, lyricsPickedToken, canvasPickedToken, askToken;
    notify_register_dispatch(kSGRelayLockLyrics, &lyricsToken, dispatch_get_main_queue(), ^(int t) {
        share(@kSGLockLyricsName, SGLockSharedLyricsPath(), kSGRelayLockLyricsShared);
    });
    // The button's choice kept; a post of it here answers MediaRemoteUI, which hears its own the same way.
    notify_register_dispatch(kSGRelayLockModeLyrics, &lyricsPickedToken, dispatch_get_main_queue(), ^(int t) {
        [addonDefaults() setBool:YES forKey:kLyricsPickedKey];
    });
    notify_register_dispatch(kSGRelayLockModeCanvas, &canvasPickedToken, dispatch_get_main_queue(), ^(int t) {
        [addonDefaults() setBool:NO forKey:kLyricsPickedKey];
    });
    notify_register_dispatch(kSGRelayLockModeAsk, &askToken, dispatch_get_main_queue(), ^(int t) { tellPicked(); });
    tellPicked();
    notify_register_dispatch(kSGRelayLockClipNone, &noneToken, dispatch_get_main_queue(), ^(int t) {
        [NSFileManager.defaultManager removeItemAtPath:SGLockSharedClipPath() error:nil];
    });
    notify_register_dispatch(kSGRelayLockShowing, &showingToken, dispatch_get_main_queue(), ^(int t) { hideWidgets(YES); });
    notify_register_dispatch(kSGRelayLockNotShowing, &hiddenToken, dispatch_get_main_queue(), ^(int t) { hideWidgets(NO); });
}
