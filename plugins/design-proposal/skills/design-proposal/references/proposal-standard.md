# Engineering Design Proposal Standard

A proposal is an argument for one decision. This standard covers the argument and
its structure. **Prose quality — concise means simplify not compress, discursive
sentences, show-don't-name, format-by-shape — lives in the `writing-for-humans`
skill. Apply it to every part of the proposal.**

## Contents

1. Decision contract
2. Authority discipline
3. The layered structure (for large proposals)
4. Detail and decision-relevance
5. Review reconciliation
6. Review rubric
7. Common failures

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
  is what a person reviews. It never opens with file paths or schemas. Diagrams
  live here, not in the specs (see `writing-for-humans`).
- **A `plan.md` per layer.** A short human summary of that layer, then the
  execution steps, each with a verify check. Humans skim it; an LLM works it.
- **A `spec.md` per layer.** The precise contract for that layer — the rules,
  models, and invariants the implementation must satisfy.

The design doc optimizes for understanding. The spec optimizes for unambiguous
execution. Neither optimizes for compression: a compressed spec is *harder* for
an executor to follow, not easier.

Keep each layer independently reviewable. A reader should be able to approve the
shape of the work from the design doc without reading a single spec.

## 4. Detail and decision-relevance

- Put the recommendation and the requested decision first, and keep it short.
- Include implementation detail only where it changes feasibility, risk, cost, or
  ownership. Move exhaustive inventories and matrices after the narrative.
- Omit any section with no decision value. Do not add empty headings or
  ceremonial content.

High risk does not call for more prose; it calls for sharper boundaries and
explicit gates.

## 5. Review reconciliation

The final proposal is the current decision surface. It is not a meeting
transcript or a changelog. Fold feedback in by status:

| Feedback state | What happens in the proposal |
| --- | --- |
| Accepted | Replace the old design with the decision |
| Rejected | Remove it, or keep a short note under alternatives when the rationale still matters |
| Contested | Keep it as an explicit open decision, with an owner |
| Superseded | Remove the stale text, names, dates, and matrices |

## 6. Review rubric

**Decision.** Can a reader repeat the requested decision and name who decides it?
Does the proposal recommend one design? Does each alternative have a rejection
reason?

**Authority.** Is every current-state claim supplied or verified? Are assumptions
labeled? Are recommendations written as proposed behavior? Does every explicit
requirement, schedule fact, and approval gate keep its meaning?

**Scope.** Are actors, systems, ownership, and non-goals explicit? Is
implementation detail limited to what affects the decision? Are the relevant
Security, Legal, privacy, data, or operational gates named?

**Prose.** Run the `writing-for-humans` checklist: every sentence lands on the
first read, tables are real grids, diagrams earn their place, and rules about
selection or calculation are shown with a worked example.

**Revision.** Did accepted feedback replace the stale text? Are contested points
explicit? Are cancelled branches and placeholders gone?

## 7. Common failures

| Failure | Correction |
| --- | --- |
| Plausible details treated as facts | Label them assumptions or verify them |
| Several options given equal weight | Recommend one and say why |
| The proposal becomes an implementation plan | Keep only the mechanics that affect the decision |
| Review history left inline | Reconcile it into the current design or open decisions |
| A risk section that lists generic risks | Include only risks that change approval, design, or rollout |
| Dense or telegraphic writing | Apply `writing-for-humans` — simplify, be discursive, show don't name |
