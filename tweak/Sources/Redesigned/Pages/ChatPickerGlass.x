// The chat's Add content sheet builds its SearchQueryElementUI apart from its
// filter chips. Both must be dressed after Spotify lays out each element.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kEntityField;

static void entitySearch(UIView *search) {
    if (!search.window) return;
    UIView *stack = SGRChildNamed(search, @"_TtCE19Encore_StackViewKitO16EncoreFoundation6Encore9StackView");
    UIView *field = SGRChildNamed(stack, @"UITextField");
    if (!field) {
        // Some app versions put the UITextField directly under the element.
        field = SGRChildNamed(search, @"UITextField");
    }
    if (!field || field.bounds.size.width < 30) return;
    SGRGlassFlatBox(field, &kEntityField, NO);
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class search = SGRSwiftClass(@"Campfire_ChatEntityPickerPageImpl", @"SearchQueryElementUI");
    if (search) SGRPassView(search, ^(UIView *view) { entitySearch(view); });
    SGRPassSwiftController(@"Campfire_ChatEntityPickerPageImpl", @"ChatEntityPickerViewController", ^(UIViewController *c) {
        if (c.viewIfLoaded.window) SGRGlassChipsIn(c.viewIfLoaded);
    });
}
