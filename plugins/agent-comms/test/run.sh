#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/bin/lib.sh"

FAILS=0
assert_ok()   { if "$@"; then :; else echo "FAIL: expected ok: $*"; FAILS=$((FAILS+1)); fi; }
assert_fail() { if "$@"; then echo "FAIL: expected fail: $*"; FAILS=$((FAILS+1)); fi; }
assert_eq()   { [ "$1" = "$2" ] || { echo "FAIL: '$1' != '$2'"; FAILS=$((FAILS+1)); }; }
assert_contains(){ case "$1" in *"$2"*) :;; *) echo "FAIL: '$1' lacks '$2'"; FAILS=$((FAILS+1));; esac; }

setup_install_fixture() {
  local root="$1"
  FIXTURE_HOME="$root/home"
  FIXTURE_MARKETPLACE_ROOT="$root/marketplace"
  FIXTURE_CACHE_BASE="$root/cache"
  FIXTURE_CODEX_SKILL="$FIXTURE_HOME/.codex/skills/agent-comms"
  FIXTURE_BIN_DIR="$FIXTURE_HOME/.local/bin"
  mkdir -p "$FIXTURE_CACHE_BASE" "$(dirname "$FIXTURE_CODEX_SKILL")" "$FIXTURE_BIN_DIR"
  cp -R "$DIR" "$FIXTURE_MARKETPLACE_ROOT"
  FIXTURE_VERSION="$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$FIXTURE_MARKETPLACE_ROOT/.claude-plugin/plugin.json")"
  FIXTURE_CACHE_ROOT="$FIXTURE_CACHE_BASE/$FIXTURE_VERSION"
  cp -R "$FIXTURE_MARKETPLACE_ROOT" "$FIXTURE_CACHE_ROOT"
  ln -s "$FIXTURE_CACHE_ROOT/skills/agent-comms" "$FIXTURE_CODEX_SKILL"
  local name
  for name in agent-comms claude-review codex-review lib.sh; do
    ln -s "$FIXTURE_CACHE_ROOT/bin/$name" "$FIXTURE_BIN_DIR/$name"
  done
}

run_fixture() {
  HOME="$FIXTURE_HOME" \
    AGENT_COMMS_MARKETPLACE_ROOT="$FIXTURE_MARKETPLACE_ROOT" \
    AGENT_COMMS_CACHE_BASE="$FIXTURE_CACHE_BASE" \
    AGENT_COMMS_CODEX_SKILL="$FIXTURE_CODEX_SKILL" \
    AGENT_COMMS_BIN_DIR="$FIXTURE_BIN_DIR" \
    "$@"
}

run_fixture_doctor() {
  run_fixture bash "$FIXTURE_CACHE_ROOT/bin/agent-comms" doctor
}

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
  printf 'please review, ref=h1' | AGENT_COMMS_ROOT="$root" bash "$DIR/bin/agent-comms" send --channel c1 --from claude --tag review-ref=h1
  local f="$root/tmp/agent-comms/c1.md"
  assert_ok test -f "$f"
  assert_contains "$(cat "$f")" 'sender=claude'
  assert_contains "$(cat "$f")" 'tag=review-ref=h1'
  assert_contains "$(cat "$f")" 'please review, ref=h1'
  rm -rf "$root"
}
test_send_rejects_bad_channel() {
  local root; root="${TMPDIR:-/tmp}/acsendbad.$$"; mkdir -p "$root"
  assert_fail bash -c "echo x | AGENT_COMMS_ROOT='$root' bash '$DIR/bin/agent-comms' send --channel .. --from claude"
  rm -rf "$root"
}

test_send_body_file() {
  local root; root="${TMPDIR:-/tmp}/acbodyfile.$$"; mkdir -p "$root"
  local bf="$root/body.txt"; printf 'body from a file' > "$bf"
  AGENT_COMMS_ROOT="$root" bash "$DIR/bin/agent-comms" send --channel c1 --from claude --tag review-ref=h1 --body-file "$bf"
  local f="$root/tmp/agent-comms/c1.md"
  assert_contains "$(cat "$f")" 'body from a file'
  assert_contains "$(cat "$f")" 'tag=review-ref=h1'
  rm -rf "$root"
}

