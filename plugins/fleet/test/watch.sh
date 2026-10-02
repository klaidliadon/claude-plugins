#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
export FLEET_STATUS_CMD="cat $T/tsv"
printf 'obj\t1-api\tin-review\trun reviews round 1\n' >"$T/tsv"
out="$("$DIR/bin/fleet-watch" --once --state "$T/state")"
assert_eq "$out" "obj/1-api: run reviews round 1"
out="$("$DIR/bin/fleet-watch" --once --state "$T/state")"
assert_eq "$out" ""
printf 'obj\t1-api\tin-review\tstart fix round 2\nobj\t2-ui\twaiting\tblocked on 1-api merge\n' >"$T/tsv"
out="$("$DIR/bin/fleet-watch" --once --state "$T/state")"
assert_contains "$out" "obj/1-api: start fix round 2"
assert_contains "$out" "obj/2-ui: blocked on 1-api merge"
printf 'obj\t2-ui\twaiting\tblocked on 1-api merge\n' >"$T/tsv"
out="$("$DIR/bin/fleet-watch" --once --state "$T/state")"
assert_eq "$out" $'obj/1-api: gone\nidle: waiting on user'
export FLEET_STATUS_CMD="false"
out="$("$DIR/bin/fleet-watch" --once --state "$T/state")"
assert_eq "$out" "fleet-watch: status failed"
out="$("$DIR/bin/fleet-watch" --once --state "$T/state")"
assert_eq "$out" ""
export FLEET_STATUS_CMD="true"
out="$("$DIR/bin/fleet-watch" --once --state "$T/state")"
assert_eq "$out" $'obj/2-ui: gone\nidle: waiting on user'
out="$("$DIR/bin/fleet-watch" --once --state "$T/state")"
assert_eq "$out" "idle: waiting on user"

printf 'obj\t1-api\tin-review\twait CI\n' >"$T/tsv"
export FLEET_STATUS_CMD="cat $T/tsv"
"$DIR/bin/fleet-watch" --once --state "$T/slack-state" >/dev/null
mkdir -p "$FLEET_HOME"
printf 'adversarial: codex\n' >"$FLEET_HOME/config.yaml"
assert_eq "$("$DIR/bin/fleet-watch" --once --state "$T/slack-state")" ""
printf 'review_requests:\n  sources: []\n' >"$FLEET_HOME/config.yaml"
assert_eq "$("$DIR/bin/fleet-watch" --once --state "$T/slack-state")" ""
assert_fail test -f "$T/slack-state.slack"
cat >"$FLEET_HOME/config.yaml" <<'YAML'
review_requests:
  interval_min: 20
  sources:
    - slack: C0TEAM
      repos: [o/r]
YAML
assert_eq "$("$DIR/bin/fleet-watch" --once --state "$T/slack-state")" "slack: check"
assert_eq "$("$DIR/bin/fleet-watch" --once --state "$T/slack-state")" ""
echo $(($(date +%s) - 19 * 60)) >"$T/slack-state.slack"
assert_eq "$("$DIR/bin/fleet-watch" --once --state "$T/slack-state")" ""
echo $(($(date +%s) - 20 * 60)) >"$T/slack-state.slack"
assert_eq "$("$DIR/bin/fleet-watch" --once --state "$T/slack-state")" "slack: check"
printf 'obj\t1-api\tin-review\tstart fix round 2\n' >"$T/tsv"
rm "$T/slack-state.slack"
assert_eq "$("$DIR/bin/fleet-watch" --once --state "$T/slack-state")" $'obj/1-api: start fix round 2\nslack: check'
yq -i 'del(.review_requests.interval_min)' "$FLEET_HOME/config.yaml"
echo $(($(date +%s) - 20 * 60)) >"$T/slack-state.slack"
assert_eq "$("$DIR/bin/fleet-watch" --once --state "$T/slack-state")" "slack: check"
for bad in 'review_requests: {interval_min: 0, sources: [{slack: C0T}]}' 'review_requests: {interval_min: abc, sources: [{slack: C0T}]}' 'review_requests: [unclosed'; do
  echo "$bad" >"$FLEET_HOME/config.yaml"
  rm -f "$T/slack-state.slack"
  assert_eq "$("$DIR/bin/fleet-watch" --once --state "$T/slack-state")" "fleet-watch: config.yaml invalid"
  assert_eq "$("$DIR/bin/fleet-watch" --once --state "$T/slack-state")" ""
  rm "$T/slack-state.config-failed"
