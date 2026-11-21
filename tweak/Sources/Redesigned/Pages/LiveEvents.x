// Live Events, the concerts hub (LiveEvents_LiveEventsPageImpl.LiveEventsPageViewController): the header's title and
// buttons on glass over the header's own gradient, and the list run on under the tab bar.
//
// Tree: the page is a plain view holding the list (LiveEventsPage.ContentScrollView, a UICollectionView on #000000) and
// the header, a LegacyUI_ECMCoreKit.HeaderLayout (Components.UI.EventHeaderHubPage) with the gradient behind it and, in
// its foreground, the HeaderNavigationBar the playlist, album and artist pages have: its own GradientView, the name "Live
// Events" as a label, Back (Components.Header.UI.BackButton) and, in a stack at the trailing edge, Saved and
// Notifications (Encore Tertiary buttons, 48x48). The list was 689pt high, ending where the now playing bar begins, so
// under the glass tab bar there was the page's black instead of the last events.
//
// The header keeps its gradient. Its buttons are the page's pinned glass circles (Back at the leading corner,
// Notifications in the trailing one and Saved beside it), as on the playlist, album and artist pages: Spotify's own are
// concealed and fired by them, since a circle glassed in place fought the header's collapse. The name in the bar sits on
// the glass capsule those pages' bars give theirs (Playlist/PlaylistBar.x), here without taking the gradient off.
//
// The list is made as tall as the page, and what the bars below took of it goes to its bottom inset, so the last event
// clears them and the rows run on under the glass, as Recents' (Pages/Recents.x) do. Spotify's constraints put the frame
// back after each pass of the page's view, so it is set again after every one.
//
// The pages Live Events opens (LiveEvents_GalleryPageImpl.GalleryPageViewController: Popular events in ..., Your top pop
// events, Venues, All events, Live events just for you) have the same header and a list of their own
// (GalleryPage.ContentScrollView, 705pt of a 844pt page). They get the playlist pages' look: Back on the pinned glass
// circle, the header's gradients gone (Playlist/PlaylistBar.x refuses them on a Gallery page, SGRGalleryPageOf), the
// name in the bar on the glass capsule, and the list as tall as the page, under the bars.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kListKey, kBellKey, kSavedKey, kBellPinKey, kSavedPinKey, kTitleGlassKey;
static char kEntityTitleKey, kEntityChipKey, kEntityFillKey;
static char kEntityHeaderScrollKey, kEntityHeaderReferenceKey, kEntityHeaderMotionKey;
static char kEntityHeaderBaseTransformKey, kEntityHeaderInitialClipKey;

// A scroll can replace its Encore header without being recreated. Keep the
// current HeaderLayout weakly so its content is not retained by the observer.
@interface SGRWeakEntityHeader : NSObject
@property (nonatomic, weak) UIView *view;
@end
@implementation SGRWeakEntityHeader
@end

static Class sg_galleryPage;

UIView *SGRGalleryPageOf(UIView *view) {
    if (!sg_galleryPage) return nil;
    for (UIView *v = view; v; v = v.superview) {
        if ([v.nextResponder isKindOfClass:sg_galleryPage]) return v;
    }
    return nil;
}

static UIScrollView *listIn(UIView *page, NSString *identifier) {
    UIView *list = SGRFindByIdentifier(page, identifier, &kListKey);
    return [list isKindOfClass:UIScrollView.class] ? (UIScrollView *)list : nil;
}

static void extendList(UIScrollView *list) {
    CGFloat pageHeight = list.superview.bounds.size.height;
    CGRect frame = list.frame;
    if (pageHeight < 1 || frame.size.width < 1 || frame.size.height < pageHeight * 0.5) return;
    // At most 40% of the page goes to the bars below: more is a list Spotify has not sized yet.
    CGFloat taken = MIN(SGRListRoomOf(list).below, pageHeight * 0.4);
    SGRSetOwnFrame(list, CGRectMake(frame.origin.x, frame.origin.y, frame.size.width, pageHeight - frame.origin.y));
    // The list's own safe area at the bottom is counted again once it reaches the bottom edge, so it is taken off.
    CGFloat safe = list.contentInsetAdjustmentBehavior == UIScrollViewContentInsetAdjustmentNever ? 0 : list.safeAreaInsets.bottom;
    CGFloat bottom = MAX(taken - safe, 0);
    UIEdgeInsets inset = list.contentInset;
    if (fabs(inset.bottom - bottom) < 0.5) return;
    inset.bottom = bottom;
    list.contentInset = inset;
    UIEdgeInsets bar = list.verticalScrollIndicatorInsets;
    bar.bottom = bottom;
    list.verticalScrollIndicatorInsets = bar;
}

