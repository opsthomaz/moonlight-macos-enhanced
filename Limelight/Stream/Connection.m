//
//  Connection.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
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

#import "Connection_Internal.h"

@implementation Connection

@synthesize clipboardReady = _clipboardReady;

static os_unfair_lock gConnectionLifecycleLock = OS_UNFAIR_LOCK_INIT;

// The app drives a single connection at a time; callbacks from the protocol
// library resolve to it through this pointer.
static __weak Connection *gActiveConnection;


Connection* CurrentConnection(void) {
    return gActiveConnection;
}

VideoDecoderRenderer* ConnectionGetRendererSnapshot(Connection *conn) {
    if (conn == nil) {
        return nil;
    }

    os_unfair_lock_lock(&conn->_stateLock);
    VideoDecoderRenderer *renderer = conn->_renderer;
    os_unfair_lock_unlock(&conn->_stateLock);
    return renderer;
}

id<ConnectionCallbacks> ConnectionGetCallbacksSnapshot(Connection *conn) {
    if (conn == nil) {
        return nil;
    }

    os_unfair_lock_lock(&conn->_stateLock);
    id<ConnectionCallbacks> callbacks = conn->_callbacks;
    os_unfair_lock_unlock(&conn->_stateLock);
    return callbacks;
}

void ConnectionSetRenderer(Connection *conn, VideoDecoderRenderer *renderer) {
    if (conn == nil) {
        return;
    }

    os_unfair_lock_lock(&conn->_stateLock);
    conn->_renderer = renderer;
    os_unfair_lock_unlock(&conn->_stateLock);
}

void ConnectionSetCallbacks(Connection *conn, id<ConnectionCallbacks> callbacks) {
    if (conn == nil) {
        return;
    }

    os_unfair_lock_lock(&conn->_stateLock);
    conn->_callbacks = callbacks;
    os_unfair_lock_unlock(&conn->_stateLock);
}

void ConnectionClearRuntimeTargets(Connection *conn) {
    if (conn == nil) {
        return;
    }

    os_unfair_lock_lock(&conn->_stateLock);
    conn->_callbacks = nil;
    conn->_renderer = nil;
    os_unfair_lock_unlock(&conn->_stateLock);
}

+ (Connection *)currentConnection {
    return CurrentConnection();
}

- (VideoDecoderRenderer *)renderer {
    return ConnectionGetRendererSnapshot(self);
}

static void FillOutputBuffer(void *aqData,
                             AudioQueueRef inAQ,
                             AudioQueueBufferRef inBuffer);
static OSStatus RenderDirectAudioUnit(void *inRefCon,
                                      AudioUnitRenderActionFlags *ioActionFlags,
                                      const AudioTimeStamp *inTimeStamp,
                                      UInt32 inBusNumber,
                                      UInt32 inNumberFrames,
                                      AudioBufferList *ioData);

int DrDecoderSetup(int videoFormat, int width, int height, int redrawRate, void* context, int drFlags)
{
    Connection *conn = context ? (__bridge Connection *)context : CurrentConnection();
    if (conn == nil) {
        return -1;
    }
    VideoDecoderRenderer *renderer = ConnectionGetRendererSnapshot(conn);
    if (renderer == nil) {
        return -1;
    }
    [renderer setupWithVideoFormat:videoFormat
                         frameRate:redrawRate
                     upscalingMode:conn->_currentUpscalingMode
                      streamConfig:conn->_rendererStreamConfig];
    return 0;
}

void DrStart(void)
{
    Connection *conn = CurrentConnection();
    if (conn != nil) {
        VideoDecoderRenderer *renderer = ConnectionGetRendererSnapshot(conn);
        renderer.frameSourceReady = YES;
        [renderer start];
    }
}

void DrStop(void)
{
    Connection *conn = CurrentConnection();
    if (conn != nil) {
        VideoDecoderRenderer *renderer = ConnectionGetRendererSnapshot(conn);
        renderer.frameSourceReady = NO;
        [renderer stop];
        ConnectionClearRuntimeTargets(conn);
    }
}

void ClStageStarting(int stage)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks) {
        [callbacks stageStarting:LiGetStageName(stage)];
    }
}

void ClStageComplete(int stage)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks) {
        [callbacks stageComplete:LiGetStageName(stage)];
    }
}

void ClStageFailed(int stage, int errorCode)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks) {
        [callbacks stageFailed:LiGetStageName(stage) withError:errorCode];
    }
}

