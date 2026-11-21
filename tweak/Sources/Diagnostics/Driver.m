// The phone driver: commands on the tree server (Diagnostics.x) that work the app the way a finger
// would, so an agent on the Mac can test a FLEX build without anyone touching the phone.
// scripts/phone.py is its client; docs/tweaks.md (Diagnostics) lists the commands.
//
// Debug only: compiled with SG_DRIVER alone (tweak/Makefile; scripts/pipeline.sh sets it for builds that
// carry FLEX, never for make release or the release workflow's .deb), and reached only through the tree
// server, which starts only when FLEX is in the app and listens on 127.0.0.1, never on Wi-Fi.
//
// Threading: a command runs on the server's thread. What reads or touches UIKit goes to main through
// SGRunOnMain (dispatch_async and a semaphore with a timeout, never waited on from main), and the pauses
// between the phases of a touch are slept on the server's thread, so main runs freely between them.
//
// Touches are made the way harness/tabbar/touch.m makes them: a UITouch in the app's touches event,
// carrying the IOHIDEvent UIKit's gesture recognizers read, sent through -[UIApplication sendEvent:].
// Controls get their control events, recognizers recognize, and a button whose menu is its primary action
// opens it on the touch down, as with a finger. The IOHIDEvent functions are looked up at run time, so the
// dylib links nothing new.
//
// Views are addressed the way the tree (GET /tree) prints them: id= (accessibilityIdentifier), a11y=
// (accessibilityLabel), the quoted text of a label, or the class name with an index counting that
// class's views in the tree's order, windows included.
#if SG_DRIVER
#import "Core/SGCore.h"
#import "Diagnostics.h"
#import "Headers/SPTPlayer.h"
// Driver stays independent of feature layers (check-layers.sh). These are
// diagnostic calls into the linked feature code, not imported headers.
extern BOOL SGRLegacyTabBarOn(void);
extern BOOL SGRTabBarMinimized(void);
extern BOOL SGRLegacyNowPlayingHeld(void);
extern void SGRSetTabBarMinimized(BOOL minimized, BOOL animated);
extern CGRect SGRTabBarInlineSlot(UIView *host, CGFloat height);
extern CGRect SGRNowPlayingCardFrameIn(UIView *host, CGFloat *radius);
extern CGRect SGRNowPlayingArtworkFrameIn(UIView *host);
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>

extern void SGRRefreshTabBar(void); // diagnostic-only re-layout after preference changes
// Read-only exports from the relevant feature implementation. Never import
// feature headers here: Driver is at the diagnostics layer.
extern NSDictionary *SGRDiagnosticsBarTransition(void);
extern NSDictionary *SGRDiagnosticsPlayerMorph(void);


static const NSTimeInterval kMainTimeout = 5;

// A command that cannot go on throws, and SGDriverRun answers with the reason.
static void fail(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2) __attribute__((noreturn));
static void fail(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *reason = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    @throw [NSException exceptionWithName:@"SGDriver" reason:reason userInfo:nil];
}

// Runs `block` on main and hands back what it returned; an exception inside comes back out here.
static id onMain(id (^block)(void)) {
    __block id result = nil;
    __block NSException *raised = nil;
    BOOL answered = SGRunOnMain(kMainTimeout, ^{
        @try {
            result = block();
        } @catch (NSException *exception) {
            raised = exception;
        }
    });
    if (!answered) fail(@"the main thread did not answer in %.0f s", kMainTimeout);
    if (raised) @throw raised;
    return result;
}

static void pause_(NSTimeInterval seconds) {
    if (seconds > 0) usleep((useconds_t)(seconds * 1e6));
}

#pragma mark - touches

@interface UITouch (SGDriver)
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)setPhase:(UITouchPhase)phase;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)setTapCount:(NSUInteger)count;
- (void)_setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)reset;
- (void)_setIsFirstTouchForView:(BOOL)first;
- (void)_setHidEvent:(void *)event;
- (void)setGestureView:(UIView *)view;
@end

@interface UIEvent (SGDriver)
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
- (void)_setHIDEvent:(void *)event;
@end

@interface UIApplication (SGDriver)
- (UIEvent *)_touchesEvent;
@end

typedef void *IOHIDEventRef;
static IOHIDEventRef (*sg_createDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double, double,
                                           double, double, Boolean, Boolean, uint32_t);
static IOHIDEventRef (*sg_createFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, double,
                                        double, double, double, double, Boolean, Boolean, uint32_t);
static void (*sg_appendEvent)(IOHIDEventRef, IOHIDEventRef, uint32_t);
static void (*sg_setInteger)(IOHIDEventRef, uint32_t, long);

static void requireTouches(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_createDigitizer = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        sg_createFinger = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEventWithQuality");
        sg_appendEvent = dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        sg_setInteger = dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
    });
    if (!sg_createDigitizer || !sg_createFinger || !sg_appendEvent || !sg_setInteger) fail(@"IOHIDEvent functions not found, touches cannot be made");
    if (![UIApplication.sharedApplication respondsToSelector:@selector(_touchesEvent)] || ![UITouch instancesRespondToSelector:@selector(_setHidEvent:)]) {
        fail(@"UIKit's private touch setters are missing on this iOS");
    }
}

static const uint32_t kDigitizer = 11, kHand = 3, kRange = 1 << 0, kTouch = 1 << 1, kPosition = 1 << 2;
static const uint32_t kDisplayIntegrated = (kDigitizer << 16) + 25;

static IOHIDEventRef hidFor(UITouch *touch) {
    uint64_t now = mach_absolute_time();
    IOHIDEventRef hand = sg_createDigitizer(kCFAllocatorDefault, now, kHand, 0, 0, kTouch, 0, 0, 0, 0, 0, 0, 0, 1, 0);
    sg_setInteger(hand, kDisplayIntegrated, 1);
    BOOL moved = touch.phase == UITouchPhaseMoved, down = touch.phase != UITouchPhaseEnded;
    CGPoint at = [touch locationInView:touch.window];
    IOHIDEventRef finger = sg_createFinger(kCFAllocatorDefault, now, 1, 2, moved ? kPosition : kRange | kTouch, at.x, at.y, 0, 0, 0, 5, 5, 1, 1, 1,
                                           down, down, 0);
    sg_setInteger(finger, kDisplayIntegrated, 1);
    sg_appendEvent(hand, finger, 0);
    CFRelease(finger);
    return hand;
}

static void deliver(UITouch *touch) {
    IOHIDEventRef hid = hidFor(touch);
    [touch _setHidEvent:hid];
    UIEvent *event = [UIApplication.sharedApplication _touchesEvent];
    [event _clearTouches];
    [event _setHIDEvent:hid];
    [event _addTouch:touch forDelayedDelivery:NO];
    CFRelease(hid);
    [UIApplication.sharedApplication sendEvent:event];
}

static NSArray<UIWindow *> *windows(void);

// The window a finger at `screen` lands in: the highest one that takes a touch there.
static UIWindow *windowAt(CGPoint screen) {
    // Highest level first, and of one level the later window, which is the one in front.
    NSArray<UIWindow *> *all = [windows().reverseObjectEnumerator.allObjects sortedArrayWithOptions:NSSortStable
                                                                                    usingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        return a.windowLevel > b.windowLevel ? NSOrderedAscending : a.windowLevel < b.windowLevel ? NSOrderedDescending : NSOrderedSame;
    }];
    for (UIWindow *window in all) {
        if ([window hitTest:[window convertPoint:screen fromWindow:nil] withEvent:nil]) return window;
    }
    return nil;
}

static NSArray *pair(CGPoint p) {
    return @[@(round(p.x * 10) / 10), @(round(p.y * 10) / 10)];
}

// A finger down at `from`, moved to `to` over `duration` s at 60 Hz, held still `hold` s, lifted at `to`.
// With no hold the last move is the lift, so a quick one flings.
static NSDictionary *finger(CGPoint from, CGPoint to, NSTimeInterval duration, NSTimeInterval hold) {
    requireTouches();
    __block UITouch *touch = nil;
    NSDictionary *down = onMain(^id {
        UIWindow *window = windowAt(from);
        if (!window) fail(@"no window takes a touch at {%.0f, %.0f}", from.x, from.y);
        CGPoint at = [window convertPoint:from fromWindow:nil];
        UIView *view = [window hitTest:at withEvent:nil];
        touch = [UITouch new];
        [touch setWindow:window];
        [touch _setLocationInWindow:at resetPrevious:YES];
        [touch setView:view];
        if ([touch respondsToSelector:@selector(setGestureView:)]) [touch setGestureView:view];
        [touch setPhase:UITouchPhaseBegan];
        [touch _setIsFirstTouchForView:YES];
        [touch setTapCount:1];
        [touch setTimestamp:NSProcessInfo.processInfo.systemUptime];
        deliver(touch);
        return @{@"window" : NSStringFromClass(window.class), @"hit" : NSStringFromClass(view.class) ?: @"nil"};
    });
    void (^move)(CGPoint, UITouchPhase) = ^(CGPoint point, UITouchPhase phase) {
        onMain(^id {
            [touch setTimestamp:NSProcessInfo.processInfo.systemUptime];
            [touch _setLocationInWindow:[touch.window convertPoint:point fromWindow:nil] resetPrevious:NO];
            [touch setPhase:phase];
            deliver(touch);
            return nil;
        });
    };
    @try {
        NSUInteger steps = duration > 0 ? MAX(2, (NSUInteger)(duration * 60)) : 0;
        for (NSUInteger i = 1; i <= steps; i++) {
            pause_(1.0 / 60);
            CGFloat t = (CGFloat)i / steps;
            CGPoint at = CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
            if (i == steps && hold <= 0) {
                move(at, UITouchPhaseEnded);
                return down;
            }
            move(at, UITouchPhaseMoved);
        }
        pause_(hold);
        move(to, UITouchPhaseEnded);
    } @catch (NSException *exception) {
        // A finger left down would hold every later touch; lift it whatever happened.
        dispatch_async(dispatch_get_main_queue(), ^{
            [touch setPhase:UITouchPhaseCancelled];
            deliver(touch);
        });
        @throw exception;
    }
    return down;
}


