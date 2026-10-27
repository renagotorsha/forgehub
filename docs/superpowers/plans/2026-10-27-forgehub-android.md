# ForgeHub on Android — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the unmodified ForgeHub Python backend on a personal Android phone under Termux + proot, reached by a thin WebView shell app, with a phone-usable layout in the existing Tailwind frontend.

**Architecture:** Three layers, none of which touch `forgehub_backend/` source. A proot-distro Ubuntu guest inside Termux hosts the backend verbatim on `127.0.0.1:8484`. A minimal single-activity Android app loads that URL. The existing frontend gains breakpoint-only responsive behaviour. All new code lands in `packaging/android/` plus one new frontend hook file, so the fork rebases onto upstream cleanly.

**Tech Stack:** Python 3.10+/FastAPI/uvicorn (unchanged), Termux + proot-distro Ubuntu, Kotlin single-activity WebView, Gradle + Android SDK cmdline-tools + JDK 17, React 18 + Vite + Tailwind, pytest, Playwright (layout verification).

**Spec:** `/home/deploy/forgehub-android-design.md` (belongs in the fork at `docs/superpowers/specs/2026-10-27-forgehub-android-design.md`)

## Global Constraints

- Python `>=3.10`. Dependency floors from `pyproject.toml`: `fastapi>=0.115.0`, `pydantic>=2.9.0`, `aiohttp>=3.10.0`, `pillow>=10.4.0`, `numpy>=1.26.0`, `pyyaml>=6.0`, `python-multipart>=0.0.12`, `websockets>=12.0`, `certifi>=2024.0.0`, `imageio-ffmpeg>=0.5.1`.
- `forgehub_backend/**` and `forgehub-app/src/api.ts` are **not modified by any task**. If a task appears to require it, stop and escalate.
- Backend binds `127.0.0.1:8484` only. No authentication is added. Nothing listens on a routable interface.
- All new backend-side and packaging files live under `packaging/android/`. No new files elsewhere except `forgehub-app/src/hooks/useIsMobile.ts`.
- Frontend diffs are **additive only**: added Tailwind breakpoint classes and uses of `useIsMobile`. No component-tree restructuring, prop renames, or JSX reordering.
- Rendering at Tailwind `xl` and above must be byte-identical before and after. `xl:` and `2xl:` class strings are never removed or reordered.
- ffmpeg and ffprobe are installed in the guest and discoverable on `PATH`. The `imageio-ffmpeg` bundled desktop binary is never used on the phone.
- Termux comes from F-Droid. The guest is proot-distro, not bare Termux.
- Build host is this Linux server. The Android toolchain lives under `/home/deploy/android-sdk` and `/home/deploy/jdk17`; no global package changes, no interaction with the ENSI Docker stack.
- No sync of outputs or settings between phone and the Win11 machine.

## Review Focus

Five conditions the spec implies that no task's happy path would exercise. Each has a test assigned to the task that owns the code.

1. **Shell launches before the backend is up** (cold boot, Termux still starting) — the app must show a retry state and recover on its own, never a white page or a raw `ERR_CONNECTION_REFUSED`. → Task 5.
2. **Doze suspends the process mid-job** — on resume the app must re-poll `/execute/{id}/status` for the job it was watching and recover the result rather than orphan it. → Task 4 (wake-lock) and Task 5 (resume re-poll).
3. **ffmpeg absent or not on `PATH` in the guest** — a video workflow must fail with a legible error, not write a thumbnail-less or truncated output. → Task 3.
4. **Install script re-run on an already-provisioned phone** — must be a no-op, not a duplicate guest or a clobbered `data/settings.json` holding the Runpod key. → Task 3.
5. **Narrow viewport with a long wildcard-heavy `RecipeForm`** — controls must stay reachable and the execute action must not be scrolled off-screen or covered by a sheet. → Task 6.

---

### Task 1: Fork, checkout, and a green baseline

**Files:**
- Create: `packaging/android/README.md`
- Test: existing `tests/` (unchanged)

**Interfaces:**
- Produces: a clone at `/home/deploy/ForgeHub` on branch `android`, with `origin` = the user's fork and `upstream` = `huchukato/ForgeHub`; a known-good baseline of `pytest` and `npm run build`.

- [ ] **Step 1: Clone the fork and wire upstream**

