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
  OUT="$("$RR" add C0TEAM "$1" U0ALICE https://acme.slack.com/archives/C0TEAM/p1759312800000100 2026-10-01T09:00:00Z C0TEAM 1759312800.000100 2>&1)"
  RC=$?
}

# A source is a Slack channel ID. C is one character short of the shortest ID, C0; a channel name and a
# lowercase ID, another first letter and a dash fail too, and no rejection writes the cursor file.
for bad in C '#some-channel' c0team X0ABC C0-T; do
  for args in "cursor $bad" "cursor $bad 1759312800.000100"; do
    OUT="$("$RR" $args 2>&1)"
    assert_eq "$?" 2; assert_eq "$OUT" "fleet-review-request: source must be a Slack channel ID: $bad"
  done
  OUT="$("$RR" add "$bad" "$PR" U0ALICE https://acme.slack.com/archives/C0TEAM/p1759312800000100 2026-10-01T09:00:00Z C0TEAM 1759312800.000100 2>&1)"
  assert_eq "$?" 2; assert_eq "$OUT" "fleet-review-request: source must be a Slack channel ID: $bad"
  assert_fail test -e "$FLEET_HOME/review-requests.cursor"
done
# A cursor stored under the old channel name is not read for the channel ID, and reading leaves it as it was.
mkdir -p "$FLEET_HOME"
printf '"#team": "1759312000.000001"\n' >"$FLEET_HOME/review-requests.cursor"
cp "$FLEET_HOME/review-requests.cursor" "$T/cursor.old"
assert_eq "$("$RR" cursor C0TEAM)" ""
assert_ok cmp -s "$T/cursor.old" "$FLEET_HOME/review-requests.cursor"
assert_ok "$RR" cursor C0TEAM 1759312800.000100
assert_ok "$RR" cursor C0OTHER 1759312000.000001
assert_eq "$("$RR" cursor C0TEAM)" "1759312800.000100"
assert_ok "$RR" cursor C0TEAM 1759316400.000200
assert_eq "$("$RR" cursor C0TEAM)" "1759316400.000200"
assert_eq "$("$RR" cursor C0OTHER)" "1759312000.000001"
assert_ok grep -qFx "$(cat "$T/cursor.old")" "$FLEET_HOME/review-requests.cursor"
for ok in C0 G0 D0; do
  assert_ok "$RR" cursor "$ok" 1759312800.000300
  assert_eq "$("$RR" cursor "$ok")" "1759312800.000300"
done

pr_json OPEN bob
add "$PR"
assert_eq "$RC" 0; assert_eq "$OUT" "skip $PR: o/app is not configured for C0TEAM"
OUT="$("$RR" add C0 "$PR" U0ALICE https://acme.slack.com/archives/C0/p1759312800000100 2026-10-01T09:00:00Z C0 1759312800.000100 2>&1)"
assert_eq "$?" 0; assert_eq "$OUT" "skip $PR: o/app is not configured for C0"
assert_fail test -e "$FLEET_HOME/reviews"

cat >"$FLEET_HOME/config.yaml" <<'YAML'
review_requests:
  sources:
    - slack: C0TEAM
      repos: [o/app, o/web]
    - slack: C0OTHER
      repos: [o/api]
  skip: {authors: [me, dependabot], already_reviewer: true}
YAML
add https://github.com/o/api/pull/1
assert_eq "$OUT" "skip https://github.com/o/api/pull/1: o/api is not configured for C0TEAM"
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
  '{"objective":"reviews","task":"o+app+12","kind":"review","pr":"'"$PR"'","repo":"app","repo_slug":"o/app","requested_by":"U0ALICE","request_link":"https://acme.slack.com/archives/C0TEAM/p1759312800000100","asked_at":"2026-10-01T09:00:00Z","request_channel":"C0TEAM","request_ts":"1759312800.000100","answer":null,"session":{"task_id":null,"dispatch_id":null,"terminal":null,"worktree_path":null}}'