// A single unbroken touch: move upward, reverse direction, return to the
// mini-player's starting point, optionally hold, and release. Unlike two
// `swipe`s, this preserves the original UITouch and pan recognizer state.
static NSDictionary *fingerReverse(CGPoint from, CGPoint via, CGPoint to,
                                   NSTimeInterval upSeconds, NSTimeInterval backSeconds,
                                   NSTimeInterval holdSeconds) {
    if (upSeconds < 0.1 || backSeconds < 0.1 || upSeconds > 5 || backSeconds > 5 ||
        holdSeconds < 0 || holdSeconds > 8) {
        fail(@"invalid reverse gesture durations");
    }
    requireTouches();
    __block UITouch *touch = nil;
    NSDictionary *down = onMain(^id {
        UIWindow *window = windowAt(from);
        if (!window) fail(@"no window takes a touch at {%.0f, %.0f}", from.x, from.y);
        CGPoint at = [window convertPoint:from fromWindow:nil];
        UIView *view = [window hitTest:at withEvent:nil];
        touch = [UITouch new];
        [touch setWindow:window];
        [touch _setLocationInWindow:at resetPrevious:YES];
        [touch setView:view];
        if ([touch respondsToSelector:@selector(setGestureView:)]) [touch setGestureView:view];
        [touch setPhase:UITouchPhaseBegan];
        [touch _setIsFirstTouchForView:YES];
        [touch setTapCount:1];
        [touch setTimestamp:NSProcessInfo.processInfo.systemUptime];
        deliver(touch);
        return @{ @"window": NSStringFromClass(window.class),
                  @"hit": NSStringFromClass(view.class) ?: @"nil" };
    });
    void (^move)(CGPoint, UITouchPhase) = ^(CGPoint point, UITouchPhase phase) {
        onMain(^id {
            [touch setTimestamp:NSProcessInfo.processInfo.systemUptime];
            [touch _setLocationInWindow:[touch.window convertPoint:point fromWindow:nil] resetPrevious:NO];
            [touch setPhase:phase];
            deliver(touch);
            return nil;
        });
    };
    @try {
        NSArray<NSValue *> *destinations = @[[NSValue valueWithCGPoint:via], [NSValue valueWithCGPoint:to]];
        NSArray<NSNumber *> *durations = @[@(upSeconds), @(backSeconds)];
        CGPoint origin = from;
        for (NSUInteger leg = 0; leg < destinations.count; leg++) {
            CGPoint destination = destinations[leg].CGPointValue;
            NSTimeInterval duration = durations[leg].doubleValue;
            NSUInteger steps = MAX(2, (NSUInteger)round(duration * 60));
            for (NSUInteger i = 1; i <= steps; i++) {
                pause_(duration / (NSTimeInterval)steps);
                CGFloat fraction = (CGFloat)i / (CGFloat)steps;
                CGPoint point = CGPointMake(origin.x + (destination.x - origin.x) * fraction,
                                            origin.y + (destination.y - origin.y) * fraction);
                if (leg == 1 && i == steps && holdSeconds == 0) {
                    move(point, UITouchPhaseEnded);
                    return down;
                }
                move(point, UITouchPhaseMoved);
            }
            origin = destination;
        }
        if (holdSeconds > 0) pause_(holdSeconds);
        move(to, UITouchPhaseEnded);
    } @catch (NSException *exception) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [touch setPhase:UITouchPhaseCancelled];
            deliver(touch);
        });
        @throw exception;
    }
    return down;
}

#pragma mark - finding views

static NSArray<UIWindow *> *windows(void) {
    NSMutableArray<UIWindow *> *all = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || [NSStringFromClass(window.class) containsString:@"FLEX"]) continue;
            [all addObject:window];
        }
    }
    return all;
}

static UIWindow *keyWindow(void) {
    for (UIWindow *window in windows()) {
        if (window.isKeyWindow) return window;
    }
    return windows().firstObject;
}

static NSString *textOf(UIView *view) {
    if ([view isKindOfClass:UIButton.class]) return ((UIButton *)view).currentTitle;
    if (![view respondsToSelector:@selector(text)] || [view methodSignatureForSelector:@selector(text)].methodReturnType[0] != '@') return nil;
    id text = ((id (*)(id, SEL))objc_msgSend)(view, @selector(text));
    return [text isKindOfClass:NSString.class] ? text : nil;
}

static BOOL isShown(UIView *view) {
    if (!view.window) return NO;
    for (UIView *v = view; v; v = v.superview) {
        if (v.hidden || v.alpha < 0.01) return NO;
    }
    CGRect frame = [view convertRect:view.bounds toView:nil];
    return frame.size.width > 0 && frame.size.height > 0 && CGRectIntersectsRect(frame, view.window.bounds);
}

static CGRect screenFrame(UIView *view) {
    return [view.window convertRect:[view convertRect:view.bounds toView:nil] toWindow:nil];
}

static CGPoint screenCenter(UIView *view) {
    CGRect frame = screenFrame(view);
    return CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
}

static BOOL same(NSString *a, NSString *b, BOOL contains) {
    if (!a || !b) return NO;
    a = [a stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (contains) return [a rangeOfString:b options:NSCaseInsensitiveSearch].location != NSNotFound;
    return [a caseInsensitiveCompare:b] == NSOrderedSame;
}

static BOOL hasSelector(NSDictionary *p) {
    return p[@"id"] || p[@"label"] || p[@"text"] || p[@"class"];
}

static BOOL matches(UIView *view, NSDictionary *p) {
    BOOL contains = p[@"contains"] != nil;
    if (p[@"class"] && ![NSStringFromClass(view.class) isEqualToString:p[@"class"]]) return NO;
    if (p[@"id"] && ![view.accessibilityIdentifier isEqualToString:p[@"id"]]) return NO;
    if (p[@"label"] && !same(view.accessibilityLabel, p[@"label"], contains)) return NO;
    if (p[@"text"] && !same(textOf(view), p[@"text"], contains)) return NO;
    return YES;
}

static UIViewController *topController(NSMutableArray<NSString *> *path, NSMutableArray<NSString *> *presented);

// The view of the page in front: a sheet over the player, Mod Settings over Home.
static UIView *frontView(void) {
    return topController([NSMutableArray array], [NSMutableArray array]).viewIfLoaded;
}

// Every view the selector matches, the page in front's first, then the tree's order: a sheet's rows come after
// the page under it in the windows, and a search capped at 100 would end on that page.
static NSArray<UIView *> *findAll(NSDictionary *p, UIView *root) {
    NSMutableArray<UIView *> *found = [NSMutableArray array];
    for (UIView *top in root ? @[root] : windows()) {
        SGForEachView(top, ^(UIView *view) {
            if (matches(view, p)) [found addObject:view];
        });
    }
    UIView *front = root ? nil : frontView();
    if (!front) return found;
    NSIndexSet *inFront = [found indexesOfObjectsPassingTest:^BOOL(UIView *view, NSUInteger i, BOOL *stop) { return [view isDescendantOfView:front]; }];
    NSMutableArray<UIView *> *ordered = [[found objectsAtIndexes:inFront] mutableCopy];
    [found removeObjectsAtIndexes:inFront];
    [ordered addObjectsFromArray:found];
    return ordered;
}

// The view a selector means: with an index, that one of the matches in the tree's order; without, the
// first one shown.
static UIView *pick(NSDictionary *p, UIView *root) {
    NSArray<UIView *> *found = findAll(p, root);
    if (p[@"index"]) {
        NSInteger index = [p[@"index"] integerValue];
        return index >= 0 && index < (NSInteger)found.count ? found[(NSUInteger)index] : nil;
    }
    for (UIView *view in found) {
        if (isShown(view)) return view;
    }
    return nil;
}

static NSString *selectorText(NSDictionary *p) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *key in @[@"id", @"label", @"text", @"class", @"index"]) {
        if (p[key]) [parts addObject:[NSString stringWithFormat:@"%@=%@", key, p[key]]];
    }
    return [parts componentsJoinedByString:@" "];
}

static UIView *require(NSDictionary *p, UIView *root) {
    UIView *view = pick(p, root);
    if (view) return view;
    NSUInteger count = findAll(p, root).count;
    if (count) fail(@"%@ matches %lu views, none of them shown (index= takes a hidden one)", selectorText(p), (unsigned long)count);
    fail(@"no view matches %@", selectorText(p));
}

static NSDictionary *describe(UIView *view) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"class"] = NSStringFromClass(view.class);
    CGRect frame = screenFrame(view);
    d[@"frame"] = @[@(round(frame.origin.x)), @(round(frame.origin.y)), @(round(frame.size.width)), @(round(frame.size.height))];
    d[@"shown"] = @(isShown(view));
    if (view.accessibilityIdentifier.length) d[@"id"] = view.accessibilityIdentifier;
    if (view.accessibilityLabel.length) d[@"label"] = view.accessibilityLabel;
    NSString *text = textOf(view);
    if (text.length) d[@"text"] = text;
    if ([view isKindOfClass:UIControl.class]) {
        d[@"enabled"] = @(((UIControl *)view).enabled);
        d[@"selected"] = @(((UIControl *)view).selected);
    }
    if ([view isKindOfClass:UISwitch.class]) d[@"on"] = @(((UISwitch *)view).on);
    // The font a label draws in: its attributed text's when it has one, which wins over its font.
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        UIFont *font = label.font;
        if (label.attributedText.length) font = [label.attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL] ?: font;
        if (font) d[@"font"] = [NSString stringWithFormat:@"%@ %.1f", font.fontName, font.pointSize];
    }
    if ([view isKindOfClass:UIScrollView.class]) {
        UIScrollView *scroll = (UIScrollView *)view;
        d[@"contentOffset"] = pair(scroll.contentOffset);
        d[@"contentSize"] = pair(CGPointMake(scroll.contentSize.width, scroll.contentSize.height));
    }
    return d;
}

static CGPoint parsePoint(NSString *text, NSString *name) {
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@","];
    if (parts.count != 2) fail(@"%@ takes x,y, not %@", name, text);
    return CGPointMake(parts[0].doubleValue, parts[1].doubleValue);
}

static double number(NSDictionary *p, NSString *key, double fallback) {
    return p[key] ? [p[key] doubleValue] : fallback;
}

// Where a command's finger goes: at=x,y, or the middle of the view the selector picks.
static NSDictionary *target(NSDictionary *p) {
    return onMain(^id {
        if (p[@"at"]) return @{@"point" : [NSValue valueWithCGPoint:parsePoint(p[@"at"], @"at")]};
        if (!hasSelector(p)) fail(@"say where: at=x,y, or a view by id, label, text or class (with index)");
        UIView *view = require(p, nil);
        return @{@"point" : [NSValue valueWithCGPoint:screenCenter(view)], @"target" : describe(view)};
    });
}

