// Glass for *unrelated* native context menus (long-press interactions).
// Every button-originated dropdown is now an owned SGRDropdownController;
// none of its layout/highlight/More geometry depends on _UIContextMenu*.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/ContextMenu/ContextMenu.h"

static const CGFloat kContextRadius = 14;
static char kContextGlassKey;

UIView *SGRMenuGlass(UIView *host, const void *key, CGFloat dim) {
    if (!host || host.bounds.size.width < 1 || host.bounds.size.height < 1) return nil;
    UIView *glass = SGRGlassPaneIn(host, key, kContextRadius);
    SGRDimSheetGlass(glass, dim);
    return glass;
}

static UIView *platterIn(UIView *view, NSUInteger depth) {
    if (!view || depth > 3) return nil;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:UIVisualEffectView.class] && object_getClass(view) == UIView.class)
            return view;
        if ([NSStringFromClass(sub.class) isEqualToString:@"_UIContextMenuListView"]) continue;
        UIView *found = platterIn(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

static void styleNativeContext(UIView *list) {
    if (!list.window || !SGBelowiOS26()) return;
    UIView *platter = platterIn(list, 0);
    if (!platter) return;
    UIView *glass = SGRMenuGlass(platter, &kContextGlassKey, SGRMenuDim);
    for (UIView *sub in platter.subviews) {
        if (sub != glass && [sub isKindOfClass:UIVisualEffectView.class]) sub.hidden = YES;
    }
}

%hook _UIContextMenuListView
- (void)didMoveToWindow {
    %orig;
    styleNativeContext((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    styleNativeContext((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    %init;
}
