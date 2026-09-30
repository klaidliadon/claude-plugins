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
echo run_17c08028b992 >"$FLEET_HOME/obj/run.id"
cat >"$TD/spec.md" <<'SPEC'
---
objective: obj
task: 1-api
repo: omsx
approved_at: "2026-09-30T19:00:00Z"
depends_on: []
pr: https://github.com/o/r/pull/7
orca:
  - round: 1
    kind: worker
    task_id: task_9819fc646159
    dispatch_id: ctx_b8a0ab53d622
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

STUB_ORCA_CHECK="$FX/orca/check-peek-question.json" out="$("$DIR/bin/fleet-status")"
assert_contains "$out" "1 ask"
assert_contains "$out" "answer question"

STUB_ORCA_FAIL=1 "$DIR/bin/fleet-status" >/dev/null 2>&1
assert_eq "$?" 1

yq --front-matter=process -i '.cleaned_at = "2026-10-02T00:00:00Z"' "$TD/spec.md"
assert_not_contains "$("$DIR/bin/fleet-status" --tsv)" "1-api"
finish_tests status