```bash
git clone <FORK_URL> /home/deploy/ForgeHub
cd /home/deploy/ForgeHub
git remote add upstream https://github.com/huchukato/ForgeHub.git
git checkout -b android
```

- [ ] **Step 2: Establish the backend baseline**

Run: `cd /home/deploy/ForgeHub && python3 -m venv .venv && .venv/bin/pip install -e '.[dev]' && .venv/bin/pytest -q`
Expected: PASS. Record the pass count — later tasks must not reduce it.

- [ ] **Step 3: Establish the frontend baseline**

Run: `cd /home/deploy/ForgeHub/forgehub-app && npm ci && npm run build`
Expected: build succeeds. Record the `dist/` asset list.

- [ ] **Step 4: Write `packaging/android/README.md`**

Document: the three layers, that `forgehub_backend/**` is never modified, the rebase rule from the spec's "Living in a fork", and the baseline commands above.

- [ ] **Step 5: Commit**

```bash
git add packaging/android/README.md
git commit -m "docs: Android packaging overview and fork ground rules"
```

---

### Task 2: Prove the aarch64 dependency wall before touching the phone

The spec's central bet is that standard aarch64 wheels exist for `pydantic-core`, `aiohttp`, `Pillow` and `numpy`. This task proves or kills that bet on the server, where failure is cheap.

**Files:**
- Create: `packaging/android/verify-aarch64-deps.sh`
- Create: `packaging/android/requirements.lock.txt`

**Interfaces:**
- Produces: `requirements.lock.txt` — fully pinned, aarch64-installable dependency set, consumed by Task 3's install script.

- [ ] **Step 1: Write the failing verification script**

`verify-aarch64-deps.sh` must, under `docker run --rm --platform linux/arm64 ubuntu:24.04`: `apt-get install -y python3 python3-pip python3-venv ffmpeg`, create a venv, `pip install` the project, then assert all four imports and that ffmpeg is callable:

```bash
python3 -c "import pydantic, aiohttp, PIL, numpy, yaml; from pydantic import BaseModel; print('deps-ok')"
ffmpeg -version >/dev/null && ffprobe -version >/dev/null && echo "ffmpeg-ok"
```

Script exits non-zero unless both `deps-ok` and `ffmpeg-ok` appear.

- [ ] **Step 2: Run it and watch it fail honestly**

Run: `bash packaging/android/verify-aarch64-deps.sh`
Expected: either it prints both markers (the bet holds), or it fails on a named package. If `--platform linux/arm64` is unavailable, install `qemu-user-static` binfmt support first; if emulation cannot be had at all, fall back to querying the PyPI JSON API for each pinned version and asserting a `*manylinux*aarch64*.whl` file exists — record in the script which mode ran.

- [ ] **Step 3: Resolve every failure without touching `forgehub_backend/`**

Permitted moves, in order of preference: pin a version that has an aarch64 wheel; drop `uvicorn[standard]` to plain `uvicorn` (losing `uvloop`/`httptools`, which the spec allows); `apt-get install` a system package instead of a wheel. If a dependency can only be satisfied by editing backend source, **stop and escalate** — that invalidates the spec's core decision.

- [ ] **Step 4: Freeze the result**

Run: inside the arm64 container, `pip freeze > requirements.lock.txt`
Expected: file lists every dependency pinned, including transitive ones.

- [ ] **Step 5: Re-run the script against the lock file**

Run: `bash packaging/android/verify-aarch64-deps.sh --lock`
Expected: `deps-ok` and `ffmpeg-ok`, installing only from `requirements.lock.txt`.

- [ ] **Step 6: Commit**

```bash
git add packaging/android/verify-aarch64-deps.sh packaging/android/requirements.lock.txt
git commit -m "feat: verify and pin aarch64 dependency set for Android guest"
```

---

### Task 3: Idempotent Termux install script

**Files:**
- Create: `packaging/android/install.sh`
- Create: `packaging/android/guest-provision.sh`
- Test: `packaging/android/tests/test_install_idempotent.sh`

**Interfaces:**
- Consumes: `requirements.lock.txt` (Task 2).
- Produces: a provisioned guest with the fork cloned at `~/ForgeHub` inside it, a venv at `~/ForgeHub/.venv`, ffmpeg present, and `data/settings.json` untouched if it already existed. `guest-provision.sh` is the part that runs *inside* the guest and is the piece Task 2's container can exercise directly.