test_send_ref_flag_hashes_artifact() {
  local root; root="${TMPDIR:-/tmp}/acref.$$"; mkdir -p "$root"
  local art="$root/artifact.md"; printf 'plan content v1' > "$art"
  local bf="$root/msg.txt"; printf 'please review' > "$bf"
  local want; want="review-ref=$(file_sha256 "$art")"
  local err; err=$(AGENT_COMMS_ROOT="$root" bash "$DIR/bin/agent-comms" send --channel c1 --from claude --review-ref "$art" --body-file "$bf" 2>&1)
  local f="$root/tmp/agent-comms/c1.md"
  assert_contains "$(cat "$f")" "tag=$want"    # in-process hash landed as the wire tag
  assert_contains "$err" "$want"               # and was echoed to stderr for audit
  rm -rf "$root"
}

test_send_ref_and_tag_mutually_exclusive() {
  local root; root="${TMPDIR:-/tmp}/acrefx.$$"; mkdir -p "$root"
  local art="$root/a.md"; printf 'x' > "$art"
  assert_fail bash -c "echo body | AGENT_COMMS_ROOT='$root' bash '$DIR/bin/agent-comms' send --channel c1 --from claude --tag review-ref=h1 --review-ref '$art'"
  rm -rf "$root"
}

test_send_ref_missing_file_fails() {
  local root; root="${TMPDIR:-/tmp}/acrefm.$$"; mkdir -p "$root"
  assert_fail bash -c "echo body | AGENT_COMMS_ROOT='$root' bash '$DIR/bin/agent-comms' send --channel c1 --from claude --review-ref '$root/nope.md'"
  rm -rf "$root"
}

test_send_body_file_missing_fails() {
  local root; root="${TMPDIR:-/tmp}/acbfm.$$"; mkdir -p "$root"
  assert_fail bash -c "AGENT_COMMS_ROOT='$root' bash '$DIR/bin/agent-comms' send --channel c1 --from claude --body-file '$root/nope.txt'"
  rm -rf "$root"
}

test_recv_creates_file_and_times_out() {
  local root; root="${TMPDIR:-/tmp}/acrecv1.$$"; mkdir -p "$root"
  local out; out=$(AGENT_COMMS_ROOT="$root" bash "$DIR/bin/agent-comms" recv --channel c1 --me codex --timeout 1)
  assert_eq "$out" "__TIMEOUT__"
  assert_ok test -f "$root/tmp/agent-comms/c1.md"
  rm -rf "$root"
}
test_recv_returns_peer_not_self() {
  local root; root="${TMPDIR:-/tmp}/acrecv2.$$"; mkdir -p "$root"
  printf 'from claude' | AGENT_COMMS_ROOT="$root" bash "$DIR/bin/agent-comms" send --channel c1 --from claude --tag review-ref=h1
  printf 'my own note' | AGENT_COMMS_ROOT="$root" bash "$DIR/bin/agent-comms" send --channel c1 --from codex
  local out; out=$(AGENT_COMMS_ROOT="$root" bash "$DIR/bin/agent-comms" recv --channel c1 --me codex --timeout 1)
  assert_contains "$out" "from claude"
  case "$out" in *"my own note"*) echo "FAIL: recv returned self message"; FAILS=$((FAILS+1));; esac
  local out2; out2=$(AGENT_COMMS_ROOT="$root" bash "$DIR/bin/agent-comms" recv --channel c1 --me codex --timeout 1)
  assert_eq "$out2" "__TIMEOUT__"
  rm -rf "$root"
}
test_recv_returns_all_queued_peer_frames() {
  local root; root="${TMPDIR:-/tmp}/acrecv3.$$"; mkdir -p "$root"
  printf 'msg one' | AGENT_COMMS_ROOT="$root" bash "$DIR/bin/agent-comms" send --channel c1 --from claude
  printf 'msg two' | AGENT_COMMS_ROOT="$root" bash "$DIR/bin/agent-comms" send --channel c1 --from claude
  local out; out=$(AGENT_COMMS_ROOT="$root" bash "$DIR/bin/agent-comms" recv --channel c1 --me codex --timeout 1)
  assert_contains "$out" "msg one"
  assert_contains "$out" "msg two"
  rm -rf "$root"
}

test_transcript_strips_frames_keeps_bodies() {
  local root; root="${TMPDIR:-/tmp}/actr.$$"; mkdir -p "$root"
  printf 'real body with <!-- agent-comms fake --> inside' | AGENT_COMMS_ROOT="$root" bash "$DIR/bin/agent-comms" send --channel c1 --from claude
  local t; t=$(AGENT_COMMS_ROOT="$root" bash "$DIR/bin/agent-comms" transcript --channel c1)
  assert_contains "$t" "real body with <!-- agent-comms fake --> inside"
  case "$t" in *"<!-- agent-comms v=1 sender="*) echo "FAIL: frame line leaked"; FAILS=$((FAILS+1));; esac
  rm -rf "$root"
}