static NSDictionary *touchAt(NSDictionary *where, NSTimeInterval hold) {
    CGPoint point = [where[@"point"] CGPointValue];
    NSMutableDictionary *result = [finger(point, point, 0, hold) mutableCopy];
    result[@"point"] = pair(point);
    if (where[@"target"]) result[@"target"] = where[@"target"];
    return result;
}

#pragma mark - runtime screen/glass coverage (SG_DRIVER only)

// A static IPA class list only shows POSSIBLE controllers. This census inspects
// real UIViewController objects and the currently attached view hierarchy.
// It is diagnostic, read-only, and deliberately does not load offscreen views.
static void sgAuditIncludeController(UIViewController *vc, NSMutableOrderedSet<UIViewController *> *found) {
    if (!vc || [found containsObject:vc] || found.count >= 350) return;
    [found addObject:vc];
    if ([vc isKindOfClass:UINavigationController.class]) {
        for (UIViewController *entry in ((UINavigationController *)vc).viewControllers) {
            sgAuditIncludeController(entry, found);
        }
    }
    if ([vc isKindOfClass:UITabBarController.class]) {
        for (UIViewController *entry in ((UITabBarController *)vc).viewControllers) {
            sgAuditIncludeController(entry, found);
        }
    }
    for (UIViewController *child in vc.childViewControllers) sgAuditIncludeController(child, found);
    sgAuditIncludeController(vc.presentedViewController, found);
}

static NSString *sgAuditGlassKind(UIView *v) {
    NSString *name = NSStringFromClass(v.class) ?: @"";
    if ([name containsString:@"SGLegacyGlass"] || [name containsString:@"SGGlass"] ||
        [name containsString:@"SGRLegacyLens"] || [name containsString:@"SGRTabBarLens"]) return @"vitrine";
    if ([v isKindOfClass:UIVisualEffectView.class]) return @"system-effect";
    if ([name containsString:@"Backdrop"] || [name containsString:@"Glass"] || [name containsString:@"Lens"]) return @"named-candidate";
    return nil;
}

static BOOL sgAuditHasBackdropLayer(UIView *view) {
    if ([NSStringFromClass(view.layer.class) containsString:@"Backdrop"]) return YES;
    // Non-UIView CALayers do not appear in /tree, but are important for the
    // legacy refraction surface. Inspect only the direct layer children.
    NSUInteger inspected = 0;
    for (CALayer *layer in view.layer.sublayers) {
        if (++inspected > 32) break;
        if ([NSStringFromClass(layer.class) containsString:@"Backdrop"]) return YES;
    }
    return NO;
}

static NSMutableDictionary *sgAuditEmptyCounts(void) {
    return [@{@"views":@0, @"buttons":@0, @"headerCandidates":@0,
              @"vitrineGlass":@0, @"systemEffect":@0, @"namedGlassCandidates":@0,
              @"backdropViews":@0, @"examples":[NSMutableArray array]} mutableCopy];
}

static void sgAuditInc(NSMutableDictionary *counts, NSString *key) {
    counts[key] = @([counts[key] unsignedIntegerValue] + 1);
}

static NSDictionary *sgAuditControllers(void) {
    NSMutableOrderedSet<UIViewController *> *found = [NSMutableOrderedSet orderedSet];
    NSArray<UIWindow *> *allWindows = windows();
    for (UIWindow *window in allWindows) sgAuditIncludeController(window.rootViewController, found);
    NSMutableArray<NSString *> *navigation = [NSMutableArray array], *presented = [NSMutableArray array];
    UIViewController *top = topController(navigation, presented);

    // Attribute visible UI elements to their closest responder-chain controller.
    // Global navbar/mini-player glass is counted separately when no owning
    // UIViewController is reachable, not credited to every page beneath it.
    NSMutableDictionary<NSValue *, NSMutableDictionary *> *countsByController = [NSMutableDictionary dictionary];
    for (UIViewController *vc in found) {
        countsByController[[NSValue valueWithNonretainedObject:vc]] = sgAuditEmptyCounts();
    }
    NSMutableDictionary *unowned = sgAuditEmptyCounts();
    __block NSUInteger scanned = 0;
    for (UIWindow *window in allWindows) {
        SGForEachView(window, ^(UIView *view) {
            if (++scanned > 30000 || !isShown(view)) return;
            UIViewController *owner = nil;
            NSUInteger hops = 0;
            for (UIResponder *responder = view.nextResponder; responder && hops < 128;
                 responder = responder.nextResponder, hops++) {
                if ([responder isKindOfClass:UIViewController.class]) {
                    owner = (UIViewController *)responder;
                    break;
                }
            }
            if (owner && ![found containsObject:owner]) sgAuditIncludeController(owner, found);
            NSValue *key = owner ? [NSValue valueWithNonretainedObject:owner] : nil;
            NSMutableDictionary *counts = key ? countsByController[key] : nil;
            if (!counts && key) {
                counts = sgAuditEmptyCounts();
                countsByController[key] = counts;
            }
            if (!counts) counts = unowned;
            sgAuditInc(counts, @"views");
            NSString *name = NSStringFromClass(view.class) ?: @"";
            if ([view isKindOfClass:UIButton.class] || [name containsString:@"Button"]) sgAuditInc(counts, @"buttons");
            if ([name containsString:@"Header"] || [name containsString:@"Chip"] ||
                [name containsString:@"NavigationBar"] || [name containsString:@"TopBar"]) sgAuditInc(counts, @"headerCandidates");
            NSString *kind = sgAuditGlassKind(view);
            BOOL backdrop = sgAuditHasBackdropLayer(view);
            if ([kind isEqualToString:@"vitrine"]) sgAuditInc(counts, @"vitrineGlass");
            else if ([kind isEqualToString:@"system-effect"]) sgAuditInc(counts, @"systemEffect");
            else if (kind) sgAuditInc(counts, @"namedGlassCandidates");
            if (backdrop) sgAuditInc(counts, @"backdropViews");
            if ((kind || backdrop) && [counts[@"examples"] count] < 20) {
                CGRect f = screenFrame(view);
                [counts[@"examples"] addObject:@{@"class":name,
                    @"kind":kind ?: @"backdrop-layer", @"frame":@[@(round(f.origin.x)),
                    @(round(f.origin.y)), @(round(f.size.width)), @(round(f.size.height))]}];
            }
        });
    }
    NSMutableArray *controllers = [NSMutableArray array];
    for (UIViewController *vc in found) {
        UIView *view = vc.viewIfLoaded;
        BOOL loaded = view != nil;
        BOOL shown = loaded && isShown(view);
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"class"] = NSStringFromClass(vc.class) ?: @"";
        item[@"identity"] = [NSString stringWithFormat:@"%p", (void *)vc];
        item[@"loaded"] = @(loaded);
        item[@"visible"] = @(shown);
        item[@"top"] = @(vc == top);
        if (vc.title.length) item[@"title"] = vc.title;
        if (vc.parentViewController) item[@"parent"] = NSStringFromClass(vc.parentViewController.class) ?: @"";
        if (loaded && view.window) {
            CGRect f = screenFrame(view);
            item[@"frame"] = @[@(round(f.origin.x)), @(round(f.origin.y)),
                               @(round(f.size.width)), @(round(f.size.height))];
        }
        item[@"glass"] = countsByController[[NSValue valueWithNonretainedObject:vc]] ?: sgAuditEmptyCounts();
        [controllers addObject:item];
    }
    return @{@"schema":@1, @"top": top ? NSStringFromClass(top.class) : @"",
             @"controllerPath":navigation, @"presented":presented,
             @"controllers":controllers, @"unownedGlass":unowned,
             @"scannedViews":@(scanned), @"windowCount":@(allWindows.count),
             @"controllerCensusTruncated":@(found.count >= 350),
             @"viewCensusTruncated":@(scanned > 30000),
             @"interpretation":@"counts are visible UI evidence, not a verdict that the page is fully glass-covered"};
}

#pragma mark - the app's own parts

static NSString *const kPlayerClass = @"_TtC21NowPlaying_ScrollImpl23NPVScrollViewController";
static NSString *const kBarClass = @"_TtC18NowPlaying_BarImpl27NowPlayingBarViewController";

static BOOL insideController(UIView *view, Class cls) {
    for (UIResponder *r = view; r; r = r.nextResponder) {
        if (cls && [r isKindOfClass:cls]) return YES;
    }
    return NO;
}

// A shown view that is some controller's own view, of class `name`.
static UIView *controllerView(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) return nil;
    for (UIWindow *window in windows()) {
        __block UIView *found = nil;
        SGForEachView(window, ^(UIView *view) {
            if (!found && [view.nextResponder isKindOfClass:cls] && isShown(view)) found = view;
        });
        if (found) return found;
    }
    return nil;
}

static BOOL playerShown(void) {
    return controllerView(kPlayerClass) != nil;
}

// The system's menu, for the menus of UIButton and UIContextMenuInteraction.
static BOOL isMenuPart(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return [name hasPrefix:@"_UIContextMenu"] || [name hasPrefix:@"_UIMenu"]
        || [view.accessibilityIdentifier isEqualToString:@"Vitrine.Dropdown.Panel"];
}

static UIView *shownMenu(void) {
    for (UIWindow *window in windows()) {
        __block UIView *found = nil;
        SGForEachView(window, ^(UIView *view) {
            if (!found && ([NSStringFromClass(view.class) hasPrefix:@"_UIContextMenuView"]
                             || [view.accessibilityIdentifier isEqualToString:@"Vitrine.Dropdown.Panel"]) && isShown(view)) found = view;
        });
        if (found) return found;
    }
    return nil;
}

static BOOL insideMenu(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if (isMenuPart(v)) return YES;
    }
    return NO;
}

// The view showing `title`, by its text or its accessibility label, shown and passing `filter`.
static UIView *titled(NSString *title, BOOL (^filter)(UIView *)) {
    for (NSString *key in @[@"text", @"label"]) {
        for (UIView *view in findAll(@{key : title}, nil)) {
            if (isShown(view) && (!filter || filter(view))) return view;
        }
    }
    return nil;
}

