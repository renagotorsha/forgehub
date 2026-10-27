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
#   # Build backend: the lock pins setuptools/wheel (see BUILD_DEPS below), so
#   # the command above already fetches them. This line only matters when
#   # bootstrapping a wheelhouse from a lock that predates those pins.
#   .venv/bin/pip download --only-binary=:all: --python-version 3.12 \
#     --platform manylinux2014_aarch64 -d "$WH" 'setuptools>=68' wheel
#   FORGEHUB_WHEELHOUSE="$WH" bash packaging/android/verify-aarch64-deps.sh --lock
#
# `--lock` is the mode to run cheaply and often; that is the one that gates
# this task. `--freeze` under a wheelhouse is refused unless you also set
# FORGEHUB_ALLOW_WHEELHOUSE_FREEZE=1, because the wheelhouse bounds what pip
# can pick and is itself seeded from the lock being regenerated -- see the
# guard on the host side below.
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

# The pytest-count gate and the permitted-fallback matcher live in a
# sourceable library because they are the two predicates a *passing* run can
# never exercise -- see the header of tests/_verify_lib.sh. They are covered
# by tests/test-verify-logic.sh, which runs on the host in under a second.
# Not optional, and not silently skippable: if the library is missing, the
# assertions it carries are missing, and a run without them proves less than
# it claims to.
VERIFY_LIB="${HERE}/tests/_verify_lib.sh"
if [[ ! -r "${VERIFY_LIB}" ]]; then
  echo "FATAL: cannot read ${VERIFY_LIB} -- it defines the pytest-count gate" >&2
  echo "FATAL: (FORGEHUB_EXPECTED_PASSED, forgehub_assert_pytest_passed) and the" >&2
  echo "FATAL: pip-failure matcher this script asserts with. Refusing to run a" >&2
  echo "FATAL: verification with its own checks absent." >&2
  exit 1
fi
# shellcheck source=tests/_verify_lib.sh
source "${VERIFY_LIB}"

if [[ "${FORGEHUB_ARM64_INSIDE:-0}" != "1" ]]; then
  # --- Host side: confirm emulation is real, then run inside it ---
  ARM64="${HERE}/tests/_arm64.sh"

  echo "== verify-aarch64-deps: mode=${MODE} =="

  # Freezing under a wheelhouse is a weaker claim than freezing against PyPI,
  # and it is weak in a way the output does not show. With /wheels mounted,
  # pip resolves `.[dev]` with --no-index --find-links=/wheels, so the only
  # versions the container can possibly choose are the ones the host already
  # downloaded -- and the host seeds the wheelhouse *from the lock being
  # regenerated*. The letter of "the pins come from inside the container"
  # still holds (the container installs them and the freeze is taken there),
  # but the result is identical by construction and carries no new
  # resolution evidence: it cannot discover that a newer pydantic-core has
  # shipped, or that a wheel has been yanked. That is fine when you are
  # re-emitting a known-good set (fixing a defect in the lock's own format,
  # say) and wrong when you are asking "what does pip pick today?", so it
  # takes an explicit opt-in rather than being the quiet default. The lock
  # header records which way it was produced either way.
  if [[ "${MODE}" == "freeze" && -n "${FORGEHUB_WHEELHOUSE:-}" \
        && "${FORGEHUB_ALLOW_WHEELHOUSE_FREEZE:-0}" != "1" ]]; then
    echo "FATAL: --freeze with FORGEHUB_WHEELHOUSE set would write a lock whose pins" >&2
    echo "FATAL: were bounded by the host's wheelhouse, which was itself seeded from" >&2
    echo "FATAL: the lock being regenerated -- a result that is identical by" >&2
    echo "FATAL: construction and proves no fresh resolution." >&2
    echo "FATAL:" >&2
    echo "FATAL: For a genuine re-resolution, unset FORGEHUB_WHEELHOUSE and pay for" >&2
    echo "FATAL: the slow emulated downloads once." >&2
    echo "FATAL: To re-emit a known-good pin set cheaply (e.g. to fix the lock's" >&2
    echo "FATAL: format or header), say so explicitly:" >&2
    echo "FATAL:   FORGEHUB_ALLOW_WHEELHOUSE_FREEZE=1 FORGEHUB_WHEELHOUSE=... $0 --freeze" >&2
    exit 1
  fi
  if [[ "${MODE}" == "freeze" && -n "${FORGEHUB_WHEELHOUSE:-}" ]]; then
    echo "-- NOTE: FORGEHUB_ALLOW_WHEELHOUSE_FREEZE=1 -- freezing against the"
    echo "-- wheelhouse. Pins are bounded by what the host downloaded; this"
    echo "-- re-emits a known-good set, it does not re-resolve against PyPI."
  fi

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
    # Count pins, not lines: the body now opens with a provenance comment
    # header (see the freeze emission at the bottom of this script), and
    # counting those as packages would overstate the lock.
    echo "-- wrote $(grep -cvE '^[[:space:]]*(#|$)' "${LOCK_FILE}") package pins to ${LOCK_FILE} --"
    if grep -q '^# WARNING: DEGRADED' "${LOCK_FILE}"; then
      echo "-- NOTE: this lock records a DEGRADED dependency set (a permitted fallback"
      echo "-- fired during the freeze). See the header comments in ${LOCK_FILE}."
    fi
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
  LOCK_WHEEL_SOURCE="host-populated wheelhouse at /wheels (--no-index --find-links)"
