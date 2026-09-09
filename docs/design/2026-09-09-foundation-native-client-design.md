# Native macOS client for Foundation Sunshine — design

Date: 2026-09-09
Status: draft, awaiting review
Repository: github.com/opsthomaz/moonlight-macos-enhanced (fork of skyhua0224/moonlight-macos-enhanced)

## 1. Goal

Turn the abandoned native macOS Moonlight client into a maintained client for
Foundation Sunshine that:

- tracks the Foundation Sunshine protocol line (qiin2333/moonlight-common-c,
  branch `mic`) without carrying a private fork of the protocol library;
- keeps everything that makes the client native (AppKit, Metal, VideoToolbox,
  Core Audio, CoreHID, GameController) and improves it;
- fixes the open issues inherited from upstream;
- reaches a baseline of engineering hygiene the upstream never had:
  documented public APIs, lint, a test target, one source of truth for
  localization, docs.

### Non-goals

- Multi-connection streaming. The current code carries a per-connection
  context layer for it, but the app never opens more than one connection.
- Windows/Linux. The Qt client already covers them.
- Feature parity with the Qt client where the feature is not native to macOS
  (for example the Win11-style floating menu).

## 2. Current state (verified 2026-09-09)

**Build.** Xcode 26.6 and Xcode 27.0 beta both build the app unsigned in
Release/arm64 with the same 7 warnings and no errors. Prebuilt
`SDL2`, `FFmpeg` and `Opus` xcframeworks are downloaded from
`coofdy/moonlight-mobile-deps` at build time; they are not in the repo.
Deployment target is macOS 12.0. The bundle id is `std.skyhua.MoonlightMac`
and the product name is `Moonlight`, so installing it overwrites Moonlight V+
for PC (upstream issue 41).

**Protocol coupling.** The client does not use the public protocol API. It
includes the library's private header `Limelight-internal.h` from 7 files,
embeds the internal `ML_CONNECTION_CONTEXT` struct inside `Connection.m`, and
calls 58 `*Ctx` functions that exist only in skyhua0224's fork of
moonlight-common-c. That fork branched from qiin2333's `mic` line in March
2026 and has not synced since: 37 private commits, 59 commits behind.

**Protocol divergence that breaks features today.**

| Feature | skyhua0224 fork | qiin2333 `mic` (what the server speaks) |
|---|---|---|
| Clipboard | `LiBindClipboardSession`, `LiSendClipboardItem`, `LiRequestClipboardSnapshot` | `LiSendClipboardData(payload, len)` + `clipboardData` callback, opaque frame |
| Microphone | `LiSendMicrophoneControlCtx`, `initializeMicrophoneStreamCtx` | `initializeMicrophoneStream`, `sendMicrophoneOpusData`, `isMicrophoneEncryptionEnabled` |
| Dynamic HDR | own `hdr dynamic-range negotiation` | `LiGetNegotiatedDynamicHdrFormat/Fallback`, `DynamicHdr.h`, Dolby Vision 8.4 |
| SDR white level | none | `LiSendClientSdrWhiteNits` |
| Cursor shape sync | none | `LiSetCursorMode` + `cursorUpdate` callback |
| Remote text context (IME) | none | `LiSetRemoteTextContextCallback` |
| DualSense haptics | none | `HapticsPcm` callback |
| Native touchpad, dual touchpads | none | `LiSendTouchpadEvent`, `LiSendControllerTouchEvent2` |
| Audio passthrough | none | AC3 / E-AC3 / LPCM negotiation |
| Stats | none | frame loss rate, received video bytes, `LiGetStreamSockets` for QoS |
| Scroll trace diagnostics | 17 `LiGetScrollTrace*Ctx` functions | none |

The clipboard mismatch is the probable cause of upstream issue 32
("clipboard does not sync"), opened after the server adopted the `mic` frame
format.

**Code shape.** 63k lines outside the submodule (40.5k Objective-C, 18.2k
Swift). `Connection.m` (3.3k lines) holds protocol glue, three Core Audio
backends, the microphone uplink, 7.1.4 negotiation and HDR negotiation.
`VideoDecoderRenderer.m` (5.3k) holds VideoToolbox, Metal, MetalFX and an
inline shader string. `StreamViewController` plus categories is 11.4k lines.
Documented public methods: effectively zero. Tests: none. Lint: none.
Localization: `en` and `zh-Hans` `.strings` files that are overridden by two
hardcoded dictionaries in `LanguageManager.swift`.

