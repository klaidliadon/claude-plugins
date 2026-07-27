#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
AC="$DIR/bin/agent-comms"
PROTOCOL="$DIR/bin/protocol.pl"
source "$DIR/test/testlib.sh"

new_launch_fixture() {
  FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/agent-comms-v2-launch.XXXXXX")"
  COMMS="$FIXTURE/comms"
  FAKEBIN="$FIXTURE/bin"
  RELEASE_ROOT="$FIXTURE/cache/2.0.0"
  mkdir -p "$COMMS" "$FAKEBIN" "$(dirname "$RELEASE_ROOT")"
  cp -R "$DIR" "$RELEASE_ROOT"
  RELEASE_ROOT="$(realpath "$RELEASE_ROOT")"
  perl -pi -e 's/"version": "1\.3\.4"/"version": "2.0.0"/' \
    "$RELEASE_ROOT/.claude-plugin/plugin.json"
  bash "$DIR/bin/release.sh" manifest --root "$RELEASE_ROOT"
  AC="$RELEASE_ROOT/bin/agent-comms"
  PROTOCOL="$RELEASE_ROOT/bin/protocol.pl"
  RELEASE_DIGEST="$(bash "$RELEASE_ROOT/bin/release.sh" digest --root "$RELEASE_ROOT")"
  SHARE="$FIXTURE/share"
  PUBLIC_BIN="$FIXTURE/home/.local/bin"
  CODEX_SKILL="$FIXTURE/home/.codex/skills/agent-comms"
  mkdir -p "$SHARE" "$PUBLIC_BIN" "$(dirname "$CODEX_SKILL")"
  ln -s "$RELEASE_ROOT" "$SHARE/current"
  ln -s "$SHARE/current/bin/agent-comms" "$PUBLIC_BIN/agent-comms"
  ln -s "$SHARE/current/skills/agent-comms" "$CODEX_SKILL"
  export AGENT_COMMS_MARKETPLACE_ROOT="$RELEASE_ROOT"
  export AGENT_COMMS_CACHE_BASE="$FIXTURE/cache"
  export AGENT_COMMS_SHARE_ROOT="$SHARE"
  export AGENT_COMMS_PUBLIC_BIN="$PUBLIC_BIN"
  export AGENT_COMMS_CODEX_SKILL="$CODEX_SKILL"
  export FAKE_RELEASE_ROOT="$RELEASE_ROOT"
  printf 'review the current branch' > "$FIXTURE/prompt"
  cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "list" ] && [ "${3:-}" = "--json" ]; then
  printf '[{"id":"agent-comms@klaidliadon","version":"2.0.0","enabled":true,"installPath":"%s"}]\n' \
    "$FAKE_RELEASE_ROOT"
  exit 0
fi
if [ "${1:-}" = "--help" ]; then
  printf '%s\n' "${FAKE_CLAUDE_HELP:---add-dir --permission-mode -p --output-format --verbose}"
  exit 0
fi
printf '%s\n' "$@" > "$FAKE_ARGS"
cat > "$FAKE_STDIN"
if [ -n "${FAKE_STDOUT_FILE:-}" ]; then
  cat "$FAKE_STDOUT_FILE"
fi
if [ -n "${FAKE_STDOUT_SECOND_FILE:-}" ]; then
  sleep "${FAKE_STDOUT_GAP:-1.5}"
  cat "$FAKE_STDOUT_SECOND_FILE"
fi
sleep "${FAKE_SLEEP:-0}"
exit "${FAKE_EXIT:-0}"
EOF
  cat > "$FAKEBIN/codex" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--help" ]; then
  printf '%s\n' "${FAKE_CODEX_HELP:---dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --json}"
  exit 0
fi
printf '%s\n' "$@" > "$FAKE_ARGS"
cat > "$FAKE_STDIN"
if [ -n "${FAKE_STDOUT_FILE:-}" ]; then
  cat "$FAKE_STDOUT_FILE"
fi
if [ -n "${FAKE_STDOUT_SECOND_FILE:-}" ]; then
  sleep "${FAKE_STDOUT_GAP:-1.5}"
  cat "$FAKE_STDOUT_SECOND_FILE"
