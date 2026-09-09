//
//  Connection+Audio.m
//  Moonlight
//
//  Core Audio output: the legacy queue, direct AudioUnit and enhanced AVAudioEngine backends.
//

#import "Connection_Internal.h"

#define OUTPUT_BUS 0

// My iPod touch 5th Generation seems to really require 80 ms
// of buffering to deliver glitch-free playback :(
// FIXME: Maybe we can use a smaller buffer on more modern iOS versions?
#define CIRCULAR_BUFFER_DURATION 80

static void FillOutputBuffer(void *aqData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer);

@implementation Connection (Audio)

static const float kDirectRendererMakeupGain = 1.24f;
static const float kEnhancedRendererOutputGain = 1.08f;

static const double kLegacyEnhancedEQFrequencies[] = {
    32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0,
};
static const NSUInteger kLegacyEnhancedEQBandCount = sizeof(kLegacyEnhancedEQFrequencies) / sizeof(kLegacyEnhancedEQFrequencies[0]);
static const double kEnhancedEQFrequencies12Band[] = {
    32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 6000.0, 8000.0, 12000.0, 16000.0,
};
static const NSUInteger kEnhancedEQBandCount12 = sizeof(kEnhancedEQFrequencies12Band) / sizeof(kEnhancedEQFrequencies12Band[0]);
static const double kEnhancedEQFrequencies24Band[] = {
    20.0, 25.0, 32.0, 40.0, 50.0, 63.0, 80.0, 100.0, 125.0, 160.0, 200.0, 250.0,
    315.0, 400.0, 500.0, 630.0, 800.0, 1000.0, 1600.0, 2500.0, 4000.0, 6300.0, 10000.0, 16000.0,
};
static const NSUInteger kEnhancedEQBandCount24 = sizeof(kEnhancedEQFrequencies24Band) / sizeof(kEnhancedEQFrequencies24Band[0]);

static inline float MLApplyMakeupGainAndSoftClip(float sample, float gain) {
    float x = sample * gain;
    float ax = fabsf(x);
    if (ax <= 0.85f) {
        return x;
    }

    float excess = ax - 0.85f;
    float compressed = 0.85f + (excess / (1.0f + excess * 6.0f));
    return copysignf(MIN(compressed, 1.0f), x);
}

static int MLDefaultOutputChannelCount(void) {
    AudioDeviceID deviceID = kAudioObjectUnknown;
    UInt32 propertySize = sizeof(deviceID);
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    if (AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                   &address,
                                   0,
                                   NULL,
                                   &propertySize,
                                   &deviceID) != noErr || deviceID == kAudioObjectUnknown) {
        return 2;
    }

    AudioObjectPropertyAddress streamConfigAddress = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    UInt32 streamConfigSize = 0;
    if (AudioObjectGetPropertyDataSize(deviceID,
                                       &streamConfigAddress,
                                       0,
                                       NULL,
                                       &streamConfigSize) != noErr || streamConfigSize == 0) {
        return 2;
    }

    AudioBufferList *bufferList = (AudioBufferList *)malloc(streamConfigSize);
    if (bufferList == NULL) {
        return 2;
    }

    int channels = 2;
    if (AudioObjectGetPropertyData(deviceID,
                                   &streamConfigAddress,
                                   0,
                                   NULL,
                                   &streamConfigSize,
                                   bufferList) == noErr) {
        channels = 0;
        for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) {
            channels += (int)bufferList->mBuffers[i].mNumberChannels;
        }
        if (channels <= 0) {
            channels = 2;
        }
    }

    free(bufferList);
    return channels;
}

static NSString *MLDefaultOutputDeviceName(void) {
    AudioDeviceID deviceID = kAudioObjectUnknown;
    UInt32 propertySize = sizeof(deviceID);
    AudioObjectPropertyAddress deviceAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    if (AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                   &deviceAddress,
                                   0,
                                   NULL,
                                   &propertySize,
                                   &deviceID) != noErr || deviceID == kAudioObjectUnknown) {
        return @"Unknown Output";
    }

    CFStringRef deviceName = NULL;
    propertySize = sizeof(deviceName);
    AudioObjectPropertyAddress nameAddress = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(deviceID,
                                   &nameAddress,
                                   0,
                                   NULL,
                                   &propertySize,
                                   &deviceName) != noErr || deviceName == NULL) {
        return @"Unknown Output";
    }

    return CFBridgingRelease(deviceName);
}

static UInt32 MLDefaultOutputTransportType(void) {
    AudioDeviceID deviceID = kAudioObjectUnknown;
    UInt32 propertySize = sizeof(deviceID);
    AudioObjectPropertyAddress deviceAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    if (AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                   &deviceAddress,
                                   0,
                                   NULL,
                                   &propertySize,
                                   &deviceID) != noErr || deviceID == kAudioObjectUnknown) {
        return 0;
    }

    UInt32 transportType = 0;
    propertySize = sizeof(transportType);
    AudioObjectPropertyAddress transportAddress = {
        kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(deviceID,
                                   &transportAddress,
                                   0,
                                   NULL,
                                   &propertySize,
                                   &transportType) != noErr) {
        return 0;
    }

    return transportType;
}

static BOOL MLDefaultOutputLooksLikeHeadphones(NSString *deviceName, UInt32 transportType, int channelCount) {
    NSString *normalized = deviceName.lowercaseString ?: @"";
    NSArray<NSString *> *headphoneHints = @[
        @"airpods", @"headphone", @"headset", @"earbud", @"耳机", @"buds", @"qc ", @"wh-", @"wf-"
    ];
    for (NSString *hint in headphoneHints) {
        if ([normalized containsString:hint]) {
            return YES;
        }
    }

    NSArray<NSString *> *speakerHints = @[
        @"speaker", @"display", @"monitor", @"hdmi", @"tv", @"studio display", @"homepod", @"音箱"
    ];
    for (NSString *hint in speakerHints) {
        if ([normalized containsString:hint]) {
            return NO;
        }
    }

    if (channelCount > 2) {
        return NO;
    }

    switch (transportType) {
        case kAudioDeviceTransportTypeBluetooth:
        case kAudioDeviceTransportTypeBluetoothLE:
        case kAudioDeviceTransportTypeUSB:
            return YES;
        default:
            return NO;
    }
}

MLAudioEnhancedOutputTarget MLResolveEnhancedOutputTarget(MLAudioEnhancedOutputTarget configuredTarget) {
    if (configuredTarget != MLAudioEnhancedOutputTargetAutomatic) {
        return configuredTarget;
    }

    NSString *deviceName = MLDefaultOutputDeviceName();
    UInt32 transportType = MLDefaultOutputTransportType();
    int channelCount = MLDefaultOutputChannelCount();
    BOOL headphones = MLDefaultOutputLooksLikeHeadphones(deviceName, transportType, channelCount);
    Log(LOG_I, @"Enhanced output target auto-resolved: device=%@ transport=%u channels=%d target=%@",
        deviceName,
        (unsigned int)transportType,
        channelCount,
        headphones ? @"Headphones" : @"Speakers");
    return headphones ? MLAudioEnhancedOutputTargetHeadphones : MLAudioEnhancedOutputTargetSpeakers;
}

static const double *MLEnhancedEQFrequencyTable(NSUInteger bandCount, NSUInteger *resolvedBandCount) {
    switch (bandCount) {
        case 24:
            if (resolvedBandCount != NULL) {
                *resolvedBandCount = kEnhancedEQBandCount24;
            }
            return kEnhancedEQFrequencies24Band;
        case 12:
        case 0:
            if (resolvedBandCount != NULL) {
                *resolvedBandCount = kEnhancedEQBandCount12;
            }
            return kEnhancedEQFrequencies12Band;
        case 10:
        default:
            if (resolvedBandCount != NULL) {
                *resolvedBandCount = kLegacyEnhancedEQBandCount;
            }
            return kLegacyEnhancedEQFrequencies;
    }
}

