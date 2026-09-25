---
name: writing-for-humans
description: Use when writing or revising any human-facing text (a design proposal, PR description, doc, issue, commit body, or message) so it reads clearly and sounds like a person wrote it. Two axes. Readability is the house standard for prose a human can follow, where concise means simplify not compress, discursive prose beats telegraphic fragments, rules are shown with worked examples, and format follows the shape of the information. Voice covers the tells that mark text as machine-written, so reach for it when a draft reads like AI, sounds generic or corporate, needs de-slopping, states no point of view, or has to match the author's own register. Other writing skills (design-proposal, gh-workflow) delegate prose quality here.
---

# Writing for Humans

## Overview

This is the house standard for prose a human reader can genuinely follow - not skim, follow. It exists because an LLM optimizes for meaning per word, and meaning-per-word is the wrong target for a person. Text where every word is load-bearing forces the reader to decompress each sentence and read it twice.

**This is an opinionated, house-specific standard, not a general style guide.** It deliberately favors clarity over brevity and it prescribes when to reach for a list, a table, or a diagram. Where a generic writing skill (for example `elements-of-style:writing-clearly-and-concisely`) and this one differ, this one wins for our work.

The standard has two axes, and they catch different failures. **Readability** asks whether a human can follow the text. **Voice** asks whether it reads like a person with a stake in the subject wrote it. A draft can be perfectly clear and still read as machine-generated, because clarity is structural and voice is textural.

Read the reference for the axis you need:

- `references/readability-standard.md` for the readability before/afters and the format rules.
- `references/voice-tells.md` for the eight machine-writing tells and the correction for each.
- `references/written-register.md` for how Alex structures written artifacts himself, measured from 200 of his pre-2026 PR and issue bodies. Use it for anything going out under his name.

## The principles

Each principle is one line here. The full statement and its worked examples live in `references/readability-standard.md`, in the section named in parentheses.

- **Concise means simplify, not compress.** Cut ideas, never clarity (section 1).
- **Be discursive.** Write real sentences with verbs, not telegraphic fragments (section 2).
- **Show, don't name.** A rule about selection, structure, or calculation gets a worked example (section 3).
- **Pick the format by the shape of the information.** Default to prose, and escalate to a list, table, or diagram only when the shape needs it (section 4).
- **Readability is not fluff.** Cut contentless filler, never clarity (section 5).
- **Clarity and review are the same muscle.** Writing a rule out plainly is what exposes its gaps (section 3).

## The voice tells

Diagnose, never rewrite wholesale: correct only the tells actually present. Each tell is one line here. The full statement and a worked before-and-after for each live in `references/voice-tells.md`.

- **Name the defect, not the goal.** "Cut the closing summary" is repeatable, "write like a human" is not.
- **Start at the first sentence that carries a fact.** (tell 1)
- **Say each idea once.** Restatement is the most common tell. (tell 2)
- **Delete the predictable connectives.** (tell 3)
- **Size every claim to the evidence, and cut corporate vocabulary.** (tell 4)
- **Stop on the last fact.** (tell 5)
- **Have a point of view.** An even survey of both sides is an unanswered question, not neutrality. (tell 6)
- **Vary the rhythm.** (tell 7)
- **Never sell.** (tell 8)

Some of these pull against the readability axis if applied carelessly. `references/voice-tells.md` resolves each conflict under "Interaction with the readability axis".

## Quick check

This is the one review checklist for both axes. The references point here rather than carrying their own.

- Does every sentence land on the first read?
- Any telegraphic fragments, stacked parentheticals, or terms used before they are introduced?
- Is every table a real grid (same columns for every row), and is there at most one per section?
- Does every diagram earn its place, and is the reasoning carried by prose?
- Is any rule about selection, structure, or calculation shown with a worked example, not only named?
- Is the only thing you cut filler - never clarity?
- Does anything precede the first sentence that carries a fact?
- Is any idea stated more than once?
- Would deleting every "Furthermore" and "It's worth noting" lose anything?
- Is every adjective earning its place, and is every claim sized to the evidence?
- Does the last paragraph add a fact, or does it summarize?
- Is there a stated lean with a reason, and is it clear who has to act?
- Read three consecutive sentences aloud. Are they all the same length?
- Is anything being sold rather than stated?
- Any em dashes or en dashes? There should be none.
