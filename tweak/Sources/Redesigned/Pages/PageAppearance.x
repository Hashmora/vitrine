// Redesign: every page of Spotify's navigation stacks is dark, whatever the phone is set to.
//
// Spotify is dark in both appearances. Its own -[SPNavigationController viewDidLoad] makes the stack dark only
// while +[SPTLiquidGlass isEnabled] (see Navbar/TabBar.x), which the redesign does not rely on, so on a phone in
// light mode the stack stayed light until the app had been left and entered again: the section headings of
// Listening stats (Top artists, Top songs) were black on black, a title on its glass capsule was black on white
// glass, and Settings, Your Updates and Your Premium did the same (the bar's title "Chapters" is #000000 and its
// capsule white).
//
// So the navigation controller, its view and its bar are given the dark appearance. Every page under them
// inherits it, the bar's glass and its labels included, and no page has to override its own.
//
// The blur Spotify draws behind the bar is kept off here as well (SGRSyncBarBlur): a dressed page took it off only from
// its own first layout pass, which a page whose bar had not been built yet missed, so a tinted header showed for a
// moment on Recents, Listening stats, Your Premium and the rest, and came back when the app was left and entered again.
// It is now settled as a page is pushed or popped, on every pass of the stack and as the app comes to the front.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static NSHashTable<UINavigationController *> *sg_stacks;

static void makeDark(UINavigationController *navigation) {
    if (navigation.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UIView *view = navigation.viewIfLoaded;
    if (view && view.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) view.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UINavigationBar *bar = navigation.navigationBar;
    if (bar.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) bar.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if (!sg_stacks) sg_stacks = [NSHashTable weakObjectsHashTable];
    [sg_stacks addObject:navigation];
    SGRSyncBarBlur(navigation);
}

static void syncAllStacks(void) {
    for (UINavigationController *navigation in sg_stacks.allObjects) SGRSyncBarBlur(navigation);
}

%hook SPNavigationController
- (void)viewDidLoad {
    %orig;
    makeDark((UINavigationController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    makeDark((UINavigationController *)self);
}

// Spotify writes the style itself from its own passes; it is put back wherever it was changed.
- (void)viewDidLayoutSubviews {
    %orig;
    makeDark((UINavigationController *)self);
}

// The top page changes inside these, before anything is drawn.
- (void)pushViewController:(UIViewController *)controller animated:(BOOL)animated {
    %orig;
    SGRSyncBarBlur((UINavigationController *)self);
}

- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    UIViewController *popped = %orig;
    SGRSyncBarBlur((UINavigationController *)self);
    return popped;
}

- (void)setViewControllers:(NSArray<UIViewController *> *)controllers animated:(BOOL)animated {
    %orig;
    SGRSyncBarBlur((UINavigationController *)self);
}
%end

// UIKit builds the bar's buttons and title while laying the content view out, after the bar's own pass: Spotify's
// controls are kept out of sight for a page that wants the redesign's bar from here (SGRSyncBarBlur), and the pages
// dressed from the bar are dressed (SGRObserveBarPasses).
static NSMutableArray<void (^)(UIView *)> *sg_barPasses;
static Class sg_barClass;

void SGRObserveBarPasses(void (^pass)(UIView *bar)) {
    if (!sg_barPasses) sg_barPasses = [NSMutableArray array];
    [sg_barPasses addObject:[pass copy]];
}

static void barLaidOut(UIView *bar) {
    UINavigationController *navigation = SGRNavigationOf(bar);
    if (navigation) SGRSyncBarBlur(navigation);
    if (!SGBelowiOS26()) return;
    for (void (^pass)(UIView *) in sg_barPasses) pass(bar);
}

%hook SPNavigationBar
- (void)layoutSubviews {
    %orig;
    barLaidOut((UIView *)self);
}
%end

%hook _UINavigationBarContentView
- (void)layoutSubviews {
    %orig;
    UIView *bar = ((UIView *)self).superview;
    if (sg_barClass && [bar isKindOfClass:sg_barClass]) barLaidOut(bar);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    sg_barClass = NSClassFromString(@"SPNavigationBar");
    %init;
    SGRequireClasses(@[@"SPNavigationController", @"SPNavigationBar", @"_UINavigationBarContentView"]);
    // Spotify builds its blur again as the app comes back; it is settled at once and once more after its own pass.
    void (^comeback)(NSNotification *) = ^(NSNotification *note) {
        syncAllStacks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            syncAllStacks();
        });
    };
    for (NSNotificationName name in @[UIApplicationWillEnterForegroundNotification, UIApplicationDidBecomeActiveNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:comeback];
    }
}
