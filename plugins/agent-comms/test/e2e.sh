#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${TMPDIR:-/tmp}/ace2e.$$"; mkdir -p "$ROOT"; export AGENT_COMMS_ROOT="$ROOT"; trap 'rm -rf "$ROOT"' EXIT
AC="$DIR/bin/agent-comms"

# Reviewer process: ACK startup, wait for review, approve, wait for terminal, exit.
( bash "$AC" ack --channel c1 --from codex
  out=$(bash "$AC" recv --channel c1 --me codex --timeout 10)
  case "$out" in *"please review"*) :;; *) echo "REVIEWER: unexpected: $out"; exit 1;; esac
  printf 'approve' | bash "$AC" send --channel c1 --from codex --tag approve-ref=h1
  term=$(bash "$AC" recv --channel c1 --me codex --timeout 10)
  case "$term" in *"we are done"*) echo "REVIEWER: saw terminal, exiting";; *) echo "REVIEWER: no terminal: $term"; exit 1;; esac
) & rev=$!

# Driver: require ACK before sending review, then wait for approve and converge.
ready=$(bash "$AC" recv --channel c1 --me claude --timeout 10)
case "$ready" in *"ready"*"ACK"*) :;; *) echo "DRIVER: reviewer did not ACK: $ready"; exit 1;; esac
printf 'please review, ref=h1' | bash "$AC" send --channel c1 --from claude --tag review-ref=h1
ack=$(bash "$AC" recv --channel c1 --me claude --timeout 10)
case "$ack" in *approve*) :;; *) echo "DRIVER: no approve: $ack"; exit 1;; esac
printf 'we are done' | bash "$AC" send --channel c1 --from claude --tag converged-ref=h1

wait $rev
echo "E2E PASS"
