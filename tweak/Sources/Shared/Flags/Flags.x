// Spotify reads each feature's remote-config flags once, through the configuration provider, keyed
// "component.property": a few dozen as it starts, the rest when their feature first needs them. The value handed back is Core/SGFlagForce.h's: what the redesign forces
// (Redesigned/Kit/SGRedesign.h), which comes before an override so one left from Spotify's own screens
// cannot pull a redesigned one apart, then an override from the Flags page, then what the ad blocking
// and the lyrics sources force.
#import <mach/mach_time.h>
#import <pthread.h>
#import <stdatomic.h>
#import "Core/SGCore.h"
#import "Flags.h"
#import "Shared/AutoMix/AutoMix.h"

// What the mod's answers cost as Spotify starts, logged once (harness/launch measures it on the Mac).
static _Atomic uint64_t sg_reads, sg_mainReads, sg_ticks;
static const NSTimeInterval kCountFor = 15;

// Playlist mixing (Spotify's custom transitions, the editor, the Mix button) is one remote-config component,
// SPTPlaylistMixing_ConfigurationImplProperties (isEnabled, freeExperienceEnabled, headerMixButtonEnabled,
// trackSwapEnabled, curveEditingEnabled, beatmatchToggleEnabled, ...). The AutoMix flags the probe first named are
// only the DJ ones in it. Every flag Spotify asks of the component is logged once, so the names are the real ones.
static NSString *const kMixingComponent = @"ios-playlistcuration-mats.";

static BOOL isAutoMixProbeFlag(NSString *key) {
    return [key hasPrefix:kMixingComponent];
}

// What the transition experiment (AutoMix > Testing) turns on: the master switch, the free experience, the Mix button
// and the editors, and the DJ and backend transition flags. Not the debug, sharing and messaging ones.
static BOOL isMixingExperimentFlag(NSString *key) {
    static NSArray<NSString *> *wanted;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        wanted = @[@"is_enabled", @"free_experience", @"header_mix_button", @"auto_mix", @"automix", @"backend_auto",
                   @"beatmatch", @"track_swap", @"curve_editing", @"effects_style", @"transition_curation",
                   @"debug_bypass_mixability", @"smart_reorder", @"auto_lens"];
    });
    if (![key hasPrefix:kMixingComponent]) return NO;
    NSString *name = [key substringFromIndex:kMixingComponent.length];
    for (NSString *part in wanted) if ([name containsString:part]) return YES;
    return NO;
}

// Each flag once: Spotify asks for the same ones many times.
static void logMixingFlag(NSString *key, BOOL orig, id value) {
    static NSMutableSet<NSString *> *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    @synchronized (seen) {
        if ([seen containsObject:key]) return;
        [seen addObject:key];
    }
    SGLog(@"automix flag: %@ Spotify %@, handed %@%@", key, orig ? @"on" : @"off",
          value ? ([value boolValue] ? @"on" : @"off") : (orig ? @"on" : @"off"), value ? @" (override/forcer)" : @"");
}

static id forced(NSString *key) {
    uint64_t start = mach_absolute_time();
    id value = SGForcedFlagValue(key);
    atomic_fetch_add_explicit(&sg_ticks, mach_absolute_time() - start, memory_order_relaxed);
    atomic_fetch_add_explicit(&sg_reads, 1, memory_order_relaxed);
    if (pthread_main_np()) atomic_fetch_add_explicit(&sg_mainReads, 1, memory_order_relaxed);
    return value;
}

static BOOL boolFor(NSString *key, BOOL orig) {
    id value = forced(key);
    // The transition experiment (AutoMix > Testing): the mixing flags on unless the Flags page set one itself.
    if (!value && SGAutoMixExperimentOn() && isMixingExperimentFlag(key)) value = @YES;
    if (isAutoMixProbeFlag(key)) logMixingFlag(key, orig, value);
    return value ? [value boolValue] : orig;
}

static long intFor(NSString *key, long lower, long upper, long orig) {
    id value = forced(key);
    return value ? MAX(lower, MIN(upper, (long)[value longLongValue])) : orig;
}

// 9.1.88's switch over the system's own glass (default, force_enabled, force_disabled). Default leaves it to
// Info.plist, where the IPA build turns glass on; a force_disabled from Spotify's servers would take the glass
// off the redesign's bars. Pinned to default in both looks, after an override from the All flags page.
static NSString *const kGlassOverride = @"ios-reprise-liquid-glass-override.mode";

static id enumFor(NSString *key, id orig) {
    id value = forced(key);
    id result = [value isKindOfClass:NSString.class] ? value : orig;
    static atomic_bool toldGlass;
    if ([key isEqualToString:kGlassOverride] && !atomic_exchange(&toldGlass, true)) {
        SGLog(@"flags: Spotify's own %@ is %@, handed %@", kGlassOverride, orig, result);
    }
    return result;
}

%hook _TtC22RemoteConfigurationSDK25ConfigurationProviderImpl
- (BOOL)boolValueForId:(NSString *)key defaultValue:(BOOL)fallback {
    BOOL orig = %orig;
    return boolFor(key, orig);
}
- (long)intValueForId:(NSString *)key lower:(long)lower upper:(long)upper defaultValue:(long)fallback {
    long orig = %orig;
    return intFor(key, lower, upper, orig);
}
- (id)enumValueForId:(NSString *)key values:(NSArray *)values defaultValue:(id)fallback {
    id orig = %orig;
    return enumFor(key, orig);
}
%end

// The observable properties listed in Info.plist go through a second provider.
%hook _TtC22RemoteConfigurationSDK35ObservableConfigurationProviderImpl
- (BOOL)boolValueForId:(NSString *)key defaultValue:(BOOL)fallback {
    BOOL orig = %orig;
    return boolFor(key, orig);
}
- (long)intValueForId:(NSString *)key lower:(long)lower upper:(long)upper defaultValue:(long)fallback {
    long orig = %orig;
    return intFor(key, lower, upper, orig);
}
- (id)enumValueForId:(NSString *)key values:(NSArray *)values defaultValue:(id)fallback {
    id orig = %orig;
    return enumFor(key, orig);
}
%end

%ctor {
    // 9.1.90's switch to a Liquid Glass tab bar of Spotify's own, off by default. Both looks build on the tab bar
    // as it is, so a server turning it on would pull them apart: pinned off.
    SGRegisterFlagForcer(NO, ^id(NSString *key) {
        if ([key isEqualToString:kGlassOverride]) return @"default";
        return [key isEqualToString:@"ios-navigationui-tabbar-impl.is_liquid_glass_tab_bar_enabled"] ? @NO : nil;
    }, nil);
    %init;
    SGRequireClasses(@[
        @"_TtC22RemoteConfigurationSDK25ConfigurationProviderImpl",
        @"_TtC22RemoteConfigurationSDK35ObservableConfigurationProviderImpl",
    ]);
    // Off the main queue, so a main thread held up at launch does not hold the report back with it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCountFor * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        mach_timebase_info_data_t base;
        mach_timebase_info(&base);
        double ms = (double)atomic_load(&sg_ticks) * base.numer / base.denom / 1e6;
        SGLog(@"flags: %llu reads in the first %.0f s, %llu on the main thread, %.1f ms in the mod's answers",
              atomic_load(&sg_reads), kCountFor, atomic_load(&sg_mainReads), ms);
        SGLog(@"flags: %@", SGFlagOverrideReport());
    });
}
