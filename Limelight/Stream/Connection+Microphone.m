//
//  Connection+Microphone.m
//  Moonlight
//
//  Microphone uplink: AVAudioEngine capture, Opus encoding and delivery to the host.
//

#import "Connection_Internal.h"

// Microphone uplink entry points. They are implemented by moonlight-common-c
// (MicrophoneStream.c) but are not declared in its public header. The library
// opens the stream itself during LiStartConnection when enableMic is set.
extern int initializeMicrophoneStream(void);
extern int sendMicrophoneOpusData(const unsigned char* opusData, int opusLength);
extern bool isMicrophoneEncryptionEnabled(void);

static void *gMicQueueKey = &gMicQueueKey;

@implementation Connection (Microphone)

// (moved to instance fields)
static const int micSampleRate = 48000;
static const int micChannels = 1;
static const int micFrameSize = 960; // 20 ms at 48 kHz
static const int micBitrate = 64000;

- (void)startMicrophoneIfNeeded
{
    if (!_streamConfig.enableMic) {
        Log(LOG_I, @"Microphone disabled in settings, skipping mic start");
        return;
    }
    Log(LOG_I, @"Starting microphone capture...");

    _micSendFailures = 0;
    _micStopping = NO;
    _micEncryptionStatusLogged = NO;

    // Create encoder/queue once
    if (_micQueue == nil) {
        _micQueue = dispatch_queue_create("moonlight.mic.encode", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_micQueue, gMicQueueKey, gMicQueueKey, NULL);
    }
    if (_micPcmQueue == nil) {
        _micPcmQueue = [NSMutableData data];
    }

    AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (authStatus != AVAuthorizationStatusAuthorized) {
        Log(LOG_I, @"Microphone start skipped because permission is not authorized: status=%ld",
            (long)authStatus);
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_micStopping || !self->_streamConfig.enableMic) {
            Log(LOG_I, @"Microphone start skipped because capture is stopping");
            return;
        }
        [self startMicrophoneEngineLocked];
    });
}

- (AudioDeviceID)audioDeviceIDForUID:(NSString*)uid
{
    AudioObjectPropertyAddress propAddr = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propAddr, 0, NULL, &dataSize);
    if (status != noErr) return 0;

    int count = (int)(dataSize / sizeof(AudioDeviceID));
    AudioDeviceID* devices = malloc(dataSize);
    if (!devices) return 0;

    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddr, 0, NULL, &dataSize, devices);
    if (status != noErr) { free(devices); return 0; }

    AudioDeviceID result = 0;
    for (int i = 0; i < count; i++) {
        AudioObjectPropertyAddress uidAddr = {
            .mSelector = kAudioDevicePropertyDeviceUID,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain
        };
        CFStringRef deviceUID = NULL;
        UInt32 uidSize = sizeof(CFStringRef);
        if (AudioObjectGetPropertyData(devices[i], &uidAddr, 0, NULL, &uidSize, &deviceUID) == noErr && deviceUID) {
            if ([(__bridge NSString*)deviceUID isEqualToString:uid]) {
                result = devices[i];
                CFRelease(deviceUID);
                break;
            }
            CFRelease(deviceUID);
        }
    }
    free(devices);
    return result;
}

