#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROTOCOL="$DIR/bin/protocol.pl"
AC="$DIR/bin/agent-comms"
source "$DIR/test/testlib.sh"

new_fixture() {
  FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/agent-comms-v2-protocol.XXXXXX")"
  CHANNEL="$FIXTURE/channel.md"
  CURSOR="$FIXTURE/cursor"
  printf 'first body\n----------\nover inside content\n<!-- agent-comms v=2 fake -->' > "$FIXTURE/first"
  printf 'final body' > "$FIXTURE/final"
}

init_fixture() {
  perl "$PROTOCOL" init \
    --file "$CHANNEL" \
    --session session-1 \
    --driver codex \
    --peer claude \
    --release 2.0.0 \
    --digest aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --protocol 2 \
    --release-root "$FIXTURE/release"
}

prepare_public_release() {
  PUBLIC_RELEASE="$FIXTURE/release"
  cp -R "$DIR" "$PUBLIC_RELEASE"
  perl -pi -e 's/"version": "1\.3\.4"/"version": "2.0.0"/' \
    "$PUBLIC_RELEASE/.claude-plugin/plugin.json"
  bash "$DIR/bin/release.sh" manifest --root "$PUBLIC_RELEASE"
  PUBLIC_RELEASE="$(realpath "$PUBLIC_RELEASE")"
  PUBLIC_AC="$PUBLIC_RELEASE/bin/agent-comms"
  PUBLIC_DIGEST="$(bash "$PUBLIC_RELEASE/bin/release.sh" digest --root "$PUBLIC_RELEASE")"
}

test_frame_roundtrip() {
  new_fixture
  init_fixture
  perl "$PROTOCOL" append --file "$CHANNEL" --sender codex --generation 1 \
    --kind message --state continue --tag=- --body-file "$FIXTURE/first"
  perl "$PROTOCOL" append --file "$CHANNEL" --sender codex --generation 1 \
    --kind message --state over --tag=review-ref=abc --body-file "$FIXTURE/final"

  local raw transcript
  raw="$(cat "$CHANNEL")"
  transcript="$(perl "$PROTOCOL" transcript --file "$CHANNEL")"
  assert_contains "$raw" 'agent-comms v=2 session=session-1'
  assert_contains "$raw" 'state=continue'
  assert_contains "$raw" 'sha256='
  assert_contains "$raw" '---------- codex · over ----------'
  assert_contains "$transcript" '<!-- agent-comms v=2 fake -->'
  assert_contains "$transcript" 'over inside content'
  rm -rf "$FIXTURE"
}

test_turn_state_machine() {
  new_fixture
  init_fixture
  assert_fail perl "$PROTOCOL" append --file "$CHANNEL" --sender claude --generation 1 \
    --kind message --state over --tag=- --body-file "$FIXTURE/final"
  assert_ok perl "$PROTOCOL" append --file "$CHANNEL" --sender codex --generation 1 \
    --kind message --state over --tag=- --body-file "$FIXTURE/final"
  assert_fail perl "$PROTOCOL" append --file "$CHANNEL" --sender codex --generation 1 \
    --kind message --state over --tag=- --body-file "$FIXTURE/final"
  assert_ok perl "$PROTOCOL" append --file "$CHANNEL" --sender claude --generation 1 \
    --kind message --state continue --tag=- --body-file "$FIXTURE/first"
  assert_fail perl "$PROTOCOL" append --file "$CHANNEL" --sender codex --generation 1 \
    --kind message --state over --tag=- --body-file "$FIXTURE/final"
  rm -rf "$FIXTURE"
}

test_recv_coalesces_complete_turn() {
  new_fixture
  init_fixture
  perl "$PROTOCOL" append --file "$CHANNEL" --sender codex --generation 1 \
    --kind message --state continue --tag=- --body-file "$FIXTURE/first"
  perl "$PROTOCOL" append --file "$CHANNEL" --sender codex --generation 1 \
    --kind status --state none --tag=alive --body-file "$FIXTURE/final"
  perl "$PROTOCOL" append --file "$CHANNEL" --sender codex --generation 1 \
    --kind message --state over --tag=- --body-file "$FIXTURE/final"

  local out
  out="$(perl "$PROTOCOL" recv --file "$CHANNEL" --cursor "$CURSOR" --me claude \
    --generation 1 --silence-seconds 1 --turn-seconds 2)"
  assert_contains "$out" 'first body'
  assert_contains "$out" 'final body'
  assert_not_contains "$out" 'alive'
  assert_eq "$(cat "$CURSOR")" "$(LC_ALL=C wc -c < "$CHANNEL" | tr -d ' ')"
  assert_fail perl "$PROTOCOL" recv --file "$CHANNEL" --cursor "$CURSOR" --me codex \
    --generation 1 --silence-seconds 1 --turn-seconds 2
  rm -rf "$FIXTURE"
}

