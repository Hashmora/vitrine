#!/usr/bin/env python3
"""Check New DJ set mode isolation and, on macOS, the production page predicate."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
queue = (root / 'tweak/Sources/Shared/Player/DJQueue.x').read_text()
settings = (root / 'tweak/Sources/Shared/Player/PlayerSettings.m').read_text()
pick = (root / 'tweak/Sources/Shared/Player/DJPick.x').read_text()

def function(name):
    match = re.search(r'^static [^\n]*\b' + re.escape(name) + r'\([^\n]*\) \{', queue, re.M)
    assert match, f'missing {name}'
    start = match.start()
    pos, depth = match.end(), 1
    while depth:
        if queue[pos] == '{': depth += 1
        elif queue[pos] == '}': depth -= 1
        pos += 1
    return queue[start:pos]

skip = function('skipToNextDJSegment')
poll = function('pollNextSegmentSkip')
assert 'SGDJQueueBeginPick()' in skip and 'SGPlayerSetDJTransitionMuted(YES)' in skip
assert 'skipForward(anchor)' in poll and 'skipForward(next)' in poll
assert 'jumpWithCompletion:' not in skip + poll
assert 'signal:parameters:' not in skip + poll
assert 'SGInt(SGKeyDJQueueSetMode, SGDJQueueSetModeSkip)' in queue
assert 'SGChoiceRow(@"New DJ set action"' in settings
assert 'SGDJQueueSetModeSkip)' in settings
assert 'SGOptionRow(@"Neutral request fallback"' in settings
assert 'SGFlag(SGKeyDJPickFallback, NO)' in pick
print('New DJ set settings and request isolation: PASS')

if sys.platform != 'darwin':
    print('Page identity predicate: macOS/Foundation required (not run)')
    sys.exit(0)

prelude = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
@interface SPTPlayerTrack : NSObject
@property NSString *URI, *UID, *provider;
@property NSDictionary *metadata;
@end
@implementation SPTPlayerTrack @end
static NSString *sNextSegmentPage;
static NSSet<NSString *> *sNextSegmentOldUIDs;
static NSString *SGURIString(id uri) { return uri; }
static BOOL isCoreQueued(SPTPlayerTrack *t) { return [t.provider isEqualToString:@"queue"]; }
static BOOL isDJTrack(SPTPlayerTrack *t) { return [t.URI hasPrefix:@"spotify:track:"]; }
static NSString *baseUID(NSString *uid) { return uid; }
'''
tests = r'''
static SPTPlayerTrack *track(NSString *uri, NSString *uid, NSString *page, NSString *provider) {
    SPTPlayerTrack *t = [SPTPlayerTrack new]; t.URI = uri; t.UID = uid;
    t.metadata = page ? @{@"page_instance_id":page} : @{}; t.provider = provider; return t;
}
int main(void) { @autoreleasepool {
    sNextSegmentPage = @"old-page";
    sNextSegmentOldUIDs = [NSSet setWithArray:@[@"old-intro", @"old-song", @"old-outro"]];
    assert(!isNewSegmentItem(track(@"spotify:track:old", @"old-song", @"old-page", @"context")));
    assert(!isNewSegmentItem(track(@"spotify:track:old", @"old-song", nil, @"context")));
    assert(!isNewSegmentItem(track(@"spotify:media:outro", @"old-outro", nil, @"context")));
    assert(!isNewSegmentItem(track(@"spotify:track:old", @"new-uid", @"old-page", @"context")));
    assert(isNewSegmentItem(track(@"spotify:media:intro", @"old-intro", @"new-page", @"context")));
    assert(isNewSegmentItem(track(@"spotify:track:new", @"new-uid", nil, @"context")));
    assert(!isNewSegmentItem(track(@"spotify:track:new", @"new-uid", @"new-page", @"queue")));
    assert(!isNewSegmentItem(track(@"spotify:delimiter", @"delimiter", nil, @"context")));
    puts("Page identity predicate: PASS");
} }
'''
with tempfile.TemporaryDirectory(prefix='vitrine-dj-next-') as path:
    source = Path(path) / 'test.m'
    output = Path(path) / 'test'
    source.write_text(prelude + '\n' + function('isNewSegmentItem') + '\n' + tests)
    subprocess.run(['clang', '-fobjc-arc', '-framework', 'Foundation', str(source), '-o', str(output)], check=True)
    subprocess.run([str(output)], check=True)
