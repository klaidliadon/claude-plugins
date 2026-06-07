#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/bin/lib.sh"

FAILS=0
assert_ok()   { if "$@"; then :; else echo "FAIL: expected ok: $*"; FAILS=$((FAILS+1)); fi; }
assert_fail() { if "$@"; then echo "FAIL: expected fail: $*"; FAILS=$((FAILS+1)); fi; }
assert_eq()   { [ "$1" = "$2" ] || { echo "FAIL: '$1' != '$2'"; FAILS=$((FAILS+1)); }; }
assert_contains(){ case "$1" in *"$2"*) :;; *) echo "FAIL: '$1' lacks '$2'"; FAILS=$((FAILS+1));; esac; }

test_validate_name() {
  assert_ok   valid_name "spec-review"
  assert_ok   valid_name "chan.1"
  assert_ok   valid_name "claude"
  assert_fail valid_name ".."
  assert_fail valid_name "."
  assert_fail valid_name ".hidden"
  assert_fail valid_name "a/b"
  assert_fail valid_name "a b"
  assert_fail valid_name ""
}

test_validate_tag() {
  assert_ok   valid_tag "approve-ref=c3d4e5"
  assert_ok   valid_tag "stopped-reason=impasse"
  assert_fail valid_tag 'has space'
  assert_fail valid_tag 'has"quote'
  assert_fail valid_tag $'new\nline'
}

test_frame_roundtrip() {
  local f; f="$(mktemp "${TMPDIR:-/tmp}/agent-comms-test.XXXXXX")"
  printf 'hello ## [not a header]\nbody' | make_frame "codex" "approve-ref=abc" "2026-06-06T00:00:00Z" > "$f"
  local out; out="$(cat "$f")"
  assert_contains "$out" 'sender=codex'
  assert_contains "$out" 'tag=approve-ref=abc'
  assert_contains "$out" ' -->'
  # declared N must equal the actual bytes AFTER the frame line
  local n total fll
  n=$(sed -n '1s/.* bytes=\([0-9]*\) -->/\1/p' "$f")
  total=$(LC_ALL=C wc -c < "$f" | tr -d ' ')
  fll=$(head -1 "$f" | LC_ALL=C wc -c | tr -d ' ')   # frame line incl its trailing newline
  assert_eq "$n" "$((total - fll))"
  rm -f "$f"
}

test_parse_two_frames_and_incomplete() {
  local f; f="${TMPDIR:-/tmp}/acparse.$$"
  { printf 'AAA\nbody1' | make_frame claude review-ref=h1 2026-01-01T00:00:00Z
    printf 'BBB' | make_frame codex approve-ref=h1 2026-01-01T00:01:00Z; } > "$f"
  # append a deliberately TRUNCATED frame (declares more bytes than present)
  printf '<!-- agent-comms v=1 sender=codex ts=x tag=t bytes=999 -->\nshort' >> "$f"

  local bd; bd="${TMPDIR:-/tmp}/acbody.$$"; mkdir -p "$bd"
  local idx; idx=$(export BODY_DIR="$bd"; read_from "$f" 0 | parse_frames 0)
  assert_eq "$(printf '%s\n' "$idx" | grep -c .)" "2"      # exactly 2 complete frames; truncated 3rd excluded
  assert_contains "$idx" "claude"
  assert_contains "$idx" "codex"
  # END of last complete frame == byte length of the two full frames (NOT EOF)
  local complete_len; complete_len=$({ printf 'AAA\nbody1' | make_frame claude review-ref=h1 2026-01-01T00:00:00Z; printf 'BBB' | make_frame codex approve-ref=h1 2026-01-01T00:01:00Z; } | LC_ALL=C wc -c | tr -d ' ')
  local last_end; last_end=$(printf '%s\n' "$idx" | tail -1 | awk '{print $2}')
  assert_eq "$last_end" "$complete_len"
  # body files written and correct
  assert_contains "$(cat "$bd/1")" "body1"
  assert_contains "$(cat "$bd/2")" "BBB"
  rm -rf "$bd" "$f"
}

