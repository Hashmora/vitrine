// Lyrics stickers' search is a raw UITextField with an 8pt rectangle and the
// categories are Encore ChipsKit pills. Dress only this picker.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kLyricsSearch, kLyricsCancel;

static void lyricsSearch(UIView *view) {
    if (!view.window) return;
    UIView *stack = SGRChildNamed(view, @"_TtCE19Encore_StackViewKitO16EncoreFoundation6Encore9StackView");
    UIView *field = SGRChildNamed(stack, @"UITextField");
    if (field && field.bounds.size.width > 30) {
        SGRGlassFillBox(field, &kLyricsSearch, YES);
        if (field.backgroundColor && field.backgroundColor != UIColor.clearColor)
            field.backgroundColor = UIColor.clearColor;
        SGRHoldClear(field);
    }
    __block UIView *cancel = nil;
    SGForEachView(view, ^(UIView *v) {
        if ([v.accessibilityIdentifier isEqualToString:@"Encore.Button.Tertiary"] &&
            [v.accessibilityLabel isEqualToString:@"Cancel"]) cancel = v;
    });
    if (cancel && cancel.bounds.size.width > 1 && !cancel.hidden) {
        SGRUnclipUpTo(cancel, ^BOOL(UIView *v) { return v == view; });
        SGRGlassFlatBox(cancel, &kLyricsCancel, YES);
    }
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class field = SGRSwiftClass(@"Stickers_LyricsStickersPageImpl", @"LyricsStickerSearchElementUI");
    if (field) SGRPassView(field, ^(UIView *view) { lyricsSearch(view); });
    // The sticker picker is a separate child of the content picker; the
    // search and chips appear after the hosting navigation page has settled.
    SGRPassSwiftController(@"Stickers_LyricsStickersPageImpl", @"LyricsStickersViewController", ^(UIViewController *c) {
        UIView *root = c.viewIfLoaded;
        if (!root.window) return;
        SGRGlassChipsIn(root);
        __block UIView *search = nil;
        SGForEachView(root, ^(UIView *v) {
            if (!search && [NSStringFromClass(v.class) containsString:@"Stickers_LyricsStickersPageImpl.LyricsStickerSearchElementUI"])
                search = v;
        });
        if (search) lyricsSearch(search);
    });
    SGRPassView(UITextField.class, ^(UIView *v) {
        for (UIView *up = v.superview; up && ![up isKindOfClass:UIWindow.class]; up = up.superview) {
            if ([NSStringFromClass(up.class) containsString:@"Stickers_LyricsStickersPageImpl.LyricsStickerSearchElementUI"]) {
                lyricsSearch(up);
                return;
            }
        }
    });
    Class chips = SGRSwiftClass(@"Stickers_LyricsStickersPageImpl", @"FilterChipsView");
    if (chips) SGRPassView(chips, ^(UIView *view) {
        // The first layout happens before presentation. Do not wait for
        // didMoveToWindow or for the user to scroll the horizontal strip.
        SGRGlassChipsIn(view);
    });
    // Spotify creates and updates individual filters after FilterChipsView's
    // own layout. Dress every newly inserted chip immediately, including its
    // selected (green) pill, so SGRRepaint can follow later color changes.
    Class chip = NSClassFromString(@"_TtCE15Encore_ChipsKitO16EncoreFoundation6Encore8ChipView");
    if (chip) SGRPassView(chip, ^(UIView *view) {
        for (UIView *parent = view.superview; parent && ![parent isKindOfClass:UIWindow.class]; parent = parent.superview) {
            if ([NSStringFromClass(parent.class) containsString:@"Stickers_LyricsStickersPageImpl.FilterChipsView"]) {
                SGRGlassChipsIn(view);
                break;
            }
        }
    });
}
