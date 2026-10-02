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
  REVIEW_SKILL=none TASK_DIR=/f/reviews/r-7 REPO_PATH=/w/r REVIEWERS="adversarial, tests, architecture" \
  FOCUS="$(printf 'architecture: a & b\\c\n/x/')")"
assert_eq "$?" 0
assert_not_contains "$out" "{{"
assert_contains "$out" "run these fleet reviewers instead: adversarial, tests, architecture"
assert_contains "$out" "/w/r as \`<repo-path>\`"
assert_contains "$out" "$(printf 'architecture: a & b\\c\n/x/')"

assert_contains "$out" "Never write memory: the repo's auto memory is shared and read-only for you."
assert_contains "$out" "\`learned: <fact>\` lines; the manager decides what to keep."
rule9="$(sed -n 's/^9\. //p' "$DIR/templates/worker-contract.md")"
assert_contains "$rule9" "Never write memory"
assert_contains "$out" "- $rule9"

out="$("$FILL" "$DIR/templates/review-session.md" PR=x 2>&1)"
assert_eq "$?" 1
assert_eq "$out" "fleet-fill: unfilled {{FOCUS}} {{REPO_PATH}} {{REQUEST_LINK}} {{REVIEWERS}} {{REVIEW_SKILL}} {{TASK_DIR}}"

out="$("$FILL" "$DIR/prompts/spec-review.md" SPEC_PATH=/f/obj/1-a/spec.md SIBLINGS=none BASE=release/2 \
  OUT_PATH=/f/obj/1-a/spec-review.md)"
assert_eq "$?" 0
assert_not_contains "$out" "{{"
assert_contains "$out" "Base branch: \`origin/release/2\`"
assert_contains "$out" "checked against \`origin/release/2\`"
out="$("$FILL" "$DIR/prompts/spec-review.md" SPEC_PATH=x SIBLINGS=x OUT_PATH=x 2>&1)"
assert_eq "$?" 1
assert_eq "$out" "fleet-fill: unfilled {{BASE}}"

out="$("$FILL" "$DIR/templates/worker-contract.md" TASK_DIR=/t ROUND=1 ROUND_INPUT="")"
assert_eq "$?" 0
assert_contains "$out" "Never write memory"
assert_contains "$out" "learned: <fact>"
assert_not_contains "$out" "{{"
"$FILL" "$DIR/templates/worker-contract.md" TASK_DIR >/dev/null 2>&1
assert_eq "$?" 2

finish_tests fill
