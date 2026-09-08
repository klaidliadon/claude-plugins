---
name: writing-for-humans
description: Use when writing or revising any human-facing text (a design proposal, PR description, doc, issue, commit body, or message) so it reads clearly and sounds like a person wrote it. Two axes. Readability is the house standard for prose a human can follow, where concise means simplify not compress, discursive prose beats telegraphic fragments, rules are shown with worked examples, and format follows the shape of the information. Voice covers the tells that mark text as machine-written, so reach for it when a draft reads like AI, sounds generic or corporate, needs de-slopping, states no point of view, or has to match the author's own register. Other writing skills (design-proposal, pr-authoring) delegate prose quality here.
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

- **Concise means simplify, not compress.** When someone asks for "concise," they want fewer ideas per sentence and plainer words - not more meaning packed into each word. Shorten by cutting ideas and simplifying, never by compressing. A few more words that read once beat fewer words read three times.
- **Be discursive.** Write real sentences, with verbs, that connect the ideas. Do not drop into telegraphic fragments - a colon standing in for a verb, three facts fused into one line, a term used before it is introduced.
- **Show, don't name.** When a rule is about picking something, structure, or a calculation, a concrete case beats a definition. Paste a short example and mark the answer inline. For a rule with running state, show the state stepping through a small trace.
- **Pick the format by the shape of the information.** Default to prose. Use a list for a set of 3-5 peer items or ordered steps. Use a table only for a grid - items compared across the same columns - and at most one per section, never where a list works. Use a diagram (mermaid) only when you would otherwise describe a topology with arrows in prose.
- **Readability is not fluff.** Clear, discursive prose is disambiguation, not padding. It costs a little context but helps a human - and an LLM executor - read it correctly. The only real waste is contentless filler: hedges, restatement, ceremony. Cut that. Never cut clarity to save words.
- **Clarity and review are the same muscle.** Writing a rule out plainly, with a worked example, is what exposes its gaps. If you cannot write it clearly, you do not yet understand it.

## The voice tells

Diagnose, never rewrite wholesale. Identify which tells are actually present, correct those, and leave the rest alone. Most drafts have two or three. `references/voice-tells.md` has a worked before-and-after for each.

- **Name the defect, not the goal.** "Write like a human" produces nothing repeatable. "Cut the closing summary and the four transitions" produces exactly that.
- **Start at the first sentence that carries a fact.** Delete any opening that restates the title or sets a scene.
- **Say each idea once.** Restatement across an intro, a body, and a summary is the most common tell.
- **Delete the predictable connectives.** "Furthermore", "Moreover", "Additionally", "In today's landscape", "It's worth noting that". The sentence carries its own function.
- **Size every claim to the evidence, and cut corporate vocabulary.** "leverage", "robust", "seamless", "comprehensive", "significant refactor". Four named providers beat "flexible and extensible".
- **Stop on the last fact.** If the final paragraph adds no fact, it is ceremony.
- **Have a point of view.** An even survey of both sides is not neutrality, it is an unanswered question. State the lean, give the reason, name who has to act.
- **Vary the rhythm.** A long causal sentence followed by a very short one. Not two dozen uniform ones, and converting them to uniform bullets fixes nothing.
- **Never sell.** No hype, no artificial urgency, no benefits addressed to "you". Close the obvious objection instead of pretending it is not there.

Two of these pull against the readability axis if applied carelessly. Cutting filler is not compression, so never cut the words that make an idea land on the first read. Varied rhythm is not permission for telegraphic fragments, which the readability axis forbids outright.

## Quick check

- Does every sentence land on the first read?
- Any telegraphic fragments, stacked parentheticals, or terms used before they are introduced?
- Is every table a real grid, every diagram earning its place, and the reasoning carried by prose?
- Is any rule about selection, structure, or calculation shown with a worked example, not only named?
- Is the only thing you cut filler - never clarity?
- Does anything precede the first sentence that carries a fact, and does the last paragraph add one?
- Is there a stated lean with a reason, and is it clear who has to act?
- Read three consecutive sentences aloud. Are they all the same length?
- Any em dashes or en dashes? There should be none.
