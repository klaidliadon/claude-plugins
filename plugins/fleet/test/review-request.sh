#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
export PATH="$DIR/test/stubs:$PATH"

export STUB_LOG="$T/log" STUB_GH_PR="$T/pr.json" STUB_GH_USER="$T/user.json"
echo '{"login":"me"}' >"$STUB_GH_USER"
RR="$DIR/bin/fleet-review-request"
PR=https://github.com/o/app/pull/12

pr_json() {
  printf '{"state":"%s","author":{"login":"%s"},"reviews":%s}' "$1" "$2" "${3:-[]}" >"$STUB_GH_PR"
}
add() {
  OUT="$("$RR" add "#team" "$1" alice https://slack.example/p1 2026-10-01T09:00:00Z C0TEAM 1759312800.000100 2>&1)"
  RC=$?
}

assert_eq "$("$RR" cursor "#team")" ""
assert_ok "$RR" cursor "#team" 1759312800.000100
assert_ok "$RR" cursor "#other" 1759312000.000001
assert_eq "$("$RR" cursor "#team")" "1759312800.000100"
assert_ok "$RR" cursor "#team" 1759316400.000200
assert_eq "$("$RR" cursor "#team")" "1759316400.000200"
assert_eq "$("$RR" cursor "#other")" "1759312000.000001"

pr_json OPEN bob
add "$PR"
assert_eq "$RC" 0; assert_eq "$OUT" "skip $PR: o/app is not configured for #team"
assert_fail test -e "$FLEET_HOME/reviews"

cat >"$FLEET_HOME/config.yaml" <<'YAML'
review_requests:
  sources:
    - slack: "#team"
      repos: [o/app, o/web]
    - slack: "#other"
      repos: [o/api]
  skip: {authors: [me, dependabot], already_reviewer: true}
YAML
add https://github.com/o/api/pull/1
assert_eq "$OUT" "skip https://github.com/o/api/pull/1: o/api is not configured for #team"
add https://github.com/o/app/issues/12
assert_eq "$RC" 2; assert_contains "$OUT" "not a PR URL"
pr_json MERGED bob; add "$PR"
assert_eq "$OUT" "skip $PR: PR is MERGED"
pr_json OPEN dependabot; add "$PR"
assert_eq "$OUT" "skip $PR: author dependabot is skipped"
pr_json OPEN bob '[{"author":{"login":"me"},"state":"COMMENTED"}]'; add "$PR"
assert_eq "$OUT" "skip $PR: me already reviewed it"
assert_fail test -e "$FLEET_HOME/reviews/o+app+12"

pr_json OPEN bob '[{"author":{"login":"carol"},"state":"APPROVED"}]'; add "$PR"
assert_eq "$RC" 0; assert_eq "$OUT" "created $FLEET_HOME/reviews/o+app+12/spec.md"
S="$FLEET_HOME/reviews/o+app+12/spec.md"
assert_eq "$(yq --front-matter=extract -o=json -I=0 '.' "$S")" \
  '{"objective":"reviews","task":"o+app+12","kind":"review","pr":"'"$PR"'","repo":"app","repo_slug":"o/app","requested_by":"alice","request_link":"https://slack.example/p1","asked_at":"2026-10-01T09:00:00Z","request_channel":"C0TEAM","request_ts":"1759312800.000100","answer":null,"session":{"task_id":null,"dispatch_id":null,"terminal":null,"worktree_path":null}}'
assert_contains "$(cat "$FLEET_HOME/ledger.md")" "review-request $PR from alice"

: >"$STUB_LOG"
add "$PR"
assert_eq "$RC" 0; assert_eq "$OUT" "skip $PR: already tracked in $S"
assert_not_contains "$(cat "$STUB_LOG")" "gh pr view"
yq --front-matter=process -i '.answer = "no" | .cleaned_at = "2026-10-02T00:00:00Z"' "$S"
add "$PR"
assert_eq "$OUT" "skip $PR: already tracked in $S"

yq -i '.review_requests.skip.already_reviewer = false' "$FLEET_HOME/config.yaml"
pr_json OPEN bob '[{"author":{"login":"me"},"state":"COMMENTED"}]'; add https://github.com/o/web/pull/3
assert_eq "$OUT" "created $FLEET_HOME/reviews/o+web+3/spec.md"

pr_json OPEN bob
yq -i '.review_requests.sources[0].repos += ["o2/web"]' "$FLEET_HOME/config.yaml"
add https://github.com/o2/web/pull/3
assert_eq "$RC" 0; assert_eq "$OUT" "created $FLEET_HOME/reviews/o2+web+3/spec.md"