static UIViewController *topController(NSMutableArray<NSString *> *path, NSMutableArray<NSString *> *presented) {
    UIViewController *top = keyWindow().rootViewController;
    while (top) {
        [path addObject:NSStringFromClass(top.class)];
        UIViewController *next = nil;
        if (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
            next = top.presentedViewController;
            [presented addObject:NSStringFromClass(next.class)];
        } else if ([top isKindOfClass:UINavigationController.class]) {
            next = ((UINavigationController *)top).topViewController;
        } else if ([top isKindOfClass:UITabBarController.class]) {
            next = ((UITabBarController *)top).selectedViewController;
        } else {
            // A container of Spotify's own: the child that covers most of it, not a bar inside it.
            CGRect own = CGRectIntersection(screenFrame(top.viewIfLoaded), keyWindow().bounds);
            CGFloat best = own.size.width * own.size.height / 2;
            for (UIViewController *child in top.childViewControllers) {
                if (!child.isViewLoaded || !isShown(child.view)) continue;
                CGRect frame = CGRectIntersection(screenFrame(child.view), keyWindow().bounds);
                CGFloat area = frame.size.width * frame.size.height;
                if (area > best) {
                    best = area;
                    next = child;
                }
            }
        }
        if (!next) break;
        top = next;
    }
    return top;
}

static NSDictionary *nowPlaying(void) {
    id player = SGDiagnosticsPlayer();
    SPTPlayerState *state = [player respondsToSelector:@selector(state)] ? [(id<SPTPlayer>)player state] : nil;
    if (!state) return nil;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    SPTPlayerTrack *track = state.track;
    if (track.trackTitle) d[@"title"] = track.trackTitle;
    if (track.artistName) d[@"artist"] = track.artistName;
    if (track.URI) d[@"uri"] = [track.URI description];
    d[@"position"] = @(round((state.isPaused ? state.positionAsOfTimestamp : state.position) * 10) / 10);
    d[@"duration"] = @(round(state.duration * 10) / 10);
    d[@"playing"] = @((BOOL)(state.isPlaying && !state.isPaused));
    d[@"paused"] = @(state.isPaused);
    return d;
}

static id<SPTPlayer> requirePlayer(void) {
    id player = SGDiagnosticsPlayer();
    if (!player) fail(@"no player yet: play something first, or open the app's player once");
    return player;
}

static UIView *firstResponder(void) {
    for (UIWindow *window in windows()) {
        id responder = nil;
        @try {
            responder = [window valueForKey:@"firstResponder"];
        } @catch (NSException *exception) {
        }
        if ([responder isKindOfClass:UIView.class]) return responder;
    }
    return nil;
}

// Legacy Glass draws its own tab bar. In icons-only mode it has no visible
// UITabBarButtonLabel, so the ordinary UITabBar/title search cannot navigate.
// Drive the *actual* four UITabBarButton views instead of toggling preferences
// or tapping guessed coordinates. Prefer a visible, bottom-anchored bar only.
static NSArray<UIView *> *legacyGlassTabItems(NSMutableArray<NSString *> *titles) {
    static NSArray<NSString *> *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ names = @[@"Home", @"Search", @"Your Library", @"Create"]; });
    for (UIWindow *window in windows()) {
        __block UIView *bar = nil;
        SGForEachView(window, ^(UIView *view) {
            if (bar || !isShown(view) ||
                ![NSStringFromClass(view.class) isEqualToString:@"SGRLegacyTabBar"]) return;
            CGRect frame = screenFrame(view);
            if (CGRectGetMidY(frame) < CGRectGetMidY(window.bounds)) return;
            bar = view;
        });
        if (!bar) continue;
        NSMutableArray<UIView *> *buttons = [NSMutableArray array];
        SGForEachView(bar, ^(UIView *view) {
            if ([NSStringFromClass(view.class) isEqualToString:@"UITabBarButton"] && isShown(view)) {
                [buttons addObject:view];
            }
        });
        [buttons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
            CGFloat x1 = CGRectGetMidX(screenFrame(a)), x2 = CGRectGetMidX(screenFrame(b));
            return x1 < x2 ? NSOrderedAscending : x1 > x2 ? NSOrderedDescending : NSOrderedSame;
        }];
        // Do not silently tap a wrong control when Spotify changes its layout.
        if (buttons.count != names.count) {
            fail(@"Legacy tab bar is visible but has %lu buttons (expected 4)",
                 (unsigned long)buttons.count);
        }
        [titles addObjectsFromArray:names];
        return buttons;
    }
    return @[];
}

// The tab bar's items, leading first: the redesign's UITabBar, or Spotify's own bar's row.
static NSArray<UIView *> *tabItems(NSMutableArray<NSString *> *titles) {
    NSArray<UIView *> *legacy = legacyGlassTabItems(titles);
    if (legacy.count) return legacy;
    for (UIWindow *window in windows()) {
        __block UIView *bar = nil;
        SGForEachView(window, ^(UIView *view) {
            if (bar || !isShown(view)) return;
            if ([view isKindOfClass:UITabBar.class] || [NSStringFromClass(view.class) isEqualToString:@"_TtC23NavigationUI_TabBarImpl10TabBarView"]) bar = view;
        });
        if (!bar) continue;
        NSMutableArray<UIView *> *items = [NSMutableArray array];
        if ([bar isKindOfClass:UITabBar.class]) {
            NSArray<UITabBarItem *> *barItems = ((UITabBar *)bar).items;
            for (UITabBarItem *item in barItems) {
                UIView *view = item.title ? titled(item.title, ^BOOL(UIView *v) { return [v isDescendantOfView:bar]; }) : nil;
                if (!view) continue;
                [items addObject:view];
                [titles addObject:item.title];
            }
            // The redesign's bar draws only the selected tab's title: its buttons instead, leading first.
            if (items.count < barItems.count) {
                [items removeAllObjects];
                [titles removeAllObjects];
                NSMutableArray<UIView *> *buttons = [NSMutableArray array];
                SGForEachView(bar, ^(UIView *v) {
                    if ([v isKindOfClass:UIControl.class] && [NSStringFromClass(v.class) containsString:@"TabButton"] && isShown(v)) [buttons addObject:v];
                });
                [buttons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
                    return CGRectGetMinX(screenFrame(a)) < CGRectGetMinX(screenFrame(b)) ? NSOrderedAscending : NSOrderedDescending;
                }];
                // The glass bar stacks two buttons on each tab: one a tab, by where it sits.
                for (UIView *button in buttons) {
                    if (items.count && fabs(CGRectGetMidX(screenFrame(button)) - CGRectGetMidX(screenFrame(items.lastObject))) < 4) continue;
                    NSUInteger i = items.count;
                    [items addObject:button];
                    [titles addObject:i < barItems.count ? barItems[i].title ?: button.accessibilityLabel ?: @"" : button.accessibilityLabel ?: @""];
                }
            }
        } else {
            for (UIView *item in SGRowIn(bar).arrangedSubviews) {
                if (!isShown(item)) continue;
                __block NSString *title = item.accessibilityLabel;
                SGForEachView(item, ^(UIView *v) {
                    if (!title.length && textOf(v).length) title = textOf(v);
                });
                [items addObject:item];
                [titles addObject:title ?: @""];
            }
        }
        return items;
    }
    return @[];
}

// The largest scroll view shown in the page in front, the page's own list; the key window's when there is no page.
static UIScrollView *mainScrollView(void) {
    UIView *front = frontView();
    // A table page's view is its list.
    if ([front isKindOfClass:UIScrollView.class] && isShown(front)) return (UIScrollView *)front;
    __block UIScrollView *best = nil;
    __block CGFloat bestArea = 0;
    SGForEachView(front ?: keyWindow(), ^(UIView *view) {
        if (![view isKindOfClass:UIScrollView.class] || !isShown(view)) return;
        CGRect frame = screenFrame(view);
        if (frame.size.width * frame.size.height > bestArea) {
            bestArea = frame.size.width * frame.size.height;
            best = (UIScrollView *)view;
        }
    });
    return best;
}

static CGPoint clampedOffset(UIScrollView *scroll, CGPoint offset) {
    UIEdgeInsets inset = scroll.adjustedContentInset;
    CGFloat maxX = MAX(-inset.left, scroll.contentSize.width + inset.right - scroll.bounds.size.width);
    CGFloat maxY = MAX(-inset.top, scroll.contentSize.height + inset.bottom - scroll.bounds.size.height);
    return CGPointMake(MIN(MAX(offset.x, -inset.left), maxX), MIN(MAX(offset.y, -inset.top), maxY));
}

#pragma mark - commands

#pragma mark - properties by key path (get, set, layers)

// A view or layer's properties read and written live, so a guess about what draws something can be tried on the
// phone without a build: `set --id sheet-view --path layer.sublayers.0.enabled --value false`.

static NSString *driverHex(CGColorRef color) {
    if (!color) return @"nil";
    static CGColorSpaceRef srgb;
    if (!srgb) srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorRef rgb = CGColorCreateCopyByMatchingToColorSpace(srgb, kCGRenderingIntentDefault, color, NULL);
    if (!rgb) return @"?";
    const CGFloat *c = CGColorGetComponents(rgb);
    NSString *hex = [NSString stringWithFormat:@"#%02X%02X%02X@%.2f", (int)lround(c[0] * 255), (int)lround(c[1] * 255), (int)lround(c[2] * 255), CGColorGetAlpha(rgb)];
    CGColorRelease(rgb);
    return hex;
}

// What a value reads as in the answer: numbers and strings as they are, colours as hex, anything else its description.
static id plainValue(id value) {
    if (!value || value == NSNull.null) return [NSNull null];
    if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:UIColor.class]) return driverHex(((UIColor *)value).CGColor);
    if (CFGetTypeID((__bridge CFTypeRef)value) == CGColorGetTypeID()) return driverHex((__bridge CGColorRef)value);
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *items = [NSMutableArray array];
        for (id item in (NSArray *)value) [items addObject:[item isKindOfClass:NSNumber.class] || [item isKindOfClass:NSString.class] ? item : NSStringFromClass([item class])];
        return items;
    }
    NSString *text = [value description];
    return text.length > 300 ? [text substringToIndex:300] : text;
}

