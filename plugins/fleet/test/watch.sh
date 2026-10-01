#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-test.XXXXXX")"
export FLEET_HOME="$T/fleet"
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
assert_eq "$out" "obj/1-api: gone"
export FLEET_STATUS_CMD="false"
out="$("$DIR/bin/fleet-watch" --once --state "$T/state")"
assert_eq "$out" "fleet-watch: status failed"
out="$("$DIR/bin/fleet-watch" --once --state "$T/state")"
assert_eq "$out" ""
export FLEET_STATUS_CMD="true"
out="$("$DIR/bin/fleet-watch" --once --state "$T/state")"
assert_eq "$out" "obj/2-ui: gone"
out="$("$DIR/bin/fleet-watch" --once --state "$T/state")"
assert_eq "$out" ""

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
    - slack: "#team"
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
for bad in 'review_requests: {interval_min: 0, sources: [{slack: "#t"}]}' 'review_requests: {interval_min: abc, sources: [{slack: "#t"}]}' 'review_requests: [unclosed'; do
  echo "$bad" >"$FLEET_HOME/config.yaml"
  rm -f "$T/slack-state.slack"
  assert_eq "$("$DIR/bin/fleet-watch" --once --state "$T/slack-state")" "fleet-watch: config.yaml invalid"
  assert_eq "$("$DIR/bin/fleet-watch" --once --state "$T/slack-state")" ""
  rm "$T/slack-state.config-failed"
done
finish_tests watch
