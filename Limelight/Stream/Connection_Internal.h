//
//  Connection_Internal.h
//  Moonlight
//
//  Shared class extension for Connection and its categories. Not part of the
//  public interface; only Connection*.m files import it.
//

#import "Connection.h"
#import "LogBuffer.h"
#import "Utils.h"

#import "Moonlight-Swift.h"

#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/CoreAudio.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <os/lock.h>

#import <arpa/inet.h>
#include <netinet/in.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>

#include "Limelight.h"
#include "opus_multistream.h"
#import "MLHdrMode.h"

#define AUDIO_QUEUE_BUFFERS 4
#define AUDIO_DIRECT_BUFFER_DURATION 55
#define AUDIO_ENHANCED_BUFFER_DURATION 60
#define AUDIO_RENDER_SCRATCH_FRAMES 2048

typedef NS_ENUM(NSInteger, MLAudioOutputMode) {
    MLAudioOutputModeDirect = 0,
    MLAudioOutputModeEnhanced = 1,
};

typedef NS_ENUM(NSInteger, MLAudioEnhancedOutputTarget) {
    MLAudioEnhancedOutputTargetHeadphones = 0,
    MLAudioEnhancedOutputTargetSpeakers = 1,
    MLAudioEnhancedOutputTargetAutomatic = 2,
};

typedef NS_ENUM(NSInteger, MLAudioRendererBackend) {
    MLAudioRendererBackendLegacyQueue = 0,
    MLAudioRendererBackendDirect = 1,
    MLAudioRendererBackendEnhanced = 2,
};

@interface Connection () {
    SERVER_INFORMATION _serverInfo;
    STREAM_CONFIGURATION _streamConfig;
    CONNECTION_LISTENER_CALLBACKS _clCallbacks;
    DECODER_RENDERER_CALLBACKS _drCallbacks;
    AUDIO_RENDERER_CALLBACKS _arCallbacks;
    char _hostString[256];
    char _appVersionString[32];
    char _gfeVersionString[32];
    char _rtspSessionUrl[1024];

    NSLock *_initLock;

    VideoDecoderRenderer *_renderer;
    id<ConnectionCallbacks> _callbacks;

    OpusMSDecoder *_opusDecoder;
    int _audioBufferEntries;
    int _audioBufferWriteIndex;
    int _audioBufferReadIndex;
    int _audioBufferStride;
    int _audioSamplesPerFrame;
    short *_audioCircularBuffer;

    int _channelCount;
    float _audioVolumeMultiplier;
    NSString *_hostAddress;
    int _currentUpscalingMode;
    StreamConfiguration *_rendererStreamConfig;
    os_unfair_lock _stateLock;
    UInt32 _audioBufferReadFrameOffset;
    short *_audioRenderScratchBuffer;

    int _audioOutputMode;
    int _enhancedAudioOutputTarget;
    int _enhancedAudioPreset;
    CGFloat _enhancedAudioSpatialIntensity;
    CGFloat _enhancedAudioSoundstageWidth;
    CGFloat _enhancedAudioReverbAmount;
    NSArray<NSNumber *> *_enhancedAudioEQGains;
    int _audioDeviceChannelCount;
    int _audioRenderChannelCount;
    MLAudioRendererBackend _audioRendererBackend;

    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _audioBuffers[AUDIO_QUEUE_BUFFERS];
    void *_audioQueueContext;
    AudioComponentInstance _audioUnit;
    AVAudioEngine *_enhancedAudioEngine;
    AVAudioSourceNode *_enhancedAudioSourceNode;
    AVAudioUnitReverb *_enhancedAudioReverb;
    AVAudioUnitEQ *_enhancedAudioEQ;
    AVAudioConverter *_enhancedDownmixConverter;
    AVAudioPCMBuffer *_enhancedDownmixInputBuffer;
    AVAudioPCMBuffer *_enhancedDownmixOutputBuffer;
    BOOL _enhancedUsesCoreAudioDownmix;
    uint64_t _enhancedDownmixFailureCount;
    uint64_t _audioUnderrunCount;
    BOOL _audioDecodeThreadPriorityRaised;
    uint64_t _audioDecodeSampleCount;
    uint64_t _audioDecodeFailureCount;
    uint64_t _audioConsecutiveDecodeFailures;
    uint64_t _audioFallbackDecodeSuccessCount;
    OPUS_MULTISTREAM_CONFIGURATION _audioAdvertisedOpusConfig;
    OPUS_MULTISTREAM_CONFIGURATION _audioCurrentDecoderConfig;
    OPUS_MULTISTREAM_CONFIGURATION _audioFallbackDecoderConfig;
    BOOL _hasAudioFallbackDecoderConfig;
    BOOL _usingAudioFallbackDecoderConfig;
    BOOL _audioPrimaryReprobeAttempted;

