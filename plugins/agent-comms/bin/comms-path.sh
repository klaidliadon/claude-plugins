#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"
CHANNEL=""
while [ $# -gt 0 ]; do case "$1" in --channel) CHANNEL="$2"; shift 2;; *) shift;; esac; done
if ! valid_name "$CHANNEL"; then echo "bad --channel" >&2; exit 64; fi
channel_file "$CHANNEL"
