#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"

CHANNEL="" ME="" TIMEOUT=590
while [ $# -gt 0 ]; do
  case "$1" in
    --channel) CHANNEL="$2"; shift 2;;
    --me)      ME="$2";      shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 64;;
  esac
done
if ! valid_name "$CHANNEL"; then echo "bad --channel" >&2; exit 64; fi
if ! valid_name "$ME";      then echo "bad --me"      >&2; exit 64; fi

dir="$(comms_dir)"; mkdir -p "$dir/.cursors/$CHANNEL"
file="$(channel_file "$CHANNEL")"; assert_confined "$file"
if [ ! -e "$file" ]; then : > "$file"; fi
cur="$(cursor_file "$CHANNEL" "$ME")"; assert_confined "$cur"
off=0
if [ -f "$cur" ]; then off="$(cat "$cur")"; fi
# Guard against a corrupt (non-integer) cursor poisoning delivered output.
case "$off" in ''|*[!0-9]*) off=0;; esac

bd=""
trap 'rm -rf "${bd:-}"' EXIT INT TERM
deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  bd="${TMPDIR:-/tmp}/acrb.$$.$RANDOM"; mkdir -p "$bd"
  idx="$(read_from "$file" "$off" | BODY_DIR="$bd" parse_frames "$off")"
  if [ -n "$idx" ]; then
    peer_out="" last_peer_end="" last_any_end="" i=0
    while IFS=$'\t' read -r start end sender tag; do
      i=$((i+1)); last_any_end="$end"
      if [ "$sender" != "$ME" ]; then
        peer_out="${peer_out}$(cat "$bd/$i")"$'\n'
        last_peer_end="$end"
      fi
    done <<< "$idx"
    rm -rf "$bd"
    if [ -n "$last_peer_end" ]; then
      echo "$last_peer_end" > "$cur"
      printf '%s' "$peer_out"
      exit 0
    fi
    # Only self frames — advance past them so next poll doesn't re-read
    if [ -n "$last_any_end" ]; then
      echo "$last_any_end" > "$cur"
      off="$last_any_end"
    fi
  else
    rm -rf "$bd"
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "__TIMEOUT__"
    exit 2
  fi
  sleep 0.3
done
