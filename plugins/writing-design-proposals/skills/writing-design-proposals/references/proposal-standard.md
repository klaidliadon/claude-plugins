# Engineering Design Proposal Standard

Two things make a proposal good: the argument is decision-ready, and the writing
is readable by a human. This standard covers both, and treats them as equally
required.

## Contents

1. Decision contract
2. Authority discipline
3. The layered structure (for large proposals)
4. The readability standard
5. Detail and length
6. Review reconciliation
7. Review rubric
8. Common failures

## 1. Decision contract

A proposal exists to make one decision easier. The opening answers four
questions: What changes? Why now? What decision is waiting? Who must decide or
review it?

Lead with the recommendation, before any history, mechanism, or evidence. A
reader should know what they are being asked to approve before they learn how it
works.

If no decision is waiting, a proposal is the wrong artifact. Stop and write
whatever the situation actually needs — a doc, a ticket, a note.

## 2. Authority discipline

This is the discipline that keeps a proposal honest. Classify every input while
you work. Do not publish the classification itself.

| Class | Meaning | How it appears in the proposal |
| --- | --- | --- |
| Supplied fact | Stated by the user or a designated source | A current-state claim |
| Verified fact | Confirmed in code or an authoritative source | A current-state claim, with evidence where it helps |
| Assumption | Needed but not established | Labeled `Assumption:`, or an open decision |
| Recommendation | New behavior the author proposes | Future-tense design choice |

Use facts to describe today. Use recommendations to describe tomorrow. Do not
fill a gap with plausible architecture — plausible is not established.

When a missing fact affects whether the design even works, make verifying it part
of the decision:

> Assumption: the identity provider supports lookup by normalized email. Verify
> before implementation; if it fails, the retry design changes.

Before drafting, capture every explicit requirement, schedule fact, approval
gate, and non-goal, and preserve its meaning. Mirror each time-bound constraint
as `<event> → <date/window>`:

| Supplied constraint | Faithful proposal language |
| --- | --- |
| `Security review → Thursday` | Security reviews the proposal Thursday |
| `Implementation starts → Friday` | Implementation starts Friday; the rollout date is still open |

`Pilot launches Friday` is not a restatement of `implementation starts Friday` —
it is a different, unsupported milestone. If the recommended plan needs a
different mapping, state the conflict and ask for the change explicitly.

During final review, trace every current-state marker — `existing`, `already`,
`currently`, `remains`, `continues` — back to a supplied or verified fact.
Rewrite anything unsupported as a recommendation, or remove it.

## 3. The layered structure (for large proposals)

A small proposal is one document. A large one — a system with several build
stages that land in sequence — is better as a few files that separate the human
argument from the execution detail.

- **One human design doc.** The argument: recommendation, problem, scope,
  proposed design, alternatives, risks, rollout, locked and open decisions. This
  is what a person reviews. It never opens with file paths or schemas.
- **A `plan.md` per layer.** A short human summary of that layer, then the
  execution steps, each with a verify check. Humans skim it; an LLM works it.
- **A `spec.md` per layer.** The precise contract for that layer — the rules,
  models, and invariants the implementation must satisfy.

The design doc optimizes for understanding. The spec optimizes for unambiguous
execution. Neither optimizes for compression: a compressed spec is *harder* for
an executor to follow, not easier (see §4).

Keep each layer independently reviewable. A reader should be able to approve the
shape of the work from the design doc without reading a single spec.

## 4. The readability standard

The core idea: **an LLM optimizes for meaning per word; a human reads with
limited working memory per sentence.** Meaning-per-word is the wrong target. Text
where every word is load-bearing forces the reader to decompress each sentence
and re-read. That is the failure mode this section exists to prevent.

### Concise means simplify, not compress

When a human asks for something "concise," they are asking you to *simplify while
shortening* — fewer ideas per sentence, plainer words. They are not asking you to
pack more meaning into each word. Shorten by removing ideas and simplifying,
never by compressing.

