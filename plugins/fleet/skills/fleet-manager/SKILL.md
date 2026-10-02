---
name: fleet-manager
description: Operate the agent fleet - turn tasks into gated specs, dispatch one Orca worker per PR, review, relay questions, and propose cleanup. Use in the session started with FLEET_MANAGER=1, or when the user asks to start, check or drive fleet work.
---

# Fleet manager

You coordinate. Workers write code in their own Orca worktrees; you never do. The fleet plugin's `bin/` holds `fleet-status`, `fleet-watch`, `fleet-cleanup.sh`, `fleet-fill`, `fleet-review-request` and `lib.sh`. `FLEET_HOME` defaults to `~/Workspace/.fleet`.

## Configuration

Optional files. Without any of them, the fleet runs `adversarial` (Codex) and `tests` on every PR, no cleanup hook, and no review requests.

- A repo's `fleet.yaml`: `review_skill` (the skill a review session runs), `reviewers.<name>` (extra reviewers, see below), `focus.<name>` (text appended to that reviewer's prompt) and `cleanup` (a script run as `<script> <worktree> --apply` before worktree removal, with the path relative to the primary checkout). A glob `new-dir:<glob>` matches a directory the PR creates. `fleet_repo_config <repo-path>` picks the file: the user's own `$FLEET_HOME/repos/<owner>/<repo>.yaml` when it exists, with `<owner>/<repo>` read from the `origin` remote, else the committed `<repo>/.agents/fleet.yaml`. The first one found wins and the two are never merged. The personal file lives outside the repo and is never committed, so it suits rules the team has not agreed on.
- A `reviewers.<name>` entry is either a glob list or a map `{globs: [...], grep: [...]}`. A glob matches a changed path. A `grep` term matches an added or removed line of the round's saved diff, case-insensitive and as a fixed string. For example, `security: {globs: ["**/auth/**"], grep: [password]}` adds `security` to a PR that touches `pkg/auth/login.go`, and to one that adds the line `pw := readPassword()` anywhere. A glob list such as `security: ["**/auth/**"]` keeps working unchanged.
- `$FLEET_HOME/config.yaml`, the user's: `adversarial: codex | claude` and `review_requests` (`interval_min`, `sources[]` of `{slack, repos}`, `skip: {authors, already_reviewer}`, and `reactions: {start, done}`, the Slack emoji names added to a request when its review session starts and finishes; no `reactions` means no reactions).

`<repo-path>` below is the repo's primary checkout: `orca repo show --repo name:<repo> --json` `.result.repo.path`. `<plugin>` is this plugin's root, two directories above this skill file; the commands below run from a repo checkout, so always spell out `<plugin>/bin/...`, `<plugin>/prompts/...` and `<plugin>/templates/...`. Source `<plugin>/bin/lib.sh` to call `fleet_repo_config`, `fleet_reviewers`, `fleet_focus` and `fleet_config`.

## Every turn

1. Run `fleet-status`. Act on its `NEXT` column before anything else, oldest objective first.
2. If no Monitor is running `fleet-watch`, start one with the maximum timeout. When a monitor expiry notice arrives, re-arm it. That notice is how the fleet keeps moving while the user is away. When `fleet-watch` prints `idle: waiting on user` and exits, nothing runs and every row waits on the user: re-arm it on the user's next message, never on a timer.
3. A monitor event is not the user. Act on it only through the table below, or the "Review requests" section for `slack: check`.

## State rule

Never keep fleet state only in this conversation. After every Orca call, write what it returned into the spec frontmatter with `yq --front-matter=process -i` before doing anything else. After `/clear`, `fleet-status` and the files are the whole truth.

## Memory

Claude Code keys auto memory by git repository, so every worktree of a repo already reads the primary checkout's memory directory ([docs](https://code.claude.com/docs/en/memory)); no link or setting is needed. Workers treat it as read-only: the worker contract forbids memory writes and asks for `learned:` lines in `worker_done` instead. When a `worker_done` carries `learned:` lines, decide which ones are durable and write those to memory yourself.

## New work

