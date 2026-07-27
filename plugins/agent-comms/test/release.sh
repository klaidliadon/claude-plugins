#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="$DIR/bin/release.sh"
source "$DIR/test/testlib.sh"

new_release_fixture() {
  FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/agent-comms-v2-release.XXXXXX")"
  SOURCE="$FIXTURE/source"
  cp -R "$DIR" "$SOURCE"
  rm -f "$SOURCE/manifest.lock"
}

setup_installed_fixture() {
  new_release_fixture
  bash "$RELEASE" manifest --root "$SOURCE"
  VERSION="$(sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$SOURCE/.claude-plugin/plugin.json")"
  CACHE="$FIXTURE/cache/$VERSION"
  SHARE="$FIXTURE/share"
  PUBLIC_BIN="$FIXTURE/home/.local/bin"
  CODEX_SKILL="$FIXTURE/home/.codex/skills/agent-comms"
  FAKEBIN="$FIXTURE/fakebin"
  mkdir -p "$(dirname "$CACHE")" "$SHARE" "$PUBLIC_BIN" "$(dirname "$CODEX_SKILL")" "$FAKEBIN"
  cp -R "$SOURCE" "$CACHE"
  ln -s "$CACHE" "$SHARE/current"
  ln -s "$SHARE/current/bin/agent-comms" "$PUBLIC_BIN/agent-comms"
  ln -s "$SHARE/current/skills/agent-comms" "$CODEX_SKILL"
  cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "list" ] && [ "${3:-}" = "--json" ]; then
  printf '[{"id":"agent-comms@klaidliadon","version":"%s","enabled":true,"installPath":"%s"}]\n' \
    "$FAKE_SELECTED_VERSION" "$FAKE_SELECTED_PATH"
  exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "update" ]; then
  exit "${FAKE_UPDATE_STATUS:-0}"
fi
if [ "${1:-}" = "--help" ]; then
  printf '%s\n' '--add-dir --permission-mode -p'
  exit 0
fi
exit 64
EOF
  cat > "$FAKEBIN/codex" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--help" ]; then
  printf '%s\n' '--dangerously-bypass-approvals-and-sandbox --skip-git-repo-check'
  exit 0
fi
exit 64
EOF
  chmod +x "$FAKEBIN/claude" "$FAKEBIN/codex"
}

run_installed() {
  env \
    HOME="$FIXTURE/home" \
    PATH="$FAKEBIN:$PATH" \
    FAKE_SELECTED_VERSION="${SELECTED_VERSION:-$VERSION}" \
    FAKE_SELECTED_PATH="${SELECTED_PATH:-$CACHE}" \
    AGENT_COMMS_MARKETPLACE_ROOT="$SOURCE" \
    AGENT_COMMS_CACHE_BASE="$FIXTURE/cache" \
    AGENT_COMMS_SHARE_ROOT="$SHARE" \
    AGENT_COMMS_PUBLIC_BIN="$PUBLIC_BIN" \
    AGENT_COMMS_CODEX_SKILL="$CODEX_SKILL" \
    "$@"
}

test_manifest_identity() {
  new_release_fixture
  bash "$RELEASE" manifest --root "$SOURCE"
  local manifest="$SOURCE/manifest.lock"
  assert_contains "$(cat "$manifest")" 'protocol 2'
  assert_contains "$(cat "$manifest")" 'release '
  assert_not_contains "$(cat "$manifest")" 'manifest.lock'
  local expected_files manifest_files digest
  expected_files="$(find "$SOURCE" -type f ! -name manifest.lock | wc -l | tr -d ' ')"
  manifest_files="$(grep -c '^0[0-9][0-9][0-9] [0-9a-f]' "$manifest")"
  assert_eq "$manifest_files" "$expected_files"
  assert_ok bash "$RELEASE" verify --root "$SOURCE"
  digest="$(bash "$RELEASE" digest --root "$SOURCE")"
  assert_eq "${#digest}" "64"

  printf '\nchanged\n' >> "$SOURCE/bin/agent-comms"
  assert_fail bash "$RELEASE" verify --root "$SOURCE"
  cp "$DIR/bin/agent-comms" "$SOURCE/bin/agent-comms"
  chmod 0644 "$SOURCE/bin/agent-comms"
  assert_fail bash "$RELEASE" verify --root "$SOURCE"
  rm -rf "$FIXTURE"
}

