#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
export PATH="$DIR/test/stubs:$PATH"

source "$DIR/bin/lib.sh"
export STUB_LOG="$T/log" STUB_GH_DIFF="$T/diff" STUB_GH_PR="$T/pr.json"
echo '{"baseRefName":"main"}' >"$STUB_GH_PR"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
mkdir -p "$T/repo/apps/billing" "$T/repo/.agents"
touch "$T/repo/apps/billing/main.go"
git -C "$T/repo" add apps
git -C "$T/repo" -c commit.gpgsign=false commit -q -m init
git -C "$T/repo" push -q origin HEAD:main 2>/dev/null
PR=https://github.com/o/r/pull/7

reviewers() {
  printf '%s\n' "$@" >"$STUB_GH_DIFF"
  fleet_reviewers "$T/repo" "$PR" | paste -sd, -
}

reviewers_in() {
  local repo="$1"
  shift
  printf '%s\n' "$@" >"$STUB_GH_DIFF"
  fleet_reviewers "$repo" "$PR" | paste -sd, -
}

assert_eq "$(reviewers apps/billing/rpc/session/login.go)" "adversarial,tests"
assert_not_contains "$(cat "$STUB_LOG" 2>/dev/null)" "gh pr diff"

cat >"$T/repo/.agents/fleet.yaml" <<'YAML'
reviewers:
  security: ["apps/*/rpc/session/**", "**/perms/**", "docs/rbac.md"]
  architecture: ["schema/**", "new-dir:apps/*"]
  adversarial: ["**"]
YAML
assert_eq "$(reviewers README.md)" "adversarial,tests"
assert_eq "$(reviewers apps/billing/rpc/session/login.go)" "adversarial,tests,security"
assert_eq "$(reviewers apps/billing/rpc/sessions/login.go)" "adversarial,tests"
assert_eq "$(reviewers perms/x.go)" "adversarial,tests,security"
assert_eq "$(reviewers pkg/a/perms/x.go)" "adversarial,tests,security"
assert_eq "$(reviewers docs/rbac.md)" "adversarial,tests,security"
assert_eq "$(reviewers docs/rbacXmd)" "adversarial,tests"
assert_eq "$(reviewers schema/x.sql docs/rbac.md)" "adversarial,tests,security,architecture"
assert_eq "$(reviewers apps/billing/new.go)" "adversarial,tests"
assert_eq "$(reviewers apps/payouts/main.go)" "adversarial,tests,architecture"
assert_eq "$(reviewers apps/payouts/rpc/deep/x.go)" "adversarial,tests,architecture"
assert_eq "$(reviewers apps/top.go)" "adversarial,tests"
assert_contains "$(cat "$STUB_LOG")" "gh pr diff $PR --name-only"

assert_eq "$(reviewers apps/ledger/rpc.go)" "adversarial,tests,architecture"
git clone -q --branch main "$T/origin.git" "$T/other" 2>/dev/null
mkdir -p "$T/other/apps/ledger"
touch "$T/other/apps/ledger/main.go"
git -C "$T/other" add apps
git -C "$T/other" -c commit.gpgsign=false commit -q -m ledger
stale="$(git -C "$T/repo" rev-parse refs/remotes/origin/main)"
assert_ok git -C "$T/other" push -q origin HEAD:main
assert_eq "$(git --git-dir="$T/origin.git" rev-parse main)" "$(git -C "$T/other" rev-parse HEAD)"
assert_eq "$(git -C "$T/repo" rev-parse refs/remotes/origin/main)" "$stale"
assert_eq "$(reviewers apps/ledger/rpc.go)" "adversarial,tests"
assert_eq "$(git -C "$T/repo" rev-parse refs/remotes/origin/main)" "$(git -C "$T/other" rev-parse HEAD)"

