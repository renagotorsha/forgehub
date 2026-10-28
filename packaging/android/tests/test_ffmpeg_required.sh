#!/usr/bin/env bash
# Step 5 (Review Focus 3) from Task 3's brief: proves that when no ffmpeg
# binary is reachable at all, the backend's thumbnail endpoint fails
# legibly through the public HTTP API -- no 200 with a garbage body, no
# zero-byte or partial thumbnail left behind -- so the fix for "the phone
# might end up without a working ffmpeg" belongs in install.sh's hard
# precondition (ruling 5), not in backend source, which is off-limits.
#
# Runs for real inside `docker run --platform linux/arm64 ubuntu:24.04`
# (via _arm64.sh), driving the backend through curl against its real
# HTTP API rather than calling forgehub_backend internals directly.
#
# Lighter than test_install_idempotent.sh: no ffmpeg apt package here, so
# it skips the ~13-minute dependency closure that dominates that test's
# (and guest-provision.sh's) runtime. Set FORGEHUB_WHEELHOUSE to Task 2's
# host wheelhouse directory to also skip pip's network round-trip.
#
# Usage: bash packaging/android/tests/test_ffmpeg_required.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARM64="${HERE}/_arm64.sh"
INNER="${HERE}/_ffmpeg_required_inner.sh"

echo "== test-ffmpeg-required: inner script must exist and be valid bash =="
if [[ ! -f "${INNER}" ]]; then
  echo "FAIL -- ${INNER} does not exist yet" >&2
  exit 1
fi
bash -n "${INNER}"
echo "ok   -- inner script exists and is syntactically valid bash"

echo "== test-ffmpeg-required: driving the backend through its public API with ffmpeg absent =="
"${ARM64}" bash /workspace/packaging/android/tests/_ffmpeg_required_inner.sh

echo "test-ffmpeg-required: PASSED"