test_manifest_handles_regex_characters_in_root() {
  new_release_fixture
  mv "$SOURCE" "$FIXTURE/source[1]"
  SOURCE="$FIXTURE/source[1]"
  assert_ok bash "$RELEASE" manifest --root "$SOURCE"
  assert_ok bash "$RELEASE" verify --root "$SOURCE"
  rm -rf "$FIXTURE"
}

test_manifest_ignores_claude_runtime_metadata() {
  new_release_fixture
  mv "$SOURCE" "$FIXTURE/source[1]"
  SOURCE="$FIXTURE/source[1]"
  bash "$RELEASE" manifest --root "$SOURCE"
  mkdir -p "$SOURCE/.in_use"
  printf 'runtime-owned marker' > "$SOURCE/.in_use/1234"

  assert_ok bash "$RELEASE" verify --root "$SOURCE"
  assert_not_contains "$(cat "$SOURCE/manifest.lock")" '.in_use'
  printf '\nchanged\n' >> "$SOURCE/bin/agent-comms"
  assert_fail bash "$RELEASE" verify --root "$SOURCE"
  rm -rf "$FIXTURE"
}

test_global_doctor_detects_drift() {
  setup_installed_fixture
  local output
  output="$(run_installed bash "$CACHE/bin/agent-comms" doctor 2>&1)"
  assert_eq "$?" "0"
  assert_contains "$output" "release: $VERSION"
  assert_contains "$output" 'installation: consistent'

  SELECTED_PATH="$FIXTURE/cache/not-selected"
  output="$(run_installed bash "$CACHE/bin/agent-comms" doctor 2>&1)"
  assert_eq "$?" "1"
  assert_contains "$output" 'Claude selected path mismatch'
  unset SELECTED_PATH

  ln -s "$SHARE/current/bin/agent-comms" "$PUBLIC_BIN/claude-review"
  output="$(run_installed bash "$CACHE/bin/agent-comms" doctor 2>&1)"
  assert_eq "$?" "1"
  assert_contains "$output" 'stale public command'
  rm -rf "$FIXTURE"
}

test_atomic_install_and_rollback() {
  setup_installed_fixture
  local old="$FIXTURE/cache/old-release" output
  cp -R "$CACHE" "$old"
  rm "$SHARE/current"
  ln -s "$old" "$SHARE/current"
  ln -s "$SHARE/current/bin/agent-comms" "$PUBLIC_BIN/claude-review"

  output="$(run_installed bash "$SOURCE/bin/agent-comms" install 2>&1)"
  assert_eq "$?" "0"
  assert_eq "$(realpath "$SHARE/current")" "$(realpath "$CACHE")"
  assert_eq "$(realpath "$PUBLIC_BIN/agent-comms")" "$(realpath "$CACHE/bin/agent-comms")"
  assert_eq "$(realpath "$CODEX_SKILL")" "$(realpath "$CACHE/skills/agent-comms")"
  assert_fail test -e "$PUBLIC_BIN/claude-review"
  assert_contains "$output" 'installation: consistent'

  rm "$SHARE/current"
  ln -s "$old" "$SHARE/current"
  output="$(AGENT_COMMS_FAILPOINT=before-switch run_installed \
    bash "$SOURCE/bin/agent-comms" install 2>&1)"
  assert_eq "$?" "1"
  assert_eq "$(realpath "$SHARE/current")" "$(realpath "$old")"

  ln -s "$SHARE/current/bin/agent-comms" "$PUBLIC_BIN/claude-review"
  output="$(AGENT_COMMS_FAILPOINT=activate-current run_installed \
    bash "$SOURCE/bin/agent-comms" install 2>&1)"
  assert_eq "$?" "1"
  assert_eq "$(realpath "$SHARE/current")" "$(realpath "$old")"
  assert_ok test -L "$PUBLIC_BIN/claude-review"

  output="$(AGENT_COMMS_FAILPOINT=after-switch run_installed \
    bash "$SOURCE/bin/agent-comms" install 2>&1)"
  assert_eq "$?" "1"
  assert_eq "$(realpath "$SHARE/current")" "$(realpath "$old")"

  output="$(run_installed bash "$SOURCE/bin/agent-comms" update --check 2>&1)"
  assert_eq "$?" "0"
  assert_contains "$output" 'update available'
  assert_eq "$(realpath "$SHARE/current")" "$(realpath "$old")"
  rm -rf "$FIXTURE"
}

