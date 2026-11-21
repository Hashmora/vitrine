// Adopt actual UIButton.menu pull-down controls everywhere in the redesigned UI.
// The overlay takes their touches before UIKit can open its own menu controller.
// Long-press context menus and sheet navigation are intentionally not captured.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "SGRDropdownController.h"

static char kNativeDropdownOverlay;

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
    if (!SGRedesignedUI() || !SGBelowiOS26() || !button.menu) return NO;
    NSString *name = NSStringFromClass(button.class);
    if ([name hasPrefix:@"SGRMenu"] || [name hasPrefix:@"SGRDropdown"]) return NO;
    return YES;
}

static void updateNative(UIButton *button) {
    SGRDropdownNativeOverlay *overlay = objc_getAssociatedObject(button, &kNativeDropdownOverlay);
    if (!eligible(button)) {
        if (overlay) { [overlay removeFromSuperview]; objc_setAssociatedObject(button, &kNativeDropdownOverlay, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
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
    if (button.showsMenuAsPrimaryAction) button.showsMenuAsPrimaryAction = NO;
    if (overlay.superview != button) [button addSubview:overlay];
    else [button bringSubviewToFront:overlay];
    overlay.frame = button.bounds;
    overlay.accessibilityLabel = button.accessibilityLabel ?: @"Menu";
    overlay.enabled = button.enabled;
}

%hook UIButton
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