void ClConnectionStarted(void)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    Log(LOG_I, @"[diag] ClConnectionStarted: conn=%p callbacks=%p", conn, callbacks);
    if (!callbacks) {
        return;
    }

    conn->_clipboardReady = YES;
    __weak Connection *weakMicConn = conn;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        Log(LOG_I, @"[diag] ClConnectionStarted dispatch begin: conn=%p callbacks=%p", conn, callbacks);
        [callbacks connectionStarted];
        Log(LOG_I, @"[diag] ClConnectionStarted callback returned");

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong Connection *micConn = weakMicConn;
            if (micConn) {
                [micConn startMicrophoneIfNeeded];
            }
        });
    });
}

void ClConnectionTerminated(int errorCode)
{
    // Capture a weak reference to avoid retaining the connection if it's being deallocated
    __weak Connection *weakMicConn = CurrentConnection();
    // Stopping AVAudioEngine can occasionally block under CoreAudio stress.
    // Keep it off the main thread so UI doesn't appear frozen during disconnect.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong Connection *micConn = weakMicConn;
        if (micConn) {
            [micConn stopMicrophoneIfNeeded];
        }
    });
    Connection *conn = CurrentConnection();
    conn->_clipboardReady = NO;
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks) {
        [callbacks connectionTerminated: errorCode];
    }
}

void ClLogMessage(const char* format, ...)
{
    static uint64_t lastDropLogTime = 0;
    static int accumulatedDropCount = 0;
    
    // Simple heuristic to detect dropped frame logs from common-c
    bool isDropLog = (strstr(format, "Network dropped") != NULL);
    bool isHighFrequencyDiagnostic = (strstr(format, "[inputdiag]") != NULL);

    if (isDropLog) {
        accumulatedDropCount++;
        uint64_t now = LiGetMillis();
        if (now - lastDropLogTime < 1000) {
            return; // Suppress this log
        }
        lastDropLogTime = now;
    }

    va_list va;
    va_start(va, format);

    if (!isHighFrequencyDiagnostic) {
        va_list stderrArgs;
        va_copy(stderrArgs, va);
        vfprintf(stderr, format, stderrArgs);
        va_end(stderrArgs);
    }

    va_list formatArgs;
    va_copy(formatArgs, va);
    char stackBuffer[2048];
    int requiredLength = vsnprintf(stackBuffer, sizeof(stackBuffer), format, formatArgs);
    va_end(formatArgs);

    NSString *formattedLine = nil;
    if (requiredLength >= 0 && requiredLength < (int)sizeof(stackBuffer)) {
        formattedLine = [NSString stringWithUTF8String:stackBuffer];
    } else if (requiredLength >= (int)sizeof(stackBuffer)) {
        size_t heapLength = (size_t)requiredLength + 1;
        char *heapBuffer = malloc(heapLength);
        if (heapBuffer != NULL) {
            va_list heapArgs;
            va_copy(heapArgs, va);
            vsnprintf(heapBuffer, heapLength, format, heapArgs);
            va_end(heapArgs);
            formattedLine = [NSString stringWithUTF8String:heapBuffer];
            free(heapBuffer);
        }
    }

    va_end(va);

    if (formattedLine.length > 0) {
        NSString *trimmedLine = [formattedLine stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        if (trimmedLine.length > 0) {
            LogLevel derivedLevel = isDropLog ? LOG_W : (isHighFrequencyDiagnostic ? LOG_D : LOG_I);
            [[LogBuffer shared] appendLine:trimmedLine level:derivedLevel];
            if (!isHighFrequencyDiagnostic || LoggerIsInputDiagnosticsEnabled()) {
                LoggerPersistMessage(derivedLevel, trimmedLine);
            }
        }
    }

    if (isDropLog && accumulatedDropCount > 1) {
        NSString *summaryLine = [NSString stringWithFormat:@"(and %d more dropped frame messages suppressed)", accumulatedDropCount - 1];
        fprintf(stderr, " %s\n", summaryLine.UTF8String);
        [[LogBuffer shared] appendLine:summaryLine level:LOG_W];
        accumulatedDropCount = 0;
    }
}

void ClRumble(unsigned short controllerNumber, unsigned short lowFreqMotor, unsigned short highFreqMotor)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks) {
        [callbacks rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
    }
}

void ClConnectionStatusUpdate(int status)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks) {
        [callbacks connectionStatusUpdate:status];
    }
}

