#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
source "$HERE/lib.sh"

CLIENT_RELEASE="2.0.4"

fail_launch() {
  echo "agent-comms launch: $*" >&2
  exit 64
}

metadata_value() {
  local key="$1"
  awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$METADATA_FILE"
}

state_value() {
  local state="$1" key="$2"
  awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' <<< "$state"
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

activity_sample() {
  perl -MJSON::PP -MFcntl=SEEK_CUR -e '
    open my $handle, "<&=$ARGV[0]" or exit 1;
    my $data = "";
    while (1) {
      my $read = sysread($handle, my $chunk, 65536);
      defined $read or exit 1;
      last unless $read;
      $data .= $chunk;
    }
    exit 0 unless length $data;
    my $last_newline = rindex($data, "\n");
    if ($last_newline < 0) {
      sysseek($handle, -length($data), SEEK_CUR) or exit 1;
      exit 0;
    }
    my $trailing = length($data) - $last_newline - 1;
    sysseek($handle, -$trailing, SEEK_CUR) or exit 1 if $trailing;
    $data = substr($data, 0, $last_newline + 1);

    my %allowed_type = map { $_ => 1 } qw(
      system assistant user result stream_event
      item.started item.updated item.completed
      turn.started turn.completed thread.started error
    );
    my %allowed_block = map { $_ => 1 } qw(
      text tool_use tool_result thinking reasoning
      command_execution agent_message mcp_tool_call mcp_tool_result
      message_start message_delta message_stop
      content_block_start content_block_delta content_block_stop
    );
    my (%seen_type, %seen_block, @types, @blocks);
    my $add = sub {
      my ($value, $allowed, $seen, $values) = @_;
      $value = "other" unless defined $value && !ref($value) && $allowed->{$value};
      return if $seen->{$value}++;
      push @$values, $value;
    };
    my $events = 0;
    for my $line (split /\n/, $data) {
      next unless length $line;
      $events++;
      my $object = eval { decode_json($line) };
      if (!$object || ref($object) ne "HASH") {
        $add->("other", \%allowed_type, \%seen_type, \@types);
        next;
      }
      $add->($object->{type}, \%allowed_type, \%seen_type, \@types);
      if (ref($object->{message}) eq "HASH" &&
          ref($object->{message}{content}) eq "ARRAY") {
        for my $block (@{$object->{message}{content}}) {
          next unless ref($block) eq "HASH";
          $add->($block->{type}, \%allowed_block, \%seen_block, \@blocks);
        }
      }
      if (ref($object->{event}) eq "HASH") {
        $add->($object->{event}{type}, \%allowed_block, \%seen_block, \@blocks);
        if (ref($object->{event}{content_block}) eq "HASH") {
          $add->($object->{event}{content_block}{type},
            \%allowed_block, \%seen_block, \@blocks);
        }
      }
      if (ref($object->{content_block}) eq "HASH") {
        $add->($object->{content_block}{type}, \%allowed_block, \%seen_block, \@blocks);
      }
      if (ref($object->{item}) eq "HASH") {
        $add->($object->{item}{type}, \%allowed_block, \%seen_block, \@blocks);
      }
    }
    print "events=$events types=" . join(",", @types) .
      " blocks=" . (@blocks ? join(",", @blocks) : "-");
  ' "$ACTIVITY_META_FD"
}

append_activity() {
  local epoch="$1" sequence="$2" sample="$3"
  perl -MFcntl=:flock -MPOSIX=strftime -e '
    my ($path, $epoch, $sequence, $sample) = @ARGV;
    $sample =~ /\Aevents=\d+ types=[A-Za-z0-9.,_-]+ blocks=[A-Za-z0-9.,_-]+\z/
      or exit 1;
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
    print {$handle} "ts=$timestamp seq=$sequence $sample\n" or exit 1;
    close $handle or exit 1;
  ' "$ACTIVITY_FILE" "$epoch" "$sequence" "$sample"
}

terminate_runtime() {
  local child_pid="$1" attempts=0
  kill -TERM "$child_pid" 2>/dev/null || return
  while kill -0 "$child_pid" 2>/dev/null && [ "$attempts" -lt 20 ]; do
    sleep 0.1
    attempts=$((attempts + 1))
  done
  if kill -0 "$child_pid" 2>/dev/null; then
    kill -KILL "$child_pid" 2>/dev/null || true
  fi
}

fail_supervision() {
  local child_pid="$1" status="$2" tag="$3" body="$4"
  printf '%s\n' "$status" > "$SUPERVISOR_STATE_FILE" || true
  append_lifecycle "$tag" "$body" || true
  terminate_runtime "$child_pid"
}

semantic_watchdog_loop() {
  local child_pid="$1" timeout="$2" first_frame_timeout="$3"
  local current_size expected last_message_seq message_seq now observed_size
  local owns_floor progress_since state deadline sent_first terminal
  current_size="-1"
  last_message_seq=""
  owns_floor=0
  sent_first=0
  progress_since="$(date +%s)"
  while kill -0 "$child_pid" 2>/dev/null; do
    now="$(date +%s)"
    observed_size="$(LC_ALL=C wc -c < "$CHANNEL_FILE" | tr -d ' ')"
    if [ "$observed_size" != "$current_size" ]; then
      if ! state="$(perl "$HERE/protocol.pl" inspect --file "$CHANNEL_FILE")"; then
        fail_supervision "$child_pid" 70 semantic-supervision-failed \
          "runtime=$RUNTIME role=$ROLE generation=$GENERATION"
        return
      fi
      expected="$(state_value "$state" expected)"
      message_seq="$(state_value "$state" "message_seq.$ME")"
      terminal="$(state_value "$state" terminal)"
      if [ "$terminal" = "1" ]; then
        printf '0\n' > "$SUPERVISOR_STATE_FILE" || true
        terminate_runtime "$child_pid"
        return
      fi
      case "$message_seq" in ''|0) ;; *) sent_first=1;; esac
      if [ "$expected" = "$ME" ]; then
        if [ "$owns_floor" -eq 0 ] || [ "$message_seq" != "$last_message_seq" ]; then
          progress_since="$now"
        fi
        owns_floor=1
      else
        owns_floor=0
      fi
      current_size="$observed_size"
      last_message_seq="$message_seq"
    fi
    if [ "$sent_first" -eq 1 ]; then
      deadline="$timeout"
    else
      deadline="$first_frame_timeout"
    fi
    if [ "$owns_floor" -eq 1 ] && [ $((now - progress_since)) -ge "$deadline" ]; then
      if [ "$sent_first" -eq 1 ]; then
        fail_supervision "$child_pid" 124 semantic-timeout \
          "runtime=$RUNTIME role=$ROLE generation=$GENERATION limit=${deadline}s"
      else
        # No frame ever landed: the runtime could not use the transport at all,
        # which is a launch-environment fault, not a stalled review.
        fail_supervision "$child_pid" 124 first-frame-timeout \
          "runtime=$RUNTIME role=$ROLE generation=$GENERATION limit=${deadline}s transport=unconfirmed hint=verify sandbox excludedCommands, filesystem allowWrite for the comms dir, and that the pinned agent-comms path is executable"
      fi
      return
    fi
    sleep 1
  done
}

