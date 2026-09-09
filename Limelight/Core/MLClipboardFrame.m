#import "MLClipboardFrame.h"
#import <string.h>

const NSUInteger MLClipboardFrameHeaderLength = 10;
const NSUInteger MLClipboardFrameMaxPayload = 65535 - 10;
const NSUInteger MLClipboardInlineThreshold = 60000;

static const uint8_t kMLClipboardWireVersion = 1;

@interface MLClipboardFrame ()
@property (nonatomic, readwrite) MLClipboardKind kind;
@property (nonatomic, readwrite) uint32_t token;
@property (nonatomic, readwrite) NSData *payload;
@end

@implementation MLClipboardFrame

+ (instancetype)frameWithKind:(MLClipboardKind)kind token:(uint32_t)token payload:(NSData *)payload {
    if (payload.length == 0 || payload.length > MLClipboardFrameMaxPayload) {
        return nil;
    }
    MLClipboardFrame *frame = [[self alloc] init];
    frame.kind = kind;
    frame.token = token;
    frame.payload = [payload copy];
    return frame;
}

+ (instancetype)frameFromData:(NSData *)data {
    if (data.length < MLClipboardFrameHeaderLength) {
        return nil;
    }
    const uint8_t *bytes = data.bytes;
    if (bytes[0] != kMLClipboardWireVersion) {
        return nil;
    }
    uint8_t kind = bytes[1];
    if (kind != MLClipboardKindText && kind != MLClipboardKindPNG && kind != MLClipboardKindRef) {
        return nil;
    }
    uint32_t token = (uint32_t)bytes[2] | ((uint32_t)bytes[3] << 8) | ((uint32_t)bytes[4] << 16) | ((uint32_t)bytes[5] << 24);
    uint32_t length = (uint32_t)bytes[6] | ((uint32_t)bytes[7] << 8) | ((uint32_t)bytes[8] << 16) | ((uint32_t)bytes[9] << 24);
    if (length == 0 || length > data.length - MLClipboardFrameHeaderLength) {
        return nil;
    }
    NSData *payload = [data subdataWithRange:NSMakeRange(MLClipboardFrameHeaderLength, length)];
    if (kind == MLClipboardKindText && memchr(payload.bytes, 0, payload.length) != NULL) {
        return nil;
    }
    return [self frameWithKind:(MLClipboardKind)kind token:token payload:payload];
}

- (NSData *)encodedData {
    uint32_t length = (uint32_t)self.payload.length;
    uint32_t token = self.token;
    uint8_t header[10] = {
        kMLClipboardWireVersion,
        self.kind,
        (uint8_t)(token & 0xFF), (uint8_t)((token >> 8) & 0xFF), (uint8_t)((token >> 16) & 0xFF), (uint8_t)((token >> 24) & 0xFF),
        (uint8_t)(length & 0xFF), (uint8_t)((length >> 8) & 0xFF), (uint8_t)((length >> 16) & 0xFF), (uint8_t)((length >> 24) & 0xFF),
    };
    NSMutableData *out = [NSMutableData dataWithCapacity:MLClipboardFrameHeaderLength + self.payload.length];
    [out appendBytes:header length:sizeof(header)];
    [out appendData:self.payload];
    return out;
}

@end

BOOL MLClipboardDataLooksLikePNG(NSData *data) {
    static const uint8_t magic[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    return data.length >= sizeof(magic) && memcmp(data.bytes, magic, sizeof(magic)) == 0;
}