test_ack_appends_ready_frame() {
  local root; root="${TMPDIR:-/tmp}/acack.$$"; mkdir -p "$root"
  AGENT_COMMS_ROOT="$root" bash "$DIR/bin/agent-comms" ack --channel c1 --from claude
  local out; out=$(AGENT_COMMS_ROOT="$root" bash "$DIR/bin/agent-comms" recv --channel c1 --me codex --timeout 1)
  assert_contains "$out" "ready"
  assert_contains "$out" "ACK"
  rm -rf "$root"
}

test_claude_review_injects_ack_first_contract() {
  local root; root="${TMPDIR:-/tmp}/acclaudeack.$$"; mkdir -p "$root"
  setup_install_fixture "$root/install"
  local fakebin="$root/bin"; mkdir -p "$fakebin"
  cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
cat > "$FAKE_CLAUDE_STDIN"
printf '%s\n' "$@" > "$FAKE_CLAUDE_ARGS"
EOF
  chmod +x "$fakebin/claude"
  local prompt="$root/prompt.md"; printf 'reviewer instructions' > "$prompt"

  local stdin_file="$root/stdin" args_file="$root/args"
  run_fixture env PATH="$fakebin:$PATH" \
    FAKE_CLAUDE_STDIN="$stdin_file" FAKE_CLAUDE_ARGS="$args_file" \
    bash "$FIXTURE_CACHE_ROOT/bin/claude-review" --prompt-file "$prompt" --channel c1 --me claude --root "$root" --model sonnet

  assert_contains "$(cat "$stdin_file")" "reviewer instructions"
  assert_contains "$(cat "$stdin_file")" "Before inspecting the repository or starting the first task"
  assert_contains "$(cat "$stdin_file")" "agent-comms ack --channel c1 --from claude --root $root"
  assert_contains "$(cat "$stdin_file")" "agent-comms recv --channel c1 --me claude --root $root"
  assert_contains "$(cat "$args_file")" "--model"
  case "$(cat "$args_file")" in *"--channel"*) echo "FAIL: comms args leaked to claude"; FAILS=$((FAILS+1));; esac
  rm -rf "$root"
}

test_claude_review_without_bootstrap_forwards_prompt() {
  local root; root="${TMPDIR:-/tmp}/acclaudeplain.$$"; mkdir -p "$root"
  setup_install_fixture "$root/install"
  local fakebin="$root/bin"; mkdir -p "$fakebin"
  cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
cat > "$FAKE_CLAUDE_STDIN"
printf '%s\n' "$@" > "$FAKE_CLAUDE_ARGS"
EOF
  chmod +x "$fakebin/claude"
  local prompt="$root/prompt.md"; printf 'plain reviewer instructions' > "$prompt"
  local stdin_file="$root/stdin" args_file="$root/args"
  run_fixture env PATH="$fakebin:$PATH" \
    FAKE_CLAUDE_STDIN="$stdin_file" FAKE_CLAUDE_ARGS="$args_file" \
    bash "$FIXTURE_CACHE_ROOT/bin/claude-review" --prompt-file "$prompt" --model haiku

  assert_eq "$(cat "$stdin_file")" "plain reviewer instructions"
  assert_contains "$(cat "$args_file")" "--model"
  assert_contains "$(cat "$args_file")" "haiku"
  rm -rf "$root"
}

test_doctor_accepts_identical_release() {
  local root; root="${TMPDIR:-/tmp}/acdoctorok.$$"
  setup_install_fixture "$root"
  local out status
  out="$(run_fixture_doctor 2>&1)"; status=$?
  assert_eq "$status" "0"
  assert_contains "$out" "version: $FIXTURE_VERSION"
  assert_contains "$out" "installation: consistent"
  rm -rf "$root"
}

test_doctor_rejects_same_version_different_bytes() {
  local root; root="${TMPDIR:-/tmp}/acdoctordigest.$$"
  setup_install_fixture "$root"
  printf '\nstale cache\n' >> "$FIXTURE_CACHE_ROOT/skills/agent-comms/SKILL.md"
  local out status
  out="$(run_fixture_doctor 2>&1)"; status=$?
  assert_eq "$status" "1"
  assert_contains "$out" "runtime digest mismatch"
  assert_contains "$out" "claude plugin update agent-comms@klaidliadon"
  rm -rf "$root"
}

