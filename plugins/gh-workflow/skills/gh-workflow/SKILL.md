---
name: gh-workflow
description: Use when authoring a GitHub pull request or issue body, composing a bug report or proposal issue, deciding whether a PR is ready to open, working through the review pipeline that gates opening a PR, formatting code-review findings, handling automated/bot or human review comments, or coordinating chained/dependent PRs that have a required merge or deploy order.
---

# gh-workflow

How to author GitHub PRs and issues, and take a PR through review: the shared body-composition rules, the PR-description and issue-body formats, the gated review pipeline, chained/dependent-PR rules, and the code-review output convention. This is the canonical home for the body-composition rules — branch/commit/destructive-git invariants live in CLAUDE.md and are not repeated here.

## Body composition (PRs and issues)

PR descriptions and issue bodies share the same composition rules. Write both for an interrupted reader.

- **First screen carries the point.** The change/ask and its impact are clear without scrolling. A waiting action, decision, or blocker is the first visible line — name who must act or what must happen. Nothing waiting → no status boilerplate.
- **Plain English, bullets over prose.** ~15-word sentences, one idea each. Three-plus items → a bullet list. No dense noun stacks, no LLM preamble/recap/pleasantries.
- **No hard-wrapping.** GFM renders a single newline inside a paragraph as a hard `<br>`, so prose wrapped at ~80 cols displays broken mid-sentence. One physical line per paragraph; blank lines separate paragraphs. List items and table rows stay one per line; an intentional multi-line stack is fine — the break is the point there.
- **Bodies via `--body-file` / `-F body=@…`, never heredoc** — heredoc mangles backticks, fences, `!`, `"`. Don't escape backticks. Assemble the file with the Write tool (append boilerplate via `cp` + `printf >>` if needed) — never `printf … "$(cat draft.md)"`: command substitution always escalates the Bash call to a manual permission prompt, no matter how allowlisted the inner commands are.
- **Sourced claims.** A technical assertion (spec behavior, vendor API, RFC) links its authoritative source inline, or says "corroborated, not primary-verified" when the source can't be machine-read.

## PR descriptions

Before opening the PR, read only the first screen. Pretend you are returning after a context switch. It passes when:

- The change and its impact are clear without opening the diff.
- A waiting action, decision, or blocker is the first visible line and names who acts or what must happen.
- With nothing waiting, the body starts at `## Goal` and adds no status boilerplate.
- Mechanism and evidence follow the human summary.

Every PR body:

```markdown
## Goal
<1–3 plain sentences: what this change does and why it matters. A big change ends
with a one-line before→after: "X goes from <old behavior> to <new behavior>.">

## Problem it solves
- <the concrete pain, stated so the reader can picture it happening — never an
  abstraction like "security concerns">
- <another, if any>

## What changes                     <!-- multi-part PRs only; drop for small ones -->
- **<plain-verb outcome>.** <one sentence of how, in plain words>
- **<another moving part>.** <...>
```

- Human sections carry mechanism in plain words — no file paths, type names, or config keys (the diff has those), and no diff rehash or agent footers. Extra sections (`## Notes`: risky migration, deploy step) only when genuinely needed.
- Test evidence, when shown, is real: command + pasted result. Never aspirational checklists (`- [ ] Verify edge cases`).
- Chained/stacked PRs: the blocking callout goes first, above `## Goal` (see below).

## Issue bodies

An issue is a **bug report** or a **proposal**. Both open with a plain summary, then layer precision beneath.

```markdown
<BLUF: 1–3 plain sentences. Bug → what's wrong and its impact. Proposal → the
decision or change you want. This is what a reader skims to decide if it's theirs.>

## Problem / Context
- <the concrete pain, or the current state, stated so a reader can picture it>

## Reproducer            <!-- bug reports -->
<minimal steps or a copy-paste snippet, plus observed vs expected>

## Proposal              <!-- proposals -->
- <the change you want, in plain verbs>

## Open questions        <!-- proposals with calls left to the maintainer -->
- <the decision(s) you want the reader to make>
```

- A bug report without a reproducer is a guess — include minimal repro + observed vs expected.
- A proposal names its judgment calls as **Open questions** so the maintainer can decide, rather than burying or pre-deciding them.
- `Closes #N` / `Refs #N` when the issue relates to an existing one.

## Spec / plan branches — push, don't PR

When the deliverable is a doc, spec, or plan landing on a `docs/...` or `spec/...` branch (or a `tmp/<topic>/` scratch doc being "saved"/"pushed"), push the branch and surface the branch + file URL in chat — then stop. Don't `gh pr create` unprompted: a PR forces review machinery (bots, approvals, conflicts) onto a doc that's still iterating. The PR is opt-in; if one is wanted, it'll be asked for.

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

## Chained / dependent PRs — the merge order MUST be in the description

When a change spans multiple PRs with a required merge/deploy order (a stack, or a cross-repo chain like schema → issuer → enforcer), the dependency is invisible to anyone who didn't write it. GitHub will let a reviewer merge the trailing PR first and break production. Make the chain explicit on **every** PR in it:

- **First visible line of the body on any PR that is unsafe to merge until upstream ships:** a blocking callout naming what must land first. Example: `⚠️ BLOCKED: do not merge until <repo>#N is merged AND deployed to all envs. This enforces a contract the issuer does not yet satisfy; merging early 403s every caller.`
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
- **Verify before replying, cite inline.** A reply that asserts a technical fact (spec behavior, vendor API rules, browser/cookie semantics) gets checked against an authoritative source first — vendor docs, MDN, RFC — and links it in the reply. If the primary source can't be machine-read (JS-rendered docs), say "corroborated, not primary-verified" rather than asserting. Keep the reply short: verdict, commit ref, source link.
- Resolve threads with `gh api` (audit trail), never the web UI "Resolve conversation" button.
- Each push triggers a new review cycle. Repeat until zero open bot comments before requesting human review.
- Human reviewers focus on architecture, intent, and tradeoffs — bots already caught the rest.
