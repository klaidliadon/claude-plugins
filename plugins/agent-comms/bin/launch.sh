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

prepare_private_directory() {
  local directory="$1" physical_root="$2" physical_directory
  [ ! -L "$directory" ] || fail_launch "activity path is a symlink: $directory"
  if [ ! -e "$directory" ]; then
    (umask 077; mkdir "$directory") ||
      fail_launch "cannot create activity directory: $directory"
  fi
  [ -d "$directory" ] && [ ! -L "$directory" ] ||
    fail_launch "activity path is not a directory: $directory"
  physical_directory="$(realpath "$directory")"
  case "$physical_directory/" in
    "$physical_root/"*) ;;
    *) fail_launch "activity path escapes comms directory: $directory";;
  esac
  chmod 700 "$directory" ||
    fail_launch "cannot secure activity directory: $directory"
}

prepare_activity() {
  local comms_physical
  comms_physical="$(realpath "$COMMS_DIRECTORY")"
  ACTIVITY_ROOT="$comms_physical/.activity"
  ACTIVITY_DIRECTORY="$ACTIVITY_ROOT/$CHANNEL"
  ACTIVITY_FILE="$ACTIVITY_DIRECTORY/$ME.$GENERATION.log"
  prepare_private_directory "$ACTIVITY_ROOT" "$comms_physical"
  prepare_private_directory "$ACTIVITY_DIRECTORY" "$comms_physical"
  if [ -e "$ACTIVITY_FILE" ] || [ -L "$ACTIVITY_FILE" ]; then
    fail_launch "activity file already exists: $ACTIVITY_FILE"
  fi
  (umask 077; set -o noclobber; : > "$ACTIVITY_FILE") ||
    fail_launch "cannot create activity file: $ACTIVITY_FILE"
  chmod 600 "$ACTIVITY_FILE" ||
    fail_launch "cannot secure activity file: $ACTIVITY_FILE"
  ACTIVITY_SPOOL="$(mktemp "$ACTIVITY_DIRECTORY/.spool.$ME.$GENERATION.XXXXXX")" ||
    fail_launch "cannot create activity spool"
  chmod 600 "$ACTIVITY_SPOOL" ||
    fail_launch "cannot secure activity spool"
  exec 8>>"$ACTIVITY_SPOOL"
  exec 9<"$ACTIVITY_SPOOL"
  ACTIVITY_WRITE_FD=8
  ACTIVITY_META_FD=9
  rm -f "$ACTIVITY_SPOOL"
  ACTIVITY_SPOOL=""
}

activity_size() {
  perl -e '
    open my $handle, "<&=$ARGV[0]" or exit 1;
    my @metadata = stat($handle);
    @metadata or exit 1;
    print $metadata[7];
  ' "$ACTIVITY_META_FD"
}

append_activity() {
  local epoch="$1" sequence="$2"
  perl -MFcntl=:flock -MPOSIX=strftime -e '
    my ($path, $epoch, $sequence) = @ARGV;
    my @path_metadata = lstat($path);
    @path_metadata or exit 1;
    -l _ and exit 1;
    open my $handle, ">>", $path or exit 1;
    flock($handle, LOCK_EX) or exit 1;
    my @handle_metadata = stat($handle);
    @handle_metadata or exit 1;
    $path_metadata[0] == $handle_metadata[0] or exit 1;
    $path_metadata[1] == $handle_metadata[1] or exit 1;
    my $timestamp = strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($epoch));
    print {$handle} "ts=$timestamp seq=$sequence\n" or exit 1;
    close $handle or exit 1;
  ' "$ACTIVITY_FILE" "$epoch" "$sequence"
}

