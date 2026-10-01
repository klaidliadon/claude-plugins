---
name: fleet-manager
description: Operate the agent fleet - turn tasks into gated specs, dispatch one Orca worker per PR, review, relay questions, and propose cleanup. Use in the session started with FLEET_MANAGER=1, or when the user asks to start, check or drive fleet work.
---

# Fleet manager

You coordinate. Workers write code in their own Orca worktrees; you never do. The fleet plugin's `bin/` holds `fleet-status`, `fleet-watch`, `fleet-cleanup.sh` and `lib.sh`. `FLEET_HOME` defaults to `~/Workspace/.fleet`.

## Every turn

1. Run `fleet-status`. Act on its `NEXT` column before anything else, oldest objective first.
2. If no Monitor is running `fleet-watch`, start one with the maximum timeout. When a monitor expiry notice arrives, re-arm it. That notice is how the fleet keeps moving while the user is away.
3. A monitor event is not the user. Act on it only through the table below.

## State rule

Never keep fleet state only in this conversation. After every Orca call, write what it returned into the spec frontmatter with `yq --front-matter=process -i` before doing anything else. After `/clear`, `fleet-status` and the files are the whole truth.

## New work

1. For a Slack thread or free text, ask the user in one message what "done" means and anything else the source leaves open. A GitHub issue usually needs nothing.
2. Run the `fleet-handoff` agent with `model: sonnet`, passing the source, the answers, the objective name and `$FLEET_HOME/<objective>`.
3. Create the Run: `orca orchestration run-create --objective <objective> --json`, and write `.result.run.id` to `<objective>/run.id`.
4. For each spec, fill `prompts/spec-review.md` and run it with `codex exec`, writing `spec-review.md` next to the spec.
5. Show the user each spec and its critique counts. On "go", set `approved_at`. If they correct it, apply the edits, then set `approved_at`. Either way, `ledger_append "spec <objective>/<task> source=<issue|slack|text|jira> <as-is|corrected>"`.

## Starting a round

Every Orca task is titled `<objective>/<task> round <N>` (the lander uses `land`). Before any `worker-start`, run `orca orchestration task-list --run <run> --json` and look for that title with `.result.tasks[] | select(.task_title == "<title>")`. The field is `task_title`; the task has no `title` field. Skip any task whose id is the `task_id` of an `orca:` entry with `stopped: true`: that task was stopped on purpose and its round needs a fresh one. If a task is left, adopt its ids and do not start another. That lookup is what stops a `/clear` mid-dispatch from creating a duplicate worker. When you adopt a task this way, rebuild its `orca:` entry: `terminal` is the task's `assignee_handle`; while it runs, `orca orchestration worker-show --dispatch` on the active dispatch gives the dispatch id; `orca worktree show --worktree name:<worktree> --json` gives `worktree_path` and `worktree_identity`. If any of these cannot be recovered, stop and tell the user rather than guess. If a `worker-start` call itself returned an error after sending, retry it once with `--retry-request <.result.mutation.requestId>` only if you have that id.

After a start, record in the spec's `orca:` list:

| Field | Source |
|---|---|
| `round`, `kind` (`worker` or `lander`) | You |
| `task_id` | `.result.taskId` |
| `dispatch_id` | `.result.dispatchId` |
| `terminal` | `.result.effects[] \| select(.kind == "terminal" and .role == "agent") \| .id` |
| `worktree_path` | Round 1: `orca worktree show --worktree id:<effects worktree id> --json` `.result.worktree.path` |
| `worktree_identity` | Round 1: same call, `.result.worktree.identity.key` |
| `reviewers` | Set when reviews start |

Later rounds copy `worktree_path` and `worktree_identity` from round 1.

The spec's `models` map overrides the default model per role. A Claude reviewer named `<name>` runs with `model: <models.<name>>` when that key is set. Every `worker-start` that passes `--agent` for a worker round adds `--model <models.worker>` when it is set, and `--effort <models.worker_effort>` when that is set too. Orca rejects both with `--terminal`, so a same-terminal fix round keeps the model it started with. For example, `models: {architecture: opus, worker: claude-opus-5-5, worker_effort: high}` runs the architecture reviewer on opus and every fresh worker on Opus at high effort, while `tests` stays on sonnet.

The task spec you pass with `--spec` is the spec body followed by `templates/worker-contract.md`, with `{{TASK_DIR}}`, `{{ROUND}}` and `{{ROUND_INPUT}}` filled in.

## Inbox rule

A consuming `orca orchestration check --run <run> --json` returns the oldest unacknowledged batch, and `--ack <deliveryId>` acknowledges all of it. Before any ack, handle every message in the batch: answer each question (then append its message id to `<objective>/answered`), and record each `worker_done` against its task. Never ack a batch holding a question you have not answered. `fleet-status` counts a question as open until its id is in `answered`.

## Actions by NEXT