out="$(STUB_GH_FAIL="pr view" fleet_reviewers "$T/repo" "$PR" 2>&1)"
assert_eq "$?" 1; assert_not_contains "$out" "adversarial"
git -C "$T/repo" remote set-url origin "$T/nowhere.git"
out="$(fleet_reviewers "$T/repo" "$PR" 2>&1)"
assert_eq "$?" 1; assert_eq "$out" "fleet_reviewers: cannot fetch origin/main in $T/repo"
git -C "$T/repo" remote set-url origin "$T/origin.git"
echo '{"baseRefName":"gone"}' >"$STUB_GH_PR"
out="$(fleet_reviewers "$T/repo" "$PR" 2>&1)"
assert_eq "$?" 1; assert_eq "$out" "fleet_reviewers: cannot fetch origin/gone in $T/repo"
echo '{"baseRefName":"main"}' >"$STUB_GH_PR"

# The base fetch must advance origin/main even when remote.origin.fetch maps only another branch.
git -C "$T/other" push -q origin HEAD:other 2>/dev/null
git -C "$T/repo" config remote.origin.fetch '+refs/heads/other:refs/remotes/origin/other'
mkdir -p "$T/other/apps/audit"
touch "$T/other/apps/audit/main.go"
git -C "$T/other" add apps
git -C "$T/other" -c commit.gpgsign=false commit -q -m audit
git -C "$T/other" push -q origin HEAD:main 2>/dev/null
assert_eq "$(reviewers apps/audit/rpc.go)" "adversarial,tests"
assert_eq "$(git -C "$T/repo" rev-parse refs/remotes/origin/main)" "$(git -C "$T/other" rev-parse HEAD)"
git -C "$T/repo" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'

cp "$T/repo/.agents/fleet.yaml" "$T/fleet.yaml"
cat >"$T/repo/.agents/fleet.yaml" <<'YAML'
reviewers:
  security: ["**/*pii*", "**/*secret*", "**/*crypto*"]
  tests: ["**"]
YAML
: >"$STUB_LOG"
assert_eq "$(reviewers pkg/pii/model.go)" "adversarial,tests,security"
assert_eq "$(reviewers pkg/crypto/x.go)" "adversarial,tests,security"
assert_eq "$(reviewers apps/a/secrets.go)" "adversarial,tests,security"
assert_eq "$(reviewers pkg/copy/x.go)" "adversarial,tests"
printf 'reviewers:\n  docs: ["docs/a+b.md", "src/?.go", "lib/(x)|y/*.c"]\n' >"$T/repo/.agents/fleet.yaml"
assert_eq "$(reviewers docs/a+b.md)" "adversarial,tests,docs"
assert_eq "$(reviewers docs/aab.md)" "adversarial,tests"
assert_eq "$(reviewers src/a.go)" "adversarial,tests,docs"
assert_eq "$(reviewers src/ab.go src/a/b.go)" "adversarial,tests"
assert_eq "$(reviewers 'lib/(x)|y/z.c')" "adversarial,tests,docs"
assert_eq "$(reviewers lib/x/z.c)" "adversarial,tests"
assert_not_contains "$(cat "$STUB_LOG")" "gh pr view"
out="$(STUB_GH_FAIL="pr diff" fleet_reviewers "$T/repo" "$PR" 2>&1)"
assert_eq "$?" 1; assert_not_contains "$out" "adversarial"
echo 'reviewers: [unclosed' >"$T/repo/.agents/fleet.yaml"
out="$(fleet_reviewers "$T/repo" "$PR" 2>/dev/null)"
assert_eq "$?" 1; assert_eq "$out" ""
cp "$T/fleet.yaml" "$T/repo/.agents/fleet.yaml"

printf 'focus:\n  architecture: "Check the gateway."\n  "it\x27s \\"odd\\"": "quoted"\n' >>"$T/repo/.agents/fleet.yaml"
assert_eq "$(fleet_focus "$T/repo" "it's \"odd\"")" "quoted"
assert_eq "$(fleet_focus "$T/repo" architecture)" "Check the gateway."
assert_eq "$(fleet_focus "$T/repo" security)" ""
assert_eq "$(fleet_focus "$T/nowhere" architecture)" ""

# A reviewer rule may be a map of globs and grep terms; grep terms match only added or removed lines of a saved diff.
cat >"$T/repo/.agents/fleet.yaml" <<'YAML'
reviewers:
  security: {grep: [Password, "x-api-key"]}
  architecture: {globs: ["schema/**"]}
  docs: ["docs/**"]
  data: {globs: ["new-dir:apps/*"], grep: [migration]}
