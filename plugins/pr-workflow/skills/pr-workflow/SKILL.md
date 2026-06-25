---
name: pr-workflow
description: Use when authoring a pull request description or body, deciding whether a PR is ready to open, working through the review pipeline that gates opening a PR, formatting code-review findings, handling automated/bot or human review comments, or coordinating chained/dependent PRs that have a required merge or deploy order.
---

# pr-workflow

How to take finished work through review and into a PR: the gated review pipeline, the PR-description format, the rules for chained/dependent PRs, and the code-review output convention. This is reference for *authoring* — branch/commit/destructive-git invariants live in CLAUDE.md and are not repeated here.

## The AI-first review pipeline

**Tier by blast radius, not line count.** Gate the pipeline on risk:
- **Trivial** — docs, config, comments, a single-line change, or generated-file regen with no logic change: tests green + self-review (Step 2) + PR. Skip the dual-agent steps.
- **Standard** — any feature, refactor, new branch, or change touching auth / crypto / data / migrations / money: full pipeline below, no skipping. A 3-line auth change is Standard.

Work through these in order. Don't skip ahead — each step's exit criteria must be met before moving on. Fresh context matters: re-running reviews in a new window catches what a fatigued context misses.

**Step 1 — Implement with tests baked in.**
Build the feature end-to-end with unit, integration, and e2e tests. Tests must be hermetic. Task is not done until all tests pass and exercise real behavior (not mocks all the way down).
*Exit:* feature complete, every test green, behavior verified.

**Step 2 — Self-review (same agent).**
Run `/review` (or `/superpowers:requesting-code-review`). Fix every issue raised. Open a **fresh context** and request review again. Finish with `/security-review` and repeat the loop.
*Exit:* clean pass on a fresh context + clean security review.

**Step 3 — Adversarial review (different agent).**
Switch agents — if Claude wrote it, Codex reviews (and vice versa). Run `/codex:review`, iterate until clean. Then `/codex:adversarial-review`, iterate until findings are addressed.
*Exit:* both review types pass with no outstanding findings.

Worktree paths, broker-state cleanup, job-state location, and polling gotchas live in the `codex-review` skill — invoke it, don't restate them here.

**Step 4 — Open the PR.**
*Prerequisite (one-time per repo):* `/install-github-app` if not yet wired up.
Push and open the PR. This triggers the automated AI review (Claude Code GitHub Action). `gh pr create` only after Step 3 exit criteria — opening a PR triggers automated bot reviews, so don't waste cycles on work that hasn't passed adversarial review yet.
*Exit:* PR opened, automated reviewers triggered.

**Step 5 — Resolve all bot comments.**
Address every automated review comment — fix or justify. See [Author-side](#author-side-handling-review-comments) for the convention.
*Exit:* zero unresolved bot comments across all cycles.

**Step 6 — Human review.**
Architecture, intent, tradeoffs. Address requested changes, re-request review.
*Exit:* human approval — merge and ship.

## Pull request descriptions

PR bodies have two audiences. The top is for humans skimming on GitHub; the bottom is the audit trail for bots, future Claude sessions, and archaeology.

Structure:
- **Top (human, no headers):** one or two prose sentences. The *why*, not the *what*. Examples: "There's a race condition in token refresh — fixed by serializing with a singleflight group." / "Need this because the new auth flow can't tolerate the existing retry behavior."
- **`---` separator** — everything above it is for humans, everything below is for the record.
- **Bottom (structured):** test plan (commands actually run + output, not aspirational checklists), implementation notes, references. Headings are fine down here.

Do not:
- Open with `## Summary` and rehash the diff — the reviewer is about to read it.
- Add `🤖 Generated with Claude Code` footers — pure noise.
- Write test plans as wishlists (`- [ ] Verify edge cases`). Either you ran it (paste the command + result) or you didn't (say so).

Bodies always via `--body-file` / `-F body=@…`, never heredoc — heredoc mangles backticks, fences, `!`, `"`. Don't escape backticks.

## Chained / dependent PRs — the merge order MUST be in the description

When a change spans multiple PRs with a required merge/deploy order (a stack, or a cross-repo chain like schema → issuer → enforcer), the dependency is invisible to anyone who didn't write it. GitHub will let a reviewer merge the trailing PR first and break production. Make the chain explicit on **every** PR in it:

- **First line of the body, before anything else, on any PR that is unsafe to merge until upstream ships:** a blocking callout naming what must land first. Example: `⚠️ BLOCKED: do not merge until <repo>#N is merged AND deployed to all envs. This enforces a contract the issuer does not yet satisfy; merging early 403s every caller.`
- **State the full order and this PR's position in it:** `Stack: go-libs#56 → omsx#1271 (deploy) → this PR.` Note where a *deploy* (not just a merge) is the real gate — cross-repo chains usually gate on the upstream being live, not merged.
- **Never write a claim in the present tense that depends on an unmerged PR.** "the grant shape OMSX emits" reads as "OMSX already emits it" and tells the merger it's safe. Say "will emit (omsx#1271, not yet deployed)" instead. A misleading Notes line is worse than a missing one — it manufactures false confidence.
- Enforcement / breaking-validation PRs are the trailing PR by default. The thing that starts rejecting traffic ships last, after every producer is live.

## Code-review output

- Findings tiered: **Critical** / **Important** / **Suggestion**, each with file:line and a fix snippet.
- On PRs:
  - **Body** — overall take + cross-file/architectural concerns that don't pin to a single line.
  - **Inline comments** — anything pinpointable to file+line(s). Use ` ```suggestion ` blocks when the fix is concrete code so the author can apply with one click.

What to look for:
- **Catch:** transactional gaps, external-before-local violations, blast radius mismatches, ghost fields (schema but no DB), dead-on-arrival code, `http.DefaultClient`, unsalted crypto, N+1 patterns.
- **Praise:** clean separation of concerns, strong table-driven tests, correct reuse of infrastructure, PII handled properly.

## Author-side: handling review comments

- Address every automated/bot comment — fix it or explain why it doesn't apply. Reply `Addressed in <commit-hash>` (or your reasoning). Never silently click "Resolve."
- Resolve threads with `gh api` (audit trail), never the web UI "Resolve conversation" button.
- Each push triggers a new review cycle. Repeat until zero open bot comments before requesting human review.
- Human reviewers focus on architecture, intent, and tradeoffs — bots already caught the rest.
