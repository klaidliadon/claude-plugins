#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
export PATH="$DIR/test/stubs:$PATH"

setup() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-test.XXXXXX")"
  export FLEET_HOME="$T/fleet" STUB_LOG="$T/log" STUB_GH_PR="$T/pr.json"
  git init -q --bare "$T/origin.git"
  git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
  git -C "$T/repo" -c commit.gpgsign=false commit -q --allow-empty -m init
  git -C "$T/repo" push -q origin HEAD:main
  git -C "$T/repo" remote set-head origin main 2>/dev/null ||
    git -C "$T/repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  mkdir -p "$T/repo/scripts"
  printf '#!/usr/bin/env bash\necho "$@" > "%s/db-cleanup-called"\n' "$T" >"$T/repo/scripts/worktree-db-cleanup.sh"
  chmod +x "$T/repo/scripts/worktree-db-cleanup.sh"
  mkdir -p "$T/repo/.agents"
  echo 'cleanup: scripts/worktree-db-cleanup.sh' >"$T/repo/.agents/fleet.yaml"
  git -C "$T/repo" worktree add -q -b feat "$T/wt" origin/main 2>/dev/null
  echo work >"$T/wt/work.txt"
  git -C "$T/wt" add work.txt
  git -C "$T/wt" -c commit.gpgsign=false commit -q -m work
  git -C "$T/wt" push -q origin feat 2>/dev/null
  export STUB_PRIMARY="$T/repo" STUB_WT_PATH="$T/wt"
  SPEC="$FLEET_HOME/obj/1-task/spec.md"
  mkdir -p "$(dirname "$SPEC")"
  cat >"$SPEC" <<EOF
---
objective: obj
task: 1-task
repo: app
pr: https://github.com/o/r/pull/7
orca:
  - round: 1
    kind: worker
    worktree_identity: wt-id
    worktree_path: $T/wt
---
body
EOF
  pr_json MERGED "$(git -C "$T/wt" rev-parse HEAD)"
}

pr_json() {
  printf '{"state":"%s","headRefOid":"%s","headRefName":"feat"}' "$1" "$2" >"$STUB_GH_PR"
}

run_cleanup() {
  OUT="$("$DIR/bin/fleet-cleanup.sh" "$@" 2>&1)"
  RC=$?
}

setup; pr_json OPEN "$(git -C "$T/wt" rev-parse HEAD)"; run_cleanup --apply "$SPEC"
assert_eq "$RC" 1; assert_contains "$OUT" "refuse: PR is OPEN"

setup; pr_json CLOSED "$(git -C "$T/wt" rev-parse HEAD)"; run_cleanup --apply "$SPEC"
assert_eq "$RC" 1; assert_contains "$OUT" "refuse: PR is CLOSED"

setup; touch "$T/wt/dirty"; run_cleanup --apply "$SPEC"
assert_eq "$RC" 1; assert_contains "$OUT" "refuse: worktree is dirty"

setup; echo more >>"$T/wt/work.txt"; git -C "$T/wt" -c commit.gpgsign=false commit -q -am unpushed; run_cleanup --apply "$SPEC"
assert_eq "$RC" 1; assert_contains "$OUT" "refuse: HEAD is not the PR head"

setup; yq --front-matter=process -i ".orca[0].worktree_path = \"$T/repo\"" "$SPEC"; run_cleanup --apply "$SPEC"
assert_eq "$RC" 1; assert_contains "$OUT" "refuse: target is the primary checkout"

setup; git -C "$T/repo" checkout -q --detach; git -C "$T/wt" checkout -q main 2>/dev/null
pr_json MERGED "$(git -C "$T/wt" rev-parse HEAD)"; run_cleanup --apply "$SPEC"
assert_eq "$RC" 1; assert_contains "$OUT" "refuse: branch main is the default branch"

setup; run_cleanup "$SPEC"
assert_eq "$RC" 0; assert_contains "$OUT" "dry run"
assert_ok test -d "$T/wt"; assert_fail test -f "$T/db-cleanup-called"

