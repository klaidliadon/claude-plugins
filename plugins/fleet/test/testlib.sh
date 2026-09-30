#!/usr/bin/env bash
set -uo pipefail

FAILS=0

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
