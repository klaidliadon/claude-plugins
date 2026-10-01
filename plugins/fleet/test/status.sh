#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
export PATH="$DIR/test/stubs:$PATH"
FX="$DIR/test/fixtures"

T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-test.XXXXXX")"
export FLEET_HOME="$T/fleet" STUB_LOG="$T/log" STUB_GH_PR="$FX/gh/pr-open.json"
export STUB_ORCA_TASKS="$FX/orca/task-list-completed.json" STUB_ORCA_CHECK="$T/check-empty.json"
echo '{"ok":true,"result":{"messages":[]}}' >"$STUB_ORCA_CHECK"
TD="$FLEET_HOME/obj/1-api"
mkdir -p "$TD"
echo run_000000000001 >"$FLEET_HOME/obj/run.id"
cat >"$TD/spec.md" <<'SPEC'
---
objective: obj
task: 1-api
repo: app
approved_at: "2026-09-30T19:00:00Z"
depends_on: []
pr: https://github.com/o/r/pull/7
orca:
  - round: 1
    kind: worker
    task_id: task_000000000006
    dispatch_id: ctx_000000000007
    reviewers: [adversarial, tests]
---
body
SPEC
touch "$TD/spec-review.md"
printf '<!-- counts: critical=0 important=0 suggestion=0 -->\n' >"$TD/review-1-adversarial.md"
printf '## findings without a header\n' >"$TD/review-1-tests.md"

out="$("$DIR/bin/fleet-status" --tsv)"
assert_contains "$out" $'obj\t1-api\tin-review\trun reviews round 1'

printf '<!-- counts: critical=0 important=2 suggestion=1 -->\n' >"$TD/review-1-tests.md"
out="$("$DIR/bin/fleet-status" --tsv)"
assert_contains "$out" $'obj\t1-api\tin-review\tstart fix round 2'
out="$("$DIR/bin/fleet-status")"
assert_contains "$out" "🟡2 🟢1"
assert_contains "$out" "#7"

STUB_ORCA_CHECK="$FX/orca/check-all.json" out="$("$DIR/bin/fleet-status")"
assert_contains "$out" "1 ask"
assert_contains "$out" "answer question"
echo msg_000000000008 >"$FLEET_HOME/obj/answered"
STUB_ORCA_CHECK="$FX/orca/check-all.json" out="$("$DIR/bin/fleet-status")"
assert_not_contains "$out" "ask"

for fx in pr-status-failure pr-cancelled; do
  STUB_GH_PR="$FX/gh/$fx.json" out="$("$DIR/bin/fleet-status")"
  assert_contains "$out" "❌"
done
STUB_GH_PR="$FX/gh/pr-status-pending.json" out="$("$DIR/bin/fleet-status")"
assert_contains "$out" "⏳"

STUB_ORCA_FAIL=1 "$DIR/bin/fleet-status" >/dev/null 2>"$T/err"
assert_eq "$?" 1
assert_eq "$(cat "$T/err")" "fleet-status: orca unreachable"

assert_not_contains "$(cat "$STUB_LOG")" "worker-show"

shown() {
  jq --argjson t "$1" '.result.terminal.lastOutputAt = $t' "$FX/orca/worker-show-fresh.json" >"$T/shown.json"
  echo "$T/shown.json"
}
ago() { echo $((($(date +%s) - $1) * 1000)); }
export STUB_ORCA_TASKS="$FX/orca/task-list-running.json"
out="$(STUB_ORCA_WORKER_SHOW="$FX/orca/worker-show-stale.json" "$DIR/bin/fleet-status" --tsv)"
assert_contains "$out" $'obj\t1-api\tpr-open\tworker stalled: inspect'
assert_contains "$(cat "$STUB_LOG")" "orca orchestration worker-show --dispatch ctx_000000000007 --json"
out="$(STUB_ORCA_WORKER_SHOW="$(shown "$(ago 0)")" "$DIR/bin/fleet-status" --tsv)"
assert_contains "$out" $'obj\t1-api\tpr-open\twait worker'
out="$(STUB_ORCA_WORKER_SHOW="$(shown "$(ago 120)")" "$DIR/bin/fleet-status" --tsv)"
assert_contains "$out" $'obj\t1-api\tpr-open\twait worker'
out="$(STUB_ORCA_WORKER_SHOW="$(shown "$(ago 120)")" FLEET_STALL_MIN=1 "$DIR/bin/fleet-status" --tsv)"
assert_contains "$out" $'obj\t1-api\tpr-open\tworker stalled: inspect'
out="$(STUB_ORCA_WORKER_SHOW="$(shown "$(ago 120)")" FLEET_STALL_MIN=08 "$DIR/bin/fleet-status" --tsv 2>"$T/err")"
assert_eq "$?" 0
assert_contains "$out" $'obj\t1-api\tpr-open\twait worker'
assert_eq "$(cat "$T/err")" ""
for bad in 0 00 abc -5 1.5; do
  FLEET_STALL_MIN="$bad" "$DIR/bin/fleet-status" --tsv >/dev/null 2>"$T/err"
  assert_eq "$?" 1
  assert_eq "$(cat "$T/err")" "fleet-status: FLEET_STALL_MIN must be a positive integer"