- [ ] **Step 1: Write the failing idempotency test**

`test_install_idempotent.sh` runs `guest-provision.sh` twice in the arm64 container with a pre-seeded `data/settings.json` containing a sentinel Runpod key, and asserts:

```bash
# after second run
test "$(jq -r .runpod_api_key data/settings.json)" = "SENTINEL-KEY-DO-NOT-CLOBBER"
test "$(ls -d ~/ForgeHub | wc -l)" = "1"
grep -q "already provisioned" second-run.log
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash packaging/android/tests/test_install_idempotent.sh`
Expected: FAIL — `guest-provision.sh` does not exist.

- [ ] **Step 3: Write `guest-provision.sh`**

Runs inside the guest. Installs `python3 python3-venv git ffmpeg` via apt; clones the fork's `android` branch to `~/ForgeHub` if absent, otherwise `git pull`; creates the venv and installs from `requirements.lock.txt`; builds nothing (the frontend `dist/` is committed or fetched — see Step 5). Never writes `data/settings.json` if it exists; logs `already provisioned` and skips completed stages.

- [ ] **Step 4: Write `install.sh`**

Runs in Termux proper. Asserts Termux (`$PREFIX` set) and refuses to run elsewhere with a clear message. Installs `termux-api`, `proot-distro`, `git`; runs `proot-distro install ubuntu` if the guest is absent; then executes `guest-provision.sh` inside it via `proot-distro login ubuntu -- bash`. Prints the exact next command to start the backend.

- [ ] **Step 5: Add the ffmpeg-absence test (Review Focus 3)**

Create `packaging/android/tests/test_ffmpeg_required.sh`. In the arm64 container, start the backend with ffmpeg removed from `PATH`, place a known video file in the outputs directory, and drive it through the public API rather than internal helpers:

```bash
curl -fsS "127.0.0.1:8484/outputs/meta" | jq -e '.[] | select(.name=="probe.mp4")'
curl -s -o thumb.out -w '%{http_code}' "127.0.0.1:8484/outputs/probe.mp4?thumb=1" > code.txt
# must not be a success with a garbage body
test "$(cat code.txt)" != "200" || ! test -s thumb.out
test ! -e outputs/probe.mp4.thumb.jpg -o -s outputs/probe.mp4.thumb.jpg
```

Assert the failure is legible and that no zero-byte or partial thumbnail is left behind. If the backend's current behaviour is a silent skip, the fix goes into `install.sh` as a hard precondition (`ffmpeg -version` and `ffprobe -version` must both succeed before provisioning reports success) — **not** into backend source.

- [ ] **Step 6: Run both tests to verify they pass**

Run: `bash packaging/android/tests/test_install_idempotent.sh && bash packaging/android/tests/test_ffmpeg_required.sh`
Expected: PASS, PASS.

- [ ] **Step 7: Commit**

```bash
git add packaging/android/install.sh packaging/android/guest-provision.sh packaging/android/tests/
git commit -m "feat: idempotent Termux + proot install scripts for Android"
```

---

### Task 4: Start script with wake-lock and autostart

**Files:**
- Create: `packaging/android/start-backend.sh`
- Create: `packaging/android/boot/start-forgehub.sh` (Termux:Boot entry point)

**Interfaces:**
- Consumes: the provisioned guest (Task 3).
- Produces: a backend answering `GET http://127.0.0.1:8484/config` with HTTP 200, surviving screen-off.

- [ ] **Step 1: Write the failing liveness test**

`packaging/android/tests/test_backend_liveness.sh` starts the backend via `start-backend.sh`, polls `/config` for up to 60s, asserts HTTP 200 and that the response parses as JSON; then asserts the listening socket is `127.0.0.1:8484` and **not** `0.0.0.0`:

```bash
ss -ltnp | grep -q '127.0.0.1:8484'
! ss -ltnp | grep -q '0.0.0.0:8484'
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash packaging/android/tests/test_backend_liveness.sh`
Expected: FAIL — script missing.

- [ ] **Step 3: Write `start-backend.sh`**

