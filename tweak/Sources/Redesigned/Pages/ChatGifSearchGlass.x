// The GIF picker differs from the two other chat pickers: its Clear search
// button is embedded in the same UITextField, not a trailing Cancel control.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kGifField, kGifClear;

static void glassGifSearch(UIView *view) {
    if (!view.window) return;
    UIView *field = SGRChildNamed(view, @"UITextField");
    if (!field || field.bounds.size.height < 20) return;
    SGRGlassFillBox(field, &kGifField, YES);
    if (field.backgroundColor && field.backgroundColor != UIColor.clearColor)
        field.backgroundColor = UIColor.clearColor;
    SGRHoldClear(field);
    __block UIView *clear = nil;
    SGForEachView(field, ^(UIView *v) {
        if ([v.accessibilityLabel isEqualToString:@"Clear search text"] &&
            [v.accessibilityIdentifier isEqualToString:@"Encore.Button.Tertiary"]) clear = v;
    });
    if (clear && clear.bounds.size.width > 1 && !clear.hidden) {
        SGRUnclipUpTo(clear, ^BOOL(UIView *v) { return v == view; });
        SGRGlassInside(clear, &kGifClear, 32);
    }
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class search = SGRSwiftClass(@"Campfire_ChatGifPickerPageImpl", @"ChatGifSearchElementUI");
    if (search) SGRPassView(search, ^(UIView *view) { glassGifSearch(view); });
    SGRPassView(UITextField.class, ^(UIView *v) {
        for (UIView *up = v.superview; up && ![up isKindOfClass:UIWindow.class]; up = up.superview) {
            if ([NSStringFromClass(up.class) containsString:@"Campfire_ChatGifPickerPageImpl.ChatGifSearchElementUI"]) {
                glassGifSearch(up);
                return;
            }
        }
    });
}
