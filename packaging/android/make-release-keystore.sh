#!/usr/bin/env bash
# Generates the local signing keystore for the WebView shell APK's release
# build (packaging/android/shell), OUTSIDE this repository.
#
# Controller ruling 4: the keystore must never live inside the working
# tree -- it would be one `git add -A` away from being committed, and the
# root .gitignore belongs to upstream and is off-limits for a defensive
# pattern here (packaging/android/shell/.gitignore already carries *.jks/
# *.keystore/*.p12 patterns as a backstop, but "don't put one here" is the
# real control). This script refuses outright if FORGEHUB_RELEASE_KEYSTORE
# points anywhere under this checkout.
#
# Idempotent by refusal, not by overwriting: re-running after the file
# exists FATALs rather than silently replacing a signing identity already
# in use -- an app re-signed with a different key can no longer be
# installed as an update over itself, so overwriting on request is a
# recoverable annoyance but overwriting by accident is not.
#
# Required environment: FORGEHUB_RELEASE_KEYSTORE_PASSWORD,
#                        FORGEHUB_RELEASE_KEY_PASSWORD (must be IDENTICAL to
#                        the keystore password -- see the check below for why).
# Optional environment: FORGEHUB_RELEASE_KEYSTORE (default:
#                        "${HOME}/forgehub-release.keystore" -- a sibling
#                        of, never inside, this checkout),
#                        FORGEHUB_RELEASE_KEY_ALIAS (default: "forgehub-shell").
#
# After this script succeeds, build the signed release with the same four
# FORGEHUB_RELEASE_* variables exported (app/build.gradle.kts's
# signingConfigs reads them -- see its own comment):
#   cd packaging/android/shell && ./gradlew :app:assembleRelease
set -euo pipefail

KEYSTORE="${FORGEHUB_RELEASE_KEYSTORE:-${HOME}/forgehub-release.keystore}"
ALIAS="${FORGEHUB_RELEASE_KEY_ALIAS:-forgehub-shell}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "${KEYSTORE}" in
  "${REPO_ROOT}"/*)
    echo "FATAL: FORGEHUB_RELEASE_KEYSTORE ('${KEYSTORE}') is inside the repository" >&2
    echo "FATAL: checkout (${REPO_ROOT}) -- controller ruling 4 requires the keystore" >&2
    echo "FATAL: to live outside the working tree entirely. Point it somewhere else," >&2
    echo "FATAL: e.g. leave FORGEHUB_RELEASE_KEYSTORE unset to use the default" >&2
    echo "FATAL: (\${HOME}/forgehub-release.keystore)." >&2
    exit 1
    ;;
esac

if [[ -z "${FORGEHUB_RELEASE_KEYSTORE_PASSWORD:-}" ]]; then
  echo "FATAL: FORGEHUB_RELEASE_KEYSTORE_PASSWORD is not set." >&2
  exit 1
fi
if [[ -z "${FORGEHUB_RELEASE_KEY_PASSWORD:-}" ]]; then
  echo "FATAL: FORGEHUB_RELEASE_KEY_PASSWORD is not set." >&2
  exit 1
fi
# keytool's default keystore type is PKCS12 (JDK 17's default, and this
# script does not override -storetype), and PKCS12 has no concept of a
# per-key password distinct from the store password: `keytool -genkeypair`
# silently IGNORES a differing -keypass and prints only a one-line warning
# ("Different store and key passwords not supported for PKCS12 KeyStores"),
# then uses the store password for the key entry anyway. Observed directly
# running this script, not a guess from documentation. Accepting two
# different values here would mean the keystore quietly ends up with a
# key password neither variable actually holds -- a mismatch nobody would
# notice until a much later `apksigner` or Gradle signing failure pointed
# at the wrong cause entirely. Refusing here, loudly, instead.
if [[ "${FORGEHUB_RELEASE_KEY_PASSWORD}" != "${FORGEHUB_RELEASE_KEYSTORE_PASSWORD}" ]]; then
  echo "FATAL: FORGEHUB_RELEASE_KEY_PASSWORD differs from" >&2
  echo "FATAL: FORGEHUB_RELEASE_KEYSTORE_PASSWORD. PKCS12 keystores (this script's" >&2
  echo "FATAL: default) force them to be the same value -- keytool would silently" >&2
  echo "FATAL: ignore your key password and use the store password instead, leaving" >&2
  echo "FATAL: the keystore's real key password different from what you think you" >&2
  echo "FATAL: set. Set both environment variables to the SAME value." >&2
  exit 1
fi

KEYTOOL="${JAVA_HOME:-/home/deploy/jdk17}/bin/keytool"
if [[ ! -x "${KEYTOOL}" ]]; then
  if command -v keytool >/dev/null 2>&1; then
    KEYTOOL="$(command -v keytool)"
  else
    echo "FATAL: no keytool found at '${KEYTOOL}' or on PATH -- JDK 17 required" >&2
    echo "FATAL: (set JAVA_HOME, or install to /home/deploy/jdk17 per the project's" >&2
    echo "FATAL: documented toolchain layout)." >&2
    exit 1
  fi
fi

if [[ -e "${KEYSTORE}" ]]; then
  echo "FATAL: ${KEYSTORE} already exists -- refusing to overwrite a signing" >&2
  echo "FATAL: identity that may already be in use. Delete it yourself first if" >&2
  echo "FATAL: you really mean to replace it (this invalidates in-place updates of" >&2
  echo "FATAL: any APK already installed from the old key)." >&2
  exit 1
fi

mkdir -p "$(dirname "${KEYSTORE}")"

echo "== generating ${KEYSTORE} (alias: ${ALIAS}) =="
"${KEYTOOL}" -genkeypair \
  -keystore "${KEYSTORE}" \
  -storepass "${FORGEHUB_RELEASE_KEYSTORE_PASSWORD}" \
  -alias "${ALIAS}" \
  -keypass "${FORGEHUB_RELEASE_KEY_PASSWORD}" \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=ForgeHub Shell, OU=Personal, O=Personal, L=Unknown, ST=Unknown, C=XX"

chmod 600 "${KEYSTORE}"
echo "== ${KEYSTORE} created, mode 600 =="
echo ""
echo "Export these before building a signed release (same values used above):"
echo "  export FORGEHUB_RELEASE_KEYSTORE='${KEYSTORE}'"
echo "  export FORGEHUB_RELEASE_KEYSTORE_PASSWORD='<password you set>'"
echo "  export FORGEHUB_RELEASE_KEY_ALIAS='${ALIAS}'"
echo "  export FORGEHUB_RELEASE_KEY_PASSWORD='<password you set>'"
