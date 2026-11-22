// UIKit deferred menu sources captured at creation time for the owned dropdown.
// A UIDeferredMenuElement has no public getter for its provider. Do not attempt
// private runtime inspection: unsupported elements stay in UIKit's presentation.
#import <UIKit/UIKit.h>

typedef void (^SGRDropdownDeferredCompletion)(NSArray<UIMenuElement *> *elements);
typedef void (^SGRDropdownDeferredBlock)(SGRDropdownDeferredCompletion completion);

// Can the owned renderer load every deferred source in this menu tree?
// This checks nested submenus too, before suppressing UIKit's normal opening.
BOOL SGRDropdownDeferredMenuSupported(UIMenu *menu);

// Resolve an element from the original Spotify block. Completion is always
// delivered on the main thread, including cached results and timeouts.
void SGRDropdownDeferredRequest(UIDeferredMenuElement *element, SGRDropdownDeferredCompletion completion);
