// The redesign's AMOLED background, always on: its copy of Native/Appearance/Amoled.x without the switch.
// AMOLED background: Spotify paints its base surface #121212; with the switch on, that gray and
// the gradients fading into it go pure black. Lighter grays stay (#1F1F1F placeholders, #292929
// cards), so elevated surfaces still read against the black.
//
// Trees: #121212 sits on the Home, Search, Library and settings scroll views, on list rows, the
// message bar and the player's bottom gradient view.
#import "Core/SGCore.h"

// Neutral and darker than #1A1A1A, but not already black.
static BOOL isBaseGrey(CGColorRef color) {
    if (!color || CFGetTypeID(color) != CGColorGetTypeID()) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    size_t n = CGColorGetNumberOfComponents(color);
    if (n == 2) return c[0] > 0.01 && c[0] <= 0.10;
    if (n < 3) return NO;
    return c[0] > 0.01 && c[0] <= 0.10 && fabs(c[0] - c[1]) < 0.02 && fabs(c[1] - c[2]) < 0.02;
}

// Layers get set from background threads too, so no autoreleased UIColor here.
static CGColorRef copyBlack(CGColorRef color) {
    return CGColorCreateGenericGray(0, CGColorGetAlpha(color));
}

%hook CALayer
- (void)setBackgroundColor:(CGColorRef)color {
    if (!isBaseGrey(color)) {
        %orig;
        return;
    }
    CGColorRef black = copyBlack(color);
    %orig(black);
    CGColorRelease(black);
}
%end

%hook CAGradientLayer
- (void)setColors:(NSArray *)colors {
    NSMutableArray *mapped = [[NSMutableArray alloc] initWithCapacity:colors.count];
    for (id entry in colors) {
        CGColorRef color = (__bridge CGColorRef)entry;
        if (!isBaseGrey(color)) {
            [mapped addObject:entry];
            continue;
        }
        CGColorRef black = copyBlack(color);
        [mapped addObject:(__bridge id)black];
        CGColorRelease(black);
    }
    %orig(colors ? mapped : nil);
}
%end

// Spotify's settings list paints nothing of its own and shows whatever sits under it, which is not
// the base gray the hooks above turn black. The list is the top surface, so it takes the black.
%hook _TtC21Settings_PlatformImpl26SettingsListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    for (UIView *sub in ((UIViewController *)self).view.subviews) {
        if ([sub isKindOfClass:UICollectionView.class]) sub.backgroundColor = UIColor.blackColor;
    }
}
%end

// The splash screen (trees/continuous/1.txt): ContainerUI_RootUIInternalImpl.LaunchViewController holds a plain view
// (#000000 there) with the logo. Its fill is whatever Spotify gives it, which is not always the base grey the hooks above turn
// black (the system's background in light mode, a dynamic colour), so the AMOLED black is put on the view and the window
// under it every time it loads, appears or lays out, never left to those hooks.
// A Swift class by its module and name: the mangled name the runtime registers, else the dotted one.
static Class swiftClass(NSString *module, NSString *name) {
    NSString *mangled = [NSString stringWithFormat:@"_TtC%lu%@%lu%@", (unsigned long)module.length, module, (unsigned long)name.length, name];
    return NSClassFromString(mangled) ?: NSClassFromString([NSString stringWithFormat:@"%@.%@", module, name]);
}

static void blackenSplash(UIViewController *launch) {
    UIView *view = launch.viewIfLoaded;
    if (!view) return;
    UIColor *black = UIColor.blackColor;
    if (![view.backgroundColor isEqual:black]) view.backgroundColor = black;
    if (view.window && ![view.window.backgroundColor isEqual:black]) view.window.backgroundColor = black;
}

%group SGRSplashBlack
%hook SGRLaunchController
- (void)viewDidLoad {
    %orig;
    blackenSplash((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    blackenSplash((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    blackenSplash((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    blackenSplash((UIViewController *)self);
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    Class launch = swiftClass(@"ContainerUI_RootUIInternalImpl", @"LaunchViewController");
    if (launch) {
        %init(SGRSplashBlack, SGRLaunchController = launch);
    } else {
        SGLog(@"class ContainerUI_RootUIInternalImpl.LaunchViewController not found, the splash screen keeps Spotify's fill");
    }
}