- (void)dealloc
{
    // Remove notification observer to prevent crashes from stale references
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

-(void) terminate
{
    ConnectionGetRendererSnapshot(self).frameSourceReady = NO;

    // Interrupt any action blocking LiStartConnection(). This is
    // thread-safe and done outside initLock on purpose, since we
    // won't be able to acquire it if LiStartConnection is in
    // progress.
    LiInterruptConnection();
    _clipboardReady = NO;

    // Ensure mic queue is stopped before connection teardown
    [self stopMicrophoneIfNeeded];

    // We dispatch this async to get out because this can be invoked
    // on a thread inside common and we don't want to deadlock. It also avoids
    // blocking on the caller's thread waiting to acquire initLock.
    // Capture self strongly in the block to keep the Connection object alive
    // until LiStopConnection finishes.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        // Prevent self from being deallocated during cleanup
        __strong Connection *conn = self;
        if (conn == nil) {
            return;
        }
        os_unfair_lock_lock(&gConnectionLifecycleLock);
        LiStopConnection();
        os_unfair_lock_unlock(&gConnectionLifecycleLock);
        if (gActiveConnection == conn) {
            gActiveConnection = nil;
        }
        // conn is released here after the block completes, ensuring
        // the Connection object stays alive throughout cleanup
    });
}

