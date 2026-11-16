// Lyrics stickers' search is a raw UITextField with an 8pt rectangle and the
// categories are Encore ChipsKit pills. Dress only this picker.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kLyricsSearch, kLyricsCancel;

static void lyricsSearch(UIView *view) {
    if (!view.window) return;
    UIView *stack = SGRChildNamed(view, @"_TtCE19Encore_StackViewKitO16EncoreFoundation6Encore9StackView");
    UIView *field = SGRChildNamed(stack, @"UITextField");
    if (field && field.bounds.size.width > 30) SGRGlassFlatBox(field, &kLyricsSearch, NO);
    __block UIView *cancel = nil;
    SGForEachView(view, ^(UIView *v) {
        if ([v.accessibilityIdentifier isEqualToString:@"Encore.Button.Tertiary"] &&
            [v.accessibilityLabel isEqualToString:@"Cancel"]) cancel = v;
    });
    if (cancel && cancel.bounds.size.width > 1 && !cancel.hidden) {
        SGRUnclipUpTo(cancel, ^BOOL(UIView *v) { return v == view; });
        SGRGlassCapsuleInside(cancel, &kLyricsCancel,
                              CGSizeMake(cancel.bounds.size.width + 12, 40), NO);
    }
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class field = SGRSwiftClass(@"Stickers_LyricsStickersPageImpl", @"LyricsStickerSearchElementUI");
    if (field) SGRPassView(field, ^(UIView *view) { lyricsSearch(view); });
    Class chips = SGRSwiftClass(@"Stickers_LyricsStickersPageImpl", @"FilterChipsView");
    if (chips) SGRPassView(chips, ^(UIView *view) {
        if (view.window) SGRGlassChipsIn(view);
    });
}