done
out="$("$DIR/bin/fleet-status" --tsv 2>"$T/err")"
assert_eq "$?" 0
assert_contains "$out" $'obj\t1-api\tpr-open\twait worker'
assert_eq "$(cat "$T/err")" ""
jq 'del(.result.terminal.lastOutputAt)' "$FX/orca/worker-show-stale.json" >"$T/no-output.json"
out="$(STUB_ORCA_WORKER_SHOW="$T/no-output.json" "$DIR/bin/fleet-status" --tsv)"
assert_contains "$out" $'obj\t1-api\tpr-open\twait worker'
for variant in \
  '.result.observation.agentWait = {"kind": "permission_prompt"}' \
  'del(.result.observation)' \
  '.result.terminal.lastOutputAt = "1790798400000"' \
  '{id, ok: false, error: {code: "dispatch_not_found", message: "no such dispatch"}}'; do
  jq "$variant" "$FX/orca/worker-show-stale.json" >"$T/variant.json"
  out="$(STUB_ORCA_WORKER_SHOW="$T/variant.json" "$DIR/bin/fleet-status" --tsv 2>"$T/err")"
  assert_eq "$?" 0
  assert_contains "$out" $'obj\t1-api\tpr-open\twait worker'
  assert_eq "$(cat "$T/err")" ""
done
jq 'del(.result.observation.agentWait)' "$FX/orca/worker-show-stale.json" >"$T/no-wait-key.json"
out="$(STUB_ORCA_WORKER_SHOW="$T/no-wait-key.json" "$DIR/bin/fleet-status" --tsv)"
assert_contains "$out" $'obj\t1-api\tpr-open\twait worker'
jq --arg d "$(date -u +'%Y-%m-%d %H:%M:%S')" '.result.dispatch.dispatchedAt = $d' "$FX/orca/worker-show-stale.json" >"$T/fresh-dispatch.json"
out="$(STUB_ORCA_WORKER_SHOW="$T/fresh-dispatch.json" "$DIR/bin/fleet-status" --tsv)"
assert_contains "$out" $'obj\t1-api\tpr-open\twait worker'
jq '.result.tasks[0].status = "blocked"' "$FX/orca/task-list-running.json" >"$T/task-list-blocked.json"
out="$(STUB_ORCA_TASKS="$T/task-list-blocked.json" "$DIR/bin/fleet-status" --tsv)"
assert_contains "$out" $'obj\t1-api\tpr-open\trelease stopped round 1'
export STUB_ORCA_TASKS="$FX/orca/task-list-completed.json"

mkdir -p "$FLEET_HOME/obj2/1-a" "$FLEET_HOME/obj2/2-b"
echo run_fenced0000 >"$FLEET_HOME/obj2/run.id"
for t in 1-a 2-b; do
  printf -- '---\nobjective: obj2\ntask: %s\nrepo: app\napproved_at: "2026-09-30T19:00:00Z"\ndepends_on: []\n---\nbody\n' "$t" >"$FLEET_HOME/obj2/$t/spec.md"