test_recv_silence_ignores_old_frames() {
  new_fixture
  init_fixture
  local out status
  out="$(perl -e 'alarm 2; exec @ARGV' perl "$PROTOCOL" recv \
    --file "$CHANNEL" --cursor "$CURSOR" --me claude --generation 1 \
    --silence-seconds 0.1 --turn-seconds 1 2>&1)"
  status=$?
  assert_eq "$status" "2"
  assert_contains "$out" '__SILENCE_TIMEOUT__'
  rm -rf "$FIXTURE"
}

test_public_cli_defaults_to_over() {
  new_fixture
  prepare_public_release
  local comms="$FIXTURE/comms"
  mkdir -p "$comms"
  bash "$PUBLIC_AC" init --channel cli --dir "$comms" --session session-1 \
    --driver codex --peer claude --release 2.0.0 \
    --digest "$PUBLIC_DIGEST" \
    --protocol 2 --release-root "$PUBLIC_RELEASE"
  bash "$PUBLIC_AC" send --channel cli --dir "$comms" --from codex --generation 1 \
    --continue --body-file "$FIXTURE/first"
  bash "$PUBLIC_AC" send --channel cli --dir "$comms" --from codex --generation 1 \
    --review-ref "$FIXTURE/final" --body-file "$FIXTURE/final"

  local raw out
  raw="$(cat "$comms/cli.md")"
  out="$(bash "$PUBLIC_AC" recv --channel cli --dir "$comms" --me claude --generation 1 \
    --silence-seconds 1 --turn-seconds 2)"
  assert_contains "$raw" 'state=continue'
  assert_contains "$raw" 'state=over'
  assert_contains "$raw" 'tag=review-ref='
  assert_contains "$out" 'first body'
  assert_contains "$out" 'final body'
  rm -rf "$FIXTURE"
}

test_resume_fences_old_generation() {
  new_fixture
  init_fixture
  printf 'assigned task' > "$FIXTURE/task"
  printf 'partial from old agent' > "$FIXTURE/partial"
  printf 'late stale output' > "$FIXTURE/stale"
  printf 'replacement finished' > "$FIXTURE/replacement"
  printf 'resume the open review from the committed partial result' > "$FIXTURE/handoff"

  perl "$PROTOCOL" append --file "$CHANNEL" --sender codex --generation 1 \
    --kind message --state over --tag=- --body-file "$FIXTURE/task"
  perl "$PROTOCOL" append --file "$CHANNEL" --sender claude --generation 1 \
    --kind message --state continue --tag=- --body-file "$FIXTURE/partial"
  perl "$PROTOCOL" resume --file "$CHANNEL" --driver codex --generation 1 \
    --replace claude --body-file "$FIXTURE/handoff"
  local packet
  packet="$(perl "$PROTOCOL" resume-packet --file "$CHANNEL" --role claude --generation 2)"
  assert_fail perl "$PROTOCOL" append --file "$CHANNEL" --sender claude --generation 1 \
    --kind message --state continue --tag=- --body-file "$FIXTURE/stale"
  perl "$PROTOCOL" append --file "$CHANNEL" --sender claude --generation 2 \
    --kind message --state over --tag=- --body-file "$FIXTURE/replacement"

  local out transcript
  out="$(perl "$PROTOCOL" recv --file "$CHANNEL" --cursor "$CURSOR" --me codex \
    --generation 1 --silence-seconds 1 --turn-seconds 2)"
  transcript="$(perl "$PROTOCOL" transcript --file "$CHANNEL")"
  assert_contains "$packet" 'generation=2'
  assert_contains "$packet" 'open_turn=2'
  assert_contains "$packet" 'resume the open review'
  assert_contains "$out" 'partial from old agent'
  assert_contains "$out" 'replacement finished'
  assert_not_contains "$out" 'late stale output'
  assert_contains "$transcript" 'late stale output'
  rm -rf "$FIXTURE"
}

