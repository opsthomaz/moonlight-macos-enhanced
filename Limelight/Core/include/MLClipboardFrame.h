#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Payload kinds carried by a Foundation Sunshine clipboard frame.
typedef NS_ENUM(uint8_t, MLClipboardKind) {
    /// UTF-8 text without NUL bytes.
    MLClipboardKindText = 1,
    /// PNG file bytes.
    MLClipboardKindPNG = 2,
    /// Compact JSON reference to an out-of-band blob: {"id":"...","mime":"...","size":N}.
    MLClipboardKindRef = 3,
};

/// Size of the fixed frame header in bytes.
extern const NSUInteger MLClipboardFrameHeaderLength;
/// Largest payload that fits in one control-stream packet.
extern const NSUInteger MLClipboardFrameMaxPayload;
/// Payloads at or above this size are sent as references by the reference client.
extern const NSUInteger MLClipboardInlineThreshold;

/// One clipboard control-stream frame, as exchanged with Foundation Sunshine.
///
/// Wire layout, little-endian:
/// `u8 version (1) | u8 kind | u32 token | u32 length | payload`.
/// A non-zero token groups consecutive frames of one clipboard change
/// (text first, then image); zero marks a standalone frame.
@interface MLClipboardFrame : NSObject

/// Kind of payload carried by the frame.
@property (nonatomic, readonly) MLClipboardKind kind;
/// Burst token, 0 for a standalone frame.
@property (nonatomic, readonly) uint32_t token;
/// Payload bytes, never empty.
@property (nonatomic, readonly) NSData *payload;

/// Builds a frame for sending. Returns nil when the payload is empty or larger than
/// MLClipboardFrameMaxPayload.
+ (nullable instancetype)frameWithKind:(MLClipboardKind)kind token:(uint32_t)token payload:(NSData *)payload;

/// Parses a frame received from the host. Returns nil on any validation failure:
/// short data, unknown version or kind, a length past the end, or NUL bytes in text.
+ (nullable instancetype)frameFromData:(NSData *)data;

/// Serializes the frame into the bytes passed to LiSendClipboardData.
- (NSData *)encodedData;

@end

/// YES when the data starts with the 8-byte PNG signature.
BOOL MLClipboardDataLooksLikePNG(NSData *data);

NS_ASSUME_NONNULL_END
