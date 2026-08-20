---
name: design-proposal
description: Use when writing, drafting, or revising an engineering design proposal, technical design doc, RFC, architecture proposal, or decision proposal. Covers the decision-ready argument, source-authority discipline (facts vs recommendations), the layered design + plan/spec structure for larger proposals, alternatives, and folding review feedback into the canonical proposal. Delegates prose quality to writing-for-humans.
---

# Design Proposal

## Overview

A proposal is an argument for one decision. A reader must know what is being decided, why, and by whom, and be able to say yes or no.

This skill owns the proposal's **argument and structure**. It does not restate how to write readable prose — that is the `writing-for-humans` skill, which you apply to every part of the proposal.

Read `references/proposal-standard.md` before drafting or revising. It carries the decision contract, the source-authority discipline, the layered structure, and the review rubric.

## Route the work

- Use `superpowers:brainstorming` first when the direction is still open.
- Use `writing-for-humans` for the prose quality of every part — it is the readability standard this skill relies on.
- Use `superpowers:writing-plans` after the design is approved and you need execution steps.
- Use `gh-workflow` for the PR body that ships the proposal.

## Build the proposal

1. Name the exact decision, who decides it, the concrete problem, the explicit requirements and constraints, and any approval gates.
2. Challenge whether a proposal is even the right artifact. If no decision is waiting, stop.
3. As you work, classify each input as a **supplied fact**, a **verified fact**, an **assumption**, or a **recommendation**. Facts describe today; recommendations describe tomorrow. Never fill a gap with plausible-sounding detail.
4. Draft one recommendation with explicit boundaries, constraints, and non-goals.
5. Include the credible alternatives and say why the recommendation wins.
6. Add risks, reviewers, rollout, and verification only where they change the decision.
7. Follow the host repo's artifact path and naming conventions.

## The layered structure (large proposals)

A small proposal is one document. A large one — a system that lands in several stages — is better as a few files: one human **design doc** (the argument), plus a `plan.md` (execution steps with verify checks) and a `spec.md` (the precise contract) per layer. The design doc optimizes for understanding; the spec optimizes for unambiguous execution. See the reference for detail.

## Completion checks

- A reader can state the requested decision and who must make it.
- Every current-state claim is a supplied or verified fact; assumptions and recommendations are visibly distinct.
- Every explicit requirement, schedule fact, and approval gate keeps its meaning.
- One design is recommended, and each alternative has a rejection reason.
- The prose passes `writing-for-humans`: every sentence lands on the first read, tables are real grids, diagrams earn their place.
- No stale option, placeholder, or review-history residue survives.