static AudioChannelLayoutTag MLChannelLayoutTagForChannelCount(int channelCount) {
    switch (channelCount) {
        case 1:
            return kAudioChannelLayoutTag_Mono;
        case 2:
            return kAudioChannelLayoutTag_Stereo;
        case 4:
            return kAudioChannelLayoutTag_Quadraphonic;
        case 6:
            return kAudioChannelLayoutTag_AudioUnit_5_1;
        case 8:
            return kAudioChannelLayoutTag_AudioUnit_7_1;
        case 12:
            return kAudioChannelLayoutTag_Atmos_7_1_4;
        default:
            return kAudioChannelLayoutTag_UseChannelDescriptions;
    }
}

static void MLFillChannelLayout(AudioChannelLayout *channelLayout, int channelCount) {
    memset(channelLayout, 0, sizeof(AudioChannelLayout));
    channelLayout->mChannelLayoutTag = MLChannelLayoutTagForChannelCount(channelCount);
}

static AVAudioChannelLayout *MLCreateAVAudioChannelLayout(int channelCount) {
    AudioChannelLayoutTag tag = MLChannelLayoutTagForChannelCount(channelCount);
    if (tag == kAudioChannelLayoutTag_UseChannelDescriptions) {
        return nil;
    }

    return [[AVAudioChannelLayout alloc] initWithLayoutTag:tag];
}

static int MLAudioRingBufferDurationForMode(MLAudioOutputMode mode) {
    switch (mode) {
        case MLAudioOutputModeEnhanced:
            return AUDIO_ENHANCED_BUFFER_DURATION;
        case MLAudioOutputModeDirect:
            return AUDIO_DIRECT_BUFFER_DURATION;
        default:
            return CIRCULAR_BUFFER_DURATION;
    }
}

int ArInit(int audioConfiguration, POPUS_MULTISTREAM_CONFIGURATION originalOpusConfig, void* context, int flags)
{
    Connection *conn = context ? (__bridge Connection *)context : CurrentConnection();
    if (conn == nil) {
        Log(LOG_E, @"ArInit called without connection context");
        return -1;
    }

    int err;
    AudioChannelLayout channelLayout = {};
    OPUS_MULTISTREAM_CONFIGURATION opusConfig = {};
    MLPrepareOpusDecoderConfig(originalOpusConfig, &opusConfig);
    
    // Initialize the circular buffer
    conn->_audioBufferWriteIndex = conn->_audioBufferReadIndex = 0;
    conn->_audioBufferReadFrameOffset = 0;
    conn->_audioSamplesPerFrame = opusConfig.samplesPerFrame;
    conn->_audioBufferStride = opusConfig.channelCount * opusConfig.samplesPerFrame;
    int frameDurationMs = MAX(1, (int)(opusConfig.samplesPerFrame / (opusConfig.sampleRate / 1000)));
    int targetBufferDurationMs = MLAudioRingBufferDurationForMode((MLAudioOutputMode)conn->_audioOutputMode);
    int bufferedFramesTarget = MAX(1, (targetBufferDurationMs + frameDurationMs - 1) / frameDurationMs);
    conn->_audioBufferEntries = MAX(2, bufferedFramesTarget + 1);
    conn->_audioCircularBuffer = malloc(conn->_audioBufferEntries * conn->_audioBufferStride * sizeof(short));
    if (conn->_audioCircularBuffer == NULL) {
        Log(LOG_E, @"Error allocating output queue\n");
        return -1;
    }
    
    conn->_channelCount = opusConfig.channelCount;
    conn->_audioAdvertisedOpusConfig = *originalOpusConfig;
    conn->_audioCurrentDecoderConfig = *originalOpusConfig;
    memset(&conn->_audioFallbackDecoderConfig, 0, sizeof(conn->_audioFallbackDecoderConfig));
    conn->_hasAudioFallbackDecoderConfig = NO;
    conn->_usingAudioFallbackDecoderConfig = NO;
    
    MLFillChannelLayout(&channelLayout, opusConfig.channelCount);
    if (channelLayout.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions) {
        Log(LOG_E, @"Unsupported channel layout: %d\n", opusConfig.channelCount);
        free(conn->_audioCircularBuffer);
        conn->_audioCircularBuffer = NULL;
        return -1;
    }

    if (MLIs714HighQualityOpusConfig(originalOpusConfig)) {
        conn->_audioFallbackDecoderConfig = *originalOpusConfig;
        conn->_audioFallbackDecoderConfig.streams = 8;
        conn->_audioFallbackDecoderConfig.coupledStreams = 4;
        conn->_hasAudioFallbackDecoderConfig = YES;
        Log(LOG_I, @"Armed 7.1.4 Opus decoder fallback: primary=%d/%d fallback=%d/%d",
            originalOpusConfig->streams,
            originalOpusConfig->coupledStreams,
            conn->_audioFallbackDecoderConfig.streams,
            conn->_audioFallbackDecoderConfig.coupledStreams);
    }

    OPUS_MULTISTREAM_CONFIGURATION decoderConfig = opusConfig;
    BOOL preferCompatibility714Topology =
        conn->_disableHighQualitySurround &&
        conn->_hasAudioFallbackDecoderConfig;
    if (preferCompatibility714Topology) {
        MLPrepareOpusDecoderConfig(&conn->_audioFallbackDecoderConfig, &decoderConfig);
        conn->_audioCurrentDecoderConfig = conn->_audioFallbackDecoderConfig;
        conn->_usingAudioFallbackDecoderConfig = YES;
        Log(LOG_I, @"Starting 7.1.4 audio decoder in compatibility topology: streams=%d coupled=%d",
            decoderConfig.streams,
            decoderConfig.coupledStreams);
    }
    
    conn->_opusDecoder = opus_multistream_decoder_create(decoderConfig.sampleRate,
                                                         decoderConfig.channelCount,
                                                         decoderConfig.streams,
                                                         decoderConfig.coupledStreams,
                                                         decoderConfig.mapping,
                                                         &err);
    if (conn->_opusDecoder == NULL || err != OPUS_OK) {
        Log(LOG_E, @"Failed to create Opus decoder: %d\n", err);
        free(conn->_audioCircularBuffer);
        conn->_audioCircularBuffer = NULL;
        return -1;
    }
    conn->_audioRenderScratchBuffer = calloc(AUDIO_RENDER_SCRATCH_FRAMES * conn->_channelCount, sizeof(short));
    if (conn->_audioRenderScratchBuffer == NULL) {
        Log(LOG_E, @"Failed to allocate audio render scratch buffer\n");
        opus_multistream_decoder_destroy(conn->_opusDecoder);
        conn->_opusDecoder = NULL;
        free(conn->_audioCircularBuffer);
        conn->_audioCircularBuffer = NULL;
        return -1;
    }
    conn->_audioDeviceChannelCount = MLDefaultOutputChannelCount();
    conn->_audioRenderChannelCount = conn->_channelCount;
    conn->_audioRendererBackend = MLAudioRendererBackendLegacyQueue;
    conn->_audioUnderrunCount = 0;
    conn->_audioDecodeThreadPriorityRaised = NO;
    conn->_audioDecodeSampleCount = 0;
    conn->_audioDecodeFailureCount = 0;
    conn->_audioConsecutiveDecodeFailures = 0;
    conn->_audioFallbackDecodeSuccessCount = 0;
    conn->_audioPrimaryReprobeAttempted = preferCompatibility714Topology;

    Log(LOG_I, @"Audio renderer init request: backendMode=%d audioConfiguration=0x%08X channels=%d streams=%d coupled=%d samplesPerFrame=%d disableHighQuality714=%d",
        (int)conn->_audioOutputMode,
        audioConfiguration,
        opusConfig.channelCount,
        decoderConfig.streams,
        decoderConfig.coupledStreams,
        opusConfig.samplesPerFrame,
        preferCompatibility714Topology ? 1 : 0);

#if TARGET_OS_IPHONE
    // Configure the audio session for our app
    NSError *audioSessionError = nil;
    AVAudioSession* audioSession = [AVAudioSession sharedInstance];

    [audioSession setPreferredSampleRate:opusConfig.sampleRate error:&audioSessionError];
    [audioSession setCategory:AVAudioSessionCategoryPlayback
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers
                        error:&audioSessionError];
    [audioSession setPreferredIOBufferDuration:(opusConfig.samplesPerFrame / (opusConfig.sampleRate / 1000)) / 1000.0
                                         error:&audioSessionError];
    [audioSession setActive: YES error: &audioSessionError];
    
    // FIXME: Calling this breaks surround audio for some reason
    //[audioSession setPreferredOutputNumberOfChannels:opusConfig->channelCount error:&audioSessionError];
#endif

    OSStatus status = noErr;

    if ((MLAudioOutputMode)conn->_audioOutputMode == MLAudioOutputModeDirect) {
        if ([conn initializeDirectAudioRendererWithOpusConfig:&opusConfig channelLayout:&channelLayout]) {
            conn->_audioRendererBackend = MLAudioRendererBackendDirect;
            return noErr;
        }
        Log(LOG_W, @"Direct audio renderer unavailable; falling back to legacy audio queue backend");
    } else if ((MLAudioOutputMode)conn->_audioOutputMode == MLAudioOutputModeEnhanced) {
        if ([conn initializeEnhancedAudioRendererWithOpusConfig:&opusConfig]) {
            conn->_audioRendererBackend = MLAudioRendererBackendEnhanced;
            return noErr;
        }
        Log(LOG_W, @"Enhanced audio renderer unavailable; falling back to legacy audio queue backend");
    }
    
    AudioStreamBasicDescription audioFormat = {0};
    audioFormat.mSampleRate = opusConfig.sampleRate;
    audioFormat.mBitsPerChannel = 16;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    audioFormat.mChannelsPerFrame = opusConfig.channelCount;
    audioFormat.mBytesPerFrame = audioFormat.mChannelsPerFrame * (audioFormat.mBitsPerChannel / 8);
    audioFormat.mBytesPerPacket = audioFormat.mBytesPerFrame;
    audioFormat.mFramesPerPacket = audioFormat.mBytesPerPacket / audioFormat.mBytesPerFrame;
    audioFormat.mReserved = 0;

    if (conn->_audioQueueContext == NULL) {
        conn->_audioQueueContext = (__bridge_retained void *)conn;
    }

    status = AudioQueueNewOutput(&audioFormat, FillOutputBuffer, conn->_audioQueueContext, nil, nil, 0, &conn->_audioQueue);
    if (status != noErr) {
        Log(LOG_E, @"Error allocating output queue: %d\n", status);
        if (conn->_audioQueueContext != NULL) {
            CFBridgingRelease(conn->_audioQueueContext);
            conn->_audioQueueContext = NULL;
        }
        return status;
    }
    
    // We need to specify a channel layout for surround sound configurations
    status = AudioQueueSetProperty(conn->_audioQueue, kAudioQueueProperty_ChannelLayout, &channelLayout, sizeof(channelLayout));
    if (status != noErr) {
        Log(LOG_E, @"Error configuring surround channel layout: %d\n", status);
        AudioQueueDispose(conn->_audioQueue, true);
        conn->_audioQueue = NULL;
        if (conn->_audioQueueContext != NULL) {
            CFBridgingRelease(conn->_audioQueueContext);
            conn->_audioQueueContext = NULL;
        }
        return status;
    }
    
    for (int i = 0; i < AUDIO_QUEUE_BUFFERS; i++) {
        status = AudioQueueAllocateBuffer(conn->_audioQueue, audioFormat.mBytesPerFrame * opusConfig.samplesPerFrame, &conn->_audioBuffers[i]);
        if (status != noErr) {
            Log(LOG_E, @"Error allocating output buffer: %d\n", status);
            AudioQueueDispose(conn->_audioQueue, true);
            conn->_audioQueue = NULL;
            if (conn->_audioQueueContext != NULL) {
                CFBridgingRelease(conn->_audioQueueContext);
                conn->_audioQueueContext = NULL;
            }
            return status;
        }

        FillOutputBuffer(conn->_audioQueueContext, conn->_audioQueue, conn->_audioBuffers[i]);
    }
    
    status = AudioQueueStart(conn->_audioQueue, nil);
    if (status != noErr) {
        Log(LOG_E, @"Error starting queue: %d\n", status);
        AudioQueueDispose(conn->_audioQueue, true);
        conn->_audioQueue = NULL;
        if (conn->_audioQueueContext != NULL) {
            CFBridgingRelease(conn->_audioQueueContext);
            conn->_audioQueueContext = NULL;
        }
        return status;
    }
    
    return status;
}

