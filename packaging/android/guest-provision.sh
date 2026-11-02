#!/usr/bin/env bash
# Runs *inside* the Ubuntu guest -- proot-distro on a real phone, or
# `ubuntu:24.04` under `docker run --platform linux/arm64` for testing (see
# tests/_arm64.sh and tests/test_install_idempotent.sh). Provisions
# everything the backend needs: system packages, a clone of the fork's
# branch, and a venv with the project installed strictly from
# packaging/android/requirements.lock.txt -- the same pip-install-from-lock
# command shape verify-aarch64-deps.sh's `--lock` mode proved works on this
# architecture (Task 2). The two scripts get there by different paths
# (tar-copy vs. git-clone), so this script does not just trust that a zero
# pip exit code here means the same thing it meant there -- it re-runs
# `--lock` mode's own import check (pydantic/aiohttp/PIL/numpy/yaml plus the
# project package itself) through the venv's own interpreter before
# declaring success. It does not repeat `--lock` mode's full pytest run;
# that is Task 2's job, not every phone re-provision's.
#
# Idempotent: safe to run repeatedly, e.g. to pick up a fork update. Every
# stage checks whether it already happened and skips with an
# "already provisioned" log line instead of redoing it. It never, under any
# circumstance, writes to an existing data/settings.json -- that file can
# hold the owner's Runpod API key, and a re-run must not clobber it.
#
# Required environment:
#   FORGEHUB_REPO_URL     Git URL of the fork to clone. No default: the
#                         fork is a third-party project and its URL is not
#                         yet known (see Task 3's brief, controller ruling
#                         1). install.sh does not hardcode one either --
#                         it is the owner's job to export this.
# Optional environment:
#   FORGEHUB_REPO_BRANCH  Branch to clone/track. Default: android.
#
# install.sh is the only intended caller on a real phone (it pipes this
# script's contents into `proot-distro login ubuntu -- bash -s`, so this
# file's own on-disk path -- inside the guest or outside it -- never
# matters to the logic below). Exit code is what callers should trust:
# this script must not print a success line unless every stage, including
# the ffmpeg/ffprobe hard check, actually succeeded.
set -euo pipefail

echo "== guest-provision: starting =="

if [[ -z "${FORGEHUB_REPO_URL:-}" ]]; then
  echo "FATAL: FORGEHUB_REPO_URL is not set." >&2
  echo "FATAL: this script needs the git URL of the ForgeHub fork to clone --" >&2
  echo "FATAL: it is not hardcoded because the fork's URL is not yet public." >&2
  echo "FATAL: export it and re-run, e.g.:" >&2
  echo "FATAL:   FORGEHUB_REPO_URL=https://github.com/renagotorsha/forgehub.git bash install.sh" >&2
  exit 1
fi
FORGEHUB_REPO_BRANCH="${FORGEHUB_REPO_BRANCH:-android}"

: "${HOME:?HOME must be set -- guest-provision.sh expects a normal guest login shell}"
REPO_DIR="${HOME}/ForgeHub"

# Every pin in packaging/android/requirements.lock.txt is a cp312 wheel
# (see the lock's own "# python:" header and Task 2's report). A guest on
# any other Python fails deep inside pip with a confusing "no matching
# distribution" error instead of a clear one -- so this is checked before
# anything else is installed. If requirements.lock.txt is ever
# regenerated against a different interpreter, update this to match.
REQUIRED_PYTHON_MM="3.12"

export DEBIAN_FRONTEND=noninteractive
echo "-- apt-get update --"
apt-get update -qq

echo "-- apt-get install python3 (checking the interpreter version before anything else) --"
apt-get install -y -qq python3