YAML
cat >"$T/grep.diff" <<'DIFF'
diff --git a/pkg/password.go b/pkg/password.go
--- a/pkg/password.go
+++ b/pkg/password.go
@@ -1,3 +1,3 @@
 func check() {
-	old := 1
+	pw := readPASSWORD()
 }
DIFF
cat >"$T/context.diff" <<'DIFF'
diff --git a/pkg/password.go b/pkg/password.go
--- a/pkg/password.go
+++ b/pkg/password.go
@@ -1,3 +1,3 @@
 // password handling
-	a := 1
+	a := 2
DIFF
cat >"$T/schema.diff" <<'DIFF'
diff --git a/schema/x.sql b/schema/x.sql
--- a/schema/x.sql
+++ b/schema/x.sql
@@ -1 +1 @@
--- drop
+-- create
DIFF
for d in grep context; do echo pkg/password.go >"$T/$d.diff.names"; done
echo schema/x.sql >"$T/schema.diff.names"
: >"$STUB_LOG"
assert_eq "$(fleet_reviewers "$T/repo" "$PR" "$T/grep.diff" | paste -sd, -)" "adversarial,tests,security"
assert_eq "$(fleet_reviewers "$T/repo" "$PR" "$T/schema.diff" | paste -sd, -)" "adversarial,tests,architecture"
assert_eq "$(fleet_reviewers "$T/repo" "$PR" "$T/context.diff" | paste -sd, -)" "adversarial,tests"
assert_not_contains "$(cat "$STUB_LOG")" "gh pr diff"
assert_eq "$(reviewers docs/a.md pkg/password.go)" "adversarial,tests,docs"
printf 'diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +0,0 @@\n-send X-API-KEY header\n' >"$T/removed.diff"
echo a >"$T/removed.diff.names"
assert_eq "$(fleet_reviewers "$T/repo" "$PR" "$T/removed.diff" | paste -sd, -)" "adversarial,tests,security"
# Paths come from the names snapshot, so a pure rename, a binary change and a path with a space still match globs.
printf 'diff --git a/docs/old.md b/docs/new.md\nsimilarity index 100%%\nrename from docs/old.md\nrename to docs/new.md\n' >"$T/rename.diff"
echo docs/new.md >"$T/rename.diff.names"
assert_eq "$(fleet_reviewers "$T/repo" "$PR" "$T/rename.diff" | paste -sd, -)" "adversarial,tests,docs"
printf 'diff --git a/schema/a b.png b/schema/a b.png\nBinary files a/schema/a b.png and b/schema/a b.png differ\n' >"$T/binary.diff"
echo 'schema/a b.png' >"$T/binary.diff.names"
assert_eq "$(fleet_reviewers "$T/repo" "$PR" "$T/binary.diff" | paste -sd, -)" "adversarial,tests,architecture"
rm "$T/binary.diff.names"
out="$(fleet_reviewers "$T/repo" "$PR" "$T/binary.diff" 2>&1)"
assert_eq "$?" 1; assert_eq "$out" "fleet_reviewers: no $T/binary.diff.names; save the diff with pr_snapshot"
# One map can carry new-dir globs and grep terms: either selects it.
printf 'diff --git a/pkg/x.go b/pkg/x.go\n--- a/pkg/x.go\n+++ b/pkg/x.go\n@@ -1 +1 @@\n-a\n+run Migration 7\n' >"$T/mig.diff"
echo pkg/x.go >"$T/mig.diff.names"
assert_eq "$(fleet_reviewers "$T/repo" "$PR" "$T/mig.diff" | paste -sd, -)" "adversarial,tests,data"
printf 'diff --git a/apps/fresh/main.go b/apps/fresh/main.go\n--- /dev/null\n+++ b/apps/fresh/main.go\n@@ -0,0 +1 @@\n+package main\n' >"$T/newdir.diff"
echo apps/fresh/main.go >"$T/newdir.diff.names"
assert_eq "$(fleet_reviewers "$T/repo" "$PR" "$T/newdir.diff" | paste -sd, -)" "adversarial,tests,data"
echo apps/billing/x.go >"$T/newdir.diff.names"
assert_eq "$(fleet_reviewers "$T/repo" "$PR" "$T/newdir.diff" | paste -sd, -)" "adversarial,tests"
printf 'reviewers:\n  security: {grep: [secret]}\n' >"$T/repo/.agents/fleet.yaml"
assert_eq "$(reviewers pkg/secret.go)" "adversarial,tests"
cp "$T/fleet.yaml" "$T/repo/.agents/fleet.yaml"