heartbeat_loop() {
  local child_pid="$1" after="$2" interval="$3"
  local last_size quiet_since last_heartbeat current_size now elapsed state
  local activity_enabled activity_seq activity_last_size activity_current_size
  local activity_last_at activity_last_sample activity_next_sequence
  last_size="$(LC_ALL=C wc -c < "$CHANNEL_FILE" | tr -d ' ')"
  quiet_since="$(date +%s)"
  last_heartbeat="$quiet_since"
  activity_enabled=1
  activity_seq=0
  activity_last_size=0
  activity_last_at="$quiet_since"
  activity_last_sample="$quiet_since"
  while kill -0 "$child_pid" 2>/dev/null; do
    sleep 1
    kill -0 "$child_pid" 2>/dev/null || break
    now="$(date +%s)"
    if [ "$activity_enabled" -eq 1 ] &&
        [ $((now - activity_last_sample)) -ge "$ACTIVITY_SAMPLE_INTERVAL" ]; then
      if activity_current_size="$(activity_size)" &&
          case "$activity_current_size" in ''|*[!0-9]*) false;; *) true;; esac; then
        if [ "$activity_current_size" -gt "$activity_last_size" ]; then
          activity_next_sequence=$((activity_seq + 1))
          if append_activity "$now" "$activity_next_sequence"; then
            activity_seq="$activity_next_sequence"
            activity_last_at="$now"
          else
            append_lifecycle "activity-disabled=write" \
              "runtime=$RUNTIME role=$ROLE generation=$GENERATION" || true
            activity_enabled=0
          fi
        fi
        activity_last_size="$activity_current_size"
      else
        append_lifecycle "activity-disabled=sample" \
          "runtime=$RUNTIME role=$ROLE generation=$GENERATION" || true
        activity_enabled=0
      fi
      activity_last_sample="$now"
    fi
    current_size="$(LC_ALL=C wc -c < "$CHANNEL_FILE" | tr -d ' ')"
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
    append_lifecycle alive \
      "elapsed=${elapsed}s activity_seq=$activity_seq activity_idle=$((now - activity_last_at))s"
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
if [ "${#RUNTIME_ARGS[@]}" -gt 0 ]; then
  for argument in "${RUNTIME_ARGS[@]}"; do
    case "$argument" in
      --output-format|--output-format=*|--input-format|--input-format=*|\
      --include-partial-messages|--include-partial-messages=*|--json)
        fail_launch "runtime output flag is owned by agent-comms: $argument"
        ;;
    esac
  done
fi

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
ACTIVITY_ROOT=""
ACTIVITY_DIRECTORY=""
ACTIVITY_FILE=""
ACTIVITY_SPOOL=""
ACTIVITY_WRITE_FD=""
ACTIVITY_META_FD=""
ACTIVITY_SAMPLE_INTERVAL=30
cleanup_launch() {
  rm -f "$METADATA_FILE" "$BOOTSTRAP_FILE" "$CONTROL_CURSOR"
  if [ -n "$RESUME_PACKET_FILE" ]; then
    rm -f "$RESUME_PACKET_FILE"
  fi
  if [ -n "$ACTIVITY_SPOOL" ]; then
    rm -f "$ACTIVITY_SPOOL"
  fi
  if [ -n "$ACTIVITY_WRITE_FD" ]; then
    exec 8>&-
  fi
  if [ -n "$ACTIVITY_META_FD" ]; then
    exec 9<&-
  fi
}
stop_heartbeat() {
  local attempts=0
  [ -n "$HEARTBEAT_PID" ] || return
  kill "$HEARTBEAT_PID" 2>/dev/null || true
  while kill -0 "$HEARTBEAT_PID" 2>/dev/null && [ "$attempts" -lt 20 ]; do
    sleep 0.1
    attempts=$((attempts + 1))
  done
  if kill -0 "$HEARTBEAT_PID" 2>/dev/null; then
    kill -KILL "$HEARTBEAT_PID" 2>/dev/null || true
  fi
  wait "$HEARTBEAT_PID" 2>/dev/null || true
  HEARTBEAT_PID=""
}
handle_signal() {
  local signal="$1" status="$2"
  trap - INT TERM
  if [ -n "$CHILD_PID" ]; then
    kill -"$signal" "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  stop_heartbeat
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
  case "$ADAPTER_HELP" in *--output-format*) ;;
    *) fail_launch "claude adapter is missing --output-format";;
  esac
  case "$ADAPTER_HELP" in *--verbose*) ;; *) fail_launch "claude adapter is missing --verbose";; esac
