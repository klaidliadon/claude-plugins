#!/usr/bin/env bash
set -uo pipefail

FAILS=0

# Every test gets a fresh scratch FLEET_HOME. Without one, the fleet scripts would fall back to the real
# ~/Workspace/.fleet, so a failed mktemp aborts the test before anything can write.
T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-test.XXXXXX" 2>/dev/null)" || T=""
[ -n "$T" ] && [ -d "$T" ] || { echo "testlib: mktemp -d failed; refusing to run without a scratch FLEET_HOME" >&2; exit 1; }
export FLEET_HOME="$T/fleet"

fail() {
  echo "FAIL: $*"
  FAILS=$((FAILS + 1))
}

assert_ok() {
  "$@" || fail "expected success: $*"
}

assert_fail() {
  if "$@"; then
    fail "expected failure: $*"
  fi
}

assert_eq() {
  [ "$1" = "$2" ] || fail "'$1' != '$2'"
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "output lacks: $2" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "output unexpectedly contains: $2" ;;
    *) ;;
  esac
}

finish_tests() {
  local label="$1"
  if [ "$FAILS" -ne 0 ]; then
    echo "$FAILS failures"
    exit 1
  fi
  echo "$label PASS"
}
