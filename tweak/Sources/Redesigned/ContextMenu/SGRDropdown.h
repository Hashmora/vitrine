// A shared visual renderer for every button-originated UIKit dropdown.
// Does not affect action dispatch, submenu navigation or Spotify bottom sheets.
#pragma once
#import <UIKit/UIKit.h>

void SGRDropdownControlTouched(UIControl *control);
BOOL SGRDropdownShouldStyle(UIView *list, BOOL vitrineButtonMenu);
void SGRDropdownDress(UIView *list, UIView *platter, UIView *glass);
void SGRDropdownCellHighlightChanged(UICollectionViewCell *cell);
void SGRDropdownCellLaidOut(UICollectionViewCell *cell);
void SGRDropdownContentLaidOut(UIView *content);

// A measured six-action geometry parity pass (iOS 18 => iOS 26). Does not
// replace UIApplication action dispatch or the highlight gesture recognizer.
void SGRDropdownMatchReferenceGeometry(UIView *list);
// Keeps button submenus above a stationary, dimmed parent; sizes the measured More sheet.
BOOL SGRDropdownMatchSubmenuGeometry(UIView *menu);
void SGRDropdownSubmenuHeaderLaidOut(UIView *header);
BOOL SGRDropdownReferenceHit(UICollectionView *collection, CGPoint point, NSIndexPath **index);