test_session_doctor_verifies_pinned_release() {
  setup_installed_fixture
  local comms="$FIXTURE/comms" digest output
  mkdir -p "$comms"
  digest="$(bash "$CACHE/bin/release.sh" digest --root "$CACHE")"
  run_installed bash "$CACHE/bin/agent-comms" init --channel valid --dir "$comms" --session valid \
    --driver codex --peer claude --release "$VERSION" --digest "$digest" \
    --protocol 2 --release-root "$CACHE"
  output="$(run_installed bash "$CACHE/bin/agent-comms" doctor \
    --channel valid --dir "$comms" 2>&1)"
  assert_eq "$?" "0"
  assert_contains "$output" 'channel: valid'

  output="$(run_installed bash "$CACHE/bin/agent-comms" init --channel rejected --dir "$comms" --session rejected \
    --driver codex --peer claude --release "$VERSION" --digest "$digest" \
    --protocol 2 --release-root "$FIXTURE/missing-release" 2>&1)"
  assert_eq "$?" "1"
  assert_contains "$output" 'explicit release root is missing'
  perl "$CACHE/bin/protocol.pl" init --file "$comms/missing.md" --session missing \
    --driver codex --peer claude --release "$VERSION" --digest "$digest" \
    --protocol 2 --release-root "$FIXTURE/missing-release"
  output="$(run_installed bash "$CACHE/bin/agent-comms" doctor \
    --channel missing --dir "$comms" 2>&1)"
  assert_eq "$?" "1"
  assert_contains "$output" 'pinned release is missing'
  assert_not_contains "$output" 'falling back'
  rm -rf "$FIXTURE"
}

test_init_pins_invoked_release_identity() {
  setup_installed_fixture
  local comms="$FIXTURE/comms" metadata digest
  mkdir -p "$comms"
  run_installed bash "$CACHE/bin/agent-comms" init --channel automatic --dir "$comms" \
    --session automatic --driver codex --peer claude
  metadata="$(perl "$CACHE/bin/protocol.pl" inspect --file "$comms/automatic.md")"
  digest="$(bash "$CACHE/bin/release.sh" digest --root "$CACHE")"
  assert_contains "$metadata" "release=$VERSION"
  assert_contains "$metadata" "digest=$digest"
  assert_contains "$metadata" 'protocol=2'
  assert_contains "$metadata" "release_root=$(realpath "$CACHE")"
  rm -rf "$FIXTURE"
}

test_marketplace_runtime_rejects_channel_init() {
  setup_installed_fixture
  local output
  output="$(run_installed bash "$SOURCE/bin/agent-comms" init \
    --channel mutable --dir "$FIXTURE/comms" --session mutable \
    --driver codex --peer claude 2>&1)"
  assert_eq "$?" "1"
  assert_contains "$output" 'channel commands require an immutable cache release'
  assert_fail test -e "$FIXTURE/comms/mutable.md"
  rm -rf "$FIXTURE"
}

test_active_channel_dispatches_to_pinned_release() {
  setup_installed_fixture
  local old="$FIXTURE/cache/1.2.0" comms="$FIXTURE/comms" metadata output
  cp -R "$CACHE" "$old"
  perl -pi -e 's/"version": "[^"]+"/"version": "1.2.0"/' \
    "$old/.claude-plugin/plugin.json"
  bash "$old/bin/release.sh" manifest --root "$old"
  mkdir -p "$comms"
  run_installed bash "$old/bin/agent-comms" init --channel active --dir "$comms" \
    --session active --driver codex --peer claude >/dev/null 2>&1
  printf 'task' > "$FIXTURE/task"

  output="$(AGENT_COMMS_CACHE_BASE="$FIXTURE/cache" AGENT_COMMS_DISPATCH_TRACE=1 \
    bash "$CACHE/bin/agent-comms" send --channel active --dir "$comms" \
    --from codex --generation 1 --body-file "$FIXTURE/task" 2>&1)"
  assert_eq "$?" "0"
  assert_contains "$output" "dispatching pinned release: $(realpath "$old")"
  metadata="$(perl "$CACHE/bin/protocol.pl" inspect --file "$comms/active.md")"
  assert_contains "$metadata" "release_root=$(realpath "$old")"
  printf 'resume on the pinned release' > "$FIXTURE/handoff"
  output="$(AGENT_COMMS_CACHE_BASE="$FIXTURE/cache" AGENT_COMMS_DISPATCH_TRACE=1 \
    bash "$CACHE/bin/agent-comms" resume \
    --channel active --dir "$comms" --from codex --generation 1 \
    --replace claude --body-file "$FIXTURE/handoff" 2>&1)"
  assert_eq "$?" "0"
  assert_contains "$output" "dispatching pinned release: $(realpath "$old")"
  assert_contains "$(cat "$comms/active.md")" 'tag=replace=claude.2'

  mv "$old" "$FIXTURE/missing-old"
  output="$(AGENT_COMMS_CACHE_BASE="$FIXTURE/cache" \
    bash "$CACHE/bin/agent-comms" transcript --channel active --dir "$comms" 2>&1)"
  assert_eq "$?" "1"
  assert_contains "$output" 'pinned release is missing'
  assert_not_contains "$output" 'falling forward'
  rm -rf "$FIXTURE"
}