fi
sleep "${FAKE_SLEEP:-0}"
exit "${FAKE_EXIT:-0}"
EOF
  cat > "$FAKEBIN/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "+%s" ] && [ -n "${FAKE_DATE_COUNTER:-}" ]; then
  current=0
  if [ -f "$FAKE_DATE_COUNTER" ]; then
    read -r current < "$FAKE_DATE_COUNTER"
  fi
  current=$((current + 31))
  printf '%s\n' "$current" > "$FAKE_DATE_COUNTER"
  printf '%s\n' "$current"
  exit 0
fi
exec /bin/date "$@"
EOF
  chmod +x "$FAKEBIN/claude" "$FAKEBIN/codex" "$FAKEBIN/date"
}

init_launch_channel() {
  local channel="$1"
  shift
  bash "$AC" init --channel "$channel" --dir "$COMMS" --session "$channel" \
    --driver codex --peer claude --release 2.0.0 \
    --digest "$RELEASE_DIGEST" \
    --protocol 2 --release-root "$RELEASE_ROOT" "$@"
}

test_launch_adapters() {
  new_launch_fixture
  init_launch_channel claude-launch
  FAKE_ARGS="$FIXTURE/claude.args" FAKE_STDIN="$FIXTURE/claude.stdin" PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex --channel claude-launch \
    --generation 1 --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" -- --model sonnet
  assert_ok bash "$AC" wait-ready --channel claude-launch --me codex \
    --peer claude --generation 1 --timeout 1 --dir "$COMMS"

  init_launch_channel codex-launch
  printf 'ready' > "$FIXTURE/ready"
  perl "$PROTOCOL" append --file "$COMMS/codex-launch.md" --sender claude --generation 1 \
    --kind control --state none --tag=hello-ack=claude.1 --body-file "$FIXTURE/ready"
  FAKE_ARGS="$FIXTURE/codex.args" FAKE_STDIN="$FIXTURE/codex.stdin" PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch codex --role driver --peer claude --channel codex-launch \
    --generation 1 --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" -- --model gpt-5

  local claude_args codex_args claude_input codex_input comms_arg comms_physical
  claude_args="$(cat "$FIXTURE/claude.args")"
  codex_args="$(cat "$FIXTURE/codex.args")"
  claude_input="$(cat "$FIXTURE/claude.stdin")"
  codex_input="$(cat "$FIXTURE/codex.stdin")"
  comms_arg="$(cd "$COMMS" && pwd)"
  comms_physical="$(cd "$COMMS" && pwd -P)"
  assert_contains "$claude_args" '-p'
  assert_contains "$claude_args" '--permission-mode'
  assert_contains "$claude_args" '--add-dir'
  assert_contains "$claude_args" '--output-format'
  assert_contains "$claude_args" 'stream-json'
  assert_contains "$claude_args" '--verbose'
  assert_contains "$claude_args" "$comms_arg"
  assert_contains "$claude_args" '--model'
  assert_not_contains "$claude_args" '--channel'
  assert_contains "$codex_args" 'exec'
  assert_contains "$codex_args" '--dangerously-bypass-approvals-and-sandbox'
  assert_contains "$codex_args" '--skip-git-repo-check'
  assert_contains "$codex_args" '--json'
  assert_contains "$codex_args" '--model'
  assert_not_contains "$codex_args" '--generation'
  assert_contains "$claude_input" 'review the current branch'
  assert_contains "$claude_input" "$RELEASE_ROOT/bin/agent-comms send --channel claude-launch"
  assert_contains "$claude_input" "$RELEASE_ROOT/bin/agent-comms recv --channel claude-launch"
  assert_contains "$claude_input" 'Your first transport action is receive'
  assert_contains "$claude_input" 'Run receive synchronously in the foreground'
  assert_contains "$claude_input" 'Never background receive or return a final answer'
  assert_contains "$claude_input" 'after a major phase or 2 minutes, whichever comes first'
  assert_contains "$claude_input" 'Never exceed 5 minutes without semantic progress'
  assert_contains "$claude_input" 'Keep progress bodies at or below 256 bytes'
  assert_contains "$codex_input" "$RELEASE_ROOT/bin/agent-comms send --channel codex-launch"
  assert_contains "$codex_input" "$RELEASE_ROOT/bin/agent-comms recv --channel codex-launch"
  assert_contains "$codex_input" 'You own the first turn'
  assert_contains "$(cat "$COMMS/claude-launch.md")" \
    "activity_ref=$comms_physical/.activity/claude-launch/claude.1.log"
  assert_contains "$(cat "$COMMS/codex-launch.md")" \
    "activity_ref=$comms_physical/.activity/codex-launch/codex.1.log"
  rm -rf "$FIXTURE"
}

