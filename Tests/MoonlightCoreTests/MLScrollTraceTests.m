#import <XCTest/XCTest.h>
#import "MLScrollTrace.h"

@interface MLScrollTraceTests : XCTestCase
@end

@implementation MLScrollTraceTests

- (void)setUp {
    [super setUp];
    MLScrollTraceReset();
    MLScrollTraceSetEnabled(YES);
}

- (void)testBeginAssignsIncreasingIdsAndRecordsSource {
    uint64_t a = MLScrollTraceBegin(MLScrollTraceSourceTrackpad, 1000);
    uint64_t b = MLScrollTraceBegin(MLScrollTraceSourcePhysicalWheel, 1010);
    XCTAssertGreaterThan(a, 0ULL);
    XCTAssertGreaterThan(b, a);
    MLScrollTraceSnapshot s = MLScrollTraceCurrent();
    XCTAssertEqual(s.traceId, b);
    XCTAssertEqual(s.source, MLScrollTraceSourcePhysicalWheel);
    XCTAssertEqual(s.startedMs, 1010ULL);
    XCTAssertFalse(s.awaitingRender);
}

- (void)testDispatchMarksAwaitingRenderAndCompleteClearsIt {
    MLScrollTraceBegin(MLScrollTraceSourceSmoothWheel, 5);
    MLScrollTraceNoteDispatch(-120, NO, YES, 7);
    XCTAssertTrue(MLScrollTraceIsAwaitingRender());
    MLScrollTraceSnapshot s = MLScrollTraceCompleteRender(20);
    XCTAssertEqual(s.lastDispatchMs, 7ULL);
    XCTAssertEqual(s.lastDispatchAmount, -120);
    XCTAssertTrue(s.lastDispatchHighRes);
    XCTAssertFalse(s.lastDispatchHorizontal);
    XCTAssertTrue(s.awaitingRender);
    XCTAssertFalse(MLScrollTraceIsAwaitingRender());
}

- (void)testDisabledRecordsNothing {
    MLScrollTraceSetEnabled(NO);
    XCTAssertEqual(MLScrollTraceBegin(MLScrollTraceSourceTrackpad, 1), 0ULL);
    MLScrollTraceNoteDispatch(10, YES, NO, 2);
    XCTAssertFalse(MLScrollTraceIsAwaitingRender());
    XCTAssertEqual(MLScrollTraceCurrent().traceId, 0ULL);
}

- (void)testDispatchWithoutBeginIsIgnored {
    MLScrollTraceNoteDispatch(10, NO, NO, 2);
    XCTAssertFalse(MLScrollTraceIsAwaitingRender());
}

- (void)testResetRestartsIds {
    MLScrollTraceBegin(MLScrollTraceSourceTrackpad, 1);
    MLScrollTraceReset();
    MLScrollTraceSetEnabled(YES);
    XCTAssertEqual(MLScrollTraceBegin(MLScrollTraceSourceTrackpad, 2), 1ULL);
}

@end
