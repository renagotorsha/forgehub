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
trees, rename props, or reorder JSX for tidiness.

In practice the diff on this branch is not *only* added class strings, and
the rule above should be read as "surgical and additive", not "literally
zero structural change": `App.tsx` wraps the header's title/trigger block in
a new flex container to make room for the mobile sidebar trigger, seven
files gained `data-testid` attributes (for Playwright), and the mobile
full-screen sheets (`OutputsGallery`, `ChatDrawer`) gained a
`top-[var(--fh-header-h)]` offset fed by a new `useHeaderHeightVar` hook so
they start below the header instead of overlapping it. None of that renames
a prop, reorders existing JSX, or changes behaviour at `xl` and above, so it
still rebases cleanly in practice — but a reviewer should expect small,
additive structural changes near the header, not a diff of class-string
edits only.

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

That build is committed at `packaging/android/dist/` as of this branch (see
`git log -- packaging/android/dist/`), so a fresh clone already has it —
`install.sh`/`guest-provision.sh` only need to detect and point at it, not
wait for it to land.

## Prerequisites: apps to install first (all from F-Droid)

Install these before doing anything else below. **F-Droid specifically, not
the Play Store** — for all three, the Play Store build is a different,
often-stale release that is not what this is tested against:

1. **Termux.** The terminal everything below runs in.
2. **Termux:API.** The `termux-api` *package* (installed automatically by
   `install.sh`, below) is only half of this — it is a client that talks to
   the **Termux:API app**, which must also be installed separately and
   **opened once** to grant it notification/wake-lock permissions. Without
   the app, `termux-wake-lock` and `termux-notification` fail silently: the
   backend still starts, but `start-backend.sh` only *warns* that no
   wake-lock was acquired (it does not stop you), and a long generation can
   then die silently when the screen turns off. See `start-backend.sh`'s own
   warning text for the symptom if this is skipped.
3. **Termux:Boot.** Only needed for autostart-on-reboot; see "Autostart on
   boot" below for the one-time setup this app also requires (installing it
   is not enough — it must be opened once too).

## Bootstrap: get the fork onto the phone (Termux-side checkout)

Everything from here on distinguishes **two different checkouts of this
fork, on two different filesystems, that happen to share the path
`~/ForgeHub`:**

- The **Termux-side checkout** — `~/ForgeHub` under Termux's own `$HOME`.
  This is what `install.sh` itself runs from, what `start-backend.sh` and
  the Termux:Boot entry point read live, and what this section creates.
- The **guest-side checkout** — a *separate* clone at `~/ForgeHub` inside
  the `proot-distro` Ubuntu guest (so, from Termux, really somewhere under
  `$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu/root/ForgeHub`).
  `guest-provision.sh` creates and updates this one, from inside the guest,
  as part of "Installing on the phone" below. The venv and the running
  backend live here, not in the Termux-side checkout.

Nothing creates the Termux-side checkout automatically — it has to exist
*before* `install.sh` can even be run, because `install.sh` is a file inside
it. Set your fork's URL **once**, in this one place, and reuse it for both
this checkout and the guest-side one `install.sh` creates next:

```bash
export FORGEHUB_REPO_URL=https://github.com/<you>/ForgeHub.git   # ← set this once
export FORGEHUB_REPO_BRANCH=android                               # optional, this is the default

pkg install -y git
git clone --branch "$FORGEHUB_REPO_BRANCH" --single-branch --depth 1 \
  "$FORGEHUB_REPO_URL" ~/ForgeHub
cd ~/ForgeHub
```

`FORGEHUB_REPO_URL` has no default anywhere in these scripts — this is a
fork of a third-party repository and its URL is not public, so there is
nothing real to hardcode as a placeholder. Export your own fork's URL as
shown above before any of the commands below.

## Installing on the phone

From inside the Termux-side checkout created above (`cd ~/ForgeHub`, still
with `FORGEHUB_REPO_URL`/`FORGEHUB_REPO_BRANCH` exported in this shell):

```bash
bash packaging/android/install.sh
```

`install.sh` (in Termux proper) and `guest-provision.sh` (run inside the
`proot-distro` Ubuntu guest, either by `install.sh` or directly for
testing) provision everything the backend needs: system packages (including
`ffmpeg`/`ffprobe`, a hard precondition — video/audio workflows shell out to
both), the guest-side clone of this fork, a venv, and the dependency set
pinned in `requirements.lock.txt`.

