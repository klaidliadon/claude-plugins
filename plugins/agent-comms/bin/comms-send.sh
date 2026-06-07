#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"

CHANNEL="" FROM="" TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --channel) CHANNEL="$2"; shift 2;;
    --from)    FROM="$2";    shift 2;;
    --tag)     TAG="$2";     shift 2;;
    *) echo "unknown arg: $1" >&2; exit 64;;
  esac
done

if ! valid_name "$CHANNEL"; then echo "bad --channel" >&2; exit 64; fi
if ! valid_name "$FROM";    then echo "bad --from"    >&2; exit 64; fi
if [ -n "$TAG" ] && ! valid_tag "$TAG"; then echo "bad --tag" >&2; exit 64; fi

dir="$(comms_dir)"; mkdir -p "$dir/.cursors/$CHANNEL"
file="$(channel_file "$CHANNEL")"; assert_confined "$file"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
make_frame "$FROM" "$TAG" "$ts" | flock_append "$file"
