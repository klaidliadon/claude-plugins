#!/usr/bin/env bash
FLEET_HOME="${FLEET_HOME:-$HOME/Workspace/.fleet}"

fm_get() {
  local v
  v="$(yq --front-matter=extract "$2" "$1")"
  [ "$v" = "null" ] && v=""
  printf '%s' "$v"
}

fm_set() {
  yq --front-matter=process -i "$2" "$1"
}

ledger_append() {
  mkdir -p "$FLEET_HOME"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$FLEET_HOME/ledger.md"
}

# yaml_get prints <expr> from <file>, or nothing when the file is missing or the value is null.
yaml_get() {
  local v
  [ -f "$1" ] || return 0
  v="$(yq "$2" "$1")" || return 1
  [ "$v" = "null" ] && v=""
  printf '%s' "$v"
}

fleet_config() {
  yaml_get "$FLEET_HOME/config.yaml" "$1"
}

# fleet_repo_config prints the fleet.yaml for <repo-path>: $FLEET_HOME/repos/<owner>/<repo>.yaml, named after the origin
# remote, else <repo-path>/.agents/fleet.yaml, else nothing. The first file found wins; the two are never merged.
# The manager sources this file from zsh, so it parses the URL with expansions both shells share, not BASH_REMATCH.
fleet_repo_config() {
  local url repo owner
  if url="$(git -C "$1" remote get-url origin 2>/dev/null)"; then
    url="${url%.git}" repo="${url##*/}" url="${url%/*}" owner="${url##*[:/]}"
    [ -z "$owner" ] || [ -z "$repo" ] || [ ! -f "$FLEET_HOME/repos/$owner/$repo.yaml" ] ||
      { printf '%s\n' "$FLEET_HOME/repos/$owner/$repo.yaml"; return 0; }
  fi
  [ ! -f "$1/.agents/fleet.yaml" ] || printf '%s\n' "$1/.agents/fleet.yaml"
}

fleet_focus() {
  name="$2" yaml_get "$(fleet_repo_config "$1")" '.focus[strenv(name)]'
}

# glob_re turns a path glob into an anchored regex: ** spans directories, * and ? stay inside one.
GLOB_RE='def glob_re: gsub("(?<c>[.+^${}()|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*\\*/"; "\u0001") | gsub("\\*\\*"; "\u0002")
  | gsub("\\*"; "[^/]*") | gsub("\\?"; "[^/]") | gsub("\u0001"; "(.*/)?") | gsub("\u0002"; ".*") | "^\(.)$";
  def ancestors: split("/") as $p | range(1; $p | length) | $p[:.] | join("/");'