-(id) initWithConfig:(StreamConfiguration*)config renderer:(VideoDecoderRenderer*)myRenderer connectionCallbacks:(id<ConnectionCallbacks>)callbacks
{
    self = [super init];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateVolume) name:@"volumeSettingChanged" object:nil];
    
    // Use a lock to ensure that only one thread is initializing
    // or deinitializing a connection at a time.
    if (_initLock == nil) {
        _initLock = [[NSLock alloc] init];
    }
    
    _hostAddress = config.host;
    _audioVolumeMultiplier = 1.0f;
    _stateLock = OS_UNFAIR_LOCK_INIT;
    _audioOutputMode = config.audioOutputMode;
    _enhancedAudioOutputTarget = (int)MLResolveEnhancedOutputTarget((MLAudioEnhancedOutputTarget)config.enhancedAudioOutputTarget);
    _enhancedAudioPreset = config.enhancedAudioPreset;
    _enhancedAudioSpatialIntensity = config.enhancedAudioSpatialIntensity;
    _enhancedAudioSoundstageWidth = config.enhancedAudioSoundstageWidth;
    _enhancedAudioReverbAmount = config.enhancedAudioReverbAmount;
    _enhancedAudioEQGains = [config.enhancedAudioEQGains copy];
    _audioRendererBackend = MLAudioRendererBackendLegacyQueue;
    _audioDeviceChannelCount = 2;
    _audioRenderChannelCount = 0;
    _audioBufferReadFrameOffset = 0;
    [self updateVolume];
    
    NSString* cleanHost;
    [Utils parseAddress:config.host intoHost:&cleanHost andPort:nil];
    
    strncpy(_hostString,
            [cleanHost cStringUsingEncoding:NSUTF8StringEncoding],
            sizeof(_hostString));
    strncpy(_appVersionString,
            [config.appVersion cStringUsingEncoding:NSUTF8StringEncoding],
            sizeof(_appVersionString));
    if (config.gfeVersion != nil) {
        strncpy(_gfeVersionString,
                [config.gfeVersion cStringUsingEncoding:NSUTF8StringEncoding],
                sizeof(_gfeVersionString));
    }

    LiInitializeServerInformation(&_serverInfo);
    _serverInfo.address = _hostString;
    _serverInfo.serverInfoAppVersion = _appVersionString;
    // The library asserts that this field is set. If the host hasn't been
    // refreshed yet and we don't have it, fall back to the safest baseline.
    _serverInfo.serverCodecModeSupport = (config.serverCodecModeSupport != 0) ? config.serverCodecModeSupport : SCM_H264;
    if (config.gfeVersion != nil) {
        _serverInfo.serverInfoGfeVersion = _gfeVersionString;
    }

    if (config.sessionUrl != nil) {
        strncpy(_rtspSessionUrl, [config.sessionUrl UTF8String], sizeof(_rtspSessionUrl) - 1);
        _rtspSessionUrl[sizeof(_rtspSessionUrl) - 1] = '\0';
        _serverInfo.rtspSessionUrl = _rtspSessionUrl;
    }

    ConnectionSetRenderer(self, myRenderer);
    ConnectionSetCallbacks(self, callbacks);
    // The display link may fire before the video stream starts; frames are
    // pulled only while this flag is set, and it is cleared on terminate.
    myRenderer.frameSourceReady = YES;
    _currentUpscalingMode = config.upscalingMode;
    _rendererStreamConfig = config;

    gActiveConnection = self;
    LiInitializeStreamConfiguration(&_streamConfig);
    _streamConfig.width = config.width;
    _streamConfig.height = config.height;
    _streamConfig.fps = config.frameRate;
    _streamConfig.bitrate = config.bitRate;
    _streamConfig.audioConfiguration = config.audioConfiguration;
    _disableHighQualitySurround = config.disableHighQualitySurround;
    _streamConfig.colorSpace = COLORSPACE_REC_709;

    // Enable microphone streaming only if requested in settings. The host may ignore it.
    BOOL enableMic = NO;
    @try {
        NSString* uuid = config.hostUUID;
        if (uuid == nil && config.host != nil) {
            uuid = [SettingsClass getHostUUIDFrom:config.host];
        }

        NSString* settingsKey = uuid != nil ? uuid : @"__global__";
        NSDictionary* settings = [SettingsClass getSettingsFor:settingsKey];
        if (settings != nil) {
            enableMic = [settings[@"microphone"] boolValue];
        }
        Log(LOG_I, @"Microphone setting: enableMic=%d host=%@ uuid=%@ key=%@",
            enableMic, config.host, uuid, settingsKey);
    } @catch (NSException* exception) {
        Log(LOG_W, @"Exception reading microphone setting: %@", exception);
        enableMic = NO;
    }

    _streamConfig.enableMic = enableMic;
    if (enableMic) {
        _streamConfig.encryptionFlags |= ENCFLG_MICROPHONE;
    }

    
    // Resolve LOCAL/REMOTE for packet sizing with target-route evidence.
    // This avoids misclassifying local sessions when a VPN/proxy app is active but not used by this stream.
    BOOL remoteByConfig = config.streamingRemotely;
    BOOL vpnActive = [Utils isActiveNetworkVPN];
    NSString *egressSource = nil;
    NSString *egressIf = [Utils outboundInterfaceNameForAddress:config.host sourceAddress:&egressSource];
    BOOL routeKnown = egressIf.length > 0;
    BOOL routeThroughTunnel = routeKnown && [Utils isTunnelInterfaceName:egressIf];
    BOOL remoteByVpnFallback = vpnActive && !routeKnown && !remoteByConfig;
    BOOL useRemotePacketConfig = remoteByConfig || routeThroughTunnel || remoteByVpnFallback;

    if (routeThroughTunnel && !config.autoAdjustBitrate && _streamConfig.fps >= 120 && _streamConfig.bitrate >= 12000) {
        Log(LOG_W, @"[diag] Tunnel manual profile may be too aggressive: fps=%d bitrate=%d (consider <=90fps or <=10000kbps)",
            _streamConfig.fps,
            _streamConfig.bitrate);
    }

    if (routeThroughTunnel && config.autoAdjustBitrate) {
        int tunnelBitrateCap = 8000;
        if (_streamConfig.fps >= 90) {
            tunnelBitrateCap = 12000;
        } else if (_streamConfig.fps >= 60) {
            tunnelBitrateCap = 10000;
        }
        if (_streamConfig.bitrate > tunnelBitrateCap) {
            Log(LOG_I, @"[diag] Tunnel bitrate cap applied: %d -> %d (fps=%d)",
                _streamConfig.bitrate,
                tunnelBitrateCap,
                _streamConfig.fps);
            _streamConfig.bitrate = tunnelBitrateCap;
        }
    } else if (routeThroughTunnel) {
        Log(LOG_I, @"[diag] Tunnel bitrate auto-cap skipped: autoAdjustBitrate=0 (fps=%d bitrate=%d)",
            _streamConfig.fps,
            _streamConfig.bitrate);
    }

    Log(LOG_I, @"[diag] Packet config classification: host=%@ remoteByConfig=%d routeKnown=%d routeTunnel=%d vpn=%d vpnFallback=%d egressIf=%@ source=%@ useRemote=%d",
        config.host ?: @"(null)",
        remoteByConfig ? 1 : 0,
        routeKnown ? 1 : 0,
        routeThroughTunnel ? 1 : 0,
        vpnActive ? 1 : 0,
        remoteByVpnFallback ? 1 : 0,
        egressIf ?: @"(unknown)",
        egressSource ?: @"",
        useRemotePacketConfig ? 1 : 0);

    if (useRemotePacketConfig) {
        _streamConfig.streamingRemotely = STREAM_CFG_REMOTE;
        // For tunnel paths (utun/wg), prioritize MTU safety over lower PPS.
        // Empirically, larger payloads such as 1024 bytes can behave worse than
        // 896 bytes on encapsulated/overlay routes even at lower frame rates,
        // likely due to effective PMTU headroom and loss amplification.
        if (routeThroughTunnel) {
            _streamConfig.packetSize = 896;
            Log(LOG_I, @"[diag] Tunnel MTU-first packet mode: fps=%d bitrate=%d packet=%d",
                _streamConfig.fps,
                _streamConfig.bitrate,
                _streamConfig.packetSize);
        }
        else if (_streamConfig.fps >= 120) {
            _streamConfig.packetSize = 896;
            Log(LOG_I, @"[diag] Public remote MTU-first packet mode: fps=%d bitrate=%d packet=%d",
                _streamConfig.fps,
                _streamConfig.bitrate,
                _streamConfig.packetSize);
        }
        else {
            _streamConfig.packetSize = 1024;
        }
    } else {
        _streamConfig.streamingRemotely = STREAM_CFG_LOCAL;
        _streamConfig.packetSize = 1392;
    }

    Log(LOG_I, @"[diag] Packet size chosen: %d (remote=%d tunnel=%d)",
        _streamConfig.packetSize,
        _streamConfig.streamingRemotely == STREAM_CFG_REMOTE ? 1 : 0,
        routeThroughTunnel ? 1 : 0);
    
    // HDR implies HEVC allowed
    if (config.enableHdr) {
        config.allowHevc = YES;
    }

    // On iOS 11, we can use HEVC if the server supports encoding it
    // and this device has hardware decode for it (A9 and later).
    // Additionally, iPhone X had a bug which would cause video
    // to freeze after a few minutes with HEVC prior to iOS 11.3.
    // As a result, we will only use HEVC on iOS 11.3 or later.
    // Newer moonlight-common-c uses supportedVideoFormats for codec negotiation.
    int codecPreference = config.videoCodecPreference;
    BOOL hevcDecodeSupported = NO;
    hevcDecodeSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
    
    BOOL hevcSupported = codecPreference >= 1 && hevcDecodeSupported;
    BOOL av1Supported = codecPreference >= 2 && VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);

    // If HDR is requested, at least one 10-bit codec path must be available.
    assert(!config.enableHdr || hevcSupported || av1Supported);

    BOOL enableYuv444 = NO;
    @try {
        NSString* uuid = config.hostUUID;
        if (uuid == nil && config.host != nil) {
            uuid = [SettingsClass getHostUUIDFrom:config.host];
        }

        NSString* settingsKey = uuid != nil ? uuid : @"__global__";
        NSDictionary* settings = [SettingsClass getSettingsFor:settingsKey];
        if (settings != nil) {
            enableYuv444 = [settings[@"yuv444"] boolValue];
        }
    } @catch (NSException* exception) {
        enableYuv444 = NO;
    }

    int supportedVideoFormats = VIDEO_FORMAT_H264;
    if (hevcSupported) {
        supportedVideoFormats |= VIDEO_FORMAT_H265;
        if (config.enableHdr) {
            supportedVideoFormats |= VIDEO_FORMAT_H265_MAIN10;
        }
    }

    if (enableYuv444) {
        supportedVideoFormats |= VIDEO_FORMAT_H264_HIGH8_444;
        if (hevcSupported) {
            supportedVideoFormats |= VIDEO_FORMAT_H265_REXT8_444;
            if (config.enableHdr) {
                supportedVideoFormats |= VIDEO_FORMAT_H265_REXT10_444;
            }
        }
    }

    if (av1Supported) {
        if (config.enableHdr) {
            supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN10;
        } else {
            supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN8;
        }

        if (enableYuv444) {
            supportedVideoFormats |= VIDEO_FORMAT_AV1_HIGH8_444;
            if (config.enableHdr) {
                supportedVideoFormats |= VIDEO_FORMAT_AV1_HIGH10_444;
            }
        }
    }

    _streamConfig.supportedVideoFormats = supportedVideoFormats;
    Log(LOG_I, @"[diag] Codec preference resolved: pref=%d av1=%d hevc=%d hdr=%d yuv444=%d formats=0x%X",
        codecPreference,
        av1Supported ? 1 : 0,
        hevcSupported ? 1 : 0,
        config.enableHdr ? 1 : 0,
        enableYuv444 ? 1 : 0,
        supportedVideoFormats);

    _streamConfig.hdrMode = (int)MLHdrModeForPreference(config.enableHdr, config.hdrTransferFunction);
    Log(LOG_I, @"[diag] HDR transfer preference resolved: hdr=%d tf=%d hdrMode=%d",
        config.enableHdr ? 1 : 0,
        config.hdrTransferFunction,
        _streamConfig.hdrMode);

    memcpy(_streamConfig.remoteInputAesKey, [config.riKey bytes], [config.riKey length]);
    memset(_streamConfig.remoteInputAesIv, 0, 16);
    int riKeyId = htonl(config.riKeyId);
    memcpy(_streamConfig.remoteInputAesIv, &riKeyId, sizeof(riKeyId));

    LiInitializeVideoCallbacks(&_drCallbacks);
    _drCallbacks.setup = DrDecoderSetup;
    _drCallbacks.start = DrStart;
    _drCallbacks.stop = DrStop;

