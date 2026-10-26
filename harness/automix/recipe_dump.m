// Generic protobuf wire decoder for Spotify's automix.auto_transition_recipe.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdint.h>

static BOOL varint(const uint8_t *p, NSUInteger n, NSUInteger *at, uint64_t *out) {
    uint64_t value = 0;
    for (int shift = 0; shift < 64 && *at < n; shift += 7) {
        uint8_t b = p[(*at)++];
        value |= (uint64_t)(b & 0x7f) << shift;
        if (!(b & 0x80)) { *out = value; return YES; }
    }
    return NO;
}

static void dump(const uint8_t *p, NSUInteger n, int depth) {
    NSUInteger at = 0;
    while (at < n) {
        uint64_t tag;
        if (!varint(p, n, &at, &tag) || tag < 8) { printf("%*sINVALID\n", depth * 2, ""); return; }
        uint64_t field = tag >> 3, wire = tag & 7, value;
        printf("%*sfield %llu wire %llu ", depth * 2, "", field, wire);
        if (wire == 0) {
            if (!varint(p, n, &at, &value)) { puts("TRUNCATED"); return; }
            printf("varint %llu (0x%llx)\n", value, value);
        } else if (wire == 1) {
            if (at + 8 > n) { puts("TRUNCATED"); return; }
            printf("fixed64 0x"); for (int i = 7; i >= 0; i--) printf("%02x", p[at + i]);
            puts(""); at += 8;
        } else if (wire == 2) {
            if (!varint(p, n, &at, &value) || value > n - at) { puts("TRUNCATED"); return; }
            NSUInteger len = (NSUInteger)value;
            printf("bytes %lu", (unsigned long)len);
            BOOL printable = len > 0 && len < 4096;
            for (NSUInteger i = 0; i < len && printable; i++)
                if (p[at + i] < 0x20 || p[at + i] > 0x7e) printable = NO;
            if (printable) printf(" string=\"%.*s\"", (int)len, p + at);
            puts("");
            if (len > 0 && len < 65536) {
                printf("%*smessage {\n", depth * 2, "");
                dump(p + at, len, depth + 1);
                printf("%*s}\n", depth * 2, "");
            }
            at += len;
        } else if (wire == 5) {
            if (at + 4 > n) { puts("TRUNCATED"); return; }
            printf("fixed32 0x%02x%02x%02x%02x\n", p[at+3], p[at+2], p[at+1], p[at]); at += 4;
        } else { puts("unsupported"); return; }
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "usage: recipe-dump BASE64_RECIPE\n"); return 1; }
        NSData *data = [[NSData alloc] initWithBase64EncodedString:[NSString stringWithUTF8String:argv[1]] options:0];
        if (!data.length) { fprintf(stderr, "invalid or empty base64\n"); return 1; }
        printf("decoded %lu bytes\n", (unsigned long)data.length);
        dump(data.bytes, data.length, 0);
    }
    return 0;
}
