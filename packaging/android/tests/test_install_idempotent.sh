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
# header for why); set FORGEHUB_WHEELHOUSE to Task 2's host wheelhouse
# directory to skip pip's share of that cost (apt is what remains slow).
#
# Usage: bash packaging/android/tests/test_install_idempotent.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd "${HERE}/.." && pwd)"
ARM64="${HERE}/_arm64.sh"
GUEST_PROVISION="${ANDROID_DIR}/guest-provision.sh"
INNER="${HERE}/_install_idempotent_inner.sh"

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
