# The Written Register

How Alex structures written artifacts when he writes them himself. Derived from 200 pre-2026 PR
and issue bodies across `0xsequence/*`, `webrpc`, and `goware` (see the corpus findings in
`claude-plugins/tmp/voice-standard/`), written before an agent drafted them.

This is the counterpart to the `comms` skill, which owns the same thing for Slack. Use this when
drafting a PR body, an issue, a commit body, or a design doc that goes out under his name.

Where a repository template exists, the template's headings win. This file governs what goes
inside them.

## Absolute rules

- **No em dashes, no en dashes. Zero, across 200 samples.** Use a plain hyphen where a dash is
  genuinely needed mid-sentence ("so we can take action - like add funds to the relayers"), or
  restructure with a comma or "so".
- **No headings on anything short.** A two-paragraph body gets no `##`. Reach for headings only
  when a template asks or the body has three or more genuinely separate concerns.
- **No conclusion.** Stop on the last fact. Nothing summarizes, nothing wraps up.

## Pick the opener by change type

**Bug fix: the defect first, the fix second.** One paragraph naming the mechanism that is broken,
then a short sentence starting "This PR fixes ...". The length contrast is the point.

> If no topup limit is set, the function returns early before checking for pending transactions.
>
> This PR fixes that issue.

> The current implementation fails when switching between sandboxes or accounts because it
> retrieves cached records associated with a different account, resulting in 404 errors from
> Stripe.
>
> This PR fixes the issue by including the Stripe account ID in the cache key, ensuring proper
> cache isolation across accounts.

**Feature or refactor: the change first, then the mechanism.** One plain declarative, then how it
works.

> This PR replaces the sysadmin user flag with role. Each role has a set of permissions and both
> backend and frontend are generated using a script.
>
> The permissions are stored using powers of two, so we can check if a user has a certain
> permission using a bitwise and.

**Issue: the situation in present tense.** No "This issue ..." formula. Describe current or
desired behavior directly, then ground it with a concrete instance.

> When a Stripe Top up is executed we post to a slack channel, so we can take action - like add
> funds to the relayers.

## Sentence rhythm, measured

Mechanism sentences run long: 26 and 27 words in the samples above, carrying a full causal chain
with "because" or "so". They are followed by something very short. That pairing is what makes
them readable, not brevity.

Do not enforce a word cap. A 27-word causal sentence followed by a 4-word one is the register. Two
dozen uniform 12-word sentences is not.

## Evidence moves

- **Raw link, often as the entire body.** A bare Sentry URL, a GCP logs query, or a Slack
  permalink is a complete PR body when it is the whole story. Do not wrap it in explanation it
  does not need.
- **Permalink to a line range, as a sentence tail.** "See https://.../access_control.go#L20-L30".
  Point at the test that proves the case rather than describing it: "This scenario is detected by
  [this test](...#L427-L432)."
- **"This: / Becomes:" blocks with nothing between them.** Show the old form and the new form as
  two adjacent fenced blocks and let the reader diff them.
- **Verbatim terminal output, untrimmed,** for anything reproducible. "Command:" then the command,
  "Output" then all of it.
- **Fenced blocks as mockups.** Fence the Slack message, the error payload, or the config value
  you want to see, even when it is not code.
- **Narrative debugging, first person,** when the discovery order is the explanation: "While
  testing some endpoints I found that ... After some debugging I found the cause: ..."

## Structural habits

- **Bullets list independent changes. Prose explains a mechanism.** Never bullets for reasoning.
  When a PR does four unrelated things, four bullets. When it does one thing with a cause, prose.
- **Grade severity inline, in prose,** not with labels: "there is a minor issue: ..." then "we
  have a more impactful issue."
- **A terminal "Note:" for an incidental change** the reviewer would otherwise wonder about, kept
  clearly separate from the point of the PR.
- **Strikethrough for dropped scope:** `~~Generate Identicon on creation~~`.
- **An empty body is a legitimate choice.** 56% of his pre-2026 PRs had none. If the title and the
  diff say everything, do not manufacture prose. This does not override a repository template that
  requires sections.

## What the corpus does not license

The 0xsequence repos had no PR template, so the near-absence of headings reflects what was asked
for, not a stated preference. Where a template requires headings, fill them.