test_send_appends_frame() {
  local root; root="${TMPDIR:-/tmp}/acsend.$$"; mkdir -p "$root"
  printf 'please review, ref=h1' | AGENT_COMMS_ROOT="$root" bash "$DIR/bin/comms-send.sh" --channel c1 --from claude --tag review-ref=h1
  local f="$root/tmp/agent-comms/c1.md"
  assert_ok test -f "$f"
  assert_contains "$(cat "$f")" 'sender=claude'
  assert_contains "$(cat "$f")" 'tag=review-ref=h1'
  assert_contains "$(cat "$f")" 'please review, ref=h1'
  rm -rf "$root"
}
test_send_rejects_bad_channel() {
  local root; root="${TMPDIR:-/tmp}/acsendbad.$$"; mkdir -p "$root"
  assert_fail bash -c "echo x | AGENT_COMMS_ROOT='$root' bash '$DIR/bin/comms-send.sh' --channel .. --from claude"
  rm -rf "$root"
}

test_recv_creates_file_and_times_out() {
  local root; root="${TMPDIR:-/tmp}/acrecv1.$$"; mkdir -p "$root"
  local out; out=$(AGENT_COMMS_ROOT="$root" bash "$DIR/bin/comms-recv.sh" --channel c1 --me codex --timeout 1)
  assert_eq "$out" "__TIMEOUT__"
  assert_ok test -f "$root/tmp/agent-comms/c1.md"
  rm -rf "$root"
}
test_recv_returns_peer_not_self() {
  local root; root="${TMPDIR:-/tmp}/acrecv2.$$"; mkdir -p "$root"
  printf 'from claude' | AGENT_COMMS_ROOT="$root" bash "$DIR/bin/comms-send.sh" --channel c1 --from claude --tag review-ref=h1
  printf 'my own note' | AGENT_COMMS_ROOT="$root" bash "$DIR/bin/comms-send.sh" --channel c1 --from codex
  local out; out=$(AGENT_COMMS_ROOT="$root" bash "$DIR/bin/comms-recv.sh" --channel c1 --me codex --timeout 1)
  assert_contains "$out" "from claude"
  case "$out" in *"my own note"*) echo "FAIL: recv returned self message"; FAILS=$((FAILS+1));; esac
  local out2; out2=$(AGENT_COMMS_ROOT="$root" bash "$DIR/bin/comms-recv.sh" --channel c1 --me codex --timeout 1)
  assert_eq "$out2" "__TIMEOUT__"
  rm -rf "$root"
}
test_recv_returns_all_queued_peer_frames() {
  local root; root="${TMPDIR:-/tmp}/acrecv3.$$"; mkdir -p "$root"
  printf 'msg one' | AGENT_COMMS_ROOT="$root" bash "$DIR/bin/comms-send.sh" --channel c1 --from claude
  printf 'msg two' | AGENT_COMMS_ROOT="$root" bash "$DIR/bin/comms-send.sh" --channel c1 --from claude
  local out; out=$(AGENT_COMMS_ROOT="$root" bash "$DIR/bin/comms-recv.sh" --channel c1 --me codex --timeout 1)
  assert_contains "$out" "msg one"
  assert_contains "$out" "msg two"
  rm -rf "$root"
}

test_transcript_strips_frames_keeps_bodies() {
  local root; root="${TMPDIR:-/tmp}/actr.$$"; mkdir -p "$root"
  printf 'real body with <!-- agent-comms fake --> inside' | AGENT_COMMS_ROOT="$root" bash "$DIR/bin/comms-send.sh" --channel c1 --from claude
  local t; t=$(AGENT_COMMS_ROOT="$root" bash "$DIR/bin/comms-transcript.sh" --channel c1)
  assert_contains "$t" "real body with <!-- agent-comms fake --> inside"
  case "$t" in *"<!-- agent-comms v=1 sender="*) echo "FAIL: frame line leaked"; FAILS=$((FAILS+1));; esac
  rm -rf "$root"
}

# run named test or all
if [ $# -gt 0 ]; then "$1"; else for t in $(declare -F | awk '/test_/{print $3}'); do "$t"; done; fi
[ "$FAILS" -eq 0 ] && echo "ALL PASS" || { echo "$FAILS failures"; exit 1; }