setup; run_cleanup --apply "$SPEC"
assert_eq "$RC" 0
assert_ok test -f "$T/db-cleanup-called"
assert_contains "$(cat "$STUB_LOG")" "orca worktree rm --worktree identity:wt-id"
assert_fail test -d "$T/wt"
assert_fail git -C "$T/repo" show-ref --verify --quiet refs/heads/feat
assert_fail git -C "$T/repo" ls-remote --exit-code --heads origin feat
assert_ok test -n "$(yq --front-matter=extract '.cleaned_at' "$SPEC" | grep -v null)"
assert_contains "$(cat "$FLEET_HOME/ledger.md")" "cleaned obj/1-task"

setup; pr_json CLOSED "$(git -C "$T/wt" rev-parse HEAD)"; run_cleanup --apply --allow-closed "$SPEC"
assert_eq "$RC" 0

setup; STUB_WT_SHOW_PATH="/elsewhere" run_cleanup --apply "$SPEC"
assert_eq "$RC" 1; assert_contains "$OUT" "refuse: identity wt-id is not $T/wt"

setup; printf '{"state":"MERGED","headRefOid":"%s","headRefName":"other"}' "$(git -C "$T/wt" rev-parse HEAD)" >"$STUB_GH_PR"; run_cleanup --apply "$SPEC"
assert_eq "$RC" 1; assert_contains "$OUT" "refuse: branch feat is not the PR head branch other"

setup
git clone -q "$T/origin.git" "$T/other" 2>/dev/null
git -C "$T/other" checkout -q main
git -C "$T/other" -c commit.gpgsign=false commit -q --allow-empty -m advance
git -C "$T/other" push -q origin main 2>/dev/null
git -C "$T/other" checkout -q -b rebased
git -C "$T/other" -c commit.gpgsign=false cherry-pick "$(git -C "$T/wt" rev-parse HEAD)" >/dev/null 2>&1
git -C "$T/other" push -q -f origin rebased:feat 2>/dev/null
pr_json MERGED "$(git -C "$T/other" rev-parse HEAD)"; run_cleanup --apply "$SPEC"
assert_eq "$RC" 0; assert_contains "$OUT" "cleaned obj/1-task"

setup; run_cleanup "$SPEC"
assert_contains "$OUT" "/repo/scripts/worktree-db-cleanup.sh $T/wt --apply"

setup; rm "$T/repo/.agents/fleet.yaml"; run_cleanup "$SPEC"
assert_eq "$RC" 0; assert_not_contains "$OUT" "worktree-db-cleanup"
run_cleanup --apply "$SPEC"
assert_eq "$RC" 0; assert_fail test -f "$T/db-cleanup-called"; assert_fail test -d "$T/wt"

setup; echo 'review_skill: review' >"$T/repo/.agents/fleet.yaml"; run_cleanup --apply "$SPEC"
assert_eq "$RC" 0; assert_fail test -f "$T/db-cleanup-called"

setup; echo 'cleanup: scripts/missing.sh' >"$T/repo/.agents/fleet.yaml"; run_cleanup "$SPEC"
assert_eq "$RC" 1; assert_contains "$OUT" "refuse: cleanup hook scripts/missing.sh is not executable"

setup; chmod -x "$T/repo/scripts/worktree-db-cleanup.sh"; run_cleanup --apply "$SPEC"
assert_eq "$RC" 1; assert_contains "$OUT" "refuse: cleanup hook scripts/worktree-db-cleanup.sh is not executable"
assert_ok test -d "$T/wt"

setup; printf '#!/usr/bin/env bash\nexit 3\n' >"$T/repo/scripts/worktree-db-cleanup.sh"; run_cleanup --apply "$SPEC"
assert_eq "$RC" 1; assert_contains "$OUT" "refuse: cleanup hook scripts/worktree-db-cleanup.sh failed"
assert_ok test -d "$T/wt"; assert_ok git -C "$T/repo" show-ref --verify --quiet refs/heads/feat
assert_not_contains "$(cat "$STUB_LOG")" "worktree rm"

finish_tests cleanup
