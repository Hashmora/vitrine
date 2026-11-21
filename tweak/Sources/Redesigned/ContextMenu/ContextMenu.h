// Owns button dropdown commands for the player and pages. The visual presenter
// is SGRDropdownController, not UIKit's menu provider. Spotify still supplies
// real actions via its hidden sheet and receives picks on its actual rows.
// All submenus, panels, quick tiles and geometry are owned by the presenter.
// Native long-press context menus are not button dropdowns and are unchanged.
// Main-thread only.
#import <UIKit/UIKit.h>

// Items of the mod's own for the menu `button` opens, built afresh every time it opens.
typedef NSArray<UIMenuElement *> *(^SGRMenuItems)(void);
// What the sheet the ⋯ opens now is for ("track", "episode"...). The menu remembers which quick items the last
// sheet of each kind had, so the quick row is right before this sheet has its rows.
typedef NSString *(^SGRMenuKind)(void);

// Makes `button`, the player's ⋯ (a UIControl), open the owned dropdown: the quick row, `items`, then More.
// `kind` may be nil. Called on every layout of the ⋯'s row: it keeps the mod's button on top and over the whole
// ⋯, and replaces `items` and `kind`. The pinned ⋯ of the entity pages needs no call: the Kit records its taps
// (SGRPinnedMoreRecentButton).
void SGRSystemMenuWatch(UIView *button, SGRMenuItems items, SGRMenuKind kind);

// The mod's button over `button`, which takes the ⋯'s touches once SGRSystemMenuWatch has been called; nil before.
UIControl *SGRSystemMenuFront(UIView *button);

// The glass the system menu has below iOS 26, on `host` under `key`: SGRMenuGlass (ContextMenuGlass.x) is what the
// menu's platter gets (SGRMenuDim) and what the sliders' panel under the ⋯ takes for its background with a dim
// of its own. Nil while `host` has no size.
static const CGFloat SGRMenuDim = 0.42;
UIView *SGRMenuGlass(UIView *host, const void *key, CGFloat dim);
