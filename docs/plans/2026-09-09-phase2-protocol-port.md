# Phase 2 — Protocol Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the native macOS client speak the Foundation Sunshine protocol through the public API of `qiin2333/moonlight-common-c` branch `mic`, with zero references to the library's private header, so the client tracks the server by bumping a submodule pointer.

**Architecture:** The client today reaches into a private fork of the protocol library (58 `*Ctx` functions, an embedded internal struct, a per-thread context registry). Because the app never opens more than one connection, every `*Ctx` call collapses to its public single-connection equivalent, the registry collapses to one static pointer, and the three fork-only features (clipboard, microphone, HDR mode) are re-expressed on the `mic` API. Pure logic that the port creates (scroll trace bookkeeping, clipboard frame codec, HDR mode mapping) lives in `Limelight/Core/`, is Foundation-only, and is unit-tested through a SwiftPM package so tests run in CI without touching the Xcode project.

**Tech Stack:** Objective-C, Metal, VideoToolbox, Core Audio, AVAudioEngine, Opus (xcframework), XCTest via SwiftPM (`swift test`), git submodules, Xcode 27.0 beta, GitHub Actions `macos-26`.

**Spec:** `docs/design/2026-09-09-foundation-native-client-design.md` sections 4.1 to 4.4 and 4.6 (tests), section 5 phase 2.

## Global Constraints

- No commit, push, tag, or pull request without the owner's explicit authorization. Every "Commit" step is preceded by an **Authorization gate**.
- No mention of any AI assistant or AI tooling in commits, files, PRs, or comments. No `Co-Authored-By` trailers.
- Commit subjects: `<type>(<scope>): <lowercase description>`, max 72 chars, types `feat|fix|docs|refactor|perf|test|chore|style|build|ci`. English everywhere.
- Branch `phase2/protocol-port`, created from `phase1/housekeeping` at `aaacb74`.
- Minimum macOS is **15.0** from Task 1 on. Apple Silicon only (arm64). CI is arm64 only.
- Build command (unsigned, Xcode 27.0 beta):
  ```bash
  DEVELOPER_DIR=/Users/thomazmac/Downloads/Xcode-beta.app/Contents/Developer xcodebuild -project Moonlight.xcodeproj -scheme "Moonlight for macOS" -configuration Release -arch arm64 -derivedDataPath /tmp/dd-phase2 CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'; git checkout -- Limelight/Version.xcconfig
  ```
  Referred to below as **the build command**.
- **Adding a source file to the app target:** the `Limelight/` group is a synchronized group whose default membership is *off*; files compile only if listed in `membershipExceptions` in `Moonlight.xcodeproj/project.pbxproj` (the block starting at line 71). To add `Limelight/Core/Foo.m`, insert a line `				Core/Foo.m,` in that list, keeping it alphabetical. Headers are found by name through Xcode's headers map, no search-path change needed.
- **Adding a source file to the `moonlight-common` static library:** that project lists files explicitly (`moonlight-common/moonlight-common.xcodeproj/project.pbxproj`). Each file needs a `PBXFileReference`, a `PBXBuildFile`, a group entry, and a `PBXSourcesBuildPhase` entry. Task 8 gives the exact text.
- Manual protocol checks run against the owner's Foundation Sunshine host. The build product is `/tmp/dd-phase2/Build/Products/Release/Moonlight.app`. Launch it from there; do not install (bundle id still collides with Moonlight V+ for PC until phase 5).
- Never `git submodule update` on the old URL after Task 8; the submodule remote changes there.

## Verified starting state (2026-09-09)

- `upstream` common-c submodule: `skyhua0224/moonlight-common-c` at `f262d597`. Target: `qiin2333/moonlight-common-c` branch `mic` at **`31a2a4589e`** (`feat(control): receive remote text context updates (#28)`).
- Fork-only `STREAM_CONFIGURATION` fields the client sets: `enableMic` (exists on `mic` too), `disableHighQualitySurround` (client-only concept, not on `mic`), `dynamicRangeMode` (renamed `hdrMode` on `mic`, values 0 SDR / 1 PQ / 2 HLG).
- Public on `mic` and safe to call directly: `LiStartConnection`, `LiStopConnection`, `LiInterruptConnection`, `LiSend{MouseMove,MousePosition,MouseButton,Keyboard,Scroll,HighResScroll,HScroll,HighResHScroll,Controller,MultiController,ControllerArrival,ControllerBattery,ControllerMotion,ControllerTouch}Event`, `LiSendUtf8TextEvent`, `LiPollNextVideoFrame`, `LiWaitForNextVideoFrame`, `LiCompleteVideoFrame`, `LiGetPendingVideoFrames`, `LiGetEstimatedRttInfo`, `LiGetRTPVideoStats`, `LiGetRTPVideoBytesReceived`, `LiGetEstimatedVideoFrameLossPercentage`, `LiGetHostFeatureFlags`, `LiGetHdrMetadata`, `LiRequestIdrFrame`, `LiSendClipboardData`, `LiSetCursorMode`, `LiSendClientSdrWhiteNits`, `LiGetLaunchUrlQueryParameters`, `LiFindExternalAddressIP4`, `LiGetMillis`, `LiGetStageName`.
- Microphone on `mic` has no public header. Symbols: `int initializeMicrophoneStream(void)`, `void destroyMicrophoneStream(void)`, `int sendMicrophoneOpusData(const unsigned char*, int)`. `LiStartConnection` calls `initializeMicrophoneStream` itself when `enableMic` is set (stage `STAGE_MICROPHONE_STREAM_INIT`); a second call is idempotent. There is no control message; `LI_MIC_CONTROL_*` does not exist on `mic`.
- Clipboard on `mic`: `LiSendClipboardData(payload, len)` with `0 < len <= 65535`, callback `clipboardData(const char* data, int length)` in `CONNECTION_LISTENER_CALLBACKS` (member after `resolutionChanged`), dispatched synchronously on the control receive thread. Frame format is defined by the Qt client, not the library (see Task 7).
- Cursor sync on `mic`: `LiSetCursorMode(LI_CURSOR_MODE_LOCAL)` after `connectionStarted`, gated by `LiGetHostFeatureFlags() & LI_FF_CURSOR_SHAPE`; callback `cursorUpdate(const LI_CURSOR_UPDATE*)` (member after `clipboardData`) with tightly packed BGRA8888 pixels, max 256x256, valid only during the call.
- Reed-Solomon on `mic` moved from in-tree `reedsolomon/rs.c` to the `nanors` submodule: sources `nanors/rs.c`, `nanors/deps/obl/oblas_common.c`, `nanors/deps/obl/oblas_lite.c`; include dirs `nanors`, `nanors/deps`, `nanors/deps/obl`. New sources on `mic`: `src/CursorStream.c`, `src/Ds5HapticsStream.c`, `src/Ds5HapticsIrStream.c`, `src/RemoteTextContextStream.c`, `src/MicrophoneStream.c` (already listed).
- `Limelight/Input/StreamView.m` and `Limelight/Input/OnScreenControls.m` are iOS leftovers not compiled into the macOS target.
- Availability checks below macOS 15 in the client: 39 (`VideoDecoderRenderer.m` has 26).

## File Structure

New:
- `Package.swift` — SwiftPM manifest: target `MoonlightCore` (path `Limelight/Core`, Objective-C, Foundation only) and test target `MoonlightCoreTests` (path `Tests/MoonlightCoreTests`).
- `Limelight/Core/include/MLScrollTrace.h`, `Limelight/Core/MLScrollTrace.m` — scroll trace bookkeeping shared by input and renderer.
- `Limelight/Core/include/MLClipboardFrame.h`, `Limelight/Core/MLClipboardFrame.m` — clipboard wire frame encode/decode.
- `Limelight/Core/include/MLHdrMode.h`, `Limelight/Core/MLHdrMode.m` — HDR preference to `hdrMode` mapping.
- `Tests/MoonlightCoreTests/MLScrollTraceTests.m`, `MLClipboardFrameTests.m`, `MLHdrModeTests.m`.
- `Limelight/Stream/Connection_Internal.h` — class extension shared by the `Connection` categories.
- `Limelight/Stream/Connection+Audio.m`, `Connection+Surround.m`, `Connection+Microphone.m`, `Connection+Clipboard.m`, `Connection+Cursor.m` — categories extracted from `Connection.m`.

Modified: `Limelight/Stream/Connection.{h,m}`, `Limelight/Stream/VideoDecoderRenderer.{h,m}`, `Limelight/Input/HIDSupport.m`, `HIDSupport+Pointer.m`, `HIDSupport+Scroll.m`, `HIDSupport_Internal.h`, `HIDSupport.h`, `ControllerSupport.{h,m}`, `Limelight/macOS/ViewControllers/StreamViewController.m`, `StreamViewController_Internal.h`, `StreamViewController+Diagnostics.m`, `StreamViewController+MenuUI.m`, `StreamViewController+MouseCapture.m`, `Moonlight.xcodeproj/project.pbxproj`, `moonlight-common/moonlight-common.xcodeproj/project.pbxproj`, `.gitmodules`, `.github/workflows/build.yml`, `docs/design/...`.