mkdir -p "$FLEET_HOME/reviews/o+web+5"
add https://github.com/o/web/pull/5
assert_eq "$RC" 0; assert_eq "$OUT" "created $FLEET_HOME/reviews/o+web+5/spec.md"
assert_eq "$(ls -A "$FLEET_HOME/reviews/o+web+5")" "spec.md"

STUB_GH_FAIL="pr view" add https://github.com/o/web/pull/6
assert_eq "$RC" 1; assert_fail test -e "$FLEET_HOME/reviews/o+web+6"
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\n[ "$1" = -n ] && exit 1\nexec %s "$@"\n' "$(command -v yq)" >"$T/bin/yq"
chmod +x "$T/bin/yq"
PATH="$T/bin:$PATH" add https://github.com/o/web/pull/7
assert_eq "$RC" 1; assert_eq "$(ls -A "$FLEET_HOME/reviews/o+web+7")" ""
add https://github.com/o/web/pull/7
assert_eq "$OUT" "created $FLEET_HOME/reviews/o+web+7/spec.md"

yq -i '.review_requests.sources[0].repos += ["a-b/c", "a/b-c"]' "$FLEET_HOME/config.yaml"
add https://github.com/a-b/c/pull/1
assert_eq "$OUT" "created $FLEET_HOME/reviews/a-b+c+1/spec.md"
add https://github.com/a/b-c/pull/1
assert_eq "$OUT" "created $FLEET_HOME/reviews/a+b-c+1/spec.md"
assert_eq "$(yq --front-matter=extract '.repo_slug' "$FLEET_HOME/reviews/a+b-c+1/spec.md")" "a/b-c"

mkdir "$FLEET_HOME/reviews/.lock-o+web+8"
add https://github.com/o/web/pull/8
assert_eq "$RC" 1; assert_contains "$OUT" ".lock-o+web+8 is held"
assert_fail test -e "$FLEET_HOME/reviews/o+web+8"
rmdir "$FLEET_HOME/reviews/.lock-o+web+8"
add https://github.com/o/web/pull/8
assert_eq "$OUT" "created $FLEET_HOME/reviews/o+web+8/spec.md"
assert_fail test -e "$FLEET_HOME/reviews/.lock-o+web+8"
# A lock older than FLEET_LOCK_TTL is stale: add takes it over instead of failing.
mkdir "$FLEET_HOME/reviews/.lock-o+web+10"
touch -t 202001010000 "$FLEET_HOME/reviews/.lock-o+web+10"
add https://github.com/o/web/pull/10
assert_eq "$RC" 0; assert_eq "$OUT" "created $FLEET_HOME/reviews/o+web+10/spec.md"
assert_fail test -e "$FLEET_HOME/reviews/.lock-o+web+10"
mkdir "$FLEET_HOME/reviews/.lock-o+web+11"
touch -t "$(date -v-2M +%Y%m%d%H%M 2>/dev/null || date -d '-2 min' +%Y%m%d%H%M)" "$FLEET_HOME/reviews/.lock-o+web+11"
FLEET_LOCK_TTL=600 add https://github.com/o/web/pull/11
assert_eq "$RC" 1; assert_contains "$OUT" ".lock-o+web+11 is held"
FLEET_LOCK_TTL=60 add https://github.com/o/web/pull/11
assert_eq "$RC" 0; assert_eq "$OUT" "created $FLEET_HOME/reviews/o+web+11/spec.md"

yq -i '.review_requests.skip.already_reviewer = true' "$FLEET_HOME/config.yaml"
STUB_GH_FAIL="api user" add https://github.com/o/web/pull/9
assert_eq "$RC" 1; assert_fail test -e "$FLEET_HOME/reviews/o+web+9"
assert_fail test -e "$FLEET_HOME/reviews/.lock-o+web+9"

