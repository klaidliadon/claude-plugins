#!/usr/bin/env bash
FLEET_HOME="${FLEET_HOME:-$HOME/Workspace/.fleet}"

fm_get() {
  local v
  v="$(yq --front-matter=extract "$2" "$1")"
  [ "$v" = "null" ] && v=""
  printf '%s' "$v"
}

fm_set() {
  yq --front-matter=process -i "$2" "$1"
}

ledger_append() {
  mkdir -p "$FLEET_HOME"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$FLEET_HOME/ledger.md"
}
