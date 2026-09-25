# Engineering Design Proposal Standard

A proposal is an argument for one decision. This standard covers the argument and its structure. **Prose quality (concise means simplify not compress, discursive sentences, show-don't-name, format-by-shape) lives in the `writing-for-humans` skill. Apply it to every part of the proposal.**

## Contents

1. Decision contract
2. Authority discipline
3. The layered structure (for large proposals)
4. After the decision
5. Detail and decision-relevance
6. Review reconciliation
7. Review rubric
8. Common failures

## 1. Decision contract

A proposal exists to make one decision easier. The opening answers four questions: What changes? Why now? What decision is waiting? Who must decide or review it?

Lead with the recommendation, before any history, mechanism, or evidence. A reader should know what they are being asked to approve before they learn how it works.

If no decision is waiting, a proposal is the wrong artifact. Stop and write whatever the situation actually needs: a doc, a ticket, a note.

When a decision is waiting, weigh whether it earns a standalone document. Six questions decide it (adapted from [Michael Lynch's design-doc guide](https://refactoringenglish.com/excerpts/write-an-effective-design-doc/), which this section and section 5 draw on):

- Will multiple people coordinate work to implement the design?
- Will it take more than three months of full-time work?
- Will the result be hard to change once it is running in production?
- Does it cross team boundaries?
- Are the goals or requirements ambiguous?
- Is there a catastrophic risk, such as a security or legal flaw, that design-time review could prevent?

One yes means a standalone proposal is likely worth writing, and two or more mean it almost certainly is. All noes mean the argument fits in the ticket or the pull request body. The container shrinks; the contract does not: one recommendation, its alternatives, and the authority discipline apply at every size.

Where the proposal names goals, state each as an outcome for users, the team, or the company, never as a mechanism. "Minimize outages related to deploying new app versions" is a goal. "Add Kubernetes to our infrastructure" is a design choice wearing a goal's clothes, and putting it in the goal slot smuggles the decision past the argument.

## 2. Authority discipline

This is the discipline that keeps a proposal honest. Classify every input while you work. Do not publish the classification itself.

| Class | Meaning | How it appears in the proposal |
| --- | --- | --- |
| Supplied fact | Stated by the user or a designated source | A current-state claim |
| Verified fact | Confirmed in code or an authoritative source | A current-state claim, with evidence where it helps |
| Assumption | Needed but not established | Labeled `Assumption:`, or an open decision |
| Recommendation | New behavior the author proposes | Future-tense design choice |

Use facts to describe today. Use recommendations to describe tomorrow. Do not fill a gap with plausible architecture; plausible is not established.

When a missing fact affects whether the design even works, make verifying it part of the decision:

> Assumption: the identity provider supports lookup by normalized email. Verify before implementation; if it fails, the retry design changes.

Before drafting, capture every explicit requirement, schedule fact, approval gate, and non-goal, and preserve its meaning. Mirror each time-bound constraint as `<event> → <date/window>`:

| Supplied constraint | Faithful proposal language |
| --- | --- |
| `Security review → Thursday` | Security reviews the proposal Thursday |
| `Implementation starts → Friday` | Implementation starts Friday; the rollout date is still open |

`Pilot launches Friday` is not a restatement of `implementation starts Friday`; it is a different, unsupported milestone. If the recommended plan needs a different mapping, state the conflict and ask for the change explicitly.

During final review, trace every current-state marker (`existing`, `already`, `currently`, `remains`, `continues`) back to a supplied or verified fact. Rewrite anything unsupported as a recommendation, or remove it.

## 3. The layered structure (for large proposals)

A small proposal is one document. A large one, a system with several build stages that land in sequence, is better as a few files that separate the human argument from the execution detail.

- **One human design doc.** The argument: recommendation, problem, scope, proposed design, alternatives, risks, rollout, locked and open decisions. This is what a person reviews. It never opens with file paths or schemas. Diagrams live here, not in the specs (see `writing-for-humans`).
- **A `plan.md` per layer.** A short human summary of that layer, then the execution steps, each with a verify check. Humans skim it; an LLM works it.
- **A `spec.md` per layer.** The precise contract for that layer: the rules, models, and invariants the implementation must satisfy.

The design doc optimizes for understanding. The spec optimizes for unambiguous execution. Neither optimizes for compression: a compressed spec is *harder* for an executor to follow, not easier.

Keep each layer independently reviewable. A reader should be able to approve the shape of the work from the design doc without reading a single spec.

## 4. After the decision

This applies to any proposal that lands in a repo, not only a layered one. A proposal argues for a decision. A design doc living in the repo describes the system that decision produced, and its readers are people who already accepted it and now need to know how the thing works. Those are different artifacts with the same filename, and the second one is read far more often.

So when the proposal lands, split it. `design.md` states what the system does, in the present tense: the problem in two or three sentences, the solution as statements, the mechanics a reader needs, then limits and open questions. The argument moves to `rationale.md` beside it, linked from the design's footer.

Nothing is thrown away. Rejected alternatives, the evidence behind the choice, and the history of what was tried before are the most expensive things in the document to reconstruct later, and they are also what a reader who just wants to know how the system behaves has to wade through. One entry per decision:

```markdown
## <the decision, as a heading>

**Decision.** One line.
**Alternative.** What else was on the table, and who raised it.
**Evidence.** The numbers or the history, and how they were measured.
**Reversed.** (Only when revisited.) The date, the new decision, and what changed.
```

Entries are append-only. A reversal appends a dated **Reversed.** line to its entry and never rewrites the original, so a later reader can tell a decision was revisited rather than forgotten. A design that rejected no alternative needs no rationale file.

Keep the change-scoped argument out of both. Why this pull request, now, belongs in its body. Why the system is shaped this way belongs in the repo. A review thread copied into either ages badly and nobody updates it.

## 5. Detail and decision-relevance

- Put the recommendation and the requested decision first, and keep it short.
- Include implementation detail only where it changes feasibility, risk, cost, or ownership. Move exhaustive inventories and matrices after the narrative.
- Omit any section with no decision value. Do not add empty headings or ceremonial content.

The test for whether a decision belongs in the proposal is the penalty for being wrong. Choosing the language for a system that will grow to two hundred thousand lines is close to irreversible. Picking a page size for pagination is an afternoon's change, and it does not belong there. The same test ranks dependencies: sweat the storage backend, not the third-party email service you could swap in a day.

When the design is a system that people or other services interact with, ground it in one scenario: a short step-by-step walkthrough of the system in real use. A scenario is show-don't-name at the design level, and it exposes the gaps that a component list hides.

High risk does not call for more prose; it calls for sharper boundaries and explicit gates.

### Operational prompts

For a system that will run in production, walk these prompts while drafting. Write a section only where an answer changes the decision; an unremarkable answer stays out of the doc.

- **Reliability.** What are the objective targets for availability, latency, and scale? If the service goes down, how do you find out? If it gets 100x slower, how do you know?
- **Data.** What sensitive data does it handle, how long is it kept, who can read it, and how is it protected in transit and at rest?
- **Security.** What threats were considered, what is the attack surface, and where are the trust boundaries?
- **Logging.** Which events are recorded, where do they go, how long are they retained, and what must never be logged?
- **Legal.** Which regulatory, contractual, or licensing constraints apply to the design?

## 6. Review reconciliation

The final proposal is the current decision surface. It is not a meeting transcript or a changelog. Fold feedback in by status:

| Feedback state | What happens in the proposal |
| --- | --- |
| Accepted | Replace the old design with the decision |
| Rejected | Remove it, or keep a short note under alternatives when the rationale still matters |
| Contested | Keep it as an explicit open decision, with an owner |
| Superseded | Remove the stale text, names, dates, and matrices |

## 7. Review rubric

**Decision.** Can a reader repeat the requested decision and name who decides it? Does the proposal recommend one design? Does each alternative have a rejection reason? Could a reader who never spoke to the author understand the problem from the opening alone? Is every goal an outcome rather than a mechanism?

**Authority.** Is every current-state claim supplied or verified? Are assumptions labeled? Are recommendations written as proposed behavior? Does every explicit requirement, schedule fact, and approval gate keep its meaning?

**Scope.** Are actors, systems, ownership, and non-goals explicit? Is implementation detail limited to what affects the decision? Are the relevant Security, Legal, privacy, data, or operational gates named, and does every operational section present change the decision?

**Prose.** Run the `writing-for-humans` checklist: every sentence lands on the first read, tables are real grids, diagrams earn their place, and rules about selection or calculation are shown with a worked example.

**Revision.** Did accepted feedback replace the stale text? Are contested points explicit? Are cancelled branches and placeholders gone?

## 8. Common failures

| Failure | Correction |
| --- | --- |
| Plausible details treated as facts | Label them assumptions or verify them |
| Several options given equal weight | Recommend one and say why |
| A design choice stated as a goal | Rewrite the goal as the user, team, or company outcome; the mechanism moves to the design |
| The proposal becomes an implementation plan | Keep only the mechanics that affect the decision |
| Review history left inline | Reconcile it into the current design or open decisions |
| A risk section that lists generic risks | Include only risks that change approval, design, or rollout |
| Dense or telegraphic writing | Apply `writing-for-humans`: simplify, be discursive, show don't name |
