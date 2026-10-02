#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

usage="usage: fleet-cleanup.sh [--apply] [--allow-closed] <spec.md>"
apply=0 allow_closed=0
while [ $# -gt 1 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --allow-closed) allow_closed=1 ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
  shift
done
spec="${1:?$usage}"

refuse() { echo "refuse: $*" >&2; exit 1; }

pr="$(fm_get "$spec" '.pr')"
identity="$(fm_get "$spec" '[.orca[] | select(.kind == "worker")][0].worktree_identity')"
path="$(fm_get "$spec" '[.orca[] | select(.kind == "worker")][0].worktree_path')"
[ -n "$pr" ] || refuse "spec has no pr"
[ -n "$identity" ] && [ -n "$path" ] || refuse "spec has no worktree identity or path"
[ -d "$path" ] || refuse "worktree $path does not exist"

pr_json="$(gh pr view "$pr" --json state,headRefOid,headRefName)"
state="$(jq -r .state <<<"$pr_json")"
head="$(jq -r .headRefOid <<<"$pr_json")"
head_branch="$(jq -r .headRefName <<<"$pr_json")"
if [ "$state" != "MERGED" ]; then
  [ "$state" = "CLOSED" ] && [ "$allow_closed" = 1 ] || refuse "PR is $state"
fi

common="$(git -C "$path" rev-parse --path-format=absolute --git-common-dir)"
primary="$(dirname "$common")"
[ "$(cd "$path" && pwd -P)" != "$(cd "$primary" && pwd -P)" ] || refuse "target is the primary checkout"
[ -z "$(git -C "$path" status --porcelain)" ] || refuse "worktree is dirty"
branch="$(git -C "$path" branch --show-current)"
default="$(git -C "$primary" symbolic-ref --short refs/remotes/origin/HEAD)"
default="${default#origin/}"
[ "$branch" != "$default" ] || refuse "branch $branch is the default branch"
[ "$branch" = "$head_branch" ] || refuse "branch $branch is not the PR head branch $head_branch"
if [ "$(git -C "$path" rev-parse HEAD)" != "$head" ]; then
  git -C "$path" fetch -q origin "$head" 2>/dev/null || refuse "HEAD is not the PR head"
  [ -z "$(git -C "$path" cherry "$head" HEAD | grep "^+" || true)" ] || refuse "HEAD is not the PR head"
fi
shown="$(orca worktree show --worktree "identity:$identity" --json | jq -r ".result.worktree.path // empty")"
[ -n "$shown" ] && [ "$(cd "$shown" 2>/dev/null && pwd -P)" = "$(cd "$path" && pwd -P)" ] || refuse "identity $identity is not $path"
cfg="$(fleet_repo_config "$primary")"
hook="$(yaml_get "$cfg" .cleanup)" || refuse "cannot read $cfg"
[ -z "$hook" ] || [ -x "$primary/$hook" ] || refuse "cleanup hook $hook is not executable"
if [ -z "$hook" ] && [ "$cfg" != "$primary/.agents/fleet.yaml" ] && [ -n "$(yaml_get "$primary/.agents/fleet.yaml" .cleanup 2>/dev/null)" ]; then
  echo "note: $cfg sets no cleanup, so the committed hook in $primary/.agents/fleet.yaml does not run"
fi

objtask="$(fm_get "$spec" '.objective')/$(fm_get "$spec" '.task')"
if [ "$apply" = 0 ]; then
  echo "dry run for $objtask:"
  [ -z "$hook" ] || echo "  $primary/$hook $path --apply"
  echo "  orca worktree rm --worktree identity:$identity"
  echo "  delete branch $branch locally and on origin"
  exit 0
fi

[ -z "$hook" ] || (cd "$primary" && "$primary/$hook" "$path" --apply) || refuse "cleanup hook $hook failed"
orca worktree rm --worktree "identity:$identity" --json >/dev/null
if git -C "$primary" show-ref --verify --quiet "refs/heads/$branch"; then
  git -C "$primary" branch -D "$branch" >/dev/null
fi
if git -C "$primary" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  git -C "$primary" push -q origin --delete "$branch"
fi
fm_set "$spec" ".cleaned_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
ledger_append "cleaned $objtask pr=$pr state=$state"
echo "cleaned $objtask"