Deleted: `Limelight/Input/StreamView.m`, `Limelight/Input/StreamView.h`, `Limelight/Input/OnScreenControls.m`, `Limelight/Input/OnScreenControls.h` (iOS-only, not compiled, reference the removed API).

---

### Task 1: Raise deployment target to macOS 15

**Files:**
- Modify: `Moonlight.xcodeproj/project.pbxproj` (4 occurrences), `moonlight-common/moonlight-common.xcodeproj/project.pbxproj` (4 occurrences)

**Interfaces:**
- Produces: `MACOSX_DEPLOYMENT_TARGET = 15.0` everywhere; nothing else changes yet.

- [ ] **Step 1: Replace the setting**

Run:
```bash
sed -i '' 's/MACOSX_DEPLOYMENT_TARGET = 12.0;/MACOSX_DEPLOYMENT_TARGET = 15.0;/g' Moonlight.xcodeproj/project.pbxproj moonlight-common/moonlight-common.xcodeproj/project.pbxproj
grep -c 'MACOSX_DEPLOYMENT_TARGET = 15.0' Moonlight.xcodeproj/project.pbxproj moonlight-common/moonlight-common.xcodeproj/project.pbxproj
```
Expected: `4` and `4`.

- [ ] **Step 2: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Check Info.plist minimum**

Run: `grep -A1 LSMinimumSystemVersion Limelight/macOS/Info.plist Limelight/Info.plist 2>/dev/null | head -4; grep -rn 'LSMinimumSystemVersion' Moonlight.xcodeproj/project.pbxproj | head -2`
Expected: either no explicit key (Xcode derives it from the deployment target) or a value that is `$(MACOSX_DEPLOYMENT_TARGET)`. If a literal `12.0` appears, change it to `15.0`.

- [ ] **Step 4: Authorization gate, then commit**

```bash
git add Moonlight.xcodeproj/project.pbxproj moonlight-common/moonlight-common.xcodeproj/project.pbxproj Limelight/macOS/Info.plist
git commit -m "build: raise minimum macos to 15"
```

---

### Task 2: Test harness and scroll trace core

**Files:**
- Create: `Package.swift`, `Limelight/Core/include/MLScrollTrace.h`, `Limelight/Core/MLScrollTrace.m`, `Tests/MoonlightCoreTests/MLScrollTraceTests.m`
- Modify: `Moonlight.xcodeproj/project.pbxproj` (`membershipExceptions`: add `Core/MLScrollTrace.m`)

**Interfaces:**
- Produces:
  ```objc
  typedef NS_ENUM(NSInteger, MLScrollTraceSource) { MLScrollTraceSourceNone = 0, MLScrollTraceSourcePhysicalWheel, MLScrollTraceSourceSmoothWheel, MLScrollTraceSourceTrackpad };
  typedef struct {
      uint64_t traceId;          // 0 when no trace is active
      MLScrollTraceSource source;
      uint64_t startedMs;
      uint64_t lastDispatchMs;   // 0 until a dispatch is noted
      int32_t  lastDispatchAmount;
      BOOL     lastDispatchHorizontal;
      BOOL     lastDispatchHighRes;
      BOOL     awaitingRender;
  } MLScrollTraceSnapshot;
  uint64_t MLScrollTraceBegin(MLScrollTraceSource source, uint64_t nowMs);      // returns new traceId
  void     MLScrollTraceNoteDispatch(int32_t amount, BOOL horizontal, BOOL highRes, uint64_t nowMs);
  BOOL     MLScrollTraceIsAwaitingRender(void);
  MLScrollTraceSnapshot MLScrollTraceCompleteRender(uint64_t nowMs);          // clears awaitingRender, returns the snapshot
  MLScrollTraceSnapshot MLScrollTraceCurrent(void);
  void     MLScrollTraceSetEnabled(BOOL enabled);                             // when disabled, Begin returns 0 and nothing is recorded
  BOOL     MLScrollTraceIsEnabled(void);
  void     MLScrollTraceReset(void);                                          // tests and stream teardown
  ```
  All functions are thread-safe (one `os_unfair_lock`). Trace ids are monotonically increasing from 1 per process.

- [ ] **Step 1: Write the manifest**

`Package.swift`:
```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MoonlightCore",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "MoonlightCore",
            path: "Limelight/Core",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "MoonlightCoreTests",
            dependencies: ["MoonlightCore"],
            path: "Tests/MoonlightCoreTests"
        ),
    ]
)
```

- [ ] **Step 2: Write the failing test**

`Tests/MoonlightCoreTests/MLScrollTraceTests.m`:
```objc
#import <XCTest/XCTest.h>
#import "MLScrollTrace.h"

@interface MLScrollTraceTests : XCTestCase
@end

@implementation MLScrollTraceTests

- (void)setUp { MLScrollTraceReset(); MLScrollTraceSetEnabled(YES); }

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

@end
```

- [ ] **Step 3: Run the test to see it fail**

Run: `swift test 2>&1 | tail -5`
Expected: build error, `MLScrollTrace.h` not found.

- [ ] **Step 4: Implement**

`Limelight/Core/include/MLScrollTrace.h`:
```objc
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Where a scroll gesture came from. Mirrors the client's wheel routing.
typedef NS_ENUM(NSInteger, MLScrollTraceSource) {
    MLScrollTraceSourceNone = 0,
    MLScrollTraceSourcePhysicalWheel,
    MLScrollTraceSourceSmoothWheel,
    MLScrollTraceSourceTrackpad,
};

/// Point-in-time copy of the active scroll trace. Safe to read after the call returns.
typedef struct {
    uint64_t traceId;
    MLScrollTraceSource source;
    uint64_t startedMs;
    uint64_t lastDispatchMs;
    int32_t lastDispatchAmount;
    BOOL lastDispatchHorizontal;
    BOOL lastDispatchHighRes;
    BOOL awaitingRender;
} MLScrollTraceSnapshot;

/// Starts a new trace and returns its id, or 0 when tracing is disabled.
uint64_t MLScrollTraceBegin(MLScrollTraceSource source, uint64_t nowMs);
/// Records that a scroll event was handed to the protocol layer for the active trace.
void MLScrollTraceNoteDispatch(int32_t amount, BOOL horizontal, BOOL highRes, uint64_t nowMs);
/// YES when a dispatched scroll has not yet been matched to a rendered frame.
BOOL MLScrollTraceIsAwaitingRender(void);
/// Marks the pending dispatch as rendered and returns the trace state at that moment.
MLScrollTraceSnapshot MLScrollTraceCompleteRender(uint64_t nowMs);
/// Returns the current trace state without changing it.
MLScrollTraceSnapshot MLScrollTraceCurrent(void);
/// Enables or disables recording. Disabling also clears the active trace.
void MLScrollTraceSetEnabled(BOOL enabled);
BOOL MLScrollTraceIsEnabled(void);
/// Clears all state and restarts ids from 1. Used by tests and on stream teardown.
void MLScrollTraceReset(void);

NS_ASSUME_NONNULL_END
```

`Limelight/Core/MLScrollTrace.m`:
```objc
#import "MLScrollTrace.h"
#import <os/lock.h>

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static BOOL gEnabled = NO;
static uint64_t gNextId = 1;
static MLScrollTraceSnapshot gState;

uint64_t MLScrollTraceBegin(MLScrollTraceSource source, uint64_t nowMs) {
    os_unfair_lock_lock(&gLock);
    if (!gEnabled) { os_unfair_lock_unlock(&gLock); return 0; }
    memset(&gState, 0, sizeof(gState));
    gState.traceId = gNextId++;
    gState.source = source;
    gState.startedMs = nowMs;
    uint64_t id = gState.traceId;
    os_unfair_lock_unlock(&gLock);
    return id;
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
    BOOL v = gState.awaitingRender;
    os_unfair_lock_unlock(&gLock);
    return v;
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
    if (!enabled) memset(&gState, 0, sizeof(gState));
    os_unfair_lock_unlock(&gLock);
}

BOOL MLScrollTraceIsEnabled(void) {
    os_unfair_lock_lock(&gLock);
    BOOL v = gEnabled;
    os_unfair_lock_unlock(&gLock);
    return v;
}

void MLScrollTraceReset(void) {
    os_unfair_lock_lock(&gLock);
    memset(&gState, 0, sizeof(gState));
    gNextId = 1;
    gEnabled = NO;
    os_unfair_lock_unlock(&gLock);
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test 2>&1 | grep -E 'Executed|error|passed|failed' | tail -3`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 6: Add the file to the app target**

In `Moonlight.xcodeproj/project.pbxproj`, inside `membershipExceptions = (`, add the line `				Core/MLScrollTrace.m,` between `Crypto/mkcert.c,` and `Database/DataManager.m,`. Run the build command. Expected: `** BUILD SUCCEEDED **` (file compiles; nothing uses it yet).

- [ ] **Step 7: Ignore SwiftPM build output**

Append `.build/` to `.gitignore`.

- [ ] **Step 8: Authorization gate, then commit**

```bash
git add Package.swift Limelight/Core Tests .gitignore Moonlight.xcodeproj/project.pbxproj
git commit -m "test(core): add swiftpm test harness and scroll trace state"
```

---

### Task 3: Move scroll tracing out of the protocol layer