test_dispatch_ignores_cache_base_override() {
  setup_installed_fixture
  local attacker_base="$FIXTURE/attacker-cache"
  local attacker="$attacker_base/1.2.0"
  local comms="$FIXTURE/comms"
  local output
  mkdir -p "$attacker_base" "$comms"
  cp -R "$CACHE" "$attacker"
  perl -pi -e 's/"version": "[^"]+"/"version": "1.2.0"/' \
    "$attacker/.claude-plugin/plugin.json"
  bash "$attacker/bin/release.sh" manifest --root "$attacker"
  AGENT_COMMS_CACHE_BASE="$attacker_base" bash "$attacker/bin/agent-comms" init \
    --channel hostile --dir "$comms" --session hostile \
    --driver codex --peer claude >/dev/null 2>&1
  printf 'attacker dispatched' > "$FIXTURE/task"

  output="$(AGENT_COMMS_CACHE_BASE="$attacker_base" AGENT_COMMS_DISPATCH_TRACE=1 \
    bash "$CACHE/bin/agent-comms" send --channel hostile --dir "$comms" \
    --from codex --generation 1 --body-file "$FIXTURE/task" 2>&1)"
  assert_eq "$?" "1"
  assert_contains "$output" 'pinned release is outside the trusted cache'
  assert_not_contains "$(cat "$comms/hostile.md")" 'attacker dispatched'
  rm -rf "$FIXTURE"
}

test_v2_release_contract_is_consistent() {
  local plugin skill manifest maintenance launcher cli library
  plugin="$(cat "$DIR/.claude-plugin/plugin.json")"
  skill="$(cat "$DIR/skills/agent-comms/SKILL.md")"
  manifest="$(cat "$DIR/manifest.lock")"
  maintenance="$(cat "$DIR/MAINTENANCE.md")"
  launcher="$(cat "$DIR/bin/launch.sh")"
  cli="$(cat "$DIR/bin/agent-comms")"
  library="$(cat "$DIR/bin/lib.sh")"
  assert_contains "$plugin" '"version": "2.0.1"'
  assert_contains "$manifest" 'release 2.0.1'
  assert_contains "$launcher" 'CLIENT_RELEASE="2.0.1"'
  assert_contains "$skill" '--client-release 2.0.1'
  assert_contains "$maintenance" 'agent-comms--v2.0.1'
  assert_not_contains "$skill" 'claude-review'
  assert_not_contains "$skill" 'codex-review'
  assert_not_contains "$skill" 'install-codex'
  assert_not_contains "$skill" 'agent-comms ack'
  assert_not_contains "$cli" 'cmd_ack'
  assert_not_contains "$cli" 'install-codex'
  assert_not_contains "$cli" 'v=1'
  assert_not_contains "$library" 'make_frame'
  assert_not_contains "$library" 'parse_frames'
}

if [ $# -gt 0 ]; then
  "$1"
else
  test_manifest_identity
  test_manifest_handles_regex_characters_in_root
  test_manifest_ignores_claude_runtime_metadata
  test_global_doctor_detects_drift
  test_atomic_install_and_rollback
  test_session_doctor_verifies_pinned_release
  test_init_pins_invoked_release_identity
  test_marketplace_runtime_rejects_channel_init
  test_active_channel_dispatches_to_pinned_release
  test_dispatch_ignores_cache_base_override
  test_v2_release_contract_is_consistent
fi

finish_tests "RELEASE"
