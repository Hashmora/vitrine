// Playlist, album and artist redesign, iOS < 26: the navigation bar Spotify slides in as the page scrolls
// (HeaderNavigationBar, about 103pt). It holds a gradient in the page's colour under the pinned Back and ⋯
// buttons and the page's name in an SPTEncoreLabel. Here the page has no bar: the gradient goes and the name sits
// on a glass capsule of the same material as the buttons.
//
// The gradient is concealed on every pass of the bar's own layout and window callbacks, because Spotify draws it
// again after PlaylistHeader.x's single pass. The capsule is a child of the name label (SGRGlassCapsuleInside), so
// it follows the label's alpha and position.
//
// Liked Songs keeps Spotify's bar (the page model says which it is: formatListType). The album and artist bars are
// the same class under other ids. A bar is recognised by its page having been dressed, i.e. SGRPinnedBack pinned
// its Back button; a podcast episode shares the album template and is left alone.
//
// The scrims themselves are refused at the class: a mask or a hidden written once is undone by Spotify (-setHidden:NO
// as the page scrolls), and an album's or an artist's showed as a band under the name and behind the header, where a
// playlist's own had none. So a GradientView on a dressed playlist, album or artist page, outside the page's list
// rows, refuses to be shown, whoever asks.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Playlist.h"
#import "Redesigned/Album/Album.h"
#import "Redesigned/Artist/Artist.h"
#import "Redesigned/Profile/Profile.h"
#import "Redesigned/Pages/Pages.h"
#import <objc/message.h>

static char kBubbleKey;

// A scrim taken out of sight by an empty mask, never `hidden` (which crashes in Encore's stacks) nor alpha (which Spotify
// writes as the page scrolls).
static void maskAway(UIView *view) {
    if (view.layer.mask && CGRectIsEmpty(view.layer.mask.bounds)) return;
    view.layer.mask = [CALayer layer];
}

static BOOL isDressedPage(UIView *bar);
static BOOL isPremiumBar(UIView *bar) {
    return [bar.accessibilityIdentifier isEqualToString:@"PremiumDestinationPage.HeaderNavigationBar"];
}


static BOOL isLikedSongs(UIViewController *headerVC) {
    SEL controllerSel = NSSelectorFromString(@"headerController"), modelSel = NSSelectorFromString(@"defaultHeaderViewModel"),
        typeSel = NSSelectorFromString(@"formatListType");
    if (![headerVC respondsToSelector:controllerSel]) return NO;
    id controller = ((id (*)(id, SEL))objc_msgSend)(headerVC, controllerSel);
    if (![controller respondsToSelector:modelSel]) return NO;
    id model = ((id (*)(id, SEL))objc_msgSend)(controller, modelSel);
    if (![model respondsToSelector:typeSel]) return NO;
    id type = ((id (*)(id, SEL))objc_msgSend)(model, typeSel);
    return [type isKindOfClass:NSString.class] && [type isEqualToString:@"liked-songs"];
}

// A GradientView of a page the redesign dresses -- playlist (Liked Songs apart), album, artist, profile, Live Events gallery -- that is not
// inside one of the list's cells: the wash behind the header, the header's own fade and the bar's scrim.
static BOOL isPageScrim(UIView *view) {
    for (UIView *v = view.superview; v; v = v.superview) {
        if ([v isKindOfClass:UICollectionViewCell.class] || [v isKindOfClass:UITableViewCell.class]) return NO;
    }
    UIViewController *headerVC = SGRPlaylistHeaderOf(view);
    if (headerVC) return !isLikedSongs(headerVC);
    // A dressed profile's wash (the HeaderView's GradientView, still #000 at 57% over the header) and the bar's scrim go
    // the same way, and so do the two of a Live Events gallery page (Pages/LiveEvents.x).
    return isDressedPage(view) || SGRGalleryPageOf(view) != nil;
}

// The name: the one SPTEncoreLabel directly under the bar that holds text (the Back button's is a glyph
// in a button of its own, deeper down).
static UIView *titleIn(UIView *bar, UILabel **text) {
    for (UIView *sub in bar.subviews) {
        if (![NSStringFromClass(sub.class) hasSuffix:@"EncoreLabel"]) continue;
        for (UIView *inner in sub.subviews) {
            if ([inner isKindOfClass:UILabel.class] && ((UILabel *)inner).text.length) {
                if (text) *text = (UILabel *)inner;
                return sub;
            }
        }
    }
    return nil;
}

// An album's, an artist's or a profile's bar, once the redesign has pinned its Back on the page: that button is a direct
// subview of the page's root, which only the pages dressed in AlbumHeader.x, ArtistHeader.x and ProfileHeader.x get.
static BOOL isDressedPage(UIView *bar) {
    UIView *page = SGRAlbumPageOf(bar) ?: SGRArtistPageOf(bar) ?: SGRProfilePageOf(bar);
    return SGRPinnedBackIn(page) != nil;
}

// Whether this bar is one the redesign dresses: a playlist's (Liked Songs apart), a dressed album's or artist's.
static BOOL handles(UIView *bar) {
    UIViewController *headerVC = SGRPlaylistHeaderOf(bar);
    return isPremiumBar(bar) || (headerVC ? !isLikedSongs(headerVC) : isDressedPage(bar));
}