assert_contains "$(cat "$FLEET_HOME/ledger.md")" "review-request $PR from U0ALICE"

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
# A reply without a runs array is a failed list, not an empty one: it never creates a Run.
for reply in '{"ok":true,"result":{}}' '{"ok":true,"result":{"runs":null}}'; do
  echo "$reply" >"$STUB_ORCA_RUNS"
  : >"$STUB_LOG"
  OUT="$("$RR" run 2>&1)"
  assert_eq "$?" 1; assert_eq "$OUT" "fleet-review-request: orca run-list failed"
  assert_eq "$(grep -c 'run-create' "$STUB_LOG")" 0
  assert_fail test -e "$FLEET_HOME/reviews/run.id"
done
echo '{"ok":true,"result":{"runs":[]}}' >"$STUB_ORCA_RUNS"
echo '{"ok":false,"error":{"code":"x"}}' >"$T/create-fail.json"
OUT="$(STUB_ORCA_CREATE="$T/create-fail.json" "$RR" run 2>&1)"
assert_eq "$?" 1; assert_eq "$OUT" "fleet-review-request: orca run-create failed"
assert_fail test -e "$FLEET_HOME/reviews/run.id"
# run-list has no page token, so a full list of 500 Runs may hide a match: run adopts a match it sees, refuses to
# create when it sees none, and creates as usual below the limit.
runs() {
  jq -n --argjson n "$1" --arg o "reviews $FLEET_HOME" --arg match "$2" '{ok: true, result: {runs: (
    [range($n) | {id: "run_other_\(.)", objective: "other \(.)", created_at: "2026-09-01T00:00:00Z"}]
    | if $match == "" then . else .[:-1] + [{id: $match, objective: $o, created_at: "2026-09-02T00:00:00Z"}] end)}}' >"$STUB_ORCA_RUNS"
}
runs 500 run_000000000009
: >"$STUB_LOG"
assert_eq "$("$RR" run)" run_000000000009
assert_eq "$(grep -c 'run-create' "$STUB_LOG")" 0
rm "$FLEET_HOME/reviews/run.id"
runs 500 ""
OUT="$("$RR" run 2>&1)"
assert_eq "$?" 1; assert_eq "$OUT" "fleet-review-request: run-list returned 500 Runs; it may be truncated, not creating a Run"
assert_eq "$(grep -c 'run-create' "$STUB_LOG")" 0
assert_fail test -e "$FLEET_HOME/reviews/run.id"
runs 499 ""
assert_eq "$("$RR" run)" run_000000000001
assert_eq "$(grep -c 'run-create' "$STUB_LOG")" 1
rm "$FLEET_HOME/reviews/run.id"

# A fresh .run.lock held past the deadline: run gives up, leaves the owner's lock alone and creates nothing.
# The date stub adds the offset the sleep stub grows, and the lock's future mtime keeps it from going stale.
mkdir -p "$T/clock"
echo 0 >"$T/clock/offset"
cat >"$T/clock/date" <<SH
#!/usr/bin/env bash
[ "\$1" = +%s ] || exec $(command -v date) "\$@"
echo \$((\$($(command -v date) +%s) + \$(cat "$T/clock/offset")))
SH
cat >"$T/clock/sleep" <<SH
#!/usr/bin/env bash
echo "sleep \$*" >>"\$STUB_LOG"
echo \$((\$(cat "$T/clock/offset") + 100)) >"$T/clock/offset"
SH
chmod +x "$T/clock/date" "$T/clock/sleep"
mkdir "$FLEET_HOME/reviews/.run.lock"
echo other.1.1 >"$FLEET_HOME/reviews/.run.lock/owner"
touch -t "$(date -v+1H +%Y%m%d%H%M 2>/dev/null || date -d '+1 hour' +%Y%m%d%H%M)" "$FLEET_HOME/reviews/.run.lock"
: >"$STUB_LOG"
OUT="$(PATH="$T/clock:$PATH" FLEET_LOCK_TTL=60 "$RR" run 2>&1)"
assert_eq "$?" 1; assert_contains "$OUT" "fleet-review-request: cannot take"
assert_eq "$(cat "$FLEET_HOME/reviews/.run.lock/owner")" other.1.1
assert_contains "$(cat "$STUB_LOG")" "sleep 0.2"
assert_eq "$(grep -c 'run-create' "$STUB_LOG")" 0
assert_fail test -e "$FLEET_HOME/reviews/run.id"
rm -rf "$FLEET_HOME/reviews/.run.lock"

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

