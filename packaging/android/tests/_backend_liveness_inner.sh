#!/usr/bin/env bash
# Runs inside the arm64 test container (invoked by test_backend_liveness.sh
# via _arm64.sh). Provisions a guest exactly like
# tests/_install_idempotent_inner.sh does (reusing guest-provision.sh rather
# than reinventing a second way to get a working venv), then drives
# start-backend.sh for real and checks everything Task 4's brief and the
# controller's rulings require:
#
#   - /config answers HTTP 200 with a body that parses as JSON
#   - the listening socket is 127.0.0.1:8484 and NOT 0.0.0.0:8484 (the
#     single most important assertion here -- see start-backend.sh's own
#     header for why)
#   - a second start-backend.sh invocation refuses to run while the first
#     is still up, and does not add a second listener
#   - FORGEHUB_NO_TERMUX=1 makes the script say, plainly, that it skipped
#     every termux-* call -- never silently, never pretending
#   - stopping the backend actually frees the port (the cleanup trap ran)
#
# FORGEHUB_REPO_URL must already be set by the caller (file:///workspace,
# the same read-only checkout _arm64.sh mounts, standing in for the fork's
# not-yet-public URL -- see tests/_install_idempotent_inner.sh's header for
# the full reasoning, which applies unchanged here).
set -uo pipefail

if [[ -z "${FORGEHUB_REPO_URL:-}" ]]; then
  echo "FATAL: test harness bug -- FORGEHUB_REPO_URL was not propagated into the container" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export HOME=/root
GUEST_PROVISION=/workspace/packaging/android/guest-provision.sh
START_BACKEND=/workspace/packaging/android/start-backend.sh
HOST=127.0.0.1
PORT=8484
BACKEND_URL="http://${HOST}:${PORT}/config"

FAIL=0
ok()  { echo "ok   -- $1"; }
bad() { echo "FAIL -- $1" >&2; FAIL=1; }

# Same git/safe.directory workaround as _install_idempotent_inner.sh, for
# the identical reason: guest-provision.sh clones FORGEHUB_REPO_URL, here a
# local file:///workspace path owned by the host's uid 1000 while this
# container runs as root. git itself needs to exist before the `git config`
# call can run; guest-provision.sh's own `apt-get install ... git` right
# after is a harmless no-op repeat. curl is not something guest-provision.sh
# installs (the backend doesn't need it to run) but start-backend.sh treats
# it as a hard dependency for its second-instance guard, so it is installed
# here, in the test harness that exercises that guard -- same division of
# labour as test_ffmpeg_required_inner.sh installing curl for its own probe.
echo "-- apt-get install git curl (prerequisites this harness/script need before guest-provision.sh runs) --"
apt-get update -qq
apt-get install -y -qq git curl
git config --global --add safe.directory /workspace/.git

echo "########## provisioning the guest (reusing guest-provision.sh) ##########"
if ! bash "${GUEST_PROVISION}"; then
  echo "FATAL: guest-provision.sh failed -- cannot test start-backend.sh without a provisioned guest" >&2
  exit 1
fi

echo "########## start-backend.sh must exist and be executable bash ##########"
if [[ ! -f "${START_BACKEND}" ]]; then
  echo "FATAL: ${START_BACKEND} does not exist" >&2
  exit 1
fi
bash -n "${START_BACKEND}"

echo "########## first run: starting the backend via start-backend.sh (FORGEHUB_NO_TERMUX=1) ##########"
FORGEHUB_NO_TERMUX=1 bash "${START_BACKEND}" >/tmp/start-backend-first.log 2>&1 &
STARTER_PID=$!
echo "-- start-backend.sh launched as pid ${STARTER_PID} --"

echo "-- polling ${BACKEND_URL} for up to 60s --"
UP=0
HTTP_CODE=""
BODY_FILE=/tmp/config-body.json
for _ in $(seq 1 60); do
  HTTP_CODE="$(curl -s -o "${BODY_FILE}" -w '%{http_code}' "${BACKEND_URL}" 2>/dev/null || true)"
  if [[ "${HTTP_CODE}" == "200" ]]; then
    UP=1
    break
  fi
  # If start-backend.sh already died, no amount of further polling will help.
  if ! kill -0 "${STARTER_PID}" 2>/dev/null; then
    echo "-- start-backend.sh (pid ${STARTER_PID}) exited early -- see /tmp/start-backend-first.log --"
    break
  fi
  sleep 1
done

echo "########## start-backend.sh's own log ##########"
cat /tmp/start-backend-first.log

if [[ "${UP}" -eq 1 ]]; then
  ok "backend answered ${BACKEND_URL} with HTTP 200 within 60s"
else
  bad "backend never answered ${BACKEND_URL} with HTTP 200 (last code: '${HTTP_CODE:-<none>}')"
