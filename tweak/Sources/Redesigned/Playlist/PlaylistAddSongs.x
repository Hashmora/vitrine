// Playlist redesign, iOS < 26: the Add songs row over a playlist's tracks (Liked Songs, a playlist of the user's
// own), its square on glass.
//
// Tree: a cell holding CurateContextPluginImpl's AddMoreSectionElement, a view
// id=PlaylistCuration.AddButton with an ImageViewHolder 48x48 that carries the plus on a plain view painted
// #1F1F1F, and the label beside it. The grey box is what a search field's grey box is elsewhere in the
// redesign, so it gets the same glass (SGRGlassFlatBox): cleared, round, glass inside it, the plus above.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Playlist.h"

static char kBoxGlassKey, kBlendHolderSettleKey;

// Spotify uses a different element for Blend's identical Add songs row. Limit the extra
// path to its explicit identifier so other Blend cells are never touched.
static BOOL isBlendAddCell(UIView *cell) {
    __block BOOL found = NO;
    SGForEachView(cell, ^(UIView *view) {
        if ([view.accessibilityIdentifier isEqualToString:@"Components.UI.AddMediaRow"] &&
            [view.accessibilityLabel isEqualToString:@"Add songs"]) found = YES;
    });
    return found;
}

static BOOL isPlaylistAddCell(UIView *cell) {
    for (UIView *sub in cell.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"AddMoreSectionElement"]) return YES;
    }
    return NO;
}

// Both the cell and its 48pt image holder may be laid out after the other. In
// Blend the latter is inserted asynchronously: the cell's layout pass can finish
// while the square is still missing. Dress from the holder's *own* lifecycle too.
static void dressBoxInHolder(UIView *holder, UIView *cell) {
    if (!holder || !cell || !holder.window ||
        fabs(holder.bounds.size.width - 48) > 2 || fabs(holder.bounds.size.height - 48) > 2) return;
    UIView *box = nil;
    for (UIView *child in holder.subviews) {
        if ([child isMemberOfClass:UIView.class] &&
            fabs(child.bounds.size.width - holder.bounds.size.width) < 2 &&
            fabs(child.bounds.size.height - holder.bounds.size.height) < 2) {
            box = child;
            break;
        }
    }
    if (!box) return;
    SGRGlassFlatBox(box, &kBoxGlassKey, NO);
    if (SGUseLegacyGlass()) SGRUnclipUpTo(holder, ^BOOL(UIView *v) { return v == cell; });
}

static void dressAddCell(UIView *cell) {
    if (!cell.window) return;
    BOOL blend = isBlendAddCell(cell);
    if (!blend && (!isPlaylistAddCell(cell) || !SGRPlaylistHeaderOf(cell))) return;
    SGForEachView(cell, ^(UIView *view) {
        if (![NSStringFromClass(view.class) hasSuffix:@"ImageViewHolder"]) return;
        dressBoxInHolder(view, cell);
    });
}

// A holder reaches the window after its enclosing cell's layout callback on
// the first opening of Blend. This pass paints the glass before any tap.
static void dressBlendHolder(UIView *holder) {
    if (!holder.window || fabs(holder.bounds.size.width - 48) > 2 ||
        fabs(holder.bounds.size.height - 48) > 2) return;
    UIView *row = nil, *cell = nil;
    for (UIView *up = holder; up && ![up isKindOfClass:UIWindow.class]; up = up.superview) {
        if ([up.accessibilityIdentifier isEqualToString:@"Components.UI.AddMediaRow"] &&
            [up.accessibilityLabel isEqualToString:@"Add songs"]) row = up;
        if ([up isKindOfClass:UICollectionViewCell.class]) { cell = up; break; }
    }
    if (!row || !cell || !isBlendAddCell(cell)) return;
    dressBoxInHolder(holder, cell);
    // A placeholder may receive its painted square a little after insertion.
    if (!objc_getAssociatedObject(holder, &kBlendHolderSettleKey)) {
        objc_setAssociatedObject(holder, &kBlendHolderSettleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGRRepeatViewPass(holder, @[@0.05, @0.2], ^(UIView *v) { dressBlendHolder(v); });
    }
}

%hook _TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell
- (void)layoutSubviews {
    %orig;
    dressAddCell((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    dressAddCell((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    %init;
    Class holder = SGRPrivateSwiftClass(@"LegacyUI_ECMCoreKit", @"ImageViewHolder");
    if (holder) SGRPassView(holder, ^(UIView *v) { dressBlendHolder(v); });
    SGRequireClasses(@[@"_TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell"]);
}
