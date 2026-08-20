---
name: writing-design-proposals
description: Use when writing, drafting, or revising an engineering design proposal, technical design doc, RFC, architecture proposal, or decision proposal — and when making one read clearly for a human. Covers the decision-ready argument, source-authority discipline (facts vs recommendations), the layered design + plan/spec structure for larger proposals, and the human-readability standard (simplify don't compress, discursive prose, show-don't-name, format-by-shape). Also for folding review feedback into the canonical proposal.
---

# Writing Design Proposals

## Overview

A proposal is an argument for one decision, written so a human reader can genuinely follow it — not skim it, follow it. Two things have to be true at once:

1. **The argument is decision-ready.** A reader knows what is being decided, why, and by whom, and can say yes or no.
2. **The writing is readable.** Each sentence lands on the first read. The reader is never made to decompress dense text or hold five facts in their head at once.

Most proposals get the first and fail the second. LLM-drafted proposals fail the second badly, because a model optimizes for meaning-per-word, and meaning-per-word is the wrong target for a person.

Read `references/proposal-standard.md` before drafting or revising. It carries the templates, the authority discipline, the readability standard with before/after examples, and the review rubric.

## Route the work

- Use `superpowers:brainstorming` first when the direction is still open.
- Use `superpowers:writing-plans` after the design is approved and you need execution steps.
- Use `gh-workflow` for the PR body that ships the proposal.
- This skill owns proposal reasoning **and** how the proposal reads. The others format or execute; they do not replace this.

## Build the proposal

1. Name the exact decision, who decides it, the concrete problem, the explicit requirements and constraints, and any approval gates.
2. Challenge whether a proposal is even the right artifact. If no decision is waiting, stop.
3. As you work, classify each input as a **supplied fact**, a **verified fact**, an **assumption**, or a **recommendation**. Facts describe today; recommendations describe tomorrow. Never fill a gap with plausible-sounding detail.
4. Draft one recommendation with explicit boundaries, constraints, and non-goals.
5. Include the credible alternatives and say why the recommendation wins.
6. Add risks, reviewers, rollout, and verification only where they change the decision.
7. Follow the host repo's artifact path and naming conventions.

For a proposal too large for one document, use the **layered structure** (see the reference): one human design doc, plus a `plan.md` and `spec.md` per layer.

## Write for humans

The readability standard, in short. The reference has the before/after examples.

- **Concise means simplify, not compress.** When a human asks for "concise," they want fewer ideas per sentence and plainer words — not more meaning crammed into each word. Shorten by cutting ideas and simplifying, never by packing.
- **Be discursive.** Write real sentences with verbs that connect the ideas. Do not drop to telegraphic fragments and leave the reader to reassemble them.
- **Show, don't name.** When a rule is about picking something, structure, or a calculation, paste a short concrete case and mark the answer inline. One worked example beats a paragraph of definition.
- **Pick the format by the shape of the information** (default to prose):
  - **Prose** for reasoning, cause and effect, and walking through a mechanism.
  - **List** for a set of 3–5 peer items, or ordered steps.
  - **Table** only for a grid — 2+ items compared across the *same* columns. At most one table per section, and none where a list works.
  - **Mermaid** only in the human design doc, for a topology or flow you would otherwise describe with arrows in prose (flowchart, sequence, state, ER).
- **Readability is not fluff.** Clear, discursive prose is disambiguation. It costs a little more context but helps a human *and* an LLM executor read it correctly. The only real waste is contentless filler — hedges, restatement, ceremony. Cut that; never cut clarity.
- **Clarity and review are the same muscle.** Writing a rule out plainly, with a worked example, is what exposes its gaps. If you cannot write it clearly, you do not yet understand it.

## Completion checks

- A reader can state the requested decision and who must make it.
- Every current-state claim is a supplied or verified fact; assumptions and recommendations are visibly distinct.
- Every explicit requirement, schedule fact, and approval gate keeps its meaning.
- No sentence needs a second read to parse. No telegraphic fragments, no stacked parentheticals, no term used before it is introduced.
- Every table is a real grid; every diagram earns its place; prose carries the reasoning.
- No stale option, placeholder, or review-history residue survives.
