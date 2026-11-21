// A single Telegram-inspired visual renderer for every button-originated UIKit dropdown.
// Does not affect action dispatch, submenu navigation or Spotify bottom sheets.
#pragma once
#import <UIKit/UIKit.h>

void SGRTelegramDropdownControlTouched(UIControl *control);
BOOL SGRTelegramDropdownShouldStyle(UIView *list, BOOL vitrineButtonMenu);
void SGRTelegramDressDropdown(UIView *list, UIView *platter, UIView *glass);
void SGRTelegramDropdownCellHighlightChanged(UICollectionViewCell *cell);
void SGRTelegramDropdownCellLaidOut(UICollectionViewCell *cell);
