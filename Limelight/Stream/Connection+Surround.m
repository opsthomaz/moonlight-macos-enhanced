//
//  Connection+Surround.m
//  Moonlight
//
//  7.1.4 Opus topology classification and runtime decoder fallback.
//

#import "Connection_Internal.h"

@implementation Connection (Surround)

BOOL MLIs714HighQualityOpusConfig(const OPUS_MULTISTREAM_CONFIGURATION *opusConfig) {
    return opusConfig != NULL &&
           opusConfig->channelCount == 12 &&
           opusConfig->streams == 12 &&
           opusConfig->coupledStreams == 0;
}

BOOL MLIs714CompatibilityOpusConfig(const OPUS_MULTISTREAM_CONFIGURATION *opusConfig) {
    return opusConfig != NULL &&
           opusConfig->channelCount == 12 &&
           opusConfig->streams == 8 &&
           opusConfig->coupledStreams == 4;
}

void MLPrepareOpusDecoderConfig(const OPUS_MULTISTREAM_CONFIGURATION *sourceConfig,
                                       OPUS_MULTISTREAM_CONFIGURATION *preparedConfig) {
    if (sourceConfig == NULL || preparedConfig == NULL) {
        return;
    }

    *preparedConfig = *sourceConfig;
    if (preparedConfig->channelCount == 8) {
        preparedConfig->mapping[4] = sourceConfig->mapping[6];
        preparedConfig->mapping[5] = sourceConfig->mapping[7];
        preparedConfig->mapping[6] = sourceConfig->mapping[4];
        preparedConfig->mapping[7] = sourceConfig->mapping[5];
    }
}

- (BOOL)recreateAudioDecoderWithConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
                                reason:(NSString *)reason
{
    if (opusConfig == NULL) {
        return NO;
    }

    OPUS_MULTISTREAM_CONFIGURATION preparedConfig = {};
    MLPrepareOpusDecoderConfig(opusConfig, &preparedConfig);

    int err = OPUS_OK;
    OpusMSDecoder *replacementDecoder = opus_multistream_decoder_create(preparedConfig.sampleRate,
                                                                        preparedConfig.channelCount,
                                                                        preparedConfig.streams,
                                                                        preparedConfig.coupledStreams,
                                                                        preparedConfig.mapping,
                                                                        &err);
    if (replacementDecoder == NULL || err != OPUS_OK) {
        Log(LOG_W, @"Failed to recreate Opus decoder (%@): streams=%d coupled=%d error=%d",
            reason ?: @"unknown",
            preparedConfig.streams,
            preparedConfig.coupledStreams,
            err);
        if (replacementDecoder != NULL) {
            opus_multistream_decoder_destroy(replacementDecoder);
        }
        return NO;
    }

    if (_opusDecoder != NULL) {
        opus_multistream_decoder_destroy(_opusDecoder);
    }
    _opusDecoder = replacementDecoder;
    _audioCurrentDecoderConfig = *opusConfig;
    _usingAudioFallbackDecoderConfig = _hasAudioFallbackDecoderConfig &&
        MLIs714CompatibilityOpusConfig(opusConfig);
    _audioBufferWriteIndex = 0;
    _audioBufferReadIndex = 0;
    _audioBufferReadFrameOffset = 0;
    _audioUnderrunCount = 0;
    _audioDecodeFailureCount = 0;
    _audioConsecutiveDecodeFailures = 0;
    _audioDecodeSampleCount = 0;
    _audioFallbackDecodeSuccessCount = 0;
    if (_audioCircularBuffer != NULL) {
        memset(_audioCircularBuffer, 0, _audioBufferEntries * _audioBufferStride * sizeof(short));
    }

    Log(LOG_I, @"Recreated Opus decoder (%@): channels=%d streams=%d coupled=%d",
        reason ?: @"unknown",
        preparedConfig.channelCount,
        preparedConfig.streams,
        preparedConfig.coupledStreams);
    return YES;
}

- (BOOL)attempt714DecoderTopologyFallbackAfterDecodeError:(int)decodeError
{
    if (decodeError >= 0 ||
        !_hasAudioFallbackDecoderConfig ||
        _usingAudioFallbackDecoderConfig ||
        _audioConsecutiveDecodeFailures < 8) {
        return NO;
    }

    Log(LOG_W, @"Attempting 7.1.4 Opus decoder fallback after %llu consecutive failures: current=%d/%d fallback=%d/%d error=%d",
        (unsigned long long)_audioConsecutiveDecodeFailures,
        _audioCurrentDecoderConfig.streams,
        _audioCurrentDecoderConfig.coupledStreams,
        _audioFallbackDecoderConfig.streams,
        _audioFallbackDecoderConfig.coupledStreams,
        decodeError);
    _audioPrimaryReprobeAttempted = NO;
    return [self recreateAudioDecoderWithConfig:&_audioFallbackDecoderConfig
                                         reason:@"7.1.4 fallback"];
}

- (BOOL)attempt714PrimaryDecoderReprobeWithSampleData:(char *)sampleData
                                         sampleLength:(int)sampleLength
{
    if (_disableHighQualitySurround ||
        !_usingAudioFallbackDecoderConfig ||
        _audioPrimaryReprobeAttempted ||
        !MLIs714HighQualityOpusConfig(&_audioAdvertisedOpusConfig) ||
        _audioFallbackDecodeSuccessCount < 120) {
        return NO;
    }

    _audioPrimaryReprobeAttempted = YES;
    Log(LOG_I, @"Attempting 7.1.4 primary decoder reprobe after %llu successful fallback decodes",
        (unsigned long long)_audioFallbackDecodeSuccessCount);

    if (![self recreateAudioDecoderWithConfig:&_audioAdvertisedOpusConfig
                                       reason:@"7.1.4 primary reprobe"]) {
        return NO;
    }

    int decodeLen = opus_multistream_decode(_opusDecoder,
                                            (unsigned char *)sampleData,
                                            sampleLength,
                                            (short *)&_audioCircularBuffer[_audioBufferWriteIndex * _audioBufferStride],
                                            _audioSamplesPerFrame,
                                            0);
    if (decodeLen > 0) {
        short *buffer = &_audioCircularBuffer[_audioBufferWriteIndex * _audioBufferStride];
        for (int i = 0; i < decodeLen * _channelCount; i++) {
            buffer[i] = (short)(buffer[i] * _audioVolumeMultiplier);
        }

        __sync_synchronize();
        _audioBufferWriteIndex = (_audioBufferWriteIndex + 1) % _audioBufferEntries;
        _audioDecodeSampleCount++;
        Log(LOG_I, @"7.1.4 primary decoder restored after fallback: decodedFrames=%d sampleLength=%d",
            decodeLen,
            sampleLength);
        return YES;
    }

    Log(LOG_W, @"7.1.4 primary decoder reprobe failed: error=%d; returning to fallback",
        decodeLen);
    [self recreateAudioDecoderWithConfig:&_audioFallbackDecoderConfig
                                  reason:@"7.1.4 fallback reprobe rollback"];
    return NO;
}

@end
