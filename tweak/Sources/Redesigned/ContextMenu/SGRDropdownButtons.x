// Adopt actual UIButton.menu pull-down controls everywhere in the redesigned UI.
// The overlay takes their touches before UIKit can open its own menu controller.
// Long-press context menus and sheet navigation are intentionally not captured.
#import <objc/runtime.h>
#import <objc/message.h>
#import "Core/SGCore.h"
#import "SGRDropdownController.h"
#import "SGRDropdownDeferred.h"

static char kNativeDropdownOverlay, kNativeDropdownSuppressed;

static char kDropdownAuditLastMenuKey, kDropdownAuditRecordCountKey;
static char kDropdownAuditOriginalConfigurationKey;

static NSString *sgrDropdownAuditPointer(id object) {
    return object ? [NSString stringWithFormat:@"%p", object] : @"";
}

static BOOL sgrDropdownAuditIsTextInput(UIView *view, id delegate) {
    NSString *viewName = NSStringFromClass(view.class);
    NSString *delegateName = delegate ? NSStringFromClass([delegate class]) : @"";
    return [view isKindOfClass:UITextView.class] ||
           [view isKindOfClass:UITextField.class] ||
           [viewName containsString:@"TextField"] ||
           [viewName containsString:@"TextView"] ||
           [delegateName containsString:@"TextContextMenu"];
}


// Diagnostics only: inventory each distinct UIButton.menu without changing
// the menu's ownership or whether UIKit is allowed to present it.
static NSString *sgrDropdownAuditOwner(UIView *view) {
    for (UIResponder *responder = view; responder; responder = responder.nextResponder)
        if ([responder isKindOfClass:UIViewController.class])
            return NSStringFromClass(responder.class);
    return @"";
}

static void sgrDropdownAuditElements(NSArray<UIMenuElement *> *elements, NSMutableDictionary *counts,
                                     NSMutableArray<NSString *> *titles, NSUInteger depth) {
    if (depth > 12) return;
    for (UIMenuElement *element in elements) {
        NSString *kind = [element isKindOfClass:UIDeferredMenuElement.class] ? @"deferred"
                       : [element isKindOfClass:UIMenu.class] ? @"submenu"
                       : [element isKindOfClass:UIAction.class] ? @"action" : @"other";
        counts[kind] = @([counts[kind] unsignedIntegerValue] + 1);
        if (titles.count < 12 && element.title.length)
            [titles addObject:[element.title substringToIndex:MIN(element.title.length, 72)]];
        if ([element isKindOfClass:UIMenu.class])
            sgrDropdownAuditElements(((UIMenu *)element).children, counts, titles, depth + 1);
    }
}

static void sgrDropdownAuditRecord(NSDictionary *event) {
    if (![NSJSONSerialization isValidJSONObject:event]) return;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:event options:0 error:NULL];
    if (!payload) return;
    SGLog(@"dropdown.provider.inventory %@", [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding]);
}