# add re-checks every Slack field itself: a bad one exits 2 before anything is read or written.
P=https://acme.slack.com/archives/C0TEAM
add_bad() {
  OUT="$("$RR" add C0TEAM https://github.com/o/web/pull/20 "$1" "$2" 2026-10-01T09:00:00Z "$3" "$4" 2>&1)"
  assert_eq "$?" 2; assert_contains "$OUT" "$5"
}
: >"$STUB_LOG"
add_bad alice "$P/p1759312800000100" C0TEAM 1759312800.000100 "requested_by is not a Slack user ID: alice"
add_bad 'U0ALICE;id' "$P/p1759312800000100" C0TEAM 1759312800.000100 "requested_by is not a Slack user ID"
add_bad U0ALICE "$P/p1759312800000100" '#team' 1759312800.000100 "request_channel is not a Slack channel ID: #team"
add_bad U0ALICE "$P/p1759312800000100" C0TEAM 1759312800 "request_ts is not a Slack ts: 1759312800"
add_bad U0ALICE "$P/p1759312800000100" C0TEAM '1759312800.000100$(id)' "request_ts is not a Slack ts"
add_bad U0ALICE https://slack.example/p1 C0TEAM 1759312800.000100 "request_link is not a link to 1759312800.000100 in C0TEAM"
add_bad U0ALICE https://acme.slack.com/archives/C0OTHER/p1759312800000100 C0TEAM 1759312800.000100 "request_link is not a link to"
add_bad U0ALICE "$P/p1759312800000200" C0TEAM 1759312800.000100 "request_link is not a link to"
add_bad U0ALICE "$P/p1759312800000100&x=1" C0TEAM 1759312800.000100 "request_link is not a link to"
add_bad U0ALICE C0TEAM:1759312800.000200 C0TEAM 1759312800.000100 "request_link is not a link to"
add_bad U0ALICE C0TEAM:1759312800x000100 C0TEAM 1759312800.000100 "request_link is not a link to"
add_bad U0ALICE C0OTHER:1759312800.000100 C0TEAM 1759312800.000100 "request_link is not a link to"
assert_fail test -e "$FLEET_HOME/reviews/o+web+20"
assert_eq "$(cat "$STUB_LOG")" ""
# Without a configured workspace host, the link is <channel>:<ts>.
OUT="$("$RR" add C0TEAM https://github.com/o/web/pull/21 U0ALICE C0TEAM:1759312800.000100 2026-10-01T09:00:00Z C0TEAM 1759312800.000100 2>&1)"
assert_eq "$?" 0; assert_eq "$OUT" "created $FLEET_HOME/reviews/o+web+21/spec.md"
assert_eq "$(yq --front-matter=extract '.request_link' "$FLEET_HOME/reviews/o+web+21/spec.md")" C0TEAM:1759312800.000100
add_bad U0ALICE https://acme.evil.slack.com/archives/C0TEAM/p1759312800000100 C0TEAM 1759312800.000100 "request_link is not a link to"
add_bad U0ALICE https://acme.slack.com.evil.example/archives/C0TEAM/p1759312800000100 C0TEAM 1759312800.000100 "request_link is not a link to"
# A reply's permalink carries its thread, and an Enterprise Grid host has an .enterprise label.
OUT="$("$RR" add C0TEAM https://github.com/o/web/pull/20 U0ALICE "https://acme.enterprise.slack.com/archives/C0TEAM/p1759312800000100?thread_ts=1759312700.000100&cid=C0TEAM" \
  2026-10-01T09:00:00Z C0TEAM 1759312800.000100 2>&1)"
assert_eq "$?" 0; assert_eq "$OUT" "created $FLEET_HOME/reviews/o+web+20/spec.md"

