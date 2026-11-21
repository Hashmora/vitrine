// The default group icon in the Messages drawer is a 48pt FaceStackView with a single
// monochrome avatar bitmap. A real group photo must remain untouched. The stock bitmap
// paints its own opaque circle: for the fallback alone put a glass disc behind Spotify's
// row and draw a two-person glyph over it. No chat action or avatar outside a ChatRow changes.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kFallbackGlass, kFallbackGlyph, kFallbackMasked;

// The bundled no-photo group mark is neutral grey, while ordinary user/group art is
// chromatic. Conservative test: a grayscale photograph is possible, so this path is
// intentionally limited to the single-avatar FaceStackView used by group chat rows.
static BOOL isNeutralFallback(UIImage *image) {
    if (!image.CGImage) return NO;
    enum { SIDE = 12 };
    uint8_t pixels[SIDE * SIDE * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, SIDE, SIDE, 8, SIDE * 4,
                                                space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return NO;
    CGContextDrawImage(context, CGRectMake(0, 0, SIDE, SIDE), image.CGImage);
    CGContextRelease(context);
    NSUInteger colored = 0, visible = 0;
    for (NSUInteger i = 0; i < SIDE * SIDE; i++) {
        uint8_t *p = pixels + i * 4;
        if (p[3] < 90) continue;
        visible++;
        int r = p[0], g = p[1], b = p[2];
        if (MAX(r, MAX(g, b)) - MIN(r, MIN(g, b)) > 17) colored++;
    }
    return visible > SIDE * SIDE / 2 && colored * 20 < visible;
}

static void dressDefault(UIView *stack) {
    if (!stack.window || fabs(stack.bounds.size.width - 48) > 1 ||
        fabs(stack.bounds.size.height - 48) > 1) return;
    UIView *row = nil;
    for (UIView *v = stack; v && !row; v = v.superview) {
        if ([v.accessibilityIdentifier isEqualToString:@"Components.UI.ChatRow"]) row = v;
        if ([v isKindOfClass:UICollectionView.class]) break;
    }
    if (!row) return;
    UIView *avatar = nil;
    NSUInteger count = 0;
    for (UIView *sub in stack.subviews) {
        if (![NSStringFromClass(sub.class) hasSuffix:@"AvatarView"]) continue;
        count++;
        avatar = sub;
    }
    if (count != 1 || !avatar) return;
    __block UIImageView *source = nil;
    __block BOOL hasLetter = NO;
    SGForEachView(avatar, ^(UIView *view) {
        if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) hasLetter = YES;
        if (!source && [view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image)
            source = (UIImageView *)view;
    });
    BOOL fallback = !hasLetter && isNeutralFallback(source.image);
    UIImageView *glyph = objc_getAssociatedObject(stack, &kFallbackGlyph);
    if (!fallback) {
        if (objc_getAssociatedObject(avatar, &kFallbackMasked)) {
            avatar.layer.mask = nil;
            objc_setAssociatedObject(avatar, &kFallbackMasked, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        glyph.hidden = YES;
        return;
    }

    SGRGlassFlatBox(stack, &kFallbackGlass, NO);
    if (!objc_getAssociatedObject(avatar, &kFallbackMasked)) {
        avatar.layer.mask = [CALayer layer];
        objc_setAssociatedObject(avatar, &kFallbackMasked, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!glyph) {
        glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"person.2.fill"]];
        glyph.contentMode = UIViewContentModeScaleAspectFit;
        glyph.tintColor = UIColor.whiteColor;
        glyph.userInteractionEnabled = NO;
        glyph.accessibilityElementsHidden = YES;
        objc_setAssociatedObject(stack, &kFallbackGlyph, glyph, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGRect frame = CGRectInset(stack.bounds, 12, 12);
    if (!CGRectEqualToRect(glyph.frame, frame)) glyph.frame = frame;
    if (glyph.superview != stack) [stack addSubview:glyph];
    else [stack bringSubviewToFront:glyph];
    glyph.hidden = NO;
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class stack = NSClassFromString(@"_TtCE14Encore_FaceKitO16EncoreFoundation6Encore13FaceStackView");
    if (stack) SGRPassView(stack, ^(UIView *v) { dressDefault(v); });
}
