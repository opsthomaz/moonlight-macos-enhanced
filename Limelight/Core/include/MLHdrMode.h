#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Transfer characteristics requested for the video stream. Values match the
/// protocol's STREAM_CONFIGURATION.hdrMode.
typedef NS_ENUM(NSInteger, MLHdrMode) {
    /// Standard dynamic range.
    MLHdrModeSDR = 0,
    /// HDR10, SMPTE ST 2084 perceptual quantizer.
    MLHdrModePQ = 1,
    /// Hybrid Log-Gamma, ARIB STD-B67.
    MLHdrModeHLG = 2,
};

/// Maps the user's HDR toggle and transfer-function preference to the protocol's hdrMode.
/// `hdrTransferFunction` uses the settings encoding: 0 automatic, 1 PQ, 2 HLG.
/// Anything other than HLG resolves to PQ when HDR is enabled.
MLHdrMode MLHdrModeForPreference(BOOL enableHdr, NSInteger hdrTransferFunction);

NS_ASSUME_NONNULL_END
