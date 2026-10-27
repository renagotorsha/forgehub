#!/usr/bin/env bash
# Covering tests for the two predicates in _verify_lib.sh that a passing
# verify-aarch64-deps.sh run cannot exercise: the pytest-count gate and the
# permitted-fallback matcher.
#
# Both only misbehave on runs that fail, or that pass for the wrong reason --
# exactly the runs that cost ~13 minutes of emulated CPU to produce and that
# nobody reproduces on purpose. Fixtures here are captured from real pip and
# pytest output (see /tmp/verify-lock-run1.log, /tmp/verify-freeze-run1.log
# from the Task 2 runs), so the strings are pip's and pytest's, not
# invented.
#
# Usage: bash packaging/android/tests/test-verify-logic.sh
# Runs on the host in under a second. No network, no docker, no venv.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_verify_lib.sh
source "${HERE}/_verify_lib.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

ok() {
  PASS=$((PASS + 1))
  echo "  ok   -- $1"
}

bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL -- $1" >&2
}

# expect_rc <expected-rc> <description> <command...>
expect_rc() {
  local want="$1" desc="$2"
  shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  if [[ "${got}" -eq "${want}" ]]; then
    ok "${desc} (rc=${got})"
  else
    bad "${desc}: expected rc=${want}, got rc=${got}"
  fi
}

echo "== forgehub_pip_failed_for: the permitted-fallback matcher =="

# The finding, reproduced: a log whose only *failure* is pydantic-core (the
# actual bet of this task) but which also carries the benign progress lines
# that mention imageio-ffmpeg, uvloop, httptools and watchfiles by name.
# Both fallback flags must stay clear so the caller escalates loudly instead
# of quietly omitting imageio-ffmpeg and stripping uvicorn's extras.
cat >"${TMP}/benign-plus-unrelated-failure.log" <<'EOF'
Processing /build
  Installing build dependencies: started
  Installing build dependencies: finished with status 'done'
Collecting fastapi>=0.115.0 (from forgehub-backend==0.1.13)
Collecting imageio-ffmpeg>=0.5.1 (from forgehub-backend==0.1.13)
  Downloading imageio_ffmpeg-0.6.0-py3-none-manylinux2014_aarch64.whl.metadata (1.1 kB)
Collecting httptools>=0.8.0 (from uvicorn[standard]>=0.30.0->forgehub-backend==0.1.13)
Collecting uvloop>=0.15.1 (from uvicorn[standard]>=0.30.0->forgehub-backend==0.1.13)
  Downloading uvloop-0.23.0-cp312-cp312-manylinux2014_aarch64.manylinux_2_17_aarch64.manylinux_2_28_aarch64.whl (4.4 MB)
Collecting watchfiles>=0.20 (from uvicorn[standard]>=0.30.0->forgehub-backend==0.1.13)
Collecting pydantic>=2.9.0 (from forgehub-backend==0.1.13)
ERROR: Could not find a version that satisfies the requirement pydantic-core==2.50.1 (from pydantic) (from versions: none)
ERROR: No matching distribution found for pydantic-core==2.50.1
EOF

expect_rc 1 "benign mentions + unrelated pydantic-core failure => imageio fallback NOT triggered" \
  forgehub_pip_failed_for "${TMP}/benign-plus-unrelated-failure.log" 'imageio[_-]ffmpeg'
expect_rc 1 "benign mentions + unrelated pydantic-core failure => uvicorn fallback NOT triggered" \
  forgehub_pip_failed_for "${TMP}/benign-plus-unrelated-failure.log" 'uvloop' 'httptools' 'watchfiles'

# Same shape under a wheelhouse, where pip says "Processing /wheels/<file>"
# rather than "Downloading" -- the filename spells the package name with an
# underscore, which a naive matcher would also catch.
cat >"${TMP}/wheelhouse-benign.log" <<'EOF'
Looking in links: /wheels
Processing /wheels/imageio_ffmpeg-0.6.0-py3-none-manylinux2014_aarch64.whl (from -r /build/packaging/android/requirements.lock.txt (line 18))
Processing /wheels/uvloop-0.23.0-cp312-cp312-manylinux2014_aarch64.manylinux_2_17_aarch64.manylinux_2_28_aarch64.whl (from -r /build/packaging/android/requirements.lock.txt (line 38))
Processing /wheels/watchfiles-1.3.0-cp310-abi3-manylinux_2_17_aarch64.manylinux2014_aarch64.whl (from -r /build/packaging/android/requirements.lock.txt (line 39))
ERROR: Could not find a version that satisfies the requirement numpy==2.5.4 (from versions: none)
ERROR: No matching distribution found for numpy==2.5.4
EOF