test_activity_setup_and_flag_validation() {
  new_launch_fixture
  init_launch_channel activity-setup
  FAKE_ARGS="$FIXTURE/setup.args" FAKE_STDIN="$FIXTURE/setup.stdin" \
    PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex --channel activity-setup \
    --generation 1 --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS"

  local activity activity_dir directory_mode file_mode output raw
  activity_dir="$(cd "$COMMS" && pwd -P)/.activity/activity-setup"
  activity="$activity_dir/claude.1.log"
  assert_ok test -f "$activity"
  directory_mode="$(perl -e '@s=stat($ARGV[0]); printf "%o", $s[2] & 07777' "$activity_dir")"
  file_mode="$(perl -e '@s=stat($ARGV[0]); printf "%o", $s[2] & 07777' "$activity")"
  assert_eq "$directory_mode" "700"
  assert_eq "$file_mode" "600"

  init_launch_channel claude-output-conflict
  output="$(FAKE_ARGS="$FIXTURE/conflict-claude.args" \
    FAKE_STDIN="$FIXTURE/conflict-claude.stdin" PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex \
    --channel claude-output-conflict --generation 1 \
    --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" -- --output-format text 2>&1)"
  assert_eq "$?" "64"
  assert_contains "$output" 'runtime output flag is owned by agent-comms'
  assert_fail test -e "$FIXTURE/conflict-claude.args"
  raw="$(cat "$COMMS/claude-output-conflict.md")"
  assert_not_contains "$raw" 'tag=hello-ack=claude.1'
  assert_not_contains "$raw" 'tag=started'

  init_launch_channel codex-output-conflict
  output="$(FAKE_ARGS="$FIXTURE/conflict-codex.args" \
    FAKE_STDIN="$FIXTURE/conflict-codex.stdin" \
    AGENT_COMMS_STARTUP_TIMEOUT=0.1 PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch codex --role driver --peer claude \
    --channel codex-output-conflict --generation 1 \
    --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" -- --json 2>&1)"
  assert_eq "$?" "64"
  assert_contains "$output" 'runtime output flag is owned by agent-comms'
  assert_fail test -e "$FIXTURE/conflict-codex.args"
  raw="$(cat "$COMMS/codex-output-conflict.md")"
  assert_not_contains "$raw" 'tag=started'

  init_launch_channel missing-output-capability
  output="$(FAKE_ARGS="$FIXTURE/missing.args" FAKE_STDIN="$FIXTURE/missing.stdin" \
    FAKE_CLAUDE_HELP='--add-dir --permission-mode -p' PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex \
    --channel missing-output-capability --generation 1 \
    --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" 2>&1)"
  assert_eq "$?" "64"
  assert_contains "$output" 'claude adapter is missing --output-format'
  assert_fail test -e "$FIXTURE/missing.args"
  raw="$(cat "$COMMS/missing-output-capability.md")"
  assert_not_contains "$raw" 'tag=hello-ack=claude.1'
  assert_not_contains "$raw" 'tag=started'
  rm -rf "$FIXTURE"
}