void ArCleanup(void)
{
    Connection *conn = CurrentConnection();
    if (conn == nil) {
        return;
    }

    [conn cleanupSelectedAudioRenderer];

    if (conn->_opusDecoder != NULL) {
        opus_multistream_decoder_destroy(conn->_opusDecoder);
        conn->_opusDecoder = NULL;
    }
    
    // Must be freed after the queue is stopped
    if (conn->_audioCircularBuffer != NULL) {
        free(conn->_audioCircularBuffer);
        conn->_audioCircularBuffer = NULL;
    }

    if (conn->_audioRenderScratchBuffer != NULL) {
        free(conn->_audioRenderScratchBuffer);
        conn->_audioRenderScratchBuffer = NULL;
    }
    
#if TARGET_OS_IPHONE
    // Audio session is now inactive
    [[AVAudioSession sharedInstance] setActive: NO error: nil];
#endif
}

void ArDecodeAndPlaySample(char* sampleData, int sampleLength)
{
    Connection *conn = CurrentConnection();
    if (conn == nil || conn->_opusDecoder == NULL) {
        return;
    }

    int decodeLen;

    if (!conn->_audioDecodeThreadPriorityRaised) {
        int qosResult = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        if (qosResult == 0) {
            Log(LOG_I, @"Audio decode thread QoS promoted: backend=%d",
                (int)conn->_audioRendererBackend);
        } else {
            Log(LOG_W, @"Audio decode thread QoS promotion failed: backend=%d error=%d",
                (int)conn->_audioRendererBackend,
                qosResult);
        }
        conn->_audioDecodeThreadPriorityRaised = YES;
    }
    
    // Check if there is space for this sample in the buffer. Again, this can race
    // but in the worst case, we'll not see the sample callback having consumed a sample.
    if (conn->_audioBufferEntries == 0 || ((conn->_audioBufferWriteIndex + 1) % conn->_audioBufferEntries) == conn->_audioBufferReadIndex) {
        return;
    }
    
    decodeLen = opus_multistream_decode(conn->_opusDecoder, (unsigned char *)sampleData, sampleLength,
                                        (short*)&conn->_audioCircularBuffer[conn->_audioBufferWriteIndex * conn->_audioBufferStride], conn->_audioSamplesPerFrame, 0);
    if (decodeLen > 0) {
        if (conn->_audioDecodeSampleCount == 0) {
            Log(LOG_I, @"Audio decode primed: backend=%d sampleLength=%d decodedFrames=%d channels=%d samplesPerFrame=%d",
                (int)conn->_audioRendererBackend,
                sampleLength,
                decodeLen,
                conn->_channelCount,
                conn->_audioSamplesPerFrame);
        }
        conn->_audioDecodeSampleCount++;
        conn->_audioConsecutiveDecodeFailures = 0;
        if (conn->_usingAudioFallbackDecoderConfig) {
            conn->_audioFallbackDecodeSuccessCount++;
            if ([conn attempt714PrimaryDecoderReprobeWithSampleData:sampleData
                                                      sampleLength:sampleLength]) {
                return;
            }
        }

        // Apply volume adjustment to each audio sample
        short* buffer = &conn->_audioCircularBuffer[conn->_audioBufferWriteIndex * conn->_audioBufferStride];
        for (int i = 0; i < decodeLen * conn->_channelCount; i++) {
            buffer[i] = (short)(buffer[i] * conn->_audioVolumeMultiplier);
        }
        
        // Use a full memory barrier to ensure the circular buffer is written before incrementing the index
        __sync_synchronize();
        
        // This can race with the reader in the sample callback, however this is a benign
        // race since we'll either read the original value of s_WriteIndex (which is safe,
        // we just won't consider this sample) or the new value of s_WriteIndex
        conn->_audioBufferWriteIndex = (conn->_audioBufferWriteIndex + 1) % conn->_audioBufferEntries;
    } else if (decodeLen < 0) {
        conn->_audioDecodeFailureCount++;
        conn->_audioConsecutiveDecodeFailures++;

        if ([conn attempt714DecoderTopologyFallbackAfterDecodeError:decodeLen]) {
            decodeLen = opus_multistream_decode(conn->_opusDecoder, (unsigned char *)sampleData, sampleLength,
                                                (short*)&conn->_audioCircularBuffer[conn->_audioBufferWriteIndex * conn->_audioBufferStride], conn->_audioSamplesPerFrame, 0);
            if (decodeLen > 0) {
                Log(LOG_I, @"Audio decode recovered after 7.1.4 topology fallback: backend=%d sampleLength=%d decodedFrames=%d channels=%d samplesPerFrame=%d",
                    (int)conn->_audioRendererBackend,
                    sampleLength,
                    decodeLen,
                    conn->_channelCount,
                    conn->_audioSamplesPerFrame);
                conn->_audioDecodeSampleCount++;
                conn->_audioConsecutiveDecodeFailures = 0;

                short *buffer = &conn->_audioCircularBuffer[conn->_audioBufferWriteIndex * conn->_audioBufferStride];
                for (int i = 0; i < decodeLen * conn->_channelCount; i++) {
                    buffer[i] = (short)(buffer[i] * conn->_audioVolumeMultiplier);
                }

                __sync_synchronize();
                conn->_audioBufferWriteIndex = (conn->_audioBufferWriteIndex + 1) % conn->_audioBufferEntries;
                return;
            }
        }

        if (conn->_audioDecodeFailureCount <= 5 || (conn->_audioDecodeFailureCount % 50) == 0) {
            Log(LOG_W, @"Audio decode failed: backend=%d sampleLength=%d error=%d channels=%d samplesPerFrame=%d failures=%llu",
                (int)conn->_audioRendererBackend,
                sampleLength,
                decodeLen,
                conn->_channelCount,
                conn->_audioSamplesPerFrame,
                (unsigned long long)conn->_audioDecodeFailureCount);
        }
    }
}