done
export STUB_ORCA_FENCED_RUN=run_fenced0000 STUB_ORCA_FENCED="$FX/orca/error-consumer-fenced.json"
for code in 0 1; do
  out="$(STUB_ORCA_FENCED_EXIT="$code" "$DIR/bin/fleet-status" --tsv 2>"$T/err")"
  assert_eq "$?" 0
  assert_contains "$out" $'obj\t1-api\tin-review\tstart fix round 2'
  assert_contains "$out" $'obj2\t1-a\tapproved\trebind: orca orchestration run-use --id run_fenced0000'
  assert_contains "$out" $'obj2\t2-b\tapproved\trebind: orca orchestration run-use --id run_fenced0000'
  assert_eq "$(cat "$T/err")" ""
done
out="$(STUB_ORCA_FENCE_TASKS=1 "$DIR/bin/fleet-status" --tsv 2>"$T/err")"
assert_eq "$?" 0
assert_contains "$out" $'obj2\t1-a\tapproved\trebind: orca orchestration run-use --id run_fenced0000'
assert_contains "$out" $'obj\t1-api\tin-review\tstart fix round 2'
assert_eq "$(cat "$T/err")" ""
out="$("$DIR/bin/fleet-status")"
assert_contains "$out" "fenced"
unset STUB_ORCA_FENCED_RUN
rm -rf "$FLEET_HOME/obj2"

echo '{"id":"1b2c","ok":false,"error":{"code":"run_not_found","message":"Run run_000000000001 not found."},"_meta":{}}' >"$T/check-error.json"
STUB_ORCA_CHECK="$T/check-error.json" "$DIR/bin/fleet-status" >/dev/null 2>"$T/err"
assert_eq "$?" 1
assert_eq "$(cat "$T/err")" "fleet-status: orca run_not_found: Run run_000000000001 not found."

yq --front-matter=process -i '.cleaned_at = "2026-10-02T00:00:00Z"' "$TD/spec.md"
assert_not_contains "$("$DIR/bin/fleet-status" --tsv)" "1-api"

export STUB_ORCA_CHECK="$T/check-empty.json"
printf 'review_requests:\n  sources:\n    - slack: "#team"\n      repos: [o/app]\n' >"$FLEET_HOME/config.yaml"
"$DIR/bin/fleet-review-request" add "#team" https://github.com/o/app/pull/7 alice https://slack.example/p1 2026-10-01T09:00:00Z C0TEAM 1759312800.000100 >/dev/null
RS="$FLEET_HOME/reviews/o+app+7/spec.md"
review_next() { "$DIR/bin/fleet-status" --tsv | grep $'^reviews\to+app+7\t'; }
assert_eq "$(review_next)" $'reviews\to+app+7\treview\task review'
for a in later no; do
  yq --front-matter=process -i ".answer = \"$a\"" "$RS"
  assert_eq "$(review_next)" $'reviews\to+app+7\treview\tskipped'
done
yq --front-matter=process -i '.answer = "yes"' "$RS"
assert_eq "$(review_next)" $'reviews\to+app+7\treview\tstart review session'
echo run_000000000001 >"$FLEET_HOME/reviews/run.id"
yq --front-matter=process -i '.session = {"task_id": "task_000000000006", "dispatch_id": "ctx_000000000007", "terminal": "term_x", "worktree_path": "/w"}' "$RS"
assert_eq "$(STUB_ORCA_TASKS="$FX/orca/task-list-running.json" review_next)" $'reviews\to+app+7\treview\twait review session'
out="$(STUB_ORCA_TASKS="$FX/orca/task-list-running.json" STUB_ORCA_CHECK="$FX/orca/check-all.json" "$DIR/bin/fleet-status")"
assert_contains "$(grep o+app+7 <<<"$out")" "answer question"
assert_eq "$(STUB_ORCA_TASKS="$FX/orca/task-list-running.json" STUB_ORCA_WORKER_SHOW="$FX/orca/worker-show-stale.json" review_next)" $'reviews\to+app+7\treview\treview session stalled: inspect'
assert_eq "$(review_next)" $'reviews\to+app+7\treview\tdone'
jq '.result.tasks[0].status = "failed"' "$FX/orca/task-list-running.json" >"$T/task-list-failed.json"
assert_eq "$(STUB_ORCA_TASKS="$T/task-list-failed.json" review_next)" $'reviews\to+app+7\treview\treview session failed: inspect'
yq --front-matter=process -i '.cleaned_at = "2026-10-02T00:00:00Z"' "$RS"
assert_not_contains "$("$DIR/bin/fleet-status" --tsv)" "o+app+7"
finish_tests status
