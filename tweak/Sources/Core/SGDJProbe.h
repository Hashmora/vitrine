// Optional, read-only runtime probes for PR #227. Never linked into release behaviour.
#import <Foundation/Foundation.h>
#include <stdint.h>

#if SG_DRIVER
FOUNDATION_EXPORT void SGDJProbeRecord(NSString *kind, NSDictionary<NSString *, id> *data);
FOUNDATION_EXPORT NSDictionary *SGDJProbeRead(uint64_t since, NSUInteger maxEvents);
FOUNDATION_EXPORT NSString *SGDJProbeTag(NSString *identifier);
FOUNDATION_EXPORT void SGDJProbeArtworkDecision(BOOL confirmed, BOOL playlist);
#define SGDJ_TRACE(kind, fields) SGDJProbeRecord((kind), (fields))
#else
#define SGDJ_TRACE(kind, fields) do {} while (0)
#define SGDJProbeArtworkDecision(confirmed, playlist) do {} while (0)
#endif
