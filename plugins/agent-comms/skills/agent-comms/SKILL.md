---
name: agent-comms
description: Use when Claude and Codex must autonomously exchange progressive work, review an artifact until agreement, or resume an interrupted two-agent session without a human relaying messages.
---

# Agent Comms

Use one append-only, human-readable channel. `tail -f "$(agent-comms path …)"`
shows the whole exchange; hidden v2 headers, not visible separators or the word
`over`, are authoritative.

Release literal: `--client-release 2.0.0`. Never derive or change it at runtime.

## Start a review

Pick one absolute `--dir` and pass it on every command.

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
     --client-release 2.0.0 --dir D
   ```

3. Require the launcher handshake before spending a model turn:

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
Progress is capped at four 512-byte fragments per turn. Send useful conclusions,
not tool logs or hidden reasoning.

Maintain findings as `F1…`, severity `Critical|Important|Suggestion`, and status
`open|resolved|contested`. Only unresolved Critical/Important findings block
approval.

## Resume an interrupted peer

On `__TURN_TIMEOUT__`, stop the old launcher process, write a bounded handoff,
then fence and replace the current floor holder:

```text
agent-comms resume --channel C --from <driver> --generation <driver-gen> \
  --replace <peer> --body-file HANDOFF [--artifact-file ARTIFACT] --dir D
```

Launch the peer again with its incremented generation and the same pinned
`--client-release 2.0.0`. Pass the current artifact when one exists. The
launcher verifies its hash and injects the checksummed resume packet; never
replay the full transcript or fall forward to `current`. Late old-generation
frames remain visible but are excluded from delivery.

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
