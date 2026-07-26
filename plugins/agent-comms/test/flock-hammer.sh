#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROTOCOL="$DIR/bin/protocol.pl"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-comms-v2-flock.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FILE="$TMP/channel.md"
N=100

perl "$PROTOCOL" init --file "$FILE" --session hammer \
  --driver codex --peer claude --release 2.0.0 \
  --digest aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --protocol 2 --release-root "$TMP/release"
printf 'writer codex' > "$TMP/codex.body"
printf 'writer claude' > "$TMP/claude.body"

writer() {
  local sender="$1" index
  for ((index=0; index<N; index++)); do
    perl "$PROTOCOL" append --file "$FILE" --sender "$sender" --generation 1 \
      --kind status --state none --tag "writer=$sender" --body-file "$TMP/$sender.body"
  done
}

writer codex &
first=$!
writer claude &
second=$!
(
  for ((index=0; index<50; index++)); do
    perl "$PROTOCOL" transcript --file "$FILE" >/dev/null
    sleep 0.02
  done
) &
reader=$!
wait "$first" "$second" "$reader"

expected=$((N * 2 + 1))
frames="$(grep -c '^<!-- agent-comms v=2 ' "$FILE")"
[ "$frames" -eq "$expected" ] || {
  echo "FAIL: frame count $frames != $expected"
  exit 1
}
metadata="$(perl "$PROTOCOL" inspect --file "$FILE")"
case "$metadata" in
  *"seq=$expected"*) ;;
  *) echo "FAIL: final sequence is not $expected"; exit 1;;
esac
echo "PASS: $expected checksummed frames, no torn/interleaved append"