fi

if [[ "${UP}" -eq 1 ]]; then
  if python3 -c "import json; json.load(open('${BODY_FILE}'))" 2>/dev/null; then
    ok "/config response body parses as JSON"
  else
    bad "/config response body does NOT parse as JSON: $(cat "${BODY_FILE}" 2>/dev/null)"
  fi
fi

echo "########## the assertion that matters most: 127.0.0.1-only bind ##########"
SS_OUTPUT="$(ss -ltnp 2>/dev/null || true)"
echo "${SS_OUTPUT}"
if grep -q "127.0.0.1:${PORT}" <<<"${SS_OUTPUT}"; then
  ok "something listens on 127.0.0.1:${PORT}"
else
  bad "nothing listens on 127.0.0.1:${PORT} -- 'ss -ltnp' showed no such line"
fi
if grep -q "0.0.0.0:${PORT}" <<<"${SS_OUTPUT}"; then
  bad "0.0.0.0:${PORT} IS listening -- this would be reachable from the local Wi-Fi, " \
      "handing out the Runpod API key to anyone on it"
else
  ok "nothing listens on 0.0.0.0:${PORT} (bind is local-only, as required)"
fi

echo "########## second-instance guard: a second start-backend.sh must refuse to start ##########"
SECOND_RC=0
FORGEHUB_NO_TERMUX=1 bash "${START_BACKEND}" >/tmp/start-backend-second.log 2>&1 || SECOND_RC=$?
cat /tmp/start-backend-second.log
if [[ "${SECOND_RC}" -ne 0 ]]; then
  ok "second start-backend.sh invocation exited non-zero (rc=${SECOND_RC}), refusing to race a second uvicorn onto the socket"
else
  bad "second start-backend.sh invocation exited 0 -- it should have refused while the first instance is up"
fi

SS_AFTER_SECOND="$(ss -ltnp 2>/dev/null | grep -c ":${PORT} " || true)"
if [[ "${SS_AFTER_SECOND}" -le 1 ]]; then
  ok "still at most one listener on port ${PORT} after the second attempt (no second instance raced onto the socket)"
else
  bad "found ${SS_AFTER_SECOND} listeners on port ${PORT} -- the second instance was not actually refused"
fi

echo "########## honesty under FORGEHUB_NO_TERMUX=1: must say it skipped termux-* calls, not pretend ##########"
if grep -qi "termux-wake-lock" /tmp/start-backend-first.log && grep -qi "skip" /tmp/start-backend-first.log; then
  ok "log explicitly mentions skipping termux-wake-lock under FORGEHUB_NO_TERMUX=1"
else
  bad "log does not explicitly say it skipped termux-wake-lock -- can't tell if it's being honest about FORGEHUB_NO_TERMUX=1"
fi
if grep -qi "termux-notification" /tmp/start-backend-first.log && grep -qi "skip" /tmp/start-backend-first.log; then
  ok "log explicitly mentions skipping termux-notification under FORGEHUB_NO_TERMUX=1"
else
  bad "log does not explicitly say it skipped termux-notification -- can't tell if it's being honest about FORGEHUB_NO_TERMUX=1"
fi

echo "########## stopping the backend: the cleanup trap must actually free the port ##########"
kill -TERM "${STARTER_PID}" 2>/dev/null || true
STOPPED=0
for _ in $(seq 1 20); do
  if ! kill -0 "${STARTER_PID}" 2>/dev/null; then
    STOPPED=1
    break
  fi
  sleep 1
done
if [[ "${STOPPED}" -eq 1 ]]; then
  ok "start-backend.sh (pid ${STARTER_PID}) exited after SIGTERM"
else
  bad "start-backend.sh (pid ${STARTER_PID}) did not exit within 20s of SIGTERM"
  kill -KILL "${STARTER_PID}" 2>/dev/null || true
fi

sleep 1
SS_AFTER_STOP="$(ss -ltnp 2>/dev/null || true)"
if grep -q ":${PORT} " <<<"${SS_AFTER_STOP}"; then
  bad "port ${PORT} is still listening after start-backend.sh exited -- cleanup did not free it: ${SS_AFTER_STOP}"
else
  ok "port ${PORT} is free after start-backend.sh exited (cleanup trap worked)"
fi

if curl -fsS "${BACKEND_URL}" >/dev/null 2>&1; then
  bad "${BACKEND_URL} still answers after shutdown -- the backend process is still alive somewhere"
else
  ok "${BACKEND_URL} no longer answers after shutdown"
fi

if [[ "${FAIL}" -eq 0 ]]; then
  echo "test-backend-liveness (inner): ALL CHECKS PASSED"
else
  echo "test-backend-liveness (inner): CHECKS FAILED" >&2
fi
exit "${FAIL}"