A few more words that read once beat fewer words read three times.

### Be discursive

Write real sentences, with verbs, that connect the ideas. Do not drop into
telegraphic fragments — a colon standing in for a verb, three facts fused into
one line, a term used before it is introduced. Those save characters and cost
comprehension.

**Before** (dense — four fragments, no verbs, three undefined terms):

> Canonical usage row: one logical payment. Head grouping (`sequence = 0` or no
> payment ID). Monetary fields from the correct leg. Persist canonical ID and
> source IDs.

**After** (discursive, with a worked case):

> A payment can arrive in more than one leg. We bill it once, using the head leg
> — the one with `sequence = 0`, or the row itself if there is no payment ID.
>
> ```
> payment p_9f3 (one logical payment)
>   seq 0  inbound    1,000 USDC   <- head leg: bill from this row
>   seq 1  outbound     998 USDC
> ```
>
> We count `p_9f3` once, take the amount from the head leg, and store both the
> payment ID and the leg IDs so the figure can be traced back to the raw rows.

The second is longer. It is also understood on the first read.

### Show, don't name

When a rule is about picking something, structure, or a calculation, a concrete
case beats a definition. Paste a short example and mark the answer inline.

For a rule with running state, show the state stepping. **Before:**

> `incrementalBrackets`: current-month volume fills ascending brackets, ordered
> by timestamp and ID; month-to-date volume does not reset at a mid-month
> boundary.

**After** — a bracket table and a trace of the running total:

> Volume is priced the way income tax is. Each slice is charged at the bracket it
> lands in as the month's total grows.
>
> ```
> brackets            running total    this tx    charged as
> 0 – 100k   2.0%       0  ->  60k     60k        60k @ 2.0%
> 100k – 500k 1.5%     60k -> 120k     60k        40k @ 2.0%, then 20k @ 1.5%
> 500k +     1.0%     120k -> 160k     40k        40k @ 1.5%
> ```
>
> The running total is month-to-date. A config change mid-month does not reset it
> to zero, so the customer keeps the bracket their volume has earned.

Drawing the table also *exposes the gap*: the moment you write the brackets out,
the obvious question appears — what if the config change also changes the
brackets? Dense prose hides that question; the worked version forces it.

### Pick the format by shape

Default to prose. Escalate only when the shape of the information needs it, and
pick the one that costs the reader the least.

| Format | Use when | Smell it is the wrong choice |
| --- | --- | --- |
| Prose | Reasoning, cause and effect, walking through a mechanism | You are stacking colon-fragments instead of writing verbs |
| List | 3–5 peer items (a set), or ordered steps | A bullet needs a clause tying it to the previous one (that is prose); one bullet is a paragraph |
| Table | 2+ items compared across the *same* columns; lookup or comparison | A two-column key→value with one value per row (that is a list); columns do not apply to every row; you are arguing inside it |
| Mermaid | A topology or flow you would otherwise describe with arrows in prose | It is short and linear (a numbered list reads faster); the diagram takes longer to parse than a sentence |

Rules that hold across a whole proposal:

- **At most one table per section, and none where a list works.**
- **Mermaid only in the human design doc**, never in the layer specs. Use it for
  a flowchart (branching logic), a sequence diagram (actors interacting over
  time), a state diagram (an entity moving between named states), or an ER
  diagram (entity relationships).
- The tie-breaker: if you catch yourself writing arrows in prose ("A → B, which
  branches to C or D, and D loops back to B"), draw it. If it is a straight line,
  do not.

Division of labor between a diagram and an inline example: **mermaid for
structure and relationships; an ASCII code block for a concrete worked instance**
where the reader's eye needs specific values (the selection marker, the trace
table, a dated timeline). Do not diagram a worked example; do not tabulate a
topology.

A dated timeline is the right illustration for anything sequential. **Before:**