test_heartbeat_and_lifecycle() {
  new_launch_fixture
  init_launch_channel heartbeat --heartbeat-after 1 --heartbeat-interval 1
  printf 'task' > "$FIXTURE/task"
  printf 'result' > "$FIXTURE/result"
  bash "$AC" send --channel heartbeat --dir "$COMMS" --from codex --generation 1 \
    --body-file "$FIXTURE/task"
  FAKE_ARGS="$FIXTURE/claude.args" FAKE_STDIN="$FIXTURE/claude.stdin" \
    FAKE_SLEEP=3 PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex --channel heartbeat \
    --generation 1 --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS"

  local raw heartbeat_count received
  raw="$(cat "$COMMS/heartbeat.md")"
  heartbeat_count="$(grep -c 'kind=status.*tag=alive ' "$COMMS/heartbeat.md")"
  assert_contains "$raw" 'kind=status'
  assert_contains "$raw" 'tag=alive'
  assert_contains "$raw" 'tag=exit=0'
  if [ "$heartbeat_count" -lt 1 ] || [ "$heartbeat_count" -gt 3 ]; then
    echo "FAIL: unexpected heartbeat count: $heartbeat_count"
    FAILS=$((FAILS+1))
  fi
  bash "$AC" send --channel heartbeat --dir "$COMMS" --from claude --generation 1 \
    --body-file "$FIXTURE/result"
  received="$(bash "$AC" recv --channel heartbeat --dir "$COMMS" --me codex \
    --generation 1 --silence-seconds 1 --turn-seconds 2)"
  assert_contains "$received" 'result'
  assert_not_contains "$received" 'alive'

  init_launch_channel failed-child
  FAKE_ARGS="$FIXTURE/failed.args" FAKE_STDIN="$FIXTURE/failed.stdin" \
    FAKE_EXIT=7 PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex --channel failed-child \
    --generation 1 --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" >/dev/null 2>&1
  assert_eq "$?" "7"
  assert_contains "$(cat "$COMMS/failed-child.md")" 'tag=exit=7'
  rm -rf "$FIXTURE"
}

test_semantic_progress_timeout_is_enforced() {
  new_launch_fixture
  init_launch_channel semantic-timeout \
    --heartbeat-after 1 --heartbeat-interval 1 --semantic-timeout 1
  printf 'review without going silent' > "$FIXTURE/task"
  bash "$AC" send --channel semantic-timeout --dir "$COMMS" \
    --from codex --generation 1 --body-file "$FIXTURE/task"

  FAKE_ARGS="$FIXTURE/semantic-timeout.args" \
    FAKE_STDIN="$FIXTURE/semantic-timeout.stdin" FAKE_SLEEP=10 \
    PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex \
    --channel semantic-timeout --generation 1 \
    --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" >/dev/null 2>&1
  assert_eq "$?" "124"
  local raw
  raw="$(cat "$COMMS/semantic-timeout.md")"
  assert_contains "$raw" 'tag=semantic-timeout'
  assert_contains "$raw" 'tag=exit=124'
  rm -rf "$FIXTURE"
}

