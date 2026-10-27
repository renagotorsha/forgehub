# ForgeHub on Android — Design

**Date:** 2026-10-27
**Status:** awaiting approval
**Note on location:** this file lives outside the ForgeHub checkout because ForgeHub is not on this machine yet. It belongs in our fork at `docs/superpowers/specs/2026-10-27-forgehub-android-design.md`.

## Intent and why

Run the whole of ForgeHub on a personal Android phone — backend included — so that generating is possible from the phone with the same capabilities the home Windows 11 machine has today. Compute is not the issue: it already happens remotely on Runpod Serverless. The phone only needs to orchestrate jobs and show results.

The owner wants it to behave like an app: a home-screen icon, not a browser tab. It is for one person's own phone, sideloaded.

Two decisions were made up front, and the reasons matter more than the choices:

**The Python backend moves to the phone unmodified, hosted by Termux + proot-distro Ubuntu.** Not ported.

**Why not rewrite `forgehub_backend` (~2700 lines) in TypeScript inside the app.** ForgeHub keeps running on Win11. A TypeScript backend means two implementations of the same logic — wildcard expansion, PNG text-chunk metadata, workflow catalog inspection, the Runpod executor. Every future change has to be made twice, and the divergences surface weeks later as subtly different prompts or missing metadata. The one-off cost (3–5 weeks) is not the real cost; the permanent maintenance tax is.

**Why not Chaquopy (Python embedded in a single APK).** It delivers the single-APK ideal, but `pydantic-core` (Rust), `aiohttp`, `uvloop`/`httptools` have no aarch64-android wheels. Removing pydantic cascades into removing FastAPI, which means rewriting `main.py`'s routing — the backend gets mutilated anyway, and the single APK is not worth that.

Under proot-distro the backend is running on an ordinary Linux: manylinux aarch64 wheels install from PyPI as usual, `apt install ffmpeg` covers video, and `data/settings.json` sits exactly where it does on the desktop.

## Goals

- Feature parity with desktop: workflows, wildcard expansion with runtime selects, QwenVL/LLM chat assistance, job queue, outputs gallery, uploads, settings including the Runpod API key and endpoint autodetection.
- Launches from a home-screen icon with no visible browser chrome.
- `forgehub_backend` is shared verbatim with the desktop checkout — no Android fork of the Python code.
- Layout comfortable for one-handed phone use, portrait and landscape.
- Desktop and Electron layouts are not degraded by the responsive work.

## Non-goals

- Google Play distribution. The APK is sideloaded.
- Multi-user support, or installation on anyone else's device.
- On-device inference. All generation stays on Runpod.
- iOS.
- Any internet-reachable backend. It binds to `127.0.0.1` only.
- Syncing outputs or settings between the phone and the Win11 machine.

## Anti-goals

These would count as failure even if the app technically works:

- A second implementation of any backend logic.
- A layout that is responsive on the phone but worse on the desktop.
- A setup that requires typing shell commands before each session.
- The backend dying silently in the background while a job is running, losing the result.
- The Runpod API key reachable by anything other than this phone.

## Constraints

- Android, personal device, no root assumed.
- Termux must come from **F-Droid**; the Play Store build is abandoned and unusable.
- **proot-distro Ubuntu, not bare Termux.** Bare Termux would require building `pydantic-core` from Rust source; the proot guest installs standard aarch64 wheels.
- Android doze and background execution limits: the backend needs `termux-wake-lock` plus a foreground notification to survive, and Termux:Boot for autostart.
- The backend binds `127.0.0.1:8484`; the WebView must permit cleartext traffic to localhost only.
- Python >= 3.10 (per `pyproject.toml`).
- **Video and audio workflows are in active use.** `files.py` shells out to **ffmpeg/ffprobe** for them — video thumbnails and container metadata embedding. ffmpeg must be installed in the proot guest and discoverable on `PATH`, and the video paths through `files.py` must be exercised, not skipped. The desktop binary bundled by `imageio-ffmpeg` does not run on Android and must not be relied on.
- **ForgeHub is a third-party repository.** We work in a fork and expect to pull upstream changes. See "Living in a fork" below — this constrains how the frontend may be modified.
- **Build host: the Linux server at `/home/deploy`.** It also runs the unrelated ENSI stack (~60 Docker containers), so the Android toolchain must be self-contained and must not disturb it: a dedicated directory, no global package upheaval. Needs the fork cloned here, Node, JDK 17, and Android SDK command-line tools plus one platform and build-tools — roughly 5–8 GB of disk. The finished APK is copied to the phone by hand.

