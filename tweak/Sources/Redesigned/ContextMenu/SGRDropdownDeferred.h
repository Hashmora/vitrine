// UIKit deferred menu sources captured at creation time for the owned dropdown.
// Capture provider blocks at creation, including responder-chain providers
// when the active system supports focus-based deferred menu elements.
#import <UIKit/UIKit.h>

typedef void (^SGRDropdownDeferredCompletion)(NSArray<UIMenuElement *> *elements);
typedef void (^SGRDropdownDeferredBlock)(SGRDropdownDeferredCompletion completion);

// Can the owned renderer load every deferred source in this menu tree?
// This checks nested submenus too, before suppressing UIKit's normal opening.
BOOL SGRDropdownDeferredMenuSupported(UIMenu *menu, UIResponder *anchor);

// Resolve an element from the original Spotify block. Completion is always
// delivered on the main thread, including cached results and timeouts.
void SGRDropdownDeferredRequest(UIDeferredMenuElement *element, UIResponder *anchor,
                                SGRDropdownDeferredCompletion completion);
