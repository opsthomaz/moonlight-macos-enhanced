#import "MLScrollTrace.h"
#import <os/lock.h>
#import <string.h>

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static BOOL gEnabled = NO;
static uint64_t gNextId = 1;
static MLScrollTraceSnapshot gState;

uint64_t MLScrollTraceBegin(MLScrollTraceSource source, uint64_t nowMs) {
    os_unfair_lock_lock(&gLock);
    if (!gEnabled) {
        os_unfair_lock_unlock(&gLock);
        return 0;
    }
    memset(&gState, 0, sizeof(gState));
    gState.traceId = gNextId++;
    gState.source = source;
    gState.startedMs = nowMs;
    uint64_t traceId = gState.traceId;
    os_unfair_lock_unlock(&gLock);
    return traceId;
}

void MLScrollTraceNoteDispatch(int32_t amount, BOOL horizontal, BOOL highRes, uint64_t nowMs) {
    os_unfair_lock_lock(&gLock);
    if (gEnabled && gState.traceId != 0) {
        gState.lastDispatchMs = nowMs;
        gState.lastDispatchAmount = amount;
        gState.lastDispatchHorizontal = horizontal;
        gState.lastDispatchHighRes = highRes;
        gState.awaitingRender = YES;
    }
    os_unfair_lock_unlock(&gLock);
}

BOOL MLScrollTraceIsAwaitingRender(void) {
    os_unfair_lock_lock(&gLock);
    BOOL awaiting = gState.awaitingRender;
    os_unfair_lock_unlock(&gLock);
    return awaiting;
}

MLScrollTraceSnapshot MLScrollTraceCompleteRender(uint64_t nowMs) {
    (void)nowMs;
    os_unfair_lock_lock(&gLock);
    MLScrollTraceSnapshot copy = gState;
    gState.awaitingRender = NO;
    os_unfair_lock_unlock(&gLock);
    return copy;
}

MLScrollTraceSnapshot MLScrollTraceCurrent(void) {
    os_unfair_lock_lock(&gLock);
    MLScrollTraceSnapshot copy = gState;
    os_unfair_lock_unlock(&gLock);
    return copy;
}

void MLScrollTraceSetEnabled(BOOL enabled) {
    os_unfair_lock_lock(&gLock);
    gEnabled = enabled;
    if (!enabled) {
        memset(&gState, 0, sizeof(gState));
    }
    os_unfair_lock_unlock(&gLock);
}

BOOL MLScrollTraceIsEnabled(void) {
    os_unfair_lock_lock(&gLock);
    BOOL enabled = gEnabled;
    os_unfair_lock_unlock(&gLock);
    return enabled;
}

void MLScrollTraceReset(void) {
    os_unfair_lock_lock(&gLock);
    memset(&gState, 0, sizeof(gState));
    gNextId = 1;
    gEnabled = NO;
    os_unfair_lock_unlock(&gLock);
}