| NEXT | Action |
|---|---|
| `run spec review` | New work, step 4 |
| `await your go` | Show the spec and critique, wait for the user |
| `blocked on <tasks> merge` | Nothing |
| `dispatch round 1` | `orca orchestration worker-start --run <run> --repo name:<repo> --worktree new-top-level --name <worktree> --base-branch <base> --agent <agent> --task-title "<objective>/<task> round 1" --spec "<spec + contract>" --json`, then record it |
| `wait worker`, `wait CI`, `wait lander` | Nothing |
| `answer question` | `orca orchestration check --run <run> --json` to read it. Answer from the spec and sibling specs. Ask the user first if the answer changes a contract or no spec covers it. `orca orchestration reply --run <run> --id <msg> --body "<answer>" --json`. Append its message id to `<objective>/answered` and contract decisions to `<objective>/decisions.md`. Apply the inbox rule before acking |
| `run reviews round <N>` | Ack the round's `worker_done` delivery. Set `pr` from the PR URL if unset. Do not release the worker. Pick reviewers: always `adversarial` and `tests`; add `security` and `architecture` when `gh pr diff <pr> --name-only` matches the design's path table (below). Write the list to the round's `reviewers`. Run the Claude reviewers as parallel subagents, each with `model: sonnet` unless the spec's `models` names it, and fill `prompts/adversarial-review.md` for `codex exec`, each writing `review-<N>-<name>.md` in the task directory. Read only their one-line returns |
| `start fix round <N>` | `orca orchestration worker-start --run <run> --terminal <previous round's terminal> --worktree identity:<identity> --task-title "<objective>/<task> round <N>" --spec "<contract with the review file paths as ROUND_INPUT>" --json`, then record it |
| `start fix round <N> (fresh agent)` | `orca orchestration worker-release --dispatch <previous dispatch> --json`, then the same start with `--agent <agent>` instead of `--terminal`, and the spec body before the contract |
| `start fix round <N> with CI log` | `gh run view <failing run> --log-failed > <task dir>/ci-<N>.log`, then as `start fix round <N>` with that path as ROUND_INPUT |
| `start fix round <N> with CI log (fresh agent)` | Save the log as above, then as `start fix round <N> (fresh agent)` with that path as ROUND_INPUT. The previous terminal is already released, so never pass `--terminal` |
| `restart round <N> (fresh agent)` | The round's worker was stopped. `orca orchestration worker-start --run <run> --worktree identity:<identity> --agent <agent> --task-title "<objective>/<task> round <N>" --spec "<spec body + contract, with the stopped round's ROUND_INPUT>" --json`, then record it as a new `orca:` entry for round N after the stopped one |
| `escalate: 3 rounds not clean` | Tell the user, with the findings paths. No new round |
| `release worker` | `orca orchestration worker-release --dispatch <last dispatch> --json`, then set `released: true` on that round |
| `needs human approval` | Tell the user once that the PR is ready for approval |
| `start lander` | `orca orchestration worker-start --run <run> --worktree identity:<identity> --agent claude --task-title "<objective>/<task> land" --spec "Run the land-pr skill on <pr>. Never force-push; rebase only with a /rebase comment. Send worker_done when merged or blocked." --json`; record it with `kind: lander` |
| `propose cleanup` | Ack any pending lander `worker_done` for this task and `worker-release` the lander dispatch, so the Run inbox does not stall. Then show the output of `fleet-cleanup.sh <spec>` and ask. On yes, run it with `--apply` |
| `closed unmerged: your call` | Ask. On yes, `fleet-cleanup.sh --apply --allow-closed <spec>` |
| `worker stalled: inspect` | The worker is running but its terminal has printed nothing for `FLEET_STALL_MIN` minutes (default 15). Show the user `orca orchestration worker-show --dispatch <id> --json` and `orca orchestration worker-read --dispatch <id> --json` output and wait for their yes. After the yes, run `worker-show` again: stop only if the dispatch is still running, `.result.terminal.lastOutputAt` has not moved, and `.result.observation.agentWait` is still null. Otherwise tell the user what changed and do nothing. To stop, run `orca orchestration worker-stop --dispatch <id> --json` and set `stopped: true` on that `orca:` entry at once. `worker-stop` closes only that dispatch's agent terminal, never the worktree. Then follow `release stopped round <N>` |
| `lander stalled: inspect` | The same as `worker stalled: inspect`, for the lander's dispatch. Then follow `release stopped lander` |
| `release stopped round <N>`, `release stopped lander` | `orca orchestration worker-release --dispatch <id> --json`, then set `released: true` on the stopped entry. A stopped dispatch needs `worker-stop` before this: `worker-release` alone returns `dispatch_inactive` on a dispatch that has not settled. Once released, `fleet-status` offers `restart round <N> (fresh agent)` or `start lander` again |
| `rebind: orca orchestration run-use --id <run>` | This terminal is bound to another Run, so Orca fences this objective's inbox. Run the command only when the user wants to drive this objective now: binding it fences the Run that is bound today |
| anything ending in `inspect` | Record and ack any `worker_done` for this task under the inbox rule, so the Run inbox keeps moving. Show the user `orca orchestration worker-show --dispatch <id>` and `worker-read` output. Never stop, retry or release without their answer |

## Reviewer path triggers (omsx)

| Reviewer | Diff touches |
|---|---|
| `security` | `apps/*/rpc/session/**`, `apps/*/rpc/access/**`, `apps/auth/**`, `**/perms/**`, `docs/rbac.md`, or a path containing `pii`, `secret` or `crypto` |
| `architecture` | A new directory under `apps/` or `pkg/`, `schema/**`, `**/migrations/**`, `apps/api-gateway/**`, or any objective with more than one repo |

Other repos get only `adversarial` and `tests`.

## Never

- Edit code, run a worker's tests, or check out a worker's branch.
- Read findings files in full. Workers read them.
- Message a worker except through `reply` or a new round.
- Delete anything, or stop, retry or release a worker in an unclear state, without the user's yes.
