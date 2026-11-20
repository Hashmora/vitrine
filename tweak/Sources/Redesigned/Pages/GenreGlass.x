// Browse > Genres has a custom floating heading, not a UINavigationBar title.
// The page's Share/Back actions stay Spotify's, with glass behind their glyphs.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kTitleGlass, kShareGlass;

static void dress(UIViewController *page) {
    if (!page.viewIfLoaded.window) return;
    SGRDressBarPageBackOnly(page);
    UIView *content = SGRChildNamed(page.navigationController.navigationBar, @"_UINavigationBarContentView");
    UIView *trailing = SGRBarStackButton(content, NO);
    UIView *button = SGRChildNamed(trailing, @"_UIModernBarButton");
    if (button.bounds.size.width > 1) {
        SGRUnclipUpTo(button, ^BOOL(UIView *v) { return v.superview == page.navigationController.navigationBar; });
        SGRGlassInside(button, &kShareGlass, 44);
    }
    // The compact sticky title is vertically independent of the pinned Back.
    // Align their visual centres instead of assuming Spotify's 65pt label
    // position matches the 62pt/44pt glass Back at every screen size.
    __block UIView *pinnedBack = nil;
    SGForEachView(page.viewIfLoaded, ^(UIView *item) {
        if (!pinnedBack && [item isKindOfClass:SGRMirrorButton.class] &&
            [item.accessibilityLabel isEqualToString:@"Back"] &&
            fabs(item.bounds.size.height - 44) < 2) pinnedBack = item;
    });
    SGForEachView(page.viewIfLoaded, ^(UIView *view) {
        if (![NSStringFromClass(view.class) hasSuffix:@"HeaderView"] ||
            ![NSStringFromClass(view.class) containsString:@"Browse_GenrePageImpl"]) return;
        if (view.backgroundColor && SGIsBaseSurface(view.layer.backgroundColor)) {
            view.backgroundColor = UIColor.clearColor;
            view.layer.backgroundColor = NULL;
            SGRHoldClear(view);
        }
        for (UIView *sub in view.subviews) {
            if ([NSStringFromClass(sub.class) containsString:@"GradientFillView"]) {
                SGRConceal(sub);
            }
        }
        // On Spotify 9.1.90 the compact sticky HeaderView is 98pt high
        // (Stage 38 tree), not <=96pt. The expanded 144.67pt header still
        // carries the 32pt title and must not receive a second capsule.
        if (view.bounds.size.height > 120) return;
        SGForEachView(view, ^(UIView *label) {
            if (![NSStringFromClass(label.class) hasSuffix:@"EncoreLabel"] || label.bounds.size.height > 25) return;
            UILabel *text = (UILabel *)SGRChildNamed(label, @"UILabel");
            if (![text.text isEqualToString:@"Genres"]) return;
            if (label.hidden || label.alpha < 0.05) return;
            // Measure an unshifted label on each pass: UIKit can move the
            // sticky header while scrolling and repeated passes must not
            // accumulate translations.
            label.transform = CGAffineTransformIdentity;
            if (pinnedBack) {
                CGFloat backY = CGRectGetMidY([pinnedBack convertRect:pinnedBack.bounds toView:page.viewIfLoaded]);
                CGFloat titleY = CGRectGetMidY([label convertRect:label.bounds toView:page.viewIfLoaded]);
                CGFloat delta = round(backY - titleY);
                if (fabs(delta) < 24) label.transform = CGAffineTransformMakeTranslation(0, delta);
            }
            SGRGlassTitleCapsule(label, &kTitleGlass, SGRTitleWidth(text), label.bounds.size.width, ^BOOL(UIView *v) { return v == view; });
        });
    });
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class genre = SGRSwiftClass(@"Browse_GenrePageImpl", @"GenrePageViewController");
    if (genre) SGRDressBarPagesWith(genre, YES, ^(UIViewController *c) { dress(c); });
}
