# Voice Tells

The second axis of this skill. `readability-standard.md` asks whether a human can follow the text.
This file asks whether it reads like a person with a stake in the subject wrote it.

The two failures are independent. Text can be perfectly clear and still read as machine-generated,
because clarity is about structure and this is about texture.

## Name the defect, not the goal

"Write like a human" is a wish, and it produces nothing repeatable. "Remove the predictable
transitions and cut the closing summary" is an instruction, and it produces exactly that.

So the procedure is diagnostic, never wholesale:

1. Read the text and identify which specific tells are present.
2. Apply only the corrections for those tells.
3. Leave everything else alone.

Rewriting for all eight at once flattens the text into a different kind of sameness. Most drafts
have two or three.

## The eight tells

| Tell | What it looks like | Correction |
| --- | --- | --- |
| Generic opening | A sentence that restates the title, or sets a scene before saying anything | Start at the first real sentence and delete what preceded it |
| Filler and restatement | The same idea in the intro, the body, and the summary | Say it once, in the place it belongs |
| Predictable transitions | "Furthermore", "Moreover", "Additionally", "In today's landscape", "It's worth noting that" | Delete the connective and let the sentence carry its own function |
| Corporate language, inflated claims | "leverage", "robust", "seamless", "significant refactor", "comprehensive solution" | Plain verbs, and claims sized to the evidence you actually have |
| Forced conclusion | "In conclusion", "By following these steps", a paragraph that adds no fact | Stop on the last fact |
| No point of view | Both sides presented evenly, generic advice, no recommendation, no named actor | State the lean and say who has to act |
| Uniform rhythm | Every sentence the same length, every paragraph the same shape | Mix long causal sentences with very short ones; a fragment where it lands |
| Sales pitch | Buzzwords, hype, artificial urgency, benefits addressed to "you" | Confident without selling |

## Worked before-and-after, per tell

### 1. Generic opening

**Before**

> Authentication is a critical component of any modern web application. In this PR, we address
> several important issues in the login flow.
>
> The session token was not being invalidated on logout.

**After**

> The session token was not being invalidated on logout.

The first two sentences carry no fact. The third is the PR.

### 2. Filler and restatement

**Before**

> This change improves cache isolation. The current implementation fails when switching accounts
> because it retrieves cached records associated with a different account. By including the
> account ID in the cache key, we improve cache isolation across accounts.

**After**

> The current implementation fails when switching accounts because it retrieves cached records
> associated with a different account. This PR includes the account ID in the cache key.

"Improves cache isolation" appeared twice, wrapping the one sentence that had content.

### 3. Predictable transitions

**Before**

> The migration adds a unique index. Furthermore, it seeds the new task runners. Additionally, a
> rollback strategy is provided. Moreover, existing records are updated in place.

**After**

> The migration adds a unique index, seeds the new task runners, and updates existing records in
> place. It rolls back cleanly.

Four transitions were standing in for the commas of a single sentence.

### 4. Corporate language and inflated claims

**Before**

> This pull request introduces a significant refactor and expansion of the gas tank adjustment
> system, delivering a robust and flexible provider-based workflow that leverages a unified
> interface for seamless extensibility.

**After**

> Balance adjustments now go through a provider interface, so admin, ecosystem, Stripe, and crypto
> payments share one code path.

"Significant", "robust", "flexible", "seamless", "leverages", "unified" are all doing the work
that four named providers do better.

### 5. Forced conclusion

**Before**

> [...] so the customer keeps the bracket their volume has earned.
>
> In conclusion, this approach provides a more accurate and maintainable billing model that better
> serves both the business and our customers going forward.

**After**

> [...] so the customer keeps the bracket their volume has earned.

The conclusion contained no fact the reader did not already have.

### 6. No point of view

**Before**

> There are several possible approaches. Caching the lifecycle state reduces latency but risks
> staleness, while cascading the check on every call is slower but always correct. Both have
> trade-offs and the right choice depends on your requirements.

**After**

> Cascade the check on every call. It is slower, but it survives an outage of the auth service,
> and a stale cached lifecycle state would let a revoked key keep working. If the latency shows up
> in practice we can revisit, but I would not optimize for it before we see it.

The first version is a survey. The second is an engineer answering the question.

### 7. Uniform rhythm

**Before**

> The topup limit is checked first. The pending transactions are checked second. The function
> returns early in some cases. This causes the pending check to be skipped. The fix reorders the
> two checks.

**After**

> If no topup limit is set, the function returns early before it ever checks for pending
> transactions, so a pending topup can be missed entirely. This PR reorders the two checks.

Five sentences of near-identical length became one long causal sentence and one short one. See
`written-register.md` for the measured version of this rule.

### 8. Sales pitch

**Before**

> Say goodbye to hunting down config values. This powerful new tooling will transform your local
> setup and get you productive in minutes. You will never need to ask a teammate for
> `omsx.env` again.

**After**

> No need to pass `omsx.env` around. Caveat: the shared secret still has to be fetched once on a
> new machine. It should not be an issue since it is a single `make` target.

Confident, specific, and it closes the obvious objection instead of pretending it does not exist.

## Interaction with the readability axis

These corrections can pull against `readability-standard.md` if applied carelessly. The
resolutions:

- **Cutting filler is not compression.** Tell 2 removes restated ideas. It never removes the words
  that make one idea land on the first read. If a rewrite makes a sentence need two passes, it was
  the wrong cut.
- **Varied rhythm is not telegraphic.** Tell 7 asks for a mix that includes long sentences. It is
  not permission for colon-fragments and verbless lines, which the readability axis forbids.
- **A point of view is not hype.** Tell 6 wants a stated lean with a reason. Tell 4 forbids claims
  the evidence does not support. A recommendation you can defend satisfies both.
- **Bullets do not fix uniform rhythm.** Converting five same-length sentences into five
  same-length bullets changes nothing. Bullets are for sets of peer items and ordered steps.

## Review checklist

- Does anything precede the first sentence that carries a fact?
- Is any idea stated more than once?
- Would deleting every "Furthermore" and "It's worth noting" lose anything?
- Is every adjective earning its place, and is every claim sized to the evidence?
- Does the last paragraph add a fact, or does it summarize?
- Is there a lean, and is it clear who has to act?
- Read three consecutive sentences aloud. Are they all the same length?
- Is anything being sold rather than stated?