- (void)updateVolume {
    if (_hostAddress != nil) {
        NSString *uuid = [SettingsClass getHostUUIDFrom:_hostAddress];
        _audioVolumeMultiplier = [SettingsClass volumeLevelFor:uuid];
    }
}

- (void)copyPCMFrames:(UInt32)frameCount toInterleavedBuffer:(short *)outputBuffer
{
    if (outputBuffer == NULL || _audioCircularBuffer == NULL || _channelCount <= 0) {
        return;
    }

    memset(outputBuffer, 0, frameCount * _channelCount * sizeof(short));

    UInt32 copiedFrames = 0;
    while (copiedFrames < frameCount &&
           _audioBufferEntries > 0 &&
           _audioBufferReadIndex != _audioBufferWriteIndex) {
        short *entryBase = &_audioCircularBuffer[_audioBufferReadIndex * _audioBufferStride];
        UInt32 framesAvailable = (UInt32)_audioSamplesPerFrame - _audioBufferReadFrameOffset;
        UInt32 framesToCopy = MIN(framesAvailable, frameCount - copiedFrames);

        memcpy(outputBuffer + (copiedFrames * _channelCount),
               entryBase + (_audioBufferReadFrameOffset * _channelCount),
               framesToCopy * _channelCount * sizeof(short));

        copiedFrames += framesToCopy;
        _audioBufferReadFrameOffset += framesToCopy;

        if (_audioBufferReadFrameOffset >= (UInt32)_audioSamplesPerFrame) {
            __sync_synchronize();
            _audioBufferReadIndex = (_audioBufferReadIndex + 1) % _audioBufferEntries;
            _audioBufferReadFrameOffset = 0;
        }
    }

    if (copiedFrames < frameCount) {
        _audioUnderrunCount++;
        if ((_audioUnderrunCount % 25) == 1) {
            Log(LOG_W, @"Audio underrun on backend=%d requested=%u copied=%u entries=%d",
                (int)_audioRendererBackend,
                (unsigned int)frameCount,
                (unsigned int)copiedFrames,
                _audioBufferEntries);
        }
    }
}

- (void)downmixPCMFrames:(UInt32)frameCount
             fromBuffer:(const short *)inputBuffer
     toStereoInt16Buffer:(short *)outputBuffer
{
    if (inputBuffer == NULL || outputBuffer == NULL) {
        return;
    }

    for (UInt32 frame = 0; frame < frameCount; frame++) {
        const short *src = inputBuffer + (frame * _channelCount);

        float left = 0.0f;
        float right = 0.0f;

        if (_channelCount >= 2) {
            left += src[0];
            right += src[1];
        } else if (_channelCount == 1) {
            left += src[0];
            right += src[0];
        }
        if (_channelCount >= 3) {
            left += src[2] * 0.707f;
            right += src[2] * 0.707f;
        }
        if (_channelCount >= 4) {
            left += src[3] * 0.22f;
            right += src[3] * 0.22f;
        }
        if (_channelCount >= 6) {
            left += src[4] * 0.60f;
            right += src[5] * 0.60f;
        }
        if (_channelCount >= 8) {
            left += src[6] * 0.45f;
            right += src[7] * 0.45f;
        }
        if (_channelCount >= 10) {
            left += src[8] * 0.32f;
            right += src[9] * 0.32f;
        }
        if (_channelCount >= 12) {
            left += src[10] * 0.25f;
            right += src[11] * 0.25f;
        }

        left = MAX(MIN(left, SHRT_MAX), SHRT_MIN);
        right = MAX(MIN(right, SHRT_MAX), SHRT_MIN);
        outputBuffer[(frame * 2)] = (short)left;
        outputBuffer[(frame * 2) + 1] = (short)right;
    }
}

- (void)copyPCMFrames:(UInt32)frameCount
         toFloatBufferList:(AudioBufferList *)outputData
          expectedChannels:(UInt32)expectedChannels
{
    if (outputData == NULL || _audioRenderScratchBuffer == NULL || expectedChannels == 0) {
        return;
    }

    [self copyPCMFrames:frameCount toInterleavedBuffer:_audioRenderScratchBuffer];

    BOOL interleaved = outputData->mNumberBuffers == 1 && expectedChannels > 1;
    if (interleaved) {
        float *dst = (float *)outputData->mBuffers[0].mData;
        if (dst == NULL) {
            return;
        }
        for (UInt32 frame = 0; frame < frameCount; frame++) {
            const short *src = _audioRenderScratchBuffer + (frame * _channelCount);
            for (UInt32 channel = 0; channel < expectedChannels; channel++) {
                dst[(frame * expectedChannels) + channel] = src[channel] / 32768.0f;
            }
        }
        outputData->mBuffers[0].mDataByteSize = frameCount * expectedChannels * sizeof(float);
        return;
    }

    UInt32 buffersToFill = MIN(outputData->mNumberBuffers, expectedChannels);
    for (UInt32 channel = 0; channel < outputData->mNumberBuffers; channel++) {
        AudioBuffer buffer = outputData->mBuffers[channel];
        if (buffer.mData == NULL) {
            continue;
        }

        float *dst = (float *)buffer.mData;
        memset(dst, 0, frameCount * sizeof(float));
        if (channel < buffersToFill) {
            for (UInt32 frame = 0; frame < frameCount; frame++) {
                dst[frame] = _audioRenderScratchBuffer[(frame * _channelCount) + channel] / 32768.0f;
            }
        }
        outputData->mBuffers[channel].mDataByteSize = frameCount * sizeof(float);
    }
}

