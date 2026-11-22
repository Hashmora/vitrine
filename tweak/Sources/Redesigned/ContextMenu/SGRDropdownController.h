// Owned button-dropdown presentation. No _UIContextMenuView or UIKit menu provider
// participates in layout, hit testing, highlighting, or submenu navigation.
#import <UIKit/UIKit.h>

typedef void (^SGRDropdownFinish)(UIMenuElement *selected);

// Returns NO if the anchor is no longer in a scene. Presents exactly one overlay
// in the anchor's scene and closes an earlier one before replacing it.
BOOL SGRDropdownPresent(UIView *anchor, UIMenu *menu, SGRDropdownFinish finished);
// Replaces the data of an open overlay without dismissing it or replaying opening
// motion. Submenus are preserved by identifier when their data still exists.
void SGRDropdownUpdate(UIView *anchor, UIMenu *menu);
BOOL SGRDropdownIsPresentingFrom(UIView *anchor);
void SGRDropdownDismissFrom(UIView *anchor);
// Executes the action through a real UIControl so its UIAction handler runs,
// rather than relying on private UIKit menu-action invocation selectors.
BOOL SGRDropdownPerformAction(UIMenuElement *element);
// Hosts a real interactive custom view controller (sliders, dynamic lyrics sources)
// in the same owned glass chrome, without UIPopoverPresentationController.
BOOL SGRDropdownPresentContent(UIView *anchor, UIViewController *content, CGSize preferredSize);
// A hosted provider-backed list follows its preferredContentSize as answers
// arrive; only the safe screen viewport clips it, not the menu stack limit.
BOOL SGRDropdownPresentAdaptiveContent(UIView *anchor, UIViewController *content, CGSize preferredSize);
void SGRDropdownRefreshContentSize(UIViewController *content);
void SGRDropdownDismissActive(void);