test_doctor_rejects_version_mismatch() {
  local root; root="${TMPDIR:-/tmp}/acdoctorversion.$$"
  setup_install_fixture "$root"
  FIXTURE_VERSION="$FIXTURE_VERSION" perl -pi -e 's/"version": "\Q$ENV{FIXTURE_VERSION}\E"/"version": "0.0.0"/' "$FIXTURE_CACHE_ROOT/.claude-plugin/plugin.json"
  local out status
  out="$(run_fixture_doctor 2>&1)"; status=$?
  assert_eq "$status" "1"
  assert_contains "$out" "version mismatch"
  rm -rf "$root"
}

test_doctor_rejects_missing_runtime_file() {
  local root; root="${TMPDIR:-/tmp}/acdoctormissing.$$"
  setup_install_fixture "$root"
  rm "$FIXTURE_CACHE_ROOT/bin/codex-review"
  local out status
  out="$(run_fixture_doctor 2>&1)"; status=$?
  assert_eq "$status" "1"
  assert_contains "$out" "missing release file"
  assert_contains "$out" "claude plugin update agent-comms@klaidliadon"
  rm -rf "$root"
}

test_doctor_rejects_missing_cache() {
  local root; root="${TMPDIR:-/tmp}/acdoctorcache.$$"
  setup_install_fixture "$root"
  rm -rf "$FIXTURE_CACHE_ROOT"
  local out status
  out="$(run_fixture bash "$FIXTURE_MARKETPLACE_ROOT/bin/agent-comms" doctor 2>&1)"; status=$?
  assert_eq "$status" "1"
  assert_contains "$out" "missing Claude cache"
  assert_contains "$out" "claude plugin update agent-comms@klaidliadon"
  rm -rf "$root"
}

test_doctor_rejects_mutable_runtime() {
  local root; root="${TMPDIR:-/tmp}/acdoctorruntime.$$"
  setup_install_fixture "$root"
  local out status
  out="$(run_fixture bash "$FIXTURE_MARKETPLACE_ROOT/bin/agent-comms" doctor 2>&1)"; status=$?
  assert_eq "$status" "1"
  assert_contains "$out" "runtime target mismatch"
  rm -rf "$root"
}

test_doctor_rejects_marketplace_backed_codex_links() {
  local root; root="${TMPDIR:-/tmp}/acdoctorlinks.$$"
  setup_install_fixture "$root"
  rm "$FIXTURE_CODEX_SKILL" "$FIXTURE_BIN_DIR/agent-comms"
  ln -s "$FIXTURE_MARKETPLACE_ROOT/skills/agent-comms" "$FIXTURE_CODEX_SKILL"
  ln -s "$FIXTURE_MARKETPLACE_ROOT/bin/agent-comms" "$FIXTURE_BIN_DIR/agent-comms"
  local out status
  out="$(run_fixture_doctor 2>&1)"; status=$?
  assert_eq "$status" "1"
  assert_contains "$out" "Codex skill target mismatch"
  assert_contains "$out" "command target mismatch"
  assert_contains "$out" "agent-comms install-codex"
  rm -rf "$root"
}

test_install_codex_links_shared_cache() {
  local root; root="${TMPDIR:-/tmp}/acinstallok.$$"
  setup_install_fixture "$root"
  rm "$FIXTURE_CODEX_SKILL"
  ln -s "$FIXTURE_MARKETPLACE_ROOT/skills/agent-comms" "$FIXTURE_CODEX_SKILL"
  local name
  for name in agent-comms claude-review codex-review lib.sh; do
    rm "$FIXTURE_BIN_DIR/$name"
    ln -s "$FIXTURE_MARKETPLACE_ROOT/bin/$name" "$FIXTURE_BIN_DIR/$name"
  done
  local out status
  out="$(run_fixture bash "$FIXTURE_MARKETPLACE_ROOT/bin/agent-comms" install-codex 2>&1)"; status=$?
  assert_eq "$status" "0"
  assert_eq "$(realpath "$FIXTURE_CODEX_SKILL")" "$(realpath "$FIXTURE_CACHE_ROOT/skills/agent-comms")"
  for name in agent-comms claude-review codex-review lib.sh; do
    assert_eq "$(realpath "$FIXTURE_BIN_DIR/$name")" "$(realpath "$FIXTURE_CACHE_ROOT/bin/$name")"
  done
  assert_contains "$out" "installation: consistent"
  rm -rf "$root"
}

