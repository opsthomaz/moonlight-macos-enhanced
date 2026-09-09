# Phase 1 — Housekeeping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring every piece of inherited-but-unmerged work into the fork, remove repo litter, and get CI producing DMGs on the fork, so phase 2 starts from a clean, buildable, tested baseline.

**Architecture:** Pure integration work on a `phase1/housekeeping` branch: cherry-pick the BOOGAY renderer/shortcut commits, merge the four small upstream PRs as no-fast-forward merges that keep the contributors' authorship, clean the tree, and run the existing GitHub Actions workflow on the fork. No product code is written by hand in this phase beyond one-line fixes needed to keep the build green.

**Tech Stack:** git, GitHub CLI (`gh`), Xcode 27.0 beta via `DEVELOPER_DIR`, GitHub Actions (`macos-26` runner, arm64 only).

**Spec:** `docs/design/2026-09-09-foundation-native-client-design.md`, section 5 phase 1 and section 2 "Inherited work available".

## Global Constraints

- No commit, push, tag, or pull request is created without the owner's explicit authorization. Every "Commit" step below is preceded by an **Authorization gate**: present the exact commit list, wait for "yes".
- No mention of any AI assistant or AI tooling in commits, files, PRs, or comments. No `Co-Authored-By` trailers.
- Commit subjects follow `.githooks/commit-msg`: `<type>(<scope>): <lowercase description>`, max 72 chars, types `feat|fix|docs|refactor|perf|test|chore|style|build|ci`. Bodies and subjects in English.
- Cherry-picks and merges keep the original author. Only the subject line may be rewritten, and only to satisfy the hook.
- Local builds use Xcode 27.0 beta: `DEVELOPER_DIR=/Users/thomazmac/Downloads/Xcode-beta.app/Contents/Developer`, unsigned: `CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`.
- `Limelight/Version.xcconfig` is rewritten by the build script on every build. Run `git checkout -- Limelight/Version.xcconfig` after each build so it never lands in a commit.
- Deployment target stays 12.0. Bundle id stays `std.skyhua.MoonlightMac` in this phase (identity change is phase 5).

## Verified starting state (2026-09-09)

- Clone at `/Users/thomazmac/moonlight-macos-enhanced`, branch `master` = `upstream/master` = `a9f20cc`.
- Remotes: `origin` (opsthomaz fork), `upstream` (skyhua0224), `boogay` (BOOGAY). PR heads fetched as `upstream/pr/<n>`.
- `git merge-tree` dry run: `boogay/master`, then PRs 46, 47, 45, 44 applied in that order over `upstream/master` produce zero conflicts.
- `xcframeworks/` is present locally (SDL2, FFmpeg, Opus) and untracked. `crash_log` (198 KB) is tracked.
- Build passes on Xcode 26.6 and 27.0 beta with 7 warnings, 0 errors.
- GitHub Actions is enabled on the fork (`allowed: all`). Workflow triggers on push to `master`/`main`, PRs, tags `v*`, and manual dispatch.

## File Structure

No new source files. Files touched:

- `.gitignore` — add `xcframeworks/`.
- `crash_log` — delete.
- `docs/design/2026-09-09-foundation-native-client-design.md` — add (already on disk, untracked).
- `docs/plans/2026-09-09-phase1-housekeeping.md` — add (this file).
- `.github/scripts/build_release_body.py:146` — default repo string becomes `opsthomaz/moonlight-macos-enhanced`.
- Cherry-picked and merged files (owned by their original commits): `Limelight/Stream/VideoDecoderRenderer.m`, `Limelight/Stream/Connection.m`, `Limelight/macOS/Helpers/LanguageManager.swift`, `Limelight/macOS/ViewControllers/SettingsShortcuts.swift`, `SettingsVideoPane.swift`, `StreamViewController+Diagnostics.m`, `StreamViewController.m`, `StreamViewController+MouseCapture.m`, `StreamViewController+MenuUI.m`, `StreamViewController+WindowModes.m`, `ConnectionEditorViewController.m`, `DebugLogParser.swift`, `SettingsAppPane.swift`, `SettingsInputPane.swift`, `SettingsModel*.swift`, `SettingsObjCBridge.swift`, `SettingsStore.swift`, `MicrophoneManager.swift`, `Limelight/Input/ControllerSupport.{h,m}`, `Limelight/Input/HIDSupport.m`, `Limelight/Stream/StreamConfiguration.h`, `Limelight/Utility/Logger.m`, `Limelight/macOS/{en,zh-Hans}.lproj/Localizable.strings`, `Moonlight.xcodeproj/project.pbxproj`.

