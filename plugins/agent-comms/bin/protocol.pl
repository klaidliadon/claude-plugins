#!/usr/bin/env perl
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:flock SEEK_END SEEK_SET);
use Getopt::Long qw(GetOptionsFromArray);
use Time::HiRes qw(time sleep);
use POSIX qw(strftime);

sub fail {
    die "agent-comms protocol: @_\n";
}

sub timestamp {
    return strftime("%Y-%m-%dT%H:%M:%SZ", gmtime());
}

sub valid_name {
    return defined $_[0] && $_[0] =~ /^[A-Za-z0-9][A-Za-z0-9_-]*(?:\.[A-Za-z0-9][A-Za-z0-9_-]*)*$/;
}

sub valid_tag {
    return defined $_[0] && $_[0] =~ /^[A-Za-z0-9._=-]+$/;
}

sub read_body {
    my ($path) = @_;
    open(my $fh, "<", $path) or fail("open body $path: $!");
    binmode($fh);
    local $/;
    my $body = <$fh>;
    close($fh) or fail("close body $path: $!");
    return defined $body ? $body : "";
}

sub parse_frames {
    my ($data, $allow_incomplete) = @_;
    my @frames;
    my $pos = 0;
    my $length = length($data);
    while ($pos < $length) {
        my $newline = index($data, "\n", $pos);
        return (\@frames, { type => "partial-header", start => $pos }) if $newline < 0 && $allow_incomplete;
        fail("partial frame header at byte $pos") if $newline < 0;
        my $line = substr($data, $pos, $newline - $pos);
        my ($session, $seq, $sender, $generation, $ts, $kind, $turn, $state, $tag, $bytes, $sha) =
            $line =~ /^<!-- agent-comms v=2 session=(\S+) seq=(\d+) sender=(\S+) gen=(\d+) ts=(\S+) kind=(message|status|control) turn=(\d+) state=(continue|over|none|terminal) tag=(\S+) bytes=(\d+) sha256=([0-9a-f]{64}) -->$/;
        fail("malformed frame header at byte $pos") unless defined $sha;
        my $body_start = $newline + 1;
        if ($body_start + $bytes > $length) {
            return (\@frames, {
                type => "partial-body",
                start => $pos,
                body_start => $body_start,
                missing => $body_start + $bytes - $length,
            }) if $allow_incomplete;
            fail("partial frame body at byte $pos");
        }
        my $block = substr($data, $body_start, $bytes);
        fail("frame checksum mismatch at byte $pos") unless sha256_hex($block) eq $sha;
        push @frames, {
            start => $pos,
            end => $body_start + $bytes,
            session => $session,
            seq => 0 + $seq,
            sender => $sender,
            generation => 0 + $generation,
            ts => $ts,
            kind => $kind,
            turn => 0 + $turn,
            state => $state,
            tag => $tag,
            bytes => 0 + $bytes,
            sha256 => $sha,
            block => $block,
        };
        $pos = $body_start + $bytes;
    }
    return (\@frames, undef);
}

sub init_metadata {
    my ($frame) = @_;
    fail("first frame is not hello") unless
        $frame->{kind} eq "control" && $frame->{tag} eq "hello" && $frame->{seq} == 1;
    my %metadata;
    for my $line (split(/\n/, $frame->{block})) {
        next unless $line =~ /^(driver|peer|release|digest|protocol|release_root)=(.*)$/;
        $metadata{$1} = $2;
    }
    for my $key (qw(driver peer release digest protocol release_root)) {
        fail("hello missing $key") unless defined $metadata{$key} && length($metadata{$key});
    }
    fail("hello sender does not match driver") unless $frame->{sender} eq $metadata{driver};
    return \%metadata;
}

sub state_from_frames {
    my ($frames) = @_;
    fail("empty session") unless @$frames;
    my $metadata = init_metadata($frames->[0]);
    my %generation = (
        $metadata->{driver} => 1,
        $metadata->{peer} => 1,
    );
    my $state = {
        %$metadata,
        session => $frames->[0]{session},
        expected => $metadata->{driver},
        turn => 1,
        terminal => 0,
        generation => \%generation,
        seq => 0,
    };
    for my $index (0 .. $#$frames) {
        my $frame = $frames->[$index];
        fail("mixed sessions") unless $frame->{session} eq $state->{session};
        fail("non-monotonic sequence") unless $frame->{seq} == $index + 1;
        $state->{seq} = $frame->{seq};
        next if $index == 0;
        apply_frame($state, $frame);
    }
    return $state;
}

sub other_participant {
    my ($state, $sender) = @_;
    return $sender eq $state->{driver} ? $state->{peer} : $state->{driver};
}

