// AutoMixPolicy.m on its own: the blend each kind of pair gets.
#import <Foundation/Foundation.h>
#import "Shared/AutoMix/AutoMixPolicy.h"

static int failures;
static void check(const char *name, NSInteger got, NSInteger want, NSString *reason, NSString *wantReason) {
    BOOL ok = got == want && [reason isEqualToString:wantReason];
    printf("%s %s: %ld ms (%s)\n", ok ? "ok  " : "FAIL", name, (long)got, reason.UTF8String);
    if (!ok) { failures++; printf("     wanted %ld ms (%s)\n", (long)want, wantReason.UTF8String); }
}

int main(void) {
    @autoreleasepool {
        NSString *r;
        NSInteger ms;
        ms = SGAutoMixPolicyBlend(210, 5000, NO, NO, &r);  check("ordinary song", ms, 5000, r, @"as set");
        ms = SGAutoMixPolicyBlend(210, 5000, YES, NO, &r); check("album continues", ms, 0, r, @"continues on the album");
        ms = SGAutoMixPolicyBlend(3000, 5000, NO, YES, &r); check("episode", ms, 0, r, @"episode");
        ms = SGAutoMixPolicyBlend(3000, 5000, YES, YES, &r); check("episode beats album", ms, 0, r, @"episode");
        ms = SGAutoMixPolicyBlend(12, 5000, NO, NO, &r);   check("12 s jingle", ms, 3000, r, @"short song");
        ms = SGAutoMixPolicyBlend(2, 5000, NO, NO, &r);    check("2 s clip, a second at least", ms, 1000, r, @"short song");
        ms = SGAutoMixPolicyBlend(20, 5000, NO, NO, &r);   check("exactly four lengths", ms, 5000, r, @"as set");
        ms = SGAutoMixPolicyBlend(0, 5000, NO, NO, &r);    check("unknown length", ms, 5000, r, @"as set");
        ms = SGAutoMixPolicyBlend(210, 0, NO, NO, &r);     check("base 0 stays 0", ms, 0, r, @"as set");
        check("album context", SGAutoMixPolicyContinues(@"spotify:album:abc", nil, nil), 1, @"x", @"x");
        check("same album name", SGAutoMixPolicyContinues(@"spotify:playlist:p", @"Live", @"Live"), 1, @"x", @"x");
        check("other album", SGAutoMixPolicyContinues(@"spotify:playlist:p", @"A", @"B"), 0, @"x", @"x");
        check("no album names", SGAutoMixPolicyContinues(nil, nil, nil), 0, @"x", @"x");
        printf(failures ? "%d failed\n" : "all passed\n", failures);
    }
    return failures ? 1 : 0;
}