# Two concurrent creators of the reviews Run: exactly one run-create, and both print the same id.
export STUB_ORCA_RUNS="$T/runs.json" STUB_ORCA_CREATE="$DIR/test/fixtures/orca/run-create.json"
echo '{"ok":true,"result":{"runs":[],"nextCursor":null}}' >"$STUB_ORCA_RUNS"
: >"$STUB_LOG"
STUB_ORCA_CREATE_SLEEP=1 "$RR" run >"$T/run-a" 2>&1 &
STUB_ORCA_CREATE_SLEEP=1 "$RR" run >"$T/run-b" 2>&1 &
wait
assert_eq "$(grep -c 'run-create' "$STUB_LOG")" 1
assert_eq "$(cat "$T/run-a")" run_000000000001
assert_eq "$(cat "$T/run-b")" run_000000000001
assert_eq "$(cat "$FLEET_HOME/reviews/run.id")" run_000000000001
assert_contains "$(cat "$STUB_LOG")" "run-create --objective reviews $FLEET_HOME --json"
assert_fail test -e "$FLEET_HOME/reviews/.run.lock"
: >"$STUB_LOG"
assert_eq "$("$RR" run)" run_000000000001
assert_not_contains "$(cat "$STUB_LOG")" "orca"
# Without run.id, an existing Run with this fleet's objective is adopted, the oldest when there are several.
rm "$FLEET_HOME/reviews/run.id"
jq -n --arg o "reviews $FLEET_HOME" '{ok: true, result: {runs: [
  {id: "run_000000000003", objective: $o, created_at: "2026-10-02T00:00:00Z"},
  {id: "run_000000000002", objective: $o, created_at: "2026-10-01T00:00:00Z"},
  {id: "run_000000000004", objective: "reviews /elsewhere", created_at: "2026-09-01T00:00:00Z"}]}}' >"$STUB_ORCA_RUNS"
OUT="$("$RR" run 2>"$T/err")"
assert_eq "$OUT" run_000000000002
assert_contains "$(cat "$T/err")" "2 Runs are named"
assert_not_contains "$(cat "$STUB_LOG")" "run-create"
rm "$FLEET_HOME/reviews/run.id"
echo '{"ok":false,"error":{"code":"x"}}' >"$STUB_ORCA_RUNS"
OUT="$("$RR" run 2>&1)"
assert_eq "$?" 1; assert_eq "$OUT" "fleet-review-request: orca run-list failed"
assert_fail test -e "$FLEET_HOME/reviews/run.id"
echo '{"ok":true,"result":{"runs":[]}}' >"$STUB_ORCA_RUNS"
echo '{"ok":false,"error":{"code":"x"}}' >"$T/create-fail.json"
OUT="$(STUB_ORCA_CREATE="$T/create-fail.json" "$RR" run 2>&1)"
assert_eq "$?" 1; assert_eq "$OUT" "fleet-review-request: orca run-create failed"
assert_fail test -e "$FLEET_HOME/reviews/run.id"

# run takes over a stale .run.lock.
rm -f "$FLEET_HOME/reviews/run.id"
mkdir "$FLEET_HOME/reviews/.run.lock"
touch -t 202001010000 "$FLEET_HOME/reviews/.run.lock"
assert_eq "$("$RR" run)" run_000000000001
assert_fail test -e "$FLEET_HOME/reviews/.run.lock"

# Two contenders against one stale lock: exactly one takes it, and the loser's release never removes it.
# A stat stub that answers late makes both read the lock as stale before either breaks it.
source "$DIR/bin/lib.sh"
mkdir -p "$T/slowstat"
printf '#!/usr/bin/env bash\nout="$(%s "$@")"; rc=$?\nsleep 0.3\nprintf "%%s\\n" "$out"\nexit $rc\n' "$(command -v stat)" >"$T/slowstat/stat"
chmod +x "$T/slowstat/stat"
for i in 1 2 3; do
  L="$T/race-$i"
  mkdir "$L"
  touch -t 202001010000 "$L"
  for c in a b; do
    (PATH="$T/slowstat:$PATH"; lock_take "$L" && { echo "$c" >>"$T/race-$i.won"; sleep 1; }; lock_release "$L") &
  done
  wait
  assert_eq "$(wc -l <"$T/race-$i.won" | tr -d ' ')" 1
done
L="$T/owned"
lock_take "$L"
mine="$LOCK_OWNER"
LOCK_OWNER=someone-else lock_release "$L"
assert_ok test -d "$L"
LOCK_OWNER="$mine" lock_release "$L"
assert_fail test -e "$L"
# A crash mid-takeover leaves a stale breaker; the next taker clears it.
mkdir "$L" "$L.break"
touch -t 202001010000 "$L" "$L.break"
assert_ok lock_take "$L"
assert_fail test -e "$L.break"

echo '[1]' >"$FLEET_HOME/review-requests.cursor"
assert_fail "$RR" cursor "#team" 1759316400.000300 2>/dev/null
assert_eq "$(cat "$FLEET_HOME/review-requests.cursor")" "[1]"

OUT="$("$RR" add "#team" "$PR" alice 2>&1)"
assert_eq "$?" 2; assert_contains "$OUT" "usage:"
OUT="$("$RR" nope 2>&1)"
assert_eq "$?" 2; assert_contains "$OUT" "usage:"

finish_tests review-request
