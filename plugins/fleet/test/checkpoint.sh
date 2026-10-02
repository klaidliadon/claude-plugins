#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
export PATH="$DIR/test/stubs:$PATH"
FX="$DIR/test/fixtures"
CP="$DIR/bin/fleet-checkpoint"
H="$FLEET_HOME/handoff.md"
unset ORCA_TERMINAL_HANDLE ORCA_WORKTREE_ID FLEET_IDLE_WAIT_SEC

export STUB_LOG="$T/log" STUB_GH_PR="$FX/gh/pr-open.json"
export STUB_ORCA_TASKS="$FX/orca/task-list-running.json" STUB_ORCA_CHECK="$T/check-empty.json"
export STUB_ORCA_FENCE_TASKS=1 STUB_ORCA_FENCED_RUN=run_000000000009 STUB_ORCA_FENCED="$FX/orca/error-consumer-fenced.json"
export STUB_ORCA_RUN_CURRENT="$FX/orca/run-current-bound.json" STUB_ORCA_TERM_CREATE="$FX/orca/terminal-create.json"
echo '{"ok":true,"result":{"messages":[]}}' >"$STUB_ORCA_CHECK"

# The fleet: a live worker, a row waiting on the user, an open review request and a fenced Run. Two task names carry
# a "|" and a newline, which the handoff tables must escape.
spec() {
  mkdir -p "$FLEET_HOME/$1"
  { echo ---; cat; echo ---; echo body; } >"$FLEET_HOME/$1/spec.md"
}
mkdir -p "$FLEET_HOME/obj" "$FLEET_HOME/fenced"
echo run_000000000001 >"$FLEET_HOME/obj/run.id"
echo run_000000000009 >"$FLEET_HOME/fenced/run.id"
spec obj/1-api <<'YAML'
objective: obj
task: "1-api|v2"
repo: app
approved_at: "2026-09-30T19:00:00Z"
pr: https://github.com/o/r/pull/7
orca:
  - {round: 1, kind: worker, task_id: task_000000000006, dispatch_id: ctx_000000000007}
YAML
spec obj/2-web <<'YAML'
objective: obj
task: "2-web\nsecond line"
repo: app
YAML
touch "$FLEET_HOME/obj/2-web/spec-review.md"
spec reviews/o+r+9 <<'YAML'
objective: reviews
task: o+r+9
kind: review
repo: r
pr: https://github.com/o/r/pull/9
answer: null
YAML
spec fenced/1-x <<'YAML'
objective: fenced
task: 1-x
repo: app
approved_at: "2026-09-30T19:00:00Z"
YAML
printf 'C0TEAM: "1759312800.000100"\n' >"$FLEET_HOME/review-requests.cursor"

# fingerprint lists every path under FLEET_HOME except the handoff and its archive, with its content.
fingerprint() {
  (cd "$FLEET_HOME" && find . -path ./handoff.md -prune -o -path ./_archive -prune -o -print | LC_ALL=C sort |
    while IFS= read -r p; do if [ -f "$p" ]; then echo "$p: $(cat "$p")"; else echo "$p/"; fi; done)
}
masked() { sed -E 's/^generated: .*/generated: <generated>/; s/^fleet_home: .*/fleet_home: <fleet_home>/' "$H"; }
calls() { grep -oE '^orca (orchestration run-use|orchestration run-current|terminal wait|terminal close)' "$STUB_LOG" | cut -d' ' -f2-3; }
in_orca() { ORCA_TERMINAL_HANDLE=term_000000000001 ORCA_WORKTREE_ID=wt_000000000001 "$@"; }
day="$(date -u +%Y-%m-%d)"
A="$FLEET_HOME/_archive"
state="$(fingerprint)"