# validate reads the fleet-slack-check reply. Every field is untrusted: the batch passes whole or not at all, and the
# cursor it prints is always the dispatch epoch.
OLD=1759312800.000100 EPOCH=1759313000
row() { local IFS=$'\t'; echo "$*"; }
validate() {
  OUT="$(printf '%s\n' "$@" | "$RR" validate C0TEAM "$OLD" "$EPOCH" 2>"$T/verr")"
  RC=$?
}
GOOD="$(row req https://github.com/o/app/pull/12 U0ALICE "$P/p1759312900000100" 1759312900.000100 1759312900.000100)"
REPLY="$(row req https://github.com/o/web/pull/3 U0BOB "$P/p1759312950000200?thread_ts=1759300000.000100&cid=C0TEAM" 1759312950.000200 1759300000.000100)"
EDGE="$(row req https://github.com/o/app/pull/13 U0ALICE "$P/p1759313000000000" 1759313000.000000 1759313000.000000)"
CUR="$(row cursor "$EPOCH")"
cp "$FLEET_HOME/review-requests.cursor" "$T/cursor.before"
validate "$GOOD" "$REPLY" "$EDGE" "$CUR"
assert_eq "$RC" 0; assert_eq "$OUT" "$(printf '%s\n' "$GOOD" "$REPLY" "$EDGE" "$CUR")"
validate "$CUR"
assert_eq "$RC" 0; assert_eq "$OUT" "$CUR"
BARE="$(row req https://github.com/o/app/pull/14 U0ALICE C0TEAM:1759312960.000300 1759312960.000300 1759312960.000300)"
validate "$BARE" "$CUR"
assert_eq "$RC" 0; assert_eq "$OUT" "$(printf '%s\n' "$BARE" "$CUR")"
OUT="$(printf '%s' "$CUR" | "$RR" validate C0TEAM 1759312800 "$EPOCH")"
assert_eq "$?" 0; assert_eq "$OUT" "$CUR"
reject() {
  local why="$1"; shift
  validate "$@"
  assert_eq "$RC" 1; assert_eq "$OUT" ""; assert_contains "$(cat "$T/verr")" "$why"
}
reject "not a PR URL" "$(row req https://github.com/o/app/issues/12 U0ALICE "$P/p1759312900000100" 1759312900.000100 1759312900.000100)" "$CUR"
reject "not a PR URL" "$(row req https://github.com/o/app/pull/12/ U0ALICE "$P/p1759312900000100" 1759312900.000100 1759312900.000100)" "$CUR"
reject "not configured for C0TEAM" "$(row req https://github.com/o/api/pull/1 U0ALICE "$P/p1759312900000100" 1759312900.000100 1759312900.000100)" "$CUR"
reject "not a Slack user ID" "$(row req https://github.com/o/app/pull/12 alice "$P/p1759312900000100" 1759312900.000100 1759312900.000100)" "$CUR"
reject "permalink is not a link to message" "$(row req https://github.com/o/app/pull/12 U0ALICE https://acme.slack.com/archives/C0OTHER/p1759312900000100 1759312900.000100 1759312900.000100)" "$CUR"
reject "permalink is not a link to message" "$(row req https://github.com/o/app/pull/12 U0ALICE "$P/p1759312800000100" 1759312900.000100 1759312900.000100)" "$CUR"
for link in C0OTHER:1759312900.000100 C0TEAM:1759312900.000200 C0TEAM:1759312900x000100 "C0TEAM:1759312900.000100 "; do
  reject "permalink is not a link to message" "$(row req https://github.com/o/app/pull/12 U0ALICE "$link" 1759312900.000100 1759312900.000100)" "$CUR"