// The name in the header's bar: the SPTEncoreLabel directly under the HeaderNavigationBar that holds text (the Back
// button's is a glyph in a button of its own, deeper down). The capsule is its child, so it follows the label's alpha.
static void glassTitle(UIView *page) {
    static Class barClass;
    if (!barClass) barClass = NSClassFromString(@"_TtC28EncoreConsumerMobile_BaseKit19HeaderNavigationBar");
    if (!barClass) return;
    __block UIView *bar = nil;
    SGForEachView(page, ^(UIView *v) {
        if (!bar && [v isKindOfClass:barClass]) bar = v;
    });
    for (UIView *sub in bar.subviews) {
        if (![NSStringFromClass(sub.class) hasSuffix:@"EncoreLabel"]) continue;
        UILabel *text = nil;
        for (UIView *inner in sub.subviews) {
            if ([inner isKindOfClass:UILabel.class] && ((UILabel *)inner).text.length) text = (UILabel *)inner;
        }
        if (!text || sub.bounds.size.width < 1) continue;
        SGRGlassTitleCapsule(sub, &kTitleGlassKey, SGRTitleWidth(text), sub.bounds.size.width, ^BOOL(UIView *v) { return v.superview == page; });
        return;
    }
}

// The page's list run on under the bars, and again after each layout pass of the view it is in.
static void listUnderBars(UIViewController *controller, NSString *identifier) {
    UIScrollView *list = listIn(controller.viewIfLoaded, identifier);
    if (!list) return;
    extendList(list);
    __weak UIViewController *weakPage = controller;
    SGRWatchLayout(list.superview, ^(UIView *laidOut) {
        UIScrollView *found = listIn(weakPage.viewIfLoaded, identifier);
        if (found) extendList(found);
    });
}

static void dress(UIViewController *controller) {
    UIView *view = controller.viewIfLoaded;
    if (!view.window || view.bounds.size.width < 1) return;

    static UIImage *heart, *bell;
    if (!heart) heart = [UIImage systemImageNamed:@"heart"];
    if (!bell) bell = [UIImage systemImageNamed:@"bell"];
    // Back is found under the page (Components.Header.UI.BackButton) and concealed by the pin.
    SGRPinnedBack(view, view);
    UIView *notifications = SGRFindByIdentifier(view, @"Components.UI.EventHeaderHubPage.Notifications", &kBellKey);
    UIView *saved = SGRFindByIdentifier(view, @"Components.UI.EventHeaderHubPage.Saved", &kSavedKey);
    SGRConceal(notifications);
    SGRConceal(saved);
    SGRPinnedTrailing(view, &kBellPinKey, notifications, 0, bell);
    SGRPinnedTrailing(view, &kSavedPinKey, saved, 1, heart);
    glassTitle(view);
    listUnderBars(controller, @"LiveEventsPage.ContentScrollView");
}

// A Gallery page: Back pinned and the name on glass; the gradients are refused by PlaylistBar.x.
static void dressGallery(UIViewController *controller) {
    UIView *view = controller.viewIfLoaded;
    if (!view.window || view.bounds.size.width < 1) return;
    SGRPinnedBack(view, view);
    glassTitle(view);
    listUnderBars(controller, @"GalleryPage.ContentScrollView");
}