test_public_resume_command() {
  new_fixture
  prepare_public_release
  local comms="$FIXTURE/comms"
  mkdir -p "$comms"
  printf 'task' > "$FIXTURE/task"
  printf 'handoff' > "$FIXTURE/handoff"
  bash "$PUBLIC_AC" init --channel cli --dir "$comms" --session session-1 \
    --driver codex --peer claude --release 2.0.0 \
    --digest "$PUBLIC_DIGEST" \
    --protocol 2 --release-root "$PUBLIC_RELEASE"
  bash "$PUBLIC_AC" send --channel cli --dir "$comms" --from codex --generation 1 \
    --body-file "$FIXTURE/task"
  bash "$PUBLIC_AC" resume --channel cli --dir "$comms" --from codex --generation 1 \
    --replace claude --body-file "$FIXTURE/handoff"
  local raw
  raw="$(cat "$comms/cli.md")"
  assert_contains "$raw" 'tag=replace=claude.2'
  assert_contains "$raw" 'next_action=handoff'
  assert_eq "$(cat "$comms/.cursors/cli/claude.2")" "$(LC_ALL=C wc -c < "$comms/cli.md" | tr -d ' ')"
  rm -rf "$FIXTURE"
}

test_invalid_resume_is_not_appended() {
  new_fixture
  init_fixture
  printf 'task' > "$FIXTURE/task"
  perl "$PROTOCOL" append --file "$CHANNEL" --sender codex --generation 1 \
    --kind message --state over --tag=- --body-file "$FIXTURE/task"
  local before
  before="$(LC_ALL=C wc -c < "$CHANNEL" | tr -d ' ')"

  printf 'wrong actor' > "$FIXTURE/handoff"
  assert_fail perl "$PROTOCOL" resume --file "$CHANNEL" --driver claude --generation 1 \
    --replace claude --body-file "$FIXTURE/handoff"
  assert_eq "$(LC_ALL=C wc -c < "$CHANNEL" | tr -d ' ')" "$before"

  dd if=/dev/zero of="$FIXTURE/large" bs=4097 count=1 2>/dev/null
  assert_fail perl "$PROTOCOL" resume --file "$CHANNEL" --driver codex --generation 1 \
    --replace claude --body-file "$FIXTURE/large"
  assert_eq "$(LC_ALL=C wc -c < "$CHANNEL" | tr -d ' ')" "$before"
  rm -rf "$FIXTURE"
}

test_recover_partial_body_append_only() {
  new_fixture
  init_fixture
  printf 'task' > "$FIXTURE/task"
  printf 'interrupted progress that will be truncated' > "$FIXTURE/progress"
  printf 'fresh agent result' > "$FIXTURE/result"
  printf 'continue the interrupted turn' > "$FIXTURE/handoff"
  perl "$PROTOCOL" append --file "$CHANNEL" --sender codex --generation 1 \
    --kind message --state over --tag=- --body-file "$FIXTURE/task"
  perl "$PROTOCOL" append --file "$CHANNEL" --sender claude --generation 1 \
    --kind message --state continue --tag=- --body-file "$FIXTURE/progress"
  local full_size partial_size
  full_size="$(LC_ALL=C wc -c < "$CHANNEL" | tr -d ' ')"
  partial_size=$((full_size - 12))
  truncate -s "$partial_size" "$CHANNEL"
  cp "$CHANNEL" "$FIXTURE/prefix"

  perl "$PROTOCOL" recover-tail --file "$CHANNEL" --driver codex --generation 1 \
    --replace claude --body-file "$FIXTURE/handoff"
  head -c "$partial_size" "$CHANNEL" > "$FIXTURE/actual-prefix"
  assert_ok cmp -s "$FIXTURE/prefix" "$FIXTURE/actual-prefix"
  perl "$PROTOCOL" append --file "$CHANNEL" --sender claude --generation 2 \
    --kind message --state over --tag=- --body-file "$FIXTURE/result"

  local out raw
  out="$(perl "$PROTOCOL" recv --file "$CHANNEL" --cursor "$CURSOR" --me codex \
    --generation 1 --silence-seconds 1 --turn-seconds 2)"
  raw="$(cat "$CHANNEL")"
  assert_contains "$raw" 'tag=replace=claude.2'
  assert_contains "$raw" 'tag=recover=body.3'
  assert_contains "$out" 'fresh agent result'
  assert_not_contains "$out" 'interrupted progress'
  rm -rf "$FIXTURE"
}