sub apply_frame {
    my ($session, $frame) = @_;
    fail("frame after terminal") if $session->{terminal};
    fail("unknown participant $frame->{sender}") unless
        $frame->{sender} eq $session->{driver} || $frame->{sender} eq $session->{peer};
    my $want_generation = $session->{generation}{$frame->{sender}};
    fail("stale generation") unless $frame->{generation} == $want_generation;
    if ($frame->{kind} eq "message") {
        fail("message requires continue or over") unless
            $frame->{state} eq "continue" || $frame->{state} eq "over";
        fail("turn sequence violation: expected $session->{expected}") unless
            $frame->{sender} eq $session->{expected};
        fail("turn sequence violation: expected turn $session->{turn}") unless
            $frame->{turn} == $session->{turn};
        if ($frame->{state} eq "over") {
            $session->{expected} = other_participant($session, $frame->{sender});
            $session->{turn}++;
        }
        return;
    }
    if ($frame->{kind} eq "status") {
        fail("status requires state none") unless $frame->{state} eq "none";
        fail("status has invalid turn") unless $frame->{turn} == 0 || $frame->{turn} == $session->{turn};
        return;
    }
    fail("control has invalid turn") unless $frame->{turn} == 0;
    if ($frame->{state} eq "terminal") {
        fail("terminal control is driver-only") unless $frame->{sender} eq $session->{driver};
        $session->{terminal} = 1;
        return;
    }
    fail("control requires state none") unless $frame->{state} eq "none";
}

sub frame_block {
    my (%args) = @_;
    my $tag = $args{tag};
    my $readable = $tag eq "-" ? "" : " · " . ($tag =~ s/=/ /r);
    if ($args{kind} eq "status") {
        my $suffix = length($args{body}) ? " · $args{body}" : "";
        return "· [$args{ts}] $args{sender}$readable$suffix\n";
    }
    if ($args{kind} eq "control") {
        return "· [$args{ts}] $args{sender}$readable\n$args{body}\n";
    }
    my $separator = $args{state} eq "over"
        ? "---------- $args{sender} · over ----------"
        : "----------";
    return "## [$args{ts}] $args{sender}$readable\n$args{body}\n\n$separator\n";
}

sub encode_frame {
    my (%args) = @_;
    my $block = frame_block(%args);
    my $bytes = length($block);
    my $sha = sha256_hex($block);
    my $line = "<!-- agent-comms v=2 session=$args{session} seq=$args{seq} sender=$args{sender} gen=$args{generation} ts=$args{ts} kind=$args{kind} turn=$args{turn} state=$args{state} tag=$args{tag} bytes=$bytes sha256=$sha -->\n";
    return $line . $block;
}

sub open_locked {
    my ($file) = @_;
    open(my $fh, "+>>", $file) or fail("open $file: $!");
    binmode($fh);
    flock($fh, LOCK_EX) or fail("lock $file: $!");
    seek($fh, 0, SEEK_SET) or fail("seek $file: $!");
    local $/;
    my $data = <$fh>;
    return ($fh, defined $data ? $data : "");
}

sub cmd_init {
    my (@argv) = @_;
    my ($file, $session, $driver, $peer, $release, $digest, $protocol, $release_root);
    GetOptionsFromArray(
        \@argv,
        "file=s" => \$file,
        "session=s" => \$session,
        "driver=s" => \$driver,
        "peer=s" => \$peer,
        "release=s" => \$release,
        "digest=s" => \$digest,
        "protocol=i" => \$protocol,
        "release-root=s" => \$release_root,
    ) or fail("bad init arguments");
    fail("missing init argument") unless
        defined $file && valid_name($session) && valid_name($driver) && valid_name($peer) &&
        defined $release && defined $digest && defined $protocol && defined $release_root;
    fail("driver and peer must differ") if $driver eq $peer;
    fail("protocol must be 2") unless $protocol == 2;
    fail("bad digest") unless $digest =~ /^[0-9a-f]{64}$/;
    my ($fh, $existing) = open_locked($file);
    fail("session already exists") if length($existing);
    my $ts = timestamp();
    my $body = join("\n",
        "driver=$driver",
        "peer=$peer",
        "release=$release",
        "digest=$digest",
        "protocol=$protocol",
        "release_root=$release_root",
    );
    my $frame = encode_frame(
        session => $session,
        seq => 1,
        sender => $driver,
        generation => 1,
        ts => $ts,
        kind => "control",
        turn => 0,
        state => "none",
        tag => "hello",
        body => $body,
    );
    seek($fh, 0, SEEK_END) or fail("seek $file: $!");
    print {$fh} $frame or fail("write $file: $!");
    close($fh) or fail("close $file: $!");
}

