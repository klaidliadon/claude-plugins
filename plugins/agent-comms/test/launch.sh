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
  printf '%s\n' '-p --permission-mode --add-dir'
  exit 0
fi
printf '%s\n' "$@" > "$FAKE_ARGS"
cat > "$FAKE_STDIN"
sleep "${FAKE_SLEEP:-0}"
exit "${FAKE_EXIT:-0}"
EOF
  cat > "$FAKEBIN/codex" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--help" ]; then
  printf '%s\n' '--dangerously-bypass-approvals-and-sandbox --skip-git-repo-check'
  exit 0
fi
printf '%s\n' "$@" > "$FAKE_ARGS"
cat > "$FAKE_STDIN"
sleep "${FAKE_SLEEP:-0}"
exit "${FAKE_EXIT:-0}"
EOF
  chmod +x "$FAKEBIN/claude" "$FAKEBIN/codex"
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

  local claude_args codex_args claude_input codex_input
  claude_args="$(cat "$FIXTURE/claude.args")"
  codex_args="$(cat "$FIXTURE/codex.args")"
  claude_input="$(cat "$FIXTURE/claude.stdin")"
  codex_input="$(cat "$FIXTURE/codex.stdin")"
  assert_contains "$claude_args" '-p'
  assert_contains "$claude_args" '--permission-mode'
  assert_contains "$claude_args" '--add-dir'
  assert_contains "$claude_args" '--model'
  assert_not_contains "$claude_args" '--channel'
  assert_contains "$codex_args" 'exec'
  assert_contains "$codex_args" '--dangerously-bypass-approvals-and-sandbox'
  assert_contains "$codex_args" '--skip-git-repo-check'
  assert_contains "$codex_args" '--model'
  assert_not_contains "$codex_args" '--generation'
  assert_contains "$claude_input" 'review the current branch'
  assert_contains "$claude_input" "$RELEASE_ROOT/bin/agent-comms send --channel claude-launch"
  assert_contains "$claude_input" "$RELEASE_ROOT/bin/agent-comms recv --channel claude-launch"
  assert_contains "$claude_input" 'Your first transport action is receive'
  assert_contains "$codex_input" "$RELEASE_ROOT/bin/agent-comms send --channel codex-launch"
  assert_contains "$codex_input" "$RELEASE_ROOT/bin/agent-comms recv --channel codex-launch"
  assert_contains "$codex_input" 'You own the first turn'
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
  test_heartbeat_and_lifecycle
  test_heartbeat_requires_open_turn
  test_startup_timeout_is_visible
  test_launch_rejects_pinned_digest_before_model
  test_launch_rejects_changed_resume_artifact_before_ready
  test_signal_is_forwarded_and_visible
fi

finish_tests "LAUNCH"
