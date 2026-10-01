#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
FILL="$DIR/bin/fleet-fill"

out="$("$FILL" "$DIR/prompts/adversarial-review.md" PR_URL=https://github.com/o/r/pull/7 SPEC_PATH=/f/obj/1-a/spec.md \
  DIFF_PATH=/f/obj/1-a/round-2.diff DECISIONS_PATH=/f/obj/decisions.md OUT_PATH=/f/obj/1-a/review-2-adversarial.md \
  PREVIOUS="Previous findings: /f/obj/1-a/review-1-adversarial.md")"
assert_eq "$?" 0
assert_not_contains "$out" "{{"
assert_contains "$out" "The diff is at /f/obj/1-a/round-2.diff"
assert_contains "$out" "/f/obj/decisions.md lists the objective's standing decisions"
assert_not_contains "$out" "gh pr diff"

out="$("$FILL" "$DIR/prompts/adversarial-review.md" PR_URL=x SPEC_PATH=x DIFF_PATH=x OUT_PATH=x PREVIOUS= 2>&1)"
assert_eq "$?" 1
assert_eq "$out" "fleet-fill: unfilled {{DECISIONS_PATH}}"

out="$("$FILL" "$DIR/templates/review-session.md" PR=https://github.com/o/r/pull/7 REQUEST_LINK=https://slack.example/p1 \
  REVIEW_SKILL=none TASK_DIR=/f/reviews/r-7 REVIEWERS="adversarial, tests, architecture" \
  FOCUS="$(printf 'architecture: a & b\\c\n/x/')")"
assert_eq "$?" 0
assert_not_contains "$out" "{{"
assert_contains "$out" "run these fleet reviewers instead: adversarial, tests, architecture"
assert_contains "$out" "$(printf 'architecture: a & b\\c\n/x/')"

out="$("$FILL" "$DIR/templates/review-session.md" PR=x 2>&1)"
assert_eq "$?" 1
assert_eq "$out" "fleet-fill: unfilled {{FOCUS}} {{REQUEST_LINK}} {{REVIEWERS}} {{REVIEW_SKILL}} {{TASK_DIR}}"

out="$("$FILL" "$DIR/templates/worker-contract.md" TASK_DIR=/t ROUND=1 ROUND_INPUT="")"
assert_eq "$?" 0
assert_not_contains "$out" "{{"
"$FILL" "$DIR/templates/worker-contract.md" TASK_DIR >/dev/null 2>&1
assert_eq "$?" 2

finish_tests fill