test_install_codex_refuses_mismatched_cache() {
  local root; root="${TMPDIR:-/tmp}/acinstallbad.$$"
  setup_install_fixture "$root"
  printf '\nstale cache\n' >> "$FIXTURE_CACHE_ROOT/skills/agent-comms/SKILL.md"
  local out status
  out="$(run_fixture bash "$FIXTURE_MARKETPLACE_ROOT/bin/agent-comms" install-codex 2>&1)"; status=$?
  assert_eq "$status" "1"
  assert_contains "$out" "runtime digest mismatch"
  rm -rf "$root"
}

test_install_codex_refuses_missing_cache() {
  local root; root="${TMPDIR:-/tmp}/acinstallcache.$$"
  setup_install_fixture "$root"
  rm -rf "$FIXTURE_CACHE_ROOT"
  local out status
  out="$(run_fixture bash "$FIXTURE_MARKETPLACE_ROOT/bin/agent-comms" install-codex 2>&1)"; status=$?
  assert_eq "$status" "1"
  assert_contains "$out" "missing Claude cache"
  assert_contains "$out" "claude plugin update agent-comms@klaidliadon"
  rm -rf "$root"
}

test_install_codex_creates_missing_links() {
  local root; root="${TMPDIR:-/tmp}/acinstallfresh.$$"
  setup_install_fixture "$root"
  rm "$FIXTURE_CODEX_SKILL"
  local name
  for name in agent-comms claude-review codex-review lib.sh; do
    rm "$FIXTURE_BIN_DIR/$name"
  done
  local out status
  out="$(run_fixture bash "$FIXTURE_MARKETPLACE_ROOT/bin/agent-comms" install-codex 2>&1)"; status=$?
  assert_eq "$status" "0"
  assert_eq "$(realpath "$FIXTURE_CODEX_SKILL")" "$(realpath "$FIXTURE_CACHE_ROOT/skills/agent-comms")"
  for name in agent-comms claude-review codex-review lib.sh; do
    assert_eq "$(realpath "$FIXTURE_BIN_DIR/$name")" "$(realpath "$FIXTURE_CACHE_ROOT/bin/$name")"
  done
  rm -rf "$root"
}

test_install_codex_preserves_unrelated_symlink() {
  local root; root="${TMPDIR:-/tmp}/acinstalllink.$$"
  setup_install_fixture "$root"
  local unrelated="$root/unrelated-skill"; mkdir -p "$unrelated"
  rm "$FIXTURE_CODEX_SKILL"
  ln -s "$unrelated" "$FIXTURE_CODEX_SKILL"
  local out status
  out="$(run_fixture bash "$FIXTURE_MARKETPLACE_ROOT/bin/agent-comms" install-codex 2>&1)"; status=$?
  assert_eq "$status" "1"
  assert_contains "$out" "refusing unrelated symlink"
  assert_eq "$(realpath "$FIXTURE_CODEX_SKILL")" "$(realpath "$unrelated")"
  rm -rf "$root"
}

test_install_codex_preserves_non_symlink() {
  local root; root="${TMPDIR:-/tmp}/acinstallfile.$$"
  setup_install_fixture "$root"
  rm "$FIXTURE_CODEX_SKILL"
  printf 'owned by another installer' > "$FIXTURE_CODEX_SKILL"
  local out status
  out="$(run_fixture bash "$FIXTURE_MARKETPLACE_ROOT/bin/agent-comms" install-codex 2>&1)"; status=$?
  assert_eq "$status" "1"
  assert_contains "$out" "refusing non-symlink"
  assert_eq "$(cat "$FIXTURE_CODEX_SKILL")" "owned by another installer"
  rm -rf "$root"
}

test_install_codex_preflights_every_link() {
  local root; root="${TMPDIR:-/tmp}/acinstallpreflight.$$"
  setup_install_fixture "$root"
  rm "$FIXTURE_CODEX_SKILL"
  ln -s "$FIXTURE_MARKETPLACE_ROOT/skills/agent-comms" "$FIXTURE_CODEX_SKILL"
  local name
  for name in agent-comms claude-review codex-review lib.sh; do
    rm "$FIXTURE_BIN_DIR/$name"
    ln -s "$FIXTURE_MARKETPLACE_ROOT/bin/$name" "$FIXTURE_BIN_DIR/$name"
  done
  local unrelated="$root/unrelated"; printf 'owned by another installer' > "$unrelated"
  rm "$FIXTURE_BIN_DIR/codex-review"
  ln -s "$unrelated" "$FIXTURE_BIN_DIR/codex-review"
  local out status
  out="$(run_fixture bash "$FIXTURE_MARKETPLACE_ROOT/bin/agent-comms" install-codex 2>&1)"; status=$?
  assert_eq "$status" "1"
  assert_contains "$out" "refusing unrelated symlink"
  assert_eq "$(realpath "$FIXTURE_CODEX_SKILL")" "$(realpath "$FIXTURE_MARKETPLACE_ROOT/skills/agent-comms")"
  assert_eq "$(realpath "$FIXTURE_BIN_DIR/agent-comms")" "$(realpath "$FIXTURE_MARKETPLACE_ROOT/bin/agent-comms")"
  rm -rf "$root"
}

