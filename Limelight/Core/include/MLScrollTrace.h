#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Where a scroll gesture came from. Mirrors the client's wheel routing.
typedef NS_ENUM(NSInteger, MLScrollTraceSource) {
    MLScrollTraceSourceNone = 0,
    /// Wheel events delivered through GameController's GCMouse.
    MLScrollTraceSourceGameControllerMouse,
    /// Wheel and trackpad events delivered through AppKit's scrollWheel:.
    MLScrollTraceSourceAppKit,
};

/// Point-in-time copy of the active scroll trace. Safe to read after the call returns.
typedef struct {
    /// Identifier of the active trace, 0 when none is active.
    uint64_t traceId;
    /// Input source that started the trace.
    MLScrollTraceSource source;
    /// Timestamp in milliseconds at which the trace started.
    uint64_t startedMs;
    /// Timestamp in milliseconds of the last scroll handed to the protocol layer, 0 until then.
    uint64_t lastDispatchMs;
    /// Scroll amount of the last dispatch, in the units the sender used.
    int32_t lastDispatchAmount;
    /// YES when the last dispatch was a horizontal scroll.
    BOOL lastDispatchHorizontal;
    /// YES when the last dispatch used the high-resolution scroll event.
    BOOL lastDispatchHighRes;
    /// YES while a dispatched scroll has not been matched to a rendered frame.
    BOOL awaitingRender;
} MLScrollTraceSnapshot;

/// Starts a new trace and returns its id, or 0 when tracing is disabled.
uint64_t MLScrollTraceBegin(MLScrollTraceSource source, uint64_t nowMs);

/// Records that a scroll event was handed to the protocol layer for the active trace.
/// Ignored when tracing is disabled or no trace is active.
void MLScrollTraceNoteDispatch(int32_t amount, BOOL horizontal, BOOL highRes, uint64_t nowMs);

/// YES when a dispatched scroll has not yet been matched to a rendered frame.
BOOL MLScrollTraceIsAwaitingRender(void);

/// Marks the pending dispatch as rendered and returns the trace state as it was at that moment.
MLScrollTraceSnapshot MLScrollTraceCompleteRender(uint64_t nowMs);

/// Returns the current trace state without changing it.
MLScrollTraceSnapshot MLScrollTraceCurrent(void);

/// Enables or disables recording. Disabling also clears the active trace.
void MLScrollTraceSetEnabled(BOOL enabled);

/// YES when recording is enabled.
BOOL MLScrollTraceIsEnabled(void);

/// Clears all state, disables recording, and restarts ids from 1.
/// Used by tests and on stream teardown.
void MLScrollTraceReset(void);

NS_ASSUME_NONNULL_END
