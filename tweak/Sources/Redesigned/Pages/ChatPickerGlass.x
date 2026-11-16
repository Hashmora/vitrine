// The chat's Add content sheet builds its SearchQueryElementUI apart from its
// filter chips. Both must be dressed after Spotify lays out each element.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kEntityField, kEntityCancel;

static void entitySearch(UIView *search) {
    if (!search.window) return;
    UIView *stack = SGRChildNamed(search, @"_TtCE19Encore_StackViewKitO16EncoreFoundation6Encore9StackView");
    UIView *field = SGRChildNamed(stack, @"UITextField");
    if (!field) {
        // Some app versions put the UITextField directly under the element.
        field = SGRChildNamed(search, @"UITextField");
    }
    if (!field || field.bounds.size.width < 30) return;
    SGRGlassFillBox(field, &kEntityField, YES);
    // The field is a 40pt rectangular UITextField and repaints its own
    // 10%-white fill when focused. Clear it persistently, not just once.
    if (field.backgroundColor && field.backgroundColor != UIColor.clearColor)
        field.backgroundColor = UIColor.clearColor;
    SGRHoldClear(field);
    // Cancel is only laid out when the field becomes first responder.
    __block UIView *cancel = nil;
    SGForEachView(search, ^(UIView *v) {
        if ([v.accessibilityLabel isEqualToString:@"Cancel"] &&
            [v.accessibilityIdentifier isEqualToString:@"Encore.Button.Tertiary"]) cancel = v;
    });
    if (cancel && cancel.bounds.size.width > 1 && !cancel.hidden) {
        SGRUnclipUpTo(cancel, ^BOOL(UIView *v) { return v == search; });
        SGRGlassFlatBox(cancel, &kEntityCancel, YES);
    }
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class search = SGRSwiftClass(@"Campfire_ChatEntityPickerPageImpl", @"SearchQueryElementUI");
    if (search) SGRPassView(search, ^(UIView *view) { entitySearch(view); });
    // The search element frequently changes its field without relaying out
    // itself. Follow UITextField's own layout, scoped to this exact picker.
    SGRPassView(UITextField.class, ^(UIView *v) {
        for (UIView *up = v.superview; up && ![up isKindOfClass:UIWindow.class]; up = up.superview) {
            if ([NSStringFromClass(up.class) containsString:@"Campfire_ChatEntityPickerPageImpl.SearchQueryElementUI"]) {
                entitySearch(up);
                return;
            }
        }
    });
    SGRPassSwiftController(@"Campfire_ChatEntityPickerPageImpl", @"ChatEntityPickerViewController", ^(UIViewController *c) {
        if (c.viewIfLoaded.window) {
            SGRGlassChipsIn(c.viewIfLoaded);
            __block UIView *searchRoot = nil;
            SGForEachView(c.viewIfLoaded, ^(UIView *v) {
                if (!searchRoot && [NSStringFromClass(v.class) containsString:@"Campfire_ChatEntityPickerPageImpl.SearchQueryElementUI"])
                    searchRoot = v;
            });
            if (searchRoot) entitySearch(searchRoot);
        }
    });
}