else
  ADAPTER_HELP="$(codex exec --help 2>&1)" || fail_launch "codex exec --help failed"
  case "$ADAPTER_HELP" in *--dangerously-bypass-approvals-and-sandbox*) ;;
    *) fail_launch "codex adapter is missing --dangerously-bypass-approvals-and-sandbox";;
  esac
  case "$ADAPTER_HELP" in *--skip-git-repo-check*) ;;
    *) fail_launch "codex adapter is missing --skip-git-repo-check";;
  esac
  case "$ADAPTER_HELP" in *--json*) ;; *) fail_launch "codex adapter is missing --json";; esac
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

prepare_activity

if [ "$ROLE" = "reviewer" ]; then
  READY_BODY="$(mktemp "${TMPDIR:-/tmp}/agent-comms-launch-ready.XXXXXX")"
  printf 'session=%s role=%s generation=%s release=%s\nactivity_ref=%s' \
    "$(metadata_value session)" "$ME" "$GENERATION" "$SESSION_RELEASE" \
    "$ACTIVITY_FILE" > "$READY_BODY"
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
  printf 'Run receive synchronously in the foreground immediately after every yielding send.\n'
  printf 'Never background receive or return a final answer while the channel remains open.\n'
  printf 'Send semantic progress after a major phase or 2 minutes, whichever comes first.\n'
  printf 'Never exceed 5 minutes without semantic progress; report the phase, evidence, and next step or blocker.\n'
  printf 'Keep progress bodies at or below 256 bytes to control token and tail volume.\n'
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
append_lifecycle started \
  "runtime=$RUNTIME role=$ROLE generation=$GENERATION activity_ref=$ACTIVITY_FILE"
HEARTBEAT_AFTER="$SESSION_HEARTBEAT_AFTER"
HEARTBEAT_INTERVAL="$SESSION_HEARTBEAT_INTERVAL"
case "$HEARTBEAT_AFTER" in ''|*[!0-9]*) fail_launch "bad heartbeat delay";; esac
case "$HEARTBEAT_INTERVAL" in ''|*[!0-9]*) fail_launch "bad heartbeat interval";; esac
[ "$HEARTBEAT_AFTER" -gt 0 ] && [ "$HEARTBEAT_INTERVAL" -gt 0 ] ||
  fail_launch "heartbeat values must be positive"
if [ "$RUNTIME" = "claude" ]; then
  if [ "${#RUNTIME_ARGS[@]}" -gt 0 ]; then
    claude -p --permission-mode bypassPermissions \
      --add-dir "$WORK_ROOT" --add-dir "$COMMS_DIRECTORY" \
      --output-format stream-json --verbose \
      "${RUNTIME_ARGS[@]}" < "$BOOTSTRAP_FILE" >&8 &
  else
    claude -p --permission-mode bypassPermissions \
      --add-dir "$WORK_ROOT" --add-dir "$COMMS_DIRECTORY" \
      --output-format stream-json --verbose \
      < "$BOOTSTRAP_FILE" >&8 &
  fi
else
  if [ "${#RUNTIME_ARGS[@]}" -gt 0 ]; then
    codex exec --dangerously-bypass-approvals-and-sandbox \
      --skip-git-repo-check --json \
      "${RUNTIME_ARGS[@]}" < "$BOOTSTRAP_FILE" >&8 &
  else
    codex exec --dangerously-bypass-approvals-and-sandbox \
      --skip-git-repo-check --json \
      < "$BOOTSTRAP_FILE" >&8 &
  fi
fi
CHILD_PID=$!
heartbeat_loop "$CHILD_PID" "$HEARTBEAT_AFTER" "$HEARTBEAT_INTERVAL" &
HEARTBEAT_PID=$!
child_status=0
wait "$CHILD_PID" || child_status=$?
stop_heartbeat
append_lifecycle "exit=$child_status" "runtime=$RUNTIME role=$ROLE generation=$GENERATION"
exit "$child_status"
