# ForgeHub on Android — packaging overview

This directory holds everything needed to run ForgeHub on a personal Android
phone. It is new, additive, and lives entirely under `packaging/android/` so
that this fork keeps rebasing cleanly onto `upstream` (`huchukato/ForgeHub`).

Full design and task plan are checked into the repo for reference:

- Spec: `docs/superpowers/specs/2026-10-27-forgehub-android-design.md`
- Plan: `docs/superpowers/plans/2026-10-27-forgehub-android.md`

## The three layers

1. **Backend on the phone, unmodified.** Termux + `proot-distro` Ubuntu hosts
   the existing `forgehub_backend` Python package verbatim on
   `127.0.0.1:8484`. No TypeScript reimplementation, no Chaquopy — standard
   aarch64 wheels install under proot like on any other Linux. An idempotent
   install script and a wake-locked start script (with Termux:Boot autostart)
   live here, added in later tasks.
2. **Thin WebView shell APK.** A minimal single-activity Android app that
   loads `http://127.0.0.1:8484`, waits out backend cold-start with a retry
   screen, and otherwise gets out of the way. `src/api.ts` already defaults to
   same-origin relative URLs, so the shell needs no API base URL configured.
3. **Responsive frontend, same codebase.** The existing Tailwind frontend
   gains `sm`/`md` breakpoint behaviour for small screens. Rendering at `xl`
   and above is not allowed to change.

## Ground rule: `forgehub_backend/**` is never modified

`forgehub_backend/**` and `forgehub-app/src/api.ts` are not touched by any
task in this plan. ForgeHub is a third-party repository that keeps moving
upstream; porting or editing its backend would mean maintaining a second
implementation of the same logic forever. If a task ever appears to require
changing backend source, the answer is to stop and escalate — not to edit it.

## Living in a fork — the rebase rule

Everything under `packaging/android/` is new and isolated: upstream does not
have these files, so they never conflict on `git fetch upstream && git
rebase upstream/main`. The only files this plan touches that upstream also
edits are the frontend's `App.tsx` and a handful of components, and there the
rule is strict: add Tailwind breakpoint classes and, where a real branch is
needed, a small shared `useIsMobile`-style hook. Never restructure component
trees, rename props, or reorder JSX for tidiness. A diff made only of added
class strings rebases cleanly; a reorganised `App.tsx` does not.

## Committed frontend build and `FORGEHUB_FRONTEND_DIR`

The backend serves the built frontend from a directory configured by the
`FORGEHUB_FRONTEND_DIR` env var (default `forgehub-app/dist`, see
`forgehub_backend/config.py:60`). On the phone there is no Node toolchain and
no desire to run `npm run build` inside the proot guest, so on the `android`
branch the built frontend is **committed to the repo** at
`packaging/android/dist/`, and the backend is pointed at it via
`FORGEHUB_FRONTEND_DIR=packaging/android/dist` when started on the phone.

This is a deliberate exception to normal practice. `forgehub-app/dist/` is
listed in `.gitignore` (`.gitignore:9`), and editing `.gitignore` would
conflict on every rebase onto upstream — so instead of untracking it, the
build output lives at a different, android-only path that upstream's
`.gitignore` says nothing about and `git add` can target directly.

This task does not build or commit that directory — only documents the rule
for the tasks that do.

## Installing on the phone

