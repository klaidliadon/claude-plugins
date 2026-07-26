#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

bash "$DIR/test/protocol.sh"
bash "$DIR/test/launch.sh"

echo "ALL PASS"
