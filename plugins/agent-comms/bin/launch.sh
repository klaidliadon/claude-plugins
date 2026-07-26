#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
source "$HERE/lib.sh"

CLIENT_RELEASE="2.0.0"

fail_launch() {
  echo "agent-comms launch: $*" >&2
  exit 64
}

metadata_value() {
  local key="$1"
  awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$METADATA_FILE"
}

render_command() {
  local variable="$1"
  shift
  local rendered
  printf -v rendered '%q ' "$@"
  printf -v "$variable" '%s' "${rendered% }"
}

append_lifecycle() {
  local tag="$1" body="$2" body_file
  body_file="$(mktemp "${TMPDIR:-/tmp}/agent-comms-launch-status.XXXXXX")"
  printf '%s' "$body" > "$body_file"
  perl "$HERE/protocol.pl" append \
    --file "$CHANNEL_FILE" \
    --sender "$ME" \
    --generation "$GENERATION" \
    --kind status \
    --state none \
    --tag "$tag" \
    --body-file "$body_file"
  rm -f "$body_file"
}

heartbeat_loop() {
  local child_pid="$1" after="$2" interval="$3"
  local last_size quiet_since last_heartbeat current_size now elapsed state
  last_size="$(LC_ALL=C wc -c < "$CHANNEL_FILE" | tr -d ' ')"
  quiet_since="$(date +%s)"
  last_heartbeat="$quiet_since"
  while kill -0 "$child_pid" 2>/dev/null; do
    sleep 1
    kill -0 "$child_pid" 2>/dev/null || break
    current_size="$(LC_ALL=C wc -c < "$CHANNEL_FILE" | tr -d ' ')"
    now="$(date +%s)"
    if [ "$current_size" != "$last_size" ]; then
      last_size="$current_size"
      quiet_since="$now"
      continue
    fi
    elapsed=$((now - quiet_since))
    if [ "$elapsed" -lt "$after" ]; then
      continue
    fi
    if [ $((now - last_heartbeat)) -lt "$interval" ]; then
      continue
    fi
    state="$(perl "$HERE/protocol.pl" inspect --file "$CHANNEL_FILE")" || break
    case "$state" in
      *$'terminal=0\n'*$'expected='"$ME"$'\n'*) ;;
      *) continue;;
    esac
    append_lifecycle alive "elapsed=${elapsed}s"
    last_size="$(LC_ALL=C wc -c < "$CHANNEL_FILE" | tr -d ' ')"
    last_heartbeat="$now"
  done
}

RUNTIME="${1:-}"
[ -n "$RUNTIME" ] || fail_launch "missing runtime"
shift
case "$RUNTIME" in claude|codex) ;; *) fail_launch "runtime must be claude or codex";; esac

ROLE=""
PEER=""
CHANNEL=""
GENERATION="1"
PROMPT_FILE=""
DECLARED_RELEASE=""
RUNTIME_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2;;
    --peer) PEER="${2:-}"; shift 2;;
    --channel) CHANNEL="${2:-}"; shift 2;;
    --generation) GENERATION="${2:-}"; shift 2;;
    --prompt-file) PROMPT_FILE="${2:-}"; shift 2;;
    --client-release) DECLARED_RELEASE="${2:-}"; shift 2;;
    --) shift; RUNTIME_ARGS=("$@"); break;;
    *) fail_launch "unknown argument: $1";;
  esac
done

case "$ROLE" in driver|reviewer) ;; *) fail_launch "--role must be driver or reviewer";; esac
valid_name "$PEER" || fail_launch "bad --peer"
valid_name "$CHANNEL" || fail_launch "bad --channel"
case "$GENERATION" in ''|*[!0-9]*) fail_launch "bad --generation";; esac
[ -f "$PROMPT_FILE" ] || fail_launch "prompt file not found: $PROMPT_FILE"
[ "$DECLARED_RELEASE" = "$CLIENT_RELEASE" ] ||
  fail_launch "client release mismatch: launcher=$CLIENT_RELEASE caller=${DECLARED_RELEASE:-missing}"