`install.sh` (run once, in Termux proper) and `guest-provision.sh` (run
inside the `proot-distro` Ubuntu guest, either by `install.sh` or directly
for testing) provision everything the backend needs: system packages
(including `ffmpeg`/`ffprobe`, a hard precondition — video/audio workflows
shell out to both), a clone of this fork, a venv, and the dependency set
pinned in `requirements.lock.txt`. Both scripts are idempotent: re-running
them picks up a fork update without re-cloning or touching an existing
`data/settings.json` (which may hold the owner's Runpod API key).

```bash
FORGEHUB_REPO_URL=https://github.com/<you>/ForgeHub.git \
  bash packaging/android/install.sh
```

`FORGEHUB_REPO_URL` is **required** — this is a fork of a third-party
repository and its URL is not hardcoded anywhere in these scripts. Optional
`FORGEHUB_REPO_BRANCH` (default `android`) selects which branch to track.

Until Task 6 commits `packaging/android/dist/` (see above), provisioning
succeeds and warns, rather than failing: the backend's API is fully usable
without the built frontend, only `/` has nothing to serve yet.

`guest-provision.sh` is the part Task 2's `tests/_arm64.sh` container can
exercise directly (no Termux/proot-distro involved); `install.sh`'s own
guard clauses can only be smoke-checked the same way — see
`tests/test_install_idempotent.sh` and `tests/test_ffmpeg_required.sh`.

## Running the backend: `start-backend.sh`

Once `install.sh` has provisioned the guest, start the backend with:

```bash
bash packaging/android/start-backend.sh
```

This is what makes the backend survive the screen turning off mid-job: it
takes a `termux-wake-lock` (so Android's power manager doesn't suspend the
guest's CPU on screen-off), raises a persistent `termux-notification` with a
Stop button, launches `proot-distro login ubuntu --
~/ForgeHub/.venv/bin/uvicorn forgehub_backend.main:app --host 127.0.0.1
--port 8484`, and releases the wake-lock / dismisses the notification on
every exit path via a trap — normal exit, the Stop button, Ctrl-C, or an
external `kill`. It also refuses to start a second instance if `/config`
already answers on the same port, and points `FORGEHUB_FRONTEND_DIR` at
`packaging/android/dist` when that directory exists (see above) — never
failing to start just because the frontend build hasn't landed yet.

The backend binds `127.0.0.1:8484` **only**. There is no authentication of
any kind on the phone, and the Runpod API key lives in `data/settings.json`
— a backend reachable from the local Wi-Fi would hand that key to anyone on
the same network. `tests/test_backend_liveness.sh` asserts this with `ss`
(socket present on `127.0.0.1:8484`, absent on `0.0.0.0:8484`); the script
checks it again itself, best-effort, right after starting.

`termux-wake-lock` / `termux-notification` / `proot-distro` are Termux-only
and do not exist in a plain container. Set `FORGEHUB_NO_TERMUX=1` to skip
them explicitly (the script says plainly which calls it skipped — it never
pretends to have taken a wake-lock or raised a notification it did not) and
run the guest's own venv directly instead of through `proot-distro login`.
This is the escape hatch `tests/test_backend_liveness.sh` uses to exercise
everything else — the real backend start, the second-instance guard, the
local-only bind, the cleanup trap — inside `tests/_arm64.sh`'s container.

## Autostart on boot: Termux:Boot

`boot/start-forgehub.sh` is a one-line Termux:Boot entry point that
delegates to `start-backend.sh`, so the backend comes up automatically after
a reboot without the owner opening Termux. Two manual, one-time steps are
required for this to work at all — there is no way to script around either:

1. Install the **Termux:Boot** app from **F-Droid** (not the Play Store —
   that build is a different, often-stale release).
2. **Open the Termux:Boot app once** after installing it. Android does not
   deliver the boot broadcast to an app the user has never launched; this
   one launch is what registers the receiver. Skipping it is the single
   most common reason autostart silently does nothing after a reboot.

Then, in Termux:

```bash
mkdir -p ~/.termux/boot
cp ~/ForgeHub/packaging/android/boot/start-forgehub.sh ~/.termux/boot/
chmod +x ~/.termux/boot/start-forgehub.sh
```

Boot-time output (no terminal is attached that early) goes to
`~/forgehub-backend-boot.log`.

## Baseline commands

These are the commands later tasks must not regress. Run from a clean
checkout of this branch.

Backend:

```bash
cd /home/deploy/ForgeHub
python3 -m venv .venv
.venv/bin/pip install -e '.[dev]'
.venv/bin/pytest -q
```

Frontend:

```bash
cd /home/deploy/ForgeHub/forgehub-app
npm ci
npm run build
```

Baseline recorded 2026-10-27 on `android` @ `31c827f`, unmodified upstream
code:

- `pytest -q` → `33 passed` (no failures, one unrelated `httpx`/`starlette`
  deprecation warning). Later tasks must not reduce this count.
- `npm run build` → succeeds; `dist/` contains `index.html`,
  `apple-touch-icon.png`, `favicon.png`, `favicon-16.png`, `favicon-32.png`,
  `logo.png`, and `assets/` (`index-*.js`, `index-*.css`,
  `background-*.jpg`). Hashes in filenames will change on rebuild; the file
  set is what matters.
