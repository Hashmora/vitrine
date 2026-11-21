// A single Telegram-inspired visual renderer for every button-originated UIKit dropdown.
// Does not affect action dispatch, submenu navigation or Spotify bottom sheets.
#pragma once
#import <UIKit/UIKit.h>

void SGRTelegramDropdownControlTouched(UIControl *control);
BOOL SGRTelegramDropdownShouldStyle(UIView *list, BOOL vitrineButtonMenu);
void SGRTelegramDressDropdown(UIView *list, UIView *platter, UIView *glass);
void SGRTelegramDropdownCellHighlightChanged(UICollectionViewCell *cell);
void SGRTelegramDropdownCellLaidOut(UICollectionViewCell *cell);
void SGRTelegramDropdownContentLaidOut(UIView *content);

// A measured six-action geometry parity pass (iOS 18 => iOS 26). Does not
// replace UIApplication action dispatch or the highlight gesture recognizer.
void SGRTelegramDropdownMatchReferenceGeometry(UIView *list);
// Keeps button submenus above a stationary, dimmed parent; sizes the measured More sheet.
BOOL SGRTelegramDropdownMatchSubmenuGeometry(UIView *menu);
void SGRTelegramDropdownSubmenuHeaderLaidOut(UIView *header);
BOOL SGRTelegramDropdownReferenceHit(UICollectionView *collection, CGPoint point, NSIndexPath **index);