- (void)startMicrophoneEngineLocked
{
    if (_micStopping || !_streamConfig.enableMic) {
        return;
    }

    if (self.micAudioEngine != nil && self.micAudioEngine.isRunning) {
        return;
    }

    // Idempotent: LiStartConnection already opened the socket when the host
    // accepted the microphone stream.
    if (initializeMicrophoneStream() != 0) {
        Log(LOG_W, @"Failed to initialize microphone stream socket");
        return;
    }

    int err = 0;
    if (_micEncoder == NULL) {
        unsigned char mapping[1] = { 0 };
        _micEncoder = opus_multistream_encoder_create(micSampleRate,
                                                      micChannels,
                                                      1, /* streams */
                                                      0, /* coupled */
                                                      mapping,
                                                      OPUS_APPLICATION_VOIP,
                                                      &err);
        if (_micEncoder == NULL || err != OPUS_OK) {
            Log(LOG_W, @"Failed to create Opus encoder for microphone: %d\n", err);
            _micEncoder = NULL;
            return;
        }

        opus_multistream_encoder_ctl(_micEncoder, OPUS_SET_BITRATE(micBitrate));
    }

    self.micAudioEngine = [[AVAudioEngine alloc] init];

    // Set selected microphone device if configured
    NSString* micDeviceUID = [[NSUserDefaults standardUserDefaults] stringForKey:@"selectedMicDeviceUID"];
    if (micDeviceUID.length > 0) {
        AudioDeviceID deviceID = [self audioDeviceIDForUID:micDeviceUID];
        if (deviceID != 0) {
            AVAudioInputNode* inputNode = self.micAudioEngine.inputNode;
            AudioUnit audioUnit = inputNode.audioUnit;
            if (audioUnit != NULL) {
                OSStatus status = AudioUnitSetProperty(audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &deviceID, sizeof(AudioDeviceID));
                Log(LOG_I, @"Mic device set: uid=%@ deviceID=%u status=%d", micDeviceUID, deviceID, (int)status);
            }
        } else {
            Log(LOG_W, @"Mic device not found for UID: %@, using system default", micDeviceUID);
        }
    }

    AVAudioInputNode* input = self.micAudioEngine.inputNode;
    self.micOutputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                            sampleRate:micSampleRate
                                                              channels:micChannels
                                                           interleaved:YES];

    // Use the hardware input format and convert manually.
    // Passing a non-nil format to installTapOnBus can throw an exception on some devices
    // when AVAudioIONodeImpl::SetOutputFormat rejects the requested conversion.
    AVAudioFormat* hwFormat = [input outputFormatForBus:0];
    Log(LOG_I, @"Microphone hardware format: %@", hwFormat);

    // Check if we can do a direct Float32→Int16 conversion (same sample rate)
    BOOL directConvert = (fabs(hwFormat.sampleRate - micSampleRate) < 1.0 &&
                          hwFormat.commonFormat == AVAudioPCMFormatFloat32);

    if (!directConvert) {
        // Create a converter from hardware format → 48 kHz mono int16
        self.micConverter = [[AVAudioConverter alloc] initFromFormat:hwFormat toFormat:self.micOutputFormat];
        if (self.micConverter == nil) {
            Log(LOG_W, @"Cannot create AVAudioConverter from %@ to %@", hwFormat, self.micOutputFormat);
            self.micAudioEngine = nil;
            return;
        }
        Log(LOG_I, @"Microphone using AVAudioConverter (sample rate conversion needed)");
    } else {
        Log(LOG_I, @"Microphone using direct Float32→Int16 conversion (same sample rate)");
    }

    __weak typeof(self) weakSelf = self;
    __block BOOL micDataLogged = NO;
    __block int micAmplitudeLogCount = 0;
    [input removeTapOnBus:0];

    @try {
        // Pass nil format to receive audio in the hardware's native format.
        [input installTapOnBus:0 bufferSize:(AVAudioFrameCount)(micFrameSize * (hwFormat.sampleRate / micSampleRate + 1)) format:nil block:^(AVAudioPCMBuffer* buffer, AVAudioTime* when) {
            __strong typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil || !strongSelf->_streamConfig.enableMic) {
                return;
            }

            NSData* chunk = nil;

            if (directConvert) {
                // Direct Float32 → Int16 conversion (bypasses AVAudioConverter entirely)
                const float* srcFloat = buffer.floatChannelData ? buffer.floatChannelData[0] : NULL;
                AVAudioFrameCount srcFrames = buffer.frameLength;
                if (srcFloat == NULL || srcFrames == 0) {
                    return;
                }

                NSMutableData* pcmData = [NSMutableData dataWithLength:srcFrames * sizeof(int16_t)];
                int16_t* dst = (int16_t*)pcmData.mutableBytes;
                float maxAbs = 0.0f;
                for (AVAudioFrameCount i = 0; i < srcFrames; i++) {
                    float raw = srcFloat[i];
                    float absVal = raw < 0 ? -raw : raw;
                    if (absVal > maxAbs) maxAbs = absVal;
                    float s = raw * 32767.0f;
                    if (s > 32767.0f) s = 32767.0f;
                    else if (s < -32768.0f) s = -32768.0f;
                    dst[i] = (int16_t)s;
                }
                // Log amplitude of first 10 buffers to verify real audio
                if (micAmplitudeLogCount < 10) {
                    micAmplitudeLogCount++;
                    Log(LOG_I, @"Mic amplitude [%d]: maxAbs=%.6f frames=%u (Int16 max=%d)",
                        micAmplitudeLogCount, maxAbs, (unsigned)srcFrames, (int)(maxAbs * 32767.0f));
                }
                chunk = pcmData;
            } else {
                // Use AVAudioConverter for sample rate conversion
                AVAudioConverter* converter = strongSelf.micConverter;
                AVAudioFormat* outFmt = strongSelf.micOutputFormat;
                if (converter == nil || outFmt == nil) {
                    return;
                }

                AVAudioFrameCount outputFrames = (AVAudioFrameCount)(buffer.frameLength * micSampleRate / hwFormat.sampleRate) + 1;
                AVAudioPCMBuffer* converted = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outFmt frameCapacity:outputFrames];
                if (converted == nil) {
                    return;
                }

                __block BOOL inputConsumed = NO;
                NSError* convErr = nil;
                [converter convertToBuffer:converted error:&convErr withInputFromBlock:^AVAudioBuffer* _Nullable(AVAudioFrameCount inNumberOfPackets, AVAudioConverterInputStatus* _Nonnull outStatus) {
                    if (inputConsumed) {
                        *outStatus = AVAudioConverterInputStatus_NoDataNow;
                        return nil;
                    }
                    inputConsumed = YES;
                    *outStatus = AVAudioConverterInputStatus_HaveData;
                    return buffer;
                }];

                if (convErr != nil || converted.frameLength == 0) {
                    if (!micDataLogged) {
                        Log(LOG_W, @"AVAudioConverter error: %@ (frames=%u)", convErr, (unsigned)converted.frameLength);
                        micDataLogged = YES;
                    }
                    return;
                }

                const AudioBufferList* abl = converted.audioBufferList;
                if (abl == NULL || abl->mNumberBuffers < 1) {
                    return;
                }
                const AudioBuffer ab = abl->mBuffers[0];
                if (ab.mData == NULL || ab.mDataByteSize == 0) {
                    return;
                }
                chunk = [NSData dataWithBytes:ab.mData length:(NSUInteger)ab.mDataByteSize];
            }

            if (chunk == nil || chunk.length == 0) {
                return;
            }

            if (!micDataLogged) {
                Log(LOG_I, @"Microphone PCM data flowing: %lu bytes per tap callback", (unsigned long)chunk.length);
                micDataLogged = YES;
            }

            dispatch_async(strongSelf->_micQueue, ^{
                [strongSelf->_micPcmQueue appendData:chunk];
                [strongSelf drainMicPcmAndSend];
            });
        }];
    } @catch (NSException* exception) {
        Log(LOG_W, @"Failed to install microphone tap: %@ - %@", exception.name, exception.reason);
        self.micAudioEngine = nil;
        self.micConverter = nil;
        return;
    }

    NSError* startErr = nil;
    BOOL started = [self.micAudioEngine startAndReturnError:&startErr];
    if (!started || startErr != nil) {
        Log(LOG_W, @"Failed to start microphone capture: %@\n", startErr.localizedDescription);
        [self.micAudioEngine stop];
        self.micAudioEngine = nil;
        self.micConverter = nil;
        return;
    }
}