Acquires `termux-wake-lock`; raises a persistent `termux-notification` with a stop action; launches `proot-distro login ubuntu -- ~/ForgeHub/.venv/bin/uvicorn forgehub_backend.main:app --host 127.0.0.1 --port 8484`; releases the wake-lock and dismisses the notification on exit via a trap. Refuses to start a second instance if `/config` already answers.

- [ ] **Step 4: Write the Termux:Boot entry point**

`boot/start-forgehub.sh` is a one-liner delegating to `start-backend.sh`, with install instructions in a comment (`~/.termux/boot/`). Document in `packaging/android/README.md` that Termux:Boot must be installed from F-Droid and the app opened once.

- [ ] **Step 5: Run the liveness test to verify it passes**

Run: `bash packaging/android/tests/test_backend_liveness.sh`
Expected: PASS (on the phone; on the server run it against the guest-equivalent container, skipping the `termux-*` calls via the script's `FORGEHUB_NO_TERMUX=1` escape hatch).

- [ ] **Step 6: Commit**

```bash
git add packaging/android/start-backend.sh packaging/android/boot/ packaging/android/tests/test_backend_liveness.sh
git commit -m "feat: wake-locked backend start script with Termux:Boot autostart"
```

---

### Task 5: WebView shell APK

**Files:**
- Create: `packaging/android/shell/` (Gradle project, package `app.forgehub.shell`)
- Create: `packaging/android/shell/app/src/main/java/app/forgehub/shell/MainActivity.kt`
- Create: `packaging/android/shell/app/src/main/res/xml/network_security_config.xml`
- Test: `packaging/android/shell/app/src/test/java/app/forgehub/shell/BackendProbeTest.kt`

**Interfaces:**
- Consumes: a backend on `http://127.0.0.1:8484` (Task 4).
- Produces: `app-release.apk`, and `BackendProbe.await(timeoutMs: Long): Boolean` — the retry helper the activity uses before loading the WebView.

- [ ] **Step 1: Install the toolchain**

Install JDK 17 to `/home/deploy/jdk17` and Android SDK cmdline-tools to `/home/deploy/android-sdk` (platform + build-tools for the chosen `compileSdk`). Nothing global; nothing touching the ENSI stack.
Run: `/home/deploy/jdk17/bin/java -version && /home/deploy/android-sdk/cmdline-tools/latest/bin/sdkmanager --list | head`
Expected: JDK 17 reported; sdkmanager lists packages.

- [ ] **Step 2: Write the failing cold-start test (Review Focus 1)**

`BackendProbeTest.kt`, against a local stub server: `await()` returns `false` when nothing listens; returns `true` once the stub starts answering `/config` partway through the window; never throws.

```kotlin
@Test fun returnsTrueWhenBackendAppearsLate() {
    val stub = startStubAfter(2_000)
    assertTrue(BackendProbe.await(timeoutMs = 10_000))
}
@Test fun returnsFalseWhenBackendNeverAppears() {
    assertFalse(BackendProbe.await(timeoutMs = 1_000))
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cd packaging/android/shell && ./gradlew :app:testDebugUnitTest`
Expected: FAIL — `BackendProbe` unresolved.

- [ ] **Step 4: Implement `BackendProbe.await` and `MainActivity`**

`BackendProbe.await` polls `GET /config` on a backoff until timeout. `MainActivity` shows a retry screen with a manual "retry" button while `await` is false — never a WebView error page; enables JS, DOM storage, file access for `<input type=file>` (camera + gallery) and a `DownloadListener` saving outputs to the phone's Downloads; maps the hardware back button to `webView.goBack()` when history exists; on `onResume`, calls `webView.evaluateJavascript` to trigger the frontend's status re-poll (Review Focus 2). `network_security_config.xml` permits cleartext for `127.0.0.1` only.

- [ ] **Step 5: Run the unit tests to verify they pass**

Run: `cd packaging/android/shell && ./gradlew :app:testDebugUnitTest`
Expected: PASS.

- [ ] **Step 6: Build and sign**

Run: `./gradlew :app:assembleRelease` with a local keystore (keystore path and credentials from env vars, never committed).
Expected: `app-release.apk` produced; `apksigner verify` passes.

- [ ] **Step 7: Commit**

```bash
git add packaging/android/shell/
git commit -m "feat: WebView shell app with backend cold-start retry"
```

---

### Task 6: Responsive layout, additive only

**Files:**
- Create: `forgehub-app/src/hooks/useIsMobile.ts`
- Modify: `forgehub-app/src/App.tsx` (three-column shell)
- Modify: `forgehub-app/src/components/RecipeForm.tsx`, `OutputsGallery.tsx`, `OutputLightbox.tsx`, `ChatDrawer.tsx`, `SettingsDialog.tsx`, `Sidebar.tsx`
- Test: `forgehub-app/tests/layout.spec.ts` (Playwright)

**Interfaces:**
- Produces: `useIsMobile(): boolean` — `true` below Tailwind's `md` (768px), implemented with `matchMedia` and SSR-safe.

- [ ] **Step 1: Write the failing layout tests**

Against the backend serving `dist/` on `127.0.0.1:8484`, at viewport 390×844: Sidebar is not visible until its drawer trigger is tapped; the preview column is not in the document flow; the execute button is visible without scrolling with a long wildcard-heavy workflow selected (Review Focus 5); `OutputsGallery` and `SettingsDialog` occupy the full viewport when opened. At 1920×1080: a reference screenshot taken before any change matches after (Global Constraint: `xl+` unchanged).

- [ ] **Step 2: Run them to verify they fail**

Run: `cd forgehub-app && npx playwright test tests/layout.spec.ts`
Expected: FAIL on the mobile assertions; the 1920 snapshot test passes already and must keep passing.

- [ ] **Step 3: Implement `useIsMobile` and the breakpoint classes**

Add the hook. In `App.tsx`, add `sm`/`md` classes to the existing column wrappers so the Sidebar becomes a drawer and the preview column collapses; keep every `xl:`/`2xl:` class string exactly as-is. In the component files, add full-screen sheet classes at small widths. Use `useIsMobile` only where a class cannot express the branch.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd forgehub-app && npx playwright test tests/layout.spec.ts`
Expected: PASS, including the unchanged 1920×1080 snapshot.

- [ ] **Step 5: Verify the diff is additive**

Run: `git diff --stat forgehub-app/src && git diff forgehub-app/src | grep '^-' | grep -v '^---'`
Expected: removed lines are only class-string rewrites of lines re-added with extra breakpoints — no deleted JSX elements, no renamed props.

- [ ] **Step 6: Commit**

```bash
git add forgehub-app/src forgehub-app/tests
git commit -m "feat: phone-usable layout via additive Tailwind breakpoints"
```

---

### Task 7: End-to-end on the phone

**Files:**
- Create: `packaging/android/CHECKLIST.md`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Provision the phone**

Install Termux, Termux:API, Termux:Boot from F-Droid; run `install.sh`; enter the Runpod API key in Settings; confirm endpoint autodetection lists the real endpoints.

- [ ] **Step 2: Run an image job end to end**

Expected: job queues, status polls to completion, output appears in the gallery with its metadata, thumbnail renders, download to Downloads works.

- [ ] **Step 3: Run a video job end to end**

Expected: video output saves, ffmpeg-generated thumbnail renders, container metadata is readable via `/outputs/meta`.

- [ ] **Step 4: Verify upload and chat parity**

Upload an image through the picker (camera and gallery both) into a workflow that consumes one; then run the QwenVL/LLM prompt enhancer from `ChatDrawer`.
Expected: `POST /upload` succeeds from both sources and the uploaded image reaches the job; `/chat/models` lists models and an enhancement round-trip returns a modified prompt. These are spec goals that no earlier task exercises.

- [ ] **Step 5: Verify doze survival (Review Focus 2)**

Queue a long job, lock the screen, wait past the doze threshold, reopen the app.
Expected: the job is still tracked, its result is recovered, nothing orphaned.

- [ ] **Step 6: Verify cold start (Review Focus 1)**

Reboot the phone; open the app immediately.
Expected: retry screen, then the UI loads on its own once Termux:Boot has the backend up.

- [ ] **Step 7: Verify the fork rebases**

Run: `git fetch upstream && git rebase upstream/main`
Expected: no conflicts outside `forgehub-app/src`, and any conflict there is a class-string merge.

- [ ] **Step 8: Write `CHECKLIST.md` and commit**

Record the verified steps and the exact phone model and Android version tested.

```bash
git add packaging/android/CHECKLIST.md
git commit -m "docs: verified Android end-to-end checklist"
```
