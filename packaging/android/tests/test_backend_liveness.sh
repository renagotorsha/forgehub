#!/usr/bin/env bash
# TDD step 1 from Task 4's brief: proves start-backend.sh actually brings the
# backend up, refuses a second instance, and -- the single most important
# assertion in this task (controller ruling 2) -- binds 127.0.0.1:8484 ONLY.
# The phone has no authentication of any kind and the Runpod API key lives
# in its settings, so "something answers" is not enough: this test must also
# prove nothing is reachable from 0.0.0.0, or a backend quietly reachable
# over the same Wi-Fi would hand that key to anyone on it.
#
# Cheap to run RED: before start-backend.sh exists, this fails on a plain
# file-existence check, before docker is ever invoked -- same shape as
# tests/test_install_idempotent.sh and tests/test_ffmpeg_required.sh.
# Expensive to run GREEN: the actual proof provisions a guest (reusing
# guest-provision.sh, same as test_install_idempotent.sh) and then drives
# start-backend.sh for real, inside `docker run --platform linux/arm64
# ubuntu:24.04` via tests/_arm64.sh -- the one shared container entry point
# every test in this suite goes through.
#
# termux-wake-lock / termux-notification do not exist outside Termux, and
# neither does proot-distro inside this plain-ubuntu container -- so this
# test passes FORGEHUB_NO_TERMUX=1 to start-backend.sh, which is documented
# there as the exact escape hatch for this situation: it skips every
# termux-* call (honestly, not pretending to acquire anything) and skips the
# proot-distro wrapper, running the guest's own venv/uvicorn directly in the
# container -- which already stands in for "inside the guest" the same way
# test_install_idempotent.sh's container does.
#
# Usage: bash packaging/android/tests/test_backend_liveness.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd "${HERE}/.." && pwd)"
ARM64="${HERE}/_arm64.sh"
START_BACKEND="${ANDROID_DIR}/start-backend.sh"
INNER="${HERE}/_backend_liveness_inner.sh"

# Same default as test_install_idempotent.sh, for the same reason: without a
# wheelhouse this test still passes, but by hitting PyPI over emulated qemu
# networking instead of a local --find-links install -- slow, not wrong. An
# explicit FORGEHUB_WHEELHOUSE from the caller always wins over this default.
DEFAULT_WHEELHOUSE="/home/deploy/forgehub-wheelhouse-arm64"
if [[ -z "${FORGEHUB_WHEELHOUSE:-}" ]]; then
  if [[ -d "${DEFAULT_WHEELHOUSE}" ]]; then
    echo "== test-backend-liveness: FORGEHUB_WHEELHOUSE not set -- defaulting to ${DEFAULT_WHEELHOUSE} =="
    export FORGEHUB_WHEELHOUSE="${DEFAULT_WHEELHOUSE}"
  else
    echo "WARNING: FORGEHUB_WHEELHOUSE is not set and the default wheelhouse" >&2
    echo "WARNING: (${DEFAULT_WHEELHOUSE}) does not exist on this host. This run will" >&2
    echo "WARNING: provision the guest over the network instead of from a local" >&2
    echo "WARNING: wheelhouse -- slower, but not a correctness problem for this test." >&2
  fi
fi

echo "== test-backend-liveness: start-backend.sh must exist and be valid bash =="
if [[ ! -f "${START_BACKEND}" ]]; then
  echo "FAIL -- ${START_BACKEND} does not exist yet" >&2
  exit 1
fi
bash -n "${START_BACKEND}"

echo "== test-backend-liveness: inner script must exist and be valid bash =="
if [[ ! -f "${INNER}" ]]; then
  echo "FAIL -- ${INNER} does not exist yet" >&2
  exit 1
fi
bash -n "${INNER}"
echo "ok   -- start-backend.sh and the test's inner script are syntactically valid bash"

echo "== test-backend-liveness: running start-backend.sh for real inside the arm64 container =="
"${ARM64}" env \
  FORGEHUB_REPO_URL=file:///workspace \
  FORGEHUB_REPO_BRANCH=android \
  bash /workspace/packaging/android/tests/_backend_liveness_inner.sh

echo "test-backend-liveness: PASSED"
