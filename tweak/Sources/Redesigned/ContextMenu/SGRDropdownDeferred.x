// Retain the public provider blocks when Spotify constructs UIKit deferred menu
// elements. UIKit does not expose the provider on an existing element. The
// renderer calls these original blocks and owns the resulting menu visuals.
#import <objc/runtime.h>
#import <objc/message.h>
#import "Core/SGCore.h"
#import "SGRDropdownDeferred.h"

static char kDeferredStateKey, kResponderProviderBlockKey;
static const NSTimeInterval kDeferredTimeout = 12;

@interface SGRDropdownDeferredState : NSObject
@property (nonatomic, copy) SGRDropdownDeferredBlock provider;
@property (nonatomic) BOOL cachesResult;
@property (nonatomic) BOOL responderBased;
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

// UIKit's focus-based deferred path asks the active responder chain for a
// Provider. The public factory's block is retained by our creation hook.
static SGRDropdownDeferredBlock providerInChain(UIDeferredMenuElement *element, UIResponder *start) {
    SEL selector = NSSelectorFromString(@"providerForDeferredMenuElement:");
    NSUInteger depth = 0;
    for (UIResponder *responder = start; responder && depth++ < 64; responder = responder.nextResponder) {
        if (![responder respondsToSelector:selector]) continue;
        @try {
            id provider = ((id (*)(id, SEL, id))objc_msgSend)(responder, selector, element);
            SGRDropdownDeferredBlock block = objc_getAssociatedObject(provider, &kResponderProviderBlockKey);
            if (block) return block;
        } @catch (NSException *exception) {
            SGLog(@"dropdown: responder provider raised %@", exception.name);
        }
    }
    return nil;
}

static SGRDropdownDeferredBlock responderProvider(UIDeferredMenuElement *element, UIResponder *anchor) {
    if (!element || !anchor) return nil;
    // A focus-based element belongs to the currently focused responder, which
    // need not be a parent of the tapped button. Search that chain first.
    Class cls = NSClassFromString(@"UIFocusSystem");
    SEL getSystem = NSSelectorFromString(@"focusSystemForEnvironment:");
    SEL getFocusedItem = NSSelectorFromString(@"focusedItem");
    if (cls && [cls respondsToSelector:getSystem]) {
        @try {
            id system = ((id (*)(id, SEL, id))objc_msgSend)(cls, getSystem, anchor);
            if ([system respondsToSelector:getFocusedItem]) {
                id focused = ((id (*)(id, SEL))objc_msgSend)(system, getFocusedItem);
                if ([focused isKindOfClass:UIResponder.class]) {
                    SGRDropdownDeferredBlock block = providerInChain(element, focused);
                    if (block) return block;
                }
            }
        } @catch (NSException *exception) {
            SGLog(@"dropdown: focus lookup raised %@", exception.name);
        }
    }
    return providerInChain(element, anchor);
}

