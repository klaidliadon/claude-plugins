---
name: agent-comms
description: Use when two agent sessions (e.g. Claude as author, Codex as reviewer) need to autonomously iterate on an artifact — passing messages through a shared file, debating findings, and converging without the human relaying between two chats. Trigger when the user says "review this with Codex until you agree", "have the two of you iterate", "join channel X as reviewer", or "agent-comms".
---

# agent-comms — autonomous 2-party review loop

Two roles share one channel file. The scripts ship in this plugin's `bin/`,
which Claude Code adds to `$PATH` while the plugin is enabled — so call them by
**bare name** (`comms-send.sh …`).

> **Other hosts (e.g. Codex CLI):** run this plugin's `bin/install-codex-link.sh`
> once. It links the skill into `~/.codex/skills/` and prints the `export PATH=…`
> line to add the `bin/` to PATH there too. After that, the bare-name calls below
> work identically.

## Setup
- Channel `C` and the two participant names are agreed with the human.
- Both sessions must resolve the same root: same repo, or both export
  `AGENT_COMMS_ROOT=<abs path>`.

## Commands
- Send: `printf '%s' "<body>" | comms-send.sh --channel C --from <me> [--tag <wire-tag>]`
- Recv (blocks): `comms-recv.sh --channel C --me <me>`
  - prints peer message(s), or `__TIMEOUT__` (exit 2) if none within the window.
- Transcript: `comms-transcript.sh --channel C`

## Wire tags (canonical, hyphenated — never a space)
- `review-ref=H` (driver), `approve-ref=H` (reviewer),
- `converged-ref=H` (driver-only, terminal, success),
- `stopped-reason=impasse|stall|silence|circuit-breaker` (driver-only, terminal).

## Findings ledger (in message bodies)
Each review point: ID (`F1`…), severity (Critical/Important/Suggestion),
status (open/resolved/contested). Only Critical/Important block convergence.
Progress = a finding added, resolved, or given materially new evidence.

## Loop — Driver (author)
1. Edit the artifact. Compute its hash `H` (`shasum`, a manifest, or a git ref).
2. `comms-send.sh --tag review-ref=H` with the body describing the change.
3. `comms-recv.sh` and BLOCK.
4. For each finding: fix (→resolved) or rebut WITH NEW EVIDENCE (→contested);
   edit the artifact if it changed.
5. If a terminal condition holds → send the driver-only terminal tag and STOP
   (terminal sends are exempt from the recv-after-send rule). Else go to 2.

## Loop — Reviewer
1. `comms-recv.sh` and BLOCK.
2. Snapshot the artifact; hash THAT snapshot. Review the snapshot.
3. Raise/update findings, or `comms-send.sh --tag approve-ref=<snapshot-hash>`.
4. `comms-recv.sh` and BLOCK. **Two hard rules:**
   - **Terminal wins:** if a recv batch contains `converged-ref` or
     `stopped-reason`, EXIT immediately regardless of other frames.
   - **Timeout means wait:** on `__TIMEOUT__`, call `comms-recv.sh` again; do NOT
     exit. Exit ONLY on a driver terminal message.

## Termination (driver decides, always releases the reviewer)
- **Converge:** no open/contested Critical/Important AND current artifact hash ==
  reviewer's last approve-ref → `converged-ref=H`, present result + transcript.
- **Impasse:** a Critical/Important finding stays contested after two rebuttals
  with no new evidence → `stopped-reason=impasse`, present BOTH positions to human.
- **Stall:** 3 exchanges with no progress → `stopped-reason=stall`.
- **Circuit breaker:** 25 exchanges → `stopped-reason=circuit-breaker`.
- **Silence:** recv `__TIMEOUT__` after 1–2 retries → `stopped-reason=silence`
  (sent durably so a late reviewer still exits), then surface to human.

## Hash discipline
Reviewer approves the hash of the bytes it SNAPSHOTTED. Driver recomputes the
CURRENT hash before sending `converged-ref`; if it differs (driver edited after
approval), keep looping.