heartbeat_loop() {
  local child_pid="$1" after="$2" interval="$3"
  local last_size quiet_since last_heartbeat current_size now elapsed state
  local activity_enabled activity_seq activity_current_sample
  local activity_last_at activity_last_sample activity_next_sequence
  last_size="$(LC_ALL=C wc -c < "$CHANNEL_FILE" | tr -d ' ')"
  quiet_since="$(date +%s)"
  last_heartbeat="$quiet_since"
  activity_enabled=1
  activity_seq=0
  activity_last_at="$quiet_since"
  activity_last_sample="$quiet_since"
  while kill -0 "$child_pid" 2>/dev/null; do
    sleep 1
    kill -0 "$child_pid" 2>/dev/null || break
    now="$(date +%s)"
    if [ "$activity_enabled" -eq 1 ] &&
        [ $((now - activity_last_sample)) -ge "$ACTIVITY_SAMPLE_INTERVAL" ]; then
      if activity_current_sample="$(activity_sample)"; then
        if [ -n "$activity_current_sample" ]; then
          activity_next_sequence=$((activity_seq + 1))
          if append_activity "$now" "$activity_next_sequence" "$activity_current_sample"; then
            activity_seq="$activity_next_sequence"
            activity_last_at="$now"
          else
            append_lifecycle "activity-disabled=write" \
              "runtime=$RUNTIME role=$ROLE generation=$GENERATION" || true
            activity_enabled=0
          fi
        fi
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
    if ! state="$(perl "$HERE/protocol.pl" inspect --file "$CHANNEL_FILE")"; then
      fail_supervision "$child_pid" 70 heartbeat-supervision-failed \
        "runtime=$RUNTIME role=$ROLE generation=$GENERATION"
      return
    fi
    [ "$(state_value "$state" terminal)" = "0" ] || continue
    [ "$(state_value "$state" expected)" = "$ME" ] || continue
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
[ -n "${COMMS_ROOT_FLAG:-}" ] || fail_launch "launch requires --root <work-root>"
[ -d "$COMMS_ROOT_FLAG" ] || fail_launch "work root not found: $COMMS_ROOT_FLAG"
WORK_ROOT="$(realpath "$COMMS_ROOT_FLAG")"
[ "$DECLARED_RELEASE" = "$CLIENT_RELEASE" ] ||
  fail_launch "client release mismatch: launcher=$CLIENT_RELEASE caller=${DECLARED_RELEASE:-missing}"
if [ "$RUNTIME" = "claude" ] && [ "${CLAUDE_CODE_SAFE_MODE:-}" = "1" ]; then
  fail_launch "CLAUDE_CODE_SAFE_MODE disables the agent-comms protocol"
fi
if [ "${#RUNTIME_ARGS[@]}" -gt 0 ]; then
  for argument in "${RUNTIME_ARGS[@]}"; do
    case "$argument" in
      --output-format|--output-format=*|--input-format|--input-format=*|\
      --include-partial-messages|--include-partial-messages=*|--json)
        fail_launch "runtime output flag is owned by agent-comms: $argument"
        ;;
      --safe-mode|--safe-mode=*|--bare|--bare=*)
        [ "$RUNTIME" != "claude" ] ||
          fail_launch "$argument disables the agent-comms protocol"
        ;;
    esac
  done