ME="$RUNTIME"
COMMS_DIRECTORY="$(comms_dir)"
mkdir -p "$COMMS_DIRECTORY/.cursors/$CHANNEL"
CHANNEL_FILE="$(channel_file "$CHANNEL")"
assert_confined "$CHANNEL_FILE"
[ -f "$CHANNEL_FILE" ] || fail_launch "channel is not initialized: $CHANNEL_FILE"

METADATA_FILE="$(mktemp "${TMPDIR:-/tmp}/agent-comms-launch-metadata.XXXXXX")"
BOOTSTRAP_FILE="$(mktemp "${TMPDIR:-/tmp}/agent-comms-launch-prompt.XXXXXX")"
CONTROL_CURSOR="$(mktemp "${TMPDIR:-/tmp}/agent-comms-launch-control.XXXXXX")"
RESUME_PACKET_FILE=""
CHILD_PID=""
HEARTBEAT_PID=""
cleanup_launch() {
  rm -f "$METADATA_FILE" "$BOOTSTRAP_FILE" "$CONTROL_CURSOR"
  if [ -n "$RESUME_PACKET_FILE" ]; then
    rm -f "$RESUME_PACKET_FILE"
  fi
}
handle_signal() {
  local signal="$1" status="$2"
  trap - INT TERM
  if [ -n "$CHILD_PID" ]; then
    kill -"$signal" "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  if [ -n "$HEARTBEAT_PID" ]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
  fi
  append_lifecycle "signal=$signal" "runtime=$RUNTIME role=$ROLE generation=$GENERATION"
  exit "$status"
}
trap cleanup_launch EXIT
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM
perl "$HERE/protocol.pl" inspect --file "$CHANNEL_FILE" > "$METADATA_FILE"

SESSION_DRIVER="$(metadata_value driver)"
SESSION_PEER="$(metadata_value peer)"
SESSION_RELEASE="$(metadata_value release)"
SESSION_DIGEST="$(metadata_value digest)"
SESSION_PROTOCOL="$(metadata_value protocol)"
RELEASE_ROOT="$(metadata_value release_root)"
SESSION_GENERATION="$(metadata_value "generation.$ME")"
SESSION_HEARTBEAT_AFTER="$(metadata_value heartbeat_after)"
SESSION_HEARTBEAT_INTERVAL="$(metadata_value heartbeat_interval)"
[ "$SESSION_RELEASE" = "$CLIENT_RELEASE" ] ||
  fail_launch "session release mismatch: session=$SESSION_RELEASE launcher=$CLIENT_RELEASE"
[ "$SESSION_PROTOCOL" = "2" ] ||
  fail_launch "session protocol mismatch: $SESSION_PROTOCOL"
[ "$SESSION_GENERATION" = "$GENERATION" ] ||
  fail_launch "generation mismatch: session=$SESSION_GENERATION caller=$GENERATION"
if [ "$ROLE" = "driver" ]; then
  [ "$SESSION_DRIVER" = "$ME" ] && [ "$SESSION_PEER" = "$PEER" ] ||
    fail_launch "driver/peer do not match the session"
else
  [ "$SESSION_PEER" = "$ME" ] && [ "$SESSION_DRIVER" = "$PEER" ] ||
    fail_launch "reviewer/peer do not match the session"
fi
[ -x "$RELEASE_ROOT/bin/agent-comms" ] ||
  fail_launch "pinned release CLI is missing: $RELEASE_ROOT/bin/agent-comms"
RELEASE_ROOT="$(realpath "$RELEASE_ROOT")"
RUNTIME_ROOT="$(cd "$HERE/.." && pwd)"
[ "$RUNTIME_ROOT" = "$RELEASE_ROOT" ] ||
  fail_launch "launcher is not from pinned release: $RUNTIME_ROOT != $RELEASE_ROOT"
