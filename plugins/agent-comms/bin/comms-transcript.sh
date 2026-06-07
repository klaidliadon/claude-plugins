#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"
CHANNEL=""
while [ $# -gt 0 ]; do case "$1" in --channel) CHANNEL="$2"; shift 2;; *) shift;; esac; done
if ! valid_name "$CHANNEL"; then echo "bad --channel" >&2; exit 64; fi
file="$(channel_file "$CHANNEL")"; [ -e "$file" ] || exit 0
bd="${TMPDIR:-/tmp}/actrans.$$.$RANDOM"; mkdir -p "$bd"; trap 'rm -rf "$bd"' EXIT
idx="$(read_from "$file" 0 | BODY_DIR="$bd" parse_frames 0)"
i=0
while IFS=$'\t' read -r _ _ _ _; do
  i=$((i+1))
  [ -f "$bd/$i" ] && { cat "$bd/$i"; echo; }
done <<< "$idx"
