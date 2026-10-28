#!/usr/bin/env bash
# Starts ForgeHub's backend bound to 127.0.0.1:8484 ONLY, wrapped with what a
# phone needs that a desktop Linux box doesn't:
#
#   - a Termux wake-lock, so Android's power manager doesn't suspend the
#     proot guest's CPU the moment the screen turns off mid-generation --
#     that's the whole difference between a working app and one that
#     silently loses jobs (see Review Focus 2 in the plan)
#   - a persistent, ongoing termux-notification with a Stop button, Termux's
#     user-space stand-in for a foreground-service indicator, so there is a
#     visible, one-tap way to end the backend
#   - a refusal to start a second instance if one is already answering
#     /config on the same port
#
# Controller ruling 2 (the one that matters most here): the backend must be
# provably reachable ONLY on 127.0.0.1:8484, never on 0.0.0.0:8484. The
# phone has no authentication of any kind and the Runpod API key lives in
# its settings -- a backend reachable from the local Wi-Fi would hand that
# key to anyone on the same network. tests/test_backend_liveness.sh asserts
# this from the outside with `ss`; this script also checks it itself,
# best-effort, right after starting (search for "ss -ltnp" below), so a
# misconfiguration is caught at the source, not only by a separate test.
#
# Every exit path -- normal exit, the notification's Stop button (which
# kills the uvicorn process via BACKEND_PKILL_PATTERN below), Ctrl-C, or an
# external `kill` -- goes through cleanup(), trapped on EXIT/INT/TERM and
# made idempotent (CLEANED_UP guard) so it is safe to run more than once. It
# releases the wake-lock and dismisses the notification UNCONDITIONALLY
# relative to how the script exits, but only for resources this run actually
# acquired (WAKE_LOCK_ACQUIRED / NOTIFICATION_RAISED flags) -- a wake-lock
# left held after this script dies drains the phone's battery silently,
# which is treated as seriously as the backend silently going unreachable.
#
# termux-wake-lock / termux-notification / termux-notification-remove /
# termux-wake-unlock are Termux:API shell commands -- they do not exist
# outside Termux, and there is nothing to install or fake in a plain Linux
# container to get them. proot-distro is Termux-only for the same reason.
# Set FORGEHUB_NO_TERMUX=1 to skip BOTH explicitly: every termux-* call is
# skipped with a logged line saying so (never pretending one was taken), and
# the backend is started directly in the current environment instead of
# through `proot-distro login` -- which is exactly what
# tests/test_backend_liveness.sh does inside tests/_arm64.sh's plain
# ubuntu:24.04 container, the same guest-equivalent stand-in Task 3's tests
# already use (no termux/proot layer there either).
#
# Required environment: none -- every value below has a default.
# Optional environment:
#   FORGEHUB_NO_TERMUX   1 to skip termux-wake-lock/termux-notification and
#                        proot-distro (see above). Unset/0 means "really
#                        running under Termux" and is checked against $PREFIX
#                        the same way install.sh does.
#   FORGEHUB_REPO_DIR    Where the fork is checked out. Default: ~/ForgeHub,
#                        matching guest-provision.sh's REPO_DIR -- inside the
#                        guest under normal Termux use (proot-distro logs in
#                        as root by default, so this is the GUEST's $HOME,
#                        conventionally /root -- the same assumption
#                        tests/_install_idempotent_inner.sh already makes),
#                        or directly under the current $HOME when
#                        FORGEHUB_NO_TERMUX=1.
#   FORGEHUB_HOST        Bind host. Default 127.0.0.1. Changing this away
#                        from 127.0.0.1 on a real phone defeats controller
#                        ruling 2 -- don't.
#   FORGEHUB_PORT        Bind port. Default 8484.
#   FORGEHUB_CORS_ORIGINS  CORS origin the backend will accept. Default
#                        http://127.0.0.1:${PORT} -- the exact origin that
#                        serves the GUI, same-origin from the WebView's own
#                        point of view. Upstream's own default
#                        (forgehub_backend/config.py:21) is "*", and
#                        main.py:66-70 pairs that with
#                        allow_credentials=True -- the combination that lets
#                        ANY web page the phone's browser opens read
#                        /settings (the Runpod API key) and spend GPU
#                        credits via /execute, see the longer note at the
#                        launch section below. Overridable for anyone who
#                        genuinely needs a different origin, but never leave
#                        it unset: an unset value falls through to
#                        upstream's "*", silently reopening the hole.
set -euo pipefail