expect_rc 1 "wheelhouse 'Processing /wheels/imageio_ffmpeg-...' is not a failure" \
  forgehub_pip_failed_for "${TMP}/wheelhouse-benign.log" 'imageio[_-]ffmpeg'
expect_rc 1 "wheelhouse 'Processing /wheels/uvloop-...' is not a failure" \
  forgehub_pip_failed_for "${TMP}/wheelhouse-benign.log" 'uvloop' 'httptools' 'watchfiles'

# The real thing: pip actually failing to resolve imageio-ffmpeg. The
# fallback is permitted here and must trigger -- and must not drag the
# unrelated uvicorn fallback along with it.
cat >"${TMP}/imageio-real-failure.log" <<'EOF'
Collecting imageio-ffmpeg>=0.5.1 (from forgehub-backend==0.1.13)
Collecting uvloop>=0.15.1 (from uvicorn[standard]>=0.30.0->forgehub-backend==0.1.13)
  Downloading uvloop-0.23.0-cp312-cp312-manylinux_2_28_aarch64.whl (4.4 MB)
ERROR: Could not find a version that satisfies the requirement imageio-ffmpeg>=0.5.1 (from forgehub-backend) (from versions: none)
ERROR: No matching distribution found for imageio-ffmpeg>=0.5.1
EOF

expect_rc 0 "real imageio-ffmpeg resolution failure => imageio fallback triggered" \
  forgehub_pip_failed_for "${TMP}/imageio-real-failure.log" 'imageio[_-]ffmpeg'
expect_rc 1 "real imageio-ffmpeg failure alone => uvicorn fallback NOT triggered" \
  forgehub_pip_failed_for "${TMP}/imageio-real-failure.log" 'uvloop' 'httptools' 'watchfiles'

# And the uvicorn[standard] case, in both of pip's phrasings.
cat >"${TMP}/uvloop-real-failure.log" <<'EOF'
Collecting imageio-ffmpeg>=0.5.1 (from forgehub-backend==0.1.13)
  Downloading imageio_ffmpeg-0.6.0-py3-none-manylinux2014_aarch64.whl (31.2 MB)
ERROR: Could not find a version that satisfies the requirement uvloop>=0.15.1 (from uvicorn) (from versions: none)
ERROR: No matching distribution found for uvloop>=0.15.1
EOF

expect_rc 0 "real uvloop resolution failure => uvicorn fallback triggered" \
  forgehub_pip_failed_for "${TMP}/uvloop-real-failure.log" 'uvloop' 'httptools' 'watchfiles'
expect_rc 1 "real uvloop failure alone => imageio fallback NOT triggered" \
  forgehub_pip_failed_for "${TMP}/uvloop-real-failure.log" 'imageio[_-]ffmpeg'

printf 'ERROR: No matching distribution found for watchfiles\n' >"${TMP}/watchfiles-eol.log"
expect_rc 0 "package name at end of line still matches" \
  forgehub_pip_failed_for "${TMP}/watchfiles-eol.log" 'uvloop' 'httptools' 'watchfiles'

# Prefix safety: a failure naming a longer package must not satisfy a
# shorter name's fallback.
printf 'ERROR: No matching distribution found for imageio-ffmpeg-extra>=1.0\n' >"${TMP}/prefix.log"
expect_rc 1 "longer package name does not satisfy a shorter name's fallback" \
  forgehub_pip_failed_for "${TMP}/prefix.log" 'imageio[_-]ffmpeg'

# A dependency-conflict failure names no package in either failure phrasing,
# so it must escalate rather than pick a fallback.
cat >"${TMP}/conflict.log" <<'EOF'
Collecting uvloop>=0.15.1 (from uvicorn[standard]>=0.30.0->forgehub-backend==0.1.13)
ERROR: Cannot install forgehub-backend because these package versions have conflicting dependencies.
EOF
expect_rc 1 "dependency conflict escalates (no fallback claims it)" \
  forgehub_pip_failed_for "${TMP}/conflict.log" 'uvloop' 'httptools' 'watchfiles'

# "I cannot tell" must be distinguishable from "does not apply".
expect_rc 2 "unreadable log returns 2, not 1" \
  forgehub_pip_failed_for "${TMP}/does-not-exist.log" 'uvloop'

echo "== forgehub_assert_pytest_passed: the suite-erosion gate =="

