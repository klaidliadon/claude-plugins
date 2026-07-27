#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-comms-v2-e2e.XXXXXX")"
COMMS="$ROOT/comms"
mkdir -p "$COMMS"
trap 'rm -rf "$ROOT"' EXIT
RELEASE_ROOT="$ROOT/cache/2.0.1"
mkdir -p "$(dirname "$RELEASE_ROOT")"
cp -R "$DIR" "$RELEASE_ROOT"
perl -pi -e 's/"version": "1\.3\.4"/"version": "2.0.1"/' \
  "$RELEASE_ROOT/.claude-plugin/plugin.json"
bash "$DIR/bin/release.sh" manifest --root "$RELEASE_ROOT"
RELEASE_ROOT="$(realpath "$RELEASE_ROOT")"
AC="$RELEASE_ROOT/bin/agent-comms"
RELEASE_DIGEST="$(bash "$RELEASE_ROOT/bin/release.sh" digest --root "$RELEASE_ROOT")"
export AGENT_COMMS_CACHE_BASE="$ROOT/cache"

printf 'review the implementation' > "$ROOT/task"
printf 'checked protocol state' > "$ROOT/partial"
printf 'late output from dead process' > "$ROOT/stale"
printf 'continue from the verified partial review' > "$ROOT/handoff"
printf 'checked recovery' > "$ROOT/replacement-progress"
printf 'no important findings' > "$ROOT/replacement-final"
printf 'approved' > "$ROOT/approval"

bash "$AC" init --channel review --dir "$COMMS" --session e2e \
  --driver codex --peer claude --release 2.0.1 \
  --digest "$RELEASE_DIGEST" \
  --protocol 2 --release-root "$RELEASE_ROOT"
bash "$AC" send --channel review --dir "$COMMS" --from codex --generation 1 \
  --body-file "$ROOT/task"
bash "$AC" send --channel review --dir "$COMMS" --from claude --generation 1 \
  --continue --body-file "$ROOT/partial"

timeout_output="$(bash "$AC" recv --channel review --dir "$COMMS" --me codex \
  --generation 1 --silence-seconds 1 --turn-seconds 0.1 2>&1)"
timeout_status=$?
assert_eq "$timeout_status" "3"
assert_contains "$timeout_output" '__TURN_TIMEOUT__ session=e2e turn=2 sender=claude gen=1'

bash "$AC" resume --channel review --dir "$COMMS" --from codex --generation 1 \
  --replace claude --body-file "$ROOT/handoff"
bash "$AC" send --channel review --dir "$COMMS" --from claude --generation 1 \
  --continue --body-file "$ROOT/stale" >/dev/null 2>&1
assert_eq "$?" "4"
bash "$AC" send --channel review --dir "$COMMS" --from claude --generation 2 \
  --continue --body-file "$ROOT/replacement-progress"
bash "$AC" send --channel review --dir "$COMMS" --from claude --generation 2 \
  --body-file "$ROOT/replacement-final"

review="$(bash "$AC" recv --channel review --dir "$COMMS" --me codex \
  --generation 1 --silence-seconds 1 --turn-seconds 2)"
assert_contains "$review" 'checked protocol state'
assert_contains "$review" 'checked recovery'
assert_contains "$review" 'no important findings'
assert_not_contains "$review" 'late output from dead process'

bash "$AC" send --channel review --dir "$COMMS" --from codex --generation 1 \
  --body-file "$ROOT/approval"
approval="$(bash "$AC" recv --channel review --dir "$COMMS" --me claude \
  --generation 2 --silence-seconds 1 --turn-seconds 2)"
assert_contains "$approval" 'approved'

bash "$AC" send --channel review --dir "$COMMS" --from codex --generation 1 \
  --converged-ref "$ROOT/task" --body-file "$ROOT/approval"
terminal="$(bash "$AC" recv --channel review --dir "$COMMS" --me claude \
  --generation 2 --silence-seconds 1 --turn-seconds 2)"
assert_contains "$terminal" 'converged-ref'
assert_contains "$terminal" 'approved'

finish_tests "E2E"
