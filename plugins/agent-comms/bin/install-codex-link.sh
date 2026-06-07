#!/usr/bin/env bash
# Wire this plugin's agent-comms skill into Codex (which discovers skills from
# ~/.codex/skills/). Self-locating: links to wherever this plugin actually lives.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
SRC="$PLUGIN_ROOT/skills/agent-comms"
DST="$HOME/.codex/skills/agent-comms"

mkdir -p "$HOME/.codex/skills"
if [ -L "$DST" ]; then
  cur="$(readlink "$DST")"
  if [ "$cur" = "$SRC" ]; then
    echo "already linked"
  else
    echo "refusing: $DST already points to $cur (not $SRC)" >&2; exit 1
  fi
elif [ -e "$DST" ]; then
  echo "refusing: $DST exists and is not our symlink" >&2; exit 1
else
  ln -s "$SRC" "$DST"
  echo "linked $DST -> $SRC"
fi

# Codex is not a plugin host, so the bin/ dir is not auto-added to PATH the way
# it is under Claude Code. Add it so the scripts resolve by bare name there too:
echo "For Codex, add this plugin's bin to PATH (e.g. in ~/.zshrc):"
echo "  export PATH=\"$PLUGIN_ROOT/bin:\$PATH\""