static void captureResponderElement(UIDeferredMenuElement *element, BOOL cache) {
    if (!element) return;
    SGRDropdownDeferredState *state = [SGRDropdownDeferredState new];
    state.responderBased = YES;
    state.cachesResult = cache;
    state.waiting = [NSMutableArray array];
    objc_setAssociatedObject(element, &kDeferredStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL supportedElements(NSArray<UIMenuElement *> *elements, UIResponder *anchor, NSUInteger depth) {
    if (depth > 16) return NO;
    for (UIMenuElement *element in elements) {
        if ([element isKindOfClass:UIDeferredMenuElement.class]) {
            SGRDropdownDeferredState *state = objc_getAssociatedObject(element, &kDeferredStateKey);
            // A focus element may predate injection. Recover it through the
            // public responder callback when possible; never guess its block.
            if (!state && responderProvider((UIDeferredMenuElement *)element, anchor)) {
                captureResponderElement((UIDeferredMenuElement *)element, NO);
                state = objc_getAssociatedObject(element, &kDeferredStateKey);
            }
            if (!state || (state.responderBased && !responderProvider((UIDeferredMenuElement *)element, anchor))) return NO;
        } else if ([element isKindOfClass:UIMenu.class] &&
                   !supportedElements(((UIMenu *)element).children, anchor, depth + 1)) {
            return NO;
        }
    }
    return YES;
}

BOOL SGRDropdownDeferredMenuSupported(UIMenu *menu, UIResponder *anchor) {
    return menu && supportedElements(menu.children, anchor, 0);
}

static NSArray<UIMenuElement *> *safeElements(id elements) {
    if (![elements isKindOfClass:NSArray.class]) return nil;
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
    // A timeout or malformed response is not a cached empty menu. Let the
    // next presentation retry the provider rather than permanently lose it.
    if (state.cachesResult && result) {
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

void SGRDropdownDeferredRequest(UIDeferredMenuElement *element, UIResponder *anchor,
                                SGRDropdownDeferredCompletion completion) {
    if (!completion) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGRDropdownDeferredRequest(element, anchor, completion); });
        return;
    }
    SGRDropdownDeferredState *state = objc_getAssociatedObject(element, &kDeferredStateKey);
    if (!state) { completion(nil); return; }
    if (state.cachesResult && state.hasCache) {
        completion(state.cachedElements ?: @[]);
        return;
    }
    [state.waiting addObject:[completion copy]];
    if (state.fetching) return;
    state.fetching = YES;
    NSUInteger revision = ++state.revision;

    // Resolve the provider again for each new request: an uncached focus element
    // must follow the active responder rather than a prior menu's source.
    SGRDropdownDeferredBlock provider = state.responderBased
        ? responderProvider(element, anchor) : state.provider;
    if (!provider) {
        complete(state, revision, nil);
        return;
    }
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
        complete(state, revision, nil);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDeferredTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (state.fetching && state.revision == revision) {
            SGLog(@"dropdown: deferred provider timed out after %.0fs", kDeferredTimeout);
            complete(state, revision, nil);
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

// Focus-based elements and their providers were added in iOS 26. The Legacy
// runtime does not expose these factories; block-based sources still work.
%group SGRDropdownResponderProviders
%hook UIDeferredMenuElement
+ (instancetype)elementUsingFocusWithIdentifier:(id)identifier shouldCacheItems:(BOOL)cache {
    UIDeferredMenuElement *element = %orig(identifier, cache);
    captureResponderElement(element, cache);
    return element;
}
%end
%end

// Do not name UIDeferredMenuElementProvider as a compile-time type here.
// The class was introduced in iOS 26, while Vitrine targets iOS 16. Logos
// otherwise emits unguarded references in its generated C functions even
// though the hook group is only initialized at runtime on iOS 26.
static IMP sgrDropdownOriginalResponderFactory;

static id sgrDropdownCapturedResponderFactory(id cls, SEL command, SGRDropdownDeferredBlock block) {
    if (!sgrDropdownOriginalResponderFactory) return nil;
    id provider = ((id (*)(id, SEL, SGRDropdownDeferredBlock))sgrDropdownOriginalResponderFactory)
        (cls, command, block);
    if (provider && block)
        objc_setAssociatedObject(provider, &kResponderProviderBlockKey, [block copy],
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    return provider;
}

static void sgrDropdownHookResponderFactory(Class providerClass) {
    SEL selector = NSSelectorFromString(@"providerWithElementProvider:");
    Method factory = class_getClassMethod(providerClass, selector);
    if (!factory || sgrDropdownOriginalResponderFactory) return;
    sgrDropdownOriginalResponderFactory =
        method_setImplementation(factory, (IMP)sgrDropdownCapturedResponderFactory);
}

%ctor {
    if (!SGRedesignedUI()) return;
    if (SGBelowiOS26()) %init;
    Class providerClass = NSClassFromString(@"UIDeferredMenuElementProvider");
    if (providerClass &&
        [UIDeferredMenuElement respondsToSelector:NSSelectorFromString(@"elementUsingFocusWithIdentifier:shouldCacheItems:")] &&
        [providerClass respondsToSelector:NSSelectorFromString(@"providerWithElementProvider:")]) {
        sgrDropdownHookResponderFactory(providerClass);
        %init(SGRDropdownResponderProviders);
    }
}