> A published config starts a billing interval. The next published config ends
> it. A terminal config closes billing. Suspend does not stop charges. Delete
> requires a terminal config first.

**After:**

> Billing follows a project's published configs, not whether it is currently
> "live." Each published config opens an interval; the next one ends it. A
> terminal config ends billing for good.
>
> ```
> Jan 1   publish config A    -> A's rates bill from here
> Apr 1   publish config B    -> A stops; B bills from here
> Sep 1   publish terminal    -> billing ends; nothing bills after
> ```
>
> Two things follow: suspending a project does not stop billing (the config is
> still open), and you cannot delete a project while it is still billing (publish
> a terminal config first).

### Readability is not fluff

Clear, discursive prose is disambiguation, not padding. Every token you write
occupies an LLM executor's context — there is no silent pass that strips it — so
a readable doc is genuinely larger than a compressed one. But at the size of a
proposal that cost is negligible, and the clarity *helps* the executor: the same
ambiguity that makes a human re-read a dense fragment makes a model guess wrong.

So optimize for readability freely. The only real waste is contentless filler —
hedges, restatement, ceremony ("it is worth noting that…"). Cut that. Never cut
clarity to save tokens.

## 5. Detail and length

- Put the recommendation and the requested decision first, and keep it short.
- One idea per sentence.
- Include implementation detail only where it changes feasibility, risk, cost, or
  ownership. Move exhaustive inventories and matrices after the narrative.
- Omit any section with no decision value. Do not add empty headings or
  ceremonial content.

Length should serve clarity. A proposal is too long when it carries ideas that do
not earn their place — not when it uses enough words to be understood. Cut ideas,
not clarity. High risk does not call for more prose; it calls for sharper
boundaries and explicit gates.

## 6. Review reconciliation

The final proposal is the current decision surface. It is not a meeting
transcript or a changelog. Fold feedback in by status:

| Feedback state | What happens in the proposal |
| --- | --- |
| Accepted | Replace the old design with the decision |
| Rejected | Remove it, or keep a short note under alternatives when the rationale still matters |
| Contested | Keep it as an explicit open decision, with an owner |
| Superseded | Remove the stale text, names, dates, and matrices |

## 7. Review rubric

**Decision.** Can a reader repeat the requested decision and name who decides it?
Does the proposal recommend one design? Does each alternative have a rejection
reason?

**Authority.** Is every current-state claim supplied or verified? Are assumptions
labeled? Are recommendations written as proposed behavior? Does every explicit
requirement, schedule fact, and approval gate keep its meaning?

**Readability.** Does every sentence land on the first read? Any telegraphic
fragments, stacked parentheticals, or terms used before they are introduced? Is
every table a real grid, every diagram earning its place, and the reasoning
carried by prose? Are rules about selection, structure, or calculation shown with
a worked example rather than only named?

**Scope.** Are actors, systems, ownership, and non-goals explicit? Is
implementation detail limited to what affects the decision? Are the relevant
Security, Legal, privacy, data, or operational gates named?

**Revision.** Did accepted feedback replace the stale text? Are contested points
explicit? Are cancelled branches and placeholders gone?

## 8. Common failures

| Failure | Correction |
| --- | --- |
| Meaning-per-word density; each line needs re-reading | Simplify while shortening; be discursive; show a worked case |
| Telegraphic fragments standing in for sentences | Write verbs; connect the ideas |
| A rule named but not shown | Add a short concrete example with the answer marked |
| A table used where a list or prose fits | Reserve tables for same-column grids; one per section |
| A diagram for a straight line, or none for a real topology | Match the illustration to the shape; mermaid in the design doc only |
| Plausible details treated as facts | Label them assumptions or verify them |
| Several options given equal weight | Recommend one and say why |
| The proposal becomes an implementation plan | Keep only the mechanics that affect the decision |
| Review history left inline | Reconcile it into the current design or open decisions |
| Compression to save tokens | Readability is not fluff; cut filler, never clarity |