- (void)downmixPCMFrames:(UInt32)frameCount
             fromBuffer:(const short *)inputBuffer
    toStereoFloatBufferList:(AudioBufferList *)outputData
{
    if (inputBuffer == NULL || outputData == NULL || outputData->mNumberBuffers == 0) {
        return;
    }

    BOOL interleaved = outputData->mNumberBuffers == 1;
    float *left = interleaved ? (float *)outputData->mBuffers[0].mData : (float *)outputData->mBuffers[0].mData;
    float *right = interleaved
        ? ((float *)outputData->mBuffers[0].mData) + 1
        : (outputData->mNumberBuffers > 1 ? (float *)outputData->mBuffers[1].mData : NULL);
    if (left == NULL || right == NULL) {
        return;
    }

    if (interleaved) {
        memset(outputData->mBuffers[0].mData, 0, frameCount * 2 * sizeof(float));
    } else {
        memset(left, 0, frameCount * sizeof(float));
        memset(right, 0, frameCount * sizeof(float));
    }

    for (UInt32 frame = 0; frame < frameCount; frame++) {
        const short *src = inputBuffer + (frame * _channelCount);
        float leftSample = 0.0f;
        float rightSample = 0.0f;

        if (_channelCount >= 2) {
            leftSample += src[0];
            rightSample += src[1];
        } else if (_channelCount == 1) {
            leftSample += src[0];
            rightSample += src[0];
        }
        if (_channelCount >= 3) {
            leftSample += src[2] * 0.707f;
            rightSample += src[2] * 0.707f;
        }
        if (_channelCount >= 4) {
            leftSample += src[3] * 0.22f;
            rightSample += src[3] * 0.22f;
        }
        if (_channelCount >= 6) {
            leftSample += src[4] * 0.60f;
            rightSample += src[5] * 0.60f;
        }
        if (_channelCount >= 8) {
            leftSample += src[6] * 0.45f;
            rightSample += src[7] * 0.45f;
        }
        if (_channelCount >= 10) {
            leftSample += src[8] * 0.32f;
            rightSample += src[9] * 0.32f;
        }
        if (_channelCount >= 12) {
            leftSample += src[10] * 0.25f;
            rightSample += src[11] * 0.25f;
        }

        float normalizedLeft = MAX(MIN(leftSample / 32768.0f, 1.0f), -1.0f);
        float normalizedRight = MAX(MIN(rightSample / 32768.0f, 1.0f), -1.0f);
        if (interleaved) {
            ((float *)outputData->mBuffers[0].mData)[frame * 2] = normalizedLeft;
            ((float *)outputData->mBuffers[0].mData)[frame * 2 + 1] = normalizedRight;
        } else {
            left[frame] = normalizedLeft;
            right[frame] = normalizedRight;
        }
    }

    if (interleaved) {
        outputData->mBuffers[0].mDataByteSize = frameCount * 2 * sizeof(float);
    } else {
        outputData->mBuffers[0].mDataByteSize = frameCount * sizeof(float);
        if (outputData->mNumberBuffers > 1) {
            outputData->mBuffers[1].mDataByteSize = frameCount * sizeof(float);
        }
    }
}

- (BOOL)initializeDirectAudioRendererWithOpusConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
                                      channelLayout:(const AudioChannelLayout *)channelLayout
{
    if (opusConfig == NULL) {
        return NO;
    }

    _audioDeviceChannelCount = MLDefaultOutputChannelCount();
    UInt32 requestedRenderChannels = (UInt32)opusConfig->channelCount;

    for (NSUInteger attempt = 0; attempt < 2; attempt++) {
        BOOL stereoFallback = (attempt == 1 && requestedRenderChannels > 2);
        _audioRenderChannelCount = stereoFallback ? 2 : requestedRenderChannels;

        AudioComponentDescription desc = {0};
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = kAudioUnitSubType_DefaultOutput;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;

        AudioComponent component = AudioComponentFindNext(NULL, &desc);
        if (component == NULL) {
            return NO;
        }

        OSStatus status = AudioComponentInstanceNew(component, &_audioUnit);
        if (status != noErr) {
            _audioUnit = NULL;
            return NO;
        }

        AURenderCallbackStruct callback = {0};
        callback.inputProc = RenderDirectAudioUnit;
        callback.inputProcRefCon = (__bridge void *)self;
        status = AudioUnitSetProperty(_audioUnit,
                                      kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input,
                                      0,
                                      &callback,
                                      sizeof(callback));
        if (status != noErr) {
            [self cleanupSelectedAudioRenderer];
            if (!stereoFallback && requestedRenderChannels > 2) {
                Log(LOG_W, @"Direct renderer multichannel callback setup failed (%d); retrying with stereo downmix", status);
                continue;
            }
            return NO;
        }

        UInt32 maxFrames = MAX((UInt32)opusConfig->samplesPerFrame, (UInt32)512);
        AudioUnitSetProperty(_audioUnit,
                             kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global,
                             0,
                             &maxFrames,
                             sizeof(maxFrames));

        AudioStreamBasicDescription audioFormat = {0};
        audioFormat.mSampleRate = opusConfig->sampleRate;
        audioFormat.mBitsPerChannel = 32;
        audioFormat.mFormatID = kAudioFormatLinearPCM;
        audioFormat.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
        audioFormat.mChannelsPerFrame = _audioRenderChannelCount;
        audioFormat.mBytesPerFrame = sizeof(float);
        audioFormat.mBytesPerPacket = sizeof(float);
        audioFormat.mFramesPerPacket = 1;
        audioFormat.mReserved = 0;

        status = AudioUnitSetProperty(_audioUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input,
                                      0,
                                      &audioFormat,
                                      sizeof(audioFormat));
        if (status != noErr) {
            [self cleanupSelectedAudioRenderer];
            if (!stereoFallback && requestedRenderChannels > 2) {
                Log(LOG_W, @"Direct renderer multichannel stream format rejected (%d); retrying with stereo downmix", status);
                continue;
            }
            return NO;
        }

        if (!stereoFallback && channelLayout != NULL && opusConfig->channelCount > 2) {
            status = AudioUnitSetProperty(_audioUnit,
                                          kAudioUnitProperty_AudioChannelLayout,
                                          kAudioUnitScope_Input,
                                          0,
                                          channelLayout,
                                          sizeof(AudioChannelLayout));
            if (status != noErr) {
                [self cleanupSelectedAudioRenderer];
                Log(LOG_W, @"Direct renderer channel layout rejected (%d); retrying with stereo downmix", status);
                continue;
            }
        }

        status = AudioUnitInitialize(_audioUnit);
        if (status != noErr) {
            [self cleanupSelectedAudioRenderer];
            if (!stereoFallback && requestedRenderChannels > 2) {
                Log(LOG_W, @"Direct renderer multichannel initialization failed (%d); retrying with stereo downmix", status);
                continue;
            }
            return NO;
        }

        status = AudioOutputUnitStart(_audioUnit);
        if (status != noErr) {
            [self cleanupSelectedAudioRenderer];
            if (!stereoFallback && requestedRenderChannels > 2) {
                Log(LOG_W, @"Direct renderer multichannel start failed (%d); retrying with stereo downmix", status);
                continue;
            }
            return NO;
        }

        if (stereoFallback) {
            Log(LOG_W, @"Direct renderer active with stereo downmix fallback: streamChannels=%d deviceChannels=%d",
                opusConfig->channelCount,
                _audioDeviceChannelCount);
        }

        Log(LOG_I, @"Initialized direct audio renderer: streamChannels=%d deviceChannels=%d renderChannels=%d samplesPerFrame=%d bufferEntries=%d",
            opusConfig->channelCount,
            _audioDeviceChannelCount,
            _audioRenderChannelCount,
            opusConfig->samplesPerFrame,
            _audioBufferEntries);
        return YES;
    }

    return NO;
}