fi

ME="$RUNTIME"
COMMS_DIRECTORY="$(comms_dir)"
[ -d "$COMMS_DIRECTORY" ] ||
  fail_launch "comms directory not found; initialize the channel first: $COMMS_DIRECTORY"
if [ "$RUNTIME" = "claude" ]; then
  CLAUDE_CONFIG_ROOT="$(realpath "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")"
  COMMS_PHYSICAL="$(realpath "$COMMS_DIRECTORY")"
  case "$COMMS_PHYSICAL/" in
    "$CLAUDE_CONFIG_ROOT/"*)
      fail_launch "Claude cannot write channels under $CLAUDE_CONFIG_ROOT; choose --dir outside it"
      ;;
  esac
fi
mkdir -p "$COMMS_DIRECTORY/.cursors/$CHANNEL"
CHANNEL_FILE="$(channel_file "$CHANNEL")"
assert_confined "$CHANNEL_FILE"
[ -f "$CHANNEL_FILE" ] || fail_launch "channel is not initialized: $CHANNEL_FILE"

METADATA_FILE="$(mktemp "${TMPDIR:-/tmp}/agent-comms-launch-metadata.XXXXXX")"
BOOTSTRAP_FILE="$(mktemp "${TMPDIR:-/tmp}/agent-comms-launch-prompt.XXXXXX")"
CONTROL_CURSOR="$(mktemp "${TMPDIR:-/tmp}/agent-comms-launch-control.XXXXXX")"
SUPERVISOR_STATE_FILE="$(mktemp "${TMPDIR:-/tmp}/agent-comms-launch-supervisor.XXXXXX")"
RESUME_PACKET_FILE=""
CHECKPOINT_BODY_FILE=""
CHILD_PID=""
HEARTBEAT_PID=""
SUPERVISOR_PID=""
ACTIVITY_ROOT=""
ACTIVITY_DIRECTORY=""
ACTIVITY_FILE=""
ACTIVITY_SPOOL=""
ACTIVITY_WRITE_FD=""
ACTIVITY_META_FD=""
ACTIVITY_SAMPLE_INTERVAL=30
cleanup_launch() {
  rm -f "$METADATA_FILE" "$BOOTSTRAP_FILE" "$CONTROL_CURSOR" "$SUPERVISOR_STATE_FILE"
  if [ -n "$RESUME_PACKET_FILE" ]; then
    rm -f "$RESUME_PACKET_FILE"
  fi
  if [ -n "$CHECKPOINT_BODY_FILE" ]; then
    rm -f "$CHECKPOINT_BODY_FILE"
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
stop_supervisor() {
  local attempts=0
  [ -n "$SUPERVISOR_PID" ] || return
  kill "$SUPERVISOR_PID" 2>/dev/null || true
  while kill -0 "$SUPERVISOR_PID" 2>/dev/null && [ "$attempts" -lt 20 ]; do
    sleep 0.1
    attempts=$((attempts + 1))
  done
  if kill -0 "$SUPERVISOR_PID" 2>/dev/null; then
    kill -KILL "$SUPERVISOR_PID" 2>/dev/null || true
  fi
  wait "$SUPERVISOR_PID" 2>/dev/null || true
  SUPERVISOR_PID=""
}
handle_signal() {
  local signal="$1" status="$2"
  trap - INT TERM
  if [ -n "$CHILD_PID" ]; then
    kill -"$signal" "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  stop_supervisor
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
SESSION_SEMANTIC_TIMEOUT="$(metadata_value semantic_timeout)"
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
bash "$RELEASE_ROOT/bin/release.sh" doctor-locked --quiet ||
  fail_launch "global installation drift detected"

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
    --tag "launcher-ready=$ME.$GENERATION" \
    --body-file "$READY_BODY"
  rm -f "$READY_BODY"
else
  PEER_GENERATION="$(metadata_value "generation.$PEER")"
  if perl "$HERE/protocol.pl" wait-control \
      --file "$CHANNEL_FILE" \
      --cursor "$CONTROL_CURSOR" \
      --me "$ME" \
      --tag "launcher-ready=$PEER.$PEER_GENERATION" \
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
CHECKPOINT_BODY_FILE="$(mktemp "$COMMS_DIRECTORY/.checkpoint.$ME.$GENERATION.XXXXXX")"
chmod 600 "$CHECKPOINT_BODY_FILE"
if [ "$ROLE" = "reviewer" ]; then
  printf 'started; task accepted; next=inspect' > "$CHECKPOINT_BODY_FILE"
else
  printf 'started; next=send task' > "$CHECKPOINT_BODY_FILE"
fi
render_command CHECKPOINT_COMMAND "$PINNED_AC" send --channel "$CHANNEL" \
  --dir "$COMMS_DIRECTORY" --from "$ME" --generation "$GENERATION" \
  --continue --body-file "$CHECKPOINT_BODY_FILE"
PROMPT_TITLE="$(sed -n '1p' "$PROMPT_FILE")"
{
  printf '%s\n\n## Transport handshake\n\n' "$PROMPT_TITLE"
  if [ "$ROLE" = "reviewer" ] && [ "$GENERATION" -eq 1 ]; then
    printf 'Run receive first so the driver can give you the floor:\n\n    %s\n\n' "$RECV_COMMAND"
    printf 'When receive returns, verify the local checkpoint below before repository inspection.\n\n'
  else
    printf 'Verify the local checkpoint below before repository inspection.\n\n'
  fi
  printf 'Checkpoint body (verbatim):\n\n    '
  cat "$CHECKPOINT_BODY_FILE"
  printf '\n\nCheckpoint command:\n\n    %s\n\n' "$CHECKPOINT_COMMAND"
  printf 'This appends only the disclosed body to this session'\''s local channel.\n'
  printf 'Verify those disclosed values from this prompt only; do not inspect the filesystem or run a verification tool.\n'
  printf 'Apart from the required receive above when present, run no other tool before this command; execute it as your next transport action.\n\n'
  printf 'After that command succeeds, continue with the instructions below.\n\n'
  sed -n '2,$p' "$PROMPT_FILE"
  printf '\n## Agent-comms v2 transport\n\n'
  printf 'Session: %s. Runtime: %s. Role: %s. Peer: %s. Generation: %s.\n' \
    "$(metadata_value session)" "$RUNTIME" "$ROLE" "$PEER" "$GENERATION"
  printf 'Send a progress fragment without yielding:\n\n    %s --continue --body-file <file>\n\n' "$SEND_COMMAND"
  printf 'Send the final fragment and yield (default):\n\n    %s --body-file <file>\n\n' "$SEND_COMMAND"
  printf 'After yielding, receive one complete peer turn:\n\n    %s\n\n' "$RECV_COMMAND"
  printf 'Run receive synchronously in the foreground immediately after every yielding send.\n'
  printf 'Never background receive or return a final answer while the channel remains open.\n'
  printf 'Complete the verified transport handshake above before repository inspection.\n'
  if [ "$ROLE" = "reviewer" ]; then
    printf 'After every 3 files inspected, send progress naming the last file and current blocking-finding count.\n'
    printf 'After every 3 candidate findings evaluated, send progress naming the last finding and current blocking-finding count.\n'
  else
    printf 'After agreeing a plan, send progress naming the phase, evidence, and next step.\n'
  fi
  printf 'After each commit or verification batch, send progress naming the concrete result and next step.\n'
  printf 'Use those work boundaries, not elapsed time, to decide when to report progress.\n'
  printf 'Keep progress bodies at or below 256 bytes to control token and tail volume.\n'
  printf 'Do not send hidden reasoning. Keep progress fragments short and useful.\n'
  if [ "$ROLE" = "reviewer" ] && [ "$GENERATION" -eq 1 ]; then
    printf 'Your first transport action is receive. After it returns, checkpoint before inspecting the task or repository.\n'
  elif [ "$ROLE" = "reviewer" ]; then
    printf 'Resume the open turn from the packet below; checkpoint before inspecting files and do not receive first.\n'
  else
    printf 'You own the first turn. Send the task before receiving.\n'
  fi
  if [ "$GENERATION" -gt 1 ]; then
    printf '\n## Resume packet\n\n'
    cat "$RESUME_PACKET_FILE"
  fi
} > "$BOOTSTRAP_FILE"

append_lifecycle launching \
  "runtime=$RUNTIME role=$ROLE generation=$GENERATION activity_ref=$ACTIVITY_FILE"
HEARTBEAT_AFTER="$SESSION_HEARTBEAT_AFTER"
HEARTBEAT_INTERVAL="$SESSION_HEARTBEAT_INTERVAL"
case "$HEARTBEAT_AFTER" in ''|*[!0-9]*) fail_launch "bad heartbeat delay";; esac
case "$HEARTBEAT_INTERVAL" in ''|*[!0-9]*) fail_launch "bad heartbeat interval";; esac
[ "$HEARTBEAT_AFTER" -gt 0 ] && [ "$HEARTBEAT_INTERVAL" -gt 0 ] ||
  fail_launch "heartbeat values must be positive"