**Inherited work available.**

- BOOGAY/moonlight-macos-enhanced: 8 commits (SDR fast path, macOS 12 crash,
  macOS 13 pacing, text labels for modifier keys). Cherry-pick.
- Upstream PRs 44 (English UI coverage), 45 (gamepad Menu long-press toggle),
  46 (Metal stretch fix), 47 (Metal HDR/EDR mapping). Small, independent.
- Upstream PR 38: 67-file overhaul including a Parsec-style keyboard remap.
  Evaluate piece by piece in phase 3; never merge whole.
- 20 open upstream issues.

## 3. Decisions

| Topic | Decision |
|---|---|
| Protocol library | Submodule points at `qiin2333/moonlight-common-c`, branch `mic`, unmodified. No private fork. |
| Coupling | A client-side protocol bridge, single connection, public API only. The `*Ctx` layer and the embedded internal struct are removed. |
| App identity | New bundle id and new product name. Name to be chosen by the owner. |
| Language | English for code, comments, commits, and primary docs. README also in Simplified Chinese and Brazilian Portuguese. |
| Toolchain | Xcode 27.0 for local builds; CI on `macos-26` runners with the newest Xcode they offer. Deployment target stays 12.0 until a feature needs otherwise. |
| Architectures | Apple Silicon (arm64) only. The Intel and universal builds were dropped on 2026-09-09 after the `macos-26-intel` runner hung in `ibtool` during the phase 1 CI run; Moonlight V+ for PC also ships arm64 only on macOS. |
| Commits | Only with explicit approval from the owner, one logical change per commit, conventional-commit subjects enforced by `.githooks/commit-msg`. No AI attribution anywhere. |
| Upstream | Anything protocol-level that the client needs and `mic` lacks goes to qiin2333 as a PR, not into a fork. |

## 4. Architecture

### 4.1 Layers

```
AppKit UI (StreamViewController + categories, Settings*)
        │
Native services: VideoDecoderRenderer (VT + Metal), AudioOutput (Core Audio),
                 MicrophoneUplink (AVAudioEngine + Opus), ClipboardSync
                 (NSPasteboard), CursorSync, InputPipeline (CoreHID, HID, GC)
        │
MLProtocolBridge   ← the only file that includes Limelight.h for calls
        │
moonlight-common-c (qiin2333, branch mic)   ← submodule, untouched
```

### 4.2 MLProtocolBridge

One Objective-C class in `Limelight/Protocol/`. Responsibilities:

- Own the `SERVER_INFORMATION`, `STREAM_CONFIGURATION` and the three callback
  structs. Today these are filled in one block of `Connection.m`; that block
  moves here unchanged in behavior.
- Expose a single-connection API that mirrors what the client actually uses:
  start, stop, interrupt, request IDR, send input events, send clipboard,
  microphone start/stop/send, cursor mode, SDR white nits, stats getters.
- Translate C callbacks into Objective-C delegate calls on a known queue.
  Callback dispatch replaces the current `LiSetThreadConnectionContext`
  plumbing.
- Declare the three microphone symbols with local `extern` prototypes, as the
  Qt client does in `micstream.cpp`, instead of including the internal header.

Every current `*Ctx` call site (16 files) becomes a call on the bridge with
the `Ctx` suffix and the context argument dropped. The 17 scroll-trace
diagnostics functions are removed from the protocol layer; the client-side
timing they fed stays in `HIDSupport+Scroll.m` and `+Diagnostics.m` using
local timestamps only.

### 4.3 Feature ports onto the `mic` API

- **Clipboard.** Keep the NSPasteboard policy in `StreamViewController`
  (focus-based ownership, per-host enable, polling tick). Replace the transport
  with `LiSendClipboardData` and the `clipboardData` callback. The frame
  encoding must match what Foundation Sunshine and the Qt client use; port it
  from `app/streaming/clipboardsync.h` in qiin2333/moonlight-qt. Text and PNG
  images, as today.