**This is also the update command.** Both scripts are idempotent, and
`install.sh` now starts by running `git pull --ff-only` on the Termux-side
checkout it is itself running from, before doing anything else — so
re-running the exact same `bash packaging/android/install.sh` command later
updates *both* checkouts (the Termux-side one here, and the guest-side one
via `guest-provision.sh`'s own `git pull`) in one step, without re-cloning
or touching an existing `data/settings.json` (which may hold the owner's
Runpod API key). `start-backend.sh` and the Termux:Boot entry point
(`boot/start-forgehub.sh`) read the Termux-side checkout live, so this pull
is what keeps them from drifting from the fork after the first install.

`FORGEHUB_REPO_URL` is **required** by `install.sh` too — it is what the
guest-side clone is made from. Optional `FORGEHUB_REPO_BRANCH` (default
`android`) selects which branch to track; both should normally match
whatever you exported in the Bootstrap step above.

The built frontend is already committed at `packaging/android/dist/` (see
above), so provisioning normally finds it. If it is ever missing on some
checkout anyway, provisioning still succeeds and warns rather than failing:
the backend's API is fully usable without the built frontend, only `/` has
nothing to serve yet.

`guest-provision.sh` is the part Task 2's `tests/_arm64.sh` container can
exercise directly (no Termux/proot-distro involved); `install.sh`'s own
guard clauses can only be smoke-checked the same way — see
`tests/test_install_idempotent.sh` and `tests/test_ffmpeg_required.sh`.

### A note on the guest's Ubuntu version and the dependency lock

`install.sh` runs `proot-distro install ubuntu`. `"ubuntu"` is a
proot-distro **alias**, not a version pin — at the time this was written it
resolves to Ubuntu 24.04, which is exactly what
`packaging/android/requirements.lock.txt` was generated against (see that
file's own header: `Ubuntu 24.04.5 LTS` / `Python 3.12.3`), and every pin in
it is a `cp312` wheel. proot-distro can move this alias forward to a newer
LTS release at any time, and offers no `ubuntu-24.04`-style alias that stays
pinned to a specific release forever — so the guest's Python version and
this lock file are coupled, and nothing enforces that coupling except a
runtime check.

If that alias ever moves, `guest-provision.sh` catches the mismatch loudly:
it `apt-get install`s only `python3` first, checks its version before
installing anything else, and FATALs with both version numbers rather than
letting `pip install` fail deep in a confusing "no matching distribution"
error. If you see that FATAL, the fix is to regenerate the lock against the
new guest:

```bash
bash packaging/android/verify-aarch64-deps.sh --freeze
```

then commit the regenerated `requirements.lock.txt` and re-run
`install.sh`.

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
external `kill`. (That `~/ForgeHub` is the **guest-side** checkout, evaluated
inside the `proot-distro login` session — a different filesystem from the
Termux-side `~/ForgeHub` the Bootstrap step above created; see that
section.) It also refuses to start a second instance if `/config` already
answers on the same port, and points `FORGEHUB_FRONTEND_DIR` at
`packaging/android/dist` when that directory exists (see above) — never
failing to start just because the frontend build hasn't landed yet.

The backend binds `127.0.0.1:8484` **only**. There is no authentication of
any kind on the phone, and the Runpod API key lives in `data/settings.json`
— a backend reachable from the local Wi-Fi would hand that key to anyone on
the same network. `tests/test_backend_liveness.sh` asserts this with `ss`
(socket present on `127.0.0.1:8484`, absent on `0.0.0.0:8484`); the script
checks it again itself, best-effort, right after starting.

`start-backend.sh` also sets `FORGEHUB_CORS_ORIGINS=http://127.0.0.1:8484`
(the GUI's own origin) when launching uvicorn, because upstream's own
default is `*` combined with `allow_credentials=True` — permissive enough
that any web page open in any browser on the phone, not just this app's
WebView, could read `/settings` (the Runpod API key) and spend GPU credits
via `/execute`. `tests/test_backend_liveness.sh` asserts the running
backend does not echo back a foreign `Origin` header (nor answer with a
bare `*`).

`termux-wake-lock` / `termux-notification` / `proot-distro` are Termux-only
and do not exist in a plain container. Set `FORGEHUB_NO_TERMUX=1` to skip
them explicitly (the script says plainly which calls it skipped — it never
pretends to have taken a wake-lock or raised a notification it did not) and
run the guest's own venv directly instead of through `proot-distro login`.
This is the escape hatch `tests/test_backend_liveness.sh` uses to exercise
everything else — the real backend start, the second-instance guard, the
local-only bind, the cleanup trap — inside `tests/_arm64.sh`'s container.

## Autostart on boot: Termux:Boot

`boot/start-forgehub.sh` is a one-line Termux:Boot entry point that `exec`s
`start-backend.sh` from the **Termux-side checkout** (`$HOME/ForgeHub`, the
one from the Bootstrap step above — not the guest-side one), so the backend
comes up automatically after a reboot without the owner opening Termux.
Because it delegates to that checkout live rather than embedding any logic
of its own, re-running `install.sh` to update later (see "Installing on the
phone" above) also keeps this entry point current automatically — only the
one-line delegation below ever needs to be re-copied, and that only if this
file's own content changes in a future update, not on every fork update.

Two manual, one-time steps are required for this to work at all — there is
no way to script around either:

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