git init -q "$T/cfg"
assert_eq "$(fleet_repo_config "$T/cfg")" ""
mkdir -p "$T/cfg/.agents" "$FLEET_HOME/repos/acme/widgets"
echo 'review_skill: repo-review' >"$T/cfg/.agents/fleet.yaml"
assert_eq "$(fleet_repo_config "$T/cfg")" "$T/cfg/.agents/fleet.yaml"
echo 'review_skill: my-review' >"$FLEET_HOME/repos/acme/widgets.yaml"
assert_eq "$(fleet_repo_config "$T/cfg")" "$T/cfg/.agents/fleet.yaml"
git -C "$T/cfg" remote add origin https://github.com/acme/widgets.git
for url in https://github.com/acme/widgets.git https://github.com/acme/widgets git@github.com:acme/widgets.git \
  git@github.com:acme/widgets ssh://git@github.com/acme/widgets.git; do
  git -C "$T/cfg" remote set-url origin "$url"
  assert_eq "$(fleet_repo_config "$T/cfg")" "$FLEET_HOME/repos/acme/widgets.yaml"
done
assert_eq "$(yaml_get "$(fleet_repo_config "$T/cfg")" .review_skill)" "my-review"
if command -v zsh >/dev/null; then
  assert_eq "$(FLEET_HOME="$FLEET_HOME" zsh -c 'source "$1"; fleet_repo_config "$2"' _ "$DIR/bin/lib.sh" "$T/cfg")" "$FLEET_HOME/repos/acme/widgets.yaml"
fi
for url in https://github.com/acme/widgets/ git@github.com:widgets; do
  git -C "$T/cfg" remote set-url origin "$url"
  assert_eq "$(fleet_repo_config "$T/cfg")" "$T/cfg/.agents/fleet.yaml"
done
git -C "$T/cfg" remote set-url origin git@github.com:acme/other.git
assert_eq "$(fleet_repo_config "$T/cfg")" "$T/cfg/.agents/fleet.yaml"
git -C "$T/cfg" remote set-url origin git@github.com:acme/widgets.git
rm "$T/cfg/.agents/fleet.yaml"
assert_eq "$(fleet_repo_config "$T/cfg")" "$FLEET_HOME/repos/acme/widgets.yaml"
rm "$FLEET_HOME/repos/acme/widgets.yaml"
assert_eq "$(fleet_repo_config "$T/cfg")" ""

printf 'reviewers:\n  architecture: ["**"]\nfocus:\n  architecture: "repo focus"\n' >"$T/cfg/.agents/fleet.yaml"
assert_eq "$(reviewers_in "$T/cfg" pkg/pii/a.go)" "adversarial,tests,architecture"
assert_eq "$(fleet_focus "$T/cfg" architecture)" "repo focus"
printf 'reviewers:\n  security: ["**/pii/**"]\nfocus:\n  security: "my focus"\n' >"$FLEET_HOME/repos/acme/widgets.yaml"
assert_eq "$(reviewers_in "$T/cfg" pkg/pii/a.go)" "adversarial,tests,security"
assert_eq "$(fleet_focus "$T/cfg" security)" "my focus"
assert_eq "$(fleet_focus "$T/cfg" architecture)" ""
rm -r "$T/cfg/.agents" "$FLEET_HOME/repos"
assert_eq "$(reviewers_in "$T/cfg" pkg/pii/a.go)" "adversarial,tests"
assert_eq "$(fleet_focus "$T/cfg" security)" ""

finish_tests reviewers