---

### Task 1: Branch and hooks

**Files:**
- Modify: `.git/config` (local only, via `git config`)

**Interfaces:**
- Produces: branch `phase1/housekeeping` checked out at `a9f20cc`; commit-msg hook active for all later tasks.

- [ ] **Step 1: Verify the working tree is clean except for the two docs files**

Run: `git status --short`
Expected:
```
?? docs/
```

- [ ] **Step 2: Create the branch**

Run: `git switch -c phase1/housekeeping master`
Expected: `Switched to a new branch 'phase1/housekeeping'`

- [ ] **Step 3: Activate the repository's commit hooks**

Run: `git config core.hooksPath .githooks && chmod +x .githooks/commit-msg && git config core.hooksPath`
Expected: `.githooks`

- [ ] **Step 4: Prove the hook rejects a bad subject (dry test, nothing committed)**

Run:
```bash
printf 'Bad Subject\n' > /tmp/msg && sh .githooks/commit-msg /tmp/msg; echo "rc=$?"
printf 'chore: good subject\n' > /tmp/msg && sh .githooks/commit-msg /tmp/msg; echo "rc=$?"
```
Expected: first prints `invalid commit subject.` and `rc=1`; second prints `rc=0`.

No commit in this task.

---

### Task 2: Cherry-pick the BOOGAY commits

**Files:**
- Modify (by cherry-pick): `Limelight/Stream/VideoDecoderRenderer.m`, `Limelight/macOS/Helpers/LanguageManager.swift`, `Limelight/macOS/ViewControllers/SettingsShortcuts.swift`, `Limelight/macOS/ViewControllers/SettingsVideoPane.swift`, `Limelight/macOS/ViewControllers/StreamViewController+Diagnostics.m`

**Interfaces:**
- Consumes: branch from Task 1.
- Produces: 7 commits on `phase1/housekeeping`, authored by the BOOGAY author, subjects hook-compliant.

The 8 BOOGAY commits, oldest first, and what to do with each:

| Hash | Original subject | Action |
|---|---|---|
| `4bd7ade` | Fix macOS 12 crash: defer bringStreamControlsToFront to avoid re-entrant layout | pick, subject → `fix(stream): defer stream controls bring-to-front on macos 12` |
| `9a8ad4a` | perf: optimize streaming smoothness for macOS 13 (Ventura) | pick as is |
| `59641d6` | perf: add SDR fast-path bypassing compute pass for smoother streaming | pick as is |
| `53d9b76` | fix: use simd_float3 instead of Metal float3 in Objective-C code | pick as is |
| `a9b43ac` | feat: use text labels for modifier key shortcuts (Cmd/Opt/Ctrl/Shift) | pick as is |
| `4407684` | Fix: Replace Unicode modifier symbols with text equivalents | pick, subject → `fix(shortcuts): replace unicode modifier symbols with text equivalents` |
| `1a06cd9` | v1.3.9 release notes | **skip** (BOOGAY's release file; our releases get their own notes) |
| `6cb13bf` | Fix: Restore Cmd symbol in keyboard translation mode, keep stream shortcut changes | pick, subject → `fix(input): restore cmd symbol in keyboard translation mode` |

- [ ] **Step 1: Authorization gate**

Show the owner the table above and ask: "Create these 7 commits on `phase1/housekeeping`?" Do not continue until the answer is yes.

- [ ] **Step 2: Cherry-pick the five compliant commits and the three that need a subject rewrite, in order**

Run:
```bash
set -e
git cherry-pick -x 4bd7ade
git commit --amend --no-edit -m "fix(stream): defer stream controls bring-to-front on macos 12" -m "$(git log -1 --format=%b)"
git cherry-pick -x 9a8ad4a 59641d6 53d9b76 a9b43ac
git cherry-pick -x 4407684
git commit --amend --no-edit -m "fix(shortcuts): replace unicode modifier symbols with text equivalents" -m "$(git log -1 --format=%b)"
git cherry-pick -x 6cb13bf
git commit --amend --no-edit -m "fix(input): restore cmd symbol in keyboard translation mode" -m "$(git log -1 --format=%b)"
```
Expected: no conflict messages; `git log --oneline master..HEAD | wc -l` prints `7`.

Note: `-x` appends `(cherry picked from commit …)` to the body, which is the provenance we want. `--amend` keeps the original author.

- [ ] **Step 3: Verify authorship and subjects**

Run: `git log --format='%h %an | %s' master..HEAD`
Expected: 7 lines, author column shows the BOOGAY author on every line, every subject matches the hook pattern (lowercase after the colon, type prefix present).

- [ ] **Step 4: Build**

Run:
```bash
DEVELOPER_DIR=/Users/thomazmac/Downloads/Xcode-beta.app/Contents/Developer xcodebuild -project Moonlight.xcodeproj -scheme "Moonlight for macOS" -configuration Release -arch arm64 -derivedDataPath /tmp/dd-phase1 CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'
git checkout -- Limelight/Version.xcconfig
```
Expected: `** BUILD SUCCEEDED **`, no `error:` lines.

- [ ] **Step 5: Smoke test against the owner's host**

Launch `/tmp/dd-phase1/Build/Products/Release/Moonlight.app`, connect to the Foundation Sunshine host, stream for 30 seconds in SDR, open Settings → Shortcuts and confirm modifier labels read `Cmd`, `Opt`, `Ctrl`, `Shift`. Quit.
Expected: stream starts, no crash, labels are text.

---

### Task 3: Merge upstream PRs 46 and 47 (Metal renderer)

**Files:**
- Modify (by merge): `Limelight/Stream/VideoDecoderRenderer.m`, `Limelight/Stream/Connection.m`

**Interfaces:**
- Consumes: Task 2 branch state.
- Produces: two merge commits, one per PR, original author `beichen` on the merged commits.

- [ ] **Step 1: Authorization gate**

Ask: "Merge upstream PR 46 (`fix(metal): keep stream aspect ratio`, 1 commit) and PR 47 (`fix(hdr): correct Metal HDR processing baseline`, 1 commit) as two no-fast-forward merges?" Wait for yes.

- [ ] **Step 2: Merge PR 46**

Run:
```bash
git merge --no-ff upstream/pr/46 -m "fix(metal): keep stream aspect ratio in metal renderer" -m "Merges skyhua0224/moonlight-macos-enhanced#46 by beichen."
```
Expected: `Merge made by the 'ort' strategy.` and 1 file changed.

- [ ] **Step 3: Merge PR 47**

Run:
```bash
git merge --no-ff upstream/pr/47 -m "fix(hdr): correct metal hdr transfer and edr mapping" -m "Merges skyhua0224/moonlight-macos-enhanced#47 by beichen."
```
Expected: `Merge made by the 'ort' strategy.` and 2 files changed.

- [ ] **Step 4: Build**

Same command as Task 2 Step 4.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Smoke test**

Stream in a window, resize the window to a non-16:9 shape, confirm the picture keeps its aspect ratio with bars rather than stretching. If the host has HDR enabled, toggle HDR on in the client and confirm the picture is not washed out or clipped.
Expected: aspect ratio preserved; HDR looks correct or, if no HDR display, SDR unchanged.

---

### Task 4: Merge upstream PR 45 (gamepad Menu long-press toggle)

**Files:**
- Modify (by merge): `Limelight/Input/ControllerSupport.{h,m}`, `Limelight/Input/HIDSupport.m`, `Limelight/Stream/StreamConfiguration.h`, `Limelight/macOS/Helpers/LanguageManager.swift`, `Limelight/macOS/ViewControllers/SettingsInputPane.swift`, `SettingsModel.swift`, `SettingsModel+DerivedValues.swift`, `SettingsModel+Persistence.swift`, `SettingsObjCBridge.swift`, `SettingsStore.swift`, `StreamViewController.m`, `StreamViewController+MouseCapture.m`, `Limelight/macOS/{en,zh-Hans}.lproj/Localizable.strings`

**Interfaces:**
- Produces: one merge commit bringing 2 commits by `beichen`.

- [ ] **Step 1: Authorization gate**

Ask: "Merge upstream PR 45 (2 commits: independent toggle for gamepad Menu long-press, plus live settings sync) as one no-fast-forward merge?" Wait for yes.

- [ ] **Step 2: Merge**

Run:
```bash
git merge --no-ff upstream/pr/45 -m "feat(input): add independent toggle for gamepad menu long-press" -m "Merges skyhua0224/moonlight-macos-enhanced#45 by beichen."
```
Expected: `Merge made by the 'ort' strategy.`, 15 files changed.

- [ ] **Step 3: Build**

Same command as Task 2 Step 4.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Smoke test**

Open Settings → Input, confirm a new toggle for the gamepad Menu long-press exists and its label is localized in both English and Chinese (switch language in Settings → App). With a gamepad connected, long-press Menu during a stream with the toggle on and off.
Expected: toggle present in both languages; behavior follows the toggle without restarting the stream.

---

### Task 5: Merge upstream PR 44 (English UI coverage)

**Files:**
- Modify (by merge): `Limelight/Utility/Logger.m`, `Limelight/macOS/Helpers/LanguageManager.swift`, `MicrophoneManager.swift`, `ConnectionEditorViewController.m`, `DebugLogParser.swift`, `SettingsAppPane.swift`, `StreamViewController+Diagnostics.m`, `StreamViewController+MenuUI.m`, `StreamViewController+WindowModes.m`, `Moonlight.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: one merge commit bringing 2 commits by `ste94pz`.

- [ ] **Step 1: Authorization gate**

Ask: "Merge upstream PR 44 (2 commits: complete English UI coverage in context menus and logs, plus review fixes) as one no-fast-forward merge?" Wait for yes.

- [ ] **Step 2: Merge**

Run:
```bash
git merge --no-ff upstream/pr/44 -m "fix(localization): complete english coverage in menus and logs" -m "Merges skyhua0224/moonlight-macos-enhanced#44 by ste94pz. Closes upstream issue 30."
```
Expected: `Merge made by the 'ort' strategy.`, 10 files changed. The dry run showed no conflict with Task 2's `LanguageManager.swift` change; if one appears, keep both sides: BOOGAY's `Ctrl+Opt+S` text label and PR 44's added English keys.

- [ ] **Step 3: Build**

Same command as Task 2 Step 4.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Smoke test**

Set language to English in Settings → App. Right-click a host and an app in the main window, open the in-stream menu, open the debug log viewer.
Expected: no Chinese strings remain in those surfaces; the performance-overlay item reads `Performance Overlay (Ctrl+Opt+S)`.

---

### Task 6: Repository cleanup

**Files:**
- Delete: `crash_log`
- Modify: `.gitignore`
- Modify: `.github/scripts/build_release_body.py:146`

**Interfaces:**
- Produces: one commit `chore(repo): remove crash log, ignore xcframeworks, fix release repo`.

- [ ] **Step 1: Make the changes**

Run:
```bash
git rm -q crash_log
printf 'xcframeworks/\n' >> .gitignore
sed -i '' 's#"skyhua0224/moonlight-macos-enhanced"#"opsthomaz/moonlight-macos-enhanced"#' .github/scripts/build_release_body.py
git status --short
```
Expected:
```
M .github/scripts/build_release_body.py
M .gitignore
D crash_log
?? docs/
```

- [ ] **Step 2: Verify the ignore works and the script still parses**

Run:
```bash
git check-ignore -v xcframeworks/SDL2.xcframework
python3 -c "import ast,sys; ast.parse(open('.github/scripts/build_release_body.py').read()); print('ok')"
```
Expected: first line names `.gitignore` as the matching rule; second prints `ok`.

- [ ] **Step 3: Authorization gate**

Show `git diff --stat` and ask: "Commit as `chore(repo): remove crash log, ignore xcframeworks, fix release repo`?" Wait for yes.

- [ ] **Step 4: Commit**

Run:
```bash
git add .gitignore .github/scripts/build_release_body.py
git commit -m "chore(repo): remove crash log, ignore xcframeworks, fix release repo"
```
Expected: hook accepts; `git show --stat HEAD` lists 3 files.

---

### Task 7: Add the design and plan documents

**Files:**
- Create (already on disk): `docs/design/2026-09-09-foundation-native-client-design.md`, `docs/plans/2026-09-09-phase1-housekeeping.md`

**Interfaces:**
- Produces: one commit `docs: add foundation-native client design and phase 1 plan`.

- [ ] **Step 1: Scan both files for forbidden mentions**

Run: `grep -n -iE 'co-authored|generated with' docs/design/*.md docs/plans/*.md; echo "rc=$?"`
Expected: no matches, `rc=1`.

- [ ] **Step 2: Authorization gate**

Ask: "Commit the two docs as `docs: add foundation-native client design and phase 1 plan`?" Wait for yes.

- [ ] **Step 3: Commit**

Run:
```bash
git add docs/design docs/plans
git commit -m "docs: add foundation-native client design and phase 1 plan"
```
Expected: 2 files added.

---

### Task 8: CI on the fork

**Files:**
- None modified unless the run fails; see Step 5.

**Interfaces:**
- Consumes: all commits from Tasks 2–7.
- Produces: a green `Build and Release` workflow run on `origin/phase1/housekeeping` with the arm64 DMG artifact. The inherited x86_64 and universal jobs were removed in this task after the Intel runner hung in `ibtool` for over 15 minutes on the first run.

- [ ] **Step 1: Final local build of the branch tip**

Same command as Task 2 Step 4, then `git checkout -- Limelight/Version.xcconfig && git status --short`.
Expected: `** BUILD SUCCEEDED **`; status empty.

- [ ] **Step 2: Authorization gate for push**

Show `git log --oneline --first-parent master..HEAD` (expected 15 commits: 7 cherry-picks, 4 merges, 2 chores, ci, docs) and ask: "Push `phase1/housekeeping` to `origin` and trigger CI?" Wait for yes.

- [ ] **Step 3: Push and dispatch**

Run:
```bash
git push -u origin phase1/housekeeping
gh workflow run build.yml --ref phase1/housekeeping -R opsthomaz/moonlight-macos-enhanced
sleep 20; gh run list -R opsthomaz/moonlight-macos-enhanced -b phase1/housekeeping -L 1
```
Expected: a run in `queued` or `in_progress`.

- [ ] **Step 4: Wait and inspect**

Run: `gh run watch -R opsthomaz/moonlight-macos-enhanced $(gh run list -R opsthomaz/moonlight-macos-enhanced -b phase1/housekeeping -L 1 --json databaseId --jq '.[0].databaseId') --exit-status; echo "rc=$?"`
Expected: `rc=0`, jobs `Build arm64` and `build` succeed, and `gh run view --json artifacts` lists the arm64 app and DMG artifacts.

- [ ] **Step 5: If the run fails**

Read the failing step's log with `gh run view <id> --log-failed`. The two known-plausible failures and their fixes:

1. `setup-xcode` cannot find a version: the workflow asks for `latest`; if the `macos-26` image renamed it, change `.github/workflows/build.yml:42` to `xcode-version: latest-stable`. Commit as `ci: pin setup-xcode to latest-stable` after an authorization gate.
2. The slice-verification step fails on the AWDL helper path (`std.skyhua.MoonlightMac.AwdlPrivilegedHelper`): the bundle id has not changed in this phase, so this must not happen; if it does, the helper build script is broken on the runner. Capture the log and stop; that is a phase 5 concern and the owner decides.

Any other failure: capture the log, stop, report to the owner. Do not iterate blindly on CI.

- [ ] **Step 6: Download and check the arm64 DMG**

Run:
```bash
gh run download -R opsthomaz/moonlight-macos-enhanced <id> -n "$(gh run view -R opsthomaz/moonlight-macos-enhanced <id> --json artifacts --jq '.artifacts[] | select(.name|test("arm64")) | .name')" -D /tmp/phase1-dmg
hdiutil attach -nobrowse -quiet /tmp/phase1-dmg/*.dmg && ls /Volumes/Moonlight*/ && codesign -dv /Volumes/Moonlight*/Moonlight.app 2>&1 | head -3; hdiutil detach -quiet /Volumes/Moonlight*
```
Expected: the DMG mounts, contains `Moonlight.app`, and `codesign` reports it is unsigned or ad-hoc (as upstream ships).

---

### Task 9: Phase gate

- [ ] **Step 1: Report to the owner**

Summarize: 13 commits on `phase1/housekeeping`, CI green, three DMGs, smoke tests done. Ask whether to fast-forward `master` to the branch (`git switch master && git merge --ff-only phase1/housekeeping && git push origin master`) or keep it as a branch until phase 2 is ready. Do nothing until told.

Phase 1 is done when `origin` carries the branch, CI is green, and the owner has decided what to do with `master`.

## Self-review

- **Spec coverage.** Phase 1 in the spec lists: cherry-pick BOOGAY (Task 2), merge PRs 44–47 (Tasks 3–5), remove `crash_log` (Task 6), gitignore `xcframeworks/` (Task 6), CI green on the fork with DMGs (Task 8). The design doc landing in the repo is Task 7. Xcode 27 for local builds is in the constraints and Task 2 Step 4. Nothing from phase 1 is uncovered.
- **Placeholders.** None. Every command is literal; the only owner-dependent values are the CI run id, read from `gh run list` in the same step.
- **Consistency.** Branch name `phase1/housekeeping` everywhere. Build command identical in Tasks 2, 3, 4, 5, 8. First-parent commit count 7 + 2 + 1 + 1 + 1 + 1 + 2 = 15 matches Task 8 Step 2.
