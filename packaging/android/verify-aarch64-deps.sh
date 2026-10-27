#!/usr/bin/env bash
# Proves (or kills) the central bet behind running ForgeHub's backend on an
# Android phone under Termux + proot-distro Ubuntu: that pydantic-core
# (Rust), aiohttp, Pillow and numpy install and import from standard
# aarch64 wheels on an ordinary aarch64 Linux -- no backend rewrite needed.
#
# Runs for real inside `docker run --platform linux/arm64 ubuntu:24.04`
# (via tests/_arm64.sh), not just metadata-checked from the x86_64 host, so
# a pass here is evidence, not a guess.
#
# Usage (run from anywhere -- paths are self-locating):
#   bash packaging/android/verify-aarch64-deps.sh            # resolve mode
#   bash packaging/android/verify-aarch64-deps.sh --freeze   # resolve + write requirements.lock.txt
#   bash packaging/android/verify-aarch64-deps.sh --lock     # verify strictly from requirements.lock.txt
#
# Make a run cheap first (strongly recommended -- see the wheelhouse note in
# tests/_arm64.sh for why): fetch the aarch64 wheels on the *host*, where
# pip's TLS path runs natively, then hand them to the container. Measured on
# this host: 43 wheels in 11 seconds natively versus ~1 hour of emulated
# downloads crawling at 20-25 kB/s. The host only *fetches* wheels; the pins
# still come from what actually installs inside the container.
#
#   WH=/home/deploy/forgehub-wheelhouse-arm64
#   grep -viE '^forgehub[_-]backend([[:space:]=@]|$)' \
#     packaging/android/requirements.lock.txt > /tmp/lock-for-download.txt
#   .venv/bin/pip download --only-binary=:all: \
#     --platform manylinux2014_aarch64 --platform manylinux_2_17_aarch64 \
#     --platform manylinux_2_28_aarch64 --platform manylinux_2_31_aarch64 \
#     --platform manylinux_2_34_aarch64 \
#     --python-version 3.12 -d "$WH" -r /tmp/lock-for-download.txt
#   # build backend too: wheelhouse mode takes pip fully offline, and
#   # `pip install .` resolves pyproject.toml's build-system requires
#   # (setuptools>=68) through the same finder.
#   .venv/bin/pip download --only-binary=:all: --python-version 3.12 \
#     --platform manylinux2014_aarch64 -d "$WH" 'setuptools>=68' wheel
#   FORGEHUB_WHEELHOUSE="$WH" bash packaging/android/verify-aarch64-deps.sh --lock
#
# Keep the wheelhouse directory outside the repo: the container tar-copies
# the checkout, so a 61 MB wheelhouse inside it would be copied on every
# run for nothing. Note the chicken-and-egg -- the wheelhouse is seeded
# *from* an existing lock, so the very first resolve/freeze of a new
# dependency set has to pay for the slow emulated downloads once; every
# later re-verification is cheap.
#
# Resolve mode installs the project fresh (pinned to pyproject.toml's own
# floors -- see MAIN_DEPS/DEV_DEPS below), letting pip pick exact versions.
# Use this to discover what needs pinning or omitting.
#
# Freeze mode does exactly what resolve mode does, then -- only once the
# imports/ffmpeg/pytest assertions below have already passed for real --
# emits `pip freeze` wrapped in marker lines so the host side (this same
# script, re-invoked without FORGEHUB_ARM64_INSIDE set) can lift it out of
# the container's stdout and write packaging/android/requirements.lock.txt.
# This has to happen this way round because tests/_arm64.sh's mount is
# read-only: nothing inside the container can write requirements.lock.txt
# back to the repo directly.
#
# Lock mode installs strictly from requirements.lock.txt plus the project
# itself with --no-deps, with no fallback logic available -- this is
# exactly what Task 3 must reproduce on the phone, so it is the mode that
# gates this task.
#
# Exits non-zero unless "deps-ok", "ffmpeg-ok" both appear AND the backend
# test suite passes. A dependency that only "installs" by compiling from
# source (no wheel) is treated as a failure, not a pass: `--only-binary
# :all:` below forces every package -- not just the four named ones --
# onto wheels, because a silent sdist fallback would be a multi-minute-or-
# worse compile on real Android hardware, not the standard-wheel story
# this task exists to prove.
set -euo pipefail