bash "$RELEASE_ROOT/bin/release.sh" verify --root "$RELEASE_ROOT" ||
  fail_launch "pinned release manifest is invalid"
ACTUAL_DIGEST="$(file_sha256 "$RELEASE_ROOT/manifest.lock")"
[ "$ACTUAL_DIGEST" = "$SESSION_DIGEST" ] ||
  fail_launch "session digest mismatch: $SESSION_DIGEST != $ACTUAL_DIGEST"
[ "$(plugin_version "$RELEASE_ROOT")" = "$SESSION_RELEASE" ] ||
  fail_launch "session version does not match pinned release"
if [ "$GENERATION" -eq 1 ]; then
  bash "$RELEASE_ROOT/bin/release.sh" doctor-locked --quiet ||
    fail_launch "global installation drift detected"
fi

if [ "$RUNTIME" = "claude" ]; then
  ADAPTER_HELP="$(claude --help 2>&1)" || fail_launch "claude --help failed"
  case "$ADAPTER_HELP" in *-p*) ;; *) fail_launch "claude adapter is missing -p";; esac
  case "$ADAPTER_HELP" in *--permission-mode*) ;; *) fail_launch "claude adapter is missing --permission-mode";; esac
  case "$ADAPTER_HELP" in *--add-dir*) ;; *) fail_launch "claude adapter is missing --add-dir";; esac
else
  ADAPTER_HELP="$(codex exec --help 2>&1)" || fail_launch "codex exec --help failed"
  case "$ADAPTER_HELP" in *--dangerously-bypass-approvals-and-sandbox*) ;;
    *) fail_launch "codex adapter is missing --dangerously-bypass-approvals-and-sandbox";;
  esac
  case "$ADAPTER_HELP" in *--skip-git-repo-check*) ;;
    *) fail_launch "codex adapter is missing --skip-git-repo-check";;
  esac
fi

if [ "$GENERATION" -gt 1 ]; then
  RESUME_PACKET_FILE="$(mktemp "${TMPDIR:-/tmp}/agent-comms-launch-resume.XXXXXX")"
  if perl "$HERE/protocol.pl" resume-packet \
      --file "$CHANNEL_FILE" --role "$ME" --generation "$GENERATION" \
      > "$RESUME_PACKET_FILE"; then
    :
  else
    resume_status=$?
    append_lifecycle resume-invalid "runtime=$RUNTIME role=$ROLE generation=$GENERATION"
    exit "$resume_status"
  fi
fi

if [ "$ROLE" = "reviewer" ]; then
  READY_BODY="$(mktemp "${TMPDIR:-/tmp}/agent-comms-launch-ready.XXXXXX")"
  printf 'session=%s role=%s generation=%s release=%s' \
    "$(metadata_value session)" "$ME" "$GENERATION" "$SESSION_RELEASE" > "$READY_BODY"
  perl "$HERE/protocol.pl" append \
    --file "$CHANNEL_FILE" \
    --sender "$ME" \
    --generation "$GENERATION" \
    --kind control \
    --state none \
    --tag "hello-ack=$ME.$GENERATION" \
    --body-file "$READY_BODY"
  rm -f "$READY_BODY"
else
  PEER_GENERATION="$(metadata_value "generation.$PEER")"
  if perl "$HERE/protocol.pl" wait-control \
      --file "$CHANNEL_FILE" \
      --cursor "$CONTROL_CURSOR" \
      --me "$ME" \
      --tag "hello-ack=$PEER.$PEER_GENERATION" \
      --timeout "${AGENT_COMMS_STARTUP_TIMEOUT:-30}" >/dev/null; then
    :
  else
    wait_status=$?
    append_lifecycle startup-timeout "peer=$PEER generation=$PEER_GENERATION"
    exit "$wait_status"
  fi
fi