- **Microphone.** Keep `MicrophoneManager.swift` and the AVAudioEngine + Opus
  capture in a new `MicrophoneUplink` file. Replace the control message with
  the three `mic` symbols. Encryption follows `isMicrophoneEncryptionEnabled`.
- **7.1.4 and passthrough.** Keep the classification and fallback logic; add
  AC3 / E-AC3 / LPCM passthrough negotiation as an option only when the output
  device reports support.
- **HDR.** Replace the fork's negotiation with `LiGetNegotiatedDynamicHdr*`;
  add `LiSendClientSdrWhiteNits` fed from the display's current SDR reference
  white (`NSScreen.maximumReferenceExtendedDynamicRangeColorComponentValue`
  and friends). Metal renderer consumes the negotiated format.
- **New native features enabled by `mic`.** Cursor shape sync (render the
  host cursor as an `NSCursor` in Free Mouse mode), remote text context
  (nothing to do on macOS beyond exposing it; no on-screen keyboard), DualSense
  haptics through GameController `GCDeviceHaptics`, native trackpad events
  from `NSTouch`.

### 4.4 Splitting Connection.m

The port is the moment to split the 3.3k-line file along the boundaries it
already has internally. Target files, each with one job:

- `MLProtocolBridge.m` — see 4.2.
- `AudioOutput.m` — the three Core Audio backends behind one protocol; the
  enhanced (EQ / spatial) graph stays.
- `SurroundNegotiation.m` — 7.1.4 classification and fallback.
- `MicrophoneUplink.m` — capture and send.
- `ClipboardTransport.m` — frame encode/decode and send/receive.
- `HdrNegotiation.m` — format selection and SDR white reporting.

`VideoDecoderRenderer.m` is not split in this project except for moving the
inline shader source into a `.metal` file so it compiles at build time.

### 4.5 App identity

- New bundle id `com.opsthomaz.<name>` and matching helper id for the AWDL
  privileged helper (the helper's id is derived from the app id by the build
  script; verify the derivation still holds).
- New product name; DMG names and release-note tooling follow.
- On first launch, offer a one-time import of settings and host pairings from
  the old container (`std.skyhua.MoonlightMac`), so existing users keep their
  pairings. Import is optional and non-destructive.

### 4.6 Quality tooling

- Doc comments: `///` in Swift, `/** */` HeaderDoc in Objective-C headers, on
  every public class, method and property. Enforced by SwiftLint's
  `missing_docs` rule for Swift; reviewed by hand for Objective-C.
- `.swiftlint.yml` and `.clang-format` checked in; both run in CI as a
  separate job that fails the build.
- A `MoonlightTests` XCTest target covering pure logic first: key code
  translation table, clipboard frame encode/decode round trip, 7.1.4 config
  classification, HDR mode resolution, settings import.
- `// MARK:` sections in every file over 300 lines.

### 4.7 Localization

`.strings` files become the single source of truth. The two dictionaries in
`LanguageManager.swift` are deleted after their keys are merged into the
`.strings` files. Add `pt-BR.lproj`. A CI script fails if the three languages
have different key sets.

### 4.8 Docs

- `README.md` in English, `README.zh-Hans.md`, `README.pt-BR.md`.
- `CHANGELOG.md` generated from the existing `.github/release-notes/` files.
- `docs/` with this design, a build guide, a contributor guide, and the
  protocol bridge reference. `SettingsAnalysis.md` leaves the source tree and
  is either updated or deleted.
- `crash_log` is removed from the repo. `xcframeworks/` is gitignored.

## 5. Phases and acceptance criteria

Each phase ends with a build, the tests that exist at that point, a manual
stream against the owner's Foundation Sunshine host, and an approval before
anything is committed.

1. **Housekeeping.** Cherry-pick BOOGAY's 8 commits; merge PRs 44–47; remove
   `crash_log`; gitignore `xcframeworks/`; CI green on the fork.
   Done when: the fork builds in CI for arm64 and produces the arm64 DMG.