HOST="${FORGEHUB_HOST:-127.0.0.1}"
PORT="${FORGEHUB_PORT:-8484}"
BACKEND_URL="http://${HOST}:${PORT}/config"
NOTIFICATION_ID="forgehub-backend"
NO_TERMUX="${FORGEHUB_NO_TERMUX:-0}"
# One pattern, used from three places (cleanup's pkill, the notification's
# Stop button, and the FATAL message for an already-running instance) so
# they can't drift apart into matching different processes.
BACKEND_PKILL_PATTERN='uvicorn forgehub_backend\.main:app'

echo "== start-backend.sh: starting (host=${HOST} port=${PORT} FORGEHUB_NO_TERMUX=${NO_TERMUX}) =="

if [[ "${NO_TERMUX}" != "1" && -z "${PREFIX:-}" ]]; then
  echo "FATAL: \$PREFIX is not set and FORGEHUB_NO_TERMUX is not 1 -- this does not" >&2
  echo "FATAL: look like Termux. Run this from inside the Termux app on the phone, or" >&2
  echo "FATAL: set FORGEHUB_NO_TERMUX=1 if you are deliberately testing outside it" >&2
  echo "FATAL: (e.g. tests/test_backend_liveness.sh's container)." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "FATAL: 'curl' is not on PATH -- it is a hard dependency of this script's" >&2
  echo "FATAL: second-instance guard (controller ruling 4: refuse rather than race a" >&2
  echo "FATAL: second uvicorn onto the same socket). Install it first:" >&2
  if [[ "${NO_TERMUX}" == "1" ]]; then
    echo "FATAL:   apt-get install -y curl" >&2
  else
    echo "FATAL:   pkg install curl" >&2
  fi
  exit 1
fi

echo "-- checking whether a backend is already answering ${BACKEND_URL} --"
if curl -fsS "${BACKEND_URL}" >/dev/null 2>&1; then
  echo "FATAL: ${BACKEND_URL} already answers -- refusing to start a second instance" >&2
  echo "FATAL: on the same port. Stop the existing one first (the notification's Stop" >&2
  echo "FATAL: button, or 'pkill -f \"${BACKEND_PKILL_PATTERN}\"')." >&2
  exit 1
fi
echo "-- nothing answering yet -- safe to start --"

# --- cleanup: registered BEFORE anything is acquired, so even an early
# FATAL below goes through the same idempotent path. Flags start at 0/unset
# so cleanup only releases what this run actually took. ---
WAKE_LOCK_ACQUIRED=0
NOTIFICATION_RAISED=0
BACKEND_PID=""
CLEANED_UP=0

