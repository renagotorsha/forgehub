#!/usr/bin/env bash
# Shared helper: run a command inside `docker run --platform linux/arm64
# ubuntu:24.04`, with the repo mounted read-only at /workspace.
#
# This exists so every script that needs to prove something about the
# aarch64 target (dependency installs, the backend test suite, ffmpeg) goes
# through the exact same container setup instead of each reinventing
# `docker run --platform ...` with slightly different flags.
#
# Usage:
#   _arm64.sh <command> [args...]
#
# The command is exec'd directly (not through a shell) unless the caller
# passes one explicitly, e.g.:
#   _arm64.sh uname -m
#   _arm64.sh bash -c 'apt-get update && apt-get install -y python3'
#
# The mount is read-only and MUST STAY read-only. Do not "fix" build
# failures by changing this to `:/workspace` (rw). A qemu-emulated
# container running as root that can write into the host checkout is how
# you end up with root-owned build artifacts (egg-info/, __pycache__/,
# build/) jammed into the repo that the host `deploy` user then can't
# clean up without sudo -- and sudo does not work on this host at all.
#
# setuptools' egg_info step (triggered by `pip install .`) needs to write
# into the source tree it's building from, which a read-only mount can't
# satisfy. The fix lives on the caller's side, not here: anything that
# installs the project must first copy /workspace to a writable /build
# inside the container (`tar --exclude`, to skip .venv/node_modules) and
# operate from there. See
# verify-aarch64-deps.sh for the one-line implementation. This was proven
# necessary by a real failure (2026-10-27): `pip install` died with
# "Cannot update time stamp of directory 'forgehub_backend.egg-info'"
# because that directory already existed in the checkout (left by Task 1's
# editable install) and setuptools couldn't touch its mtime read-only.
#
# Anything else that must persist to the host (e.g. `pip freeze` output)
# should be captured via stdout redirection on the host side, not by
# writing inside the container.
#
# Persistent pip cache (named volume, survives --rm): every pass of
# verify-aarch64-deps.sh used to throw its downloads away because the
# container is --rm. pip's own cache dir is content-addressed (keyed by
# wheel hash, not by invocation), so re-mounting the same named volume
# across runs turns a second `pip install` of the same package into a
# local copy instead of a re-download. Named volumes are NOT removed by
# `docker run --rm` -- only anonymous volumes and the container itself are
# -- so this persists across every call to this helper without any extra
# cleanup step.
#
# Optional wheelhouse mount (FORGEHUB_WHEELHOUSE env var): set by the
# caller to a host directory of pre-downloaded wheels (see
# verify-aarch64-deps.sh's `pip download` step on the host side) when it
# wants pip inside the container to install with `--no-index
# --find-links=/wheels` instead of hitting the network. This is what
# makes a container pass cheap: pip's HTTPS path runs as emulated aarch64
# code and is CPU-bound in qemu, not network-bound, so a 15.7 MB wheel
# that downloads in under a minute natively took ~13 minutes over the same
# link inside this container. Wheels are platform-tagged artifacts, so
# fetching them on the (real) host architecture and handing them to the
# (emulated) container does not change what gets installed.
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: $(basename "$0") <command> [args...]" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PIP_CACHE_VOLUME="forgehub-android-arm64-pip-cache"

DOCKER_ARGS=(
  --rm
  --platform linux/arm64
  -v "${REPO_ROOT}:/workspace:ro"
  -v "${PIP_CACHE_VOLUME}:/root/.cache/pip"
  -w /workspace
)

if [[ -n "${FORGEHUB_WHEELHOUSE:-}" ]]; then
  DOCKER_ARGS+=(-v "${FORGEHUB_WHEELHOUSE}:/wheels:ro")
fi

exec docker run "${DOCKER_ARGS[@]}" \
  ubuntu:24.04 \
  "$@"
