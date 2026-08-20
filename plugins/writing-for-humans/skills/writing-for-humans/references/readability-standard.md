# The Readability Standard

The house standard for prose a human reader can genuinely follow. This is the depth behind the principles in `SKILL.md`: the before/after examples, the format rules, and the review checklist.

The core idea: **an LLM optimizes for meaning per word; a human reads with limited working memory per sentence.** Meaning-per-word is the wrong target. Text where every word is load-bearing forces the reader to decompress each sentence and re-read. Everything here exists to prevent that.

## 1. Concise means simplify, not compress

When someone asks for "concise," they are asking you to *simplify while shortening* — fewer ideas per sentence, plainer words. They are not asking you to pack more meaning into each word. Shorten by removing ideas and simplifying, never by compressing.

A few more words that read once beat fewer words read three times.

## 2. Be discursive

Write real sentences, with verbs, that connect the ideas. Do not drop into telegraphic fragments — a colon standing in for a verb, three facts fused into one line, a term used before it is introduced. Those save characters and cost comprehension.

**Before** (dense — four fragments, no verbs, three undefined terms):

> Canonical usage row: one logical payment. Head grouping (`sequence = 0` or no payment ID). Monetary fields from the correct leg. Persist canonical ID and source IDs.

**After** (discursive, with a worked case):

> A payment can arrive in more than one leg. We bill it once, using the head leg — the one with `sequence = 0`, or the row itself if there is no payment ID.
>
> ```
> payment p_9f3 (one logical payment)
>   seq 0  inbound    1,000 USDC   <- head leg: bill from this row
>   seq 1  outbound     998 USDC
> ```
>
> We count `p_9f3` once, take the amount from the head leg, and store both the payment ID and the leg IDs so the figure can be traced back to the raw rows.

The second is longer. It is also understood on the first read.

## 3. Show, don't name

When a rule is about picking something, structure, or a calculation, a concrete case beats a definition. Paste a short example and mark the answer inline.

For a rule with running state, show the state stepping. **Before:**

> `incrementalBrackets`: current-month volume fills ascending brackets, ordered by timestamp and ID; month-to-date volume does not reset at a mid-month boundary.

**After** — a bracket table and a trace of the running total:

> Volume is priced the way income tax is. Each slice is charged at the bracket it lands in as the month's total grows.
>
> ```
> brackets             running total    this tx    charged as
> 0 – 100k    2.0%       0  ->  60k     60k        60k @ 2.0%
> 100k – 500k 1.5%      60k -> 120k     60k        40k @ 2.0%, then 20k @ 1.5%
> 500k +      1.0%     120k -> 160k     40k        40k @ 1.5%
> ```
>
> The running total is month-to-date. A config change mid-month does not reset it to zero, so the customer keeps the bracket their volume has earned.

Drawing the table also *exposes the gap*: the moment you write the brackets out, the obvious question appears — what if the config change also changes the brackets? Dense prose hides that question; the worked version forces it. This is why clear writing and good review are the same muscle.

## 4. Pick the format by shape

Default to prose. Escalate only when the shape of the information needs it, and pick the one that costs the reader the least.

| Format | Use when | Smell it is the wrong choice |
| --- | --- | --- |
| Prose | Reasoning, cause and effect, walking through a mechanism | You are stacking colon-fragments instead of writing verbs |
| List | 3–5 peer items (a set), or ordered steps | A bullet needs a clause tying it to the previous one (that is prose); one bullet is a paragraph |
| Table | 2+ items compared across the *same* columns; lookup or comparison | A two-column key→value with one value per row (that is a list); columns do not apply to every row; you are arguing inside it |
| Diagram (mermaid) | A topology or flow you would otherwise describe with arrows in prose | It is short and linear (a numbered list reads faster); the diagram takes longer to parse than a sentence |

Rules that hold across a whole document:

- **At most one table per section, and none where a list works.**
- **Diagrams belong in the human-facing document, not in machine-executable specs.** Use a flowchart for branching logic, a sequence diagram for actors interacting over time, a state diagram for an entity moving between named states, an ER diagram for entity relationships.
- The tie-breaker: if you catch yourself writing arrows in prose ("A → B, which branches to C or D, and D loops back to B"), draw it. If it is a straight line, do not.

Division of labor between a diagram and an inline example: **a diagram for structure and relationships; an ASCII code block for a concrete worked instance** where the reader's eye needs specific values (the selection marker, the trace table, a dated timeline). Do not diagram a worked example; do not tabulate a topology.

A dated timeline is the right illustration for anything sequential. **Before:**

> A published config starts a billing interval. The next published config ends it. A terminal config closes billing. Suspend does not stop charges. Delete requires a terminal config first.

**After:**

> Billing follows a project's published configs, not whether it is currently "live." Each published config opens an interval; the next one ends it. A terminal config ends billing for good.
>
> ```
> Jan 1   publish config A    -> A's rates bill from here
> Apr 1   publish config B    -> A stops; B bills from here
> Sep 1   publish terminal    -> billing ends; nothing bills after
> ```
>
> Two things follow: suspending a project does not stop billing (the config is still open), and you cannot delete a project while it is still billing (publish a terminal config first).

## 5. Readability is not fluff

Clear, discursive prose is disambiguation, not padding. Every token you write occupies an LLM executor's context — there is no silent pass that strips it — so a readable document is genuinely larger than a compressed one. But at the size of a proposal or a PR description that cost is negligible, and the clarity *helps* the executor: the same ambiguity that makes a human re-read a dense fragment makes a model guess wrong.

So optimize for readability freely. The only real waste is contentless filler — hedges, restatement, ceremony ("it is worth noting that…"). Cut that. Never cut clarity to save tokens.

Length should serve clarity. Text is too long when it carries ideas that do not earn their place — not when it uses enough words to be understood. Cut ideas, not clarity.

## 6. Review checklist

- Does every sentence land on the first read?
- Any telegraphic fragments, stacked parentheticals, or terms used before they are introduced?
- Is every table a real grid (same columns for every row), and is there at most one per section?
- Does every diagram earn its place, and is the reasoning carried by prose?
- Is any rule about selection, structure, or calculation shown with a worked example, not only named?
- Is the only thing cut filler — never clarity?

## 7. Common failures

| Failure | Correction |
| --- | --- |
| Meaning-per-word density; each line needs re-reading | Simplify while shortening; be discursive; show a worked case |
| Telegraphic fragments standing in for sentences | Write verbs; connect the ideas |
| A rule named but not shown | Add a short concrete example with the answer marked |
| A table used where a list or prose fits | Reserve tables for same-column grids; one per section |
| A diagram for a straight line, or none for a real topology | Match the illustration to the shape |
| Compression to save tokens | Readability is not fluff; cut filler, never clarity |