# The golden: generated and fleet_home are masked, everything else is pinned.
: >"$STUB_LOG"
out="$(in_orca "$CP" write)"
assert_eq "$?" 0
assert_eq "$(tail -1 <<<"$out")" "Checkpoint written: $H. New manager starting in term_000000000002; it closes this tab once it holds the Run."
assert_eq "$(masked)" "$(cat "$FX/checkpoint-handoff.md")"
assert_eq "$(yq --front-matter=extract .fleet_home "$H")" "$FLEET_HOME"
assert_ok grep -qE '^generated: "?[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"?$' "$H"
assert_eq "$(cat "$STUB_LOG.create")" "$(printf '%s\n' terminal create --worktree id:wt_000000000001 --title "fleet manager" \
  --command 'FLEET_MANAGER=1 claude "/fleet:fleet-manager"' --focus --json)"
assert_fail test -e "$A"
assert_eq "$(fingerprint)" "$state"
assert_eq "$(find "$FLEET_HOME" -maxdepth 1 -name '.handoff.*' -o -maxdepth 1 -name '.checkpoint.lock')" ""

# Each later run archives the previous handoff verbatim into the lowest free slot of the day.
cp "$H" "$T/first"
out="$("$CP" write)"
assert_eq "$(tail -1 <<<"$out")" "Checkpoint written: $H. Not in an Orca terminal: start a new manager, then close this tab."
assert_eq "$(ls "$A")" "handoff-$day-1.md"
assert_ok cmp -s "$T/first" "$A/handoff-$day-1.md"
assert_eq "$(yq --front-matter=extract .previous_terminal "$H")" ""
cp "$H" "$T/second"
"$CP" write >/dev/null
assert_eq "$(ls "$A" | tr '\n' ' ')" "handoff-$day-1.md handoff-$day-2.md "
assert_ok cmp -s "$T/first" "$A/handoff-$day-1.md"
assert_ok cmp -s "$T/second" "$A/handoff-$day-2.md"
assert_eq "$(fingerprint)" "$state"

# A successful run-current without a binding is no failure: run_id stays empty.
STUB_ORCA_RUN_CURRENT="$FX/orca/run-current-none.json" "$CP" write >/dev/null
assert_eq "$?" 0
assert_eq "$(yq --front-matter=extract .run_id "$H")" ""
assert_contains "$(cat "$H")" $'## Terminal binding\n\nrun: none\n'
rm -f "$FLEET_HOME/review-requests.cursor"
"$CP" write >/dev/null
assert_eq "$(tail -1 "$H")" "cursor: none"
printf 'C0TEAM: "1759312800.000100"\n' >"$FLEET_HOME/review-requests.cursor"
state="$(fingerprint)"

# Stubs that fail only the checkpoint's own temp files and renames.
mkdir -p "$T/bin"
cat >"$T/bin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in *.handoff.*)
  n=\$((\$(cat "$T/mktemp.n" 2>/dev/null || echo 0) + 1)); echo "\$n" >"$T/mktemp.n"
  if [ "\$n" = "\${STUB_MKTEMP_AT:-1}" ]; then
    case "\$STUB_MKTEMP_MODE" in fail) exit 1 ;; empty) exit 0 ;; dir) mkdir -p "$T/adir"; echo "$T/adir"; exit 0 ;; esac
  fi ;;
esac
exec $(command -v mktemp) "\$@"
SH
cat >"$T/bin/mv" <<SH
#!/usr/bin/env bash
case "\$1" in \$STUB_MV_SRC) case "\${@: -1}" in \$STUB_MV_DST) exit 1 ;; esac ;; esac
exec $(command -v mv) "\$@"
SH
chmod +x "$T/bin/mktemp" "$T/bin/mv"
stubbed() { rm -f "$T/mktemp.n"; PATH="$T/bin:$PATH" "$@"; }