else
  echo "-- no wheelhouse at /wheels -- installing from the network as before --"
  LOCK_WHEEL_SOURCE="PyPI over the network"
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
# pyproject.toml declares `[build-system] requires = ["setuptools>=68"]`, so
# every `pip install .` resolves a build backend *through pip's finder* into
# a throwaway build-isolation environment. That resolution does not consult
# requirements.lock.txt and is not covered by it.
#
# On this host that was merely slow. On the phone (Task 3) it is worse:
# there is no wheelhouse there, so an isolated build would reach out to PyPI
# for an unpinned setuptools -- silently losing the fully-offline, fully
# pinned property the lock exists to provide, on the one step that installs
# the project itself. A lock that pins 41 runtime packages and then
# downloads an unpinned build backend is not a lock.
#
# So the build backend is installed explicitly, up front, from the same
# source as everything else (hence it appears in `pip freeze --all` and
# lands in the lock), and the project is then built with
# --no-build-isolation against those pinned versions. In lock mode these
# come from the lock itself; the assertion below refuses to proceed if they
# are missing from it.
BUILD_DEPS=(
  "setuptools>=68"
  "wheel"
)
OMITTED=()
DOWNGRADED=()

if [[ "${MODE}" != "lock" ]]; then
  echo "-- installing the build backend first (${BUILD_DEPS[*]}) so the project can build with --no-build-isolation --"
  pip install --only-binary=:all: "${PIP_SOURCE_FLAGS[@]}" "${BUILD_DEPS[@]}"

  echo "-- attempting the straightforward install: pip install --only-binary=:all: --no-build-isolation '.[dev]' --"
  set +e
  pip install --only-binary=:all: --no-build-isolation "${PIP_SOURCE_FLAGS[@]}" '.[dev]' >/tmp/pip-full-install.log 2>&1
  FULL_INSTALL_RC=$?
  set -e
  cat /tmp/pip-full-install.log

  if [[ "${FULL_INSTALL_RC}" -eq 0 ]]; then
    echo "-- straightforward install succeeded -- no omissions or downgrades needed --"
  else
    # A permitted fallback applies only when pip's *failure* line names the
    # package it is about. Matching the bare name anywhere in the log would
    # match "Collecting imageio-ffmpeg>=0.5.1", "Downloading uvloop-...whl"
    # and "Processing /wheels/uvloop-...whl" -- lines present in every
    # successful run -- so any failure occurring after them (a vanished
    # pydantic-core wheel, say: precisely the thing this task exists to
    # detect) would set both flags, skip the escalation below, and quietly
    # apply both permitted moves to an unrelated problem. It would also make
    # the escalation branch nearly unreachable, since it requires neither
    # name to appear in a log that normally mentions both.
    # forgehub_pip_failed_for() matches pip's failure phrasings instead;
    # tests/test-verify-logic.sh covers exactly this case.
    NEEDS_IMAGEIO_OMIT=0
    NEEDS_UVICORN_PLAIN=0
    if forgehub_pip_failed_for /tmp/pip-full-install.log 'imageio[_-]ffmpeg'; then
      NEEDS_IMAGEIO_OMIT=1
    fi
    if forgehub_pip_failed_for /tmp/pip-full-install.log 'uvloop' 'httptools' 'watchfiles'; then
      NEEDS_UVICORN_PLAIN=1
    fi

    if [[ "${NEEDS_IMAGEIO_OMIT}" -eq 0 && "${NEEDS_UVICORN_PLAIN}" -eq 0 ]]; then
      echo "FATAL: straightforward install failed for a reason other than the two" >&2
      echo "FATAL: anticipated, permitted fallbacks (imageio-ffmpeg has no usable" >&2
      echo "FATAL: aarch64 wheel; uvicorn[standard]'s uvloop/httptools/watchfiles lack" >&2
      echo "FATAL: one). Neither package is named in a 'No matching distribution found" >&2
      echo "FATAL: for' / 'Could not find a version that satisfies the requirement' line," >&2
      echo "FATAL: so neither permitted move addresses this failure." >&2
      echo "FATAL: See /tmp/pip-full-install.log above for the real failure. This" >&2
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
    echo "-- installing the project itself with --no-deps --no-build-isolation (deps satisfied above already) --"
    # PIP_SOURCE_FLAGS applies here too, and --no-build-isolation keeps the
    # build backend from being re-resolved behind our back -- see BUILD_DEPS
    # above for why that matters on the phone.
    pip install "${PIP_SOURCE_FLAGS[@]}" --no-build-isolation --no-deps .
  fi