1. For a Slack thread or free text, ask the user in one message what "done" means and anything else the source leaves open. A GitHub issue usually needs nothing.
2. Run the `fleet-handoff` agent with `model: sonnet`, passing the source, the answers, the objective name and `$FLEET_HOME/<objective>`.
3. Create the Run: `orca orchestration run-create --objective <objective> --json`, and write `.result.run.id` to `<objective>/run.id`.
4. For each spec, in `<repo-path>` run `git fetch origin +refs/heads/<base>:refs/remotes/origin/<base>` with the spec's `base`. The explicit destination updates `origin/<base>` even when `remote.origin.fetch` is narrowed, so Codex reads the current base rather than a stale ref. Then fill the prompt and run Codex, which writes `spec-review.md` next to the spec:

   ```sh
   <plugin>/bin/fleet-fill <plugin>/prompts/spec-review.md SPEC_PATH=<task dir>/spec.md SIBLINGS="<other spec paths, or none>" \
     BASE=<base> OUT_PATH=<task dir>/spec-review.md > <task dir>/spec-review.prompt
   codex exec --sandbox workspace-write --add-dir <task dir> -C <repo-path> - < <task dir>/spec-review.prompt
   ```
5. Show the user each spec and its critique counts. On "go", set `approved_at`. If they correct it, apply the edits, then set `approved_at`. Either way, `ledger_append "spec <objective>/<task> source=<issue|slack|text|jira> <as-is|corrected>"`.

## Starting a round

Every Orca task is titled `<objective>/<task> round <N>` (the lander uses `land`). Before any `worker-start`, run `orca orchestration task-list --run <run> --json` and look for that title with `.result.tasks[] | select(.task_title == "<title>")`. The field is `task_title`; the task has no `title` field. Skip any task Orca reports as `blocked`, and any task whose id is the `task_id` of an `orca:` entry with `stopped: true`: that task was stopped on purpose and its round needs a fresh one. If a task is left, adopt its ids and do not start another. That lookup is what stops a `/clear` mid-dispatch from creating a duplicate worker. When you adopt a task this way, rebuild its `orca:` entry: `terminal` is the task's `assignee_handle`; while it runs, `orca orchestration worker-show --dispatch` on the active dispatch gives the dispatch id; `orca worktree show --worktree name:<worktree> --json` gives `worktree_path` and `worktree_identity`. If any of these cannot be recovered, stop and tell the user rather than guess. If a `worker-start` call itself returned an error after sending, retry it once with `--retry-request <.result.mutation.requestId>` only if you have that id.

After a start, record in the spec's `orca:` list:

| Field | Source |
|---|---|
| `round`, `kind` (`worker` or `lander`) | You |
| `task_id` | `.result.taskId` |
| `dispatch_id` | `.result.dispatchId` |
| `terminal` | `.result.effects[] \| select(.kind == "terminal" and .role == "agent") \| .id` |
| `worktree_path` | Round 1: `orca worktree show --worktree id:<effects worktree id> --json` `.result.worktree.path` |
| `worktree_identity` | Round 1: same call, `.result.worktree.identity.key` |
| `reviewers` | Written when reviews start, before any reviewer runs |
| `reviewed_head` | The head `pr_snapshot` prints when reviews start |
| `ci_rerun` | Worker rounds: the PR's `headRefOid` when you reran its failed CI job |
| `pushed_head` | Worker rounds: `gh pr view <pr> --json headRefOid`, read when the round's `worker_done` is acked |

Later rounds copy `worktree_path` and `worktree_identity` from round 1.

The spec's `models` map overrides the default model per role. A Claude reviewer named `<name>` runs with `model: <models.<name>>` when that key is set. Every `worker-start` that passes `--agent` for a worker round adds `--model <models.worker>` when it is set, and `--effort <models.worker_effort>` when that is set too. Orca rejects both with `--terminal`, so a same-terminal fix round keeps the model it started with. For example, `models: {architecture: opus, worker: claude-opus-5-5, worker_effort: high}` runs the architecture reviewer on opus and every fresh worker on Opus at high effort, while `tests` stays on sonnet.

The task spec you pass with `--spec` is the spec body followed by the filled worker contract. Fill it with `<plugin>/bin/fleet-fill <plugin>/templates/worker-contract.md TASK_DIR=<task dir> ROUND=<N> ROUND_INPUT="<input>"`, where `<input>` is `none (round 1)` in round 1 and the findings or CI log paths in a fix round. `fleet-fill` exits 1 and names any placeholder left unfilled; never start a worker on a spec it rejected.

