// The AutoMix page (App/ModSettings.x links it from the root, under either look): the switch, then the style and
// the blend length, which read Spotify's own settings and gray out while the switch is off.
// It has no restart note: Spotify's player takes a new setting at the next track change.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "AutoMix.h"

// Spotify's own crossfade slider (Settings > Playback) runs from 0, which is off and is the switch here, to 12 s.
static const double kShortest = 1, kLongest = 12;

UIViewController *SGAutoMixSettingsPage(void) {
    SGModRow *toggle = SGOptionRow(@"AutoMix", nil, SGKeyAutoMix);
    toggle.changed = ^(BOOL on) { SGAutoMixApply(on); };

    NSArray<NSString *> *styles = @[@"Beat-matched", @"Crossfade"];
    SGModRow *style = SGMenuRow(@"Style", styles, ^NSString *{ return styles[(NSUInteger)SGAutoMixCurrentStyle()]; },
                                ^(NSInteger index) { SGAutoMixSetStyle(index); });
    style.waitsOn = SGKeyAutoMix;

    SGModRow *blend = SGSliderRow(@"Blend length", nil, kShortest, kLongest, 1,
        ^double {
            return MAX(kShortest, MIN(kLongest, SGAutoMixBaseMilliseconds() / 1000.0));
        },
        ^(double value) { SGAutoMixSetSeconds(lround(value)); },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%ld s", lround(value)]; });
    blend.waitsOn = SGKeyAutoMix;

    // On until switched off: the length above is the longest a blend gets, and each pair of songs is given what it
    // suits (AutoMixPolicy.h).
    SGModRow *adaptive = SGSwitchRow(@"Adapt to each song", @"Shorter for short songs, none between songs that follow each other on an album or for podcasts", SGKeyAutoMixAdaptive);
    adaptive.changed = ^(BOOL on) { SGAutoMixAdaptiveChanged(on); };
    adaptive.waitsOn = SGKeyAutoMix;

    SGModRow *experiment = SGOptionRow(@"Transition experiments", @"Forces Spotify's AutoMix flags on and logs what loads transitions. For testing; restart after changing", SGKeyAutoMixExperiment);

    NSString *note = SGAutoMixAccountAllows() ? nil : @"AutoMix needs Premium, or Spoof Premium under Premium, ads & privacy.";
    return [[SGModPage alloc] initWithTitle:@"AutoMix" intro:nil sections:@[
        SGNotedSection(nil, @[toggle, style, blend, adaptive], note),
        SGNotedSection(@"Testing", @[experiment], nil),
    ] footer:nil];
}
