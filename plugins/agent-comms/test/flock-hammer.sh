#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/bin/lib.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FILE="$TMP/chan.md"
N=2000   # frames per writer

writer() { # writer ID
  local id="$1" i
  for ((i=0; i<N; i++)); do
    printf 'W%s-%06d\n' "$id" "$i" | flock_append "$FILE"
  done
}

writer A & p1=$!
writer B & p2=$!
# reader starts mid-run, tails to EOF repeatedly
( for ((k=0;k<50;k++)); do read_from "$FILE" 0 >/dev/null; sleep 0.02; done ) &
wait $p1 $p2

# Assertions
lines=$(wc -l < "$FILE" | tr -d ' ')
expect=$((N*2))
[ "$lines" -eq "$expect" ] || { echo "FAIL: line count $lines != $expect (torn/lost writes)"; exit 1; }
bad=$(grep -cvE '^W[AB]-[0-9]{6}$' "$FILE" || true)
[ "$bad" -eq 0 ] || { echo "FAIL: $bad torn/interleaved lines"; exit 1; }
[ "$(grep -c '^WA-' "$FILE")" -eq "$N" ] || { echo "FAIL: WA count"; exit 1; }
[ "$(grep -c '^WB-' "$FILE")" -eq "$N" ] || { echo "FAIL: WB count"; exit 1; }
echo "PASS: $expect intact frames, no interleaving, concurrent reader OK"
