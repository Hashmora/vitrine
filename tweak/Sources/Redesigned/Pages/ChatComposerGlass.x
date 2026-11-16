// The chat composer is an ElementView at the bottom of the chat page, above
// Spotify's now-playing bar. Its black 235pt backing is a sibling of the
// composer, not part of the search-like input field. Remove that backing and
// move the composer by the same inline-bar shift used by glass toasts.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"

static char kComposeField;
static __weak UIView *sg_chatComposer;

// Called by the tab bar during its own minimize/expand animation, and by the
// chat page pass on initial layout. Never infer a fixed tab-bar height.
void SGRChatComposerFollowTabBar(void) {
    UIView *element = sg_chatComposer;
    if (!element.window || !element.superview || element.bounds.size.height < 1) return;
    // The untransformed location uses center/bounds, not frame: frame already
    // incorporates the last transform and would accumulate a moving offset.
    CGRect rest = CGRectMake(element.center.x - element.bounds.size.width / 2,
                             element.center.y - element.bounds.size.height / 2,
                             element.bounds.size.width, element.bounds.size.height);
    CGRect baseline = [element.superview convertRect:rest toView:element.window];
    CGRect card = SGRNowPlayingCardFrameIn(element.window, NULL);
    CGFloat shift = SGRNowPlayingBarInlineShift();
    if (CGRectIsNull(card) ||
        fabs(CGRectGetMaxY(baseline) - (CGRectGetMinY(card) - shift)) > 60) shift = 0;
    CGAffineTransform move = CGAffineTransformMakeTranslation(0, shift);
    if (!CGAffineTransformEqualToTransform(element.transform, move)) element.transform = move;
}

static void glassComposer(UIViewController *page) {
    UIView *root = page.viewIfLoaded;
    if (!root.window) return;
    UIView *field = SGRFindByIdentifier(root, @"Components.UI.MessageComposeView.inputField", &kComposeField);
    if (!field || field.bounds.size.width < 100) return;
    SGRGlassFlatBox(field, &kComposeField, NO);
    UIView *element = field;
    for (UIView *v = field.superview; v && v != root; v = v.superview) {
        if ([NSStringFromClass(v.class) containsString:@"ChatMessageComposeElementProps"]) {
            element = v;
            break;
        }
    }
    if (element == field || !element.superview) return;
    sg_chatComposer = element;

    // This is the exact black footer sibling in the dump, beginning where the
    // 80pt composer begins and extending to the bottom of the chat screen.
    for (UIView *sibling in element.superview.subviews) {
        if (sibling == element || ![sibling isMemberOfClass:UIView.class] ||
            sibling.bounds.size.height < element.bounds.size.height + 50 ||
            fabs(sibling.bounds.size.width - element.bounds.size.width) > 2 ||
            fabs(CGRectGetMinY(sibling.frame) - CGRectGetMinY(element.frame)) > 2) continue;
        if (SGIsBaseSurface(sibling.layer.backgroundColor)) {
            sibling.backgroundColor = UIColor.clearColor;
            sibling.layer.backgroundColor = NULL;
            SGRHoldClear(sibling);
        }
    }
    SGRChatComposerFollowTabBar();

    // Only the trailing 12pt arrow of the chat title is removed; the 24pt
    // facepile and the title button (which opens chat details) stay active.
    UIView *bar = page.navigationController.navigationBar;
    UIView *content = SGRChildNamed(bar, @"_UINavigationBarContentView");
    UIView *title = SGRChildNamed(content, @"_UINavigationBarTitleControl");
    SGForEachView(title, ^(UIView *v) {
        if ([NSStringFromClass(v.class) isEqualToString:@"SPTEncoreIconView"] &&
            v.bounds.size.width <= 14 && v.bounds.size.height <= 14 &&
            v.bounds.size.width > 1) SGRConceal(v);
    });
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    SGRPassSwiftController(@"Campfire_ChatPageImpl", @"ChatPageViewController", ^(UIViewController *c) {
        glassComposer(c);
    });
}