Before any `worker-start` for a review session, look the same way for a task titled `reviews/<task> session` in the reviews Run, and adopt it as above instead of starting another.

## Inbox rule

A consuming `orca orchestration check --run <run> --json` returns the oldest unacknowledged batch, and `--ack <deliveryId>` acknowledges all of it. Before any ack, handle every message in the batch: answer each question (then append its message id to `<objective>/answered`), and record each `worker_done` against its task. For a worker round, recording means setting `pr` from the PR URL in the `worker_done` body if unset, before the ack, then setting the round's `pushed_head` to the PR's `headRefOid` if it has none. Never ack a batch holding a question you have not answered. `fleet-status` counts a question as open until its id is in `answered`.

`fleet-status` cannot see whether a `worker_done` is still unacked. Between a round finishing and you recording its `pr`, it shows `worker done without PR: inspect`: handle the inbox first, and if the batch holds that `worker_done` with a PR URL, record it and the row moves on.

A duplicate `worker_done` for a dispatch that already completed (Orca answers "capability is revoked") is acked and not recorded.

## Actions by NEXT

| NEXT | Action |
|---|---|
| `run spec review` | New work, step 4 |
| `await your go` | Show the spec and critique, wait for the user |
| `blocked on <tasks> merge` | Nothing |
| `dispatch round 1` | In `<repo-path>`, run `git fetch origin +refs/heads/<base>:refs/remotes/origin/<base>` with the spec's `base`, so the worktree does not start from a stale ref. Then `orca orchestration worker-start --run <run> --repo name:<repo> --worktree new-top-level --name <worktree> --base-branch origin/<base> --agent <agent> --task-title "<objective>/<task> round 1" --spec "<spec + contract>" --json`, then record it |
| `wait worker`, `wait CI`, `wait lander` | Nothing |
| `wait review session` | If `session.task_id` is set and `session.reacted_start` is not, add the `start` reaction as "Review requests" step 7.5 says. Otherwise nothing |
| `answer question` | `orca orchestration check --run <run> --json` to read it. Answer from the spec and sibling specs. Ask the user first if the answer changes a contract or no spec covers it. `orca orchestration reply --run <run> --id <msg> --body "<answer>" --json`. Append its message id to `<objective>/answered` and contract decisions to `<objective>/decisions.md`. Apply the inbox rule before acking |
| `run reviews round <N>` | Record and ack the round's `worker_done` under the inbox rule, which sets `pr` and `pushed_head`. Do not release the worker. Source `<plugin>/bin/lib.sh` and run `pr_snapshot <pr> <task dir>/round-<N>.diff`: it saves the diff and prints the head that diff belongs to, retrying once if the head moves mid-capture. Set the round's `reviewed_head` to that head; if it exits 1, run `fleet-status` again. Pick reviewers as "Reviewers" says and write the list to the round's `reviewers` before starting any reviewer, so a crash keeps them for re-review. Run the Claude reviewers as parallel subagents, each with `model: sonnet` unless the spec's `models` names it, and `adversarial` as "Adversarial review" says, each writing `review-<N>-<name>.md` in the task directory. Every reviewer gets `<task dir>/round-<N>.diff` as its diff and never reads the live PR. Read only their one-line returns |
| `start fix round <N>` | Fill the contract with `fleet-fill` as "Starting a round" says, with `ROUND=<N>` and the review file paths as `ROUND_INPUT`. Then `orca orchestration worker-start --run <run> --terminal <previous round's terminal> --worktree identity:<identity> --task-title "<objective>/<task> round <N>" --spec "<filled contract>" --json`, then record it |
| `start fix round <N> (fresh agent)` | `orca orchestration worker-release --dispatch <previous dispatch> --json`, then the same start with `--agent <agent>` instead of `--terminal`, and the spec body before the contract |
| `rerun failed job: <job>` | The PR's first CI failure on this head. `<run>` is the Actions run id in the failing check's link (`gh pr checks <pr> --json name,link`, `/actions/runs/<run>/`). Run `gh run rerun <run> --failed`, then set the latest worker round's `ci_rerun` to the PR's `headRefOid`, then wait. Until the rerun shows up in the PR's checks, a `start fix round <N> with CI log` row can still be the old failure: confirm with `gh run view <run> --json status` before acting on it |
| `start fix round <N> with CI log` | `gh run view <failing run> --log-failed > <task dir>/ci-<N>.log`, then as `start fix round <N>` with that path as ROUND_INPUT |
| `start fix round <N> with CI log (fresh agent)` | Save the log as above, then as `start fix round <N> (fresh agent)` with that path as ROUND_INPUT. The previous terminal is already released, so never pass `--terminal` |
| `restart round <N> (fresh agent)` | The round's worker was stopped. `orca orchestration worker-start --run <run> --worktree identity:<identity> --agent <agent> --task-title "<objective>/<task> round <N>" --spec "<spec body + filled contract, with the stopped round's ROUND_INPUT>" --json`, then record it as a new `orca:` entry for round N after the stopped one |
| `new commits since review: inspect` | The PR head moved after the last review, and the latest worker did not push it. In the worker's `worktree_path`, run `git fetch origin +refs/pull/<n>/head:refs/remotes/origin/pr/<n> +refs/heads/<base>:refs/remotes/origin/<base>`, with `<n>` the PR number. If `git merge-base --is-ancestor <latest reviewed_head> <head>` succeeds, show the user `git log --oneline <latest reviewed_head>..<head>`. Otherwise the branch was force-pushed: say so and show `git range-diff origin/<base>..<latest reviewed_head> origin/<base>..<head>` instead, since that `git log` would be empty or misleading. Offer a re-review round with the same reviewers as the latest worker round. On yes, move each of that round's `review-<N>-<name>.md` files to `review-<N>-<name>.md.prev`, then follow `run reviews round <N>` with the round's recorded `reviewers` instead of picking them again; it records the new `reviewed_head`. On no, set that round's `reviewed_head` to the current head and `ledger_append "unreviewed <objective>/<task> <head> accepted"` |
| `escalate: 3 rounds not clean` | Tell the user, with the findings paths. No new round |
| `release worker` | `orca orchestration worker-release --dispatch <last dispatch> --json`, then set `released: true` on that round |
| `needs human approval` | Tell the user once that the PR is ready for approval |
| `start lander` | Read `gh pr view <pr> --json headRefOid`. If any round has a `reviewed_head` and the head is not the latest one, stop and run `fleet-status` again. Otherwise `orca orchestration worker-start --run <run> --worktree identity:<identity> --agent claude --task-title "<objective>/<task> land" --spec "Run the land-pr skill on <pr>. Merge only with gh pr merge --match-head-commit <head>, so a push after review fails the merge. Never force-push; rebase only with a /rebase comment. Send worker_done when merged or blocked." --json`; record it with `kind: lander` |
| `propose cleanup` | Ack any pending lander `worker_done` for this task and `worker-release` the lander dispatch, so the Run inbox does not stall. Then show the output of `fleet-cleanup.sh <spec>` and ask. On yes, run it with `--apply` |
| `closed unmerged: your call` | Ask. On yes, `fleet-cleanup.sh --apply --allow-closed <spec>` |
| `worker stalled: inspect` | The worker is running but its terminal has printed nothing for `FLEET_STALL_MIN` minutes (default 15). Show the user `orca orchestration worker-show --dispatch <id> --json` and `orca orchestration worker-read --dispatch <id> --json` output and wait for their yes. After the yes, run `worker-show` again: stop only if the dispatch is still running, `.result.terminal.lastOutputAt` has not moved, and `.result.observation.agentWait` is still null. Otherwise tell the user what changed and do nothing. To stop, run `orca orchestration worker-stop --dispatch <id> --json` and set `stopped: true` on that `orca:` entry at once. Orca then reports the task `blocked`, which `fleet-status` reads as stopped, so a session that dies before the write still converges to the release step. `worker-stop` closes only that dispatch's agent terminal, never the worktree. Then follow `release stopped round <N>` |
| `review session stalled: inspect` | The same as `worker stalled: inspect`, for the session's dispatch. After a stop and release, ask the user whether to start a new session (clear `session`) or set `answer: later` |
| `lander stalled: inspect` | The same as `worker stalled: inspect`, for the lander's dispatch. Then follow `release stopped lander` |
| `release stopped round <N>`, `release stopped lander` | `orca orchestration worker-release --dispatch <id> --json`, then set `released: true` on the stopped entry. If the call fails because the dispatch is already released, a previous session released it without recording it: set `released: true` and move on. A stopped dispatch needs `worker-stop` before this: `worker-release` alone returns `dispatch_inactive` on a dispatch that has not settled. Once released, `fleet-status` offers `restart round <N> (fresh agent)` or `start lander` again |
| `rebind: orca orchestration run-use --id <run>` | This terminal is bound to another Run, so Orca fences this objective's inbox. Run the command only when the user wants to drive this objective now: binding it fences the Run that is bound today |
| `ask review` | See "Review requests", step 6. If you already asked about this PR in this conversation and the user has not answered, do nothing |
| `skipped` | The user answered `no` or `later`, or the PR closed before its session started. Set `cleaned_at` so the row leaves the table; the spec stays, so the PR is never asked again |
| `start review session` | See "Review requests", step 7 |
| `done` | The review session sent `worker_done`. Keep its durable `learned:` lines as "Memory" says. Each step below is recorded in `session` as soon as it succeeds, and a step already recorded is skipped, so a restart resumes where it stopped. Record and ack the `worker_done` under the inbox rule. If `session.task_id` is set and `session.reacted_start` is not, add the `start` reaction first, as for `wait review session`. `worker-release` its dispatch and set `session.released: true` (an already-released dispatch counts as done). If `reactions.done` is set, add it with `slack_add_reaction` on `request_channel` and `request_ts` and set `session.reacted_done: true` (`already_reacted` counts as done). Tell the user the verdict and ask before removing the worktree with `orca worktree rm --worktree path:<worktree_path> --json`; on yes, remove it (a missing worktree counts as done), set `session.removed: true`, then set `cleaned_at` |
| anything ending in `inspect` | Record and ack any `worker_done` for this task under the inbox rule, so the Run inbox keeps moving. Show the user `orca orchestration worker-show --dispatch <id>` and `worker-read` output. Never stop, retry or release without their answer |