    dispatch_queue_t _micQueue;
    OpusMSEncoder* _micEncoder;
    NSMutableData* _micPcmQueue;
    int _micSendFailures;
    BOOL _micStopping;
    BOOL _micEncryptionStatusLogged;
    BOOL _disableHighQualitySurround;
    BOOL _clipboardReady;
}

@property (nonatomic, strong) AVAudioEngine* micAudioEngine;
@property (nonatomic, strong) AVAudioConverter* micConverter;
@property (nonatomic, strong) AVAudioFormat* micOutputFormat;
- (BOOL)initializeDirectAudioRendererWithOpusConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
                                      channelLayout:(const AudioChannelLayout *)channelLayout;
- (BOOL)initializeEnhancedAudioRendererWithOpusConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig;
- (void)cleanupSelectedAudioRenderer;
- (void)configureEnhancedAudioUnits;
- (BOOL)prepareEnhancedDownmixConverterWithOpusConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig;
- (void)copyPCMFrames:(UInt32)frameCount toInterleavedBuffer:(short *)outputBuffer;
- (void)copyPCMFrames:(UInt32)frameCount
 toFloatBufferList:(AudioBufferList *)outputData
 expectedChannels:(UInt32)expectedChannels;
- (void)renderEnhancedStereoPCMFrames:(UInt32)frameCount
                    toFloatBufferList:(AudioBufferList *)outputData;
- (BOOL)recreateAudioDecoderWithConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
                                reason:(NSString *)reason;
- (BOOL)attempt714DecoderTopologyFallbackAfterDecodeError:(int)decodeError;
- (BOOL)attempt714PrimaryDecoderReprobeWithSampleData:(char *)sampleData
                                         sampleLength:(int)sampleLength;
- (void)updateVolume;

// Microphone (Connection+Microphone.m)
- (void)startMicrophoneIfNeeded;
- (void)stopMicrophoneIfNeeded;

@end

/// The connection the protocol library is currently driving, or nil.
Connection *CurrentConnection(void);
VideoDecoderRenderer *ConnectionGetRendererSnapshot(Connection *conn);
id<ConnectionCallbacks> ConnectionGetCallbacksSnapshot(Connection *conn);
void ConnectionSetRenderer(Connection *conn, VideoDecoderRenderer *renderer);
void ConnectionSetCallbacks(Connection *conn, id<ConnectionCallbacks> callbacks);
void ConnectionClearRuntimeTargets(Connection *conn);

// Audio helpers (Connection+Audio.m)
MLAudioEnhancedOutputTarget MLResolveEnhancedOutputTarget(MLAudioEnhancedOutputTarget configuredTarget);

// Audio renderer callbacks (Connection+Audio.m)
int ArInit(int audioConfiguration, POPUS_MULTISTREAM_CONFIGURATION originalOpusConfig, void* context, int flags);
void ArCleanup(void);
void ArDecodeAndPlaySample(char* sampleData, int sampleLength);

// 7.1.4 topology helpers (Connection+Surround.m)
BOOL MLIs714HighQualityOpusConfig(const OPUS_MULTISTREAM_CONFIGURATION *opusConfig);
BOOL MLIs714CompatibilityOpusConfig(const OPUS_MULTISTREAM_CONFIGURATION *opusConfig);
void MLPrepareOpusDecoderConfig(const OPUS_MULTISTREAM_CONFIGURATION *sourceConfig,
                                OPUS_MULTISTREAM_CONFIGURATION *preparedConfig);

// Clipboard listener callback (Connection+Clipboard.m)
void ClClipboardData(const char* data, int length);

// Cursor listener callback (Connection+Cursor.m)
void ClCursorUpdate(const LI_CURSOR_UPDATE* update);