MODE="resolve"
case "${1:-}" in
  --freeze) MODE="freeze" ;;
  --lock) MODE="lock" ;;
  "") ;;
  *)
    echo "usage: $(basename "$0") [--freeze|--lock]" >&2
    exit 2
    ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_FILE="${HERE}/requirements.lock.txt"
LOCK_BEGIN_MARKER="===FORGEHUB-LOCK-BEGIN==="
LOCK_END_MARKER="===FORGEHUB-LOCK-END==="

if [[ "${FORGEHUB_ARM64_INSIDE:-0}" != "1" ]]; then
  # --- Host side: confirm emulation is real, then run inside it ---
  ARM64="${HERE}/tests/_arm64.sh"

  echo "== verify-aarch64-deps: mode=${MODE} =="
  echo "-- preflight: confirming linux/arm64 emulation is real, not just requested --"
  ACTUAL_ARCH="$("${ARM64}" uname -m)"
  if [[ "${ACTUAL_ARCH}" != "aarch64" ]]; then
    echo "FATAL: container reports arch '${ACTUAL_ARCH}', expected 'aarch64'." >&2
    echo "FATAL: arm64 emulation (binfmt) is not working on this host." >&2
    echo "FATAL: refusing to silently fall back to a PyPI-metadata check --" >&2
    echo "FATAL: see Task 2 brief Step 2 for the documented fallback, and" >&2
    echo "FATAL: run it explicitly (and loudly) if emulation truly cannot be had." >&2
    exit 1
  fi
  echo "preflight ok: container genuinely runs aarch64 code (${ACTUAL_ARCH})"

  if [[ "${MODE}" == "freeze" ]]; then
    echo "-- mode=freeze: running inside the arm64 container, capturing pip freeze for the host --"
    # Deliberately not `exec`: we need to inspect the container's stdout
    # after it exits to pull the lock block out of it. `tee /dev/stderr`
    # keeps the run visible live while `$(...)` captures it for parsing.
    set +e
    RAW_OUTPUT="$("${ARM64}" env FORGEHUB_ARM64_INSIDE=1 bash /workspace/packaging/android/verify-aarch64-deps.sh --freeze | tee /dev/stderr)"
    CONTAINER_RC=$?
    set -e
    if [[ "${CONTAINER_RC}" -ne 0 ]]; then
      echo "FATAL: freeze run exited ${CONTAINER_RC} inside the container -- not writing a lock" >&2
      echo "FATAL: file from a failed run. See the transcript above for the real failure." >&2
      exit "${CONTAINER_RC}"
    fi

    if ! grep -qF "${LOCK_BEGIN_MARKER}" <<<"${RAW_OUTPUT}" || ! grep -qF "${LOCK_END_MARKER}" <<<"${RAW_OUTPUT}"; then
      echo "FATAL: container exited 0 but the lock markers are missing from its output." >&2
      echo "FATAL: a missing marker is an error, not a shrug -- refusing to write" >&2
      echo "FATAL: requirements.lock.txt from output we can't prove is complete." >&2
      exit 1
    fi

    LOCK_BODY="$(sed -n "/${LOCK_BEGIN_MARKER}/,/${LOCK_END_MARKER}/p" <<<"${RAW_OUTPUT}" | sed '1d;$d')"
    if [[ -z "${LOCK_BODY}" ]]; then
      echo "FATAL: lock markers found but the body between them is empty --" >&2
      echo "FATAL: refusing to write an empty requirements.lock.txt." >&2
      exit 1
    fi

    printf '%s\n' "${LOCK_BODY}" > "${LOCK_FILE}"
    echo "-- wrote $(grep -c . "${LOCK_FILE}") package pins to ${LOCK_FILE} --"
    exit 0
  fi

  echo "-- mode=${MODE}: re-running this script inside the arm64 container --"
  INNER_ARGS=()
  if [[ "${MODE}" == "lock" ]]; then
    INNER_ARGS+=(--lock)
  fi
  exec "${ARM64}" env FORGEHUB_ARM64_INSIDE=1 bash /workspace/packaging/android/verify-aarch64-deps.sh "${INNER_ARGS[@]}"