//#if TARGET_OS_IPHONE
    // RFI doesn't work properly with HEVC on iOS 11 with an iPhone SE (at least)
    // It doesnt work on macOS either, tested with Network Link Conditioner.
    _drCallbacks.capabilities = CAPABILITY_PULL_RENDERER |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1;
//#endif

    LiInitializeAudioCallbacks(&_arCallbacks);
    _arCallbacks.init = ArInit;
    _arCallbacks.cleanup = ArCleanup;
    _arCallbacks.decodeAndPlaySample = ArDecodeAndPlaySample;
    _arCallbacks.capabilities = CAPABILITY_DIRECT_SUBMIT |
                                CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION;

    LiInitializeConnectionCallbacks(&_clCallbacks);
    _clCallbacks.stageStarting = ClStageStarting;
    _clCallbacks.stageComplete = ClStageComplete;
    _clCallbacks.stageFailed = ClStageFailed;
    _clCallbacks.connectionStarted = ClConnectionStarted;
    _clCallbacks.connectionTerminated = ClConnectionTerminated;
    _clCallbacks.logMessage = ClLogMessage;
    _clCallbacks.rumble = ClRumble;
    _clCallbacks.connectionStatusUpdate = ClConnectionStatusUpdate;
    _clCallbacks.clipboardData = ClClipboardData;
    _clCallbacks.cursorUpdate = ClCursorUpdate;

    return self;
}

