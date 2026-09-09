#import <XCTest/XCTest.h>
#import "MLClipboardFrame.h"

@interface MLClipboardFrameTests : XCTestCase
@end

@implementation MLClipboardFrameTests

- (void)testTextRoundTripMatchesReferenceBytes {
    NSData *payload = [@"hi" dataUsingEncoding:NSUTF8StringEncoding];
    MLClipboardFrame *frame = [MLClipboardFrame frameWithKind:MLClipboardKindText token:0 payload:payload];
    const uint8_t expected[] = {1, 1, 0, 0, 0, 0, 2, 0, 0, 0, 'h', 'i'};
    XCTAssertEqualObjects(frame.encodedData, [NSData dataWithBytes:expected length:sizeof(expected)]);
    MLClipboardFrame *decoded = [MLClipboardFrame frameFromData:frame.encodedData];
    XCTAssertEqual(decoded.kind, MLClipboardKindText);
    XCTAssertEqual(decoded.token, 0u);
    XCTAssertEqualObjects(decoded.payload, payload);
}

- (void)testTokenIsLittleEndian {
    NSData *payload = [@"x" dataUsingEncoding:NSUTF8StringEncoding];
    MLClipboardFrame *frame = [MLClipboardFrame frameWithKind:MLClipboardKindPNG token:0x01020304 payload:payload];
    const uint8_t *bytes = frame.encodedData.bytes;
    XCTAssertEqual(bytes[2], 0x04);
    XCTAssertEqual(bytes[3], 0x03);
    XCTAssertEqual(bytes[4], 0x02);
    XCTAssertEqual(bytes[5], 0x01);
    XCTAssertEqual([MLClipboardFrame frameFromData:frame.encodedData].token, 0x01020304u);
}

- (void)testRejectsShortWrongVersionAndOverlongLength {
    const uint8_t shortFrame[] = {1, 1, 0, 0, 0, 0, 0, 0, 0};
    XCTAssertNil([MLClipboardFrame frameFromData:[NSData dataWithBytes:shortFrame length:sizeof(shortFrame)]]);
    const uint8_t badVersion[] = {2, 1, 0, 0, 0, 0, 1, 0, 0, 0, 'a'};
    XCTAssertNil([MLClipboardFrame frameFromData:[NSData dataWithBytes:badVersion length:sizeof(badVersion)]]);
    const uint8_t overlong[] = {1, 1, 0, 0, 0, 0, 5, 0, 0, 0, 'a'};
    XCTAssertNil([MLClipboardFrame frameFromData:[NSData dataWithBytes:overlong length:sizeof(overlong)]]);
    const uint8_t zeroLength[] = {1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 'a'};
    XCTAssertNil([MLClipboardFrame frameFromData:[NSData dataWithBytes:zeroLength length:sizeof(zeroLength)]]);
}

- (void)testTrailingBytesAfterLengthAreIgnored {
    const uint8_t frame[] = {1, 2, 0, 0, 0, 0, 1, 0, 0, 0, 'a', 'b', 'c'};
    MLClipboardFrame *decoded = [MLClipboardFrame frameFromData:[NSData dataWithBytes:frame length:sizeof(frame)]];
    XCTAssertEqual(decoded.payload.length, 1u);
}

- (void)testUnknownKindDecodesToNil {
    const uint8_t frame[] = {1, 9, 0, 0, 0, 0, 1, 0, 0, 0, 'a'};
    XCTAssertNil([MLClipboardFrame frameFromData:[NSData dataWithBytes:frame length:sizeof(frame)]]);
}

- (void)testTextWithNulIsRejectedButBinaryIsNot {
    const uint8_t text[] = {1, 1, 0, 0, 0, 0, 2, 0, 0, 0, 'a', 0};
    XCTAssertNil([MLClipboardFrame frameFromData:[NSData dataWithBytes:text length:sizeof(text)]]);
    const uint8_t png[] = {1, 2, 0, 0, 0, 0, 2, 0, 0, 0, 'a', 0};
    XCTAssertNotNil([MLClipboardFrame frameFromData:[NSData dataWithBytes:png length:sizeof(png)]]);
}

- (void)testPayloadLimits {
    NSMutableData *big = [NSMutableData dataWithLength:MLClipboardFrameMaxPayload];
    XCTAssertNotNil([MLClipboardFrame frameWithKind:MLClipboardKindPNG token:0 payload:big]);
    [big setLength:MLClipboardFrameMaxPayload + 1];
    XCTAssertNil([MLClipboardFrame frameWithKind:MLClipboardKindPNG token:0 payload:big]);
    XCTAssertNil([MLClipboardFrame frameWithKind:MLClipboardKindText token:0 payload:[NSData data]]);
}

- (void)testPNGMagic {
    const uint8_t png[] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0};
    XCTAssertTrue(MLClipboardDataLooksLikePNG([NSData dataWithBytes:png length:sizeof(png)]));
    XCTAssertFalse(MLClipboardDataLooksLikePNG([@"GIF89a" dataUsingEncoding:NSASCIIStringEncoding]));
    XCTAssertFalse(MLClipboardDataLooksLikePNG([NSData data]));
}

@end
