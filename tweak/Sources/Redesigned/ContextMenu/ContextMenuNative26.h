// Internal iOS 26+ dispatch targets for the native UIKit popup.
#pragma once
#import "ContextMenu.h"

void SGRSystemMenuWatchIOS26(UIView *button, SGRMenuItems items, SGRMenuKind kind);
UIControl *SGRSystemMenuFrontIOS26(UIView *button);
BOOL SGPlayerMenuReplacedIOS26(UIViewController *menu);