**Files:**
- Modify: `Limelight/Input/HIDSupport.m:449-516, 660-700, 360-380`, `Limelight/Input/HIDSupport+Scroll.m:137-153, 460-478`, `Limelight/Input/HIDSupport_Internal.h:96-101, 155-156`, `Limelight/Stream/VideoDecoderRenderer.m:4786-4815`

**Interfaces:**
- Consumes: `MLScrollTrace*` from Task 2.
- Produces: no `*ScrollTrace*Ctx` symbol referenced anywhere under `Limelight/`. Log lines keep the literal substrings `scroll-trace start` and `scroll-trace render` so `DebugLogParser.swift:1175-1182` keeps working.

- [ ] **Step 1: HIDSupport.m**

1. Delete `syncScrollTraceDiagnosticsPreferenceToInputContext` (449-452) and its three call sites (360, 365, 460). At line 364 where `inputDiagnosticsEnabled` is latched, add `MLScrollTraceSetEnabled(self.inputDiagnosticsEnabled);`.
2. In `prepareScrollTraceFromSource:` (454-516), replace the `LiStartScrollTraceCtx(inputCtx, …)` call at 498 with:
   ```objc
   uint64_t traceId = MLScrollTraceBegin(MLScrollTraceSourceFromHIDSource(source), LiGetMillis());
   if (traceId == 0) { return; }
   self.activeScrollTraceId = traceId;
   ```
   and keep the existing `[inputdiag] scroll-trace start` log at 499-505 unchanged apart from reading `traceId`. Add the static mapper above the method:
   ```objc
   static MLScrollTraceSource MLScrollTraceSourceFromHIDSource(NSInteger source) {
       switch (source) {
           case 1: return MLScrollTraceSourcePhysicalWheel;
           case 2: return MLScrollTraceSourceSmoothWheel;
           case 3: return MLScrollTraceSourceTrackpad;
           default: return MLScrollTraceSourceNone;
       }
   }
   ```
   (Use the file's own source enum values; check the constants at `HIDSupport_Internal.h:96-101` and map each one explicitly.)
3. In the trace-age log block (660-700), replace `LiGetScrollTraceStartMsCtx(inputCtx)` (679) with `MLScrollTraceCurrent().startedMs`.
4. Add `#import "MLScrollTrace.h"` at the top.

- [ ] **Step 2: HIDSupport+Scroll.m**

Replace both `LiNoteScrollTraceLocalDispatchCtx(inputCtx, …)` calls (147-152 and 468-475) with `MLScrollTraceNoteDispatch(amount, horizontal, highRes, LiGetMillis());` using the same amount/axis/high-res values those calls already pass. Add `#import "MLScrollTrace.h"`.

- [ ] **Step 3: VideoDecoderRenderer.m render-completion block (4786-4815)**

Replace the nine `LiGetScrollTrace*Ctx` reads, `LiIsScrollTraceDiagnosticsEnabledCtx`, `LiIsScrollTraceAwaitingRenderCtx` and `LiCompleteScrollTraceRenderCtx` with:
```objc
if (MLScrollTraceIsEnabled() && MLScrollTraceIsAwaitingRender()) {
    uint64_t nowMs = LiGetMillis();
    MLScrollTraceSnapshot t = MLScrollTraceCompleteRender(nowMs);
    Log(LOG_D, @"[inputdiag] scroll-trace render id=%llu source=%ld startAge=%llums dispatchAge=%llums amount=%d horizontal=%d highRes=%d",
        t.traceId, (long)t.source,
        nowMs - t.startedMs, nowMs - t.lastDispatchMs,
        t.lastDispatchAmount, t.lastDispatchHorizontal, t.lastDispatchHighRes);
}
```
Delete the `inputCtx = &depacketizerCtx->connectionContext->inputContext` line at 4787. Add `#import "MLScrollTrace.h"`.

- [ ] **Step 4: Verify no protocol scroll-trace symbols remain**

Run: `grep -rn 'ScrollTrace.*Ctx\|LiStartScrollTrace\|LiSetScrollTraceDiagnostics' Limelight; echo "rc=$?"`
Expected: no output, `rc=1`.

- [ ] **Step 5: Build and stream test**

Run the build command. Expected: `** BUILD SUCCEEDED **`.
Launch the app, enable input diagnostics in Settings, stream, scroll with the trackpad, open the debug log viewer. Expected: entries "Scroll input started" and "Scroll effect displayed" appear.

- [ ] **Step 6: Authorization gate, then commit**

```bash
git add Limelight/Input Limelight/Stream/VideoDecoderRenderer.m
git commit -m "refactor(input): track scroll traces client-side"
```

---

### Task 4: Decouple the input layer from the connection context

**Files:**
- Modify: `Limelight/Input/HIDSupport_Internal.h` (delete 335-374 helpers; add `@property (atomic) BOOL inputReady;` to the class extension), `Limelight/Input/HIDSupport.h` (replace `@property void *inputContext` with `@property (atomic) BOOL inputReady`), `Limelight/Input/HIDSupport.m`, `HIDSupport+Pointer.m`, `HIDSupport+Scroll.m`, `Limelight/Input/ControllerSupport.h` (same property swap), `ControllerSupport.m` (delete `ControllerInputContext` 24-31), `Limelight/macOS/ViewControllers/StreamViewController.m:1342-1445, 498-499, 808, 1579-1580`, `StreamViewController+MouseCapture.m:1682-1688`
- Delete: `Limelight/Input/StreamView.m`, `StreamView.h`, `OnScreenControls.m`, `OnScreenControls.h`

**Interfaces:**
- Produces: `HIDSupport.inputReady` and `ControllerSupport.inputReady` (BOOL). `Connection` no longer exposes `inputStreamContext`. No `LiSend*EventCtx` call anywhere.

- [ ] **Step 1: Mechanical rewrite of send calls**

Run:
```bash
for f in Limelight/Input/HIDSupport.m Limelight/Input/HIDSupport+Pointer.m Limelight/Input/HIDSupport+Scroll.m Limelight/Input/ControllerSupport.m Limelight/Input/HIDSupport_Internal.h; do
  perl -0pi -e 's/\bLiSend(\w+)EventCtx\(\s*inputCtx\s*,\s*/LiSend$1Event(/g' "$f"
done
grep -rn 'EventCtx(' Limelight/Input | head
```
Expected: no output from the final grep (every call rewritten). Where a call was `LiSend…EventCtx(inputCtx)` with no further arguments, the result is `LiSend…Event()`; fix by hand if any.

- [ ] **Step 2: Replace the readiness helpers**

In `HIDSupport_Internal.h`:
- Delete `HIDInputContext` (335-342), `HIDValidateInputContext` (344-361), `HIDDispatchInput` (363-374).
- Add:
  ```objc
  /// YES once the connection reports that the input stream is up. All send paths check it.
  static inline BOOL HIDInputReady(HIDSupport *support) {
      return support.inputReady;
  }
  /// Runs an input block on the HID dispatch queue when the stream is ready.
  static inline void HIDDispatchInput(HIDSupport *support, dispatch_block_t block) {
      if (!support.inputReady) { return; }
      dispatch_async(support.inputQueue, block);
  }
  ```
  (Keep the queue name the deleted version used; read it from the old body before deleting.)
- Every former `PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(...); if (!inputCtx) return;` pair becomes `if (!HIDInputReady(self)) return;`. Every `LiSetThreadConnectionContext(...)` line in the Input directory is deleted.
- In `ControllerSupport.m`, delete `ControllerInputContext` and replace each `inputCtx = ControllerInputContext(self); if (!inputCtx) …` with `if (!self.inputReady) …`.

- [ ] **Step 3: StreamViewController wiring**

- `StreamViewController.m:1342-1351, 1397, 1420-1427, 1442-1445`: replace `[connection inputStreamContext]` handling and the ABI probe (`LiGetInputContextStructSize`, `LiGetInputContextOffsetInitialized`, `LiGetInputContextOffsetConnectionContext`, `LiInputContextIsInitialized`, `LiInputContextGetConnectionCtx`) with `self.hidSupport.inputReady = YES; self.controllerSupport.inputReady = YES;` at the point that runs after `connectionStarted`, and `= NO` at the teardown points (498-499, 808, 1579-1580).
- `StreamViewController+MouseCapture.m:1682-1688`: replace with `BOOL ready = self.hidSupport.inputReady || self.controllerSupport.inputReady;`.
- Delete `LiSetThreadConnectionContext(NULL)` at `StreamViewController.m:943, 1565`.

- [ ] **Step 4: Delete the iOS leftovers**

Run: `git rm -q Limelight/Input/StreamView.m Limelight/Input/StreamView.h Limelight/Input/OnScreenControls.m Limelight/Input/OnScreenControls.h; grep -rn 'StreamView\.h\|OnScreenControls\.h' Limelight | head`
Expected: no remaining imports (if one appears in a macOS file, remove that import line).

- [ ] **Step 5: Verify**

Run: `grep -rn 'inputContext\|LiSetThreadConnectionContext\|PML_INPUT_STREAM_CONTEXT' Limelight/Input Limelight/macOS; echo "rc=$?"`
Expected: no output, `rc=1`. Then the build command: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Stream test**

Stream; move the mouse in both Free and Locked modes, click all three buttons, scroll, type text with Shift and Cmd combinations, press gamepad buttons and sticks, trigger rumble. Expected: every input reaches the host; nothing is dropped after reconnect (disconnect the host app and reconnect once).

- [ ] **Step 7: Authorization gate, then commit**

```bash
git add -A Limelight/Input Limelight/macOS/ViewControllers
git commit -m "refactor(input): send input through the public single-connection api"
```

---

### Task 5: Renderer pull loop on the public API

**Files:**
- Modify: `Limelight/Stream/VideoDecoderRenderer.h:51` (delete `depacketizerContext`), `Limelight/Stream/VideoDecoderRenderer.m:10, 4660-4845`, `Limelight/Stream/Connection.m:2376`

**Interfaces:**
- Produces: `VideoDecoderRenderer.m` no longer includes `Limelight-internal.h`.

- [ ] **Step 1: Rewrite the pull loop**

In the loop at 4660-4845: delete the `depacketizerCtx` acquisition (4666) and `LiSetThreadConnectionContext` (4671). Replace `LiPollNextVideoFrameCtx(depacketizerCtx, &handle, &du)` (4701) with `LiPollNextVideoFrame(&handle, &du)`, `LiCompleteVideoFrameCtx(depacketizerCtx, handle, status)` (4775) with `LiCompleteVideoFrame(handle, status)`, and every `LiGetPendingVideoFramesCtx(depacketizerCtx)` (4715, 4812, 4826, 4839) with `LiGetPendingVideoFrames()`. Change `#include "Limelight-internal.h"` (10) to `#include "Limelight.h"`.

- [ ] **Step 2: Remove the property**

Delete `@property (nonatomic) void *depacketizerContext;` at `VideoDecoderRenderer.h:51` and the assignment at `Connection.m:2376`.

- [ ] **Step 3: Verify and build**

Run: `grep -n 'depacketizerContext\|Limelight-internal' Limelight/Stream/VideoDecoderRenderer.* ; echo "rc=$?"` Expected: `rc=1`. Run the build command: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Stream test**

Stream 2 minutes at the host's native refresh in the Metal renderer and 1 minute in the Native renderer. Open the performance overlay. Expected: frame pacing stats populate, no black frames, no "pending frames" runaway.

- [ ] **Step 5: Authorization gate, then commit**

```bash
git add Limelight/Stream
git commit -m "refactor(video): pull frames through the public api"
```

---

### Task 6: StreamViewController stops including the private header

**Files:**
- Modify: `Limelight/macOS/ViewControllers/StreamViewController_Internal.h:32, 187-221`, `StreamViewController+Diagnostics.m:2541-2542`, `StreamViewController+MenuUI.m:889-912`, `Limelight/Stream/Connection.h:60-61`, `Limelight/Stream/Connection.m`

**Interfaces:**
- Produces on `Connection`:
  ```objc
  /// Returns NO until the control stream has an RTT estimate.
  - (BOOL)getEstimatedRtt:(uint32_t *)rttMs variance:(uint32_t *)varianceMs;
  ```
  `inputStreamContext` and `controlStreamContext` are removed from `Connection.h`.

- [ ] **Step 1: Add the method to Connection**

`Connection.m`, next to `getVideoDiagnosticSnapshot:`:
```objc
- (BOOL)getEstimatedRtt:(uint32_t *)rttMs variance:(uint32_t *)varianceMs {
    uint32_t rtt = 0, variance = 0;
    if (!LiGetEstimatedRttInfo(&rtt, &variance)) { return NO; }
    if (rttMs) *rttMs = rtt;
    if (varianceMs) *varianceMs = variance;
    return YES;
}
```
Declare it in `Connection.h`; delete the two context accessors from `Connection.h` and their implementations.

- [ ] **Step 2: Rewrite the inline helpers**

In `StreamViewController_Internal.h`, change `MLGetUsableRttInfo(PML_CONTROL_STREAM_CONTEXT ctx, …)` to `MLGetUsableRttInfo(Connection *connection, uint32_t *rtt, uint32_t *variance)` calling `[connection getEstimatedRtt:rtt variance:variance]`, keep the "usable" filtering it already does; `MLRttLogSummary` takes `Connection *` likewise. Delete `#include "Limelight-internal.h"` (line 32). Update the three callers (`+Diagnostics.m:2541-2542`, `+MenuUI.m:889-890, 911-912`) to pass `self.connection` instead of `[connection controlStreamContext]`.

- [ ] **Step 3: Verify**

Run: `grep -rln 'Limelight-internal.h' Limelight` Expected: only `Limelight/Stream/Connection.m`. Build: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Stream test**

Open the in-stream menu and the diagnostics panel. Expected: the RTT value shows within 5 seconds and matches the performance overlay.

- [ ] **Step 5: Authorization gate, then commit**

```bash
git add Limelight/Stream Limelight/macOS/ViewControllers
git commit -m "refactor(stream): expose rtt through connection instead of private context"
```

---

### Task 7: Clipboard frame codec (core + tests)

**Files:**
- Create: `Limelight/Core/include/MLClipboardFrame.h`, `Limelight/Core/MLClipboardFrame.m`, `Tests/MoonlightCoreTests/MLClipboardFrameTests.m`
- Modify: `Moonlight.xcodeproj/project.pbxproj` (`membershipExceptions`: add `Core/MLClipboardFrame.m`)

**Interfaces:**
- Produces:
  ```objc
  typedef NS_ENUM(uint8_t, MLClipboardKind) { MLClipboardKindText = 1, MLClipboardKindPNG = 2, MLClipboardKindRef = 3 };
  extern const NSUInteger MLClipboardFrameHeaderLength;   // 10
  extern const NSUInteger MLClipboardFrameMaxPayload;     // 65525
  extern const NSUInteger MLClipboardInlineThreshold;     // 60000
  @interface MLClipboardFrame : NSObject
  @property (nonatomic, readonly) MLClipboardKind kind;
  @property (nonatomic, readonly) uint32_t token;         // 0 = standalone
  @property (nonatomic, readonly) NSData *payload;
  + (nullable instancetype)frameWithKind:(MLClipboardKind)kind token:(uint32_t)token payload:(NSData *)payload; // nil if payload too large or empty
  + (nullable instancetype)frameFromData:(NSData *)data;  // nil on any validation failure
  - (NSData *)encodedData;
  @end
  BOOL MLClipboardDataLooksLikePNG(NSData *data);
  ```
  Wire layout (little-endian): `u8 version=1 | u8 kind | u32 token | u32 length | payload`. Text payload is UTF-8 without NUL; a text frame whose payload contains NUL decodes to nil.

- [ ] **Step 1: Write the failing tests**

`Tests/MoonlightCoreTests/MLClipboardFrameTests.m`:
```objc
#import <XCTest/XCTest.h>
#import "MLClipboardFrame.h"

@interface MLClipboardFrameTests : XCTestCase
@end

@implementation MLClipboardFrameTests

- (void)testTextRoundTripMatchesReferenceBytes {
    NSData *payload = [@"hi" dataUsingEncoding:NSUTF8StringEncoding];
    MLClipboardFrame *f = [MLClipboardFrame frameWithKind:MLClipboardKindText token:0 payload:payload];
    const uint8_t expected[] = {1, 1, 0,0,0,0, 2,0,0,0, 'h','i'};
    XCTAssertEqualObjects(f.encodedData, [NSData dataWithBytes:expected length:sizeof(expected)]);
    MLClipboardFrame *d = [MLClipboardFrame frameFromData:f.encodedData];
    XCTAssertEqual(d.kind, MLClipboardKindText);
    XCTAssertEqual(d.token, 0u);
    XCTAssertEqualObjects(d.payload, payload);
}

- (void)testTokenIsLittleEndian {
    NSData *payload = [@"x" dataUsingEncoding:NSUTF8StringEncoding];
    MLClipboardFrame *f = [MLClipboardFrame frameWithKind:MLClipboardKindPNG token:0x01020304 payload:payload];
    const uint8_t *b = f.encodedData.bytes;
    XCTAssertEqual(b[2], 0x04); XCTAssertEqual(b[3], 0x03); XCTAssertEqual(b[4], 0x02); XCTAssertEqual(b[5], 0x01);
}

- (void)testRejectsShortWrongVersionAndOverlongLength {
    const uint8_t shortFrame[] = {1, 1, 0,0,0,0, 0,0,0};
    XCTAssertNil([MLClipboardFrame frameFromData:[NSData dataWithBytes:shortFrame length:sizeof(shortFrame)]]);
    const uint8_t badVersion[] = {2, 1, 0,0,0,0, 1,0,0,0, 'a'};
    XCTAssertNil([MLClipboardFrame frameFromData:[NSData dataWithBytes:badVersion length:sizeof(badVersion)]]);
    const uint8_t overlong[] = {1, 1, 0,0,0,0, 5,0,0,0, 'a'};
    XCTAssertNil([MLClipboardFrame frameFromData:[NSData dataWithBytes:overlong length:sizeof(overlong)]]);
}

- (void)testUnknownKindDecodesToNil {
    const uint8_t frame[] = {1, 9, 0,0,0,0, 1,0,0,0, 'a'};
    XCTAssertNil([MLClipboardFrame frameFromData:[NSData dataWithBytes:frame length:sizeof(frame)]]);
}

- (void)testTextWithNulIsRejected {
    const uint8_t frame[] = {1, 1, 0,0,0,0, 2,0,0,0, 'a', 0};
    XCTAssertNil([MLClipboardFrame frameFromData:[NSData dataWithBytes:frame length:sizeof(frame)]]);
}

- (void)testPayloadLimits {
    NSMutableData *big = [NSMutableData dataWithLength:MLClipboardFrameMaxPayload];
    XCTAssertNotNil([MLClipboardFrame frameWithKind:MLClipboardKindPNG token:0 payload:big]);
    [big setLength:MLClipboardFrameMaxPayload + 1];
    XCTAssertNil([MLClipboardFrame frameWithKind:MLClipboardKindPNG token:0 payload:big]);
    XCTAssertNil([MLClipboardFrame frameWithKind:MLClipboardKindText token:0 payload:[NSData data]]);
}

- (void)testPNGMagic {
    const uint8_t png[] = {0x89,'P','N','G',0x0D,0x0A,0x1A,0x0A, 0};
    XCTAssertTrue(MLClipboardDataLooksLikePNG([NSData dataWithBytes:png length:sizeof(png)]));
    XCTAssertFalse(MLClipboardDataLooksLikePNG([@"GIF89a" dataUsingEncoding:NSASCIIStringEncoding]));
}

@end
```

- [ ] **Step 2: Run to see failure**

Run: `swift test 2>&1 | tail -3` Expected: compile error, header missing.

- [ ] **Step 3: Implement**

`Limelight/Core/include/MLClipboardFrame.h`:
```objc
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Payload kinds carried by a Foundation Sunshine clipboard frame.
typedef NS_ENUM(uint8_t, MLClipboardKind) {
    MLClipboardKindText = 1,   ///< UTF-8 text without NUL
    MLClipboardKindPNG = 2,    ///< PNG file bytes
    MLClipboardKindRef = 3,    ///< JSON reference to an out-of-band blob
};

extern const NSUInteger MLClipboardFrameHeaderLength;
extern const NSUInteger MLClipboardFrameMaxPayload;
extern const NSUInteger MLClipboardInlineThreshold;

/// One clipboard control-stream frame: 10-byte little-endian header followed by the payload.
/// Layout: u8 version (1), u8 kind, u32 token (0 = standalone), u32 length, payload.
@interface MLClipboardFrame : NSObject

@property (nonatomic, readonly) MLClipboardKind kind;
@property (nonatomic, readonly) uint32_t token;
@property (nonatomic, readonly) NSData *payload;

/// Returns nil when the payload is empty or exceeds MLClipboardFrameMaxPayload.
+ (nullable instancetype)frameWithKind:(MLClipboardKind)kind token:(uint32_t)token payload:(NSData *)payload;
/// Parses a frame received from the host. Returns nil on any validation failure.
+ (nullable instancetype)frameFromData:(NSData *)data;
/// Serializes the frame for LiSendClipboardData.
- (NSData *)encodedData;

@end

/// YES when the data starts with the 8-byte PNG signature.
BOOL MLClipboardDataLooksLikePNG(NSData *data);

NS_ASSUME_NONNULL_END
```

`Limelight/Core/MLClipboardFrame.m`:
```objc
#import "MLClipboardFrame.h"

const NSUInteger MLClipboardFrameHeaderLength = 10;
const NSUInteger MLClipboardFrameMaxPayload = 65535 - 10;
const NSUInteger MLClipboardInlineThreshold = 60000;

static const uint8_t kWireVersion = 1;

@interface MLClipboardFrame ()
@property (nonatomic, readwrite) MLClipboardKind kind;
@property (nonatomic, readwrite) uint32_t token;
@property (nonatomic, readwrite) NSData *payload;
@end

@implementation MLClipboardFrame

+ (instancetype)frameWithKind:(MLClipboardKind)kind token:(uint32_t)token payload:(NSData *)payload {
    if (payload.length == 0 || payload.length > MLClipboardFrameMaxPayload) { return nil; }
    MLClipboardFrame *f = [[self alloc] init];
    f.kind = kind;
    f.token = token;
    f.payload = [payload copy];
    return f;
}

+ (instancetype)frameFromData:(NSData *)data {
    if (data.length < MLClipboardFrameHeaderLength) { return nil; }
    const uint8_t *b = data.bytes;
    if (b[0] != kWireVersion) { return nil; }
    uint8_t kind = b[1];
    if (kind != MLClipboardKindText && kind != MLClipboardKindPNG && kind != MLClipboardKindRef) { return nil; }
    uint32_t token = (uint32_t)b[2] | ((uint32_t)b[3] << 8) | ((uint32_t)b[4] << 16) | ((uint32_t)b[5] << 24);
    uint32_t length = (uint32_t)b[6] | ((uint32_t)b[7] << 8) | ((uint32_t)b[8] << 16) | ((uint32_t)b[9] << 24);
    if (length == 0 || length > data.length - MLClipboardFrameHeaderLength) { return nil; }
    NSData *payload = [data subdataWithRange:NSMakeRange(MLClipboardFrameHeaderLength, length)];
    if (kind == MLClipboardKindText && memchr(payload.bytes, 0, payload.length) != NULL) { return nil; }
    return [self frameWithKind:(MLClipboardKind)kind token:token payload:payload];
}

- (NSData *)encodedData {
    NSMutableData *out = [NSMutableData dataWithCapacity:MLClipboardFrameHeaderLength + self.payload.length];
    uint32_t length = (uint32_t)self.payload.length;
    uint8_t header[10] = {
        kWireVersion, self.kind,
        (uint8_t)(self.token & 0xFF), (uint8_t)((self.token >> 8) & 0xFF), (uint8_t)((self.token >> 16) & 0xFF), (uint8_t)((self.token >> 24) & 0xFF),
        (uint8_t)(length & 0xFF), (uint8_t)((length >> 8) & 0xFF), (uint8_t)((length >> 16) & 0xFF), (uint8_t)((length >> 24) & 0xFF),
    };
    [out appendBytes:header length:sizeof(header)];
    [out appendData:self.payload];
    return out;
}

@end

BOOL MLClipboardDataLooksLikePNG(NSData *data) {
    static const uint8_t magic[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    return data.length >= 8 && memcmp(data.bytes, magic, 8) == 0;
}
```

- [ ] **Step 4: Run tests**

Run: `swift test 2>&1 | grep -E 'Executed|failed' | tail -2` Expected: `Executed 11 tests, with 0 failures` (4 scroll + 7 clipboard).

- [ ] **Step 5: Add to the app target and build**

Add `				Core/MLClipboardFrame.m,` to `membershipExceptions` (alphabetically before `Core/MLScrollTrace.m`). Run the build command: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Authorization gate, then commit**

```bash
git add Limelight/Core Tests Moonlight.xcodeproj/project.pbxproj
git commit -m "feat(core): add clipboard frame codec for the foundation protocol"
```

---

### Task 8: Switch the submodule to `mic` and port Connection

This is the crux. The end state must build and stream; intermediate steps will not build, so do them in one sitting.

**Files:**
- Modify: `.gitmodules`, submodule pointer `moonlight-common/moonlight-common-c`, `moonlight-common/moonlight-common.xcodeproj/project.pbxproj`, `Limelight/Stream/Connection.h`, `Limelight/Stream/Connection.m`, `Limelight/macOS/ViewControllers/StreamViewController.m` (clipboard call sites 203-208, 1354, 1817, 1881, 1901, 2074, 2189), `Limelight/Stream/StreamConfiguration.h` (no change; `disableHighQualitySurround` stays client-side)
- Create: `Limelight/Core/include/MLHdrMode.h`, `Limelight/Core/MLHdrMode.m`, `Tests/MoonlightCoreTests/MLHdrModeTests.m`

**Interfaces:**
- Consumes: `MLClipboardFrame` (Task 7), `getEstimatedRtt:` (Task 6), `inputReady` (Task 4).
- Produces on `Connection`:
  ```objc
  /// Sends one clipboard frame. Returns NO when the host does not support the clipboard channel or the frame is invalid.
  - (BOOL)sendClipboardFrame:(MLClipboardFrame *)frame;
  /// YES after connectionStarted and until termination; the clipboard channel needs no separate binding on this protocol.
  @property (atomic, readonly) BOOL clipboardReady;
  /// Feature bits advertised by the host (LI_FF_*). Valid after connectionStarted.
  - (uint32_t)hostFeatureFlags;
  ```
  and in `ConnectionCallbacks`: `- (void)clipboardFrameReceived:(MLClipboardFrame *)frame;` replacing `clipboardItemReceived:`.
  `MLHdrMode`:
  ```objc
  typedef NS_ENUM(NSInteger, MLHdrMode) { MLHdrModeSDR = 0, MLHdrModePQ = 1, MLHdrModeHLG = 2 };
  /// Maps the user's HDR toggle and transfer-function preference (0 auto, 1 PQ, 2 HLG) to the protocol's hdrMode.
  MLHdrMode MLHdrModeForPreference(BOOL enableHdr, NSInteger hdrTransferFunction);
  ```

- [ ] **Step 1: HDR mode mapping with a test**

Test `Tests/MoonlightCoreTests/MLHdrModeTests.m`:
```objc
#import <XCTest/XCTest.h>
#import "MLHdrMode.h"
@interface MLHdrModeTests : XCTestCase
@end
@implementation MLHdrModeTests
- (void)testMapping {
    XCTAssertEqual(MLHdrModeForPreference(NO, 0), MLHdrModeSDR);
    XCTAssertEqual(MLHdrModeForPreference(NO, 2), MLHdrModeSDR);
    XCTAssertEqual(MLHdrModeForPreference(YES, 0), MLHdrModePQ);
    XCTAssertEqual(MLHdrModeForPreference(YES, 1), MLHdrModePQ);
    XCTAssertEqual(MLHdrModeForPreference(YES, 2), MLHdrModeHLG);
    XCTAssertEqual(MLHdrModeForPreference(YES, 99), MLHdrModePQ);
}
@end
```
Implementation `Limelight/Core/MLHdrMode.m`:
```objc
#import "MLHdrMode.h"
MLHdrMode MLHdrModeForPreference(BOOL enableHdr, NSInteger hdrTransferFunction) {
    if (!enableHdr) { return MLHdrModeSDR; }
    return hdrTransferFunction == 2 ? MLHdrModeHLG : MLHdrModePQ;
}
```
Header with the enum and a doc comment as in the Interfaces block. `swift test` expected `Executed 12 tests, with 0 failures`. Add `Core/MLHdrMode.m` to `membershipExceptions`.

Before relying on this, confirm the old fork used the same numbers: `grep -n 'DYNAMIC_RANGE_MODE_' moonlight-common/moonlight-common-c/src/Limelight.h`. Expected `SDR 0`, `HDR10_PQ 1`, `HLG 2`. If they differ, the mapping above is still what `mic` wants; note the difference in the commit body.

- [ ] **Step 2: Swap the submodule**

```bash
git config -f .gitmodules submodule.moonlight-common/moonlight-common-c.url https://github.com/qiin2333/moonlight-common-c.git
git config -f .gitmodules submodule.moonlight-common/moonlight-common-c.branch mic
git submodule sync -- moonlight-common/moonlight-common-c
cd moonlight-common/moonlight-common-c
git fetch -q origin mic
git checkout -q 31a2a4589e
git submodule update --init --recursive -q
ls nanors/rs.c nanors/deps/obl/oblas_lite.c src/CursorStream.c && git log --oneline -1
cd ../..
git status --short
```
Expected: the four files exist; log shows `31a2a45 feat(control): receive remote text context updates (#28)`; status shows `M .gitmodules` and `M moonlight-common/moonlight-common-c`.

- [ ] **Step 3: Update the static library project**

In `moonlight-common/moonlight-common.xcodeproj/project.pbxproj`:
1. Change the `rs.c` file reference path from `moonlight-common-c/reedsolomon/rs.c` to `moonlight-common-c/nanors/rs.c`.
2. Add six new files. For each, generate a 24-hex id pair (`uuidgen | tr -d - | cut -c1-24`, upper-case) and add three entries following the exact shape of the existing `MicrophoneStream.c` entries:
   - `PBXBuildFile`: `<BF_ID> /* <name> in Sources */ = {isa = PBXBuildFile; fileRef = <FR_ID> /* <name> */; };`
   - `PBXFileReference`: `<FR_ID> /* <name> */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.c.c; name = <name>; path = "<relative path>"; sourceTree = "<group>"; };`
   - the `files = (` list of the `PBXSourcesBuildPhase`: `<BF_ID> /* <name> in Sources */,`
   - the `children = (` list of the group that holds `MicrophoneStream.c`: `<FR_ID> /* <name> */,`
   Files and paths: `CursorStream.c` → `moonlight-common-c/src/CursorStream.c`; `Ds5HapticsStream.c` → `moonlight-common-c/src/Ds5HapticsStream.c`; `Ds5HapticsIrStream.c` → `moonlight-common-c/src/Ds5HapticsIrStream.c`; `RemoteTextContextStream.c` → `moonlight-common-c/src/RemoteTextContextStream.c`; `oblas_common.c` → `moonlight-common-c/nanors/deps/obl/oblas_common.c`; `oblas_lite.c` → `moonlight-common-c/nanors/deps/obl/oblas_lite.c`.
3. In both `HEADER_SEARCH_PATHS` blocks add `"moonlight-common-c/nanors"`, `"moonlight-common-c/nanors/deps"`, `"moonlight-common-c/nanors/deps/obl"`.
4. Validate: `plutil -lint moonlight-common/moonlight-common.xcodeproj/project.pbxproj` → `OK`.

- [ ] **Step 4: Port Connection.m — lifecycle**

1. Delete the `#undef` block (27-42) and change `#include "Limelight-internal.h"` to `#include "Limelight.h"`.
2. Delete the registry (229-349) and `ensureControlContextBacklink` (223-228). Add `static Connection *__weak gActiveConnection;` and `static Connection *CurrentConnection(void) { return gActiveConnection; }`. Keep `ConnectionGetRendererSnapshot` and friends only if they read something other than the map; otherwise make them read `self` fields directly.
3. Delete `ML_CONNECTION_CONTEXT _connectionContext;` (149) and the context bootstrap (2361-2377).
4. `main` (3323-3337): `gActiveConnection = self; int err = LiStartConnection(&_serverInfo, &_streamConfig, &_clCallbacks, &_drCallbacks, &_arCallbacks, (__bridge void*)self, 0, (__bridge void*)self, 0);` and keep the existing error handling.
5. `terminate` (2260-2293): `LiInterruptConnection();` then on the teardown queue `LiStopConnection(); gActiveConnection = nil;`. Drop `gConnectionLifecycleLock` if nothing else uses it.
6. Every `Cl*`/`Ar*`/`Dr*` callback that called `CurrentConnection()` keeps doing so; `DrDecoderSetup` and `ArInit` keep preferring their `context` argument.
7. `getVideoDiagnosticSnapshot:` (2824-2850): rebuild from the public API:
   ```objc
   const RTP_VIDEO_STATS *stats = LiGetRTPVideoStats();
   snapshot.receivedPackets = stats->receivedPackets;   // map each MLVideoDiagnosticSnapshot field to the RTP_VIDEO_STATS field with the same meaning; delete fields with no public source
   snapshot.frameLossPercent = LiGetEstimatedVideoFrameLossPercentage();
   snapshot.bytesReceived = LiGetRTPVideoBytesReceived();
   ```
   Open `RTP_VIDEO_STATS` in `Limelight.h` and `MLVideoDiagnosticSnapshot` in `Connection.h` side by side; keep only fields that exist in both or are derivable. Update the one consumer of removed fields in `StreamViewController+Diagnostics.m` (search `MLVideoDiagnosticSnapshot`).

- [ ] **Step 5: Port Connection.m — stream configuration**

- Replace `_streamConfig.disableHighQualitySurround = config.disableHighQualitySurround;` (2385) with `_disableHighQualitySurround = config.disableHighQualitySurround;` (new `BOOL` ivar) and update the read at 754.
- Replace the `dynamicRangeMode` assignment (2596-2601) with `_streamConfig.hdrMode = (int)MLHdrModeForPreference(config.enableHdr, config.hdrTransferFunction);` and delete `MLResolvedDynamicRangeModeForPreference` (65-81). `#import "MLHdrMode.h"`.
- Remove the `#if defined(LI_MIC_CONTROL_START)` guards around 2388-2412 and keep the body: `_streamConfig.enableMic = micEnabled; if (micEnabled) _streamConfig.encryptionFlags |= ENCFLG_MICROPHONE;`.
- Delete the legacy `enableHdr`/`hevcBitratePercentageMultiplier` block (2414-2422).
- Keep everything else in 2379-2606 as is.

- [ ] **Step 6: Port Connection.m — microphone**

- Add near the top, after the includes:
  ```objc
  // Microphone uplink entry points. They are implemented by moonlight-common-c
  // (MicrophoneStream.c) but not declared in its public header.
  extern int initializeMicrophoneStream(void);
  extern int sendMicrophoneOpusData(const unsigned char* opusData, int opusLength);
  ```
- Delete `sendMicrophoneControlPacket:reason:` (2947-2971) and all `LI_MIC_CONTROL_*` uses. `notifyInputStreamReadyForMicrophoneControlIfNeeded` (2852-2867) becomes: if `_streamConfig.enableMic`, call `startMicrophoneIfNeeded`. It is called from `ClConnectionStarted` (2090-2124) on the connection's own queue, not from `StreamViewController.m:1354` (delete that call).
- In `startMicrophoneEngineLocked` (2973-3203): replace `initializeMicrophoneStreamCtx(...)` (2983) with `if (initializeMicrophoneStream() != 0) { Log(LOG_W, @"microphone stream init failed"); return; }`; delete the address diagnostics (2988-3008).
- In `drainMicPcmAndSend` (3205-3251): delete the thread-context line (3211) and the deferred control start (3213-3215); after encoding into the buffer, pad the length up to a multiple of 16 for the buffer but pass the unpadded `len` to `sendMicrophoneOpusData(payload, len)` (the Qt client does this so the encryption path has slack). Keep the 5-failure disable policy.
- `stopMicrophoneIfNeeded` (3253-3289): delete `destroyMicrophoneStreamCtx` (3287); `LiStopConnection` tears the stream down. Stop the AVAudioEngine and free the encoder as before.
- Remove every remaining `#if defined(LI_MIC_CONTROL_START)` / `#else` / `#endif` and the stub at 3292-3296.

- [ ] **Step 7: Port Connection.m — clipboard**

- Delete `isClipboardControlReady`, `clipboardControlReadinessReason`, `clipboardHostFeatureFlags`, `clipboardControlDebugSummary`, `performClipboardControlOperationNamed:block:`, `bindClipboardSession`, `unbindClipboardSession`, `requestClipboardSnapshot`, `sendClipboardItemData:…` (2649-2822) and `ClClipboardItemReceived` (2235-2252), plus their declarations in `Connection.h`.
- Add:
  ```objc
  - (BOOL)sendClipboardFrame:(MLClipboardFrame *)frame {
      if (!self.clipboardReady || frame == nil) { return NO; }
      NSData *bytes = frame.encodedData;
      int rc = LiSendClipboardData(bytes.bytes, (int)bytes.length);
      if (rc != 0) { Log(LOG_D, @"LiSendClipboardData(%lu bytes) -> %d", (unsigned long)bytes.length, rc); }
      return rc == 0;
  }
  - (uint32_t)hostFeatureFlags { return LiGetHostFeatureFlags(); }
  static void ClClipboardData(const char* data, int length) {
      Connection *conn = CurrentConnection();
      if (conn == nil || data == NULL || length <= 0) { return; }
      MLClipboardFrame *frame = [MLClipboardFrame frameFromData:[NSData dataWithBytes:data length:(NSUInteger)length]];
      if (frame == nil) { Log(LOG_W, @"dropping malformed clipboard frame (%d bytes)", length); return; }
      id<ConnectionCallbacks> callbacks = conn->_callbacks;
      dispatch_async(dispatch_get_main_queue(), ^{
          if ([callbacks respondsToSelector:@selector(clipboardFrameReceived:)]) { [callbacks clipboardFrameReceived:frame]; }
      });
  }
  ```
  Register `_clCallbacks.clipboardData = ClClipboardData;` next to the other listener assignments (2627-2636). Set `_clipboardReady = YES` in `ClConnectionStarted` and `NO` in `ClConnectionTerminated` and `terminate`.
- `Connection.h`: `#import "MLClipboardFrame.h"`, declare the new method/property, replace the optional callback with `- (void)clipboardFrameReceived:(MLClipboardFrame *)frame;`.

- [ ] **Step 8: StreamViewController clipboard policy on the new transport**

The policy code (`StreamViewController.m:1721-2187`) keeps its focus-ownership, per-host enable and 500 ms poll. Rewire only the transport edges:
- Send sites (1817, 1881, 1901, 2074): where the old code built `LI_CLIPBOARD_ITEM`s, build frames instead. Text: `[MLClipboardFrame frameWithKind:MLClipboardKindText token:0 payload:[text dataUsingEncoding:NSUTF8StringEncoding]]`. Image: take `NSPasteboardTypePNG` data if present, else `[[[NSBitmapImageRep alloc] initWithData:[pasteboard dataForType:NSPasteboardTypeTIFF]] representationUsingType:NSBitmapImageFileTypePNG properties:@{}]`. If text and image are both present, send text then image with the same non-zero token (`arc4random()` until non-zero). Skip a payload of size zero or larger than `MLClipboardFrameMaxPayload` (log at debug level; out-of-band blobs are not implemented in this phase). Call `[self.connection sendClipboardFrame:frame]`.
- Receive (2189 handler and the 203-208 shim): implement `clipboardFrameReceived:`; for `MLClipboardKindText` write `NSPasteboardTypeString`; for `MLClipboardKindPNG` write `NSPasteboardTypePNG` and a TIFF rendition via `[[NSImage alloc] initWithData:]`; ignore `MLClipboardKindRef` with a debug log. Keep the echo suppression the old handler had (it tracks the last written change count); if none exists, add: remember the pasteboard `changeCount` after each write and skip the next local-change poll that reports that count.
- Delete calls to `bindClipboardSession`, `unbindClipboardSession`, `requestClipboardSnapshot`, `isClipboardControlReady`, `clipboardControlReadinessReason`, `clipboardHostFeatureFlags`, `clipboardControlDebugSummary`; where the UI showed the readiness reason, show "Clipboard sync ready" when `connection.clipboardReady` and "Waiting for connection" otherwise.
- Delete the `notifyInputStreamReadyForMicrophoneControlIfNeeded` call at 1354.

- [ ] **Step 9: Build until clean**

Run the build command repeatedly, fixing only errors that come from the port (missing symbols, changed signatures). Do not silence warnings with pragmas. Expected end state: `** BUILD SUCCEEDED **` and
```bash
grep -rn 'Limelight-internal\|Ctx(' Limelight | grep -v 'CGContext\|NSGraphicsContext\|EAGLContext\|MTLRenderCommandEncoder\|dispatch_get_specific'
```
prints nothing.

- [ ] **Step 10: Stream test (the phase's acceptance)**

Against the Foundation Sunshine host:
1. Connect; stream starts; overlay shows RTT and frame stats.
2. Both mouse modes, keyboard with modifiers, gamepad.
3. Clipboard: copy text on Mac → paste on host; copy text on host → paste on Mac; copy a screenshot on Mac → paste in Paint on host; copy an image on host → paste in Preview on Mac.
4. Microphone: enable per host, speak, confirm on the host (Sound settings input meter or a voice app).
5. HDR on and off, if the host and display support it; else confirm SDR unchanged.
6. 7.1.4 and stereo audio paths.
7. Disconnect and reconnect twice.
Record each result in the phase gate message.

- [ ] **Step 11: Authorization gate, then commit (two commits)**

```bash
git add .gitmodules moonlight-common
git commit -m "build(common-c): track qiin2333 moonlight-common-c branch mic"
git add Limelight Tests Moonlight.xcodeproj/project.pbxproj
git commit -m "feat(stream): port connection to the foundation protocol public api"
```

---

### Task 9: Split Connection.m into categories

**Files:**
- Create: `Limelight/Stream/Connection_Internal.h`, `Limelight/Stream/Connection+Audio.m`, `Connection+Surround.m`, `Connection+Microphone.m`, `Connection+Clipboard.m`
- Modify: `Limelight/Stream/Connection.m`, `Moonlight.xcodeproj/project.pbxproj` (`membershipExceptions`: add the four `.m` files under `Stream/`)

**Interfaces:**
- Produces: `Connection_Internal.h` declares the class extension with every ivar the categories touch (audio state, mic state, clipboard state, `_streamConfig`, `_disableHighQualitySurround`) and the private methods each category implements. Public `Connection.h` is unchanged.

- [ ] **Step 1: Create the internal header**

Move the `@interface Connection ()` block and the ivar declarations from `Connection.m` into `Connection_Internal.h`; `Connection.m` imports it. Build. Expected: `** BUILD SUCCEEDED **` with no behavior change.

- [ ] **Step 2: Move code, one category at a time, building after each**

| Category | Moves from `Connection.m` (post-Task-8 line numbers will differ; identify by symbol) |
|---|---|
| `Connection+Audio.m` | `ArInit`, `ArCleanup`, `ArDecodeAndPlaySample`, `FillOutputBuffer`, `RenderDirectAudioUnit`, `initializeDirectAudioRendererWithOpusConfig:channelLayout:`, `initializeEnhancedAudioRendererWithOpusConfig:`, `configureEnhancedAudioUnits`, `prepareEnhancedDownmixConverterWithOpusConfig:`, `renderEnhancedStereoPCMFrames:toFloatBufferList:`, `cleanupSelectedAudioRenderer`, `MLAudioRingBufferDurationForMode`, the PCM copy/downmix helpers |
| `Connection+Surround.m` | `MLIs714HighQualityOpusConfig`, `MLIs714CompatibilityOpusConfig`, `MLPrepareOpusDecoderConfig`, layout tag helpers, `recreateAudioDecoderWithConfig:reason:`, `attempt714DecoderTopologyFallbackAfterDecodeError:`, `attempt714PrimaryDecoderReprobeWithSampleData:sampleLength:` |
| `Connection+Microphone.m` | the two `extern` mic prototypes, `notifyInputStreamReadyForMicrophoneControlIfNeeded`, `startMicrophoneIfNeeded`, `audioDeviceIDForUID:`, `startMicrophoneEngineLocked`, `drainMicPcmAndSend`, `stopMicrophoneIfNeeded` |
| `Connection+Clipboard.m` | `sendClipboardFrame:`, `ClClipboardData` (declare it in `Connection_Internal.h` so `Connection.m` can register it) |

Static C functions that a category needs become either category-file statics (if used only there) or declared in `Connection_Internal.h` (if shared). No logic changes.

- [ ] **Step 3: Verify sizes and build**

Run: `wc -l Limelight/Stream/Connection*.m` Expected: `Connection.m` under 1200 lines; no category over 1600. Build: `** BUILD SUCCEEDED **`. Stream 1 minute with audio in stereo and in 7.1.4, and use the microphone once.

- [ ] **Step 4: Authorization gate, then commit**

```bash
git add Limelight/Stream Moonlight.xcodeproj/project.pbxproj
git commit -m "refactor(stream): split connection into audio, surround, microphone and clipboard"
```

---

### Task 10: Host cursor shape in Free Mouse mode

**Files:**
- Create: `Limelight/Stream/Connection+Cursor.m`
- Modify: `Limelight/Stream/Connection.h` (callback `- (void)hostCursorUpdated:(nullable NSCursor *)cursor visible:(BOOL)visible;`), `Connection_Internal.h`, `Connection.m` (register `_clCallbacks.cursorUpdate`), `StreamViewController+MouseCapture.m`, `Moonlight.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces on `Connection`: `- (void)setLocalCursorRendering:(BOOL)enabled;` which calls `LiSetCursorMode(enabled ? LI_CURSOR_MODE_LOCAL : LI_CURSOR_MODE_VIDEO)` when `hostFeatureFlags & LI_FF_CURSOR_SHAPE`, and logs and returns otherwise.

- [ ] **Step 1: Callback and NSCursor construction** (`Connection+Cursor.m`)

```objc
static void ClCursorUpdate(const LI_CURSOR_UPDATE* update) {
    Connection *conn = CurrentConnection();
    if (conn == nil || update == NULL) { return; }
    BOOL visible = (update->flags & LI_CURSOR_UPDATE_FLAG_VISIBLE) != 0;
    NSCursor *cursor = nil;
    if ((update->flags & LI_CURSOR_UPDATE_FLAG_SHAPE) && update->pixels && update->width > 0 && update->height > 0 &&
        update->pixelDataLength == (uint32_t)update->width * update->height * 4) {
        NSData *bgra = [NSData dataWithBytes:update->pixels length:update->pixelDataLength];
        cursor = MLCursorFromBGRA(bgra, update->width, update->height, update->hotspotX, update->hotspotY);
    }
    id<ConnectionCallbacks> callbacks = conn->_callbacks;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([callbacks respondsToSelector:@selector(hostCursorUpdated:visible:)]) { [callbacks hostCursorUpdated:cursor visible:visible]; }
    });
}