2. **Protocol port.** Submodule to `mic`; bridge; Connection.m split;
   clipboard, microphone, HDR on the new API. Done when: a stream starts,
   input works in both mouse modes, clipboard text and image sync both ways,
   microphone reaches the host, HDR negotiates, and the client builds with
   zero references to `Limelight-internal.h`.
   Delivered 2026-09-09 on branch `phase2/protocol-port`. Verified against the
   owner's Foundation Sunshine host: stream, both mouse modes, keyboard, trackpad
   scroll, clipboard text in both directions, reconnect. Not yet verified:
   clipboard images, 7.1.4 audio, microphone, HDR, gamepad. Deviations from
   this design: the bridge is the `Connection` class itself plus categories
   (`Connection+Audio/Surround/Microphone/Clipboard/Cursor.m`) rather than a
   separate `MLProtocolBridge` file, because nothing was left to wrap once the
   `*Ctx` layer was gone; the iOS leftovers under `Limelight/Input` stay until
   phase 4 because their headers still declare types the macOS code uses.
   Known follow-up: a clipboard change is occasionally sent twice because macOS
   bumps the pasteboard change count more than once; adopt the reference
   client's 16-entry echo cache.
3. **Issues.** Triage the 20 upstream issues into fixed / reproduced /
   cannot reproduce / won't do, then fix in order of user impact: locked-mouse
   stuck (24), Cmd+Tab focus steal (40), sticky modifiers (37), hover
   activation (21), arrow keys in DNF (39), LAN discovery (35), gamepad mapping
   (25), Command as Windows key (23), 10-bit SDR (22). Pull individual pieces
   of PR 38 where they resolve one of these. Done when: each issue has a
   reproduction note and a resolution in the tracker.
4. **Native and quality.** New `mic`-enabled features from 4.3; doc comments;
   lint; tests; MARKs; localization unification; `.metal` file. Done when:
   lint passes, `missing_docs` passes, tests pass in CI.
5. **Docs and identity.** New name and bundle id with settings import;
   README ×3; CHANGELOG; docs folder. Done when: a fresh install next to
   Moonlight V+ for PC runs both, and a user of the old app can import
   pairings.

Phase 5's identity change can be pulled forward to phase 1 if the owner
picks a name early; it is independent of the protocol work.

## 6. Testing strategy

- **Unit** (XCTest, CI): pure logic listed in 4.6.
- **Build** (CI): arm64, Release, unsigned, newest Xcode on the runner.
- **Manual protocol checks** (owner's host, per phase): connect, both mouse
  modes, keyboard with modifiers, gamepad, clipboard text and image in both
  directions, microphone, HDR on and off, 7.1.4 and stereo, reconnect after
  sleep, AWDL path.
- **Regression against the Qt client**: when a `mic` feature misbehaves, the
  same host is checked with Moonlight V+ for PC to separate client bugs from
  server bugs.

## 7. Risks

- **Clipboard frame format** is defined by the Qt helper, not by the C
  library. If it changes upstream the bridge must follow. Mitigation: a
  round-trip unit test pinned to captured frames.
- **Microphone symbols are not part of the public header** even on `mic`.
  Mitigation: local `extern` prototypes plus a CI check that the symbols still
  exist in the built static library; propose a public header upstream.
- **Xcode 27 beta** may change Metal or CoreHID behavior before release.
  Mitigation: CI also builds on the stable Xcode of the runner.
- **Losing the `Ctx` layer** removes a hypothetical multi-connection path. No
  shipped feature depends on it.
- **Settings container change** on rename. Mitigation: the import flow in 4.5.

## 8. Out of scope for now, tracked for later

- Folder mapping / host file access (Qt has it via a FileProvider bridge).
- Sunshine ABR client feedback loop.
- Notarized builds (needs a paid Apple Developer account).
- Dynamic SDR reference white (`LiSendClientSdrWhiteNits`): macOS exposes EDR
  headroom but no SDR-white-in-nits query; needs research before it can feed
  the 1 Hz loop the Windows client runs.
- Dynamic HDR capabilities (HDR10+, Dolby Vision 8.1/8.4): the Metal renderer
  has no path for them yet; the client keeps advertising none.
- DualSense haptics (IR v2 frames) through GameController haptics.
- Native trackpad events (`LiSendTouchpadEvent`).
- Remote text context: nothing to do on macOS beyond registering the callback,
  which also opts the client in server-side; left unregistered for now.
- Retina scaling of host cursor shapes (currently shown at host pixel size).