# The finding, reproduced: every one of these exits 0 from pytest.
printf '.................................                                        [100%%]\n33 passed, 1 warning in 14.19s\n' \
  >"${TMP}/pytest-good.log"
printf 'sssssssssssssssssssssssssssssssss                                        [100%%]\n33 skipped in 1.20s\n' \
  >"${TMP}/pytest-all-skipped.log"
printf '33 passed, 1 warning in 14.19s\n' >"${TMP}/pytest-bare.log"
printf '12 passed, 21 skipped in 2.40s\n' >"${TMP}/pytest-partly-skipped.log"
printf 'no tests ran in 0.01s\n' >"${TMP}/pytest-none.log"
printf '34 passed, 1 warning in 15.02s\n' >"${TMP}/pytest-grew.log"
printf '1 failed, 32 passed in 13.80s\n' >"${TMP}/pytest-failed.log"
printf 'Traceback (most recent call last):\nImportError: cannot import name BaseModel\n' \
  >"${TMP}/pytest-crashed.log"

expect_rc 0 "'33 passed, 1 warning in 14.19s' passes the gate" \
  forgehub_assert_pytest_passed "${TMP}/pytest-good.log" "${FORGEHUB_EXPECTED_PASSED}"
expect_rc 0 "summary line with no progress line still passes" \
  forgehub_assert_pytest_passed "${TMP}/pytest-bare.log" "${FORGEHUB_EXPECTED_PASSED}"
expect_rc 1 "'33 skipped' (pytest exit 0!) fails the gate" \
  forgehub_assert_pytest_passed "${TMP}/pytest-all-skipped.log" "${FORGEHUB_EXPECTED_PASSED}"
expect_rc 1 "'12 passed, 21 skipped' (pytest exit 0!) fails the gate" \
  forgehub_assert_pytest_passed "${TMP}/pytest-partly-skipped.log" "${FORGEHUB_EXPECTED_PASSED}"
expect_rc 1 "'no tests ran' fails the gate" \
  forgehub_assert_pytest_passed "${TMP}/pytest-none.log" "${FORGEHUB_EXPECTED_PASSED}"
expect_rc 1 "'34 passed' fails the gate (count moved; baseline needs re-recording)" \
  forgehub_assert_pytest_passed "${TMP}/pytest-grew.log" "${FORGEHUB_EXPECTED_PASSED}"
expect_rc 1 "'1 failed, 32 passed' fails the gate" \
  forgehub_assert_pytest_passed "${TMP}/pytest-failed.log" "${FORGEHUB_EXPECTED_PASSED}"
expect_rc 1 "no summary line at all (pytest crashed) fails the gate" \
  forgehub_assert_pytest_passed "${TMP}/pytest-crashed.log" "${FORGEHUB_EXPECTED_PASSED}"
expect_rc 2 "unreadable pytest log returns 2, not 1" \
  forgehub_assert_pytest_passed "${TMP}/does-not-exist.log" "${FORGEHUB_EXPECTED_PASSED}"

echo "== forgehub_pytest_summary_line: what the FATAL message quotes =="
for fixture in pytest-good:"33 passed, 1 warning in 14.19s" \
               pytest-all-skipped:"33 skipped in 1.20s" \
               pytest-partly-skipped:"12 passed, 21 skipped in 2.40s" \
               pytest-none:"no tests ran in 0.01s" \
               pytest-failed:"1 failed, 32 passed in 13.80s"; do
  name="${fixture%%:*}"
  want="${fixture#*:}"
  got="$(forgehub_pytest_summary_line "${TMP}/${name}.log")"
  if [[ "${got}" == "${want}" ]]; then
    ok "summary extracted from ${name}: '${got}'"
  else
    bad "summary from ${name}: expected '${want}', got '${got}'"
  fi
done

got="$(forgehub_pytest_summary_line "${TMP}/pytest-crashed.log")"
if [[ -z "${got}" ]]; then
  ok "crashed run yields no summary line (reported as <none found>)"
else
  bad "crashed run should yield no summary line, got '${got}'"
fi

echo "== baseline constant =="
if [[ "${FORGEHUB_EXPECTED_PASSED}" == "33" ]]; then
  ok "FORGEHUB_EXPECTED_PASSED is 33 (Task 1 x86_64 baseline, README.md)"
else
  bad "FORGEHUB_EXPECTED_PASSED is ${FORGEHUB_EXPECTED_PASSED}, expected 33"
fi

echo
echo "test-verify-logic: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
