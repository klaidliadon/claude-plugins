#!/usr/bin/env bash
# bin/lib.sh — agent-comms shared helpers (Task 0 subset; extended in later tasks)

# flock_append FILE  — append stdin to FILE atomically under an exclusive lock.
flock_append() {
  local file="$1"
  perl -e '
    use Fcntl qw(:flock SEEK_END);
    open(my $fh, ">>", $ARGV[0]) or die "open: $!";
    flock($fh, LOCK_EX)         or die "flock: $!";
    seek($fh, 0, SEEK_END)      or die "seek: $!";
    local $/; my $data = <STDIN>;
    print {$fh} $data if defined $data;
    close($fh)                  or die "close: $!";
  ' "$file"
}

# read_from FILE OFFSET — print bytes from OFFSET..EOF under a shared lock.
read_from() {
  local file="$1" off="$2"
  [ -e "$file" ] || return 0
  perl -e '
    use Fcntl qw(:flock SEEK_SET);
    open(my $fh, "<", $ARGV[0]) or exit 0;
    binmode($fh);
    flock($fh, LOCK_SH)         or die "flock: $!";
    seek($fh, $ARGV[1], SEEK_SET) or die "seek: $!";
    local $/; my $d = <$fh>;
    binmode(STDOUT); print $d if defined $d;
    close($fh);
  ' "$file" "$off"
}

# --- validation ---
# valid_name NAME — channel/agent slug; forbids bare . or .. segments, slashes, spaces.
valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)*$ ]]
}

# valid_tag TAG — frame-safe control tag.
valid_tag() {
  [[ "$1" =~ ^[A-Za-z0-9._=-]+$ ]]
}

# file_sha256 FILE — print the sha256 hex digest of FILE (no filename).
file_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# --- root resolution ---
# canon_dir DIR — print canonical absolute path of a possibly-nonexistent dir
# (its parent MUST exist). Lets --dir be compared byte-for-byte in assert_confined.
canon_dir() {
  local p="$1"
  if [ -d "$p" ]; then ( cd "$p" && pwd ); return; fi
  local par; par="$( cd "$(dirname "$p")" 2>/dev/null && pwd )" \
    || { echo "no such parent dir for: $p" >&2; return 1; }
  printf '%s/%s\n' "$par" "$(basename "$p")"
}

# comms_root — print <root> (NOT including tmp/agent-comms).
# Precedence: --root flag (COMMS_ROOT_FLAG) > AGENT_COMMS_ROOT > git root > $PWD.
comms_root() {
  local root gcd
  if [ -n "${COMMS_ROOT_FLAG:-}" ]; then
    root="$COMMS_ROOT_FLAG"
  elif [ -n "${AGENT_COMMS_ROOT:-}" ]; then
    root="$AGENT_COMMS_ROOT"
  elif gcd=$(git rev-parse --git-common-dir 2>/dev/null); then
    root="$(cd "$(dirname "$gcd")" && pwd)"
  else
    root="$PWD"
  fi
  realpath "$root"
}

# comms_dir — the comms dir. --dir flag (COMMS_DIR_FLAG) overrides outright;
# otherwise <root>/tmp/agent-comms.
comms_dir() {
  if [ -n "${COMMS_DIR_FLAG:-}" ]; then printf '%s\n' "$COMMS_DIR_FLAG"; return; fi
  echo "$(comms_root)/tmp/agent-comms"
}

# channel_file CHANNEL ; cursor_file CHANNEL AGENT
channel_file() { echo "$(comms_dir)/$1.md"; }
cursor_file()  { echo "$(comms_dir)/.cursors/$1/$2"; }

# make_frame SENDER TAG TS  (body on stdin) — emit: frame-comment line + block.
# Block = readable header line + body + trailing newline. bytes=N is the BYTE
# length of the block (LC_ALL=C wc -c), never character count.
make_frame() {
  local sender="$1" tag="$2" ts="$3"
  local body; body="$(cat)"
  local header="## [$ts] $sender"
  [ -n "$tag" ] && header="$header · ${tag/=/ }"   # readable render (space), wire tag stays in comment
  local block; block="$header"$'\n'"$body"$'\n'      # block ends with newline; it is part of N
  local n; n=$(printf '%s' "$block" | LC_ALL=C wc -c | tr -d ' ')
  printf '<!-- agent-comms v=1 sender=%s ts=%s tag=%s bytes=%s -->\n' "$sender" "$ts" "$tag" "$n"
  printf '%s' "$block"                               # write EXACTLY the block, no extra \n
}

# parse_frames BASE_OFFSET  (buffer on stdin)
# Emits one TSV line per COMPLETE frame: "<start>\t<end>\t<sender>\t<tag>"
# (start/end = absolute byte offsets = BASE_OFFSET + position). Writes each frame
# body block to $BODY_DIR/<n> (1-based) if BODY_DIR set. Stops at the first
# incomplete frame; never advances past it.
parse_frames() {
  local base="$1"
  BODY_DIR="${BODY_DIR:-}" perl -e '
    use strict; use warnings;
    my $base = $ARGV[0];
    local $/; binmode(STDIN); my $buf = <STDIN>; $buf = "" unless defined $buf;
    my $bodydir = $ENV{BODY_DIR} // "";
    my $pos = 0; my $n = 0; my $len = length($buf);
    while ($pos < $len) {
      my $nl = index($buf, "\n", $pos);
      last if $nl < 0;                                  # no complete comment line yet
      my $line = substr($buf, $pos, $nl - $pos);
      last unless $line =~ /^<!-- agent-comms .* sender=(\S+) .* tag=(\S*) bytes=(\d+) -->$/;
      my ($sender,$tag,$bytes) = ($1,$2,$3);
      my $body_start = $nl + 1;
      last if $body_start + $bytes > $len;              # incomplete frame — stop, do not advance
      my $body = substr($buf, $body_start, $bytes);
      $n++;
      if ($bodydir ne "") { open(my $b, ">", "$bodydir/$n") or die $!; binmode($b); print {$b} $body; close($b); }
      my $start = $base + $pos;
      my $end   = $base + $body_start + $bytes;
      print "$start\t$end\t$sender\t$tag\n";
      $pos = $body_start + $bytes;
    }
  ' "$base"
}

# assert_confined PATH — fail unless PATH's parent resolves under comms_dir.
assert_confined() {
  local target="$1" base; base="$(comms_dir)"
  local parent; parent="$(cd "$(dirname "$target")" 2>/dev/null && pwd || true)"
  case "$parent/" in "$base/"*) return 0;; *) echo "refusing path outside $base: $target" >&2; return 1;; esac
}