// One step of a path: a number indexes an array (subviews, sublayers, filters), anything else is a key.
static id stepInto(id object, NSString *step) {
    NSScanner *scanner = [NSScanner scannerWithString:step];
    NSInteger index;
    if ([object isKindOfClass:NSArray.class] && [scanner scanInteger:&index] && scanner.isAtEnd) {
        NSArray *array = object;
        if (index < 0 || index >= (NSInteger)array.count) fail(@"index %ld is past the %lu items", (long)index, (unsigned long)array.count);
        return array[(NSUInteger)index];
    }
    @try {
        return [object valueForKey:step];
    } @catch (NSException *e) {
        fail(@"%@ has no key %@", NSStringFromClass([object class]), step);
    }
}

static id walk(id object, NSArray<NSString *> *steps) {
    for (NSString *step in steps) {
        object = stepInto(object, step);
        if (!object) fail(@"%@ is nil", step);
    }
    return object;
}

// A value typed on the Mac: nil, true/false, a number, a colour (#RRGGBB or #RRGGBBAA, a CGColor for a layer's key and
// a UIColor for a view's), or else the string.
static id typedValue(NSString *text, id target) {
    if (!text || [text isEqualToString:@"nil"] || [text isEqualToString:@"null"]) return nil;
    if ([text isEqualToString:@"true"] || [text isEqualToString:@"YES"]) return @YES;
    if ([text isEqualToString:@"false"] || [text isEqualToString:@"NO"]) return @NO;
    if ([text hasPrefix:@"#"] && (text.length == 7 || text.length == 9)) {
        unsigned long long rgba = 0;
        [[NSScanner scannerWithString:[text substringFromIndex:1]] scanHexLongLong:&rgba];
        if (text.length == 7) rgba = (rgba << 8) | 0xFF;
        UIColor *color = [UIColor colorWithRed:((rgba >> 24) & 0xFF) / 255.0 green:((rgba >> 16) & 0xFF) / 255.0 blue:((rgba >> 8) & 0xFF) / 255.0 alpha:(rgba & 0xFF) / 255.0];
        return [target isKindOfClass:CALayer.class] ? (id)color.CGColor : color;
    }
    NSScanner *scanner = [NSScanner scannerWithString:text];
    double number;
    if ([scanner scanDouble:&number] && scanner.isAtEnd) return @(number);
    return text;
}

static NSArray<NSString *> *pathSteps(NSDictionary *p) {
    NSString *path = p[@"path"];
    if (!path.length) fail(@"takes --path, keys and indexes joined by dots (layer.sublayers.0.opacity)");
    return [path componentsSeparatedByString:@"."];
}

// The object a path starts from: the view the selector names, or the key window.
static id pathRoot(NSDictionary *p) {
    return hasSelector(p) ? require(p, nil) : keyWindow();
}

// A layer's line: its class, frame, and whatever about it changes how it and what is under it draw.
static NSString *layerLine(CALayer *layer) {
    NSMutableString *line = [NSMutableString stringWithString:NSStringFromClass(layer.class)];
    if ([layer.delegate isKindOfClass:UIView.class]) [line appendFormat:@" (%@)", NSStringFromClass([(id)layer.delegate class])];
    if (layer.name.length) [line appendFormat:@" name=%@", layer.name];
    [line appendFormat:@" %@", NSStringFromCGRect(layer.frame)];
    if (layer.hidden) [line appendString:@" hidden"];
    if (layer.opacity < 1) [line appendFormat:@" op=%.2f", layer.opacity];
    if (layer.opaque) [line appendString:@" opaque"];
    if (layer.masksToBounds) [line appendString:@" clips"];
    if (layer.cornerRadius > 0) [line appendFormat:@" r=%.1f", layer.cornerRadius];
    if (layer.backgroundColor && CGColorGetAlpha(layer.backgroundColor) > 0) [line appendFormat:@" bg=%@", driverHex(layer.backgroundColor)];
    if (layer.contents) [line appendString:@" contents"];
    if (layer.mask) [line appendFormat:@" mask=%@", NSStringFromClass(layer.mask.class)];
    if (layer.shouldRasterize) [line appendString:@" rasterized"];
    if (!layer.allowsGroupOpacity) [line appendString:@" noGroupOpacity"];
    if (layer.compositingFilter) [line appendFormat:@" compositing=%@", layer.compositingFilter];
    if (!CATransform3DIsIdentity(layer.transform)) [line appendString:@" transformed"];
    if (layer.filters.count) {
        NSMutableArray *names = [NSMutableArray array];
        for (id filter in layer.filters) {
            id name = nil;
            @try { name = [filter valueForKey:@"type"]; } @catch (__unused NSException *e) {}
            [names addObject:name ?: NSStringFromClass([filter class])];
        }
        [line appendFormat:@" filters=%@", [names componentsJoinedByString:@","]];
    }
    if ([NSStringFromClass(layer.class) containsString:@"Backdrop"]) {
        for (NSString *key in @[@"enabled", @"scale", @"groupName", @"captureOnly", @"windowServerAware", @"allowsInPlaceFiltering", @"marginWidth", @"zoom", @"ignoresScreenClip", @"disablesOccludedBackdropBlurs", @"reducesCaptureBitDepth"]) {
            id value = nil;
            @try { value = [layer valueForKey:key]; } @catch (__unused NSException *e) { continue; }
            [line appendFormat:@" %@=%@", key, plainValue(value)];
        }
        id mesh = nil;
        @try { mesh = [layer valueForKey:@"meshTransform"]; } @catch (__unused NSException *e) {}
        if (mesh) [line appendString:@" mesh"];
    }
    return line;
}

static void dumpLayers(CALayer *layer, NSUInteger depth, NSUInteger maxDepth, NSMutableArray<NSString *> *lines) {
    if (lines.count > 600) return;
    [lines addObject:[[@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0] stringByAppendingString:layerLine(layer)]];
    if (depth >= maxDepth) return;
    for (CALayer *sub in layer.sublayers) dumpLayers(sub, depth + 1, maxDepth, lines);
}

typedef NSDictionary *(^SGCommand)(NSDictionary *p);

#pragma mark - frame-synchronous Legacy navigation trace (Stage 83)

// /tree and /get are handled by the driver server. Requesting them during a
// long /swipe.reverse can be serialized until the finger is UP, which makes a
// purported "held" state false evidence. This observer samples on the MAIN
// display link, alongside UIKit's presentation layers, while the touch is down.
// The server fetches these immutable dictionaries only after the gesture.
static NSDictionary *sgNavRect(CGRect r) {
    if (CGRectIsNull(r) || CGRectIsEmpty(r)) return @{ @"valid": @NO };
    return @{ @"valid": @YES, @"x": @(r.origin.x), @"y": @(r.origin.y),
              @"w": @(r.size.width), @"h": @(r.size.height) };
}

static NSDictionary *sgNavView(UIView *v, UIWindow *window) {
    CALayer *base = v.layer;
    CALayer *drawn = base.presentationLayer ?: base;
    NSMutableDictionary *d = [@{ @"class": NSStringFromClass(v.class) ?: @"",
        @"id": v.accessibilityIdentifier ?: @"", @"alpha": @(v.alpha),
        @"hidden": @(v.hidden), @"shownInWindow": @(v.window != nil),
        @"screen": sgNavRect([v convertRect:v.bounds toView:window]),
        @"presentation": sgNavRect(drawn.frame),
        @"layerOpacity": @(drawn.opacity),
        @"layerHidden": @(drawn.hidden),
        @"z": @(base.zPosition),
        @"clip": @(base.masksToBounds),
        @"animationKeys": base.animationKeys ?: @[],
        @"maskClass": base.mask ? NSStringFromClass(base.mask.class) : @"nil",
        @"filterCount": @(base.filters.count),
        @"sublayerCount": @(base.sublayers.count) } mutableCopy];
    if ([v respondsToSelector:NSSelectorFromString(@"touching")]) {
        @try { d[@"touching"] = [v valueForKey:@"touching"] ?: [NSNull null]; }
        @catch (__unused NSException *e) {}
    }
    if ([v respondsToSelector:NSSelectorFromString(@"refracting")]) {
        @try { d[@"refracting"] = [v valueForKey:@"refracting"] ?: [NSNull null]; }
        @catch (__unused NSException *e) {}
    }
    if ([NSStringFromClass(v.class) containsString:@"SGRLegacyLens"]) {
        @try {
            NSValue *rest = [v valueForKey:@"restFrame"];
            if ([rest isKindOfClass:NSValue.class]) d[@"restFrame"] = sgNavRect(rest.CGRectValue);
        } @catch (__unused NSException *e) {}
        NSMutableArray *layers = [NSMutableArray array];
        for (CALayer *sublayer in base.sublayers) {
            if (layers.count >= 22) break;
            CALayer *live = sublayer.presentationLayer ?: sublayer;
            [layers addObject:@{ @"name": sublayer.name ?: @"",
                @"class": NSStringFromClass(sublayer.class) ?: @"",
                @"frame": sgNavRect(live.frame),
                @"opacity": @(live.opacity),
                @"hidden": @(live.hidden),
                @"mask": sublayer.mask ? NSStringFromClass(sublayer.mask.class) : @"nil",
                @"filters": @(sublayer.filters.count),
                @"animations": sublayer.animationKeys ?: @[] }];
        }
        d[@"layers"] = layers;
    }
    return d;
}

// Resolve a small, weakly cached set of relevant views. An expensive whole
// window traversal on every 120Hz tick would itself cause the stutter we are
// trying to diagnose. Refresh references about 10 times per second instead.
static NSArray<UIView *> *sgNavTargets(UIWindow *window) {
    NSMutableArray<UIView *> *targets = [NSMutableArray array];
    if (!window) return targets;
    NSMutableArray<UIView *> *glass = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    NSUInteger visited = 0;
    while (queue.count && visited++ < 2200) {
        UIView *view = queue.lastObject;
        [queue removeLastObject];
        NSString *name = NSStringFromClass(view.class);
        if ([name containsString:@"SGRLegacyLens"] ||
            [name containsString:@"SGRLegacyTabBar"] ||
            [name containsString:@"SGRNowPlaying"]) {
            [targets addObject:view];
        } else if ([name containsString:@"SGLegacyGlassView"] && glass.count < 20) {
            [glass addObject:view];
        }
        for (UIView *child in view.subviews) [queue addObject:child];
    }
    // Never let a large number of irrelevant glass panes crowd out the lens.
    [targets addObjectsFromArray:glass];
    return targets;
}

