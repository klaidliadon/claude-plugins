#!/usr/bin/env bash

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)*$ ]]
}

valid_tag() {
  [[ "$1" =~ ^[A-Za-z0-9._=-]+$ ]]
}

file_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

plugin_version() {
  local root="$1" manifest version
  manifest="$root/.claude-plugin/plugin.json"
  if [ ! -f "$manifest" ]; then
    echo "missing plugin manifest: $manifest" >&2
    return 1
  fi
  version="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest")"
  if [ -z "$version" ]; then
    echo "missing plugin version: $manifest" >&2
    return 1
  fi
  printf '%s\n' "$version"
}

marketplace_plugin_root() {
  printf '%s\n' "${AGENT_COMMS_MARKETPLACE_ROOT:-$HOME/.claude/plugins/marketplaces/klaidliadon/plugins/agent-comms}"
}

claude_cache_base() {
  printf '%s\n' "${AGENT_COMMS_CACHE_BASE:-$HOME/.claude/plugins/cache/klaidliadon/agent-comms}"
}

resolved_path() {
  local path="$1"
  [ -e "$path" ] || return 1
  realpath "$path"
}

canon_dir() {
  local path="$1" parent
  if [ -d "$path" ]; then
    (cd "$path" && pwd)
    return
  fi
  parent="$(cd "$(dirname "$path")" 2>/dev/null && pwd)" || {
    echo "no such parent dir for: $path" >&2
    return 1
  }
  printf '%s/%s\n' "$parent" "$(basename "$path")"
}

comms_root() {
  local root git_dir
  if [ -n "${COMMS_ROOT_FLAG:-}" ]; then
    root="$COMMS_ROOT_FLAG"
  elif [ -n "${AGENT_COMMS_ROOT:-}" ]; then
    root="$AGENT_COMMS_ROOT"
  elif git_dir="$(git rev-parse --git-common-dir 2>/dev/null)"; then
    root="$(cd "$(dirname "$git_dir")" && pwd)"
  else
    root="$PWD"
  fi
  realpath "$root"
}

comms_dir() {
  if [ -n "${COMMS_DIR_FLAG:-}" ]; then
    printf '%s\n' "$COMMS_DIR_FLAG"
    return
  fi
  printf '%s/tmp/agent-comms\n' "$(comms_root)"
}

channel_file() {
  printf '%s/%s.md\n' "$(comms_dir)" "$1"
}

cursor_file() {
  printf '%s/.cursors/%s/%s\n' "$(comms_dir)" "$1" "$2"
}

assert_confined() {
  local target="$1" base parent
  base="$(comms_dir)"
  parent="$(cd "$(dirname "$target")" 2>/dev/null && pwd || true)"
  case "$parent/" in
    "$base/"*) return 0;;
    *) echo "refusing path outside $base: $target" >&2; return 1;;
  esac
}