fi

if [[ "${MODE}" == "lock" ]]; then
  LOCK_IN_CONTAINER=/build/packaging/android/requirements.lock.txt
  # The lock must carry the build backend, because the project below is
  # built with --no-build-isolation against whatever the lock installed. If
  # it does not, pip would fail with its own (correct but cryptic) missing-
  # build-dependency error; say plainly what is wrong instead. A lock
  # without this pin also means Task 3 cannot install offline on the phone.
  if ! grep -qiE '^setuptools==' "${LOCK_IN_CONTAINER}"; then
    echo "FATAL: ${LOCK_IN_CONTAINER} does not pin setuptools, but pyproject.toml's" >&2
    echo "FATAL: [build-system] requires it and the project is built here with" >&2
    echo "FATAL: --no-build-isolation so that no unpinned build backend is fetched" >&2
    echo "FATAL: from the network. Regenerate the lock with --freeze (which emits" >&2
    echo "FATAL: 'pip freeze --all' and asserts the build pins are present)." >&2
    exit 1
  fi
  echo "-- lock mode: pip install --only-binary=:all: -r packaging/android/requirements.lock.txt --"
  pip install --only-binary=:all: "${PIP_SOURCE_FLAGS[@]}" -r "${LOCK_IN_CONTAINER}"
  echo "-- lock mode: pip install --no-deps --no-build-isolation . (project itself, deps already satisfied by lock) --"
  # --no-build-isolation is what makes this step honour the lock: with
  # isolation, pip would resolve setuptools>=68 through the finder into a
  # throwaway env, i.e. off the network on the phone, regardless of what the
  # lock says. This is the exact command shape Task 3 must reproduce.
  pip install "${PIP_SOURCE_FLAGS[@]}" --no-build-isolation --no-deps .
fi

echo "-- asserting the four heavy imports plus a basic pydantic smoke check --"
python3 -c "import pydantic, aiohttp, PIL, numpy, yaml; from pydantic import BaseModel; print('deps-ok')"