- (void)renderEnhancedStereoPCMFrames:(UInt32)frameCount
                    toFloatBufferList:(AudioBufferList *)outputData
{
    if (outputData == NULL || _audioRenderScratchBuffer == NULL || outputData->mNumberBuffers == 0) {
        return;
    }

    BOOL interleaved = outputData->mNumberBuffers == 1;
    float *interleavedDst = interleaved ? (float *)outputData->mBuffers[0].mData : NULL;
    float *leftDst = interleaved ? NULL : (float *)outputData->mBuffers[0].mData;
    float *rightDst = interleaved
        ? NULL
        : (outputData->mNumberBuffers > 1 ? (float *)outputData->mBuffers[1].mData : NULL);
    if ((interleaved && interleavedDst == NULL) || (!interleaved && (leftDst == NULL || rightDst == NULL))) {
        return;
    }

    const BOOL headphones = _enhancedAudioOutputTarget == MLAudioEnhancedOutputTargetHeadphones;
    const BOOL fallbackDecoderActive = _usingAudioFallbackDecoderConfig;
    const float spatial = MAX(0.0f, MIN(1.0f, (float)_enhancedAudioSpatialIntensity));
    const float width = MAX(0.0f, MIN(1.0f, (float)_enhancedAudioSoundstageWidth));
    const float centerGain = headphones ? (0.84f - (width * 0.05f)) : (0.86f - (width * 0.04f));
    const float lfeGain = fallbackDecoderActive ? 0.03f : (headphones ? 0.08f : 0.12f);
    const float sideSame = fallbackDecoderActive ? 0.02f : (0.22f + (spatial * 0.28f));
    const float sideCross = fallbackDecoderActive ? 0.01f : (0.03f + (width * 0.06f));
    const float rearSame = fallbackDecoderActive ? 0.01f : (0.17f + (spatial * 0.22f));
    const float rearCross = fallbackDecoderActive ? 0.00f : (0.06f + (width * 0.08f));
    const float topSame = fallbackDecoderActive ? 0.00f : (0.10f + (spatial * 0.14f));
    const float topCross = fallbackDecoderActive ? 0.00f : (0.05f + (width * 0.06f));
    const float widthScale = 1.0f + (width * (headphones ? 0.34f : 0.16f));
    const float outputTrim = headphones ? 0.98f : 1.0f;

    UInt32 framesRemaining = frameCount;
    UInt32 frameOffset = 0;
    while (framesRemaining > 0) {
        UInt32 chunkFrames = MIN(framesRemaining, (UInt32)AUDIO_RENDER_SCRATCH_FRAMES);
        BOOL usedCoreAudioDownmix = NO;
        float *coreAudioLeft = NULL;
        float *coreAudioRight = NULL;

        if (_enhancedUsesCoreAudioDownmix &&
            _enhancedDownmixConverter != nil &&
            _enhancedDownmixInputBuffer != nil &&
            _enhancedDownmixOutputBuffer != nil) {
            [self copyPCMFrames:chunkFrames toInterleavedBuffer:_audioRenderScratchBuffer];

            AudioBufferList *inputBufferList = _enhancedDownmixInputBuffer.mutableAudioBufferList;
            if (inputBufferList != NULL &&
                inputBufferList->mNumberBuffers > 0 &&
                inputBufferList->mBuffers[0].mData != NULL) {
                UInt32 byteCount = chunkFrames * _channelCount * sizeof(short);
                memcpy(inputBufferList->mBuffers[0].mData, _audioRenderScratchBuffer, byteCount);
                inputBufferList->mBuffers[0].mDataByteSize = byteCount;
                _enhancedDownmixInputBuffer.frameLength = chunkFrames;
                _enhancedDownmixOutputBuffer.frameLength = 0;

                NSError *conversionError = nil;
                if ([_enhancedDownmixConverter convertToBuffer:_enhancedDownmixOutputBuffer
                                                   fromBuffer:_enhancedDownmixInputBuffer
                                                        error:&conversionError] &&
                    _enhancedDownmixOutputBuffer.frameLength == chunkFrames &&
                    _enhancedDownmixOutputBuffer.floatChannelData != NULL) {
                    coreAudioLeft = _enhancedDownmixOutputBuffer.floatChannelData[0];
                    coreAudioRight =
                        (_enhancedDownmixOutputBuffer.format.channelCount > 1 &&
                         _enhancedDownmixOutputBuffer.floatChannelData[1] != NULL)
                        ? _enhancedDownmixOutputBuffer.floatChannelData[1]
                        : _enhancedDownmixOutputBuffer.floatChannelData[0];
                    usedCoreAudioDownmix = (coreAudioLeft != NULL && coreAudioRight != NULL);
                } else {
                    _enhancedDownmixFailureCount++;
                    if (_enhancedDownmixFailureCount <= 5 || (_enhancedDownmixFailureCount % 50) == 0) {
                        Log(LOG_W, @"Enhanced Core Audio downmix failed: channels=%d frames=%u error=%@ failures=%llu",
                            _channelCount,
                            (unsigned int)chunkFrames,
                            conversionError.localizedDescription ?: @"unknown",
                            (unsigned long long)_enhancedDownmixFailureCount);
                    }
                }
            }
        }

        if (!usedCoreAudioDownmix) {
            [self copyPCMFrames:chunkFrames toInterleavedBuffer:_audioRenderScratchBuffer];
        }

        for (UInt32 frame = 0; frame < chunkFrames; frame++) {
            float normalizedLeft = 0.0f;
            float normalizedRight = 0.0f;

            if (usedCoreAudioDownmix) {
                normalizedLeft = coreAudioLeft[frame];
                normalizedRight = coreAudioRight[frame];
            } else {
                const short *src = _audioRenderScratchBuffer + (frame * _channelCount);

                float left = 0.0f;
                float right = 0.0f;

                if (_channelCount >= 2) {
                    left += src[0];
                    right += src[1];
                } else if (_channelCount == 1) {
                    left += src[0];
                    right += src[0];
                }
                if (_channelCount >= 3) {
                    left += src[2] * centerGain;
                    right += src[2] * centerGain;
                }
                if (_channelCount >= 4) {
                    left += src[3] * lfeGain;
                    right += src[3] * lfeGain;
                }
                if (_channelCount >= 6) {
                    left += src[4] * rearSame;
                    right += src[4] * rearCross;
                    right += src[5] * rearSame;
                    left += src[5] * rearCross;
                }
                if (_channelCount >= 8) {
                    left += src[6] * sideSame;
                    right += src[6] * sideCross;
                    right += src[7] * sideSame;
                    left += src[7] * sideCross;
                }
                if (_channelCount >= 10) {
                    left += src[8] * topSame;
                    right += src[8] * topCross;
                    right += src[9] * topSame;
                    left += src[9] * topCross;
                }
                if (_channelCount >= 12) {
                    left += src[10] * (topSame * 0.88f);
                    right += src[10] * (topCross + 0.03f);
                    right += src[11] * (topSame * 0.88f);
                    left += src[11] * (topCross + 0.03f);
                }

                normalizedLeft = left / 32768.0f;
                normalizedRight = right / 32768.0f;
            }

            float mid = (normalizedLeft + normalizedRight) * 0.5f;
            float side = (normalizedLeft - normalizedRight) * 0.5f;
            float widenedSide = side * widthScale;
            float finalLeft = MLApplyMakeupGainAndSoftClip((mid + widenedSide) * outputTrim, kEnhancedRendererOutputGain);
            float finalRight = MLApplyMakeupGainAndSoftClip((mid - widenedSide) * outputTrim, kEnhancedRendererOutputGain);

            if (interleaved) {
                UInt32 dstIndex = (frameOffset + frame) * 2;
                interleavedDst[dstIndex] = finalLeft;
                interleavedDst[dstIndex + 1] = finalRight;
            } else {
                leftDst[frameOffset + frame] = finalLeft;
                rightDst[frameOffset + frame] = finalRight;
            }
        }

        frameOffset += chunkFrames;
        framesRemaining -= chunkFrames;
    }

    if (interleaved) {
        outputData->mBuffers[0].mDataByteSize = frameCount * 2 * sizeof(float);
    } else {
        outputData->mBuffers[0].mDataByteSize = frameCount * sizeof(float);
        if (outputData->mNumberBuffers > 1) {
            outputData->mBuffers[1].mDataByteSize = frameCount * sizeof(float);
        }
    }
}

- (void)configureEnhancedAudioUnits
{
    if (_enhancedAudioEQ == nil || _enhancedAudioReverb == nil || _enhancedAudioSourceNode == nil) {
        return;
    }

    NSArray<NSNumber *> *gains = _enhancedAudioEQGains;
    NSUInteger resolvedBandCount = 0;
    const double *frequencies = MLEnhancedEQFrequencyTable(gains.count, &resolvedBandCount);
    if (gains.count != resolvedBandCount) {
        frequencies = MLEnhancedEQFrequencyTable(kEnhancedEQBandCount12, &resolvedBandCount);
        gains = nil;
    }

    float maxPositiveGain = 0.0f;
    for (NSUInteger i = 0; i < MIN((NSUInteger)_enhancedAudioEQ.bands.count, resolvedBandCount); i++) {
        AVAudioUnitEQFilterParameters *band = _enhancedAudioEQ.bands[i];
        band.filterType = AVAudioUnitEQFilterTypeParametric;
        band.frequency = frequencies[i];
        band.bandwidth = 0.7f;
        band.gain = (float)(i < gains.count ? gains[i].doubleValue : 0.0);
        maxPositiveGain = MAX(maxPositiveGain, band.gain);
        band.bypass = NO;
    }

    float clampedReverb = MAX(0.0f, MIN(1.0f, (float)_enhancedAudioReverbAmount));
    [_enhancedAudioReverb loadFactoryPreset:
        (_enhancedAudioOutputTarget == MLAudioEnhancedOutputTargetHeadphones)
        ? AVAudioUnitReverbPresetSmallRoom
        : AVAudioUnitReverbPresetMediumRoom];
    _enhancedAudioReverb.wetDryMix =
        clampedReverb *
        (_enhancedAudioOutputTarget == MLAudioEnhancedOutputTargetHeadphones ? 10.0f : 18.0f);

    _enhancedAudioEQ.globalGain =
        -MIN(2.5f,
             MAX(0.0f, maxPositiveGain) * 0.20f +
             clampedReverb * 0.8f);

    _enhancedAudioSourceNode.volume = 1.0f;
}

