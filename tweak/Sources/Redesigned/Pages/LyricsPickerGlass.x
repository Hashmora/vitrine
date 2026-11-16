// Lyrics stickers' search is a raw UITextField with an 8pt rectangle and the
// categories are Encore ChipsKit pills. Dress only this picker.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kLyricsSearch;

static void lyricsSearch(UIView *view) {
    if (!view.window) return;
    UIView *stack = SGRChildNamed(view, @"_TtCE19Encore_StackViewKitO16EncoreFoundation6Encore9StackView");
    UIView *field = SGRChildNamed(stack, @"UITextField");
    if (field && field.bounds.size.width > 30) SGRGlassFlatBox(field, &kLyricsSearch, NO);
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
