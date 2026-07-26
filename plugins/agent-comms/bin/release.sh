#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
source "$HERE/lib.sh"

fail_release() {
  echo "agent-comms release: $*" >&2
  exit 1
}

file_mode() {
  perl -e 'my @s = stat($ARGV[0]) or die "stat $ARGV[0]: $!\n"; printf "%04o\n", $s[2] & 07777' "$1"
}

manifest_to() {
  local root="$1" destination="$2" version paths rel
  root="$(realpath "$root")"
  version="$(plugin_version "$root")"
  paths="$(mktemp "${TMPDIR:-/tmp}/agent-comms-manifest-paths.XXXXXX")"
  find "$root" -type f ! -path "$root/manifest.lock" -print |
    sed "s#^$root/##" |
    LC_ALL=C sort > "$paths"
  {
    printf 'protocol 2\n'
    printf 'release %s\n' "$version"
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      case "$rel" in /*|../*|*/../*) fail_release "unsafe manifest path: $rel";; esac
      printf '%s %s %s\n' "$(file_mode "$root/$rel")" "$(file_sha256 "$root/$rel")" "$rel"
    done < "$paths"
  } > "$destination"
  rm -f "$paths"
}

manifest_verify() {
  local root="$1" expected generated
  root="$(realpath "$root")"
  expected="$root/manifest.lock"
  [ -f "$expected" ] || fail_release "missing manifest: $expected"
  generated="$(mktemp "${TMPDIR:-/tmp}/agent-comms-manifest.XXXXXX")"
  manifest_to "$root" "$generated"
  if ! cmp -s "$expected" "$generated"; then
    echo "agent-comms release: manifest mismatch: $root" >&2
    diff -u "$expected" "$generated" >&2 || true
    rm -f "$generated"
    return 1
  fi
  rm -f "$generated"
}

parse_root() {
  ROOT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) ROOT="${2:-}"; shift 2;;
      *) fail_release "unknown argument: $1";;
    esac
  done
  [ -n "$ROOT" ] || ROOT="$(cd "$HERE/.." && pwd)"
}

share_root() {
  printf '%s\n' "${AGENT_COMMS_SHARE_ROOT:-$HOME/.local/share/agent-comms}"
}

public_bin() {
  printf '%s\n' "${AGENT_COMMS_PUBLIC_BIN:-$HOME/.local/bin}"
}

selected_plugin() {
  claude plugin list --json |
    perl -MJSON::PP -0777 -e '
      my $items = decode_json(<STDIN>);
      my @selected = grep {
        ($_->{id} // "") eq q{agent-comms@klaidliadon} && $_->{enabled}
      } @$items;
      die "expected one enabled agent-comms plugin\n" unless @selected == 1;
      my $item = $selected[0];
      for my $key (qw(version installPath)) {
        die "selected plugin missing $key\n" unless defined $item->{$key} && length $item->{$key};
        die "invalid selected plugin $key\n" if $item->{$key} =~ /[\t\r\n]/;
      }
      print "$item->{version}\t$item->{installPath}\n";
    '
}

adapter_check() {
  local output
  output="$(claude --help 2>&1)" || fail_release "claude --help failed"
  case "$output" in *-p*--permission-mode*--add-dir*) ;; *) fail_release "Claude adapter flags are unsupported";; esac
  output="$(codex exec --help 2>&1)" || fail_release "codex exec --help failed"
  case "$output" in *--dangerously-bypass-approvals-and-sandbox*--skip-git-repo-check*) ;;
    *) fail_release "Codex adapter flags are unsupported";;
  esac
}

expect_target() {
  local label="$1" path="$2" expected="$3" got want
  got="$(resolved_path "$path" 2>/dev/null || true)"
  want="$(resolved_path "$expected" 2>/dev/null || true)"
  if [ -z "$got" ] || [ "$got" != "$want" ]; then
    echo "agent-comms doctor: $label mismatch: ${got:-missing} != ${want:-missing}" >&2
    return 1
  fi
}

metadata_value_file() {
  local file="$1" key="$2"
  awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$file"
}

doctor_channel() {
  local channel="$1" file metadata release version digest protocol root actual_digest cursor value
  valid_name "$channel" || fail_release "bad channel"
  file="$(channel_file "$channel")"
  [ -f "$file" ] || fail_release "channel does not exist: $file"
  metadata="$(mktemp "${TMPDIR:-/tmp}/agent-comms-channel.XXXXXX")"
  if ! perl "$HERE/protocol.pl" inspect --file "$file" > "$metadata"; then
    rm -f "$metadata"
    return 1
  fi
  release="$(metadata_value_file "$metadata" release)"
  digest="$(metadata_value_file "$metadata" digest)"
  protocol="$(metadata_value_file "$metadata" protocol)"
  root="$(metadata_value_file "$metadata" release_root)"
  rm -f "$metadata"
  [ "$protocol" = "2" ] || fail_release "channel protocol mismatch: $protocol"
  case "$root" in /*) ;; *) fail_release "pinned release root is not absolute: $root";; esac
  if [ ! -d "$root" ]; then
    echo "agent-comms doctor: pinned release is missing: $root" >&2
    echo "reinstall exact release $release; refusing to fall forward to current" >&2
    return 1
  fi
  root="$(realpath "$root")"
  manifest_verify "$root"
  version="$(plugin_version "$root")"
  actual_digest="$(file_sha256 "$root/manifest.lock")"
  [ "$version" = "$release" ] ||
    fail_release "channel release mismatch: $release != $version"
  [ "$actual_digest" = "$digest" ] ||
    fail_release "channel digest mismatch: $digest != $actual_digest"
  if [ -d "$(comms_dir)/.cursors/$channel" ]; then
    while IFS= read -r cursor; do
      value="$(cat "$cursor")"
      case "$value" in ''|*[!0-9]*) fail_release "invalid cursor: $cursor";; esac
    done < <(find "$(comms_dir)/.cursors/$channel" -type f -print)
  fi
  echo "channel: $channel"
  echo "pinned release: $release"
  echo "pinned digest: $digest"
  echo "pinned root: $root"
}

doctor_global() {
  local quiet="" channel=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet) quiet=1; shift;;
      --channel) channel="${2:-}"; shift 2;;
      *) fail_release "unknown doctor argument: $1";;
    esac
  done
  local marketplace share current selected version selected_path current_version
  local marketplace_digest current_digest cli skill name failed=0
  marketplace="$(marketplace_plugin_root)"
  share="$(share_root)"
  current="$share/current"
  if ! manifest_verify "$marketplace"; then failed=1; fi
  if [ ! -L "$current" ]; then
    echo "agent-comms doctor: missing current symlink: $current" >&2
    failed=1
  elif ! manifest_verify "$current"; then
    failed=1
  fi
  if [ "$failed" -eq 0 ]; then
    selected="$(selected_plugin 2>&1)" || {
      echo "agent-comms doctor: Claude plugin selection failed: $selected" >&2
      failed=1
    }
  fi
  if [ "$failed" -eq 0 ]; then
    version="${selected%%	*}"
    selected_path="${selected#*	}"
    current_version="$(plugin_version "$current")"
    if [ "$version" != "$current_version" ]; then
      echo "agent-comms doctor: Claude selected version mismatch: $version != $current_version" >&2
      failed=1
    fi
    if [ "$(realpath "$selected_path" 2>/dev/null || true)" != "$(realpath "$current" 2>/dev/null || true)" ]; then
      echo "agent-comms doctor: Claude selected path mismatch: $selected_path != $(realpath "$current")" >&2
      failed=1
    fi
    marketplace_digest="$(file_sha256 "$marketplace/manifest.lock")"
    current_digest="$(file_sha256 "$current/manifest.lock")"
    if [ "$marketplace_digest" != "$current_digest" ]; then
      echo "agent-comms doctor: marketplace/current digest mismatch" >&2
      failed=1
    fi
    cli="$(public_bin)/agent-comms"
    skill="${AGENT_COMMS_CODEX_SKILL:-$HOME/.codex/skills/agent-comms}"
    expect_target "public CLI target" "$cli" "$current/bin/agent-comms" || failed=1
    expect_target "Codex skill target" "$skill" "$current/skills/agent-comms" || failed=1
    for name in claude-review codex-review lib.sh; do
      if [ -e "$(public_bin)/$name" ] || [ -L "$(public_bin)/$name" ]; then
        echo "agent-comms doctor: stale public command: $(public_bin)/$name" >&2
        failed=1
      fi
    done
    adapter_check || failed=1
  fi
  [ "$failed" -eq 0 ] || return 1
  if [ -n "$channel" ]; then
    doctor_channel "$channel" || return 1
  fi
  if [ -z "$quiet" ]; then
    echo "release: $current_version"
    echo "digest: $current_digest"
    echo "current: $(realpath "$current")"
    echo "installation: consistent"
  fi
}

owned_link() {
  local path="$1" target resolved share marketplace cache
  [ -L "$path" ] || return 1
  target="$(readlink "$path")"
  resolved="$(resolved_path "$path" 2>/dev/null || true)"
  share="$(share_root)"
  marketplace="$(marketplace_plugin_root)"
  cache="$(claude_cache_base)"
  case "$resolved/" in
    "$share/"*|"$marketplace/"*|"$cache/"*) return 0;;
  esac
  case "$target" in
    *agent-comms*) return 0;;
  esac
  return 1
}

preflight_destination() {
  local path="$1"
  if [ -e "$path" ] || [ -L "$path" ]; then
    owned_link "$path" || fail_release "refusing unrelated destination: $path"
  fi
}

set_link() {
  local path="$1" target="$2"
  mkdir -p "$(dirname "$path")"
  ln -sfn "$target" "$path"
}

restore_link() {
  local path="$1" old_target="$2"
  if [ -n "$old_target" ]; then
    ln -sfn "$old_target" "$path"
  else
    rm -f "$path"
  fi
}

activate_current() {
  local share="$1" selected_path="$2" temporary relative
  share="$(realpath "$share")"
  temporary="$share/current.new.$$"
  relative="$(perl -MFile::Spec -e 'print File::Spec->abs2rel($ARGV[0], $ARGV[1])' \
    "$selected_path" "$share")"
  rm -f "$temporary"
  ln -s "$relative" "$temporary"
  perl -e 'rename($ARGV[0], $ARGV[1]) or die "activate current: $!\n"' \
    "$temporary" "$share/current"
}

restore_current() {
  local share="$1" old_target="$2" temporary
  share="$(realpath "$share")"
  temporary="$share/current.rollback.$$"
  rm -f "$temporary"
  if [ -n "$old_target" ]; then
    ln -s "$old_target" "$temporary"
    perl -e 'rename($ARGV[0], $ARGV[1]) or die "restore current: $!\n"' \
      "$temporary" "$share/current"
  else
    rm -f "$share/current"
  fi
}

stage_removed_commands() {
  local name path backup
  REMOVED_COMMAND_BACKUPS=()
  for name in claude-review codex-review lib.sh; do
    path="$(public_bin)/$name"
    [ -L "$path" ] || continue
    backup="$path.agent-comms-backup.$$"
    if ! mv "$path" "$backup"; then
      restore_removed_commands
      fail_release "could not stage removal: $path"
    fi
    REMOVED_COMMAND_BACKUPS+=("$path" "$backup")
  done
}

restore_removed_commands() {
  local index=0 path backup
  while [ "$index" -lt "${#REMOVED_COMMAND_BACKUPS[@]}" ]; do
    path="${REMOVED_COMMAND_BACKUPS[$index]}"
    backup="${REMOVED_COMMAND_BACKUPS[$((index + 1))]}"
    if [ -L "$backup" ]; then mv "$backup" "$path"; fi
    index=$((index + 2))
  done
}

discard_removed_command_backups() {
  local index=1
  while [ "$index" -lt "${#REMOVED_COMMAND_BACKUPS[@]}" ]; do
    rm -f "${REMOVED_COMMAND_BACKUPS[$index]}"
    index=$((index + 2))
  done
}

install_locked() {
  local marketplace share selected version selected_path marketplace_version selected_version
  local marketplace_digest selected_digest current old_target="" cli skill name commit receipt pending_receipt
  local old_cli_target="" old_skill_target=""
  marketplace="$(marketplace_plugin_root)"
  share="$(share_root)"
  current="$share/current"
  mkdir -p "$share"
  if selected_plugin >/dev/null 2>&1; then
    claude plugin update agent-comms@klaidliadon >/dev/null
  else
    claude plugin install agent-comms@klaidliadon >/dev/null
  fi
  selected="$(selected_plugin)"
  version="${selected%%	*}"
  selected_path="${selected#*	}"
  selected_path="$(realpath "$selected_path")"
  manifest_verify "$marketplace"
  manifest_verify "$selected_path"
  marketplace_version="$(plugin_version "$marketplace")"
  selected_version="$(plugin_version "$selected_path")"
  [ "$version" = "$selected_version" ] ||
    fail_release "selected version mismatch: CLI=$version manifest=$selected_version"
  [ "$marketplace_version" = "$selected_version" ] ||
    fail_release "marketplace/cache version mismatch: $marketplace_version != $selected_version"
  marketplace_digest="$(file_sha256 "$marketplace/manifest.lock")"
  selected_digest="$(file_sha256 "$selected_path/manifest.lock")"
  [ "$marketplace_digest" = "$selected_digest" ] ||
    fail_release "same release has different marketplace/cache bytes"
  perl -c "$selected_path/bin/protocol.pl" >/dev/null
  bash -n "$selected_path/bin/agent-comms"
  bash -n "$selected_path/bin/launch.sh"
  bash "$selected_path/bin/agent-comms" help >/dev/null

  cli="$(public_bin)/agent-comms"
  skill="${AGENT_COMMS_CODEX_SKILL:-$HOME/.codex/skills/agent-comms}"
  preflight_destination "$current"
  preflight_destination "$cli"
  preflight_destination "$skill"
  for name in claude-review codex-review lib.sh; do
    preflight_destination "$(public_bin)/$name"
  done
  stage_removed_commands
  if [ "${AGENT_COMMS_FAILPOINT:-}" = "before-switch" ]; then
    restore_removed_commands
    fail_release "injected failure before current switch"
  fi
  if [ -L "$current" ]; then old_target="$(readlink "$current")"; fi
  if [ -L "$cli" ]; then old_cli_target="$(readlink "$cli")"; fi
  if [ -L "$skill" ]; then old_skill_target="$(readlink "$skill")"; fi
  activate_current "$share" "$selected_path"
  if ! set_link "$cli" "$share/current/bin/agent-comms" ||
     ! set_link "$skill" "$share/current/skills/agent-comms"; then
    restore_current "$share" "$old_target"
    restore_link "$cli" "$old_cli_target"
    restore_link "$skill" "$old_skill_target"
    restore_removed_commands
    fail_release "stable link activation failed; restored previous release"
  fi
  if [ "${AGENT_COMMS_FAILPOINT:-}" = "after-switch" ]; then
    restore_current "$share" "$old_target"
    restore_link "$cli" "$old_cli_target"
    restore_link "$skill" "$old_skill_target"
    restore_removed_commands
    fail_release "injected failure after current switch; restored previous release"
  fi
  if ! doctor_global; then
    restore_current "$share" "$old_target"
    restore_link "$cli" "$old_cli_target"
    restore_link "$skill" "$old_skill_target"
    restore_removed_commands
    fail_release "post-switch doctor failed; restored previous release"
  fi
  mkdir -p "$share/receipts"
  commit="$(git -C "$marketplace" rev-parse HEAD 2>/dev/null || printf unknown)"
  receipt="$share/receipts/$version"
  pending_receipt="$receipt.pending.$$"
  {
    printf 'version=%s\n' "$version"
    printf 'digest=%s\n' "$selected_digest"
    printf 'protocol=2\n'
    printf 'tag=agent-comms--v%s\n' "$version"
    printf 'commit=%s\n' "$commit"
    printf 'installed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$pending_receipt"
  if ! mv "$pending_receipt" "$receipt"; then
    restore_current "$share" "$old_target"
    restore_link "$cli" "$old_cli_target"
    restore_link "$skill" "$old_skill_target"
    restore_removed_commands
    fail_release "receipt activation failed; restored previous release"
  fi
  discard_removed_command_backups
}

with_update_lock() {
  local share lock
  share="$(share_root)"
  mkdir -p "$share"
  lock="$share/update.lock"
  perl -e '
    use Fcntl qw(:flock);
    open(my $lock, ">>", shift @ARGV) or die "open update lock: $!\n";
    flock($lock, LOCK_EX) or die "lock update: $!\n";
    my $status = system @ARGV;
    exit($status == -1 ? 127 : $status >> 8);
  ' "$lock" bash "$SCRIPT_PATH" _install
}

check_update() {
  local marketplace current selected version selected_path marketplace_digest selected_digest
  marketplace="$(marketplace_plugin_root)"
  current="$(share_root)/current"
  manifest_verify "$marketplace"
  selected="$(selected_plugin)"
  version="${selected%%	*}"
  selected_path="$(realpath "${selected#*	}")"
  manifest_verify "$selected_path"
  [ "$version" = "$(plugin_version "$selected_path")" ] ||
    fail_release "selected version does not match its manifest"
  marketplace_digest="$(file_sha256 "$marketplace/manifest.lock")"
  selected_digest="$(file_sha256 "$selected_path/manifest.lock")"
  [ "$marketplace_digest" = "$selected_digest" ] ||
    fail_release "marketplace and selected release differ"
  if [ ! -L "$current" ] || [ "$(realpath "$current")" != "$selected_path" ]; then
    echo "update available: ${current} -> $selected_path"
    return
  fi
  echo "up to date: $version $selected_digest"
}

command="${1:-}"
[ $# -eq 0 ] || shift
case "$command" in
  manifest)
    parse_root "$@"
    temporary="$(mktemp "${TMPDIR:-/tmp}/agent-comms-manifest.XXXXXX")"
    manifest_to "$ROOT" "$temporary"
    mv "$temporary" "$ROOT/manifest.lock"
    ;;
  verify)
    parse_root "$@"
    manifest_verify "$ROOT"
    ;;
  digest)
    parse_root "$@"
    manifest_verify "$ROOT"
    file_sha256 "$ROOT/manifest.lock"
    ;;
  doctor)
    doctor_global "$@"
    ;;
  install)
    with_update_lock
    ;;
  update)
    if [ "${1:-}" = "--check" ] && [ $# -eq 1 ]; then
      check_update
    elif [ $# -eq 0 ]; then
      with_update_lock
    else
      fail_release "usage: agent-comms update [--check]"
    fi
    ;;
  _install)
    install_locked
    ;;
  *)
    fail_release "unknown command: ${command:-missing}"
    ;;
esac