static NSCursor *MLCursorFromBGRA(NSData *bgra, uint16_t width, uint16_t height, int16_t hotspotX, int16_t hotspotY) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)bgra);
    CGImageRef image = CGImageCreate(width, height, 8, 32, width * 4, cs,
                                     kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
    if (image == NULL) { return nil; }
    NSImage *nsImage = [[NSImage alloc] initWithCGImage:image size:NSMakeSize(width, height)];
    CGImageRelease(image);
    return [[NSCursor alloc] initWithImage:nsImage hotSpot:NSMakePoint(hotspotX, hotspotY)];
}
```
The host sends pixels in the host's scale; on a Retina display the cursor appears half-size. Acceptable for this task; a later task can scale by `backingScaleFactor`.

- [ ] **Step 2: Mode switch**

In `StreamViewController+MouseCapture.m`, where the mouse mode changes between Free and Locked (search the existing mode setter), call `[self.connection setLocalCursorRendering:isFreeMouse]` after the connection has started, and again from the `connectionStarted` handler. Implement `hostCursorUpdated:visible:`: in Free Mouse mode, `[cursor set]` when a cursor arrives and `visible`, `[NSCursor hide]` / `[NSCursor unhide]` on visibility changes; in Locked mode ignore updates. Keep a balanced hide/unhide count (hide only when not already hidden).

- [ ] **Step 3: Build and test**

Build: `** BUILD SUCCEEDED **`. Stream in Free Mouse mode; hover over a text field, a link, and a window edge on the host. Expected: the Mac cursor changes to I-beam, hand, and resize shapes; in Locked mode the host's cursor is still drawn in the video.

- [ ] **Step 4: Authorization gate, then commit**

```bash
git add Limelight/Stream Limelight/macOS/ViewControllers Moonlight.xcodeproj/project.pbxproj
git commit -m "feat(input): render host cursor shapes locally in free mouse mode"
```

---

### Task 11: Remove pre-15 compatibility paths

**Files:**
- Modify: every file with `@available(macOS 1[0-4]` (39 sites: `VideoDecoderRenderer.m` 26, `ContainerViewController.m` 4, `StreamViewController+MenuUI.m` 3, `StreamViewController+Diagnostics.m` 3, `Connection.m` 1, `HttpManager.m` 1, `AppDelegateForAppKit.m` 1), `Limelight/Input/HIDSupport+Pointer.m` and `CoreHIDMouseDriver.swift` (the "CoreHID unsupported" branch)

- [ ] **Step 1: Availability checks**

For each `if (@available(macOS X, *)) { A } else { B }` with X ≤ 15: keep `A`, delete `B` and the condition. For Swift `if #available(macOS X, *)` likewise. For `@available(macOS X, *)` attributes on declarations with X ≤ 15: delete the attribute. Run: `grep -rn '@available(macOS 1[0-4]\|#available(macOS 1[0-4]' Limelight; echo rc=$?` Expected `rc=1`.

- [ ] **Step 2: CoreHID mandatory**

In `CoreHIDMouseDriver.swift` delete the `unsupported` state and its message key; in `HIDSupport+Pointer.m` delete the fallback pointer path that ran when CoreHID was unavailable (search the message keys the driver used for "unsupported"). Keep the `denied` and `error` states.

- [ ] **Step 3: Build and test**

Build: `** BUILD SUCCEEDED **`. Stream; mouse in both modes; Metal and Native renderers; HDR toggle. Expected: no behavior change on macOS 15+.

- [ ] **Step 4: Authorization gate, then commit**

```bash
git add Limelight
git commit -m "refactor: drop pre-macos-15 compatibility paths"
```

---

### Task 12: CI runs the unit tests; docs

**Files:**
- Modify: `.github/workflows/build.yml` (new job), `docs/design/2026-09-09-foundation-native-client-design.md` (status of phase 2, note that SDR white, dynamic HDR caps, haptics and touchpad moved to phase 4)

- [ ] **Step 1: Add the test job**

In `build.yml` add before `build_arm64`:
```yaml
  unit_tests:
    name: Unit tests
    runs-on: macos-26
    steps:
    - uses: actions/checkout@v6
    - uses: maxim-lobanov/setup-xcode@v1
      with:
        xcode-version: latest
    - name: Run core tests
      run: swift test 2>&1 | tail -20
```
and add `unit_tests` to the `build` aggregator's `needs` and its check. Run `actionlint .github/workflows/build.yml` → clean.

- [ ] **Step 2: Design doc**

Under section 5 phase 2, append "Delivered 2026-MM-DD" with the checklist results from Task 8 Step 10. Under section 8 add: dynamic SDR white (macOS has no direct SDR-white-nits query; needs research), dynamic HDR caps (renderer has no HDR10+/Dolby Vision path), DualSense haptics IR v2, native touchpad events.

- [ ] **Step 3: Authorization gate, then commit**

```bash
git add .github/workflows/build.yml docs/design
git commit -m "ci: run core unit tests; docs: record phase 2 delivery"
```

---

### Task 13: Phase gate

- [ ] **Step 1: Full manual checklist** (Task 8 Step 10 plus Task 10 cursor check and Task 11 renderer check) on the final branch tip, recorded pass/fail.
- [ ] **Step 2: Authorization gate for push**, then `git push origin phase2/protocol-port`, `gh workflow run build.yml --ref phase2/protocol-port`, watch to green, download the DMG, mount, confirm it launches.
- [ ] **Step 3: Report** and ask whether `master` should now fast-forward to phase 2 (phase 1 is included).

## Self-review

- **Spec coverage.** 4.1 layers and 4.2 bridge: Tasks 4, 5, 6, 8 (the `Connection` class is the bridge; no separate `MLProtocolBridge` file is created because after removing the `*Ctx` layer nothing was left for it to wrap; the design's intent — one file includes the protocol header for calls — holds: only `Connection*.m` do). 4.3 clipboard: Tasks 7, 8; microphone: 8; 7.1.4: kept in 8/9; HDR: 8 (`hdrMode`), the rest to phase 4 per Task 12; cursor: 10; remote text context, haptics, touchpad: explicitly deferred in Task 12. 4.4 split: Task 9 (categories instead of separate classes; state stays in one object). 4.6 tests: Tasks 2, 7, 8, 12. macOS 15: Tasks 1, 11. Phase 2 acceptance criteria: Task 8 Step 10 and Task 13.
- **Placeholders.** None. Line numbers are from the 2026-09-09 audit and will shift after Task 8; each step also names the symbol to find.
- **Consistency.** `inputReady` (Task 4) is what Task 8 relies on for input; `getEstimatedRtt:variance:` (Task 6) is used by Task 8's snapshot; `MLClipboardFrame` API in Task 7 matches Task 8's calls; `hostFeatureFlags` (Task 8) is used by Task 10; `CurrentConnection()` after Task 8 is the static pointer that Tasks 9 and 10 use.