static void apply(UIView *bar) {
    if (!handles(bar)) return;
    if (isPremiumBar(bar)) {
        // The premium destination is an Element page, not an FTP playlist controller.
        // Its header has the same Back identifier, title label and gradient.
        UIView *back = SGRFindByIdentifier(bar, @"Components.Header.UI.BackButton", NULL);
        if (back) {
            SGRPinnedBackOf(bar, back);
            SGRUnclipUpTo(bar, ^BOOL(UIView *v) { return v.superview == bar.window; });
        }
    }

    for (UIView *sub in bar.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"GradientView"]) maskAway(sub);
    }
    if (SGIsVisibleColor(bar.layer.backgroundColor)) bar.backgroundColor = UIColor.clearColor;

    UILabel *text = nil;
    UIView *title = titleIn(bar, &text);
    if (!title || title.bounds.size.width < 1) return;
    // Spotify centres the name in the 64pt below the bar's top, 2pt under the pinned buttons' middle. The
    // label is moved by a transform, which Auto Layout never writes -- but the bar's layout may set the label's
    // frame, and a frame set under a transform moves the centre by the transform's opposite, so the move was
    // worked out from a centre it had itself displaced and grew with every pass until it was dropped as too
    // large, leaving the name where Spotify had it, 2pt low. The layout hook below puts the transform back to
    // identity before Spotify lays out, so what is read here is always the layout's own centre, and the move
    // is written only then: a pass of ours with a move on already (didMoveToWindow, a gradient added) leaves it.
    // Recompute from Spotify's *untransformed* layout every pass. Earlier
    // versions only applied a shift when transform was identity: the first
    // premature call could leave an old shift stuck for the rest of a scroll.
    CGAffineTransform before = title.transform;
    BOOL translationOnly = fabs(before.a - 1) < 0.001 && fabs(before.d - 1) < 0.001 &&
        fabs(before.b) < 0.001 && fabs(before.c) < 0.001;
    if (!translationOnly) return;
    if (!CGAffineTransformIsIdentity(before)) title.transform = CGAffineTransformIdentity;
    CGFloat middle = [title.superview convertPoint:title.center toView:nil].y;
    CGFloat target = bar.window.safeAreaInsets.top + SGRGlassCircleSize / 2;
    BOOL pinnedArtist = NO;
    UIView *artistPage = SGRArtistPageOf(bar);
    SGRMirrorButton *back = SGRPinnedBackIn(artistPage);
    if (back.window && back.superview && !back.hidden) {
        target = [back.superview convertPoint:back.center toView:nil].y;
        pinnedArtist = YES;
    }
    CGFloat shift = target - middle;
    CGFloat limit = pinnedArtist ? 52 : 20;
    if (fabs(shift) > 0.5 && fabs(shift) < limit) {
        title.transform = CGAffineTransformMakeTranslation(0, shift);
        if (pinnedArtist) {
            // The 64pt title holder moved down inside a 100pt bar can extend
            // ~6pt below it. Never cut its 44pt glass at the bottom edge.
            SGRUnclipUpTo(title, ^BOOL(UIView *v) { return v == bar; });
        }
    }
    SGRGlassTitleCapsule(title, &kBubbleKey, SGRTitleWidth(text), title.bounds.size.width, nil);
}

%hook _TtC28EncoreConsumerMobile_BaseKit19HeaderNavigationBar
- (void)layoutSubviews {
    UIView *bar = (UIView *)self;
    if (handles(bar)) {
        UIView *title = titleIn(bar, NULL);
        if (title && title.transform.ty != 0) title.transform = CGAffineTransformIdentity;
    }
    %orig;
    apply(bar);
}

- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) apply((UIView *)self);
}

// Spotify draws its colour back in from the scroll, with no layout pass of the bar's own.
- (void)didAddSubview:(UIView *)subview {
    %orig;
    if ([NSStringFromClass(subview.class) containsString:@"GradientView"]) apply((UIView *)self);
}
%end

// Spotify's GradientView (LegacyUI_ECMCoreKit.GradientView in the trees), found by name at launch.
// Whether a view is a page's scrim is worked out once each time it comes into a window, not on every pass: the walk goes
// up to the root.
static char kScrimKey;

static void maskIfScrim(UIView *view) {
    NSNumber *known = objc_getAssociatedObject(view, &kScrimKey);
    if (!known) {
        if (!view.window) return;
        known = @(isPageScrim(view));
        objc_setAssociatedObject(view, &kScrimKey, known, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (known.boolValue) maskAway(view);
}

%group SGRPageScrim
%hook SGRScrimView
- (void)didMoveToWindow {
    %orig;
    UIView *view = (UIView *)self;
    objc_setAssociatedObject(view, &kScrimKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    maskIfScrim(view);
}

- (void)layoutSubviews {
    %orig;
    maskIfScrim((UIView *)self);
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGBelowiOS26()) return;
    %init;
    SGRequireClasses(@[@"_TtC28EncoreConsumerMobile_BaseKit19HeaderNavigationBar"]);
    Class scrim = NSClassFromString(@"_TtC19LegacyUI_ECMCoreKit12GradientView") ?: NSClassFromString(@"LegacyUI_ECMCoreKit.GradientView");
    if (scrim) {
        %init(SGRPageScrim, SGRScrimView = scrim);
    } else {
        SGLog(@"class LegacyUI_ECMCoreKit.GradientView not found, the page scrims are masked from the bar's passes only");
    }
}
