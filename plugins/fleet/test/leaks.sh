#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"

# The repo is public: tracked files carry no local home paths and only synthetic ids (zeros, then a short counter).
uuid='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
synthetic_uuid='^00000000-0000-0000-0000-000000000[0-9a-f]{3}$'
orca_id='(task|ctx|run|msg|dcap)_[0-9a-f]{12}'
synthetic_orca_id='_000000000[0-9a-f]{3}$'

scan() {
  local f hits
  while IFS= read -r f; do
    [ "$f" != test/leaks.sh ] || continue
    hits="$(grep -nE '/User[s]/' "$1/$f")" && fail "local path in $f: $hits"
    hits="$(grep -oE "$uuid" "$1/$f" | grep -vE "$synthetic_uuid")" && fail "real-looking uuid in $f: $hits"
    hits="$(grep -oE "$orca_id" "$1/$f" | grep -vE "$synthetic_orca_id")" && fail "real-looking Orca id in $f: $hits"
  done < <(git -C "$1" ls-files)
}

scan "$DIR"

T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-test.XXXXXX")"
git init -q "$T/repo"
printf '{"id":"00000000-0000-0000-0000-000000000001","task":"task_000000000001"}\n' >"$T/repo/ok.json"
printf '{"path":"/%s/someone/x","id":"deadbeef-1234-4abc-8def-0123456789ab","task":"task_abcdef123456"}\n' Users >"$T/repo/bad.json"
git -C "$T/repo" add ok.json bad.json
before=$FAILS
out="$(scan "$T/repo"; echo "fails=$FAILS")"
assert_contains "$out" "local path in bad.json"
assert_contains "$out" "real-looking uuid in bad.json: deadbeef-1234-4abc-8def-0123456789ab"
assert_contains "$out" "real-looking Orca id in bad.json: task_abcdef123456"
assert_not_contains "$out" "ok.json"
assert_contains "$out" "fails=$((before + 3))"

finish_tests leaks
