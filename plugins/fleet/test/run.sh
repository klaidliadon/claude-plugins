#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
for t in cleanup derive fill leaks review-request reviewers skill status watch; do
  [ -f "$DIR/test/$t.sh" ] && bash "$DIR/test/$t.sh"
done
echo "ALL PASS"