# fleet_reviewers prints adversarial, tests, then every reviewer whose fleet_repo_config rules match the PR.
# A reviewer's rule is a glob list or {globs, grep}. A glob matches a changed path or any of its parent directories.
# A new-dir:<glob> entry matches a directory the PR creates: a parent directory of a changed path that matches the glob
# and is absent on the fetched base branch. With <diff-path>, the changed paths come from the <diff-path>.names file
# pr_snapshot saved beside it, and a grep term matches an added or removed line of the diff, case-insensitive and as
# a fixed string. Without it, the paths come from the live PR and grep terms never match.
fleet_reviewers() {
  local cfg rules files lines='[]' parsed pr base d added="" extra=""
  cfg="$(fleet_repo_config "$1")"
  if [ -n "$cfg" ]; then
    rules="$(yq -o=json -I=0 '.reviewers // {}' "$cfg")" || return 1
    rules="$(jq -c 'map_values(if type == "array" then {globs: ., grep: []} else {globs: (.globs // []), grep: (.grep // [])} end)' \
      <<<"$rules")" || return 1
    if [ -n "${3:-}" ]; then
      [ -f "$3.names" ] || { echo "fleet_reviewers: no $3.names; save the diff with pr_snapshot" >&2; return 1; }
      files="$(jq -Rsc 'split("\n") | map(select(. != ""))' <"$3.names")"
      lines="$(awk '/^diff --git /{h=1; next} /^@@/{h=0; next} !h && /^[-+]/{print substr($0, 2)}' "$3" |
        jq -Rsc 'split("\n") | map(select(. != "") | ascii_downcase)')" || return 1
    else
      files="$(gh pr diff "$2" --name-only)" || return 1
      files="$(jq -Rsc 'split("\n") | map(select(. != ""))' <<<"$files")"
    fi
    if jq -e '[.[].globs[] | select(startswith("new-dir:"))] | length > 0' >/dev/null <<<"$rules"; then
      pr="$(gh pr view "$2" --json baseRefName)" || return 1
      base="$(jq -r '.baseRefName // empty' <<<"$pr")"
      [ -n "$base" ] || { echo "fleet_reviewers: no base branch for $2" >&2; return 1; }
      git -C "$1" fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" 2>/dev/null &&
        git -C "$1" rev-parse -q --verify "refs/remotes/origin/$base^{commit}" >/dev/null ||
        { echo "fleet_reviewers: cannot fetch origin/$base in $1" >&2; return 1; }
      while IFS= read -r d; do
        git -C "$1" cat-file -e "refs/remotes/origin/$base:$d" 2>/dev/null || added+="$d"$'\n'
      done < <(jq -r --argjson files "$files" "$GLOB_RE"'
        [.[].globs[] | select(startswith("new-dir:")) | ltrimstr("new-dir:") | glob_re] as $res
        | [$files[] | ancestors] | unique[] | select(. as $d | any($res[]; . as $r | $d | test($r)))' <<<"$rules")
    fi
    extra="$(jq -r --argjson files "$files" --argjson lines "$lines" \
      --argjson added "$(jq -Rsc 'split("\n") | map(select(. != ""))' <<<"$added")" "$GLOB_RE"'
      ([$files[], ($files[] | ancestors)] | unique) as $paths
      | to_entries[] | select(.key != "adversarial" and .key != "tests")
      | select(any(.value.globs[];
          if startswith("new-dir:") then (ltrimstr("new-dir:") | glob_re) as $r | any($added[]; test($r))
          else glob_re as $r | any($paths[]; test($r)) end)
        or any(.value.grep[]; ascii_downcase as $t | any($lines[]; contains($t))))
      | .key' <<<"$rules")" || return 1
  fi
  printf 'adversarial\ntests\n'
  [ -z "$extra" ] || printf '%s\n' "$extra"
}

# pr_snapshot saves <pr>'s diff to <diff-path>, its changed paths to <diff-path>.names, and prints the head both
# belong to. When the head moves during the capture it retries once, so head, diff and names are one snapshot.
pr_snapshot() {
  local before after try
  for try in 1 2; do
    before="$(gh pr view "$1" --json headRefOid | jq -r '.headRefOid // empty')" && [ -n "$before" ] || return 1
    gh pr diff "$1" >"$2" || return 1
    gh pr diff "$1" --name-only >"$2.names" || return 1
    after="$(gh pr view "$1" --json headRefOid | jq -r '.headRefOid // empty')" || return 1
    [ "$before" != "$after" ] || { printf '%s\n' "$after"; return 0; }
  done
  echo "pr_snapshot: the head of $1 moved twice during the capture" >&2
  return 1
}

# lock_take creates the mkdir lock <dir> and records LOCK_OWNER in it. A lock older than FLEET_LOCK_TTL seconds
# (default 300) is stale. Taking one over happens under <dir>.break, re-checked inside, so two contenders cannot
# both break the same stale lock.
lock_take() {
  LOCK_OWNER="$$.$(date +%s).$RANDOM"
  if ! mkdir "$1" 2>/dev/null; then
    lock_stale "$1.break" && rm -rf "$1.break"
    mkdir "$1.break" 2>/dev/null || return 1
    if ! lock_stale "$1"; then rm -rf "$1.break"; return 1; fi
    rm -rf "$1"
    mkdir "$1" 2>/dev/null || { rm -rf "$1.break"; return 1; }
    rm -rf "$1.break"
  fi
  printf '%s\n' "$LOCK_OWNER" >"$1/owner"
}

# lock_stale succeeds when <dir> exists and is older than FLEET_LOCK_TTL seconds.
lock_stale() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" || return 1
  [ $(($(date +%s) - m)) -gt "${FLEET_LOCK_TTL:-300}" ]
}

# lock_release removes <dir> only while it still holds this process's LOCK_OWNER, never a lock taken over since.
lock_release() {
  [ "$(cat "$1/owner" 2>/dev/null)" != "${LOCK_OWNER:-}" ] || rm -rf "$1"
}
