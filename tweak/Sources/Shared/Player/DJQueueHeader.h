// Only data and action callbacks cross the Shared -> look-specific boundary.
// The two UIs are separate implementations and never import one another.
#import <UIKit/UIKit.h>
void SGDJQueueNextSetTapped(void);
// Leading edge of the native header action group (Edit and, when present, Clear).
CGFloat SGDJQueueActionLeadingEdge(UIView *page, UIView *edit);
void SGDJNativeDrawNextSet(UIView *page, UIView *edit, BOOL visible, BOOL enabled, BOOL requestMode, NSString *title);
void SGRDJQueueDrawNextSet(UIView *page, UIView *edit, BOOL visible, BOOL enabled, BOOL requestMode, NSString *title);
