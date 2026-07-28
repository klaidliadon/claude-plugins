---
name: agent-comms
description: Use when Claude and Codex must autonomously exchange progressive work, review an artifact until agreement, or resume an interrupted two-agent session without a human relaying messages.
---

# Agent Comms

Use one append-only, human-readable channel. `tail -f "$(agent-comms path …)"`
shows the whole exchange; hidden v2 headers, not visible separators or the word
`over`, are authoritative.

Release literal: `--client-release 2.0.3`. Never derive or change it at runtime.

## Start a review

Pick the reviewed repository's absolute root `R` and one absolute `--dir D`
writable by both runtime sandboxes. Pass `--dir D` on every command. Every
`launch` also requires `--root R`; this keeps the work tree independent from
the shared channel directory and the caller's current directory. For Claude,
`D` must be outside `CLAUDE_CONFIG_DIR` (normally `~/.claude`); that tree is
protected even with `--add-dir` and bypass mode, so launch rejects it before
spending a model turn.

1. Create the channel. The invoked immutable release pins its own version,
   digest, protocol, and root:

   ```text
   agent-comms init --channel C --session S --driver <me> --peer <peer> --dir D
   ```

2. Write a reviewer prompt beginning with a concrete one-line title. Launch the
   peer with the host's background-process facility:

   ```text
   agent-comms launch <claude|codex> --role reviewer --peer <me> \
     --channel C --generation 1 --prompt-file P \
     --client-release 2.0.3 --root R --dir D
   ```

3. Require `launcher-ready` before spending a model turn. This proves the
   transport and runtime adapter are ready; it is not a model-generated ACK:

   ```text
   agent-comms wait-ready --channel C --me <me> --peer <peer> \
     --generation 1 --dir D
   ```

4. Send the task with `--review-ref <artifact>`, then call `recv`.

## Walkie-talkie turns

Write each body to a file. A normal `send` ends with the visible
`---------- <sender> · over ----------` and yields the floor. `--continue`
emits `----------` and retains it.

```text
agent-comms send --channel C --from <me> --generation N \
  [--continue] [--review-ref|--approve-ref <artifact>] --body-file B --dir D
agent-comms recv --channel C --me <me> --generation N --dir D
```

`recv` returns one completed peer turn, coalescing progressive messages and
excluding heartbeats/status. Never poll after `--continue`; keep working.
Progress is capped at eight 512-byte fragments per turn. Send useful conclusions,
not tool logs or hidden reasoning.

When taking the floor, complete the launcher's transport handshake before
reading repository files. The prompt discloses the exact bounded checkpoint
body and command; verify their pinned path, channel, sender, generation, and
body from the disclosed prompt, without a filesystem probe before running it.
This proves model transport participation without blind execution or tokens
spent composing status.
Every later progress body must be written by the current agent and carry new
evidence; a byte-identical consecutive progress body is rejected. Reviewers
send progress after every three files inspected and every three candidate
findings evaluated, naming the last item and current blocking-finding count.
Drivers send after the plan, each commit, and each verification batch. Use work
boundaries, not elapsed-time guesses. Report evidence and the next step or
blocker in at most 256 bytes. Skip inapplicable phases; never manufacture
updates.

The session defaults `semantic_timeout` to 300 seconds and permits at most 3600.
The default is the maximum gap between evidence-bearing updates, not a total
task-duration limit. Use a larger explicit session value only for a workload
whose meaningful progress cannot be split; do not silently raise it for
ordinary reviews.
While an agent holds the floor, only one of its current-generation message
frames resets that clock; status, heartbeat, and activity ticks do not. The
launcher records `semantic-timeout`, terminates the runtime, and exits 124 when
the limit expires. The waiting peer may then resume it.
Before the first frame, a running peer gets the shorter 60-second
`first-frame-timeout`; a peer that exits while holding the floor gets
`first-frame-exit`, and a false-success child status is converted to exit 70.
Terminal peer control stops the launched runtime immediately.

Claude launches with foreground Bash timeouts long enough for the default
540-second `recv`. Call `recv` synchronously again after a silence timeout;
never leave it running in the background.
Do not launch Claude with `--safe-mode`, `--bare`, or
`CLAUDE_CODE_SAFE_MODE=1`; launch rejects modes that remove the protocol
instruction substrate.

Maintain findings as `F1…`, severity `Critical|Important|Suggestion`, and status
`open|resolved|contested`. Only unresolved Critical/Important findings block
approval.

## Tail activity without waking the peer

`launcher-ready` and `launching` publish `activity_ref=<absolute path>`. Humans
and external supervisors may tail it. Each active 30-second sample reports
`seq`, event count, structural event types, and structural content-block types.
It exposes no message text, reasoning, tool input/output, or byte count.
Activity never yields or wakes `recv`; never relay it to the waiting model.

## Resume an interrupted peer

On `__TURN_TIMEOUT__`, stop the old launcher process, write a bounded handoff,
then fence and replace the current floor holder:

```text
agent-comms resume --channel C --from <driver> --generation <driver-gen> \
  --replace <peer> --body-file HANDOFF [--artifact-file ARTIFACT] --dir D
```

Launch the peer again with its incremented generation, `--root R`, and the same
pinned `--client-release 2.0.3`. Pass the current artifact when one exists. The
launcher verifies its hash and injects the original task body, task checksum,
handoff, and artifact checksum; never replay the full transcript or fall
forward to `current`. Late old-generation frames remain visible but are
excluded from delivery. Replacement keeps the open turn number but starts fresh
receive and semantic-progress deadlines.

## Finish

- Reviewer: `--approve-ref <artifact>` only for the exact reviewed bytes, then
  `recv` again.
- Driver convergence: send `--converged-ref <artifact>` with a body. This is a
  terminal control and releases the reviewer.
- Driver stop: send `--tag stopped-reason=impasse|stall|silence|circuit-breaker`.
- Stop after 25 exchanges, three no-progress exchanges, or two evidence-free
  rebuttals. Report both positions on impasse.

Run `agent-comms doctor` for global drift and
`agent-comms doctor --channel C --dir D` for pinned-session integrity. Do not
repair drift by hand; use `agent-comms install`.