FIRST_FRAME_TIMEOUT="${AGENT_COMMS_FIRST_FRAME_TIMEOUT:-120}"
case "$FIRST_FRAME_TIMEOUT" in ''|*[!0-9]*) fail_launch "bad first-frame timeout";; esac
[ "$FIRST_FRAME_TIMEOUT" -gt 0 ] || fail_launch "first-frame timeout must be positive"
# A missing first frame is diagnosed sooner than a mid-turn stall, but the
# session-pinned semantic limit still wins when it is the tighter of the two.
[ "$FIRST_FRAME_TIMEOUT" -le "$SESSION_SEMANTIC_TIMEOUT" ] ||
  FIRST_FRAME_TIMEOUT="$SESSION_SEMANTIC_TIMEOUT"
if [ "$RUNTIME" = "claude" ]; then
  export BASH_DEFAULT_TIMEOUT_MS=600000
  export BASH_MAX_TIMEOUT_MS=600000
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
semantic_watchdog_loop "$CHILD_PID" "$SESSION_SEMANTIC_TIMEOUT" "$FIRST_FRAME_TIMEOUT" &
SUPERVISOR_PID=$!
child_status=0
wait "$CHILD_PID" || child_status=$?
stop_supervisor
stop_heartbeat
if [ -s "$SUPERVISOR_STATE_FILE" ]; then
  read -r child_status < "$SUPERVISOR_STATE_FILE"
else
  state="$(perl "$HERE/protocol.pl" inspect --file "$CHANNEL_FILE")" ||
    fail_launch "cannot inspect channel after runtime exit"
  if [ "$(state_value "$state" terminal)" = "0" ] &&
      [ "$(state_value "$state" expected)" = "$ME" ]; then
    message_seq="$(state_value "$state" "message_seq.$ME")"
    case "$message_seq" in
      ''|0)
        runtime_status="$child_status"
        [ "$child_status" -ne 0 ] || child_status=70
        append_lifecycle first-frame-exit \
          "runtime=$RUNTIME role=$ROLE generation=$GENERATION child_status=$runtime_status transport=unconfirmed"
        ;;
    esac
  fi
fi
if ! append_lifecycle "exit=$child_status" \
    "runtime=$RUNTIME role=$ROLE generation=$GENERATION"; then
  [ -s "$SUPERVISOR_STATE_FILE" ] || exit 1
fi
exit "$child_status"