static void sgrDropdownAuditButton(UIButton *button) {
    if (!button || !button.menu || !button.window || !SGRedesignedUI() || !SGBelowiOS26()) return;
    UIMenu *menu = button.menu;
    NSValue *last = objc_getAssociatedObject(button, &kDropdownAuditLastMenuKey);
    if ([last isKindOfClass:NSValue.class] && [last nonretainedObjectValue] == menu) return;
    // A constantly reconstructed menu must not flood the driver's 100-line log.
    NSUInteger count = [objc_getAssociatedObject(button, &kDropdownAuditRecordCountKey) unsignedIntegerValue];
    if (count >= 6) return;
    objc_setAssociatedObject(button, &kDropdownAuditLastMenuKey,
                             [NSValue valueWithNonretainedObject:menu], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(button, &kDropdownAuditRecordCountKey, @(count + 1),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    sgrDropdownAuditElements(menu.children, counts, titles, 0);
    BOOL supported = SGRDropdownDeferredMenuSupported(menu, button);
    sgrDropdownAuditRecord(@{
        @"kind": @"button", @"class": NSStringFromClass(button.class),
        @"owner": sgrDropdownAuditOwner(button),
        @"id": button.accessibilityIdentifier ?: @"",
        @"label": button.accessibilityLabel ?: @"",
        @"menuTitle": menu.title ?: @"", @"titles": titles, @"elements": counts,
        @"primary": @(button.showsMenuAsPrimaryAction),
        @"alreadyOwned": @(objc_getAssociatedObject(button, &kNativeDropdownOverlay) != nil),
        @"supported": @(supported),
        @"reason": supported ? @"supported" :
            [counts[@"deferred"] unsignedIntegerValue] ? @"unresolved-deferred" : @"no-usable-children"
    });
}

// Stage 172: trace the actual configuration callback without replacing the
// menu model or presenting anything. Each delegate's original IMP is retained
// on the concrete class. For inherited implementations we install an override
// on the subclass; this avoids changing every instance of a UIKit superclass.
static id sgrDropdownAuditConfiguration(id delegate, SEL selector, id interaction, CGPoint location) {
    typedef id (*ConfigIMP)(id, SEL, id, CGPoint);
    ConfigIMP original = NULL;
    for (Class cls = object_getClass(delegate); cls; cls = class_getSuperclass(cls)) {
        NSValue *value = objc_getAssociatedObject((id)cls, &kDropdownAuditOriginalConfigurationKey);
        if (value) {
            original = (ConfigIMP)[value pointerValue];
            break;
        }
    }
    // Never synthesize an empty configuration. This should be unreachable:
    // we install the replacement only after saving its original implementation.
    if (!original) return nil;
    id configuration = original(delegate, selector, interaction, location);
    UIView *view = nil;
    SEL viewSelector = NSSelectorFromString(@"view");
    if ([interaction respondsToSelector:viewSelector])
        view = ((UIView *(*)(id, SEL))objc_msgSend)(interaction, viewSelector);
    if (sgrDropdownAuditIsTextInput(view, delegate)) return configuration;
    id actionProvider = nil;
    if ([configuration respondsToSelector:@selector(actionProvider)])
        actionProvider = ((id (*)(id, SEL))objc_msgSend)(configuration, @selector(actionProvider));
    sgrDropdownAuditRecord(@{
        @"kind": @"configuration",
        @"class": view ? NSStringFromClass(view.class) : @"",
        @"owner": view ? sgrDropdownAuditOwner(view) : @"",
        @"id": view.accessibilityIdentifier ?: @"",
        @"label": view.accessibilityLabel ?: @"",
        @"delegate": NSStringFromClass([delegate class]),
        @"interaction": NSStringFromClass([interaction class]),
        @"interactionPointer": sgrDropdownAuditPointer(interaction),
        @"anchorPointer": sgrDropdownAuditPointer(view),
        @"hasConfiguration": @(configuration != nil),
        @"hasActionProvider": @(actionProvider != nil),
        @"configurationClass": configuration ? NSStringFromClass([configuration class]) : @""
    });
    return configuration;
}

static void sgrDropdownAuditHookDelegate(id delegate) {
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    if (!cls) return;
    // Never swizzle UIKit's own generic delegates globally. We only need
    // app-specific menu configuration callbacks, not system text/edit menus.
    NSString *delegateClassName = NSStringFromClass(cls);
    if ([delegateClassName hasPrefix:@"UI"] ||
        [delegateClassName hasPrefix:@"_UI"]) return;
    SEL selector = @selector(contextMenuInteraction:configurationForMenuAtLocation:);
    Method inheritedOrOwn = class_getInstanceMethod(cls, selector);
    if (!inheritedOrOwn) return;
    IMP original = method_getImplementation(inheritedOrOwn);
    if (original == (IMP)sgrDropdownAuditConfiguration) return;
    if (objc_getAssociatedObject((id)cls, &kDropdownAuditOriginalConfigurationKey)) return;
    const char *signature = method_getTypeEncoding(inheritedOrOwn);
    // Record before replacing; the wrapper can always find the original.
    objc_setAssociatedObject((id)cls, &kDropdownAuditOriginalConfigurationKey,
                             [NSValue valueWithPointer:(void *)original],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!class_addMethod(cls, selector, (IMP)sgrDropdownAuditConfiguration, signature)) {
        Method ownMethod = class_getInstanceMethod(cls, selector);
        method_setImplementation(ownMethod, (IMP)sgrDropdownAuditConfiguration);
    }
    sgrDropdownAuditRecord(@{
        @"kind": @"delegate-hook",
        @"delegate": NSStringFromClass(cls),
        @"selector": NSStringFromSelector(selector)
    });
}

// Only adopt menus whose deferred providers were captured at construction.
// Unsupported providers keep native presentation instead of an empty panel.
@interface SGRDropdownNativeOverlay : UIControl
@property (nonatomic, weak) UIButton *sourceButton;
@end
@implementation SGRDropdownNativeOverlay
@end

@interface SGRDropdownNativeTarget : NSObject
+ (instancetype)shared;
- (void)open:(SGRDropdownNativeOverlay *)overlay;
@end
@implementation SGRDropdownNativeTarget
+ (instancetype)shared {
    static SGRDropdownNativeTarget *target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ target = [SGRDropdownNativeTarget new]; });
    return target;
}
- (void)open:(SGRDropdownNativeOverlay *)overlay {
    UIButton *button = overlay.sourceButton;
    UIMenu *menu = button.menu;
    if (!button.window || !menu || SGRDropdownIsPresentingFrom(button)) return;
    SGRDropdownPresent(button, menu, ^(UIMenuElement *element) {
        if (element) SGRDropdownPerformAction(element);
    });
}
@end

