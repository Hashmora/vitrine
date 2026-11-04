#import "AutoMixPolicy.h"

NSInteger SGAutoMixPolicyBlend(double durationSeconds, NSInteger baseMilliseconds, BOOL continues, BOOL episode,
                               NSString **reason) {
    NSString *why = @"as set";
    NSInteger result = MAX(0, baseMilliseconds);
    if (episode) {
        result = 0; why = @"episode";
    } else if (continues) {
        result = 0; why = @"continues on the album";
    } else if (durationSeconds > 0 && result > 0 && durationSeconds * 1000.0 < 4.0 * result) {
        // A whole second at least, but never longer than the song itself leaves room for.
        NSInteger quarter = (NSInteger)(durationSeconds * 250.0);
        result = MIN(result, MAX(1000, quarter));
        why = @"short song";
    }
    if (reason) *reason = why;
    return result;
}

BOOL SGAutoMixPolicyContinues(NSString *contextURI, NSString *currentAlbum, NSString *nextAlbum) {
    if ([contextURI hasPrefix:@"spotify:album:"]) return YES;
    return currentAlbum.length > 0 && [currentAlbum isEqualToString:nextAlbum];
}