GUEST_PYTHON_FULL="$(python3 -c 'import sys; print(sys.version.split()[0])')"
GUEST_PYTHON_MM="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
if [[ "${GUEST_PYTHON_MM}" != "${REQUIRED_PYTHON_MM}" ]]; then
  echo "FATAL: guest Python is ${GUEST_PYTHON_FULL} (${GUEST_PYTHON_MM}.x), but" >&2
  echo "FATAL: packaging/android/requirements.lock.txt pins cp${REQUIRED_PYTHON_MM/./} wheels" >&2
  echo "FATAL: for every dependency. Every pip install below would fail with a" >&2
  echo "FATAL: confusing 'no matching distribution' error instead of this clear one." >&2
  echo "FATAL:   required: Python ${REQUIRED_PYTHON_MM}.x" >&2
  echo "FATAL:   found:    Python ${GUEST_PYTHON_FULL}" >&2
  exit 1
fi
echo "-- guest Python ${GUEST_PYTHON_FULL} matches the required ${REQUIRED_PYTHON_MM}.x --"

echo "-- apt-get install python3-venv python3-pip git ffmpeg iproute2 --"
# iproute2 (ss) is not in Ubuntu's default set; Task 4's liveness test
# needs it to confirm the backend binds 127.0.0.1 and not 0.0.0.0.
apt-get install -y -qq python3-venv python3-pip git ffmpeg iproute2

echo "-- asserting ffmpeg/ffprobe are callable (hard precondition, not a nice-to-have) --"
# forgehub_backend/files.py shells out to both for video thumbnails and
# container metadata -- that is in active use, not an edge case. A guest
# where either binary is missing or broken must never be reported as
# successfully provisioned (Task 3's controller ruling 5).
if ! ffmpeg -version >/dev/null 2>&1; then
  echo "FATAL: 'ffmpeg -version' failed after apt-get install. ffmpeg is a hard" >&2
  echo "FATAL: precondition for this backend (thumbnails, container metadata) --" >&2
  echo "FATAL: refusing to report a successful provisioning." >&2
  exit 1
fi
if ! ffprobe -version >/dev/null 2>&1; then
  echo "FATAL: 'ffprobe -version' failed after apt-get install -- same hard" >&2
  echo "FATAL: precondition as ffmpeg above. Refusing to report success." >&2
  exit 1
fi
echo "-- ffmpeg-ok, ffprobe-ok --"

echo "-- cloning/updating the fork at ${REPO_DIR} (branch ${FORGEHUB_REPO_BRANCH}) --"
if [[ -d "${REPO_DIR}/.git" ]]; then
  echo "-- ${REPO_DIR} already provisioned (git repo present) -- pulling latest --"
  git -C "${REPO_DIR}" pull --ff-only
elif [[ -e "${REPO_DIR}" ]]; then
  echo "FATAL: ${REPO_DIR} exists but is not a git repository -- refusing to" >&2
  echo "FATAL: overwrite content we don't recognize. Move it aside and re-run." >&2
  exit 1
else
  # --depth 1: this is a deploy target, not a dev checkout. The owner has
  # no use for history, and a shallow clone is lighter on whatever
  # connection the phone has. `git pull --ff-only` above still works fine
  # against a shallow clone on later runs.
  git clone --branch "${FORGEHUB_REPO_BRANCH}" --single-branch --depth 1 \
    "${FORGEHUB_REPO_URL}" "${REPO_DIR}"
fi

cd "${REPO_DIR}"
# A stale egg-info directory left by an earlier provisioning run can trip
# setuptools' egg_info step the same way Task 2 hit this on the build host
# -- scrub it defensively before installing.
rm -rf forgehub_backend.egg-info

VENV="${REPO_DIR}/.venv"
if [[ -x "${VENV}/bin/python3" ]]; then
  echo "-- venv already provisioned at ${VENV} -- skipping creation --"
else
  echo "-- creating venv at ${VENV} --"
  python3 -m venv "${VENV}"
fi

LOCK_FILE="${REPO_DIR}/packaging/android/requirements.lock.txt"
if [[ ! -r "${LOCK_FILE}" ]]; then
  echo "FATAL: ${LOCK_FILE} was not found in the cloned fork -- was Task 2's lock" >&2
  echo "FATAL: committed to the '${FORGEHUB_REPO_BRANCH}' branch?" >&2
  exit 1
fi

