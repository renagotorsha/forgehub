#!/usr/bin/env bash
# Runs inside the arm64 test container (invoked by test_ffmpeg_required.sh
# via _arm64.sh). Proves Step 5's premise empirically: forgehub_backend's
# thumbnail endpoint already fails *legibly* -- a clean HTTP error, no
# partial or zero-byte thumbnail left behind -- when no ffmpeg binary is
# reachable at all. That confirms the fix belongs in install.sh's hard
# ffmpeg/ffprobe precondition (Task 3's controller ruling 5), not in
# backend source, which is off-limits.
#
# Deliberately installs the backend's runtime deps WITHOUT imageio-ffmpeg,
# and never apt-get installs ffmpeg: "ffmpeg removed from PATH" taken to
# its logical conclusion. imageio-ffmpeg's own wheel bundles a real aarch64
# ffmpeg binary (see Task 2's report), so leaving that package installed
# while merely editing $PATH would not reliably reproduce "no ffmpeg
# available at all" -- forgehub_backend/files.py's _ffmpeg_bin() falls
# back to exactly that bundled binary when nothing is on PATH.
#
# Lighter than test_install_idempotent.sh's run on purpose: no ffmpeg apt
# package here means skipping the ~13-minute dependency closure that
# dominates verify-aarch64-deps.sh's and guest-provision.sh's runtime --
# this test does not need a working ffmpeg, it needs the opposite.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export HOME=/root

echo "-- apt-get install python3 python3-venv curl (ffmpeg deliberately omitted) --"
apt-get update -qq
apt-get install -y -qq python3 python3-venv curl

VENV=/opt/venv
python3 -m venv "${VENV}"

PIP_SOURCE_FLAGS=()
if [[ -d /wheels ]]; then
  echo "-- wheelhouse detected at /wheels -- installing offline --"
  PIP_SOURCE_FLAGS=(--no-index --find-links=/wheels)
else
  "${VENV}/bin/pip" install --upgrade pip -q
fi

# Reuse the exact pinned versions Task 2 proved, minus imageio-ffmpeg --
# the one line in the lock that must NOT be installed for this test to be
# deterministic (see header comment above).
LOCK_FILE=/workspace/packaging/android/requirements.lock.txt
LOCK_NO_IMAGEIO=/tmp/lock-no-imageio.txt
grep -viE '^imageio[_-]ffmpeg' "${LOCK_FILE}" > "${LOCK_NO_IMAGEIO}"

echo "-- pip install --only-binary=:all: -r requirements.lock.txt (imageio-ffmpeg excluded) --"
"${VENV}/bin/pip" install --only-binary=:all: "${PIP_SOURCE_FLAGS[@]}" -r "${LOCK_NO_IMAGEIO}"

mkdir -p /tmp/storage/outputs
printf 'not a real video, just a probe target for the thumbnail endpoint' \
  > /tmp/storage/outputs/probe.mp4

export FORGEHUB_STORAGE_DIR=/tmp/storage
export FORGEHUB_SETTINGS_FILE=/tmp/settings.json
export PATH=/opt/venv/bin:/usr/bin:/bin   # no ffmpeg/ffprobe anywhere on PATH

cd /workspace   # read-only; only read from here (default workflow/wildcard dirs resolve against it)

echo "-- confirming imageio_ffmpeg truly is not installed (the determinism this test relies on) --"
if "${VENV}/bin/python3" -c "import imageio_ffmpeg" 2>/dev/null; then
  echo "FATAL: imageio_ffmpeg imported successfully -- it must not be installed in" >&2
  echo "FATAL: this test's venv, or the ffmpeg-absence this test exercises is not real." >&2
  exit 1
fi
echo "-- confirmed: imageio_ffmpeg is not importable, and no ffmpeg/ffprobe is on PATH --"

echo "-- starting the backend (ffmpeg genuinely unavailable) --"
"${VENV}/bin/python3" -m uvicorn forgehub_backend.main:app \
  --host 127.0.0.1 --port 8484 --app-dir /workspace >/tmp/uvicorn.log 2>&1 &
UVICORN_PID=$!
trap 'kill "${UVICORN_PID}" 2>/dev/null || true' EXIT

echo "-- waiting for the backend to answer /config --"
UP=0
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:8484/config" >/dev/null 2>&1; then
    UP=1
    break
  fi
  sleep 1
done
if [[ "${UP}" -ne 1 ]]; then
  echo "FATAL: backend never answered /config -- see /tmp/uvicorn.log" >&2
  cat /tmp/uvicorn.log >&2
  exit 1
fi
echo "-- backend is up --"

FAIL=0

echo "-- GET /outputs lists probe.mp4 --"
LIST_JSON="$(curl -fsS "http://127.0.0.1:8484/outputs")"
if printf '%s' "${LIST_JSON}" | "${VENV}/bin/python3" -c "
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if any(o.get('filename') == 'probe.mp4' for o in d.get('outputs', [])) else 1)
"; then
  echo "ok   -- probe.mp4 is listed via the public /outputs API"
else
  echo "FAIL -- probe.mp4 missing from /outputs: ${LIST_JSON}" >&2
  FAIL=1
fi

echo "-- GET /outputs/probe.mp4/thumb must fail legibly, not succeed with a garbage body --"
HTTP_CODE="$(curl -s -o /tmp/thumb.out -w '%{http_code}' "http://127.0.0.1:8484/outputs/probe.mp4/thumb")"
echo "-- http status: ${HTTP_CODE} --"
if [[ "${HTTP_CODE}" == "200" ]]; then
  echo "FAIL -- thumb endpoint returned HTTP 200 with no ffmpeg available (should have failed)" >&2
  FAIL=1
  if [[ -s /tmp/thumb.out ]]; then
    echo "FAIL -- ... and the 200 came with a non-empty body: a garbage thumbnail was served" >&2
  fi
else
  echo "ok   -- thumb endpoint failed with HTTP ${HTTP_CODE} (legible, not a disguised success)"
  BODY_SNIPPET="$(head -c 200 /tmp/thumb.out 2>/dev/null || true)"
  echo "ok   -- error body is legible, not garbage bytes: ${BODY_SNIPPET}"
fi

echo "-- no zero-byte or partial thumbnail left behind in the thumbs cache --"
mkdir -p /tmp/storage/thumbs
THUMB_LEFTOVERS="$(find /tmp/storage/thumbs -type f 2>/dev/null || true)"
if [[ -z "${THUMB_LEFTOVERS}" ]]; then
  echo "ok   -- no thumbnail artifact was left behind at all"
else
  BAD=0
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    if [[ ! -s "${f}" ]]; then
      echo "FAIL -- zero-byte thumbnail artifact left behind: ${f}" >&2
      BAD=1
    fi
  done <<< "${THUMB_LEFTOVERS}"
  if [[ "${BAD}" -eq 1 ]]; then
    FAIL=1
  else
    echo "ok   -- thumbnail artifact(s) present are non-empty, i.e. not partial writes: ${THUMB_LEFTOVERS}"
  fi
fi

if [[ "${FAIL}" -eq 0 ]]; then
  echo "test-ffmpeg-required (inner): ALL CHECKS PASSED"
else
  echo "test-ffmpeg-required (inner): CHECKS FAILED" >&2
fi
exit "${FAIL}"