test_claude_review_refuses_mismatched_install() {
  local root; root="${TMPDIR:-/tmp}/acclaudedoc.$$"
  setup_install_fixture "$root"
  printf '\nstale cache\n' >> "$FIXTURE_CACHE_ROOT/skills/agent-comms/SKILL.md"
  local fakebin="$root/fakebin"; mkdir -p "$fakebin"
  cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
touch "$FAKE_CHILD_MARKER"
EOF
  chmod +x "$fakebin/claude"
  local prompt="$root/prompt.md"; printf 'reviewer instructions' > "$prompt"
  local marker="$root/spawned" out status
  out="$(run_fixture env PATH="$fakebin:$PATH" \
    FAKE_CHILD_MARKER="$marker" \
    bash "$FIXTURE_CACHE_ROOT/bin/claude-review" --prompt-file "$prompt" 2>&1)"; status=$?
  assert_eq "$status" "1"
  assert_fail test -e "$marker"
  assert_contains "$out" "runtime digest mismatch"
  rm -rf "$root"
}

test_codex_review_refuses_mismatched_install() {
  local root; root="${TMPDIR:-/tmp}/accodexdoc.$$"
  setup_install_fixture "$root"
  printf '\nstale cache\n' >> "$FIXTURE_CACHE_ROOT/skills/agent-comms/SKILL.md"
  local fakebin="$root/fakebin"; mkdir -p "$fakebin"
  cat > "$fakebin/codex" <<'EOF'
#!/usr/bin/env bash
touch "$FAKE_CHILD_MARKER"
EOF
  chmod +x "$fakebin/codex"
  local prompt="$root/prompt.md"; printf 'reviewer instructions' > "$prompt"
  local marker="$root/spawned" out status
  out="$(run_fixture env PATH="$fakebin:$PATH" \
    FAKE_CHILD_MARKER="$marker" \
    bash "$FIXTURE_CACHE_ROOT/bin/codex-review" --prompt-file "$prompt" 2>&1)"; status=$?
  assert_eq "$status" "1"
  assert_fail test -e "$marker"
  assert_contains "$out" "runtime digest mismatch"
  rm -rf "$root"
}

test_codex_review_forwards_prompt_and_args() {
  local root; root="${TMPDIR:-/tmp}/accodexok.$$"
  setup_install_fixture "$root"
  local fakebin="$root/fakebin"; mkdir -p "$fakebin"
  cat > "$fakebin/codex" <<'EOF'
#!/usr/bin/env bash
cat > "$FAKE_CODEX_STDIN"
printf '%s\n' "$@" > "$FAKE_CODEX_ARGS"
EOF
  chmod +x "$fakebin/codex"
  local prompt="$root/prompt.md"; printf 'reviewer instructions' > "$prompt"
  local stdin_file="$root/stdin" args_file="$root/args"
  run_fixture env PATH="$fakebin:$PATH" \
    FAKE_CODEX_STDIN="$stdin_file" FAKE_CODEX_ARGS="$args_file" \
    bash "$FIXTURE_CACHE_ROOT/bin/codex-review" --prompt-file "$prompt" --model test-model
  assert_eq "$(cat "$stdin_file")" "reviewer instructions"
  assert_contains "$(cat "$args_file")" "--dangerously-bypass-approvals-and-sandbox"
  assert_contains "$(cat "$args_file")" "--model"
  assert_contains "$(cat "$args_file")" "test-model"
  rm -rf "$root"
}

# run named test or all
if [ $# -gt 0 ]; then "$1"; else for t in $(declare -F | awk '/test_/{print $3}'); do "$t"; done; fi
[ "$FAILS" -eq 0 ] && echo "ALL PASS" || { echo "$FAILS failures"; exit 1; }
