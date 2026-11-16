// The standalone artist About page below iOS 26 should follow the same glass navigation
// and card styling as the other redesigned legacy pages: no opaque navigation strip, a
// white title in a glass pill, and the rank / listeners / biography / facts blocks on glass.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Pages/PageBar.h"

static char kAboutPageCardKey;

static BOOL isGrey(CGColorRef color) {
    if (!color || CGColorGetAlpha(color) < 0.95 || CGColorGetNumberOfComponents(color) < 3) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    return c[0] > 0.12 && c[0] < 0.22 && fabs(c[0] - c[1]) < 0.02 && fabs(c[1] - c[2]) < 0.02;
}

static void dressCard(UIView *card, CGFloat radius) {
    if (!card || card.bounds.size.width < 1 || card.bounds.size.height < 1) return;
    if (isGrey(card.layer.backgroundColor) || (card.backgroundColor && CGColorGetAlpha(card.backgroundColor.CGColor) > 0.05))
        card.backgroundColor = UIColor.clearColor;
    if (card.layer.backgroundColor && isGrey(card.layer.backgroundColor)) card.layer.backgroundColor = NULL;
    card.layer.cornerRadius = radius;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    SGRGlassPaneIn(card, &kAboutPageCardKey, radius);
    for (UIView *sub in card.subviews) {
        if (isGrey(sub.layer.backgroundColor)) sub.backgroundColor = UIColor.clearColor;
    }
}

static void dressPage(UIView *root) {
    if (!root.window) return;
    SGForEachView(root, ^(UIView *view) {
        NSString *identifier = view.accessibilityIdentifier ?: @"";
        NSString *name = NSStringFromClass(view.class);
        if ([identifier isEqualToString:@"ArtistFactsView.Card"]) {
            dressCard(view, view.layer.cornerRadius > 0 ? view.layer.cornerRadius : 16);
        } else if ([identifier isEqualToString:@"artist-about-rank"] || [identifier isEqualToString:@"artist-about-listeners"] ||
                   [name isEqualToString:@"SPTArtistAboutBiographyView"]) {
            dressCard(view, view.layer.cornerRadius > 0 ? view.layer.cornerRadius : 16);
        }
    });
}

%hook SPTArtistAboutViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController *page = (UIViewController *)self;
    SGRDressBarPage(page);
    dressPage(page.view);
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    %init;
}