## Reviewers

`fleet_reviewers <repo-path> <pr> <task dir>/round-<N>.diff` prints one reviewer per line: always `adversarial` and `tests`, plus each reviewer whose `fleet_repo_config` rules match the saved diff's paths or, for `grep` terms, its added and removed lines. Without the diff path it reads `gh pr diff <pr> --name-only` and applies globs only. Fix rounds and review sessions both use it. A `new-dir:` glob fetches the PR's base branch from `origin` in `<repo-path>`, so `origin` must be the PR's base repository; when the fetch fails, `fleet_reviewers` exits 1 and you pick reviewers by hand. Also add `architecture` when the objective has specs in more than one repo. For each Claude reviewer, append `fleet_focus <repo-path> <name>` to its prompt when that prints text.

## Adversarial review

`fleet_config .adversarial` picks the runner: `codex` or empty runs Codex, `claude` runs the same filled prompt as a Claude subagent with `model: opus`. Codex reads untrusted PR content, so it always runs in its own sandbox, never with a flag that turns it off. For round `<N>` of a task, with `<task dir>/round-<N>.diff` saved by `pr_snapshot` as `run reviews round <N>` says:

```sh
touch <objective dir>/decisions.md
<plugin>/bin/fleet-fill <plugin>/prompts/adversarial-review.md PR_URL=<pr> SPEC_PATH=<task dir>/spec.md \
  DIFF_PATH=<task dir>/round-<N>.diff DECISIONS_PATH=<objective dir>/decisions.md \
  OUT_PATH=<task dir>/review-<N>-adversarial.md PREVIOUS="<previous line>" > <task dir>/review-<N>-adversarial.prompt
codex exec --sandbox workspace-write --add-dir <task dir> -C <repo-path> - < <task dir>/review-<N>-adversarial.prompt
```

