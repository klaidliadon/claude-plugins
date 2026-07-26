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

test_public_cli_defaults_to_over() {
  new_fixture
  local comms="$FIXTURE/comms"
  mkdir -p "$comms"
  bash "$AC" init --channel cli --dir "$comms" --session session-1 \
    --driver codex --peer claude --release 2.0.0 \
    --digest aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --protocol 2 --release-root "$FIXTURE/release"
  bash "$AC" send --channel cli --dir "$comms" --from codex --generation 1 \
    --continue --body-file "$FIXTURE/first"
  bash "$AC" send --channel cli --dir "$comms" --from codex --generation 1 \
    --review-ref "$FIXTURE/final" --body-file "$FIXTURE/final"

  local raw out
  raw="$(cat "$comms/cli.md")"
  out="$(bash "$AC" recv --channel cli --dir "$comms" --me claude --generation 1 \
    --silence-seconds 1 --turn-seconds 2)"
  assert_contains "$raw" 'state=continue'
  assert_contains "$raw" 'state=over'
  assert_contains "$raw" 'tag=review-ref='
  assert_contains "$out" 'first body'
  assert_contains "$out" 'final body'
  rm -rf "$FIXTURE"
}

if [ $# -gt 0 ]; then
  "$1"
else
  test_frame_roundtrip
  test_turn_state_machine
  test_recv_coalesces_complete_turn
  test_public_cli_defaults_to_over
fi

finish_tests "PROTOCOL"
