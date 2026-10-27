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