// Event and Venue detail pages do not use the hub/gallery controller. Their
// HeaderNavigationBar moves inside a collapsing HeaderLayout, while the
// ContentScrollView and the header share one *stationary* page root. Pin Back
// to that root: pinning it to the bar makes it wander sideways as the header
// animates. Match pages by their concrete list identifiers, not by the bar
// class (which is also used throughout Spotify).
static UIView *entityRootOf(UIView *piece) {
    if (!piece.window) return nil;
    for (UIView *v = piece; v && ![v isKindOfClass:UIWindow.class]; v = v.superview) {
        if (v.bounds.size.width < 280 ||
            v.bounds.size.height < piece.window.bounds.size.height * 0.75) continue;
        for (UIView *child in v.subviews) {
            if (![child isKindOfClass:UICollectionView.class]) continue;
            NSString *identifier = child.accessibilityIdentifier;
            if ([identifier isEqualToString:@"LiveEventPage.ContentScrollView"] ||
                [identifier isEqualToString:@"VenuePage.ContentScrollView"]) return v;
        }
    }
    return nil;
}

static void hideEntityScrim(UIView *view) {
    // An empty layer mask is safer than hiding an Encore/SwiftUI header view:
    // hidden changes can disturb the stack's layout, and its own layout can
    // restore the gradient's opacity as the hero collapses.
    if (!view || (view.layer.mask && CGRectIsEmpty(view.layer.mask.bounds))) return;
    view.layer.mask = [CALayer layer];
}

static void dressEntityBar(UIView *bar) {
    UIView *root = entityRootOf(bar);
    if (!root || bar.bounds.size.width < 1) return;

    UIView *back = nil;
    UIView *title = nil;
    UILabel *label = nil;
    for (UIView *child in bar.subviews) {
        NSString *name = NSStringFromClass(child.class);
        if ([name containsString:@"GradientView"]) hideEntityScrim(child);
        if ([child.accessibilityIdentifier isEqualToString:@"Components.Header.UI.BackButton"]) back = child;
        if (![name hasSuffix:@"EncoreLabel"]) continue;
        for (UIView *inner in child.subviews) {
            if (![inner isKindOfClass:UILabel.class] || !((UILabel *)inner).text.length) continue;
            title = child;
            label = (UILabel *)inner;
            break;
        }
    }
    // Only the painted background of HeaderLayout is removed. Do not mask
    // the hero's own artwork/gradient; it carries event details and tags.
    for (UIView *up = bar.superview; up && up != root; up = up.superview) {
        if (![up.accessibilityIdentifier isEqualToString:@"Components.UI.EventHeaderEntityPage"] &&
            ![up.accessibilityIdentifier isEqualToString:@"Components.UI.VenueHeaderEntityPage"]) continue;
        for (UIView *section in up.subviews) {
            if (![section.accessibilityIdentifier isEqualToString:@"_clippingView"]) continue;
            for (UIView *background in section.subviews) {
                if (![background.accessibilityIdentifier isEqualToString:@"_backgroundViewContainer"]) continue;
                SGForEachView(background, ^(UIView *v) {
                    if ([NSStringFromClass(v.class) containsString:@"GradientView"]) hideEntityScrim(v);
                });
            }
        }
        break;
    }

    if (SGIsVisibleColor(bar.layer.backgroundColor)) bar.backgroundColor = UIColor.clearColor;
    if (back) SGRPinnedBackOf(root, back);
    else SGRPlacePinnedBack(root);
    if (title && title.bounds.size.width > 1)
        SGRGlassTitleCapsule(title, &kEntityTitleKey, SGRTitleWidth(label), title.bounds.size.width, nil);
}