echo "-- asserting ffmpeg/ffprobe (apt package, not the imageio-ffmpeg wheel) are callable --"
ffmpeg -version >/dev/null && ffprobe -version >/dev/null && echo "ffmpeg-ok"

echo "-- running the backend test suite under aarch64 (x86_64 baseline from Task 1: ${FORGEHUB_EXPECTED_PASSED} passed) --"
# Captured to a file rather than left on stdout alone, because the exit code
# is not enough to judge this run -- the summary line has to be asserted
# against the baseline. `--color=no` keeps that line free of ANSI escapes so
# the assertion matches on a plain string regardless of how the container
# was invoked.
PYTEST_EXIT=0
set +e
python3 -m pytest -q --color=no >/tmp/pytest-run.log 2>&1
PYTEST_EXIT=$?
set -e
cat /tmp/pytest-run.log
echo "pytest exit code: ${PYTEST_EXIT}"

PYTEST_SUMMARY="$(forgehub_pytest_summary_line /tmp/pytest-run.log || true)"
echo "pytest summary line: ${PYTEST_SUMMARY:-<none found>}"

if [[ "${PYTEST_EXIT}" -ne 0 ]]; then
  echo "FATAL: backend test suite failed under aarch64 -- a dependency that imports fine" >&2
  echo "FATAL: but breaks the test suite is still a failure of this task's bet." >&2
  exit "${PYTEST_EXIT}"
fi

# Exit code 0 is only a precondition, never the result. pytest exits 0 for
# "33 skipped", for "12 passed, 21 skipped", and for any collection that
# shrank without failing -- only an empty collection (exit 5) or a real
# failure would have tripped the check above. The spec's claim is that the
# aarch64 suite matches Task 1's x86_64 baseline *exactly*, and
# README.md makes "later tasks must not reduce this count" standing policy,
# so the count is the assertion. See tests/_verify_lib.sh for the reasoning
# and tests/test-verify-logic.sh for the cases.
if ! forgehub_assert_pytest_passed /tmp/pytest-run.log "${FORGEHUB_EXPECTED_PASSED}"; then
  echo "FATAL: pytest exited 0 but did not report exactly ${FORGEHUB_EXPECTED_PASSED} passed." >&2
  echo "FATAL: summary line was: ${PYTEST_SUMMARY:-<no summary line found at all>}" >&2
  echo "FATAL: a green exit code covers '${FORGEHUB_EXPECTED_PASSED} skipped' and" >&2
  echo "FATAL: '12 passed, 21 skipped' just as happily as a real pass, so the count is" >&2
  echo "FATAL: the only thing proving the arch-sensitive tests actually ran." >&2
  echo "FATAL: ${FORGEHUB_EXPECTED_PASSED} is Task 1's x86_64 baseline (see" >&2
  echo "FATAL: packaging/android/README.md). If upstream legitimately changed the suite" >&2
  echo "FATAL: size, re-record the baseline in README.md and FORGEHUB_EXPECTED_PASSED in" >&2
  echo "FATAL: tests/_verify_lib.sh together -- deliberately, in a reviewable commit." >&2
  exit 1