cleanup() {
  [[ "${CLEANED_UP}" -eq 1 ]] && return
  CLEANED_UP=1
  echo "== start-backend.sh: cleaning up =="

  # Kill by command-line pattern, not just the captured PID: on a real phone
  # BACKEND_PID is proot-distro's own wrapper process, and proot provides no
  # PID-namespace isolation (same real kernel, no container boundary), so
  # the actual uvicorn process is a separate, visible PID that a plain `kill
  # $BACKEND_PID` would orphan still bound to the port. pkill -f reaches it
  # (and any proot/proot-distro layers whose own argv also names the
  # command) regardless of how deep it's nested. Also what the
  # notification's Stop button runs (BACKEND_PKILL_PATTERN, same string) --
  # one termination path, used from two places.
  pkill -f "${BACKEND_PKILL_PATTERN}" 2>/dev/null || true
  if [[ -n "${BACKEND_PID}" ]] && kill -0 "${BACKEND_PID}" 2>/dev/null; then
    sleep 1
    kill -KILL "${BACKEND_PID}" 2>/dev/null || true
  fi
  if [[ -n "${BACKEND_PID}" ]]; then
    wait "${BACKEND_PID}" 2>/dev/null || true
  fi

  if [[ "${NOTIFICATION_RAISED}" -eq 1 ]]; then
    echo "-- dismissing termux-notification (id=${NOTIFICATION_ID}) --"
    termux-notification-remove "${NOTIFICATION_ID}" 2>/dev/null || true
  fi
  if [[ "${WAKE_LOCK_ACQUIRED}" -eq 1 ]]; then
    echo "-- releasing termux-wake-lock --"
    termux-wake-unlock 2>/dev/null || true
  fi
  echo "== start-backend.sh: cleanup done =="
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# --- locate the provisioned guest / venv ---
if [[ "${NO_TERMUX}" == "1" ]]; then
  REPO_DIR_HOST_VIEW="${FORGEHUB_REPO_DIR:-${HOME}/ForgeHub}"
else
  # proot-distro's own layout for an installed guest (same path install.sh
  # computes as GUEST_ROOTFS). The guest's root filesystem is a plain
  # directory on the Termux side, so it can be inspected directly without
  # entering proot -- used here only for existence checks/better error
  # messages before we ever try to launch anything through proot-distro.
  # proot-distro logs in as root by default, so the guest's own $HOME is
  # /root -- the same assumption tests/_install_idempotent_inner.sh makes.
  GUEST_ROOTFS="${PREFIX}/var/lib/proot-distro/installed-rootfs/ubuntu"
  REPO_DIR_HOST_VIEW="${GUEST_ROOTFS}/root/ForgeHub"
fi

VENV_UVICORN="${REPO_DIR_HOST_VIEW}/.venv/bin/uvicorn"
if [[ ! -x "${VENV_UVICORN}" ]]; then
  echo "FATAL: ${VENV_UVICORN} not found or not executable -- the guest does not look" >&2
  echo "FATAL: provisioned yet. Run install.sh (or guest-provision.sh directly) first." >&2
  exit 1
fi
echo "-- found provisioned venv at ${REPO_DIR_HOST_VIEW}/.venv --"

# --- controller ruling 1: FORGEHUB_FRONTEND_DIR is this script's job ---
FRONTEND_DIST_HOST_VIEW="${REPO_DIR_HOST_VIEW}/packaging/android/dist"
if [[ -d "${FRONTEND_DIST_HOST_VIEW}" ]]; then
  FRONTEND_ENV_ASSIGNMENT='FORGEHUB_FRONTEND_DIR="${HOME}/ForgeHub/packaging/android/dist" '
  echo "-- ${FRONTEND_DIST_HOST_VIEW} exists -- the GUI will be served at '/' --"
else
  FRONTEND_ENV_ASSIGNMENT=''
  echo "NOTE: ${FRONTEND_DIST_HOST_VIEW} does not exist yet (Task 6 commits it)." >&2
  echo "NOTE: starting WITHOUT a GUI at '/' -- the backend's API is fully usable" >&2
  echo "NOTE: without it; this is deliberate, not a failure." >&2
fi

# --- security fix: FORGEHUB_CORS_ORIGINS must never fall through to
# upstream's default. forgehub_backend/config.py:21 defaults
# FORGEHUB_CORS_ORIGINS to "*" when unset, and main.py:66-70 wires that
# straight into CORSMiddleware with allow_credentials=True, allow_methods=
# ["*"], allow_headers=["*"]. allow_origins="*" + allow_credentials=True is
# exactly what a browser's CORS check is for preventing: with it, any web
# page open in any browser on this phone -- not just this app's own
# WebView -- can fetch http://127.0.0.1:${PORT}/settings with credentials
# and have the response (including the Runpod API key) handed back to the
# page's own JavaScript, then POST /execute to spend the owner's GPU
# credits. A browser would normally block exactly this by same-origin
# policy; permissive CORS is what defeats that protection, same shape as
# the Wi-Fi exposure controller ruling 2 above closes for the network
# layer -- this closes the equivalent hole for the browser layer. The GUI
# itself is served same-origin by this very backend (src/api.ts defaults
# to relative URLs; the WebView loads http://127.0.0.1:${PORT} directly),
# so http://127.0.0.1:${PORT} is the one legitimate origin -- not "*", and
# not something derived from $HOST, since the GUI is always loaded at the
# literal loopback address regardless of what this script binds to. This
# assignment, set unconditionally below, is the ONLY thing standing
# between upstream's permissive default and this exposure -- do not
# "simplify" it away by leaving FORGEHUB_CORS_ORIGINS unset.
CORS_ORIGINS="${FORGEHUB_CORS_ORIGINS:-http://127.0.0.1:${PORT}}"
echo "-- FORGEHUB_CORS_ORIGINS=${CORS_ORIGINS} (never '*' -- see comment above) --"

# --- controller ruling 3: acquire the wake-lock, honestly ---
if [[ "${NO_TERMUX}" == "1" ]]; then
  echo "-- FORGEHUB_NO_TERMUX=1 -- skipping termux-wake-lock (NOT acquired; this run" \
       "cannot and does not claim to keep the CPU awake on screen-off) --"
else
  echo "-- termux-wake-lock --"
  if termux-wake-lock; then
    WAKE_LOCK_ACQUIRED=1
    echo "-- wake-lock acquired --"
  else
    echo "WARNING: termux-wake-lock failed (rc=$?) -- is Termux:API installed and" >&2
    echo "WARNING: granted? Continuing WITHOUT a wake-lock: the backend will start, but" >&2
    echo "WARNING: Android may suspend it on screen-off and lose an in-progress job." >&2
  fi
fi

# --- controller ruling 3: raise the persistent notification, honestly ---
if [[ "${NO_TERMUX}" == "1" ]]; then
  echo "-- FORGEHUB_NO_TERMUX=1 -- skipping termux-notification (NOT raised) --"
else
  echo "-- termux-notification (ongoing, with a Stop action) --"
  if termux-notification \
      --id "${NOTIFICATION_ID}" \
      --title "ForgeHub backend" \
      --content "Running on 127.0.0.1:${PORT} -- tap Stop to shut it down" \
      --ongoing \
      --button1 "Stop" \
      --button1-action "pkill -f '${BACKEND_PKILL_PATTERN}'"; then
    NOTIFICATION_RAISED=1
    echo "-- notification raised (id=${NOTIFICATION_ID}) --"
  else
    echo "WARNING: termux-notification failed (rc=$?) -- is Termux:API installed and" >&2
    echo "WARNING: granted? Continuing WITHOUT a visible Stop button; use" >&2
    echo "WARNING: 'pkill -f \"${BACKEND_PKILL_PATTERN}\"' to stop the backend." >&2
  fi
fi

# --- launch ---
# Mirrors install.sh's own documented NEXT_CMD exactly (see install.sh's
# final echo block, which explicitly says "Task 4 adds start-backend.sh,
# which wraps this same command"): cd into the repo so the backend's
# relative defaults (data/settings.json, data/storage) resolve against it,
# and set FORGEHUB_WORKFLOW_DIR because its own default is a hardcoded
# container path (/workspace/workflows, see config.py) that does not exist
# on the phone. `exec` replaces the guest's login shell with uvicorn itself,
# so `pkill -f 'uvicorn forgehub_backend.main:app'` (cleanup, and the
# notification's Stop button) finds the real process directly instead of a
# shell wrapping it. The uvicorn invocation itself -- the console-script at
# .venv/bin/uvicorn, module path, --host/--port -- matches the plan's Step 3
# verbatim; only the surrounding cd/env/exec is this script's addition
# (FORGEHUB_CORS_ORIGINS=${CORS_ORIGINS} included -- see the security-fix
# comment above CORS_ORIGINS's assignment for why that one is non-optional),
# and it is unconditional so both the proot-distro and FORGEHUB_NO_TERMUX=1
# paths below share one definition instead of two copies that can drift.
GUEST_CMD="cd \"\${HOME}/ForgeHub\" && FORGEHUB_WORKFLOW_DIR=\"\${HOME}/ForgeHub/workflows\" FORGEHUB_CORS_ORIGINS=\"${CORS_ORIGINS}\" ${FRONTEND_ENV_ASSIGNMENT}exec .venv/bin/uvicorn forgehub_backend.main:app --host ${HOST} --port ${PORT}"

if [[ "${NO_TERMUX}" == "1" ]]; then
  echo "-- FORGEHUB_NO_TERMUX=1 -- running the guest command directly (no proot-distro) --"
  bash -lc "${GUEST_CMD}" &
else
  echo "-- proot-distro login ubuntu -- .venv/bin/uvicorn forgehub_backend.main:app --host ${HOST} --port ${PORT} --"
  proot-distro login ubuntu -- bash -lc "${GUEST_CMD}" &
fi
BACKEND_PID=$!
echo "-- backend launcher started as pid ${BACKEND_PID} --"

# --- confirm it actually came up before saying so anywhere (notification
# text above already says "Running" optimistically -- this is what makes
# that claim true, or kills the attempt if it never materializes) ---
echo "-- polling ${BACKEND_URL} for up to 60s --"
UP=0
for _ in $(seq 1 60); do
  if curl -fsS "${BACKEND_URL}" >/dev/null 2>&1; then
    UP=1
    break
  fi
  if ! kill -0 "${BACKEND_PID}" 2>/dev/null; then
    echo "FATAL: the backend launcher (pid ${BACKEND_PID}) exited before ${BACKEND_URL}" >&2
    echo "FATAL: ever answered -- it did not start successfully." >&2
    exit 1
  fi
  sleep 1
done
if [[ "${UP}" -ne 1 ]]; then
  echo "FATAL: ${BACKEND_URL} never answered within 60s -- refusing to report success." >&2
  exit 1
fi
echo "-- ${BACKEND_URL} answers -- checking the bind before calling this a success --"

# --- controller ruling 2, enforced here too, not only by the external test:
# best-effort, because `ss` (iproute2) is guaranteed inside the guest
# (guest-provision.sh installs it specifically for this) but NOT guaranteed
# in Termux proper, which this script normally runs from. Absence of the
# tool is not treated as absence of the problem -- it is reported plainly
# and the script does not claim to have verified what it could not. ---
if command -v ss >/dev/null 2>&1; then
  SS_OUTPUT="$(ss -ltnp 2>/dev/null || true)"
  if grep -q "0\.0\.0\.0:${PORT}" <<<"${SS_OUTPUT}"; then
    echo "FATAL: ${PORT} is listening on 0.0.0.0, not just 127.0.0.1 -- this would be" >&2
    echo "FATAL: reachable from the local Wi-Fi, exposing the Runpod API key in" >&2
    echo "FATAL: settings to anyone on the same network. Shutting the backend down" >&2
    echo "FATAL: rather than reporting success." >&2
    exit 1
  fi
  if grep -q "127\.0\.0\.1:${PORT}" <<<"${SS_OUTPUT}"; then
    echo "-- confirmed via 'ss -ltnp': bind is 127.0.0.1:${PORT} only --"
  else
    echo "WARNING: 'ss -ltnp' did not show 127.0.0.1:${PORT} even though ${BACKEND_URL}" >&2
    echo "WARNING: answered -- unexpected, but not treated as fatal since the HTTP" >&2
    echo "WARNING: probe above is the primary liveness signal." >&2
  fi
else
  echo "NOTE: 'ss' is not on PATH -- cannot independently verify the bind is" >&2
  echo "NOTE: 127.0.0.1-only from here. This is expected in plain Termux (iproute2 is" >&2
  echo "NOTE: only guaranteed inside the guest); the backend was still started with" >&2
  echo "NOTE: --host ${HOST}, which is the actual control, and the project's" >&2
  echo "NOTE: tests/test_backend_liveness.sh verifies the bind independently." >&2
fi

echo "-- backend is up: ${BACKEND_URL} answers --"
echo "== start-backend.sh: running (pid ${BACKEND_PID}) -- Ctrl-C or the notification's Stop button to end =="
set +e
wait "${BACKEND_PID}"
BACKEND_RC=$?
set -e
echo "== start-backend.sh: backend process exited (rc=${BACKEND_RC}) =="
exit "${BACKEND_RC}"