# /wheels only exists under tests/_arm64.sh's optional wheelhouse mount
# (see verify-aarch64-deps.sh) -- never on a real phone, where this reaches
# PyPI over the network like any ordinary first install. Kept so this
# script reproduces verify-aarch64-deps.sh's `--lock` mode exactly, which
# is the whole point of this task.
PIP_SOURCE_FLAGS=()
if [[ -d /wheels ]]; then
  echo "-- wheelhouse detected at /wheels -- installing offline via --no-index --find-links=/wheels --"
  PIP_SOURCE_FLAGS=(--no-index --find-links=/wheels)
else
  echo "-- no wheelhouse -- installing from the network --"
  "${VENV}/bin/pip" install --upgrade pip -q
fi

echo "-- pip install --only-binary=:all: -r packaging/android/requirements.lock.txt --"
"${VENV}/bin/pip" install --only-binary=:all: "${PIP_SOURCE_FLAGS[@]}" -r "${LOCK_FILE}"
echo "-- pip install --no-deps --no-build-isolation . (project itself; deps already satisfied by the lock) --"
# --no-build-isolation is what keeps this offline-safe on reruns: with
# isolation, pip would resolve pyproject.toml's `setuptools>=68` through
# its finder into a throwaway env regardless of what the lock pins -- see
# verify-aarch64-deps.sh's BUILD_DEPS comment for the full reasoning.
"${VENV}/bin/pip" install "${PIP_SOURCE_FLAGS[@]}" --no-build-isolation --no-deps .

# A zero exit from the pip installs above is necessary but not sufficient.
# verify-aarch64-deps.sh's `--lock` mode -- the thing this script's own
# header claims to reproduce -- only counts as proof because it follows the
# install with exactly this import check (plus a full pytest run this
# script is too cheap to repeat on every phone re-provision). The
# clone-then-pip-install path above is not byte-for-byte identical to that
# script's tar-copy-then-pip-install path, so without re-running the check
# here, Task 2's proof never actually transfers to this script. Importing
# through the venv's own interpreter (not system python3) is what confirms
# the venv itself -- not some unrelated system package -- satisfies these.
echo "-- verifying the installed venv actually works (import check) --"
if ! VERIFY_OUTPUT="$("${VENV}/bin/python3" -c "
import pydantic, aiohttp, PIL, numpy, yaml
from pydantic import BaseModel
import forgehub_backend
print('deps-ok')
" 2>&1)"; then
  echo "FATAL: pip install exited 0, but importing pydantic/aiohttp/PIL/numpy/" >&2
  echo "FATAL: yaml/forgehub_backend through ${VENV}/bin/python3 failed:" >&2
  echo "${VERIFY_OUTPUT}" | sed 's/^/FATAL:   /' >&2
  echo "FATAL: provisioning did NOT succeed -- refusing to report success." >&2
  exit 1
fi
echo "-- ${VERIFY_OUTPUT} -- the installed venv imports everything it needs --"

SETTINGS_FILE="${REPO_DIR}/data/settings.json"
mkdir -p "$(dirname "${SETTINGS_FILE}")"
if [[ -f "${SETTINGS_FILE}" ]]; then
  echo "-- data/settings.json already provisioned -- leaving it untouched (it may hold the owner's Runpod API key) --"
else
  echo "-- data/settings.json does not exist yet -- leaving it absent; the backend creates it on the first save from the GUI --"
fi

FRONTEND_DIST="${REPO_DIR}/packaging/android/dist"
if [[ ! -d "${FRONTEND_DIST}" ]]; then
  echo "WARNING: ${FRONTEND_DIST} does not exist yet." >&2
  echo "WARNING: Task 6 commits the built frontend there. Until it does, the" >&2
  echo "WARNING: backend will run without serving the GUI at '/' -- its API is" >&2
  echo "WARNING: fully usable without it, and this ordering is deliberate, not a bug." >&2
  echo "WARNING: once it exists, point FORGEHUB_FRONTEND_DIR at it when starting" >&2
  echo "WARNING: the backend (see start-backend.sh, Task 4)." >&2
fi

echo "== guest-provision: ForgeHub guest provisioned successfully at ${REPO_DIR} =="