test_semantic_progress_resets_timeout() {
  new_launch_fixture
  init_launch_channel semantic-progress --semantic-timeout 1
  printf 'review with a checkpoint' > "$FIXTURE/task"
  printf 'phase complete; inspecting the next invariant' > "$FIXTURE/progress"
  bash "$AC" send --channel semantic-progress --dir "$COMMS" \
    --from codex --generation 1 --body-file "$FIXTURE/task"

  FAKE_ARGS="$FIXTURE/semantic-progress.args" \
    FAKE_STDIN="$FIXTURE/semantic-progress.stdin" \
    FAKE_SLEEP=1.5 FAKE_EXIT=7 PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex \
    --channel semantic-progress --generation 1 \
    --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" >/dev/null 2>&1 &
  local launcher_pid=$! attempts=0
  while [ ! -f "$FIXTURE/semantic-progress.args" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  sleep 0.2
  bash "$AC" send --channel semantic-progress --dir "$COMMS" \
    --from claude --generation 1 --continue --body-file "$FIXTURE/progress"
  wait "$launcher_pid"
  assert_eq "$?" "7"
  local raw
  raw="$(cat "$COMMS/semantic-progress.md")"
  assert_not_contains "$raw" 'tag=semantic-timeout'
  assert_contains "$raw" 'tag=exit=7'
  rm -rf "$FIXTURE"
}

test_semantic_timeout_pauses_without_floor() {
  new_launch_fixture
  init_launch_channel semantic-waiting --semantic-timeout 1

  FAKE_ARGS="$FIXTURE/semantic-waiting.args" \
    FAKE_STDIN="$FIXTURE/semantic-waiting.stdin" \
    FAKE_SLEEP=1.5 FAKE_EXIT=7 PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex \
    --channel semantic-waiting --generation 1 \
    --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" >/dev/null 2>&1
  assert_eq "$?" "7"
  local raw
  raw="$(cat "$COMMS/semantic-waiting.md")"
  assert_not_contains "$raw" 'tag=semantic-timeout'
  assert_contains "$raw" 'tag=exit=7'
  rm -rf "$FIXTURE"
}

test_semantic_inspection_failure_is_fail_closed() {
  new_launch_fixture
  init_launch_channel semantic-inspection-failure
  printf 'review while the channel is valid' > "$FIXTURE/task"
  bash "$AC" send --channel semantic-inspection-failure --dir "$COMMS" \
    --from codex --generation 1 --body-file "$FIXTURE/task"

  FAKE_ARGS="$FIXTURE/semantic-inspection-failure.args" \
    FAKE_STDIN="$FIXTURE/semantic-inspection-failure.stdin" \
    FAKE_SLEEP=10 PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex \
    --channel semantic-inspection-failure --generation 1 \
    --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" >/dev/null 2>&1 &
  local launcher_pid=$! attempts=0
  while [ ! -f "$FIXTURE/semantic-inspection-failure.args" ] &&
      [ "$attempts" -lt 100 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  printf 'damaged channel tail\n' >> "$COMMS/semantic-inspection-failure.md"
  wait "$launcher_pid"
  assert_eq "$?" "70"
  rm -rf "$FIXTURE"
}

test_sanitized_activity_sampling() {
  new_launch_fixture
  init_launch_channel activity --heartbeat-after 1 --heartbeat-interval 1
  printf 'review activity' > "$FIXTURE/task"
  printf '%s\n%s\n' \
    '{"type":"tool","secret":"ACTIVITY_SECRET_DO_NOT_COPY"}' \
    '{"type":"assistant","text":"ACTIVITY_SECRET_DO_NOT_COPY"}' \
    > "$FIXTURE/first.jsonl"
  printf '%s\n' '{"type":"result","secret":"ACTIVITY_SECRET_DO_NOT_COPY"}' \
    > "$FIXTURE/second.jsonl"
  bash "$AC" send --channel activity --dir "$COMMS" --from codex --generation 1 \
    --body-file "$FIXTURE/task"
  FAKE_ARGS="$FIXTURE/activity.args" FAKE_STDIN="$FIXTURE/activity.stdin" \
    FAKE_STDOUT_FILE="$FIXTURE/first.jsonl" \
    FAKE_STDOUT_SECOND_FILE="$FIXTURE/second.jsonl" FAKE_STDOUT_GAP=1.5 \
    FAKE_SLEEP=2 FAKE_DATE_COUNTER="$FIXTURE/date.counter" PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex --channel activity \
    --generation 1 --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS"

  local activity_dir activity raw feed tick_count spool_count
  activity_dir="$(cd "$COMMS" && pwd -P)/.activity/activity"
  activity="$activity_dir/claude.1.log"
  raw="$(cat "$COMMS/activity.md")"
  feed="$(cat "$activity")"
  tick_count="$(grep -c '^ts=.* seq=' "$activity")"
  spool_count="$(find "$activity_dir" -name '.spool.*' -print | wc -l | tr -d ' ')"
  assert_eq "$tick_count" "2"
  assert_contains "$feed" 'seq=1'
  assert_contains "$feed" 'seq=2'
  assert_not_contains "$feed" 'seq=3'
  assert_not_contains "$feed" 'bytes='
  assert_not_contains "$feed" 'ACTIVITY_SECRET_DO_NOT_COPY'
  assert_not_contains "$raw" 'ACTIVITY_SECRET_DO_NOT_COPY'
  assert_contains "$raw" 'activity_seq=2'
  assert_contains "$raw" 'activity_idle='
  assert_eq "$spool_count" "0"
  rm -rf "$FIXTURE"
}

test_activity_generation_fencing() {
  new_launch_fixture
  init_launch_channel activity-resume --heartbeat-after 1 --heartbeat-interval 1
  printf 'review activity' > "$FIXTURE/task"
  printf 'resume activity review' > "$FIXTURE/handoff"
  printf '%s\n' '{"type":"tool","text":"generation activity"}' > "$FIXTURE/output.jsonl"
  bash "$AC" send --channel activity-resume --dir "$COMMS" \
    --from codex --generation 1 --body-file "$FIXTURE/task"
  FAKE_ARGS="$FIXTURE/generation-1.args" FAKE_STDIN="$FIXTURE/generation-1.stdin" \
    FAKE_STDOUT_FILE="$FIXTURE/output.jsonl" FAKE_SLEEP=2 \
    FAKE_DATE_COUNTER="$FIXTURE/date-1.counter" PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex --channel activity-resume \
    --generation 1 --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS"
  bash "$AC" resume --channel activity-resume --dir "$COMMS" \
    --from codex --generation 1 --replace claude \
    --body-file "$FIXTURE/handoff"
  FAKE_ARGS="$FIXTURE/generation-2.args" FAKE_STDIN="$FIXTURE/generation-2.stdin" \
    FAKE_STDOUT_FILE="$FIXTURE/output.jsonl" FAKE_SLEEP=2 \
    FAKE_DATE_COUNTER="$FIXTURE/date-2.counter" PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex --channel activity-resume \
    --generation 2 --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS"

  local activity_dir first second
  activity_dir="$(cd "$COMMS" && pwd -P)/.activity/activity-resume"
  first="$(cat "$activity_dir/claude.1.log")"
  second="$(cat "$activity_dir/claude.2.log")"
  assert_contains "$first" 'seq=1'
  assert_not_contains "$first" 'seq=2'
  assert_contains "$second" 'seq=1'
  assert_not_contains "$second" 'seq=2'
  assert_contains "$(cat "$COMMS/activity-resume.md")" \
    "activity_ref=$activity_dir/claude.2.log"
  rm -rf "$FIXTURE"
}

test_activity_write_failure_is_fail_open() {
  new_launch_fixture
  init_launch_channel activity-write-failure --heartbeat-after 1 --heartbeat-interval 1
  printf 'review activity' > "$FIXTURE/task"
  printf '%s\n' '{"type":"tool","text":"activity"}' > "$FIXTURE/output.jsonl"
  bash "$AC" send --channel activity-write-failure --dir "$COMMS" \
    --from codex --generation 1 --body-file "$FIXTURE/task"
  FAKE_ARGS="$FIXTURE/write-failure.args" \
    FAKE_STDIN="$FIXTURE/write-failure.stdin" \
    FAKE_STDOUT_FILE="$FIXTURE/output.jsonl" FAKE_SLEEP=3 FAKE_EXIT=7 \
    FAKE_DATE_COUNTER="$FIXTURE/date.counter" PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex \
    --channel activity-write-failure --generation 1 \
    --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" >/dev/null 2>&1 &
  local launcher_pid=$! activity attempts=0
  activity="$(cd "$COMMS" && pwd -P)/.activity/activity-write-failure/claude.1.log"
  while [ ! -f "$activity" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  chmod 400 "$activity"
  wait "$launcher_pid"
  assert_eq "$?" "7"
  assert_contains "$(cat "$COMMS/activity-write-failure.md")" \
    'tag=activity-disabled=write'
  rm -rf "$FIXTURE"
}

test_activity_sampler_death_is_fail_open() {
  new_launch_fixture
  init_launch_channel activity-sampler-death
  FAKE_ARGS="$FIXTURE/sampler-death.args" \
    FAKE_STDIN="$FIXTURE/sampler-death.stdin" FAKE_SLEEP=3 FAKE_EXIT=7 \
    PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex \
    --channel activity-sampler-death --generation 1 \
    --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" >/dev/null 2>&1 &
  local launcher_pid=$! heartbeat_pid attempts=0
  while [ ! -f "$FIXTURE/sampler-death.args" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  heartbeat_pid="$(ps -axo pid=,ppid=,command= |
    awk -v parent="$launcher_pid" \
      '$2 == parent && $0 ~ /bin\/launch\.sh/ {print $1; exit}')"
  if [ -z "$heartbeat_pid" ]; then
    fail "heartbeat child was not found"
  else
    kill -KILL "$heartbeat_pid"
  fi
  wait "$launcher_pid"
  assert_eq "$?" "7"
  rm -rf "$FIXTURE"
}

test_activity_shutdown_is_bounded() {
  new_launch_fixture
  init_launch_channel activity-bounded-shutdown
  FAKE_ARGS="$FIXTURE/bounded.args" FAKE_STDIN="$FIXTURE/bounded.stdin" \
    FAKE_SLEEP=2 FAKE_EXIT=7 PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex \
    --channel activity-bounded-shutdown --generation 1 \
    --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" >/dev/null 2>&1 &
  local launcher_pid=$! heartbeat_pid watchdog_pid attempts=0
  while [ ! -f "$FIXTURE/bounded.args" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  heartbeat_pid="$(ps -axo pid=,ppid=,command= |
    awk -v parent="$launcher_pid" \
      '$2 == parent && $0 ~ /bin\/launch\.sh/ {print $1; exit}')"
  if [ -z "$heartbeat_pid" ]; then
    fail "heartbeat child was not found"
  else
    kill -STOP "$heartbeat_pid"
  fi
  (
    sleep 7
    kill -KILL "$launcher_pid" 2>/dev/null || true
  ) &
  watchdog_pid=$!
  wait "$launcher_pid"
  assert_eq "$?" "7"
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  kill -KILL "$heartbeat_pid" 2>/dev/null || true
  rm -rf "$FIXTURE"
}

test_activity_rejects_symlink_paths() {
  new_launch_fixture
  mkdir "$FIXTURE/outside"
  init_launch_channel activity-root-symlink
  ln -s "$FIXTURE/outside" "$COMMS/.activity"
  local output raw
  output="$(FAKE_ARGS="$FIXTURE/root-symlink.args" \
    FAKE_STDIN="$FIXTURE/root-symlink.stdin" PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex \
    --channel activity-root-symlink --generation 1 \
    --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" 2>&1)"
  assert_eq "$?" "64"
  assert_contains "$output" 'activity path is a symlink'
  assert_fail test -e "$FIXTURE/root-symlink.args"
  raw="$(cat "$COMMS/activity-root-symlink.md")"
  assert_not_contains "$raw" 'tag=hello-ack=claude.1'
  assert_not_contains "$raw" 'tag=started'

  rm "$COMMS/.activity"
  mkdir "$COMMS/.activity"
  chmod 700 "$COMMS/.activity"
  init_launch_channel activity-channel-symlink
  ln -s "$FIXTURE/outside" "$COMMS/.activity/activity-channel-symlink"
  output="$(FAKE_ARGS="$FIXTURE/channel-symlink.args" \
    FAKE_STDIN="$FIXTURE/channel-symlink.stdin" PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex \
    --channel activity-channel-symlink --generation 1 \
    --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" 2>&1)"
  assert_eq "$?" "64"
  assert_contains "$output" 'activity path is a symlink'
  assert_fail test -e "$FIXTURE/channel-symlink.args"
  raw="$(cat "$COMMS/activity-channel-symlink.md")"
  assert_not_contains "$raw" 'tag=hello-ack=claude.1'
  assert_not_contains "$raw" 'tag=started'
  rm -rf "$FIXTURE"
}

test_heartbeat_requires_open_turn() {
  new_launch_fixture
  init_launch_channel waiting --heartbeat-after 1 --heartbeat-interval 1
  FAKE_ARGS="$FIXTURE/claude.args" FAKE_STDIN="$FIXTURE/claude.stdin" \
    FAKE_SLEEP=3 PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex --channel waiting \
    --generation 1 --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS"

  local raw
  raw="$(cat "$COMMS/waiting.md")"
  assert_not_contains "$raw" 'tag=alive'
  assert_contains "$raw" 'tag=exit=0'
  rm -rf "$FIXTURE"
}

test_startup_timeout_is_visible() {
  new_launch_fixture
  init_launch_channel startup-timeout
  FAKE_ARGS="$FIXTURE/codex.args" FAKE_STDIN="$FIXTURE/codex.stdin" \
    PATH="$FAKEBIN:$PATH" AGENT_COMMS_STARTUP_TIMEOUT=0.1 \
    bash "$AC" launch codex --role driver --peer claude --channel startup-timeout \
    --generation 1 --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" >/dev/null 2>&1
  assert_eq "$?" "2"
  assert_contains "$(cat "$COMMS/startup-timeout.md")" 'tag=startup-timeout'
  assert_fail test -e "$FIXTURE/codex.args"
  rm -rf "$FIXTURE"
}

test_launch_rejects_pinned_digest_before_model() {
  new_launch_fixture
  perl "$PROTOCOL" init --file "$COMMS/bad-digest.md" --session bad-digest \
    --driver codex --peer claude --release 2.0.0 \
    --digest bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --protocol 2 --release-root "$RELEASE_ROOT"
  local output
  output="$(FAKE_ARGS="$FIXTURE/claude.args" FAKE_STDIN="$FIXTURE/claude.stdin" \
    PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex --channel bad-digest \
    --generation 1 --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" 2>&1)"
  assert_eq "$?" "1"
  assert_contains "$output" 'pinned release identity mismatch'
  assert_fail test -e "$FIXTURE/claude.args"
  rm -rf "$FIXTURE"
}

