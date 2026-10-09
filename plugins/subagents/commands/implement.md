---
description: Scout, plan, critique and implement a task with tiered subagents, stopping at a reviewed diff
argument-hint: "<task>"
---

Run this task as a tiered subagent chain:

$ARGUMENTS

Every dispatch passes `model` explicitly as each step names it. These are explicit choices, not defaults to re-price.

## 1. Scout

Run the `scout` agent with `model: haiku`, passing the task and a thoroughness level. Keep its full output for the next steps.

## 2. Plan

Record the base commit (`git rev-parse HEAD`). Run a planner subagent with `model: opus` and `effort: high`. When the task spans more than one PR, use `model: fable` and say why in one line. Pass it the task and the scout's full output. Tell it:

- Use the `superpowers:writing-plans` skill, and save the plan to `tmp/<topic>/YYYY-MM-DD-plan.md` at the repository root, never under `docs/`.
- Treat the scout's output as a starting map; read the code where the plan depends on it.
- Add these sections to the plan: **Decisions** (what was chosen, the rejected alternatives, and why), **Edge cases**, and **Open questions**.
- Tag every task `worker` (complete spec, one or two files, no design choice left open) or `main` (judgment, integration across files, or business logic with edge cases).
- If anything material is unknown, stop and return the open questions instead of guessing.

If it returns open questions, ask the user, then resume the same planner with the answers.

## 3. Critique

Run the `critic` agent with `model: opus`, passing the plan path, the task and the scout's output. If it reports any 🔴 or 🟡 finding, resume the planner with the findings for one revision, then run the critic once more on the revised plan. Whatever is still open after that goes to the user.

## 4. Approval

Show the user the plan path, its task list with tags, and the critic's last counts and open findings. Stop and wait for an explicit yes. Nothing is implemented before it.

## 5. Implement

Use the `superpowers:subagent-driven-development` skill on the approved plan, with these overrides:

- `worker` tasks: implementer with `model: sonnet`. `main` tasks: implement them yourself.
- Task reviewer: `model: opus`.
- Fix loop: one round, resuming the same implementer. If the re-review still finds a 🔴 or 🟡 issue, take the task over yourself instead of starting round two.

## 6. Hand off

1. Check signatures: `git log --format='%h %G? %s' <base>..HEAD`. Re-sign any commit that does not show `G` while it is unpushed.
2. Run the repository's lint and test targets once on the whole change.
3. Report the commits, the test result, and every finding left open. Stop there: opening the PR and its review pipeline are separate steps the user starts.