- (BOOL)prepareEnhancedDownmixConverterWithOpusConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
{
    if (opusConfig == NULL || opusConfig->channelCount <= 0) {
        return NO;
    }

    _enhancedDownmixConverter = nil;
    _enhancedDownmixInputBuffer = nil;
    _enhancedDownmixOutputBuffer = nil;
    _enhancedUsesCoreAudioDownmix = NO;
    _enhancedDownmixFailureCount = 0;

    if (opusConfig->channelCount > 2) {
        // Manual virtualization preserves surround placement better than AVAudioConverter.
        // Empirically, AVAudioConverter with 5.1/7.1/7.1.4 layouts on macOS can collapse to
        // front-L/R only instead of performing a real surround-to-stereo downmix, which makes
        // Enhanced mode lose side/rear/top content entirely.
        return NO;
    }

    AVAudioChannelLayout *sourceLayout = MLCreateAVAudioChannelLayout(opusConfig->channelCount);
    AVAudioFormat *sourceFormat = sourceLayout != nil
        ? [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                           sampleRate:opusConfig->sampleRate
                                          interleaved:YES
                                        channelLayout:sourceLayout]
        : [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                           sampleRate:opusConfig->sampleRate
                                             channels:opusConfig->channelCount
                                          interleaved:YES];
    AVAudioFormat *stereoFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:opusConfig->sampleRate
                                                                                  channels:2];
    if (sourceFormat == nil || stereoFormat == nil) {
        return NO;
    }

    _enhancedDownmixConverter = [[AVAudioConverter alloc] initFromFormat:sourceFormat toFormat:stereoFormat];
    if (_enhancedDownmixConverter == nil) {
        return NO;
    }

    _enhancedDownmixInputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:sourceFormat
                                                                 frameCapacity:AUDIO_RENDER_SCRATCH_FRAMES];
    _enhancedDownmixOutputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:stereoFormat
                                                                  frameCapacity:AUDIO_RENDER_SCRATCH_FRAMES];
    if (_enhancedDownmixInputBuffer == nil || _enhancedDownmixOutputBuffer == nil) {
        _enhancedDownmixConverter = nil;
        _enhancedDownmixInputBuffer = nil;
        _enhancedDownmixOutputBuffer = nil;
        return NO;
    }

    _enhancedUsesCoreAudioDownmix = YES;
    return YES;
}

- (BOOL)initializeEnhancedAudioRendererWithOpusConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
{
    if (opusConfig == NULL) {
        return NO;
    }

    if (@available(macOS 10.15, *)) {
        AVAudioFormat *sourceFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:opusConfig->sampleRate
                                                                                     channels:2];
        AVAudioFormat *renderFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:opusConfig->sampleRate
                                                                                     channels:2];
        [self prepareEnhancedDownmixConverterWithOpusConfig:opusConfig];
        __weak Connection *weakSelf = self;
        _enhancedAudioSourceNode = [[AVAudioSourceNode alloc] initWithFormat:sourceFormat renderBlock:^OSStatus(BOOL * _Nonnull isSilence,
                                                                                                                const AudioTimeStamp * _Nonnull timestamp,
                                                                                                                AVAudioFrameCount frameCount,
                                                                                                                AudioBufferList * _Nonnull outputData) {
            __strong Connection *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return noErr;
            }

            [strongSelf renderEnhancedStereoPCMFrames:frameCount
                                    toFloatBufferList:outputData];
            *isSilence = NO;
            return noErr;
        }];

        NSUInteger resolvedBandCount = 0;
        MLEnhancedEQFrequencyTable(_enhancedAudioEQGains.count, &resolvedBandCount);
        _enhancedAudioEngine = [[AVAudioEngine alloc] init];
        _enhancedAudioReverb = [[AVAudioUnitReverb alloc] init];
        _enhancedAudioEQ = [[AVAudioUnitEQ alloc] initWithNumberOfBands:(uint32_t)resolvedBandCount];

        [_enhancedAudioEngine attachNode:_enhancedAudioSourceNode];
        [_enhancedAudioEngine attachNode:_enhancedAudioReverb];
        [_enhancedAudioEngine attachNode:_enhancedAudioEQ];

        [_enhancedAudioEngine connect:_enhancedAudioSourceNode to:_enhancedAudioReverb format:sourceFormat];
        [_enhancedAudioEngine connect:_enhancedAudioReverb to:_enhancedAudioEQ format:renderFormat];
        [_enhancedAudioEngine connect:_enhancedAudioEQ to:_enhancedAudioEngine.mainMixerNode format:renderFormat];
        [self configureEnhancedAudioUnits];

        [_enhancedAudioEngine prepare];

        NSError *error = nil;
        if (![_enhancedAudioEngine startAndReturnError:&error]) {
            Log(LOG_W, @"Failed to start enhanced audio renderer: %@", error.localizedDescription);
            [self cleanupSelectedAudioRenderer];
            return NO;
        }

        _audioRenderChannelCount = 2;
        Log(LOG_I, @"Enhanced renderer using stereo virtualizer: streamChannels=%d target=%d preset=%d spatial=%.2f width=%.2f reverb=%.2f",
            opusConfig->channelCount,
            _enhancedAudioOutputTarget,
            _enhancedAudioPreset,
            _enhancedAudioSpatialIntensity,
            _enhancedAudioSoundstageWidth,
            _enhancedAudioReverbAmount);
        if (_enhancedUsesCoreAudioDownmix) {
            Log(LOG_I, @"Enhanced renderer Core Audio downmix active: streamChannels=%d -> stereo", opusConfig->channelCount);
        } else if (opusConfig->channelCount > 2) {
            Log(LOG_I, @"Enhanced renderer using manual surround virtualization: streamChannels=%d -> stereo", opusConfig->channelCount);
        } else {
            Log(LOG_W, @"Enhanced renderer Core Audio downmix unavailable; using manual stereo virtualization fallback");
        }
        if (opusConfig->channelCount > 2) {
            Log(LOG_I, @"Enhanced multichannel virtualization active: streamChannels=%d -> stereo", opusConfig->channelCount);
        }
        Log(LOG_I, @"Initialized enhanced audio renderer: preset=%d target=%d spatial=%.2f width=%.2f samplesPerFrame=%d bufferEntries=%d",
            _enhancedAudioPreset,
            _enhancedAudioOutputTarget,
            _enhancedAudioSpatialIntensity,
            _enhancedAudioSoundstageWidth,
            opusConfig->samplesPerFrame,
            _audioBufferEntries);
        return YES;
    }

    return NO;
}

- (void)cleanupSelectedAudioRenderer
{
    if (_audioQueue != NULL) {
        AudioQueueStop(_audioQueue, true);
        AudioQueueDispose(_audioQueue, true);
        _audioQueue = NULL;
    }

    if (_audioQueueContext != NULL) {
        CFBridgingRelease(_audioQueueContext);
        _audioQueueContext = NULL;
    }

    if (_audioUnit != NULL) {
        AudioOutputUnitStop(_audioUnit);
        AudioUnitUninitialize(_audioUnit);
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = NULL;
    }

    if (_enhancedAudioEngine != nil) {
        [_enhancedAudioEngine stop];
        _enhancedAudioEngine = nil;
        _enhancedAudioSourceNode = nil;
        _enhancedAudioReverb = nil;
        _enhancedAudioEQ = nil;
    }

    _enhancedDownmixConverter = nil;
    _enhancedDownmixInputBuffer = nil;
    _enhancedDownmixOutputBuffer = nil;
    _enhancedUsesCoreAudioDownmix = NO;
    _enhancedDownmixFailureCount = 0;

    _audioRendererBackend = MLAudioRendererBackendLegacyQueue;
    _audioRenderChannelCount = 0;
}