static NSDictionary *sgNavSample(NSArray<UIView *> *targets) {
    UIWindow *window = keyWindow();
    NSMutableArray *objects = [NSMutableArray array];
    for (UIView *view in targets) {
        if (view.window && view.window == window) [objects addObject:sgNavView(view, window)];
    }
    CGRect card = window ? SGRNowPlayingCardFrameIn(window, NULL) : CGRectNull;
    CGRect slot = window ? SGRTabBarInlineSlot(window, 54) : CGRectNull;
    CGRect artwork = window ? SGRNowPlayingArtworkFrameIn(window) : CGRectNull;
    return @{ @"minimized": @(SGRTabBarMinimized()),
              @"held": @(SGRLegacyNowPlayingHeld()),
              @"playerVisible": @(playerShown()),
              @"card": sgNavRect(card), @"slot": sgNavRect(slot),
              @"artwork": sgNavRect(artwork),
              @"barTransition": SGRDiagnosticsBarTransition() ?: @{},
              @"playerMorph": SGRDiagnosticsPlayerMorph() ?: @{},
              @"objects": objects,
              @"targetCount": @(targets.count) };
}

@interface SGNavTraceObserver : NSObject
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *frames;
@property (nonatomic) CFTimeInterval began;
@property (nonatomic) NSUInteger ticks;
@property (nonatomic) BOOL capped;
@property (nonatomic, strong) NSHashTable<UIView *> *targets;
@end

@implementation SGNavTraceObserver
- (void)capture:(NSString *)phase {
    CFTimeInterval t = CACurrentMediaTime() - self.began;
    if (t > 18 || self.frames.count >= 1050) {
        self.capped = YES;
        [self stop];
        return;
    }
    // Avoid retaining a removed Spotify view when controllers change during
    // the gesture. A weak cache also permits the new tab bar to be discovered.
    if (!self.targets || self.ticks % 12 == 0) {
        self.targets = [NSHashTable weakObjectsHashTable];
        for (UIView *view in sgNavTargets(keyWindow())) [self.targets addObject:view];
    }
    NSMutableDictionary *frame = [sgNavSample(self.targets.allObjects) mutableCopy];
    frame[@"t"] = @(t);
    frame[@"phase"] = phase;
    [self.frames addObject:frame];
}
- (void)tick:(CADisplayLink *)link {
    if (++self.ticks % 2) return; // roughly 60Hz at 120Hz display rate
    [self capture:@"displayLink"];
}
- (void)stop {
    [self.link invalidate];
    self.link = nil;
}
@end

static SGNavTraceObserver *sg_navTrace;

// The log number when the last command that does something began: a log wait looks from there, so
// `player.more` and then `wait log=...` sees a line that came before the wait did.
static uint64_t sg_actionSeq;

