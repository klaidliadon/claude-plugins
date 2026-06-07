#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${TMPDIR:-/tmp}/ace2e.$$"; mkdir -p "$ROOT"; export AGENT_COMMS_ROOT="$ROOT"; trap 'rm -rf "$ROOT"' EXIT
S="$DIR/bin/comms-send.sh"; R="$DIR/bin/comms-recv.sh"

# Reviewer process: wait for review, approve, wait for terminal, exit.
( out=$(bash "$R" --channel c1 --me codex --timeout 10)
  case "$out" in *"please review"*) :;; *) echo "REVIEWER: unexpected: $out"; exit 1;; esac
  printf 'approve' | bash "$S" --channel c1 --from codex --tag approve-ref=h1
  term=$(bash "$R" --channel c1 --me codex --timeout 10)
  case "$term" in *"we are done"*) echo "REVIEWER: saw terminal, exiting";; *) echo "REVIEWER: no terminal: $term"; exit 1;; esac
) & rev=$!

# Driver: send review, wait for approve, send converged terminal.
printf 'please review, ref=h1' | bash "$S" --channel c1 --from claude --tag review-ref=h1
ack=$(bash "$R" --channel c1 --me claude --timeout 10)
case "$ack" in *approve*) :;; *) echo "DRIVER: no approve: $ack"; exit 1;; esac
printf 'we are done' | bash "$S" --channel c1 --from claude --tag converged-ref=h1

wait $rev
echo "E2E PASS"