test_launch_rejects_changed_resume_artifact_before_ready() {
  new_launch_fixture
  init_launch_channel bad-resume
  printf 'task' > "$FIXTURE/task"
  printf 'resume the interrupted review' > "$FIXTURE/handoff"
  printf 'original artifact' > "$FIXTURE/artifact"
  bash "$AC" send --channel bad-resume --dir "$COMMS" --from codex --generation 1 \
    --body-file "$FIXTURE/task"
  bash "$AC" resume --channel bad-resume --dir "$COMMS" --from codex --generation 1 \
    --replace claude --body-file "$FIXTURE/handoff" --artifact-file "$FIXTURE/artifact"
  printf 'changed artifact' > "$FIXTURE/artifact"

  local output raw
  output="$(FAKE_ARGS="$FIXTURE/claude.args" FAKE_STDIN="$FIXTURE/claude.stdin" \
    PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex --channel bad-resume \
    --generation 2 --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" 2>&1)"
  assert_eq "$?" "1"
  assert_contains "$output" 'resume packet artifact digest mismatch'
  assert_fail test -e "$FIXTURE/claude.args"
  raw="$(cat "$COMMS/bad-resume.md")"
  assert_contains "$raw" 'tag=resume-invalid'
  assert_not_contains "$raw" 'tag=hello-ack=claude.2'
  rm -rf "$FIXTURE"
}