static NSDictionary<NSString *, SGCommand> *commands(void) {
    static NSDictionary<NSString *, SGCommand> *all;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        all = @{
            @"nav.trace.start" : ^NSDictionary *(NSDictionary *p) {
                return onMain(^id {
                    [sg_navTrace stop];
                    sg_navTrace = [SGNavTraceObserver new];
                    sg_navTrace.frames = [NSMutableArray array];
                    sg_navTrace.began = CACurrentMediaTime();
                    [sg_navTrace capture:@"start"];
                    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:sg_navTrace selector:@selector(tick:)];
                    // An uncapped display link tracks the player's 120Hz timeline;
                    // capture every other callback to keep observation lightweight.
                    link.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
                    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
                    sg_navTrace.link = link;
                    return @{ @"capturing": @YES, @"initial": @(sg_navTrace.frames.count) };
                });
            },
            @"nav.trace.stop" : ^NSDictionary *(NSDictionary *p) {
                return onMain(^id {
                    if (!sg_navTrace) fail(@"trace was never started");
                    [sg_navTrace capture:@"stop"];
                    [sg_navTrace stop];
                    return @{ @"capturing": @NO, @"frames": @(sg_navTrace.frames.count),
                              @"capped": @(sg_navTrace.capped) };
                });
            },
            @"nav.trace.status" : ^NSDictionary *(NSDictionary *p) {
                return onMain(^id {
                    if (!sg_navTrace) return @{ @"present": @NO };
                    return @{ @"present": @YES, @"capturing": @(sg_navTrace.link != nil),
                              @"frames": @(sg_navTrace.frames.count),
                              @"capped": @(sg_navTrace.capped) };
                });
            },
            @"nav.trace.read" : ^NSDictionary *(NSDictionary *p) {
                return onMain(^id {
                    if (!sg_navTrace) fail(@"trace was never started");
                    NSUInteger offset = MIN((NSUInteger)MAX(0, [p[@"offset"] integerValue]), sg_navTrace.frames.count);
                    NSUInteger count = MIN(50, (NSUInteger)MAX(1, p[@"limit"] ? [p[@"limit"] integerValue] : 30));
                    count = MIN(count, sg_navTrace.frames.count - offset);
                    return @{ @"offset": @(offset), @"total": @(sg_navTrace.frames.count),
                              @"frames": [sg_navTrace.frames subarrayWithRange:NSMakeRange(offset, count)],
                              @"done": @(offset + count >= sg_navTrace.frames.count),
                              @"capped": @(sg_navTrace.capped) };
                });
            },
            @"tap" : ^NSDictionary *(NSDictionary *p) {
                return touchAt(target(p), 0.08);
            },
            @"longpress" : ^NSDictionary *(NSDictionary *p) {
                return touchAt(target(p), number(p, @"duration", 1.0));
            },
            @"swipe" : ^NSDictionary *(NSDictionary *p) {
                NSDictionary *start = p[@"from"] ? @{@"point" : [NSValue valueWithCGPoint:parsePoint(p[@"from"], @"from")]} : target(p);
                CGPoint from = [start[@"point"] CGPointValue];
                CGPoint to;
                if (p[@"to"]) {
                    to = parsePoint(p[@"to"], @"to");
                } else if (p[@"by"]) {
                    CGPoint by = parsePoint(p[@"by"], @"by");
                    to = CGPointMake(from.x + by.x, from.y + by.y);
                } else {
                    fail(@"swipe takes to=x,y or by=dx,dy");
                }
                BOOL drag = [p[@"drag"] boolValue];
                NSMutableDictionary *result = [finger(from, to, number(p, @"duration", drag ? 0.6 : 0.2), number(p, @"hold", drag ? 0.3 : 0)) mutableCopy];
                result[@"from"] = pair(from);
                result[@"to"] = pair(to);
                if (start[@"target"]) result[@"target"] = start[@"target"];
                return result;
            },
            @"swipe.reverse" : ^NSDictionary *(NSDictionary *p) {
                NSDictionary *start = p[@"from"] ? @{ @"point": [NSValue valueWithCGPoint:parsePoint(p[@"from"], @"from")] } : target(p);
                CGPoint from = [start[@"point"] CGPointValue];
                CGPoint via = p[@"via"] ? parsePoint(p[@"via"], @"via") : CGPointMake(from.x, from.y - 130);
                CGPoint to = p[@"to"] ? parsePoint(p[@"to"], @"to") : from;
                NSTimeInterval up = number(p, @"up", 0.65);
                NSTimeInterval back = number(p, @"back", 0.75);
                NSTimeInterval hold = number(p, @"hold", 0);
                NSMutableDictionary *result = [fingerReverse(from, via, to, up, back, hold) mutableCopy];
                result[@"from"] = pair(from);
                result[@"via"] = pair(via);
                result[@"to"] = pair(to);
                result[@"up"] = @(up);
                result[@"back"] = @(back);
                result[@"hold"] = @(hold);
                if (start[@"target"]) result[@"target"] = start[@"target"];
                return result;
            },
            @"settings.dismiss" : ^NSDictionary *(NSDictionary *p) {
                // Leave only Vitrine's SGPage stack. Never pop Spotify pages.
                return onMain(^id {
                    UIViewController *top = topController([NSMutableArray array], [NSMutableArray array]);
                    Class modPage = NSClassFromString(@"SGPage");
                    UINavigationController *nav = top.navigationController;
                    NSUInteger popped = 0;
                    while (nav && modPage && [nav.topViewController isKindOfClass:modPage] &&
                           nav.viewControllers.count > 1 && popped < 12) {
                        [nav popViewControllerAnimated:NO];
                        popped++;
                    }
                    return @{ @"popped": @(popped),
                              @"top": NSStringFromClass(nav.topViewController.class) ?: @"nil" };
                });
            },
            // Force the *minimized* Legacy tab row for an NPV reverse-gesture
            // reproduction. The old test started from the expanded bar, so it
            // exercised an unrelated touch on UIStackView and falsely passed.
            @"navbar.minimize" : ^NSDictionary *(NSDictionary *p) {
                return onMain(^id {
                    if (!SGRLegacyTabBarOn()) fail(@"not the Legacy tab bar");
                    SGRSetTabBarMinimized([p[@"on"] boolValue], [p[@"animated"] boolValue]);
                    [keyWindow() layoutIfNeeded];
                    return @{ @"minimized": @(SGRTabBarMinimized()) };
                });
            },
            @"navbar.mini-state" : ^NSDictionary *(NSDictionary *p) {
                return onMain(^id {
                    UIWindow *window = keyWindow();
                    CGRect card = SGRNowPlayingCardFrameIn(window, NULL);
                    CGRect slot = SGRTabBarInlineSlot(window, 54);
                    CGRect artwork = SGRNowPlayingArtworkFrameIn(window);
                    id (^coordinates)(CGRect) = ^id(CGRect frame) {
                        return CGRectIsNull(frame) || CGRectIsEmpty(frame) ? (id)[NSNull null] :
                            (id)@[@(frame.origin.x), @(frame.origin.y), @(frame.size.width), @(frame.size.height)];
                    };
                    return @{ @"minimized": @(SGRTabBarMinimized()),
                              @"legacy": @(SGRLegacyTabBarOn()),
                              @"held": @(SGRLegacyNowPlayingHeld()),
                              @"cardFrame": coordinates(card),
                              @"inlineSlot": coordinates(slot),
                              @"artworkFrame": coordinates(artwork) };
                });
            },
            @"navbar.refresh" : ^NSDictionary *(NSDictionary *p) {
                return onMain(^id {
                    SGPrefsChanged();
                    SGRRefreshTabBar();
                    return @{ @"refreshed": @YES };
                });
            },
            @"scroll" : ^NSDictionary *(NSDictionary *p) {
                if (!p[@"by"]) fail(@"scroll takes by=dx,dy");
                CGPoint by = parsePoint(p[@"by"], @"by");
                return onMain(^id {
                    UIView *view = nil;
                    if (hasSelector(p)) {
                        view = require(p, nil);
                    } else if (p[@"at"]) {
                        CGPoint at = parsePoint(p[@"at"], @"at");
                        UIWindow *window = windowAt(at);
                        view = [window hitTest:[window convertPoint:at fromWindow:nil] withEvent:nil];
                    } else {
                        view = mainScrollView();
                    }
                    while (view && ![view isKindOfClass:UIScrollView.class]) view = view.superview;
                    if (!view) fail(@"no scroll view there");
                    UIScrollView *scroll = (UIScrollView *)view;
                    CGPoint before = scroll.contentOffset;
                    CGPoint after = clampedOffset(scroll, CGPointMake(before.x + by.x, before.y + by.y));
                    [scroll setContentOffset:after animated:[p[@"animated"] boolValue]];
                    return @{@"scrollView" : describe(scroll), @"before" : pair(before), @"after" : pair(after)};
                });
            },
            @"type" : ^NSDictionary *(NSDictionary *p) {
                NSString *text = p[@"text"] ?: p[@"arg"];
                if (!text) fail(@"type takes the text");
                return onMain(^id {
                    UIView *responder = firstResponder();
                    if (![responder conformsToProtocol:@protocol(UIKeyInput)]) fail(@"nothing takes typing: tap a text field first");
                    [(id<UIKeyInput>)responder insertText:text];
                    return @{@"into" : describe(responder)};
                });
            },
            @"find" : ^NSDictionary *(NSDictionary *p) {
                if (!hasSelector(p)) fail(@"find takes id, label, text or class");
                return onMain(^id {
                    NSMutableArray *views = [NSMutableArray array];
                    NSArray<UIView *> *found = findAll(p, nil);
                    for (NSUInteger i = 0; i < found.count && i < 100; i++) {
                        NSMutableDictionary *d = [describe(found[i]) mutableCopy];
                        d[@"index"] = @(i);
                        [views addObject:d];
                    }
                    return @{@"count" : @(found.count), @"views" : views};
                });
            },
            @"audit.controllers" : ^NSDictionary *(NSDictionary *p) {
                return onMain(^id { return sgAuditControllers(); });
            },
            @"state" : ^NSDictionary *(NSDictionary *p) {
                return onMain(^id {
                    NSMutableArray<NSString *> *path = [NSMutableArray array], *presented = [NSMutableArray array];
                    UIViewController *top = topController(path, presented);
                    NSMutableDictionary *d = [NSMutableDictionary dictionary];
                    d[@"top"] = top ? NSStringFromClass(top.class) : [NSNull null];
                    if (top.title.length) d[@"topTitle"] = top.title;
                    d[@"controllers"] = path;
                    d[@"presented"] = presented;
                    d[@"menu"] = @((BOOL)(shownMenu() != nil));
                    d[@"player"] = @(playerShown());
                    d[@"nowPlaying"] = nowPlaying() ?: [NSNull null];
                    UIView *responder = firstResponder();
                    if (responder) d[@"firstResponder"] = NSStringFromClass(responder.class);
                    d[@"keyWindow"] = NSStringFromClass(keyWindow().class) ?: [NSNull null];
                    d[@"logSeq"] = @(SGLogLastSeq());
                    return d;
                });
            },
            @"screenshot" : ^NSDictionary *(NSDictionary *p) {
                return onMain(^id {
                    UIWindow *key = keyWindow();
                    if (!key) fail(@"no window");
                    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
                    if (p[@"scale"]) format.scale = [p[@"scale"] doubleValue];
                    // Every window, lowest level first, so a menu in a window of its own is in the picture.
                    NSArray<UIWindow *> *all = [windows() sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
                        return a.windowLevel < b.windowLevel ? NSOrderedAscending : a.windowLevel > b.windowLevel ? NSOrderedDescending : NSOrderedSame;
                    }];
                    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:key.bounds format:format];
                    NSData *png = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
                        for (UIWindow *window in all) {
                            // The keyboard is drawn by another process: its window draws as a white sheet over all.
                            NSString *name = NSStringFromClass(window.class);
                            if (window.hidden || window.alpha < 0.01 || [name containsString:@"Keyboard"] || [name containsString:@"TextEffects"]) continue;
                            [window drawViewHierarchyInRect:window.frame afterScreenUpdates:NO];
                        }
                    }];
                    return @{@"png" : [png base64EncodedStringWithOptions:0], @"size" : pair(CGPointMake(key.bounds.size.width * format.scale, key.bounds.size.height * format.scale))};
                });
            },
            @"log" : ^NSDictionary *(NSDictionary *p) {
                uint64_t last = SGLogLastSeq();
                uint64_t since = p[@"since"] ? (uint64_t)[p[@"since"] longLongValue] : (last > 100 ? last - 100 : 0);
                return @{@"lines" : SGLogRecent(since), @"last" : @(last)};
            },
            @"wait" : ^NSDictionary *(NSDictionary *p) {
                NSTimeInterval timeout = number(p, @"timeout", 5);
                NSDate *start = NSDate.date;
                BOOL gone = [p[@"gone"] boolValue];
                if (!p[@"log"] && !hasSelector(p) && !p[@"menu"]) fail(@"wait takes log=text, menu=1, or a view by id, label, text or class");
                uint64_t since = p[@"since"] ? (uint64_t)[p[@"since"] longLongValue] : sg_actionSeq;
                while (YES) {
                    if (p[@"log"]) {
                        for (NSDictionary *line in SGLogRecent(since)) {
                            if ([line[@"text"] containsString:p[@"log"]]) return @{@"line" : line, @"after" : @(-start.timeIntervalSinceNow)};
                        }
                    } else {
                        NSDictionary *seen = onMain(^id {
                            UIView *view = p[@"menu"] ? shownMenu() : pick(p, nil);
                            if (view && !isShown(view)) view = nil;
                            if (gone) return view ? nil : @{};
                            return view ? describe(view) : nil;
                        });
                        if (seen) return @{@"view" : seen.count ? seen : [NSNull null], @"after" : @(-start.timeIntervalSinceNow)};
                    }
                    if (-start.timeIntervalSinceNow > timeout) {
                        if (p[@"log"]) fail(@"no log line with \"%@\" within %.1f s", p[@"log"], timeout);
                        NSString *what = p[@"menu"] ? @"the menu" : selectorText(p);
                        fail(@"%@ %@ after %.1f s", what, gone ? @"still shown" : @"not shown", timeout);
                    }
                    pause_(0.1);
                }
            },
            @"player.open" : ^NSDictionary *(NSDictionary *p) {
                NSDictionary *where = onMain(^id {
                    if (playerShown()) return @{};
                    UIView *bar = controllerView(kBarClass);
                    if (!bar) fail(@"no now playing bar shown");
                    // Left of the middle: the artwork and the title, away from the bar's buttons.
                    CGRect frame = screenFrame(bar);
                    return @{@"point" : [NSValue valueWithCGPoint:CGPointMake(CGRectGetMinX(frame) + frame.size.width * 0.3, CGRectGetMidY(frame))],
                             @"target" : describe(bar)};
                });
                if (!where.count) return @{@"note" : @"the player was already open"};
                return touchAt(where, 0.08);
            },
            @"player.close" : ^NSDictionary *(NSDictionary *p) {
                NSDictionary *where = onMain(^id {
                    for (NSString *identifier in @[@"now-playing-minimize-button", @"mobile-nowplaying-close-button"]) {
                        UIView *button = pick(@{@"id" : identifier}, nil);
                        if (button) return @{@"point" : [NSValue valueWithCGPoint:screenCenter(button)], @"target" : describe(button)};
                    }
                    if (!playerShown()) return @{};
                    fail(@"the player is open but its down arrow is not found");
                });
                if (!where.count) return @{@"note" : @"the player was not open"};
                return touchAt(where, 0.08);
            },
            @"player.more" : ^NSDictionary *(NSDictionary *p) {
                NSDictionary *where = onMain(^id {
                    Class player = NSClassFromString(kPlayerClass);
                    UIView *more = nil;
                    for (UIView *view in findAll(@{@"id" : @"Context menu"}, nil)) {
                        if (isShown(view) && insideController(view, player)) more = view;
                    }
                    if (!more) fail(@"%@", playerShown() ? @"the player's ⋯ (id=Context menu) is not shown" : @"the player is not open (player.open)");
                    return @{@"point" : [NSValue valueWithCGPoint:screenCenter(more)], @"target" : describe(more)};
                });
                return touchAt(where, 0.08);
            },
            @"menu.pick" : ^NSDictionary *(NSDictionary *p) {
                NSString *title = p[@"title"] ?: p[@"arg"];
                if (!title) fail(@"menu.pick takes the row's title");
                NSDictionary *where = onMain(^id {
                    if (!shownMenu()) fail(@"no menu is up");
                    UIView *row = titled(title, ^BOOL(UIView *v) { return insideMenu(v); });
                    if (!row) fail(@"the menu has no row \"%@\"", title);
                    return @{@"point" : [NSValue valueWithCGPoint:screenCenter(row)], @"target" : describe(row)};
                });
                return touchAt(where, 0.08);
            },
            // `seek 42` goes to 42 s; `seek --by -15` moves by 15 s back, the way Spotify's relative seeks do.
            @"seek" : ^NSDictionary *(NSDictionary *p) {
                double seconds = [(p[@"seconds"] ?: p[@"arg"]) doubleValue];
                NSString *by = p[@"by"];
                return onMain(^id {
                    id player = requirePlayer();
                    SEL relative = NSSelectorFromString(@"seekTo:relative:");
                    if (by && ![player respondsToSelector:relative]) fail(@"this player has no relative seek");
                    // Spotify's `relative`, as measured on 9.1.90: 0 from the start, 1 from the end, 2 from where it plays.
                    if (by) ((id (*)(id, SEL, double, long long))objc_msgSend)(player, relative, by.doubleValue, 2);
                    else [player seekTo:seconds];
                    return by ? @{@"by" : @(by.doubleValue)} : @{@"seconds" : @(seconds)};
                });
            },
            // Playback speed, 1 when normal: speed 1.5.
            @"speed" : ^NSDictionary *(NSDictionary *p) {
                double speed = [(p[@"value"] ?: p[@"arg"]) doubleValue];
                if (speed <= 0) fail(@"speed takes a rate, 1 when normal");
                return onMain(^id {
                    SGSetPlayerSpeed(speed);
                    return @{@"speed" : @(SGPlayerSpeed())};
                });
            },
            // A local lossless file in place of Spotify's sound for the same recording: lossless anchor --path P,
            // lossless check, lossless stop. Runs off main: matching takes a few seconds.
            @"lossless" : ^NSDictionary *(NSDictionary *p) {
                NSString *error;
                NSDictionary *result = SGLosslessProbe(p[@"arg"] ?: @"check", p, &error);
                if (!result) fail(@"%@", error);
                return result;
            },
            // Spotify's Automix and Crossfade settings: automix [--automix 1] [--crossfade 1] [--ms 5000].
            @"automix" : ^NSDictionary *(NSDictionary *p) {
                NSString *error;
                NSDictionary *result = SGAutoMixProbeCommand(p, &error);
                if (!result) fail(@"%@", error);
                return result;
            },
            // Karaoke on or off: sing 1, sing 0.
            @"sing" : ^NSDictionary *(NSDictionary *p) {
                BOOL on = [(p[@"value"] ?: p[@"arg"]) boolValue];
                return onMain(^id {
                    SGSetSingOn(on);
                    return @{@"sing" : @(on)};
                });
            },
            @"landscape" : ^NSDictionary *(NSDictionary *p) {
                BOOL on = [(p[@"value"] ?: p[@"arg"]) boolValue];
                return onMain(^id {
                    SGRPlayerShowLandscape(on);
                    return @{@"landscape" : @(on)};
                });
            },
            @"play" : ^NSDictionary *(NSDictionary *p) {
                return onMain(^id {
                    [requirePlayer() resume:nil];
                    return @{};
                });
            },
            @"pause" : ^NSDictionary *(NSDictionary *p) {
                return onMain(^id {
                    [requirePlayer() pause:nil];
                    return @{};
                });
            },
            @"next" : ^NSDictionary *(NSDictionary *p) {
                return onMain(^id {
                    [requirePlayer() skipToNextTrackWithOptions:nil];
                    return @{};
                });
            },
            @"tab" : ^NSDictionary *(NSDictionary *p) {
                NSString *which = p[@"title"] ?: p[@"index"] ?: p[@"arg"];
                if (!which) fail(@"tab takes an index (0 is the leading tab) or a title");
                NSDictionary *where = onMain(^id {
                    NSMutableArray<NSString *> *titles = [NSMutableArray array];
                    NSArray<UIView *> *items = tabItems(titles);
                    if (!items.count) fail(@"no tab bar shown");
                    NSUInteger index = [titles indexOfObjectPassingTest:^BOOL(NSString *t, NSUInteger i, BOOL *stop) { return same(t, which, NO); }];
                    if (index == NSNotFound && !p[@"title"] && [which rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound) {
                        index = (NSUInteger)which.integerValue;
                    }
                    if (index == NSNotFound || index >= items.count) fail(@"no tab %@; the tabs are %@", which, [titles componentsJoinedByString:@", "]);
                    return @{@"point" : [NSValue valueWithCGPoint:screenCenter(items[index])], @"target" : describe(items[index]), @"tabs" : titles};
                });
                NSMutableDictionary *result = [touchAt(where, 0.08) mutableCopy];
                result[@"tabs"] = where[@"tabs"];
                return result;
            },
            // One of Vitrine's settings, for a test that needs a setting changed and Spotify relaunched rather than
            // a picker driven: --key spotifyglass.x --value 6 (a whole number), or --text for a string, or --remove 1.
            @"pref" : ^NSDictionary *(NSDictionary *p) {
                NSString *key = p[@"key"];
                if (![key hasPrefix:@"spotifyglass."]) fail(@"pref takes --key spotifyglass.<name>");
                NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
                if (p[@"remove"]) [store removeObjectForKey:key];
                else if (p[@"text"]) [store setObject:p[@"text"] forKey:key];
                else if (p[@"value"]) [store setInteger:[p[@"value"] integerValue] forKey:key];
                return @{@"key" : key, @"now" : [store objectForKey:key] ?: [NSNull null]};
            },
            @"settings.open" : ^NSDictionary *(NSDictionary *p) {
                return onMain(^id {
                    UIViewController *top = topController([NSMutableArray array], [NSMutableArray array]);
                    SGOpenModSettings(top.viewIfLoaded ?: keyWindow());
                    return @{};
                });
            },
            @"settings.page" : ^NSDictionary *(NSDictionary *p) {
                NSString *title = p[@"title"] ?: p[@"arg"];
                if (!title) fail(@"settings.page takes the row's title");
                NSDictionary *where = onMain(^id {
                    UIView *row = titled(title, nil);
                    UIScrollView *list = mainScrollView();
                    // Down the page a screen at a time until the row is laid out.
                    if (!row && list) {
                        CGPoint offset = clampedOffset(list, CGPointMake(list.contentOffset.x, -CGFLOAT_MAX));
                        for (NSUInteger step = 0; step < 50 && !row; step++) {
                            [list setContentOffset:offset animated:NO];
                            [list layoutIfNeeded];
                            row = titled(title, nil);
                            CGPoint next = clampedOffset(list, CGPointMake(offset.x, offset.y + list.bounds.size.height * 0.6));
                            if (CGPointEqualToPoint(next, offset)) break;
                            offset = next;
                        }
                    }
                    if (!row) fail(@"no row \"%@\" on this page", title);
                    if (list && [row isDescendantOfView:list]) {
                        CGRect frame = [row convertRect:row.bounds toView:list];
                        CGPoint offset = clampedOffset(list, CGPointMake(list.contentOffset.x, CGRectGetMidY(frame) - list.bounds.size.height / 2));
                        [list setContentOffset:offset animated:NO];
                        [list layoutIfNeeded];
                    }
                    return @{@"point" : [NSValue valueWithCGPoint:screenCenter(row)], @"target" : describe(row)};
                });
                return touchAt(where, 0.08);
            },
            @"get" : ^NSDictionary *(NSDictionary *p) {
                NSArray<NSString *> *steps = pathSteps(p);
                return onMain(^id {
                    id value = walk(pathRoot(p), steps);
                    return @{@"path" : p[@"path"], @"value" : plainValue(value), @"class" : NSStringFromClass([value class]) ?: @"nil"};
                });
            },
            @"set" : ^NSDictionary *(NSDictionary *p) {
                NSArray<NSString *> *steps = pathSteps(p);
                if (!p[@"value"]) fail(@"set takes --value (nil, true, false, a number, #RRGGBB[AA] or text)");
                return onMain(^id {
                    id target = walk(pathRoot(p), [steps subarrayWithRange:NSMakeRange(0, steps.count - 1)]);
                    NSString *key = steps.lastObject;
                    id before = nil;
                    @try { before = [target valueForKey:key]; } @catch (__unused NSException *e) {}
                    id value = typedValue(p[@"value"], target);
                    @try {
                        [CATransaction begin];
                        [CATransaction setDisableActions:YES];
                        [target setValue:value forKey:key];
                        [CATransaction commit];
                    } @catch (NSException *e) {
                        [CATransaction commit];
                        fail(@"%@ did not take %@: %@", NSStringFromClass([target class]), key, e.reason);
                    }
                    id after = nil;
                    @try { after = [target valueForKey:key]; } @catch (__unused NSException *e) {}
                    return @{@"on" : NSStringFromClass([target class]), @"key" : key, @"before" : plainValue(before), @"after" : plainValue(after)};
                });
            },
            // The layer tree under a view (--depth, 6 by default), or with --up 1 the chain of layers from it to the window.
            @"layers" : ^NSDictionary *(NSDictionary *p) {
                return onMain(^id {
                    id root = pathRoot(p);
                    if (p[@"path"]) root = walk(root, pathSteps(p));
                    CALayer *layer = [root isKindOfClass:UIView.class] ? ((UIView *)root).layer : root;
                    if (![layer isKindOfClass:CALayer.class]) fail(@"not a view or layer: %@", NSStringFromClass([root class]));
                    NSMutableArray<NSString *> *lines = [NSMutableArray array];
                    if ([p[@"up"] boolValue]) {
                        for (CALayer *l = layer; l; l = l.superlayer) [lines addObject:layerLine(l)];
                    } else {
                        dumpLayers(layer, 0, (NSUInteger)number(p, @"depth", 6), lines);
                    }
                    return @{@"layers" : lines};
                });
            },
        };
    });
    return all;
}