PINNED_AC="$RELEASE_ROOT/bin/agent-comms"
render_command SEND_COMMAND "$PINNED_AC" send --channel "$CHANNEL" --dir "$COMMS_DIRECTORY" \
  --from "$ME" --generation "$GENERATION"
render_command RECV_COMMAND "$PINNED_AC" recv --channel "$CHANNEL" --dir "$COMMS_DIRECTORY" \
  --me "$ME" --generation "$GENERATION"
{
  cat "$PROMPT_FILE"
  printf '\n\n## Agent-comms v2 transport\n\n'
  printf 'Session: %s. Runtime: %s. Role: %s. Peer: %s. Generation: %s.\n' \
    "$(metadata_value session)" "$RUNTIME" "$ROLE" "$PEER" "$GENERATION"
  printf 'Send a progress fragment without yielding:\n\n    %s --continue --body-file <file>\n\n' "$SEND_COMMAND"
  printf 'Send the final fragment and yield (default):\n\n    %s --body-file <file>\n\n' "$SEND_COMMAND"
  printf 'After yielding, receive one complete peer turn:\n\n    %s\n\n' "$RECV_COMMAND"
  printf 'Do not send hidden reasoning. Keep progress fragments short and useful.\n'
  if [ "$ROLE" = "reviewer" ] && [ "$GENERATION" -eq 1 ]; then
    printf 'Your first transport action is receive. Do not inspect or start the task before it arrives.\n'
  elif [ "$ROLE" = "reviewer" ]; then
    printf 'Resume the open turn from the packet below; do not receive first.\n'
  else
    printf 'You own the first turn. Send the task before receiving.\n'
  fi
  if [ "$GENERATION" -gt 1 ]; then
    printf '\n## Resume packet\n\n'
    cat "$RESUME_PACKET_FILE"
  fi
} > "$BOOTSTRAP_FILE"

WORK_ROOT="${COMMS_ROOT_FLAG:-$PWD}"
append_lifecycle started "runtime=$RUNTIME role=$ROLE generation=$GENERATION"
HEARTBEAT_AFTER="$SESSION_HEARTBEAT_AFTER"
HEARTBEAT_INTERVAL="$SESSION_HEARTBEAT_INTERVAL"
case "$HEARTBEAT_AFTER" in ''|*[!0-9]*) fail_launch "bad heartbeat delay";; esac
case "$HEARTBEAT_INTERVAL" in ''|*[!0-9]*) fail_launch "bad heartbeat interval";; esac
[ "$HEARTBEAT_AFTER" -gt 0 ] && [ "$HEARTBEAT_INTERVAL" -gt 0 ] ||
  fail_launch "heartbeat values must be positive"
if [ "$RUNTIME" = "claude" ]; then
  if [ "${#RUNTIME_ARGS[@]}" -gt 0 ]; then
    claude -p --permission-mode bypassPermissions --add-dir "$WORK_ROOT" \
      "${RUNTIME_ARGS[@]}" < "$BOOTSTRAP_FILE" &
  else
    claude -p --permission-mode bypassPermissions --add-dir "$WORK_ROOT" \
      < "$BOOTSTRAP_FILE" &
  fi
else
  if [ "${#RUNTIME_ARGS[@]}" -gt 0 ]; then
    codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
      "${RUNTIME_ARGS[@]}" < "$BOOTSTRAP_FILE" &
  else
    codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
      < "$BOOTSTRAP_FILE" &
  fi
fi
CHILD_PID=$!
heartbeat_loop "$CHILD_PID" "$HEARTBEAT_AFTER" "$HEARTBEAT_INTERVAL" &
HEARTBEAT_PID=$!
child_status=0
wait "$CHILD_PID" || child_status=$?
kill "$HEARTBEAT_PID" 2>/dev/null || true
wait "$HEARTBEAT_PID" 2>/dev/null || true
append_lifecycle "exit=$child_status" "runtime=$RUNTIME role=$ROLE generation=$GENERATION"
exit "$child_status"
