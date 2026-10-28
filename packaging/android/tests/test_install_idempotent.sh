#!/usr/bin/env bash
# TDD steps 1/2/6 from Task 3's brief: proves guest-provision.sh is
# genuinely idempotent -- a second run never re-clones ~/ForgeHub, never
# clobbers an existing data/settings.json (the owner's Runpod API key), and
# says so in its own log.
#
# Cheap to run RED: before guest-provision.sh exists, this fails on a plain
# file-existence check, before docker is ever invoked. Expensive to run
# GREEN: once guest-provision.sh exists, the actual proof runs it for real,
# twice, inside `docker run --platform linux/arm64 ubuntu:24.04` via
# _arm64.sh -- the same vehicle Task 2 used to prove the aarch64 dependency
# bet. The first of those two runs pays for ffmpeg's full apt dependency
# closure (~13 minutes under qemu emulation, see verify-aarch64-deps.sh's
# header for why); this test defaults FORGEHUB_WHEELHOUSE to Task 2's host
# wheelhouse directory (see below) to skip pip's share of that cost (apt is
# what remains slow) -- and, not just as a speed-up, that wheelhouse mount
# is also what lets this test assert the offline-install property (see
# "offline-install assertion" below); override FORGEHUB_WHEELHOUSE yourself
# to point at a different wheelhouse, or unset-and-ignore the warning to
# deliberately run fully networked.
#
# Usage: bash packaging/android/tests/test_install_idempotent.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd "${HERE}/.." && pwd)"
ARM64="${HERE}/_arm64.sh"
GUEST_PROVISION="${ANDROID_DIR}/guest-provision.sh"
INNER="${HERE}/_install_idempotent_inner.sh"

# _arm64.sh only mounts /wheels when FORGEHUB_WHEELHOUSE is already set in
# the calling shell -- left to its own devices this test would reach the
# network for every pip install and never exercise guest-provision.sh's
# `--no-index --find-links=/wheels` path (guest-provision.sh:143-150),
# silently never proving the offline-install property Task 2 established
# (zero "Downloading" lines). Default to Task 2's host wheelhouse so a
# plain invocation of this test still exercises and asserts that property;
# an explicit FORGEHUB_WHEELHOUSE from the caller always wins over this
# default.
DEFAULT_WHEELHOUSE="/home/deploy/forgehub-wheelhouse-arm64"
if [[ -z "${FORGEHUB_WHEELHOUSE:-}" ]]; then
  if [[ -d "${DEFAULT_WHEELHOUSE}" ]]; then
    echo "== test-install-idempotent: FORGEHUB_WHEELHOUSE not set -- defaulting to ${DEFAULT_WHEELHOUSE} =="
    export FORGEHUB_WHEELHOUSE="${DEFAULT_WHEELHOUSE}"
  else
    echo "WARNING: FORGEHUB_WHEELHOUSE is not set and the default wheelhouse" >&2
    echo "WARNING: (${DEFAULT_WHEELHOUSE}) does not exist on this host. This run" >&2
    echo "WARNING: CANNOT prove the offline-install property (zero network fetches" >&2
    echo "WARNING: through --no-index --find-links=/wheels) -- it will install from" >&2
    echo "WARNING: the network and the inner script will SKIP that assertion" >&2
    echo "WARNING: explicitly and loudly, not pass as though it had proven it." >&2
  fi
fi

echo "== test-install-idempotent: guest-provision.sh must exist and be valid bash =="
if [[ ! -f "${GUEST_PROVISION}" ]]; then
  echo "FAIL -- ${GUEST_PROVISION} does not exist yet" >&2
  exit 1
fi
bash -n "${GUEST_PROVISION}"
bash -n "${INNER}"
echo "ok   -- guest-provision.sh and the test's inner script are syntactically valid bash"

echo "== test-install-idempotent: running guest-provision.sh twice inside the arm64 container =="
"${ARM64}" env \
  FORGEHUB_REPO_URL=file:///workspace \
  FORGEHUB_REPO_BRANCH=android \
  bash /workspace/packaging/android/tests/_install_idempotent_inner.sh

echo "test-install-idempotent: PASSED"