- (void)drainMicPcmAndSend
{
    if (_micEncoder == NULL || _micStopping || !_streamConfig.enableMic) {
        return;
    }

    if (!_micEncryptionStatusLogged) {
        BOOL micEncryptionEnabled = isMicrophoneEncryptionEnabled();
        Log(LOG_I, @"Microphone uplink encryption negotiated: %@", micEncryptionEnabled ? @"enabled" : @"disabled");
        _micEncryptionStatusLogged = YES;
    }

    const NSUInteger bytesPerFrame = sizeof(int16_t) * micChannels;
    const NSUInteger packetPcmBytes = (NSUInteger)micFrameSize * bytesPerFrame;

    while (_micPcmQueue.length >= packetPcmBytes) {
        const int16_t* pcm = (const int16_t*)_micPcmQueue.bytes;

        // Sized with slack so the library's AES-CBC path can pad in place.
        unsigned char opusPayload[1500 + 16];
        int opusLen = opus_multistream_encode(_micEncoder, pcm, micFrameSize, opusPayload, 1500);
        if (opusLen > 0) {
            int sent = sendMicrophoneOpusData(opusPayload, opusLen);

            if (sent < 0) {
                _micSendFailures++;
                if (sent == -1 || _micSendFailures >= 5) {
                    Log(LOG_W, @"sendMicrophoneData failed: %d (stopping mic)\n", sent);
                    _streamConfig.enableMic = NO;
                    [self stopMicrophoneIfNeeded];
                    return;
                }
            } else {
                _micSendFailures = 0;
            }
        }

        [_micPcmQueue replaceBytesInRange:NSMakeRange(0, packetPcmBytes) withBytes:NULL length:0];
    }
}

- (void)stopMicrophoneIfNeeded
{
    _micStopping = YES;
    _micEncryptionStatusLogged = NO;

    if (self.micAudioEngine != nil) {
        [self.micAudioEngine.inputNode removeTapOnBus:0];
        [self.micAudioEngine stop];
        self.micAudioEngine = nil;
    }
    self.micConverter = nil;

    dispatch_block_t teardownBlock = ^{
        self->_micSendFailures = 0;
        if (self->_micEncoder != NULL) {
            opus_multistream_encoder_destroy(self->_micEncoder);
            self->_micEncoder = NULL;
        }
        [self->_micPcmQueue setLength:0];
    };
    if (_micQueue != nil) {
        if (dispatch_get_specific(gMicQueueKey) == gMicQueueKey) {
            teardownBlock();
        } else {
            dispatch_sync(_micQueue, teardownBlock);
        }
    } else {
        teardownBlock();
    }
}

@end
