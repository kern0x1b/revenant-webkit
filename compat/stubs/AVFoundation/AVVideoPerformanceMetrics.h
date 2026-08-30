/* Not in this SDK. WebKit reads these counters through a soft-linked object that
 * never exists on iOS 6, so the declarations only have to typecheck. */
#pragma once
#import <Foundation/Foundation.h>
@interface AVVideoPerformanceMetrics : NSObject
@property (readonly) NSUInteger totalNumberOfVideoFrames;
@property (readonly) NSUInteger numberOfDroppedVideoFrames;
@property (readonly) NSUInteger numberOfCorruptedVideoFrames;
@property (readonly) NSUInteger numberOfDisplayCompositedVideoFrames;
@property (readonly) NSTimeInterval totalFrameDelay;
@end
