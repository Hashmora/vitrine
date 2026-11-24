// Native macOS fallback for Stage 188. Uses only frameworks shipped with Xcode/macOS.
// Decode every presentation-order video sample with AVAssetReader; store PNG + PTS.
// Build: xcrun clang -fobjc-arc -O2 -Wno-deprecated-declarations \
//        -framework Foundation -framework AVFoundation -framework CoreImage \
//        -framework CoreMedia -framework CoreVideo -framework CoreGraphics \
//        stage188-avfoundation-extract.m -o stage188-avfoundation-extract
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

static int fail(NSString *message) {
    fprintf(stderr, "stage188 AVFoundation: %s\n", message.UTF8String);
    return 1;
}

static id secondsOrNull(CMTime time) {
    double seconds = CMTimeGetSeconds(time);
    return (CMTIME_IS_VALID(time) && isfinite(seconds)) ? @(seconds) : [NSNull null];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            return fail(@"usage: stage188-avfoundation-extract VIDEO.mp4 FRAMES_DIR MAX_FRAMES (0 = all)");
        }
        NSString *videoPath = [NSString stringWithUTF8String:argv[1]];
        NSString *framesPath = [NSString stringWithUTF8String:argv[2]];
        NSInteger limit = [[NSString stringWithUTF8String:argv[3]] integerValue];
        if (limit < 0) return fail(@"MAX_FRAMES must be nonnegative");

        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:framesPath
                                       withIntermediateDirectories:YES attributes:nil error:&error]) {
            return fail([NSString stringWithFormat:@"frames directory: %@", error]);
        }
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:videoPath] options:nil];
        NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (tracks.count < 1) return fail(@"no video track in recording");
        AVAssetTrack *track = tracks.firstObject;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        if (!reader) return fail([NSString stringWithFormat:@"reader: %@", error]);
        NSDictionary *settings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
        AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
                                            initWithTrack:track outputSettings:settings];
        output.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:output]) return fail(@"cannot add video track output");
        [reader addOutput:output];
        if (![reader startReading]) return fail([NSString stringWithFormat:@"startReading: %@", reader.error]);

        CIContext *context = [CIContext contextWithOptions:nil];
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        if (!srgb) return fail(@"unable to create sRGB color space");
        NSMutableArray *timestamps = [NSMutableArray array];
        NSUInteger count = 0;
        size_t width = 0, height = 0;
        BOOL truncated = NO;
        BOOL failed = NO;
        NSString *failureDescription = nil;

        while (YES) {
            @autoreleasepool {
                CMSampleBufferRef sample = [output copyNextSampleBuffer];
                if (!sample) break;
                CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sample);
                if (!pixelBuffer) {
                    failed = YES;
                    failureDescription = @"video sample has no decoded image buffer";
                    CFRelease(sample);
                    break;
                }
                if (!width) {
                    width = CVPixelBufferGetWidth(pixelBuffer);
                    height = CVPixelBufferGetHeight(pixelBuffer);
                }
                CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
                NSString *name = [NSString stringWithFormat:@"frame_%06lu.png", (unsigned long)count];
                NSURL *target = [NSURL fileURLWithPath:[framesPath stringByAppendingPathComponent:name]];
                NSError *pngError = nil;
                BOOL ok = [context writePNGRepresentationOfImage:image toURL:target
                                                         format:kCIFormatRGBA8 colorSpace:srgb
                                                        options:@{} error:&pngError];
                if (!ok) {
                    failed = YES;
                    failureDescription = [NSString stringWithFormat:@"PNG %@: %@", name, pngError];
                    CFRelease(sample);
                    break;
                }
                id pts = secondsOrNull(CMSampleBufferGetPresentationTimeStamp(sample));
                id dur = secondsOrNull(CMSampleBufferGetDuration(sample));
                [timestamps addObject:@{@"frame_index":@(count),
                                        @"filename":name,
                                        @"best_effort_timestamp_time":pts,
                                        @"pkt_duration_time":dur}];
                count++;
                CFRelease(sample);
                if (limit > 0 && count >= (NSUInteger)limit) {
                    truncated = YES;
                    break;
                }
            }
        }
        if (truncated || failed) [reader cancelReading];
        CGColorSpaceRelease(srgb);
        if (failed) return fail(failureDescription);
        if (!truncated && reader.status == AVAssetReaderStatusFailed) {
            return fail([NSString stringWithFormat:@"reading MP4: %@", reader.error]);
        }
        if (!count) return fail(@"zero video frames decoded");
        NSDictionary *result = @{
            @"backend":@"AVFoundation (native macOS, no ffmpeg)",
            @"decoded_frames":@(count),
            @"width":@(width), @"height":@(height),
            @"duration_seconds":secondsOrNull(asset.duration),
            @"nominal_frame_rate":@(track.nominalFrameRate),
            @"truncated_by_max_frames":@(truncated),
            @"frames":timestamps,
            @"note":@"Frames follow decoded presentation order. PTS are relative to MP4, not SG_DRIVER's monotonic clock. Recording itself may omit compositor refreshes."
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:result
                                                     options:NSJSONWritingPrettyPrinted error:&error];
        if (!data) return fail([NSString stringWithFormat:@"metadata serialization: %@", error]);
        NSString *metadataPath = [framesPath stringByAppendingPathComponent:@"native-extraction.json"];
        if (![data writeToFile:metadataPath options:NSDataWritingAtomic error:&error]) {
            return fail([NSString stringWithFormat:@"metadata write: %@", error]);
        }
        fprintf(stdout, "Decoded %lu frames %lux%lu using AVFoundation\n",
                (unsigned long)count, (unsigned long)width, (unsigned long)height);
        return 0;
    }
}