static OSStatus RenderDirectAudioUnit(void *inRefCon,
                                      AudioUnitRenderActionFlags *ioActionFlags,
                                      const AudioTimeStamp *inTimeStamp,
                                      UInt32 inBusNumber,
                                      UInt32 inNumberFrames,
                                      AudioBufferList *ioData) {
    Connection *conn = (__bridge Connection *)inRefCon;
    if (conn == nil || ioData == NULL || conn->_audioRenderScratchBuffer == NULL) {
        return noErr;
    }

    UInt32 framesRemaining = inNumberFrames;
    UInt32 frameOffset = 0;
    BOOL interleaved = ioData->mNumberBuffers == 1 && conn->_audioRenderChannelCount > 1;
    while (framesRemaining > 0) {
        UInt32 chunkFrames = MIN(framesRemaining, (UInt32)AUDIO_RENDER_SCRATCH_FRAMES);
        [conn copyPCMFrames:chunkFrames toInterleavedBuffer:conn->_audioRenderScratchBuffer];

        if (conn->_audioRenderChannelCount == conn->_channelCount) {
            if (interleaved) {
                float *dst = ((float *)ioData->mBuffers[0].mData) + (frameOffset * conn->_audioRenderChannelCount);
                for (UInt32 frame = 0; frame < chunkFrames; frame++) {
                    const short *src = conn->_audioRenderScratchBuffer + (frame * conn->_channelCount);
                    for (UInt32 channel = 0; channel < (UInt32)conn->_audioRenderChannelCount; channel++) {
                        dst[(frame * conn->_audioRenderChannelCount) + channel] =
                            MLApplyMakeupGainAndSoftClip(src[channel] / 32768.0f, kDirectRendererMakeupGain);
                    }
                }
            } else {
                for (UInt32 channel = 0; channel < MIN(ioData->mNumberBuffers, (UInt32)conn->_audioRenderChannelCount); channel++) {
                    float *dst = ((float *)ioData->mBuffers[channel].mData) + frameOffset;
                    for (UInt32 frame = 0; frame < chunkFrames; frame++) {
                        dst[frame] = MLApplyMakeupGainAndSoftClip(
                            conn->_audioRenderScratchBuffer[(frame * conn->_channelCount) + channel] / 32768.0f,
                            kDirectRendererMakeupGain);
                    }
                }
            }
        } else if (conn->_audioRenderChannelCount == 2) {
            if (interleaved) {
                float *dst = ((float *)ioData->mBuffers[0].mData) + (frameOffset * 2);
                for (UInt32 frame = 0; frame < chunkFrames; frame++) {
                    const short *src = conn->_audioRenderScratchBuffer + (frame * conn->_channelCount);
                    float left = 0.0f;
                    float right = 0.0f;
                    if (conn->_channelCount >= 2) {
                        left += src[0];
                        right += src[1];
                    } else if (conn->_channelCount == 1) {
                        left += src[0];
                        right += src[0];
                    }
                    if (conn->_channelCount >= 3) {
                        left += src[2] * 0.707f;
                        right += src[2] * 0.707f;
                    }
                    if (conn->_channelCount >= 4) {
                        left += src[3] * 0.22f;
                        right += src[3] * 0.22f;
                    }
                    if (conn->_channelCount >= 6) {
                        left += src[4] * 0.60f;
                        right += src[5] * 0.60f;
                    }
                    if (conn->_channelCount >= 8) {
                        left += src[6] * 0.45f;
                        right += src[7] * 0.45f;
                    }
                    if (conn->_channelCount >= 10) {
                        left += src[8] * 0.32f;
                        right += src[9] * 0.32f;
                    }
                    if (conn->_channelCount >= 12) {
                        left += src[10] * 0.25f;
                        right += src[11] * 0.25f;
                    }
                    dst[frame * 2] = MLApplyMakeupGainAndSoftClip(left / 32768.0f, kDirectRendererMakeupGain);
                    dst[frame * 2 + 1] = MLApplyMakeupGainAndSoftClip(right / 32768.0f, kDirectRendererMakeupGain);
                }
            } else if (ioData->mNumberBuffers >= 2) {
                float *leftDst = ((float *)ioData->mBuffers[0].mData) + frameOffset;
                float *rightDst = ((float *)ioData->mBuffers[1].mData) + frameOffset;
                for (UInt32 frame = 0; frame < chunkFrames; frame++) {
                    const short *src = conn->_audioRenderScratchBuffer + (frame * conn->_channelCount);
                    float left = 0.0f;
                    float right = 0.0f;
                    if (conn->_channelCount >= 2) {
                        left += src[0];
                        right += src[1];
                    } else if (conn->_channelCount == 1) {
                        left += src[0];
                        right += src[0];
                    }
                    if (conn->_channelCount >= 3) {
                        left += src[2] * 0.707f;
                        right += src[2] * 0.707f;
                    }
                    if (conn->_channelCount >= 4) {
                        left += src[3] * 0.22f;
                        right += src[3] * 0.22f;
                    }
                    if (conn->_channelCount >= 6) {
                        left += src[4] * 0.60f;
                        right += src[5] * 0.60f;
                    }
                    if (conn->_channelCount >= 8) {
                        left += src[6] * 0.45f;
                        right += src[7] * 0.45f;
                    }
                    if (conn->_channelCount >= 10) {
                        left += src[8] * 0.32f;
                        right += src[9] * 0.32f;
                    }
                    if (conn->_channelCount >= 12) {
                        left += src[10] * 0.25f;
                        right += src[11] * 0.25f;
                    }
                    leftDst[frame] = MLApplyMakeupGainAndSoftClip(left / 32768.0f, kDirectRendererMakeupGain);
                    rightDst[frame] = MLApplyMakeupGainAndSoftClip(right / 32768.0f, kDirectRendererMakeupGain);
                }
            }
        } else {
            for (UInt32 channel = 0; channel < ioData->mNumberBuffers; channel++) {
                memset(((float *)ioData->mBuffers[channel].mData) + frameOffset,
                       0,
                       chunkFrames * sizeof(float));
            }
        }

        frameOffset += chunkFrames;
        framesRemaining -= chunkFrames;
    }

    if (interleaved) {
        ioData->mBuffers[0].mDataByteSize = inNumberFrames * conn->_audioRenderChannelCount * sizeof(float);
    } else {
        for (UInt32 channel = 0; channel < ioData->mNumberBuffers; channel++) {
            ioData->mBuffers[channel].mDataByteSize = inNumberFrames * sizeof(float);
        }
    }
    return noErr;
}

static void FillOutputBuffer(void *aqData,
                             AudioQueueRef inAQ,
                             AudioQueueBufferRef inBuffer) {
    Connection *conn = (__bridge Connection *)aqData;
    UInt32 bytesPerBuffer = (conn && conn->_audioBufferStride > 0) ? (UInt32)(conn->_audioBufferStride * sizeof(short)) : 0;
    if (conn == nil || bytesPerBuffer == 0 || conn->_audioCircularBuffer == NULL || conn->_audioBufferEntries == 0) {
        bytesPerBuffer = MIN(inBuffer->mAudioDataBytesCapacity, bytesPerBuffer);
        inBuffer->mAudioDataByteSize = bytesPerBuffer;
        if (bytesPerBuffer > 0) {
            memset(inBuffer->mAudioData, 0, bytesPerBuffer);
        }
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
        return;
    }

    if (bytesPerBuffer > inBuffer->mAudioDataBytesCapacity) {
        bytesPerBuffer = inBuffer->mAudioDataBytesCapacity;
    }

    inBuffer->mAudioDataByteSize = bytesPerBuffer;
    UInt32 frames = (conn->_channelCount > 0) ? (bytesPerBuffer / (UInt32)(conn->_channelCount * sizeof(short))) : 0;
    [conn copyPCMFrames:frames toInterleavedBuffer:(short *)inBuffer->mAudioData];
    
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
}

@end
