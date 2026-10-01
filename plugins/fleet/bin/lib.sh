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

fleet_focus() {
  name="$2" yaml_get "$1/.agents/fleet.yaml" '.focus[strenv(name)]'
}

# glob_re turns a path glob into an anchored regex: ** spans directories, * and ? stay inside one.
GLOB_RE='def glob_re: gsub("(?<c>[.+^${}()|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*\\*/"; "\u0001") | gsub("\\*\\*"; "\u0002")
  | gsub("\\*"; "[^/]*") | gsub("\\?"; "[^/]") | gsub("\u0001"; "(.*/)?") | gsub("\u0002"; ".*") | "^\(.)$";
  def ancestors: split("/") as $p | range(1; $p | length) | $p[:.] | join("/");'

# fleet_reviewers prints adversarial, tests, then every reviewer whose .agents/fleet.yaml globs match the PR diff.
# A glob matches a changed path or any of its parent directories. A new-dir:<glob> entry matches a directory
# the PR creates: a parent directory of a changed path that matches the glob and is absent on the fetched base branch.
fleet_reviewers() {
  local cfg="$1/.agents/fleet.yaml" rules files pr base d added="" extra=""
  if [ -f "$cfg" ]; then
    rules="$(yq -o=json -I=0 '.reviewers // {}' "$cfg")" || return 1
    files="$(gh pr diff "$2" --name-only)" || return 1
    files="$(jq -Rsc 'split("\n") | map(select(. != ""))' <<<"$files")"
    if jq -e '[.[][] | select(startswith("new-dir:"))] | length > 0' >/dev/null <<<"$rules"; then
      pr="$(gh pr view "$2" --json baseRefName)" || return 1
      base="$(jq -r '.baseRefName // empty' <<<"$pr")"
      [ -n "$base" ] || { echo "fleet_reviewers: no base branch for $2" >&2; return 1; }
      git -C "$1" fetch -q origin "$base" 2>/dev/null &&
        git -C "$1" rev-parse -q --verify "refs/remotes/origin/$base^{commit}" >/dev/null ||
        { echo "fleet_reviewers: cannot fetch origin/$base in $1" >&2; return 1; }
      while IFS= read -r d; do
        git -C "$1" cat-file -e "refs/remotes/origin/$base:$d" 2>/dev/null || added+="$d"$'\n'
      done < <(jq -r --argjson files "$files" "$GLOB_RE"'
        [.[][] | select(startswith("new-dir:")) | ltrimstr("new-dir:") | glob_re] as $res
        | [$files[] | ancestors] | unique[] | select(. as $d | any($res[]; . as $r | $d | test($r)))' <<<"$rules")
    fi
    extra="$(jq -r --argjson files "$files" --argjson added "$(jq -Rsc 'split("\n") | map(select(. != ""))' <<<"$added")" "$GLOB_RE"'
      ([$files[], ($files[] | ancestors)] | unique) as $paths
      | to_entries[] | select(.key != "adversarial" and .key != "tests")
      | select(any(.value[];
          if startswith("new-dir:") then (ltrimstr("new-dir:") | glob_re) as $r | any($added[]; test($r))
          else glob_re as $r | any($paths[]; test($r)) end))
      | .key' <<<"$rules")" || return 1
  fi
  printf 'adversarial\ntests\n'
  [ -z "$extra" ] || printf '%s\n' "$extra"
}
