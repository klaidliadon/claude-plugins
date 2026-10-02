#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
export PATH="$DIR/test/stubs:$PATH"
source "$DIR/bin/lib.sh"
export STUB_LOG="$T/log" STUB_GH_QUEUE="$T/queue"
PR=https://github.com/o/r/pull/7
for h in aaa bbb; do echo "{\"headRefOid\":\"$h\"}" >"$T/head-$h.json"; echo "diff at $h" >"$T/diff-$h"; done

printf '%s\n' "$T/head-aaa.json" "$T/diff-aaa" "$T/head-aaa.json" >"$STUB_GH_QUEUE"
assert_eq "$(pr_snapshot "$PR" "$T/round.diff")" "aaa"
assert_eq "$(cat "$T/round.diff")" "diff at aaa"

# The head moves between the first read and the diff: the retry captures bbb, and head and diff agree.
printf '%s\n' "$T/head-aaa.json" "$T/diff-bbb" "$T/head-bbb.json" "$T/head-bbb.json" "$T/diff-bbb" "$T/head-bbb.json" >"$STUB_GH_QUEUE"
assert_eq "$(pr_snapshot "$PR" "$T/round.diff")" "bbb"
assert_eq "$(cat "$T/round.diff")" "diff at bbb"
assert_eq "$(grep -c 'gh pr diff' "$STUB_LOG")" 3

printf '%s\n' "$T/head-aaa.json" "$T/diff-bbb" "$T/head-bbb.json" "$T/head-bbb.json" "$T/diff-aaa" "$T/head-aaa.json" >"$STUB_GH_QUEUE"
out="$(pr_snapshot "$PR" "$T/round.diff" 2>&1)"
assert_eq "$?" 1
assert_eq "$out" "pr_snapshot: the head of $PR moved twice during the capture"

printf '5xx\n' >"$STUB_GH_QUEUE"
assert_fail pr_snapshot "$PR" "$T/round.diff" 2>/dev/null

finish_tests snapshot
