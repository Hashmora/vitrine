// First visual pass for button-opened pull-down menus, styled after Telegram's
// modern glass actions stack. Own UIKit rendering; Spotify/UIMenu owns actions.
#pragma once
#import <UIKit/UIKit.h>

// Only the dropdown material/rows are painted here. Never touches menu actions.
void SGRTelegramDressDropdown(UIView *list, UIView *platter, UIView *glass);
void SGRTelegramDropdownCellHighlightChanged(UICollectionViewCell *cell);
