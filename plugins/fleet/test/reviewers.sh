#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
source "$DIR/bin/lib.sh"
export PATH="$DIR/test/stubs:$PATH"

T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-test.XXXXXX")"
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

git clone -q "$T/origin.git" "$T/other" 2>/dev/null
mkdir -p "$T/other/apps/ledger"
touch "$T/other/apps/ledger/main.go"
git -C "$T/other" add apps
git -C "$T/other" -c commit.gpgsign=false commit -q -m ledger
git -C "$T/other" push -q origin HEAD:main 2>/dev/null
assert_eq "$(reviewers apps/ledger/rpc.go)" "adversarial,tests"

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

finish_tests reviewers