fi

# --- Container side: we are now actually running as aarch64 code ---
if [[ "$(uname -m)" != "aarch64" ]]; then
  echo "FATAL: FORGEHUB_ARM64_INSIDE=1 but uname -m is not aarch64 -- refusing to proceed" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
echo "-- apt-get install python3 python3-pip python3-venv ffmpeg --"
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv ffmpeg

# /workspace is mounted read-only (see tests/_arm64.sh) on purpose: a qemu
# container that could write into the host checkout is how root-owned
# build artifacts end up jammed into the repo. `pip install .` runs
# setuptools' egg_info step, which needs to write into the source tree
# it's building -- so copy to a writable path first and operate from there.
#
# Excluding .venv/, node_modules/, .git/ and .superpowers/ from the copy:
# none of them are needed to build or test the backend, but together they
# were dragging the copy up to ~507 MB (Task 1's virtualenv and the
# frontend's node_modules are the bulk of it). Under this container's
# emulated I/O that is minutes spent copying bytes nothing downstream
# reads. `tar --exclude` (not `cp -a` + a post-hoc `rm -rf`) is what
# actually skips copying them instead of copying-then-deleting.
echo "-- copying read-only /workspace to a writable /build, excluding .venv/node_modules/.git/.superpowers --"
mkdir -p /build
tar -C /workspace \
  --exclude='./.venv' \
  --exclude='./.git' \
  --exclude='./.superpowers' \
  --exclude='./forgehub-app/node_modules' \
  -cf - . | tar -C /build -xf -
cd /build
# Task 1's editable install left a stale forgehub_backend.egg-info/ in the
# real checkout (gitignored, carried over by the copy above). Scrub it so
# egg_info regenerates cleanly here instead of tripping over stale metadata.
rm -rf forgehub_backend.egg-info

python3 -m venv /opt/venv
# shellcheck disable=SC1091
source /opt/venv/bin/activate

# Wheelhouse mode: tests/_arm64.sh mounts FORGEHUB_WHEELHOUSE (a host
# directory of pre-downloaded wheels, see verify-aarch64-deps.sh's host
# side) read-only at /wheels when the caller set that env var. When present,
# every pip call below installs with `--no-index --find-links=/wheels`
# instead of hitting the network -- this is the "make a container pass
# cheap" fix: pip's HTTPS path is CPU-bound under qemu emulation, not
# network-bound, so skipping it entirely (not just caching it) is what
# turns an hour into minutes. `--only-binary=:all:` is kept either way:
# wheelhouse mode does not relax that discipline, it just changes where the
# wheels come from.
PIP_SOURCE_FLAGS=()
if [[ -d /wheels ]]; then
  echo "-- wheelhouse detected at /wheels -- installing offline via --no-index --find-links=/wheels --"
  PIP_SOURCE_FLAGS=(--no-index --find-links=/wheels)
else
  echo "-- no wheelhouse at /wheels -- installing from the network as before --"
fi

if [[ "${#PIP_SOURCE_FLAGS[@]}" -eq 0 ]]; then
  pip install --upgrade pip -q
else
  echo "-- wheelhouse mode: skipping 'pip install --upgrade pip' (no network, no need) --"
fi

# Mirrors pyproject.toml's [project.dependencies] / [project.optional-
# dependencies] dev floors exactly -- NOT read from pyproject.toml. This
# duplication exists only because pip has no "install the project's deps
# except this one" flag, and pyproject.toml/uv.lock are both off-limits to
# edit (upstream files). Listing the deps explicitly is what lets us
# implement the "omit the wheel-less package, install the project with
# --no-deps" permitted move below without touching either file. If
# pyproject.toml's dependency list ever changes, update this list too.
MAIN_DEPS=(
  "fastapi>=0.115.0"
  "uvicorn[standard]>=0.30.0"
  "pydantic>=2.9.0"
  "aiohttp>=3.10.0"
  "pillow>=10.4.0"
  "numpy>=1.26.0"
  "pyyaml>=6.0"
  "python-multipart>=0.0.12"
  "websockets>=12.0"
  "certifi>=2024.0.0"
  "imageio-ffmpeg>=0.5.1"
)
DEV_DEPS=(
  "pytest>=8.3.0"
  "pytest-asyncio>=0.24.0"
  "httpx>=0.27.0"
)
OMITTED=()
DOWNGRADED=()