# Every failure before the launch exits 1, leaves the previous handoff byte-identical and starts no tab.
cp "$H" "$T/prev"
archived="$(ls "$A")"
prelaunch_fails() {
  : >"$STUB_LOG"
  rm -f "$STUB_LOG.create"
  out="$(in_orca "$@" 2>"$T/err")"
  assert_eq "$?" 1
  assert_eq "$(tail -1 "$T/err")" "fleet-checkpoint: FAILED, do not close this tab"
  assert_not_contains "$out" "Checkpoint written"
  assert_ok cmp -s "$T/prev" "$H"
  assert_eq "$(ls "$A")" "$archived"
  assert_fail test -e "$STUB_LOG.create"
  assert_eq "$(find "$FLEET_HOME" -maxdepth 1 -name '.handoff.*')" ""
  assert_eq "$(fingerprint)" "$state"
}
STUB_GH_FAIL="pr view" prelaunch_fails "$CP" write
STUB_ORCA_RUN_CURRENT="$FX/orca/run-current-fenced.json" STUB_ORCA_RUN_CURRENT_EXIT=1 prelaunch_fails "$CP" write
echo '<html>' >"$T/html"
STUB_ORCA_RUN_CURRENT="$T/html" prelaunch_fails "$CP" write
echo '{"ok":true,"result":{}}' >"$T/no-run-key.json"
STUB_ORCA_RUN_CURRENT="$T/no-run-key.json" prelaunch_fails "$CP" write
STUB_MKTEMP_MODE=fail prelaunch_fails stubbed "$CP" write
STUB_MKTEMP_MODE=empty prelaunch_fails stubbed "$CP" write
STUB_MKTEMP_MODE=dir prelaunch_fails stubbed "$CP" write
STUB_MV_SRC="$H" STUB_MV_DST="*/_archive/*" prelaunch_fails stubbed "$CP" write
STUB_MV_SRC="*/.handoff.*" STUB_MV_DST="$H" prelaunch_fails stubbed "$CP" write
prelaunch_fails env -u ORCA_WORKTREE_ID ORCA_TERMINAL_HANDLE=term_000000000001 "$CP" write
assert_contains "$(cat "$T/err")" "ORCA_WORKTREE_ID is unset"
# A slot that cannot be created and does not exist ends the search instead of looping.
slot="$A/handoff-$day-$(($(ls "$A" | wc -l) + 1)).md"
ln -s "$T/missing/x" "$slot"
archived="$(ls "$A")"
prelaunch_fails "$CP" write
rm "$slot"
archived="$(ls "$A")"

# Launch outcomes: a clean failure is exit 1, success survives a failed rewrite, anything else is unknown.
: >"$STUB_LOG"
out="$(STUB_ORCA_TERM_CREATE="$FX/orca/terminal-create-failed.json" STUB_ORCA_TERM_CREATE_EXIT=1 in_orca "$CP" write 2>"$T/err")"
assert_eq "$?" 1
assert_eq "$(tail -1 "$T/err")" "fleet-checkpoint: FAILED, do not close this tab"
assert_not_contains "$out" "Checkpoint written"
assert_eq "$(yq --front-matter=extract .previous_terminal "$H")" ""
in_orca "$CP" write >/dev/null
STUB_ORCA_TERM_CREATE="$FX/orca/terminal-create-failed.json" STUB_ORCA_TERM_CREATE_EXIT=1 STUB_MKTEMP_MODE=fail STUB_MKTEMP_AT=2 \
  stubbed in_orca "$CP" write >/dev/null 2>"$T/err"
