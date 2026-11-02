// Keeps the areas the redesign stripped transparent when Spotify repaints them, and learns which views
// could be the now playing bar's card from the album-color paint.
#import "Core/SGCore.h"
#import "SGRRepaint.h"
#import "SGRGlass.h"
#import "SGRChips.h"

__weak UIView *sgr_nowPlayingRoot = nil;
NSHashTable<UIView *> *sgr_nowPlayingPainted = nil;
__weak UIView *sgr_lyricsPageRoot = nil;
__weak UIView *sgr_playlistRoot = nil;
__weak UIView *sgr_albumRoot = nil;
__weak UIView *sgr_artistRoot = nil;
__weak UIView *sgr_sheetChromeRoot = nil;
__weak UIView *sgr_addSongsSearchBar = nil;
__weak UIView *sgr_showSearchField = nil;
__weak UIView *sgr_showSearchHeader = nil;

// Views whose fill is kept clear for good (SGRHoldClear): a dressed button's or a dressed disc's own paint, which Encore
// paints again as the control is pressed, let go or reused.
static NSHashTable<UIView *> *heldClear;

void SGRHoldClear(UIView *view) {
    if (!view) return;
    if (!heldClear) heldClear = [NSHashTable weakObjectsHashTable];
    [heldClear addObject:view];
}

// The flat, translucent white Spotify tints an unselected filter chip with (#FFFFFF@0.10). A selected chip is painted a solid colour of its own, which is never this.
static BOOL isNeutralTint(CGColorRef color) {
    if (!color || CFGetTypeID(color) != CGColorGetTypeID()) return NO;
    CGFloat alpha = CGColorGetAlpha(color);
    if (alpha < 0.01 || alpha > 0.3) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    size_t n = CGColorGetNumberOfComponents(color);
    for (size_t i = 0; i + 1 < n; i++) if (c[i] < 0.9) return NO;
    return n >= 2;
}

// One walk up from the view says which roots it is inside, the way SGIsInside would for each: not past a
// visual effect view. The roots are then taken in their order, not in the order the walk meets them.
enum { kInNowPlaying = 1, kInLyrics = 2, kInPage = 4 };

