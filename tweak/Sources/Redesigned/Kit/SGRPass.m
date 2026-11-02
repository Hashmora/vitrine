#import "SGRPass.h"
#import "Core/SGCore.h"
#import "SGRRestyle.h"
#import <objc/runtime.h>

void SGRRepeatPass(UIViewController *controller, NSArray<NSNumber *> *delays, SGRControllerPass pass) {
    __weak UIViewController *weak = controller;
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *strong = weak;
            if (strong) pass(strong);
        });
    }
}

#pragma mark - following a scroll

@interface SGROffsetFollower : NSObject
@property (nonatomic, weak) UIScrollView *scroll;
@property (nonatomic, copy) void (^follow)(UIScrollView *scroll);
@end

@implementation SGROffsetFollower
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    UIScrollView *scroll = self.scroll;
    if (scroll) self.follow(scroll);
}
@end
