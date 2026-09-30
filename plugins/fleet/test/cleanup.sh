#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
export PATH="$DIR/test/stubs:$PATH"

setup() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-test.XXXXXX")"
  export FLEET_HOME="$T/fleet" STUB_LOG="$T/log" STUB_GH_PR="$T/pr.json"
  git init -q --bare "$T/origin.git"
  git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
  git -C "$T/repo" commit -q --allow-empty -m init
  git -C "$T/repo" push -q origin HEAD:main
  git -C "$T/repo" remote set-head origin main 2>/dev/null ||
    git -C "$T/repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  mkdir -p "$T/repo/scripts"
  printf '#!/usr/bin/env bash\necho "$@" > "%s/db-cleanup-called"\n' "$T" >"$T/repo/scripts/worktree-db-cleanup.sh"
  chmod +x "$T/repo/scripts/worktree-db-cleanup.sh"
  git -C "$T/repo" worktree add -q -b feat "$T/wt" origin/main 2>/dev/null
  git -C "$T/wt" commit -q --allow-empty -m work
  git -C "$T/wt" push -q origin feat 2>/dev/null
  export STUB_PRIMARY="$T/repo" STUB_WT_PATH="$T/wt"
  SPEC="$FLEET_HOME/obj/1-task/spec.md"
  mkdir -p "$(dirname "$SPEC")"
  cat >"$SPEC" <<EOF
---
objective: obj
task: 1-task
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

setup; git -C "$T/wt" commit -q --allow-empty -m unpushed; run_cleanup --apply "$SPEC"
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

finish_tests cleanup