if [[ "${MODE}" != "lock" ]]; then
  echo "-- attempting the straightforward install: pip install --only-binary=:all: '.[dev]' --"
  set +e
  pip install --only-binary=:all: "${PIP_SOURCE_FLAGS[@]}" '.[dev]' >/tmp/pip-full-install.log 2>&1
  FULL_INSTALL_RC=$?
  set -e
  cat /tmp/pip-full-install.log

  if [[ "${FULL_INSTALL_RC}" -eq 0 ]]; then
    echo "-- straightforward install succeeded -- no omissions or downgrades needed --"
  else
    NEEDS_IMAGEIO_OMIT=0
    NEEDS_UVICORN_PLAIN=0
    grep -qi "imageio-ffmpeg" /tmp/pip-full-install.log && NEEDS_IMAGEIO_OMIT=1
    grep -qiE "uvloop|httptools|watchfiles" /tmp/pip-full-install.log && NEEDS_UVICORN_PLAIN=1

    if [[ "${NEEDS_IMAGEIO_OMIT}" -eq 0 && "${NEEDS_UVICORN_PLAIN}" -eq 0 ]]; then
      echo "FATAL: straightforward install failed for a reason other than the two" >&2
      echo "FATAL: anticipated, permitted fallbacks (imageio-ffmpeg has no usable" >&2
      echo "FATAL: aarch64 wheel; uvicorn[standard]'s uvloop/httptools/watchfiles lack" >&2
      echo "FATAL: one). See /tmp/pip-full-install.log above for the real failure. This" >&2
      echo "FATAL: needs a human decision (pin a version / apt-get a system package /" >&2
      echo "FATAL: escalate as BLOCKED), not an automatic retry -- refusing to guess." >&2
      exit "${FULL_INSTALL_RC}"
    fi

    FILTERED_DEPS=()
    for dep in "${MAIN_DEPS[@]}"; do
      if [[ "${NEEDS_IMAGEIO_OMIT}" -eq 1 && "${dep}" == "imageio-ffmpeg"* ]]; then
        echo "-- omitting ${dep}: no usable aarch64 wheel; its bundled binary is a desktop" \
             "build that can't execute on Android anyway (ffmpeg comes from apt in the guest) --"
        OMITTED+=("${dep}")
        continue
      fi
      if [[ "${NEEDS_UVICORN_PLAIN}" -eq 1 && "${dep}" == "uvicorn[standard]"* ]]; then
        PLAIN="${dep/uvicorn\[standard\]/uvicorn}"
        echo "-- downgrading ${dep} -> ${PLAIN}: dropping the [standard] extras" \
             "(uvloop/httptools/watchfiles), which the spec explicitly allows --"
        DOWNGRADED+=("${dep} -> ${PLAIN}")
        FILTERED_DEPS+=("${PLAIN}")
        continue
      fi
      FILTERED_DEPS+=("${dep}")
    done

    echo "-- retrying with adjustments applied --"
    pip install --only-binary=:all: "${PIP_SOURCE_FLAGS[@]}" "${FILTERED_DEPS[@]}" "${DEV_DEPS[@]}"
    echo "-- installing the project itself with --no-deps (deps satisfied above already) --"
    # PIP_SOURCE_FLAGS applies here too: `pip install .` resolves
    # pyproject.toml's build-system requires (setuptools>=68) through the
    # same finder, so in wheelhouse mode that resolution must come from
    # /wheels as well -- otherwise this one call quietly reopens the slow
    # emulated network path the wheelhouse exists to avoid.
    pip install "${PIP_SOURCE_FLAGS[@]}" --no-deps .
  fi