%hook CALayer
- (void)setBackgroundColor:(CGColorRef)color {
    if (!color) {
        %orig;
        return;
    }
    BOOL legacyLook = SGBelowiOS26();
    // The podcast search page's field: the grey goes, the glass (Pages/ShowSearch.x) stands in its place.
    if (legacyLook && color && sgr_showSearchField && self.delegate == sgr_showSearchField && (isNeutralTint(color) || CGColorGetAlpha(color) > 0.5)) color = NULL;
    // The podcast search page's header, Spotify's black behind the field row: it goes and the field and Cancel float.
    if (legacyLook && color && sgr_showSearchHeader && self.delegate == sgr_showSearchHeader && CGColorGetAlpha(color) > 0.5) color = NULL;
    // The Add songs sheet's search bar: its grey goes, the glass (Playlist/PlaylistAddSearch.x) stands in its place.
    if (legacyLook && color && sgr_addSongsSearchBar && self.delegate == sgr_addSongsSearchBar && CGColorGetAlpha(color) > 0.5) color = NULL;
    // A fill the Kit holds clear (SGRHoldClear): the button or disc is on glass, and Spotify's paint goes whenever it is set.
    if (legacyLook && color && heldClear.count && CGColorGetAlpha(color) > 0.05 && NSThread.isMainThread) {
        UIView *held = (UIView *)self.delegate;
        if ([held isKindOfClass:UIView.class] && held.layer == self && [heldClear containsObject:held]) color = NULL;
    }
    // A chip's fill painted: the grey goes, and either way the chip's glass is told (below, once the paint is
    // in), because selecting and deselecting a chip repaints the fill and lays nothing out, so the glass kept
    // whatever state the last layout gave it (hidden under a selected colour that was gone again).
    UIView *paintedChip = nil;
    if (legacyLook && color && (isNeutralTint(color) || CGColorGetAlpha(color) > 0.5)) {
        UIView *fill = (UIView *)self.delegate;
        if ([fill isKindOfClass:UIView.class] && fill.layer == self) {
            // The pill of a chip dressed by the Kit (SGRChips.h): the genres over Liked Songs, Recents' chips.
            if (SGRIsDressedChipPill(fill)) paintedChip = fill.superview;
            if (paintedChip && (isNeutralTint(color) || SGRIsSheetSurface(color))) color = NULL;
            // A selected chip's solid colour lands as a tint over the chip's glass (SGRChips.h).
            else if (paintedChip) color = SGRSelectedChipPaint(color);
        }
    }
    // A pill of the Add to playlist sheet (SGRSheetPills.x): its grey goes, and the pill's glass is told once the
    // paint is in, since selecting a pill repaints it and lays nothing out. The dressed mark is one lookup.
    UIView *paintedPill = nil;
    if (legacyLook && color && SGRSheetPillsLive()) {
        UIView *pill = (UIView *)self.delegate;
        if ([pill isKindOfClass:UIView.class] && pill.layer == self && SGRIsSheetPill(pill)) {
            paintedPill = pill;
            if (SGRIsPillGrey(color)) color = NULL;
            else color = SGRSelectedChipPaint(color);
        }
    }
    UIView *nowPlaying = sgr_nowPlayingRoot, *lyrics = sgr_lyricsPageRoot;
    UIView *playlist = sgr_playlistRoot, *album = sgr_albumRoot, *artist = sgr_artistRoot;
    UIView *sheet = sgr_sheetChromeRoot;
    // A page only ever loses the base surface, so another color asks after the player and the lyrics alone.
    if (color && (playlist || album || artist) && !SGIsBaseSurface(color)) playlist = album = artist = nil;
    if (color && (nowPlaying || lyrics || playlist || album || artist || sheet)) {
        UIView *view = (UIView *)self.delegate;
        if ([view isKindOfClass:UIView.class] && view.layer == self && !SGKeepsColor(view)) {
            NSUInteger inside = 0;
            for (UIView *v = view; v && !(inside & kInNowPlaying); v = v.superview) {
                if ([v isKindOfClass:UIVisualEffectView.class]) break;
                if (v == nowPlaying) inside |= kInNowPlaying;
                if (v == lyrics) inside |= kInLyrics;
                if (v == playlist || v == album || v == artist) inside |= kInPage;
            }
            if (inside & kInNowPlaying) {
                // Its size is judged when the bar picks its card: Spotify can paint a card before it sizes it.
                // The Jam strip's avatar keeps its colour, or only its initial is left.
                if (!SGRIsStripAvatar(view)) {
                    if (SGIsVisibleColor(color)) {
                        // The bar reads the table on main, and Spotify also paints layers off main.
                        void (^learn)(UIView *) = ^(UIView *painted) {
                            if (!painted || [sgr_nowPlayingPainted containsObject:painted]) return;
                            [sgr_nowPlayingPainted addObject:painted];
                            dispatch_async(dispatch_get_main_queue(), ^{ [nowPlaying.superview setNeedsLayout]; });
                        };
                        if (NSThread.isMainThread) {
                            learn(view);
                        } else {
                            __weak UIView *weakView = view;
                            dispatch_async(dispatch_get_main_queue(), ^{ learn(weakView); });
                        }
                    }
                    color = NULL;
                }
            } else if (inside & (kInLyrics | kInPage)) {
                color = NULL;
            } else if (sheet) {
                if (SGRIsSwiftUICard(view) && SGRIsSheetSurface(color) && SGIsInside(view, sheet)) {
                    // The device picker's cards: translucent rather than an opaque grey on the glass.
                    color = SGRSheetCardFill();
                } else if (SGIsVisibleColor(color) && SGRIsSheetChromeArea(view, sheet) && !SGRIsSheetCard(view)) {
                    color = NULL;
                } else if (SGRIsSheetSurface(color) && !SGRIsSheetCard(view) && SGIsInside(view, sheet)
                           && sheet.bounds.size.width > 1 && view.bounds.size.width >= sheet.bounds.size.width * SGRSheetBandShare) {
                    // A band in the sheet's own list (the queue's QueueCell and TrackRowQueue.Cell, #1F1F1F).
                    color = NULL;
                }
            }
        }
    }
    %orig(color);
    if (paintedPill) dispatch_async(dispatch_get_main_queue(), ^{ SGRSheetPillPainted(paintedPill); });
    if (paintedChip) dispatch_async(dispatch_get_main_queue(), ^{ SGRDressedChipPainted(paintedChip); });
}
%end