fi
echo "pytest count ok: ${FORGEHUB_EXPECTED_PASSED} passed, matching Task 1's x86_64 baseline exactly"

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
  # pip itself is deliberately not pinned: it is supplied by the guest's
  # venv/apt, and a lock that pins pip has `pip install -r` try to replace
  # the pip doing the installing -- for no benefit, since pip's version does
  # not affect which wheels the pins resolve to.
  PIP_ITSELF_PATTERN='^pip([[:space:]=@]|$)'
  # `--all`, not plain `pip freeze`: plain freeze suppresses setuptools and
  # wheel as "dev packages", and here they are load-bearing. pyproject.toml
  # requires setuptools>=68 to build the project, and this script now builds
  # it with --no-build-isolation precisely so that no unpinned build backend
  # gets fetched behind the lock's back -- which only works if the lock
  # pins it. See BUILD_DEPS above.
  FULL_FREEZE="$(pip freeze --all)"

  if grep -qiE "${PROJECT_SELF_REF_PATTERN}" <<<"${FULL_FREEZE}"; then
    echo "-- dropping self-reference line(s) matching '${PROJECT_SELF_REF_PATTERN}' from the lock --"
  else
    echo "FATAL: expected this project's own self-reference in 'pip freeze' output but" >&2
    echo "FATAL: found none -- the filter pattern may no longer match pip's naming, or" >&2
    echo "FATAL: the project failed to install. Either way, refusing to trust a freeze" >&2
    echo "FATAL: whose assumptions have silently stopped holding." >&2
    exit 1
  fi

  # The build pins are not optional extras -- lock mode and Task 3's phone
  # install both build the project with --no-build-isolation against them.
  # A freeze that lost them would produce a lock that cannot install the
  # project offline, which is the whole point of the artifact.
  for required_pin in setuptools wheel; do
    if ! grep -qiE "^${required_pin}==" <<<"${FULL_FREEZE}"; then
      echo "FATAL: 'pip freeze --all' does not report a ${required_pin}== pin, but the" >&2
      echo "FATAL: project is built with --no-build-isolation against it and Task 3" >&2
      echo "FATAL: needs it pinned to install offline on the phone. Refusing to write" >&2
      echo "FATAL: a lock that cannot build the project without the network." >&2
      exit 1
    fi
  done

  echo "${LOCK_BEGIN_MARKER}"
  # Provenance header. Without it the artifact says nothing about how it was
  # produced -- and in particular, a lock written from a run where a
  # permitted fallback fired (imageio-ffmpeg omitted, uvicorn[standard]
  # reduced to plain uvicorn) would reach Task 3 indistinguishable from a
  # clean one, since those NOTE lines only ever reached the transcript.
  # Comment lines are ignored by `pip install -r` and by `pip download -r`,
  # so this costs nothing at consumption time.
  echo "# ForgeHub Android aarch64 dependency lock -- GENERATED FILE, do not hand-edit."
  echo "# Regenerate with: bash packaging/android/verify-aarch64-deps.sh --freeze"
  echo "# Verify with:     bash packaging/android/verify-aarch64-deps.sh --lock"
  echo "#"
  echo "# generated:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# mode:         ${MODE}"
  echo "# container:    $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  echo "# uname -m:     $(uname -m)"
  echo "# python:       $(python3 -V 2>&1)"
  echo "# pip:          $(pip --version)"
  echo "# wheel source: ${LOCK_WHEEL_SOURCE}"
  echo "# pytest:       ${PYTEST_SUMMARY:-<none>} (baseline ${FORGEHUB_EXPECTED_PASSED} passed)"
  if [[ "${#OMITTED[@]}" -gt 0 ]]; then
    echo "# omitted:      ${OMITTED[*]}"
  else
    echo "# omitted:      (none)"
  fi
  if [[ "${#DOWNGRADED[@]}" -gt 0 ]]; then
    echo "# downgraded:   ${DOWNGRADED[*]}"
  else
    echo "# downgraded:   (none)"
  fi
  if [[ "${#OMITTED[@]}" -gt 0 || "${#DOWNGRADED[@]}" -gt 0 ]]; then
    echo "#"
    echo "# WARNING: DEGRADED DEPENDENCY SET -- a permitted fallback fired during this"
    echo "# freeze (see omitted/downgraded above). This lock does NOT represent the"
    echo "# unmodified dependency set; whoever consumes it needs to know that."
  fi
  echo "#"
  echo "# pip itself is intentionally not pinned (supplied by the guest's venv)."
  echo "# setuptools/wheel ARE pinned: the project is installed with"
  echo "# --no-build-isolation against them, so the build backend never comes"
  echo "# from an unpinned network fetch."
  grep -viE "${PROJECT_SELF_REF_PATTERN}" <<<"${FULL_FREEZE}" \
    | grep -viE "${PIP_ITSELF_PATTERN}"
  echo "${LOCK_END_MARKER}"
fi