test_signal_is_forwarded_and_visible() {
  new_launch_fixture
  init_launch_channel signal
  FAKE_ARGS="$FIXTURE/claude.args" FAKE_STDIN="$FIXTURE/claude.stdin" \
    FAKE_SLEEP=5 PATH="$FAKEBIN:$PATH" \
    bash "$AC" launch claude --role reviewer --peer codex --channel signal \
    --generation 1 --prompt-file "$FIXTURE/prompt" --client-release 2.0.0 \
    --dir "$COMMS" >/dev/null 2>&1 &
  local launcher_pid=$! attempts=0
  while [ ! -f "$FIXTURE/claude.args" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  kill -TERM "$launcher_pid"
  wait "$launcher_pid"
  assert_eq "$?" "143"
  assert_contains "$(cat "$COMMS/signal.md")" 'tag=signal=TERM'
  rm -rf "$FIXTURE"
}

if [ $# -gt 0 ]; then
  "$1"
else
  test_launch_adapters
  test_activity_setup_and_flag_validation
  test_heartbeat_and_lifecycle
  test_semantic_progress_timeout_is_enforced
  test_semantic_progress_resets_timeout
  test_semantic_timeout_pauses_without_floor
  test_semantic_inspection_failure_is_fail_closed
  test_sanitized_activity_sampling
  test_activity_generation_fencing
  test_activity_write_failure_is_fail_open
  test_activity_sampler_death_is_fail_open
  test_activity_shutdown_is_bounded
  test_activity_rejects_symlink_paths
  test_heartbeat_requires_open_turn
  test_startup_timeout_is_visible
  test_launch_rejects_pinned_digest_before_model
  test_launch_rejects_changed_resume_artifact_before_ready
  test_signal_is_forwarded_and_visible
fi

finish_tests "LAUNCH"
