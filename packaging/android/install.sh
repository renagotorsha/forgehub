#!/usr/bin/env bash
# The one command the owner runs in Termux proper to provision ForgeHub's
# backend inside a proot-distro Ubuntu guest -- and also the one command
# they run later to update it. There is no separate "update" procedure:
# this script re-pulls the Termux-side checkout it is itself running from
# (see the git-pull block right after the Termux check below) before doing
# anything else, so running the exact same command again is how an update
# is applied.
#
# PREREQUISITE this script cannot satisfy itself: it must already be
# sitting inside a `git clone` of the fork at `~/ForgeHub` in Termux (the
# "Termux-side checkout" -- see the README's "Bootstrap" step for the
# `pkg install git && git clone ...` command that creates it). This script
# cannot bootstrap that checkout because obtaining *this file* already
# required it to exist; it can only keep it updated once it does.
#
# This script only knows about Termux: confirming the Termux-side checkout
# and keeping it current, asserting it is actually running under Termux,
# installing the handful of Termux-side packages proot-distro needs, and
# getting the guest installed. All backend provisioning (apt packages
# inside the guest, cloning the fork into the GUEST's own separate
# ~/ForgeHub, the venv, the dependency lock) lives in guest-provision.sh,
# which this script runs *inside* the guest. Two different filesystems
# share the path "~/ForgeHub" -- Termux's $HOME (this script's checkout,
# read directly by start-backend.sh and the Termux:Boot entry point) and
# the guest's $HOME (a separate clone inside proot-distro, updated by
# guest-provision.sh's own `git pull`). Keeping both current is why this
# script pulls the former below and always runs the latter.
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
#   FORGEHUB_REPO_URL     Git URL of the ForgeHub fork to clone into the
#                         GUEST. No default -- the fork's URL is not yet
#                         public (see Task 3's brief, controller ruling 1).
#                         Example:
#                           FORGEHUB_REPO_URL=https://github.com/renagotorsha/forgehub.git \
#                             bash packaging/android/install.sh
#                         (The Termux-side checkout this script itself runs
#                         from comes from the same URL -- see the README's
#                         "Bootstrap" step -- but this variable only ever
#                         feeds the GUEST-side clone; the Termux-side one is
#                         kept current by `git pull`, below, not by this.)
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_TERMUX="$(cd "${HERE}/../.." && pwd)"

if ! command -v git >/dev/null 2>&1; then
  echo "FATAL: 'git' is not on PATH." >&2
  echo "FATAL: this script only exists on the phone because it was 'git clone'd" >&2
  echo "FATAL: here in the first place (see the README's Bootstrap step), so git" >&2
  echo "FATAL: must already have been installed once. If this Termux install was" >&2
  echo "FATAL: wiped or restored without it, reinstall and re-run:" >&2
  echo "FATAL:   pkg install git" >&2
  exit 1
fi

# Keep the Termux-side checkout (the one this very script is running from)
# up to date on every run. This is the whole update story for this side:
# re-running `bash packaging/android/install.sh` later both updates this
# checkout (here) and the guest's separate checkout (guest-provision.sh's
# own `git pull`, run further down) -- install and update are one command.
# Without this, start-backend.sh and the Termux:Boot entry point, both read
# live from this checkout, would drift from the fork forever after the
# first install.
if [[ -d "${REPO_ROOT_TERMUX}/.git" ]]; then
  echo "-- Termux-side checkout at ${REPO_ROOT_TERMUX} -- git pull --ff-only --"
  git -C "${REPO_ROOT_TERMUX}" pull --ff-only
else
  echo "FATAL: ${REPO_ROOT_TERMUX} (where install.sh itself lives) is not a git" >&2
  echo "FATAL: checkout -- there is no .git directory at its repo root." >&2
  echo "FATAL: install.sh must be run from inside a 'git clone' of the fork, not" >&2
  echo "FATAL: from a loose copy of just this file -- see the README's Bootstrap" >&2
  echo "FATAL: step. Without a real checkout here, there would be nothing for" >&2
  echo "FATAL: 'git pull' to update on a later run." >&2
  exit 1
fi

if [[ -z "${FORGEHUB_REPO_URL:-}" ]]; then
  echo "FATAL: FORGEHUB_REPO_URL is not set." >&2
  echo "FATAL: this needs the git URL of the ForgeHub fork to clone into the" >&2
  echo "FATAL: guest -- it is not hardcoded because the fork's URL is not yet" >&2
  echo "FATAL: public. Export it and re-run, e.g.:" >&2
  echo "FATAL:   FORGEHUB_REPO_URL=https://github.com/renagotorsha/forgehub.git bash $0" >&2
  exit 1
fi
FORGEHUB_REPO_BRANCH="${FORGEHUB_REPO_BRANCH:-android}"

GUEST_PROVISION="${HERE}/guest-provision.sh"
if [[ ! -r "${GUEST_PROVISION}" ]]; then
  echo "FATAL: ${GUEST_PROVISION} not found next to install.sh." >&2
  echo "FATAL: both files are expected to travel together -- copy guest-provision.sh" >&2
  echo "FATAL: alongside install.sh before running it." >&2
  exit 1
fi

echo "-- pkg install termux-api proot-distro git curl --"
# curl is listed here, not left for start-backend.sh to discover missing:
# that script hard-requires curl on the Termux side for its second-instance
# guard (it FATALs with the right remedy otherwise, but there is no reason
# to make the owner hit that round trip when this script already knows).
pkg install -y termux-api proot-distro git curl

DISTRO=ubuntu
# "ubuntu" is a proot-distro ALIAS, not a version pin -- it currently
# resolves to Ubuntu 24.04, matching the cp312 wheels pinned in
# requirements.lock.txt (see that file's own header: built against
# "Ubuntu 24.04.5 LTS" / "Python 3.12.3"), but proot-distro can and does
# move this alias forward to a newer LTS release over time, and proot-distro
# has no "ubuntu-24.04"-style alias that stays pinned to a specific release
# forever. If that happens, this line will install a newer guest with a
# newer system Python, and guest-provision.sh's own hard Python-version
# check (REQUIRED_PYTHON_MM, just above its apt-get install block) will
# refuse to proceed with a clear FATAL naming both versions -- loud and
# legible, not a silent breakage, but something to know about before it
# happens on a phone instead of in this comment. The fix at that point is
# to regenerate the lock against the new guest:
#   bash packaging/android/verify-aarch64-deps.sh --freeze
# See the README's note on this coupling for the full explanation.
#
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

echo "== install.sh: provisioning complete =="
echo
echo "Next, start the backend:"
echo
echo "  bash ${HERE}/start-backend.sh"
echo
echo "(start-backend.sh -- not a hand-rolled uvicorn command -- is the supported way"
echo "to start this. It sets FORGEHUB_WORKFLOW_DIR (the backend's own default is a"
echo "hardcoded container path that does not exist on the phone -- see config.py),"
echo "FORGEHUB_FRONTEND_DIR when packaging/android/dist exists (otherwise the GUI has"
echo "nothing to serve at '/'), and -- this one matters most -- FORGEHUB_CORS_ORIGINS"
echo "pinned to this phone's own origin. Upstream's default for that last one is '*'"
echo "paired with allow_credentials=True (config.py:21, main.py:66-70), which would let"
echo "any web page open in any browser on this phone read /settings -- the Runpod API"
echo "key -- and spend GPU credits via /execute. Never start uvicorn by hand instead;"
echo "if you ever must, set FORGEHUB_CORS_ORIGINS=http://127.0.0.1:8484 explicitly, the"
echo "same way start-backend.sh does, rather than leaving it to fall through to '*'.)"