- (BOOL)getEstimatedRtt:(uint32_t *)rttMs variance:(uint32_t *)varianceMs {
    uint32_t rtt = 0;
    uint32_t variance = 0;
    if (!LiGetEstimatedRttInfo(&rtt, &variance)) {
        return NO;
    }
    if (rttMs != NULL) {
        *rttMs = rtt;
    }
    if (varianceMs != NULL) {
        *varianceMs = variance;
    }
    return YES;
}

- (uint32_t)hostFeatureFlags {
    return LiGetHostFeatureFlags();
}

- (BOOL)getVideoDiagnosticSnapshot:(MLVideoDiagnosticSnapshot *)snapshot {
    if (snapshot == NULL) {
        return NO;
    }

    memset(snapshot, 0, sizeof(*snapshot));

    const RTP_VIDEO_STATS *stats = LiGetRTPVideoStats();
    if (stats != NULL) {
        snapshot->videoPackets = stats->packetCountVideo;
        snapshot->fecPackets = stats->packetCountFec;
        snapshot->fecRecoveredPackets = stats->packetCountFecRecovered;
        snapshot->fecFailedPackets = stats->packetCountFecFailed;
        snapshot->outOfSequencePackets = stats->packetCountOOS;
        snapshot->invalidPackets = stats->packetCountInvalid + stats->packetCountFecInvalid;
    }
    snapshot->bytesReceived = LiGetRTPVideoBytesReceived();
    snapshot->frameLossPercent = LiGetEstimatedVideoFrameLossPercentage();
    snapshot->pendingFrames = LiGetPendingVideoFrames();

    return YES;
}

-(void) main
{
    os_unfair_lock_lock(&gConnectionLifecycleLock);
    gActiveConnection = self;
    Log(LOG_I, @"LiStartConnection: conn=%p", self);
    LiStartConnection(&_serverInfo,
                      &_streamConfig,
                      &_clCallbacks,
                      &_drCallbacks,
                      &_arCallbacks,
                      (__bridge void *)self, 0,
                      (__bridge void *)self, 0);
    os_unfair_lock_unlock(&gConnectionLifecycleLock);
}

@end
