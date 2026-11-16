// The New message row in Campfire's drawer has a grey 48pt disc with a
// plus, the same structure as Save in's Add songs. Never change the row action.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kNewMessageGlass, kRowKey;

static void dressRow(UIView *row) {
    if (!row.window || ![row.accessibilityIdentifier isEqualToString:@"Components.UI.ChatNewMessageRow"]) return;
    __block BOOL newMessage = NO;
    __block UIView *disc = nil;
    SGForEachView(row, ^(UIView *v) {
        if ([v isKindOfClass:UILabel.class] && [((UILabel *)v).text isEqualToString:@"New message"]) newMessage = YES;
        if ([v isMemberOfClass:UIView.class] && fabs(v.bounds.size.width-48)<0.5 &&
            fabs(v.bounds.size.height-48)<0.5 && SGRChildNamed(v, @"SPTEncoreIconView")) disc = v;
    });
    if (!newMessage || !disc) return;
    SGRGlassFlatBox(disc, &kNewMessageGlass, YES);
    SGRUnclipUpTo(disc, ^BOOL(UIView *v) { return v == row; });
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class row = NSClassFromString(@"_TtCE16Encore_LayoutKitO16EncoreFoundation6Encore7ListRow");
    if (row) SGRPassView(row, ^(UIView *v) { dressRow(v); });
    // The row is often inserted without its own layoutSubviews being called.
    // The collection cell always lays out as it appears or is recycled.
    Class cell = SGRSwiftClass(@"Element_List", @"CollectionViewCell");
    if (cell) SGRPassView(cell, ^(UIView *v) {
        UIView *found = SGRFindByIdentifier(v, @"Components.UI.ChatNewMessageRow", &kRowKey);
        if (found) dressRow(found);
    });
}