sub cmd_append {
    my (@argv) = @_;
    my ($file, $sender, $generation, $kind, $state, $tag, $body_file);
    GetOptionsFromArray(
        \@argv,
        "file=s" => \$file,
        "sender=s" => \$sender,
        "generation=i" => \$generation,
        "kind=s" => \$kind,
        "state=s" => \$state,
        "tag=s" => \$tag,
        "body-file=s" => \$body_file,
    ) or fail("bad append arguments");
    fail("missing append argument") unless
        defined $file && valid_name($sender) && defined $generation &&
        defined $kind && defined $state && defined $tag && valid_tag($tag) &&
        defined $body_file;
    fail("bad kind") unless $kind =~ /^(?:message|status|control)$/;
    fail("bad state") unless $state =~ /^(?:continue|over|none|terminal)$/;
    my $body = read_body($body_file);
    my ($fh, $data) = open_locked($file);
    my ($frames, $incomplete) = parse_frames($data, 1);
    fail("cannot append after incomplete tail") if $incomplete;
    my $session = state_from_frames($frames);
    my $turn = $kind eq "message" ? $session->{turn} : ($kind eq "status" ? $session->{turn} : 0);
    my $ts = timestamp();
    my $candidate = {
        session => $session->{session},
        seq => $session->{seq} + 1,
        sender => $sender,
        generation => 0 + $generation,
        ts => $ts,
        kind => $kind,
        turn => $turn,
        state => $state,
        tag => $tag,
    };
    apply_frame($session, $candidate);
    my $encoded = encode_frame(%$candidate, body => $body);
    seek($fh, 0, SEEK_END) or fail("seek $file: $!");
    print {$fh} $encoded or fail("write $file: $!");
    close($fh) or fail("close $file: $!");
}

sub cmd_transcript {
    my (@argv) = @_;
    my $file;
    GetOptionsFromArray(\@argv, "file=s" => \$file) or fail("bad transcript arguments");
    fail("missing --file") unless defined $file;
    open(my $fh, "<", $file) or fail("open $file: $!");
    binmode($fh);
    local $/;
    my $data = <$fh>;
    close($fh);
    my ($frames) = parse_frames(defined $data ? $data : "", 1);
    print $_->{block} for @$frames;
}

sub cursor_offset {
    my ($path) = @_;
    return 0 unless -f $path;
    open(my $fh, "<", $path) or fail("open cursor $path: $!");
    my $value = <$fh>;
    close($fh);
    chomp($value //= "");
    return $value =~ /^\d+$/ ? 0 + $value : 0;
}

sub write_cursor {
    my ($path, $offset) = @_;
    my $temporary = "$path.$$";
    open(my $fh, ">", $temporary) or fail("open cursor temp $temporary: $!");
    print {$fh} "$offset\n" or fail("write cursor temp $temporary: $!");
    close($fh) or fail("close cursor temp $temporary: $!");
    rename($temporary, $path) or fail("rename cursor $temporary: $!");
}

sub cmd_recv {
    my (@argv) = @_;
    my ($file, $cursor, $me, $generation, $silence_seconds, $turn_seconds);
    $silence_seconds = 590;
    $turn_seconds = 1800;
    GetOptionsFromArray(
        \@argv,
        "file=s" => \$file,
        "cursor=s" => \$cursor,
        "me=s" => \$me,
        "generation=i" => \$generation,
        "silence-seconds=f" => \$silence_seconds,
        "turn-seconds=f" => \$turn_seconds,
    ) or fail("bad recv arguments");
    fail("missing recv argument") unless
        defined $file && defined $cursor && valid_name($me) && defined $generation;
    my $offset = cursor_offset($cursor);
    my $started = time();
    my $last_frame = $started;
    my $turn_started;
    while (1) {
        open(my $fh, "<", $file) or fail("open $file: $!");
        binmode($fh);
        local $/;
        my $data = <$fh>;
        close($fh);
        $data = "" unless defined $data;
        my ($frames) = parse_frames($data, 1);
        my @after = grep { $_->{end} > $offset } @$frames;
        my @semantic;
        my $complete_end;
        for my $frame (@after) {
            next if $frame->{end} <= $offset;
            $last_frame = time();
            next if $frame->{sender} eq $me;
            next if $frame->{kind} ne "message";
            $turn_started //= time();
            push @semantic, $frame;
            if ($frame->{state} eq "over") {
                $complete_end = $frame->{end};
                last;
            }
        }
        if (defined $complete_end) {
            write_cursor($cursor, $complete_end);
            print $_->{block} for @semantic;
            return;
        }
        my $session = @$frames ? state_from_frames($frames) : undef;
        if (!@semantic && $session && $session->{expected} eq $me && $offset >= length($data)) {
            fail("$me owns the floor and must send before recv");
        }
        my $now = time();
        if (defined $turn_started && $now - $turn_started >= $turn_seconds) {
            print "__TURN_TIMEOUT__ session=$session->{session} turn=$session->{turn} sender=$session->{expected} gen=$session->{generation}{$session->{expected}}\n";
            exit 3;
        }
        if ($now - $last_frame >= $silence_seconds) {
            print "__SILENCE_TIMEOUT__\n";
            exit 2;
        }
        sleep(0.05);
    }
}

my $command = shift(@ARGV) // "";
if ($command eq "init") {
    cmd_init(@ARGV);
} elsif ($command eq "append") {
    cmd_append(@ARGV);
} elsif ($command eq "recv") {
    cmd_recv(@ARGV);
} elsif ($command eq "transcript") {
    cmd_transcript(@ARGV);
} else {
    fail("unknown command '$command'");
}
