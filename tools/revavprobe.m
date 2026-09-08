// revavprobe — ask AVFoundation directly whether it can open a URL, outside the
// engine. Prints the AVPlayerItem status and error for each URL given, so a
// playback failure can be attributed to AVFoundation itself rather than to the
// WebKit media pipeline.
//
//   revavprobe file:///tmp/sample.mp4 http://host/sample.mp4

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#include <unistd.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: revavprobe <url> [url...]\n"); return 2; }

        for (int i = 1; i < argc; i++) {
            NSString *s = [NSString stringWithUTF8String:argv[i]];
            NSURL *url = [NSURL URLWithString:s];
            printf("=== %s\n", argv[i]);
            if (!url) { printf("  bad URL\n"); continue; }

            AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:url options:nil];
            printf("  asset=%p playable=%d tracks=%lu\n", asset,
                (int)[asset isPlayable], (unsigned long)[[asset tracks] count]);

            AVPlayerItem *item = [[AVPlayerItem alloc] initWithAsset:asset];
            AVPlayer *player = [[AVPlayer alloc] init];
            [player replaceCurrentItemWithPlayerItem:item];

            for (int t = 0; t < 60; t++) {
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
                AVPlayerItemStatus st = [item status];
                if (st != AVPlayerItemStatusUnknown) {
                    NSError *e = [item error];
                    printf("  status=%d after %.2fs err='%s' domain='%s' code=%ld\n",
                        (int)st, t * 0.25,
                        e ? [[e localizedDescription] UTF8String] : "(none)",
                        e ? [[e domain] UTF8String] : "-",
                        e ? (long)[e code] : 0L);
                    CMTime d = [item duration];
                    printf("  duration=%.3f\n", CMTIME_IS_NUMERIC(d) ? CMTimeGetSeconds(d) : -1.0);
                    break;
                }
                if (t == 59)
                    printf("  status stayed Unknown after 15s\n");
            }
        }
    }
    return 0;
}
