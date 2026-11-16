// People has an ordinary Back/title navigation bar but its Invite people row
// holds a separate 48pt grey icon. Keep the row's existing tap handling.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kInviteRow, kInvitePlus;

static void peopleGlass(UIViewController *c) {
    UIView *root = c.viewIfLoaded;
    if (!root.window) return;
    SGRDressBarPageBackOnly(c);
    UIView *row = SGRFindByIdentifier(root, @"CreateGroup.Row", &kInviteRow);
    if (!row || !row.accessibilityLabel || ![row.accessibilityLabel containsString:@"Invite"]) {
        // The row often has no accessibility label; identify its visible text.
        __block BOOL invited = NO;
        SGForEachView(row, ^(UIView *v) {
            if ([v isKindOfClass:UILabel.class] && [((UILabel *)v).text isEqualToString:@"Invite people"]) invited = YES;
        });
        if (!invited) return;
    }
    __block UIView *box = nil;
    SGForEachView(row, ^(UIView *v) {
        if (box || ![v isMemberOfClass:UIView.class] || fabs(v.bounds.size.width - 48) > 1 ||
            fabs(v.bounds.size.height - 48) > 1) return;
        if (SGRChildNamed(v, @"SPTEncoreIconView")) box = v;
    });
    if (!box) return;
    SGRGlassFlatBox(box, &kInvitePlus, NO);
    SGRUnclipUpTo(box, ^BOOL(UIView *v) { return [v isKindOfClass:UICollectionView.class]; });
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    SGRPassSwiftController(@"Campfire_ChatMemberPageImpl", @"ChatMemberViewController", ^(UIViewController *c) { peopleGlass(c); });
}