done
reject "outside" "$(row req https://github.com/o/app/pull/12 U0ALICE "$P/p1759313000000001" 1759313000.000001 1759313000.000001)" "$CUR"
reject "outside" "$(row req https://github.com/o/app/pull/12 U0ALICE "$P/p1759312800000100" 1759312800.000100 1759312800.000100)" "$CUR"
reject "outside" "$(row req https://github.com/o/app/pull/12 U0ALICE "$P/p1759312700000100" 1759312700.000100 1759312700.000100)" "$CUR"
reject "parent_ts is after ts" "$(row req https://github.com/o/app/pull/12 U0ALICE "$P/p1759312900000100" 1759312900.000100 1759312950.000100)" "$CUR"
reject "not a Slack ts" "$(row req https://github.com/o/app/pull/12 U0ALICE "$P/p1759312900000100" 1759312900.000100 1759312900)" "$CUR"
reject "the cursor is not the dispatch epoch" "$GOOD" "$(row cursor 1759399999)"
reject "the cursor is not the dispatch epoch" "$GOOD" "$(row cursor 1759313000.000000)"
reject "no cursor line" "$GOOD"
OUT="$("$RR" validate C0TEAM "$OLD" "$EPOCH" </dev/null 2>&1)"
assert_eq "$?" 1; assert_eq "$OUT" "fleet-review-request: batch rejected, line 1: no cursor line"
reject "a line follows the cursor line" "$CUR" "$GOOD"
reject "a line follows the cursor line" "$GOOD" "$CUR" "$CUR"
reject "unknown record type" "$(row note hello)" "$CUR"
reject "unknown record type" "" "$CUR"
reject "unknown record type" "Here is what I found:" "$GOOD" "$CUR"
reject "six non-empty fields" "$(row req https://github.com/o/app/pull/12 U0ALICE "$P/p1759312900000100" 1759312900.000100 1759312900.000100 extra)" "$CUR"
reject "six non-empty fields" "$(row req https://github.com/o/app/pull/12 U0ALICE "" "$P/p1759312900000100" 1759312900.000100)" "$CUR"
reject "six non-empty fields" "$GOOD"$'\t' "$CUR"
reject "six non-empty fields" $'\t'"$GOOD" "$CUR"
reject "two non-empty fields" "$(row cursor "$EPOCH" "")"
# A newline inside a field splits the line, and shell metacharacters fail the field's pattern; nothing runs.
reject "six non-empty fields" "$(row req https://github.com/o/app/pull/12 $'U0ALICE\ncursor' "$P/p1759312900000100" 1759312900.000100 1759312900.000100)" "$CUR"
reject "not a PR URL" "$(row req 'https://github.com/o/app/pull/12$(touch '"$T"'/pwned)' U0ALICE "$P/p1759312900000100" 1759312900.000100 1759312900.000100)" "$CUR"
reject "not a Slack user ID" "$(row req https://github.com/o/app/pull/12 'U0ALICE;touch '"$T"'/pwned' "$P/p1759312900000100" 1759312900.000100 1759312900.000100)" "$CUR"
reject "permalink is not a link to message" "$(row req https://github.com/o/app/pull/12 U0ALICE "$P/p1759312900000100\`touch $T/pwned\`" 1759312900.000100 1759312900.000100)" "$CUR"
assert_fail test -e "$T/pwned"
reject "not a PR URL" "$GOOD" "$(row req https://github.com/o/app/pull/x U0ALICE "$P/p1759312900000100" 1759312900.000100 1759312900.000100)" "$CUR"
assert_ok cmp -s "$T/cursor.before" "$FLEET_HOME/review-requests.cursor"
for args in "C0TEAM $OLD" "C0TEAM $OLD 1759313000.5" "C0TEAM x $EPOCH" "#team $OLD $EPOCH"; do
  OUT="$(printf '%s\n' "$CUR" | "$RR" validate $args 2>&1)"
  assert_eq "$?" 2; assert_not_contains "$OUT" "cursor	"
done

echo '[1]' >"$FLEET_HOME/review-requests.cursor"
assert_fail "$RR" cursor C0TEAM 1759316400.000300 2>/dev/null
assert_eq "$(cat "$FLEET_HOME/review-requests.cursor")" "[1]"

OUT="$("$RR" add C0TEAM "$PR" U0ALICE 2>&1)"
assert_eq "$?" 2; assert_contains "$OUT" "usage:"
OUT="$("$RR" nope 2>&1)"
assert_eq "$?" 2; assert_contains "$OUT" "usage:"

finish_tests review-request
