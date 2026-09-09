//
//  Connection.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamConfiguration.h"
#import "VideoDecoderRenderer.h"
#import "Limelight.h"
#import "MLClipboardFrame.h"

@protocol ConnectionCallbacks <NSObject>

- (void)connectionStarted;
- (void)connectionTerminated:(int)errorCode;
- (void)stageStarting:(const char *)stageName;
- (void)stageComplete:(const char *)stageName;
- (void)stageFailed:(const char *)stageName withError:(int)errorCode;
- (void)launchFailed:(NSString *)message;
- (void)rumble:(unsigned short)controllerNumber
     lowFreqMotor:(unsigned short)lowFreqMotor
    highFreqMotor:(unsigned short)highFreqMotor;
- (void)connectionStatusUpdate:(int)status;

@optional
/// Delivered on the main queue for every clipboard frame the host sends.
- (void)clipboardFrameReceived:(MLClipboardFrame *)frame;
/// Delivered on the main queue when the host cursor changes shape or visibility.
/// `cursor` is nil when only visibility changed.
- (void)hostCursorUpdated:(NSCursor *)cursor visible:(BOOL)visible;

@end

/// Point-in-time video transport counters from the protocol library.
typedef struct {
    uint32_t videoPackets;
    uint32_t fecPackets;
    uint32_t fecRecoveredPackets;
    uint32_t fecFailedPackets;
    uint32_t outOfSequencePackets;
    uint32_t invalidPackets;
    uint64_t bytesReceived;
    double frameLossPercent;
    int pendingFrames;
} MLVideoDiagnosticSnapshot;

@interface Connection : NSOperation <NSStreamDelegate>

/// Returns the active connection, if any.
+ (Connection *)currentConnection;

@property(nonatomic, readonly) VideoDecoderRenderer *renderer;

- (id)initWithConfig:(StreamConfiguration *)config
               renderer:(VideoDecoderRenderer *)myRenderer
    connectionCallbacks:(id<ConnectionCallbacks>)callbacks;
/// Returns NO until the control stream has an RTT estimate.
- (BOOL)getEstimatedRtt:(uint32_t *)rttMs variance:(uint32_t *)varianceMs;
/// YES between connectionStarted and termination. The clipboard channel needs no separate binding.
@property (atomic, readonly) BOOL clipboardReady;
/// Sends one clipboard frame. Returns NO when the connection is not ready, the host
/// does not support the clipboard channel, or the frame is invalid.
- (BOOL)sendClipboardFrame:(MLClipboardFrame *)frame;
/// Feature bits advertised by the host (LI_FF_*). Valid after connectionStarted.
- (uint32_t)hostFeatureFlags;
/// Asks the host to stop drawing its cursor into the video and send shapes instead
/// (YES), or to draw it again (NO). Returns NO when the host lacks the capability.
- (BOOL)setLocalCursorRendering:(BOOL)enabled;
/// Fills transport counters for diagnostics. Returns NO when no snapshot is available.
- (BOOL)getVideoDiagnosticSnapshot:(MLVideoDiagnosticSnapshot *)snapshot;
- (void)terminate;
- (void)main;

@end