static BOOL eligible(UIButton *button) {
    if (!SGRedesignedUI() || !SGBelowiOS26() || !button.menu || !button.window.windowScene) return NO;
    if (!button.menu.children.count || !SGRDropdownDeferredMenuSupported(button.menu, button)) return NO;
    NSString *name = NSStringFromClass(button.class);
    if ([name hasPrefix:@"SGRMenu"] || [name hasPrefix:@"SGRDropdown"]) return NO;
    return YES;
}

static void updateNative(UIButton *button) {
    sgrDropdownAuditButton(button);
    SGRDropdownNativeOverlay *overlay = objc_getAssociatedObject(button, &kNativeDropdownOverlay);
    if (!eligible(button)) {
        if (overlay) {
            [overlay removeFromSuperview];
            objc_setAssociatedObject(button, &kNativeDropdownOverlay, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (objc_getAssociatedObject(button, &kNativeDropdownSuppressed)) {
            objc_setAssociatedObject(button, &kNativeDropdownSuppressed, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            // Restore the primary-action behavior for unsupported deferred menus
            // and for buttons whose menus were removed or replaced.
            button.showsMenuAsPrimaryAction = YES;
        }
        return;
    }
    // A menu that is not configured as the button's primary action is likely
    // a long-press context menu. Only adopt genuine pull-down buttons.
    if (!overlay && !button.showsMenuAsPrimaryAction) return;
    if (!overlay) {
        overlay = [SGRDropdownNativeOverlay new];
        overlay.sourceButton = button;
        overlay.backgroundColor = UIColor.clearColor;
        overlay.isAccessibilityElement = YES;
        overlay.accessibilityTraits = UIAccessibilityTraitButton;
        [overlay addTarget:[SGRDropdownNativeTarget shared] action:@selector(open:) forControlEvents:UIControlEventTouchDown];
        objc_setAssociatedObject(button, &kNativeDropdownOverlay, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Disable the system primary-action menu, not the button's command model.
    // Its overlaid control now owns opening and dismissal.
    if (button.showsMenuAsPrimaryAction) {
        objc_setAssociatedObject(button, &kNativeDropdownSuppressed, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        button.showsMenuAsPrimaryAction = NO;
    }
    if (overlay.superview != button) [button addSubview:overlay];
    else [button bringSubviewToFront:overlay];
    overlay.frame = button.bounds;
    overlay.accessibilityLabel = button.accessibilityLabel ?: @"Menu";
    overlay.enabled = button.enabled;
}


// UIContextMenuInteraction-backed buttons do not necessarily expose
// UIButton.menu. Record those attachment sites separately; do not hijack
// the interaction or invoke its Spotify delegate.
%hook UIView
- (void)addInteraction:(id<UIInteraction>)interaction {
    %orig;
    NSString *name = NSStringFromClass(interaction.class);
    if (![name containsString:@"ContextMenu"] && ![name containsString:@"EditMenu"]) return;
    id delegate = nil;
    SEL selector = @selector(delegate);
    if ([interaction respondsToSelector:selector]) {
        @try {
            delegate = ((id (*)(id, SEL))objc_msgSend)(interaction, selector);
        } @catch (__unused NSException *exception) {}
    }
    // Text editing interactions are not Spotify dropdowns. The Stage 170
    // buffer was dominated by them, obscuring actual menu entrypoints.
    if (sgrDropdownAuditIsTextInput(self, delegate)) return;
    if ([interaction isKindOfClass:UIContextMenuInteraction.class])
        sgrDropdownAuditHookDelegate(delegate);
    sgrDropdownAuditRecord(@{
        @"kind": @"interaction", @"interaction": name,
        @"interactionPointer": sgrDropdownAuditPointer(interaction),
        @"anchorPointer": sgrDropdownAuditPointer(self),
        @"class": NSStringFromClass(self.class),
        @"owner": sgrDropdownAuditOwner(self),
        @"id": self.accessibilityIdentifier ?: @"",
        @"label": self.accessibilityLabel ?: @"",
        @"delegate": delegate ? NSStringFromClass([delegate class]) : @""
    });
}
%end

%hook UIButton
- (void)didMoveToWindow {
    %orig;
    // Some Spotify buttons attach a ready-made menu after their last layout.
    // Recheck on window attachment rather than waiting for another resize.
    updateNative((UIButton *)self);
}
- (void)layoutSubviews {
    %orig;
    updateNative((UIButton *)self);
}
- (void)setMenu:(UIMenu *)menu {
    %orig;
    [self setNeedsLayout];
}
- (void)setShowsMenuAsPrimaryAction:(BOOL)showsMenuAsPrimaryAction {
    %orig;
    if (showsMenuAsPrimaryAction) [self setNeedsLayout];
}
%end

// A Spotify menu can also be a dedicated presented controller, rather than
// UIButton.menu or UIContextMenuInteraction. Record such presentations; don't
// replace or intercept their lifecycle.
%hook UIViewController
- (void)presentViewController:(UIViewController *)presented animated:(BOOL)animated
                  completion:(void (^)(void))completion {
    NSString *name = presented ? NSStringFromClass(presented.class) : @"";
    NSString *lower = name.lowercaseString;
    // Stage 172 filtered out dedicated picker controllers (including
    // SPTSortingFilteringPickerViewController). Record them as a DIFFERENT
    // category from dropdowns instead of silently losing the transition.
    BOOL picker = [lower containsString:@"picker"] || [lower containsString:@"sorting"];
    if (([lower containsString:@"menu"] ||
         [lower containsString:@"popover"] ||
         [lower containsString:@"actioncontroller"] || picker) &&
        ![lower containsString:@"text"]) {
        sgrDropdownAuditRecord(@{
            @"kind": picker ? @"picker-presentation" : @"presentation",
            @"class": name,
            @"owner": NSStringFromClass(self.class),
            @"presenterPointer": sgrDropdownAuditPointer(self),
            @"presentedPointer": sgrDropdownAuditPointer(presented),
            @"style": @(presented.modalPresentationStyle),
            @"animated": @(animated)
        });
    }
    %orig;
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    %init;
}
