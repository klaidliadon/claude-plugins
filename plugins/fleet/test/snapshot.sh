#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
export PATH="$DIR/test/stubs:$PATH"
source "$DIR/bin/lib.sh"
export STUB_LOG="$T/log" STUB_GH_QUEUE="$T/queue"
PR=https://github.com/o/r/pull/7
for h in aaa bbb; do echo "{\"headRefOid\":\"$h\"}" >"$T/head-$h.json"; echo "diff at $h" >"$T/diff-$h"; echo "path-$h.go" >"$T/names-$h"; done

printf '%s\n' "$T/head-aaa.json" "$T/diff-aaa" "$T/names-aaa" "$T/head-aaa.json" >"$STUB_GH_QUEUE"
assert_eq "$(pr_snapshot "$PR" "$T/round.diff")" "aaa"
assert_eq "$(cat "$T/round.diff")" "diff at aaa"
assert_eq "$(cat "$T/round.diff.names")" "path-aaa.go"
assert_contains "$(cat "$STUB_LOG")" "gh pr diff $PR --name-only"

# The head moves between the first read and the diff: the retry captures bbb, and head, diff and names agree.
: >"$STUB_LOG"
printf '%s\n' "$T/head-aaa.json" "$T/diff-bbb" "$T/names-bbb" "$T/head-bbb.json" "$T/head-bbb.json" "$T/diff-bbb" "$T/names-bbb" "$T/head-bbb.json" >"$STUB_GH_QUEUE"
assert_eq "$(pr_snapshot "$PR" "$T/round.diff")" "bbb"
assert_eq "$(cat "$T/round.diff")" "diff at bbb"
assert_eq "$(cat "$T/round.diff.names")" "path-bbb.go"
assert_eq "$(grep -c 'gh pr diff' "$STUB_LOG")" 4

printf '%s\n' "$T/head-aaa.json" "$T/diff-bbb" "$T/names-bbb" "$T/head-bbb.json" "$T/head-bbb.json" "$T/diff-aaa" "$T/names-aaa" "$T/head-aaa.json" >"$STUB_GH_QUEUE"
out="$(pr_snapshot "$PR" "$T/round.diff" 2>&1)"
assert_eq "$?" 1
assert_eq "$out" "pr_snapshot: the head of $PR moved twice during the capture"

printf '5xx\n' >"$STUB_GH_QUEUE"
assert_fail pr_snapshot "$PR" "$T/round.diff" 2>/dev/null

finish_tests snapshot
