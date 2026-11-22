// Retain the public provider blocks when Spotify constructs UIKit deferred menu
// elements. UIKit does not expose the provider on an existing element. The
// renderer calls these original blocks and owns the resulting menu visuals.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "SGRDropdownDeferred.h"

static char kDeferredStateKey;
static const NSTimeInterval kDeferredTimeout = 12;

@interface SGRDropdownDeferredState : NSObject
@property (nonatomic, copy) SGRDropdownDeferredBlock provider;
@property (nonatomic) BOOL cachesResult;
@property (nonatomic) BOOL hasCache;
@property (nonatomic, strong) NSArray<UIMenuElement *> *cachedElements;
@property (nonatomic, strong) NSMutableArray *waiting;
@property (nonatomic) BOOL fetching;
@property (nonatomic) NSUInteger revision;
@end
@implementation SGRDropdownDeferredState
@end

static void capture(UIDeferredMenuElement *element, SGRDropdownDeferredBlock provider, BOOL cache) {
    if (!element || !provider) return;
    SGRDropdownDeferredState *state = [SGRDropdownDeferredState new];
    state.provider = provider;
    state.cachesResult = cache;
    state.waiting = [NSMutableArray array];
    objc_setAssociatedObject(element, &kDeferredStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL supportedElements(NSArray<UIMenuElement *> *elements, NSUInteger depth) {
    if (depth > 16) return NO;
    for (UIMenuElement *element in elements) {
        if ([element isKindOfClass:UIDeferredMenuElement.class]) {
            if (!objc_getAssociatedObject(element, &kDeferredStateKey)) return NO;
        } else if ([element isKindOfClass:UIMenu.class] &&
                   !supportedElements(((UIMenu *)element).children, depth + 1)) {
            return NO;
        }
    }
    return YES;
}

BOOL SGRDropdownDeferredMenuSupported(UIMenu *menu) {
    return menu && supportedElements(menu.children, 0);
}

static NSArray<UIMenuElement *> *safeElements(id elements) {
    if (![elements isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<UIMenuElement *> *safe = [NSMutableArray array];
    for (id element in (NSArray *)elements) {
        if (![element isKindOfClass:UIMenuElement.class]) continue;
        [safe addObject:element];
        if (safe.count >= 256) break;
    }
    return safe;
}

static void complete(SGRDropdownDeferredState *state, NSUInteger revision,
                     NSArray<UIMenuElement *> *result) {
    if (!state.fetching || state.revision != revision) return;
    state.fetching = NO;
    if (state.cachesResult) {
        state.cachedElements = result;
        state.hasCache = YES;
    }
    NSArray *waiting = [state.waiting copy];
    [state.waiting removeAllObjects];
    for (id callback in waiting) {
        SGRDropdownDeferredCompletion completion = callback;
        completion(result);
    }
}

void SGRDropdownDeferredRequest(UIDeferredMenuElement *element, SGRDropdownDeferredCompletion completion) {
    if (!completion) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGRDropdownDeferredRequest(element, completion); });
        return;
    }
    SGRDropdownDeferredState *state = objc_getAssociatedObject(element, &kDeferredStateKey);
    if (!state) { completion(@[]); return; }
    if (state.cachesResult && state.hasCache) {
        completion(state.cachedElements ?: @[]);
        return;
    }
    [state.waiting addObject:[completion copy]];
    if (state.fetching) return;
    state.fetching = YES;
    NSUInteger revision = ++state.revision;

    SGRDropdownDeferredBlock provider = state.provider;
    @try {
        provider(^(NSArray<UIMenuElement *> *elements) {
            // Spotify is allowed to finish asynchronously on another queue.
            // Never mutate an open UIKit view or complete a waiter off main.
            dispatch_async(dispatch_get_main_queue(), ^{
                complete(state, revision, safeElements(elements));
            });
        });
    } @catch (NSException *exception) {
        SGLog(@"dropdown: deferred provider raised %@", exception.name);
        complete(state, revision, @[]);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDeferredTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (state.fetching && state.revision == revision) {
            SGLog(@"dropdown: deferred provider timed out after %.0fs", kDeferredTimeout);
            complete(state, revision, @[]);
        }
    });
}

%hook UIDeferredMenuElement
+ (instancetype)elementWithProvider:(SGRDropdownDeferredBlock)provider {
    UIDeferredMenuElement *element = %orig(provider);
    capture(element, provider, YES);
    return element;
}
+ (instancetype)elementWithUncachedProvider:(SGRDropdownDeferredBlock)provider {
    UIDeferredMenuElement *element = %orig(provider);
    capture(element, provider, NO);
    return element;
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    %init;
}
