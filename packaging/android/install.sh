#!/usr/bin/env bash
# The one command the owner runs once, in Termux proper, to provision
# ForgeHub's backend inside a proot-distro Ubuntu guest.
#
# This script only knows about Termux: asserting it is running there,
# installing the handful of Termux-side packages proot-distro needs, and
# getting the guest installed. All backend provisioning (apt packages
# inside the guest, cloning the fork, the venv, the dependency lock) lives
# in guest-provision.sh, which this script runs *inside* the guest.
#
# That split exists because this file cannot be exercised end to end
# outside a real phone: $PREFIX, proot-distro and termux-api do not exist
# in a container. guest-provision.sh has no such dependency and is what
# Task 3's tests actually run (see tests/test_install_idempotent.sh, via
# tests/_arm64.sh). Keep Termux/proot-distro specifics out of
# guest-provision.sh and keep this file thin, so that split keeps paying
# off instead of rotting.
#
# Required environment:
#   FORGEHUB_REPO_URL     Git URL of the ForgeHub fork to clone. No
#                         default -- the fork's URL is not yet public (see
#                         Task 3's brief, controller ruling 1). Example:
#                           FORGEHUB_REPO_URL=https://github.com/<you>/ForgeHub.git \
#                             bash packaging/android/install.sh
# Optional environment:
#   FORGEHUB_REPO_BRANCH  Branch to clone/track. Default: android.
set -euo pipefail

echo "== install.sh: starting =="

if [[ -z "${PREFIX:-}" ]]; then
  echo "FATAL: \$PREFIX is not set -- this does not look like Termux." >&2
  echo "FATAL: install.sh must be run from inside the Termux app on the phone," >&2
  echo "FATAL: not from an SSH session, a regular Linux shell, or a container." >&2
  exit 1
fi

if [[ -z "${FORGEHUB_REPO_URL:-}" ]]; then
  echo "FATAL: FORGEHUB_REPO_URL is not set." >&2
  echo "FATAL: this needs the git URL of the ForgeHub fork to clone into the" >&2
  echo "FATAL: guest -- it is not hardcoded because the fork's URL is not yet" >&2
  echo "FATAL: public. Export it and re-run, e.g.:" >&2
  echo "FATAL:   FORGEHUB_REPO_URL=https://github.com/<you>/ForgeHub.git bash $0" >&2
  exit 1
fi
FORGEHUB_REPO_BRANCH="${FORGEHUB_REPO_BRANCH:-android}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUEST_PROVISION="${HERE}/guest-provision.sh"
if [[ ! -r "${GUEST_PROVISION}" ]]; then
  echo "FATAL: ${GUEST_PROVISION} not found next to install.sh." >&2
  echo "FATAL: both files are expected to travel together -- copy guest-provision.sh" >&2
  echo "FATAL: alongside install.sh before running it." >&2
  exit 1
fi

echo "-- pkg install termux-api proot-distro git --"
pkg install -y termux-api proot-distro git

DISTRO=ubuntu
# proot-distro's own layout for an already-installed guest. If a future
# proot-distro release moves this, `proot-distro install` below is also
# safe to attempt again -- it is this check that would start costing an
# unnecessary reinstall, not correctness.
GUEST_ROOTFS="${PREFIX}/var/lib/proot-distro/installed-rootfs/${DISTRO}"
if [[ -d "${GUEST_ROOTFS}" ]]; then
  echo "-- ${DISTRO} guest already provisioned at ${GUEST_ROOTFS} -- skipping proot-distro install --"
else
  echo "-- proot-distro install ${DISTRO} --"
  proot-distro install "${DISTRO}"
fi

echo "-- running guest-provision.sh inside the ${DISTRO} guest --"
# Piped via stdin to `bash -s` rather than referenced by path: proot-distro
# does not guarantee the Termux filesystem is bind-mounted at any
# particular path inside the guest, so handing the guest a path on the
# Termux side to go read would be a bet on an implementation detail. Stdin
# needs no such bet -- it works regardless of what is or isn't bound in.
proot-distro login "${DISTRO}" -- env \
  "FORGEHUB_REPO_URL=${FORGEHUB_REPO_URL}" \
  "FORGEHUB_REPO_BRANCH=${FORGEHUB_REPO_BRANCH}" \
  bash -s < "${GUEST_PROVISION}"

NEXT_CMD="cd ~/ForgeHub && FORGEHUB_WORKFLOW_DIR=\$HOME/ForgeHub/workflows .venv/bin/python3 -m uvicorn forgehub_backend.main:app --host 127.0.0.1 --port 8484"
echo "== install.sh: provisioning complete =="
echo
echo "Next, start the backend:"
echo
echo "  proot-distro login ${DISTRO} -- bash -lc '${NEXT_CMD}'"
echo
echo "(FORGEHUB_WORKFLOW_DIR is set explicitly above because the backend's own"
echo "default for it is a hardcoded container path that does not exist on the"
echo "phone -- see config.py. Task 4 adds start-backend.sh, which wraps this"
echo "same command with a wake-lock and a persistent notification; once it"
echo "exists, prefer that instead of running this by hand.)"