fi

if [[ "${MODE}" == "lock" ]]; then
  echo "-- lock mode: pip install --only-binary=:all: -r packaging/android/requirements.lock.txt --"
  pip install --only-binary=:all: "${PIP_SOURCE_FLAGS[@]}" -r /build/packaging/android/requirements.lock.txt
  echo "-- lock mode: pip install --no-deps . (project itself, deps already satisfied by lock) --"
  # See the note on the same call above: build-system requires resolve
  # through the finder, so wheelhouse mode has to cover them too.
  pip install "${PIP_SOURCE_FLAGS[@]}" --no-deps .
fi

echo "-- asserting the four heavy imports plus a basic pydantic smoke check --"
python3 -c "import pydantic, aiohttp, PIL, numpy, yaml; from pydantic import BaseModel; print('deps-ok')"

echo "-- asserting ffmpeg/ffprobe (apt package, not the imageio-ffmpeg wheel) are callable --"
ffmpeg -version >/dev/null && ffprobe -version >/dev/null && echo "ffmpeg-ok"

echo "-- running the backend test suite under aarch64 (x86_64 baseline from Task 1: 33 passed) --"
PYTEST_EXIT=0
python3 -m pytest -q || PYTEST_EXIT=$?
echo "pytest exit code: ${PYTEST_EXIT}"
if [[ "${PYTEST_EXIT}" -ne 0 ]]; then
  echo "FATAL: backend test suite failed under aarch64 -- a dependency that imports fine" >&2
  echo "FATAL: but breaks the test suite is still a failure of this task's bet." >&2
  exit "${PYTEST_EXIT}"
fi

if [[ "${#OMITTED[@]}" -gt 0 ]]; then
  echo "NOTE: omitted from this run's dependency set: ${OMITTED[*]}"
fi
if [[ "${#DOWNGRADED[@]}" -gt 0 ]]; then
  echo "NOTE: downgraded in this run's dependency set: ${DOWNGRADED[*]}"
fi

echo "verify-aarch64-deps: ALL CHECKS PASSED (deps-ok, ffmpeg-ok, pytest clean) -- mode=${MODE}"

if [[ "${MODE}" == "freeze" ]]; then
  echo "-- freeze mode: emitting pip freeze between markers for the host to extract --"
  # Filter this project's own self-reference ("forgehub-backend @
  # file:///build") out of the lock before it ever reaches the host.
  # /build is this container's writable scratch copy (see the `cp`/`tar`
  # step above) -- it does not exist on the phone, and never will, so a
  # lock line pointing at it is not reproducible outside this container.
  # The project is installed separately in every mode above
  # ("pip install --no-deps ."), so it must never be a pin inside its own
  # lock file. Matches both "forgehub-backend" and "forgehub_backend"
  # (pip normalizes names, but the two npm-style separators are both seen
  # in the wild) followed by whitespace, "=", or "@" so this can't
  # accidentally eat an unrelated package whose name merely starts with
  # the same prefix.
  PROJECT_SELF_REF_PATTERN='^forgehub[_-]backend([[:space:]=@]|$)'
  FULL_FREEZE="$(pip freeze)"
  if grep -qiE "${PROJECT_SELF_REF_PATTERN}" <<<"${FULL_FREEZE}"; then
    echo "-- dropping self-reference line(s) matching '${PROJECT_SELF_REF_PATTERN}' from the lock --"
  else
    echo "FATAL: expected this project's own self-reference in 'pip freeze' output but" >&2
    echo "FATAL: found none -- the filter pattern may no longer match pip's naming, or" >&2
    echo "FATAL: the project failed to install. Either way, refusing to trust a freeze" >&2
    echo "FATAL: whose assumptions have silently stopped holding." >&2
    exit 1
  fi
  echo "${LOCK_BEGIN_MARKER}"
  grep -viE "${PROJECT_SELF_REF_PATTERN}" <<<"${FULL_FREEZE}"
  echo "${LOCK_END_MARKER}"
fi
