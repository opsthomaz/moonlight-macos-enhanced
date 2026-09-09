#import <XCTest/XCTest.h>
#import "MLHdrMode.h"

@interface MLHdrModeTests : XCTestCase
@end

@implementation MLHdrModeTests

- (void)testDisabledIsAlwaysSDR {
    XCTAssertEqual(MLHdrModeForPreference(NO, 0), MLHdrModeSDR);
    XCTAssertEqual(MLHdrModeForPreference(NO, 1), MLHdrModeSDR);
    XCTAssertEqual(MLHdrModeForPreference(NO, 2), MLHdrModeSDR);
}

- (void)testEnabledPrefersPQUnlessHLGRequested {
    XCTAssertEqual(MLHdrModeForPreference(YES, 0), MLHdrModePQ);
    XCTAssertEqual(MLHdrModeForPreference(YES, 1), MLHdrModePQ);
    XCTAssertEqual(MLHdrModeForPreference(YES, 2), MLHdrModeHLG);
    XCTAssertEqual(MLHdrModeForPreference(YES, 99), MLHdrModePQ);
}

- (void)testValuesMatchProtocol {
    XCTAssertEqual((NSInteger)MLHdrModeSDR, 0);
    XCTAssertEqual((NSInteger)MLHdrModePQ, 1);
    XCTAssertEqual((NSInteger)MLHdrModeHLG, 2);
}

@end