%group SheetPaint
// A row coming into the sheet after its chrome was stripped (scrolled in, reused, picked up to be dragged)
// carries its grey with it, and is painted before it is inside the sheet for the hook above to hear of it,
// so it is cleared from its own layout pass, like SGRClearCellPaint does for the pages.
%hook UITableViewCell
- (void)layoutSubviews {
    %orig;
    UIView *root = sgr_sheetChromeRoot;
    if (root && SGIsInside((UIView *)self, root)) SGRClearSheetCellPaint((UIView *)self, root);
}
%end

// Paint that lands before the layer hook can place it: a view given its grey while it has no parent yet, or
// through UIKit's own setter, is not inside the sheet when it is painted. That is the grey seen for a moment
// when the queue opens and cleared a beat later by the next chrome pass. These two catch it as it is set and
// as it is attached, so it is never drawn. Gated on one pointer, so every other screen pays a load and a test.
static BOOL isSheetPaint(UIView *view, CGColorRef color) {
    UIView *root = sgr_sheetChromeRoot;
    if (!root || root.bounds.size.width < 1 || !SGRIsSheetSurface(color)) return NO;
    if (SGKeepsColor(view) || SGRIsSheetCard(view) || !SGIsInside(view, root)) return NO;
    return SGRIsSheetChromeArea(view, root) || view.bounds.size.width >= root.bounds.size.width * SGRSheetBandShare;
}

static void clearAttachedPaint(UIView *view) {
    if (!sgr_sheetChromeRoot) return;
    CGColorRef paint = view.layer.backgroundColor;
    if (paint && isSheetPaint(view, paint)) view.backgroundColor = UIColor.clearColor;
}

%hook UIView
- (void)setBackgroundColor:(UIColor *)color {
    if (sgr_sheetChromeRoot && color && isSheetPaint((UIView *)self, color.CGColor)) color = UIColor.clearColor;
    %orig(color);
}

- (void)didMoveToSuperview {
    %orig;
    clearAttachedPaint((UIView *)self);
}

// A subtree built off screen (the queue's table and its bars) is attached to the sheet as a whole: only its
// root hears didMoveToSuperview, with every view below it still painted and, when it was set, not yet inside
// the sheet. didMoveToWindow reaches each of them with the full chain above it, so the grey a descendant
// carried in is cleared before its first frame instead of at the next chrome pass.
- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) clearAttachedPaint((UIView *)self);
}
%end

// Spotify builds a view and paints it before it is laid out: its bounds are zero then, which SGKeepsColor
// reads as a hairline and spares, and nothing paints it again once it has its size. So the grey of the queue's
// table, its header rows and the cell laid out last stood until the next chrome pass, which is a viewDidAppear
// away. This catches the moment such a view gets its size.
%hook CALayer
- (void)setBounds:(CGRect)bounds {
    %orig;
    if (!sgr_sheetChromeRoot || bounds.size.height <= 4 || bounds.size.width < 1) return;
    CGColorRef paint = self.backgroundColor;
    if (!paint || !SGRIsSheetSurface(paint)) return;   // the cheap test first: this runs for every layer
    UIView *view = (UIView *)self.delegate;
    if ([view isKindOfClass:UIView.class] && view.layer == self && isSheetPaint(view, paint)) view.backgroundColor = UIColor.clearColor;
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    if (!SGBelowiOS26()) return;
    %init(SheetPaint);
}
