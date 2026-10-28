#!/usr/bin/env bash
# Runs *inside* the arm64 test container (invoked by
# test_install_idempotent.sh via _arm64.sh). Exercises guest-provision.sh
# exactly as a real phone guest would, twice in a row, and checks the three
# idempotency guarantees Task 3's brief requires of a second run:
#
#   - a pre-seeded data/settings.json sentinel (the owner's Runpod API key)
#     survives untouched
#   - ~/ForgeHub is not re-cloned into a second copy
#   - the run's own log says "already provisioned"
#
# FORGEHUB_REPO_URL must already be set by the caller. A local clone source
# (file:///workspace, the same read-only checkout _arm64.sh mounts) stands
# in for the fork's not-yet-public URL -- see controller ruling 1 in Task
# 3's brief. guest-provision.sh does not know or care that the URL is
# local; it runs the exact `git clone <url>` it would run against a real
# remote, and `git clone` only ever needs read access to its source.
set -euo pipefail

if [[ -z "${FORGEHUB_REPO_URL:-}" ]]; then
  echo "FATAL: test harness bug -- FORGEHUB_REPO_URL was not propagated into the container" >&2
  exit 1
fi

export HOME=/root
GUEST_PROVISION=/workspace/packaging/android/guest-provision.sh

# Test-harness-only workaround, not a guest-provision.sh fix: _arm64.sh
# mounts the repo read-only at /workspace, owned by the host's uid 1000
# (deploy), while this container runs as root. `git clone file:///workspace`
# reads /workspace/.git directly (the local-clone fast path) and git's own
# "dubious ownership" protection refuses that mismatch outright. On a real
# phone, guest-provision.sh clones FORGEHUB_REPO_URL over https:// from a
# real remote -- there is no local directory for git to own-check, so this
# condition cannot arise there. Teaching guest-provision.sh about
# safe.directory would mean shipping a workaround for a problem the phone
# never has; this exception lives here, in the test harness, where the
# problem actually is. git itself prints this exact remedy in the FATAL
# this works around.
#
# `git` itself is not on this bare ubuntu:24.04 image yet -- guest-
# provision.sh is what normally installs it, but that happens later, inside
# the very run this config call needs to precede. Installing it here first
# is harmless duplication: guest-provision.sh's own `apt-get install ...
# git` right after sees it already satisfied and moves on, same as any
# idempotent second install would.
apt-get update -qq
apt-get install -y -qq git
git config --global --add safe.directory /workspace/.git

echo "########## first run (fresh guest) ##########"
set +e
bash "${GUEST_PROVISION}" 2>&1 | tee /tmp/first-run.log
FIRST_RC=${PIPESTATUS[0]}
set -e
if [[ "${FIRST_RC}" -ne 0 ]]; then
  echo "FATAL: first guest-provision.sh run failed (rc=${FIRST_RC}) -- see /tmp/first-run.log above" >&2
  exit "${FIRST_RC}"
fi

SETTINGS_FILE="${HOME}/ForgeHub/data/settings.json"
mkdir -p "$(dirname "${SETTINGS_FILE}")"
printf '{"runpod_api_key": "SENTINEL-KEY-DO-NOT-CLOBBER"}' > "${SETTINGS_FILE}"
echo "-- seeded a sentinel data/settings.json between the two runs --"

echo "########## second run (re-provision on top of the same guest) ##########"
set +e
bash "${GUEST_PROVISION}" 2>&1 | tee /tmp/second-run.log
SECOND_RC=${PIPESTATUS[0]}
set -e
if [[ "${SECOND_RC}" -ne 0 ]]; then
  echo "FATAL: second guest-provision.sh run failed (rc=${SECOND_RC}) -- see /tmp/second-run.log above" >&2
  exit "${SECOND_RC}"
fi

echo "########## assertions ##########"
FAIL=0

SENTINEL_NOW="$(python3 -c "
import json
print(json.load(open('${SETTINGS_FILE}')).get('runpod_api_key', ''))
")"
if [[ "${SENTINEL_NOW}" == "SENTINEL-KEY-DO-NOT-CLOBBER" ]]; then
  echo "ok   -- data/settings.json sentinel survived the second run"
else
  echo "FAIL -- data/settings.json sentinel was clobbered: got '${SENTINEL_NOW}'" >&2
  FAIL=1
fi

# Wildcard, not the literal name: catches a re-clone landing at a sibling
# name (ForgeHub-1, ForgeHub.bak, ...) as well as a literal duplicate.
FORGEHUB_DIR_COUNT="$(find "${HOME}" -maxdepth 1 -iname 'ForgeHub*' | wc -l)"
if [[ "${FORGEHUB_DIR_COUNT}" -eq 1 ]]; then
  echo "ok   -- exactly one ~/ForgeHub directory exists"
else
  echo "FAIL -- expected exactly one ~/ForgeHub*, found ${FORGEHUB_DIR_COUNT}" >&2
  FAIL=1
fi

if grep -q "already provisioned" /tmp/second-run.log; then
  echo "ok   -- second run's log says 'already provisioned'"
else
  echo "FAIL -- second run's log never says 'already provisioned'" >&2
  FAIL=1
fi

if [[ "${FAIL}" -eq 0 ]]; then
  echo "test-install-idempotent (inner): ALL CHECKS PASSED"
else
  echo "test-install-idempotent (inner): CHECKS FAILED" >&2
fi
exit "${FAIL}"