// Native HeaderLayout does not always move its contents for the whole scroll.
// On Event and Venue pages the header may stop shrinking while the list still
// advances, leaving the ticket card or genre/action chips "frozen" below Back.
// Stage 125 removed ALL _safeAreaView pixels at 33% of the hero displacement:
// this cut the card in half and produced an abrupt black area mid-scroll.
//
// Instead, first let Spotify run its normal collapsing layout. Only once a
// continuing list scroll no longer moves the native hero do we advance the
// hero CONTENT by the extra scroll amount, behind its existing safe-area clip.
// Nothing suddenly disappears; it slides out with the same finger movement.
// The foreground navigation remains a separate, stationary sibling.
static void advanceStalledEntityContent(UIView *header) {
    NSString *identifier = header.accessibilityIdentifier;
    BOOL event = [identifier isEqualToString:@"Components.UI.EventHeaderEntityPage"];
    if (!event && ![identifier isEqualToString:@"Components.UI.VenueHeaderEntityPage"]) return;
    UIView *root = entityRootOf(header);
    if (!root) return;
    UICollectionView *list = nil;
    NSString *listID = event ? @"LiveEventPage.ContentScrollView" : @"VenuePage.ContentScrollView";
    for (UIView *child in root.subviews) {
        if ([child isKindOfClass:UICollectionView.class] &&
            [child.accessibilityIdentifier isEqualToString:listID]) {
            list = (UICollectionView *)child;
            break;
        }
    }
    if (!list) return;
    UIView *clip = nil, *background = nil, *safeArea = nil;
    for (UIView *child in header.subviews) {
        if ([child.accessibilityIdentifier isEqualToString:@"_clippingView"]) {
            clip = child;
            break;
        }
    }
    for (UIView *child in clip.subviews) {
        if ([child.accessibilityIdentifier isEqualToString:@"_backgroundViewContainer"]) background = child;
        if ([child.accessibilityIdentifier isEqualToString:@"_safeAreaView"]) safeArea = child;
    }
    if (!background || !safeArea || header.bounds.size.height < 1) return;
    UIView *hero = nil, *content = nil;
    for (UIView *child in background.subviews) {
        if (child.bounds.size.height >= header.bounds.size.height - 1) {
            hero = child;
            break;
        }
    }
    for (UIView *child in safeArea.subviews) {
        if ([child.accessibilityIdentifier isEqualToString:@"_headerContentContainer"]) {
            content = child;
            break;
        }
    }
    if (!hero || !content || hero.bounds.size.height < 140) return;

    NSMutableDictionary *motion = objc_getAssociatedObject(header, &kEntityHeaderMotionKey);
    if (!motion || [motion[@"content"] nonretainedObjectValue] != content) {
        motion = [NSMutableDictionary dictionaryWithDictionary:@{
            @"content": [NSValue valueWithNonretainedObject:content],
            @"offset": @(list.contentOffset.y),
            @"heroY": @(hero.frame.origin.y),
            @"nativeCenterY": @(content.center.y),
            @"height": @(header.bounds.size.height),
            @"extra": @0.0
        }];
        objc_setAssociatedObject(header, &kEntityHeaderMotionKey, motion, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat offset = list.contentOffset.y;
    CGFloat heroY = hero.frame.origin.y;
    CGFloat height = header.bounds.size.height;
    CGFloat extra = [motion[@"extra"] doubleValue];
    CGFloat deltaScroll = offset - [motion[@"offset"] doubleValue];
    CGFloat deltaHero = heroY - [motion[@"heroY"] doubleValue];
    CGFloat deltaHeight = height - [motion[@"height"] doubleValue];
    // UIView.center is not affected by our transform, so this tests whether
    // Spotify itself is still moving the content during the collapse.
    CGFloat deltaNative = content.center.y - [motion[@"nativeCenterY"] doubleValue];
    BOOL movingHero = fabs(deltaHero) > 0.75 || fabs(deltaHeight) > 0.75 || fabs(deltaNative) > 0.75;
    if (heroY > -12 || movingHero) {
        // Native header is still collapsing (or is expanding again): never
        // compensate during this part of Spotify's animation.
        extra = 0;
    } else if (deltaScroll > 0.5) {
        // Header position is stationary but scroll progresses downwards.
        extra = MIN(hero.bounds.size.height, extra + deltaScroll);
    } else if (deltaScroll < -0.5) {
        // Scroll back through exactly the extra travel before letting the
        // native header expand; no sudden reverse visibility transition.
        extra = MAX(0, extra + deltaScroll);
    }
    motion[@"offset"] = @(offset);
    motion[@"heroY"] = @(heroY);
    motion[@"nativeCenterY"] = @(content.center.y);
    motion[@"height"] = @(height);
    motion[@"extra"] = @(extra);

    NSValue *base = objc_getAssociatedObject(content, &kEntityHeaderBaseTransformKey);
    if (!base) {
        base = [NSValue valueWithCGAffineTransform:content.transform];
        objc_setAssociatedObject(content, &kEntityHeaderBaseTransformKey, base, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGAffineTransform expected = CGAffineTransformTranslate(base.CGAffineTransformValue, 0, -extra);
    if (!CGAffineTransformEqualToTransform(content.transform, expected)) content.transform = expected;
    NSNumber *initialClip = objc_getAssociatedObject(safeArea, &kEntityHeaderInitialClipKey);
    if (!initialClip) {
        initialClip = @(safeArea.clipsToBounds);
        objc_setAssociatedObject(safeArea, &kEntityHeaderInitialClipKey, initialClip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Clip only the moving CONTENT, never the pinned nav or the artwork.
    BOOL shouldClip = extra > 0.5 || initialClip.boolValue;
    if (safeArea.clipsToBounds != shouldClip) safeArea.clipsToBounds = shouldClip;

    SGRWeakEntityHeader *reference = objc_getAssociatedObject(list, &kEntityHeaderReferenceKey);
    if (!reference) {
        reference = [SGRWeakEntityHeader new];
        objc_setAssociatedObject(list, &kEntityHeaderReferenceKey, reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    reference.view = header;
    SGRFollowOffset(list, &kEntityHeaderScrollKey, ^(UIScrollView *watched) {
        // Read the settled frame after Spotify's own scrolling/layout pass;
        // observing an offset before that layout would falsely detect a stall.
        __weak UIScrollView *weakScroll = watched;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIScrollView *scroll = weakScroll;
            SGRWeakEntityHeader *ref = objc_getAssociatedObject(scroll, &kEntityHeaderReferenceKey);
            if (ref.view.window) advanceStalledEntityContent(ref.view);
        });
    });
}

// The genre tags on Event and Venue pages are LiveEvents_ECMKit.ConceptChipView,
// not Encore_ChipsKit.ChipView. Reuse the library chip material, without
// changing the tap target or a scroll view's own clipping/scroll behavior.
static void dressEntityConceptChip(UIView *chip) {
    UIView *root = entityRootOf(chip);
    if (!root || chip.bounds.size.width < 1 || chip.bounds.size.height < 1) return;
    UIView *fill = objc_getAssociatedObject(chip, &kEntityFillKey);
    if (fill && fill.superview != chip) fill = nil;
    if (!fill) {
        for (UIView *child in chip.subviews) {
            if (![child isMemberOfClass:UIView.class] ||
                fabs(child.bounds.size.width - chip.bounds.size.width) > 2 ||
                fabs(child.bounds.size.height - chip.bounds.size.height) > 2) continue;
            if (child.layer.cornerRadius < 6) continue;
            fill = child;
            break;
        }
        if (!fill) return;
        objc_setAssociatedObject(chip, &kEntityFillKey, fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    SGRGlassChip(chip, fill, NO, &kEntityChipKey);
    SGRHoldClear(fill);
    if (SGUseLegacyGlass()) SGRUnclipUpTo(chip.superview, ^BOOL(UIView *v) {
        // The last wrapper may clip a pressed capsule, but leave the actual
        // scroll view and page root clipped as intended.
        return [v.superview isKindOfClass:UIScrollView.class] || v.superview == root;
    });
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    // The header's buttons and the list's rows are made after the first layout.
    SGRPassSwiftController(@"LiveEvents_LiveEventsPageImpl", @"LiveEventsPageViewController", ^(UIViewController *c) { dress(c); });
    sg_galleryPage = SGRSwiftClass(@"LiveEvents_GalleryPageImpl", @"GalleryPageViewController");
    SGRPassController(sg_galleryPage, ^(UIViewController *c) { dressGallery(c); });
    // The same stable-root handler covers Event details (#4 and #6), their
    // expanded hero (#5), and Venue details (#7).
    Class bar = SGRSwiftClass(@"EncoreConsumerMobile_BaseKit", @"HeaderNavigationBar");
    if (bar) SGRPassView(bar, ^(UIView *view) { dressEntityBar(view); });
    Class header = SGRSwiftClass(@"LegacyUI_ECMCoreKit", @"HeaderLayout");
    if (header) SGRPassView(header, ^(UIView *view) { advanceStalledEntityContent(view); });
    Class concept = SGRSwiftClass(@"LiveEvents_ECMKit", @"ConceptChipView");
    if (concept) SGRPassView(concept, ^(UIView *view) { dressEntityConceptChip(view); });
}
