// Adopt actual UIButton.menu pull-down controls everywhere in the redesigned UI.
// The overlay takes their touches before UIKit can open its own menu controller.
// Long-press context menus and sheet navigation are intentionally not captured.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "SGRDropdownController.h"

static char kNativeDropdownOverlay, kNativeDropdownSuppressed;

// The owned renderer consumes concrete UIMenu/UIAction trees. UIKit's deferred
// providers are private to the native presentation; do not steal a button's
// primary action when its menu depends on one of those providers.
static BOOL hasDeferredProvider(UIMenu *menu, NSUInteger depth) {
    if (!menu || depth > 12) return YES;
    for (UIMenuElement *element in menu.children) {
        if ([element isKindOfClass:UIDeferredMenuElement.class]) return YES;
        if ([element isKindOfClass:UIMenu.class] && hasDeferredProvider((UIMenu *)element, depth + 1)) return YES;
    }
    return NO;
}

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
    if (!button.menu.children.count || hasDeferredProvider(button.menu, 0)) return NO;
    NSString *name = NSStringFromClass(button.class);
    if ([name hasPrefix:@"SGRMenu"] || [name hasPrefix:@"SGRDropdown"]) return NO;
    return YES;
}

static void updateNative(UIButton *button) {
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

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    %init;
}