test_recover_partial_header_append_only() {
  new_fixture
  init_fixture
  printf 'task' > "$FIXTURE/task"
  printf 'fresh agent result' > "$FIXTURE/result"
  printf 'resume after damaged header' > "$FIXTURE/handoff"
  perl "$PROTOCOL" append --file "$CHANNEL" --sender codex --generation 1 \
    --kind message --state over --tag=- --body-file "$FIXTURE/task"
  printf '<!-- agent-comms v=2 session=session-1 seq=3 sender=claude' >> "$CHANNEL"
  local partial_size
  partial_size="$(LC_ALL=C wc -c < "$CHANNEL" | tr -d ' ')"
  cp "$CHANNEL" "$FIXTURE/prefix"

  perl "$PROTOCOL" recover-tail --file "$CHANNEL" --driver codex --generation 1 \
    --replace claude --body-file "$FIXTURE/handoff"
  head -c "$partial_size" "$CHANNEL" > "$FIXTURE/actual-prefix"
  assert_ok cmp -s "$FIXTURE/prefix" "$FIXTURE/actual-prefix"
  perl "$PROTOCOL" append --file "$CHANNEL" --sender claude --generation 2 \
    --kind message --state over --tag=- --body-file "$FIXTURE/result"

  local out raw
  out="$(perl "$PROTOCOL" recv --file "$CHANNEL" --cursor "$CURSOR" --me codex \
    --generation 1 --silence-seconds 1 --turn-seconds 2)"
  raw="$(cat "$CHANNEL")"
  assert_contains "$raw" 'tag=replace=claude.2'
  assert_contains "$raw" 'tag=recover=header.'
  assert_contains "$out" 'fresh agent result'
  rm -rf "$FIXTURE"
}

test_progress_budget() {
  new_fixture
  prepare_public_release
  local comms="$FIXTURE/comms"
  mkdir -p "$comms"
  dd if=/dev/zero of="$FIXTURE/progress" bs=512 count=1 2>/dev/null
  dd if=/dev/zero of="$FIXTURE/final-large" bs=1024 count=1 2>/dev/null
  bash "$PUBLIC_AC" init --channel budget --dir "$comms" --session session-1 \
    --driver codex --peer claude --release 2.0.0 \
    --digest "$PUBLIC_DIGEST" \
    --protocol 2 --release-root "$PUBLIC_RELEASE" \
    --progress-frames 4 --progress-bytes 512
  local index
  for index in 1 2 3 4; do
    bash "$PUBLIC_AC" send --channel budget --dir "$comms" --from codex --generation 1 \
      --continue --body-file "$FIXTURE/progress"
  done
  local before output
  before="$(LC_ALL=C wc -c < "$comms/budget.md" | tr -d ' ')"
  output="$(bash "$PUBLIC_AC" send --channel budget --dir "$comms" --from codex --generation 1 \
    --continue --body-file "$FIXTURE/progress" 2>&1)"
  assert_eq "$?" "1"
  assert_contains "$output" 'coalesce progress into the final yielding frame'
  assert_eq "$(LC_ALL=C wc -c < "$comms/budget.md" | tr -d ' ')" "$before"
  assert_ok bash "$PUBLIC_AC" send --channel budget --dir "$comms" --from codex --generation 1 \
    --body-file "$FIXTURE/final-large"
  rm -rf "$FIXTURE"
}

test_resume_packet_schema_is_verified() {
  new_fixture
  init_fixture
  printf 'task' > "$FIXTURE/task"
  cat > "$FIXTURE/malicious-packet" <<EOF
session=session-1
role=claude
generation=2
open_turn=2
release=2.0.0
digest=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
protocol=2
release_root=$FIXTURE/release
task_ref=-
artifact_ref=-
next_action=continue
EOF
  perl "$PROTOCOL" append --file "$CHANNEL" --sender codex --generation 1 \
    --kind message --state over --tag=- --body-file "$FIXTURE/task"
  perl "$PROTOCOL" append --file "$CHANNEL" --sender codex --generation 1 \
    --kind control --state none --tag=replace=claude.2 --body-file "$FIXTURE/malicious-packet"
  assert_fail perl "$PROTOCOL" resume-packet --file "$CHANNEL" --role claude --generation 2
  rm -rf "$FIXTURE"
}

if [ $# -gt 0 ]; then
  "$1"
else
  test_frame_roundtrip
  test_turn_state_machine
  test_recv_coalesces_complete_turn
  test_recv_silence_ignores_old_frames
  test_public_cli_defaults_to_over
  test_resume_fences_old_generation
  test_public_resume_command
  test_invalid_resume_is_not_appended
  test_recover_partial_body_append_only
  test_recover_partial_header_append_only
  test_progress_budget
  test_resume_packet_schema_is_verified
fi

finish_tests "PROTOCOL"