assert_eq "$?" 1
assert_eq "$(head -1 "$T/err")" "fleet-checkpoint: cannot clear previous_terminal in $H"
out="$(STUB_MKTEMP_MODE=fail STUB_MKTEMP_AT=2 stubbed in_orca "$CP" write 2>"$T/err")"
assert_eq "$?" 0
assert_eq "$(tail -1 <<<"$out")" "Checkpoint written: $H. New manager starting in term_000000000002; it closes this tab once it holds the Run."
assert_eq "$(cat "$T/err")" "fleet-checkpoint: cannot record next_terminal term_000000000002 in $H"
assert_eq "$(yq --front-matter=extract .next_terminal "$H")" ""
assert_eq "$(yq --front-matter=extract .previous_terminal "$H")" term_000000000001
echo 'not json' >"$T/not-json"
for c in "$T/not-json:0" "$T/no-run-key.json:0" "$T/not-json:1" "/dev/null:1"; do
  out="$(STUB_ORCA_TERM_CREATE="${c%:*}" STUB_ORCA_TERM_CREATE_EXIT="${c##*:}" in_orca "$CP" write 2>"$T/err")"
  assert_eq "$?" 3
  assert_eq "$(cat "$T/err")" "fleet-checkpoint: launch outcome unknown, check Orca for a new fleet manager tab before doing anything"
  assert_not_contains "$out" "Checkpoint written"
done
assert_eq "$(fingerprint)" "$state"

# One checkpoint at a time per FLEET_HOME.
mkdir "$FLEET_HOME/.checkpoint.lock"
for sub in write takeover; do
  out="$("$CP" "$sub" 2>&1)"
  assert_eq "$?" 1
  assert_eq "$out" "fleet-checkpoint: another checkpoint holds the lock"
done
rmdir "$FLEET_HOME/.checkpoint.lock"

# takeover, run in the new manager's terminal against a handoff the old one wrote.
export STUB_ORCA_RUN_USE="$FX/orca/run-use.json" STUB_ORCA_TERM_WAIT="$FX/orca/terminal-wait-idle.json"
export STUB_ORCA_TERM_CLOSE="$FX/orca/terminal-close.json"
# fresh writes a handoff from term_000000000001 and clears next_terminal, so a test sees what takeover records.
fresh() {
  in_orca "$CP" write >/dev/null 2>&1
  yq --front-matter=process -i '.next_terminal = ""' "$H"
  : >"$STUB_LOG"
}
as_new() { ORCA_TERMINAL_HANDLE=term_000000000002 "$@"; }
fm() { yq --front-matter=extract ".$1" "$H"; }

fresh
out="$(as_new "$CP" takeover)"
assert_eq "$?" 0
assert_eq "$out" "takeover: run_000000000001 held here, closed term_000000000001"
assert_eq "$(calls | tr '\n' ',')" "orchestration run-use,orchestration run-current,terminal wait,terminal close,"
assert_contains "$(cat "$STUB_LOG")" "orca orchestration run-use --id run_000000000001 --json"
assert_contains "$(cat "$STUB_LOG")" "orca terminal wait --terminal term_000000000001 --for tui-idle --timeout-ms 120000 --json"
assert_contains "$(cat "$STUB_LOG")" "orca terminal close --terminal term_000000000001 --tab --json"
assert_eq "$(fm next_terminal)" term_000000000002
assert_ok grep -qE '^taken_over_at: "?[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z"?$' "$H"
assert_eq "$(fingerprint)" "$state"
: >"$STUB_LOG"
assert_eq "$(as_new "$CP" takeover)" "takeover: nothing to do"
assert_eq "$(cat "$STUB_LOG")" ""

fresh
assert_eq "$(in_orca "$CP" takeover)" "takeover: nothing to do"
assert_eq "$(cat "$STUB_LOG")" ""
rm "$H"
assert_eq "$(as_new "$CP" takeover)" "takeover: nothing to do"

STUB_ORCA_RUN_CURRENT="$FX/orca/run-current-none.json" fresh
out="$(FLEET_IDLE_WAIT_SEC=5 as_new "$CP" takeover)"
assert_eq "$?" 0
assert_eq "$out" "takeover: no Run held here, closed term_000000000001"
assert_eq "$(calls | tr '\n' ',')" "terminal wait,terminal close,"
assert_contains "$(cat "$STUB_LOG")" "--timeout-ms 5000 --json"

# A failed rebind closes nothing and leaves the takeover pending.
# takeover_fails runs a takeover on a fresh handoff and asserts its error, its Orca calls and whether it recorded
# taken_over_at.
takeover_fails() {
  out="$(as_new "$CP" takeover 2>"$T/err")"
  assert_eq "$?" 1
  assert_eq "$out" ""
  assert_eq "$(cat "$T/err")" "$1"
  assert_eq "$(calls | tr '\n' ',')" "$2"
  if [ "$3" = recorded ]; then assert_ok grep -q '^taken_over_at: ' "$H"; else assert_eq "$(fm taken_over_at)" null; fi
}
fresh
STUB_ORCA_RUN_USE="$FX/orca/run-current-fenced.json" STUB_ORCA_RUN_USE_EXIT=1 takeover_fails \
  "fleet-checkpoint: takeover FAILED, old tab left open: run-use --id run_000000000001 failed: consumer_fenced" \
  "orchestration run-use," pending
jq '.result.run.id = "run_000000000002"' "$FX/orca/run-current-bound.json" >"$T/other-run.json"
fresh
STUB_ORCA_RUN_CURRENT="$T/other-run.json" takeover_fails \
  "fleet-checkpoint: takeover FAILED, old tab left open: run-current names run_000000000002, not run_000000000001" \
  "orchestration run-use,orchestration run-current," pending
assert_eq "$(fm next_terminal)" ""
fresh
STUB_ORCA_TERM_WAIT="$FX/orca/terminal-wait-timeout.json" STUB_ORCA_TERM_WAIT_EXIT=1 takeover_fails \
  "fleet-checkpoint: Run taken over, old session not idle, close term_000000000001 by hand once it is" \
  "orchestration run-use,orchestration run-current,terminal wait," pending
assert_eq "$(fm next_terminal)" term_000000000002
fresh
echo '{"ok":false,"error":{"code":"internal","message":"boom"}}' >"$T/close-failed.json"
STUB_ORCA_TERM_CLOSE="$T/close-failed.json" STUB_ORCA_TERM_CLOSE_EXIT=1 takeover_fails \
  "fleet-checkpoint: Run taken over, close term_000000000001 by hand" \
  "orchestration run-use,orchestration run-current,terminal wait,terminal close," recorded
fresh
STUB_ORCA_RUN_CURRENT="$FX/orca/run-current-fenced.json" STUB_ORCA_RUN_CURRENT_EXIT=1 takeover_fails \
  "fleet-checkpoint: takeover FAILED, old tab left open: run-current failed" "orchestration run-use,orchestration run-current," pending
fresh
out="$(env -u ORCA_TERMINAL_HANDLE "$CP" takeover 2>"$T/err")"
assert_eq "$?" 1
assert_eq "$(cat "$T/err")" "fleet-checkpoint: takeover FAILED, old tab left open: not in an Orca terminal"
assert_eq "$(cat "$STUB_LOG")" ""
# The takeover's own handoff writes: a failed next_terminal write stops before the wait, a failed taken_over_at
# write after a close only warns.
out="$(STUB_MKTEMP_MODE=fail stubbed as_new "$CP" takeover 2>"$T/err")"
assert_eq "$?" 1
assert_eq "$(cat "$T/err")" "fleet-checkpoint: Run taken over, cannot write $H, close term_000000000001 by hand once it is idle"
assert_eq "$(calls | tr '\n' ',')" "orchestration run-use,orchestration run-current,"
fresh
out="$(STUB_MKTEMP_MODE=fail STUB_MKTEMP_AT=2 stubbed as_new "$CP" takeover 2>"$T/err")"
assert_eq "$?" 0
assert_eq "$out" "takeover: run_000000000001 held here, closed term_000000000001"
assert_eq "$(cat "$T/err")" "fleet-checkpoint: cannot record taken_over_at in $H"
assert_eq "$(fm taken_over_at)" null

fresh
out="$(STUB_ORCA_TERM_CLOSE="$FX/orca/terminal-close-stale.json" STUB_ORCA_TERM_CLOSE_EXIT=1 as_new "$CP" takeover)"
assert_eq "$?" 0
assert_eq "$out" "takeover: run_000000000001 held here, closed term_000000000001"

for bad in 0 -1 1.5 abc; do
  fresh
  out="$(FLEET_IDLE_WAIT_SEC="$bad" as_new "$CP" takeover 2>&1)"
  assert_eq "$?" 2
  assert_eq "$out" "fleet-checkpoint: FLEET_IDLE_WAIT_SEC must be a positive integer"
  assert_eq "$(cat "$STUB_LOG")" ""
done
assert_eq "$(fingerprint)" "$state"

finish_tests checkpoint