`<repo-path>` is the primary checkout, never a worker's worktree, so a stray Codex write cannot reach a fix round; the PR's change reaches Codex only through the diff. `<previous line>` is empty in round 1, and later `Previous findings: <task dir>/review-<N-1>-adversarial.md. Mark each item fixed or still open first.` `fleet-fill` exits 1 and names any placeholder left unfilled; never run Codex on a prompt it rejected. A review session takes the same `pr_snapshot` first, and runs the same commands with its own directory as both `<task dir>` and `<objective dir>`, and the repo's primary checkout as `<repo-path>`, never its own worktree.

## Review requests

On `slack: check` from `fleet-watch`, for each `review_requests.sources[]` entry in `config.yaml`:

1. Read the cursor: `<plugin>/bin/fleet-review-request cursor "<source>"`. Empty means first run: look back one `interval_min`.
2. Search the source channel with the Slack MCP search tools for messages after the cursor ts that ask for a PR review and link a GitHub PR in one of the source's `repos`. Skip messages from the user themselves.
3. For each match, run `<plugin>/bin/fleet-review-request add "<source>" <pr-url> <requester> <message permalink> <message time, ISO 8601> <channel id> <message ts>`. It applies the repo filter, deduplicates by PR (one spec per `<owner>+<repo>+<n>`, cleaned or not), and applies `skip.authors` (PR author) and `skip.already_reviewer` (the `gh` user already reviewed). It prints `created <spec>` or `skip <url>: <reason>`. Exit 1 means it failed or another add holds the lock: stop and do not move the cursor.
4. Write the cursor only after every match is processed: `<plugin>/bin/fleet-review-request cursor "<source>" <newest message ts seen>`. A crash before this re-reads the same messages, and dedup makes that harmless.
5. Run `<plugin>/bin/fleet-review-request run`, which prints the reviews Run id. When `$FLEET_HOME/reviews/run.id` is missing, it takes the lock `$FLEET_HOME/reviews/.run.lock` (stale after `FLEET_LOCK_TTL` seconds, default 300) and reads `run.id` again; a creator that finds it reuses it. Otherwise it adopts the oldest Run whose objective is exactly `reviews <FLEET_HOME>` from `orca orchestration run-list`, warning when there is more than one, and only when there is none runs `run-create`. It writes `run.id` before it releases the lock, so two managers on one `FLEET_HOME`, or a session that dies after the create, still end up with one Run. Exit 1 means Orca failed: tell the user and stop.
6. Ask the user once, in one message, about every spec with NEXT `ask review`: PR, title, requester, request link. Write each answer to `answer` (`yes`, `no` or `later`).
7. For each `yes`, in order, skipping any step already recorded:
   1. `gh pr view <pr> --json state`. If the PR is no longer open, set `answer: closed` (NEXT becomes `skipped`) and stop.
   2. Resolve the repo from `repo_slug`: `orca repo list --json` `.result.repos[] | select((.gitRemoteIdentity.canonicalKey | ascii_downcase) == ("github.com/" + <repo_slug> | ascii_downcase))`. Its `id` is the selector and its `path` is `<repo-path>`. If none or several match, tell the user and stop.
   3. Fill the session spec: `<plugin>/bin/fleet-fill <plugin>/templates/review-session.md PR=<pr> REQUEST_LINK=<request_link> REPO_PATH=<repo-path> REVIEW_SKILL=<yaml_get "$(fleet_repo_config <repo-path>)" .review_skill, or none> REVIEWERS="<fleet_reviewers output, comma-separated>" FOCUS="<each non-empty fleet_focus as name: text, or none>" TASK_DIR=<spec dir>`.
   4. Look for a task titled `reviews/<task> session` in the reviews Run and adopt it as "Starting a round" says; start a new one only when there is none. To start it on a fresh worktree off the PR's base, read `<base>` from `gh pr view <pr> --json baseRefName`, run `git fetch origin +refs/heads/<base>:refs/remotes/origin/<base>` in `<repo-path>`, then `orca orchestration worker-start --run <reviews run> --repo id:<repo id> --worktree new-top-level --name review-<task> --base-branch origin/<base> --setup skip --agent claude --task-title "reviews/<task> session" --spec "<filled spec>" --json`. Record `session.task_id`, `session.dispatch_id`, `session.terminal` and `session.worktree_path` as for a worker round.
   5. If `reactions.start` is set, add it with `slack_add_reaction` on `request_channel` and `request_ts` (`already_reacted` counts as done), then set `session.reacted_start: true`.

No `slack: check` means `config.yaml` has no sources, and no review requests run.

## Never

- Edit code, run a worker's tests, or check out a worker's branch.
- Read findings files in full. Workers read them.
- Message a worker except through `reply` or a new round.
- Delete anything, or stop, retry or release a worker in an unclear state, without the user's yes.