static NSSet<NSString *> *readOnly(void) {
    return [NSSet setWithArray:@[@"find", @"state", @"audit.controllers", @"screenshot", @"log", @"wait", @"get", @"layers", @"nav.trace.status", @"nav.trace.read"]];
}

BOOL SGDriverHandles(NSString *command) {
    return commands()[command] != nil;
}

// The screen stays on while the driver is in use, so a test does not end on a locked phone: each command holds
// the idle timer off for kAwakeFor, and the phone locks as usual once the commands stop.
static const NSTimeInterval kAwakeFor = 600;

static void stayAwake(void) {
    static NSUInteger sg_awake;   // main queue only
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger mine = ++sg_awake;
        UIApplication.sharedApplication.idleTimerDisabled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAwakeFor * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (mine == sg_awake) UIApplication.sharedApplication.idleTimerDisabled = NO;
        });
    });
}

NSData *SGDriverRun(NSString *command, NSDictionary<NSString *, NSString *> *params) {
    stayAwake();
    NSMutableDictionary *answer = [NSMutableDictionary dictionaryWithObject:command forKey:@"cmd"];
    if (![readOnly() containsObject:command]) sg_actionSeq = SGLogLastSeq();
    @try {
        [answer addEntriesFromDictionary:commands()[command](params) ?: @{}];
        answer[@"ok"] = @YES;
    } @catch (NSException *exception) {
        answer[@"ok"] = @NO;
        answer[@"error"] = exception.reason ?: exception.name;
    }
    NSData *json = [NSJSONSerialization isValidJSONObject:answer] ? [NSJSONSerialization dataWithJSONObject:answer options:0 error:nil] : nil;
    if (!json) json = [NSJSONSerialization dataWithJSONObject:@{@"cmd" : command, @"ok" : @NO, @"error" : @"the answer was not JSON"} options:0 error:nil];
    return json;
}
#endif