## The how, as decided

Three parts, in this order of risk.

### 1. Backend on the phone, unmodified

- Termux, Termux:Boot and Termux:API installed from F-Droid.
- `proot-distro install ubuntu`; inside the guest: python3, pip, git, ffmpeg.
- ForgeHub checked out in the guest; dependencies installed from `pyproject.toml`.
- Settings and outputs stay at the standard locations (`data/settings.json`, `SETTINGS.storage_dir`), so behaviour matches desktop.
- One **idempotent install script**, committed to the repo (suggested `packaging/android/install.sh`), performs all of the above. The owner runs it once.
- One **start script** that acquires `termux-wake-lock`, raises a foreground notification, launches uvicorn on `127.0.0.1:8484`, and is also wired into Termux:Boot for autostart.

### 2. Thin WebView shell APK

- Minimal Android application, single activity, loading `http://127.0.0.1:8484`. The backend already serves the built frontend, and `src/api.ts` defaults to same-origin relative URLs, so nothing in the client needs an API base URL.
- A splash/retry state while the backend comes up, polling `/config`; if it never answers, show a plain instruction to start the backend rather than a blank page.
- `usesCleartextTraffic` scoped to localhost.
- Download/save of outputs to the phone's storage, and a file picker (camera and gallery) feeding `POST /upload`.
- Hardware back button mapped to in-app navigation, not app exit.
- Signed with a local keystore and sideloaded.

### 3. Responsive frontend, same codebase

- `App.tsx`'s three-column shell (Sidebar / RecipeForm / preview + filmstrip) collapses on small screens: Sidebar becomes a drawer, the preview column becomes a sheet or a tab.
- `RecipeForm` goes single-column with touch-sized controls.
- `OutputsGallery`, `OutputLightbox`, `ChatDrawer` and `SettingsDialog` become full-screen sheets on small screens.
- The existing `xl:` breakpoints are the starting point. Add `sm`/`md` behaviour; rendering at `xl` and above must not change.

### Gallery scope

Each device keeps its own outputs. No sync. `config.py` already supports optional S3-compatible storage for large outputs, so a shared gallery can be turned on later as configuration rather than code.

### Living in a fork

ForgeHub belongs to someone else and keeps moving. Everything here has to survive repeated rebases onto upstream, and that shapes two things:

- **All new work is additive and isolated.** The Termux install script, the start script and the WebView shell are new files under `packaging/android/`. They never conflict, because upstream does not have them. This is also a second reason the backend is not ported: a TypeScript reimplementation would have to track upstream's Python changes by hand, forever.
- **Frontend edits stay surgical.** The responsive work is the only part that touches files upstream also edits (`App.tsx` and the components). So: add Tailwind breakpoint classes and, where a real branch is needed, a small shared `useIsMobile`-style hook — do not restructure component trees, rename props, or reorder JSX for tidiness. A diff made of added class strings rebases cleanly; a reorganised `App.tsx` does not.

## Left to the builder

- Kotlin shell versus a Capacitor shell.
- The exact small-screen pattern — bottom nav, tabs, or stacked sheets. This needs mockups and a look on the real device before committing.
- Whether to run uvicorn on the plain asyncio loop, dropping `uvloop`/`httptools` (likely simpler, and the backend is not throughput-bound).
- Ubuntu versus Debian for the proot guest.
- Autostart and wake-lock UX details.

Settled by the answers above, no longer open: the phone pulls our fork with `git clone` inside the proot guest (we control the fork, so this also delivers updates); ffmpeg is installed unconditionally; the toolchain lives on the Linux server.

## Known risks

- Doze suspending the process during long jobs, breaking status polling mid-generation.
- Saving outputs into the phone's shared storage from inside proot — path and permission friction.
- Memory headroom with numpy and Pillow loaded in the guest. Small, but not zero on a modest phone.