done
# Idle: every row waits on the user and nothing runs, so the loop prints one idle line and exits 0.
rm -f "$FLEET_HOME/config.yaml"
cat >"$T/tsv" <<'TSV'
obj	1-a	spec-reviewed	await your go	false
obj	2-b	ready	needs human approval	false
obj	3-c	closed	closed unmerged: your call	false
obj	4-d	merged	propose cleanup	false
obj	5-e	waiting	blocked on 4-d merge	false
obj	6-f	in-review	escalate: 3 rounds not clean	false
obj2	1-a	approved	rebind: orca orchestration run-use --id run_000000000001	false
obj	7-g	dispatched	round 1 failed: inspect	false
TSV
out="$(FLEET_WATCH_INTERVAL=0 "$DIR/bin/fleet-watch" --state "$T/idle-state")"
assert_eq "$?" 0
assert_eq "$(grep -c '^idle: waiting on user$' <<<"$out")" 1
assert_eq "$(tail -1 <<<"$out")" "idle: waiting on user"
assert_eq "$(wc -l <<<"$out" | tr -d ' ')" 9
# Not idle: a live worker behind a gated row, or one actionable row.
not_idle() {
  out="$("$DIR/bin/fleet-watch" --once --state "$T/idle-state")"
  assert_not_contains "$out" "idle:"
}
cp "$T/tsv" "$T/tsv.gated"
awk -F'\t' -v OFS='\t' '$1 == "obj2" { $5 = "true" } 1' "$T/tsv.gated" >"$T/tsv"
not_idle
cp "$T/tsv.gated" "$T/tsv"
printf 'obj\t8-h\tin-review\trun reviews round 1\tfalse\n' >>"$T/tsv"
not_idle
cp "$T/tsv.gated" "$T/tsv"
printf 'obj\t9-i\treview\task review\tfalse\n' >>"$T/tsv"
not_idle
cp "$T/tsv.gated" "$T/tsv"
# With a source, an idle fleet still ticks: an all-gated or empty table prints the idle line, then "slack: check".
printf 'review_requests:\n  sources: [{slack: C0TEAM, repos: [o/r]}]\n' >"$FLEET_HOME/config.yaml"
rm -f "$T/idle-state.slack"
out="$("$DIR/bin/fleet-watch" --once --state "$T/idle-state")"
assert_eq "$out" $'obj/9-i: gone\nidle: waiting on user\nslack: check'
export FLEET_STATUS_CMD="true"
rm -f "$T/idle-state.slack"
out="$("$DIR/bin/fleet-watch" --once --state "$T/idle-state")"
assert_eq "$(tail -2 <<<"$out")" $'idle: waiting on user\nslack: check'
# loop runs the watch for 4s at a 0.1s poll from a fresh state while "$1" runs in the background.
# until_file waits up to 4s for the watch to write a state file that matches a pattern, so the steps follow the
# watch, not a clock.
until_file() {
  local i
  for i in $(seq 80); do grep -qs "$2" "$1" && return 0; sleep 0.05; done
  return 1
}
loop() {
  rm -f "$T/loop-state"*
  eval "$1" &
  out="$(FLEET_WATCH_INTERVAL=0.1 timeout 4 "$DIR/bin/fleet-watch" --state "$T/loop-state")"
  rc=$?
  wait
}
# Idle with a source: the loop keeps running (timeout kills it, 124), prints the idle line once, and ticks
# again when the interval passes.
for status in "cat $T/tsv" true; do
  export FLEET_STATUS_CMD="$status"
  loop 'until_file "$T/loop-state.slack" .; echo 0 >"$T/loop-state.slack"'
  assert_eq "$rc" 124
  assert_eq "$(grep -c '^idle: waiting on user$' <<<"$out")" 1
  assert_eq "$(grep -c '^slack: check$' <<<"$out")" 2
done
# Leaving idle and coming back prints the idle line again.
export FLEET_STATUS_CMD="cat $T/tsv"
loop 'until_file "$T/loop-state.slack" .; printf "obj\t8-h\tin-review\trun reviews round 1\tfalse\n" >>"$T/tsv"
  until_file "$T/loop-state" 8-h; cp "$T/tsv.gated" "$T/tsv"'
assert_eq "$rc" 124
assert_eq "$(grep -c '^idle: waiting on user$' <<<"$out")" 2
assert_contains "$out" $'obj/8-h: run reviews round 1\nobj/8-h: gone\nidle: waiting on user'
# Without a source nothing can wake an idle fleet, so the loop exits 0 after one idle line.
rm "$FLEET_HOME/config.yaml"
for status in "cat $T/tsv" true; do
  export FLEET_STATUS_CMD="$status"
  loop :
  assert_eq "$rc" 0
  assert_eq "$(tail -1 <<<"$out")" "idle: waiting on user"
  assert_eq "$(grep -c '^idle: waiting on user$' <<<"$out")" 1
done
# An unreadable config.yaml names no source either.
echo 'review_requests: [unclosed' >"$FLEET_HOME/config.yaml"
export FLEET_STATUS_CMD=true
loop :
assert_eq "$rc" 0
assert_eq "$out" $'idle: waiting on user\nfleet-watch: config.yaml invalid'
rm "$FLEET_HOME/config.yaml"
out="$("$DIR/bin/fleet-watch" --once --state "$T/idle-state")"
assert_eq "$out" "idle: waiting on user"
finish_tests watch
