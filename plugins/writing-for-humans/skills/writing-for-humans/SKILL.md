---
name: writing-for-humans
description: Use when writing or revising any human-facing text — a design proposal, PR description, doc, issue, commit body, or message — to make it read clearly for a human. The house readability standard: concise means simplify not compress; discursive prose over telegraphic fragments; show-don't-name with worked examples; pick prose/list/table/diagram by the shape of the information. Other writing skills (design-proposal, pr-authoring) delegate prose quality here.
---

# Writing for Humans

## Overview

This is the house standard for prose a human reader can genuinely follow — not skim, follow. It exists because an LLM optimizes for meaning per word, and meaning-per-word is the wrong target for a person. Text where every word is load-bearing forces the reader to decompress each sentence and read it twice.

**This is an opinionated, house-specific standard, not a general style guide.** It deliberately favors clarity over brevity and it prescribes when to reach for a list, a table, or a diagram. Where a generic writing skill (for example `elements-of-style:writing-clearly-and-concisely`) and this one differ, this one wins for our work.

Read `references/readability-standard.md` for the before/after examples and the format rules. The principles are below.

## The principles

- **Concise means simplify, not compress.** When someone asks for "concise," they want fewer ideas per sentence and plainer words — not more meaning packed into each word. Shorten by cutting ideas and simplifying, never by compressing. A few more words that read once beat fewer words read three times.
- **Be discursive.** Write real sentences, with verbs, that connect the ideas. Do not drop into telegraphic fragments — a colon standing in for a verb, three facts fused into one line, a term used before it is introduced.
- **Show, don't name.** When a rule is about picking something, structure, or a calculation, a concrete case beats a definition. Paste a short example and mark the answer inline. For a rule with running state, show the state stepping through a small trace.
- **Pick the format by the shape of the information.** Default to prose. Use a list for a set of 3–5 peer items or ordered steps. Use a table only for a grid — items compared across the same columns — and at most one per section, never where a list works. Use a diagram (mermaid) only when you would otherwise describe a topology with arrows in prose.
- **Readability is not fluff.** Clear, discursive prose is disambiguation, not padding. It costs a little context but helps a human — and an LLM executor — read it correctly. The only real waste is contentless filler: hedges, restatement, ceremony. Cut that. Never cut clarity to save words.
- **Clarity and review are the same muscle.** Writing a rule out plainly, with a worked example, is what exposes its gaps. If you cannot write it clearly, you do not yet understand it.

## Quick check

- Does every sentence land on the first read?
- Any telegraphic fragments, stacked parentheticals, or terms used before they are introduced?
- Is every table a real grid, every diagram earning its place, and the reasoning carried by prose?
- Is any rule about selection, structure, or calculation shown with a worked example, not only named?
- Is the only thing you cut filler — never clarity?
