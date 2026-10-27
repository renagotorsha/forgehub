#!/usr/bin/env bash
# Pure predicates shared by verify-aarch64-deps.sh and exercised directly by
# tests/test-verify-logic.sh.
#
# These live in their own sourceable file for one reason: they are the two
# pieces of verify-aarch64-deps.sh whose bugs are invisible in a passing run.
# A gate that cannot tell "33 passed" from "33 skipped", and a fallback
# matcher that fires on pip's progress chatter instead of pip's failures,
# both look perfectly healthy every time the happy path is taken -- they only
# misbehave on the runs nobody wants to spend an hour of emulated CPU
# reproducing. Factored out here, they can be fed captured logs and asserted
# against in under a second on the host. Nothing in this file may touch the
# network, the filesystem beyond reading the file it is handed, or any global
# state: that is what makes it testable.
#
# Sourced by verify-aarch64-deps.sh; do not execute directly.

# The x86_64 baseline recorded by Task 1 on unmodified upstream code, and the
# standing requirement in packaging/android/README.md ("Later tasks must not
# reduce this count"). Named and defined once, here, so the aarch64 gate and
# Task 3's on-phone verification assert against the same number instead of
# each carrying its own copy.
#
# Deliberately NOT overridable by an environment variable. The whole point of
# this constant is that lowering the bar has to be a visible, reviewable edit
# to a tracked file -- not something a caller can do to make a red run go
# green. If upstream legitimately changes the suite size, update this and
# README.md together, in the same commit, with the new baseline re-recorded.
FORGEHUB_EXPECTED_PASSED=33

# forgehub_pip_failed_for <pip-log> <name-ere> [name-ere...]
#
# True only when the pip log contains a *resolution failure line naming one
# of the given packages*. This is the distinction that matters: a plain
# substring search for the package name matches pip's entirely benign
# progress output --
#
#   Collecting imageio-ffmpeg>=0.5.1 (from forgehub-backend==0.1.13)
#   Downloading uvloop-0.23.0-cp312-...-manylinux_2_28_aarch64.whl (4.4 MB)
#   Processing /wheels/uvloop-0.23.0-cp312-...-manylinux_2_28_aarch64.whl
#
# -- all of which appear in every successful run. A name-substring trigger
# therefore fires on *any* install failure that happens to occur after those
# lines, including the one failure this whole task exists to detect (a
# missing pydantic-core aarch64 wheel), and would quietly apply the two
# permitted fallbacks to a problem they have nothing to do with. Worse, it
# makes the loud-escalation branch nearly unreachable: it demands that
# neither name appear anywhere in a log that normally mentions both.
#
# So match pip's two failure phrasings instead, and require the package name
# to follow immediately. The trailing character class stops a name from
# matching as a prefix of a longer one ("imageio-ffmpeg" must not be
# satisfied by a failure naming "imageio-ffmpeg-extra") while still allowing
# the version specifier pip appends ("imageio-ffmpeg>=0.5.1").
#
# Callers pass EREs, so hyphen/underscore spellings can be covered with
# 'imageio[_-]ffmpeg' -- pip normalizes distribution names and either form
# shows up depending on whether the name came from metadata or a filename.
#
# Returns 2 (not 1) if the log is unreadable: "I could not tell" must never
# be mistaken for "this specific fallback does not apply".
forgehub_pip_failed_for() {
  local log="$1"
  shift
  [[ -r "${log}" ]] || return 2
  [[ "$#" -gt 0 ]] || return 2

  local alt
  alt="$(printf '%s|' "$@")"
  alt="${alt%|}"

  grep -qiE \
    "(No matching distribution found for|Could not find a version that satisfies the requirement)[[:space:]]+(${alt})([^[:alnum:]._-]|\$)" \
    "${log}"
}

# forgehub_pytest_summary_line <pytest-output-file>
#
# Echoes pytest's final counts line ("33 passed, 1 warning in 14.19s",
# "1 failed, 32 passed in 2.10s", "33 skipped in 1.20s", "no tests ran in
# 0.01s"), or nothing if the run produced no summary at all -- which is
# itself a result worth reporting, since it means pytest died before
# finishing.
forgehub_pytest_summary_line() {
  local out="$1"
  [[ -r "${out}" ]] || return 2
  grep -aE "^([0-9]+ (passed|failed|skipped|error|deselected|xfailed|xpassed)|no tests ran)" "${out}" | tail -n 1
}

# forgehub_assert_pytest_passed <pytest-output-file> <expected-count>
#
# True only when pytest reported exactly <expected-count> passed.
#
# pytest's exit code cannot carry this. It is 0 for "33 skipped", 0 for
# "12 passed, 21 skipped", and 0 for any collection that silently shrank --
# only an empty collection (exit 5) or an actual failure (exit 1) would trip
# an exit-code check. So a conftest change, or a dependency that makes the
# arch-sensitive tests skip rather than fail, would hand back a green
# "ALL CHECKS PASSED" while proving far less than the run claims. Since
# "the suite matches Task 1's x86_64 baseline exactly" is the comparison the
# spec names, the count is the assertion, and the exit code is only a
# precondition.
#
# Equality, not ">=": a count that moved in either direction means the
# baseline needs re-recording by a human (upstream added or removed tests),
# and silently accepting a larger number would also accept
# "34 passed, 20 skipped" as if nothing had changed.
#
# Anchoring at line start is what makes this precise -- pytest's progress
# output and warning bodies can mention numbers anywhere, but only the
# summary line begins with the count.
forgehub_assert_pytest_passed() {
  local out="$1"
  local expected="$2"
  [[ -r "${out}" ]] || return 2
  [[ -n "${expected}" ]] || return 2
  grep -qE "^${expected} passed([,[:space:]]|\$)" "${out}"
}
