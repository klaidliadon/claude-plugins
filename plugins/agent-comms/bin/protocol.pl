#!/usr/bin/env perl
use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:flock SEEK_END SEEK_SET);
use Getopt::Long qw(GetOptionsFromArray);
use Time::HiRes qw(time sleep);
use Time::Local qw(timegm);
use POSIX qw(strftime);

sub fail {
    print STDERR "agent-comms protocol: @_\n";
    exit 1;
}

sub timestamp {
    return strftime("%Y-%m-%dT%H:%M:%SZ", gmtime());
}

sub timestamp_epoch {
    my ($value) = @_;
    my ($year, $month, $day, $hour, $minute, $second) =
        $value =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/;
    fail("invalid frame timestamp: $value") unless defined $second;
    return timegm($second, $minute, $hour, $day, $month - 1, $year);
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
    my $header_damage;
    while ($pos < $length) {
        my $newline = index($data, "\n", $pos);
        return (\@frames, { type => "partial-header", start => $pos }) if $newline < 0 && $allow_incomplete;
        fail("partial frame header at byte $pos") if $newline < 0;
        my $line = substr($data, $pos, $newline - $pos);
        my ($session, $seq, $sender, $generation, $ts, $kind, $turn, $state, $tag, $bytes, $sha) =
            $line =~ /^<!-- agent-comms v=2 session=(\S+) seq=(\d+) sender=(\S+) gen=(\d+) ts=(\S+) kind=(message|status|control) turn=(\d+) state=(continue|over|none|terminal) tag=(\S+) bytes=(\d+) sha256=([0-9a-f]{64}) -->$/;
        if (!defined $sha) {
            fail("consecutive malformed frame headers at byte $pos") if $header_damage;
            $header_damage = { type => "header", start => $pos };
            $pos = $newline + 1;
            next;
        }
        my $body_start = $newline + 1;
        if ($body_start + $bytes > $length) {
            return (\@frames, {
                type => "partial-body",
                start => $pos,
                body_start => $body_start,
                missing => $body_start + $bytes - $length,
                session => $session,
                seq => 0 + $seq,
                sender => $sender,
                generation => 0 + $generation,
                kind => $kind,
                turn => 0 + $turn,
                state => $state,
                tag => $tag,
            }) if $allow_incomplete;
            fail("partial frame body at byte $pos");
        }
        my $block = substr($data, $body_start, $bytes);
        my $frame = {
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
        $frame->{damage_before} = $header_damage if $header_damage;
        $header_damage = undef;
        $frame->{corrupt} = 1 unless sha256_hex($block) eq $sha;
        push @frames, $frame;
        $pos = $body_start + $bytes;
    }
    fail("unrecovered malformed frame header at byte $header_damage->{start}") if $header_damage;
    return (\@frames, undef);
}

sub init_metadata {
    my ($frame) = @_;
    fail("damaged hello frame") if $frame->{corrupt} || $frame->{damage_before};
    fail("first frame is not hello") unless
        $frame->{kind} eq "control" && $frame->{tag} eq "hello" && $frame->{seq} == 1;
    my %metadata;
    for my $line (split(/\n/, $frame->{block})) {
        next unless $line =~ /^(driver|peer|release|digest|protocol|release_root|progress_frames|progress_bytes|heartbeat_after|heartbeat_interval|semantic_timeout)=(.*)$/;
        $metadata{$1} = $2;
    }
    for my $key (qw(driver peer release digest protocol release_root progress_frames progress_bytes heartbeat_after heartbeat_interval semantic_timeout)) {
        fail("hello missing $key") unless defined $metadata{$key} && length($metadata{$key});
    }
    for my $key (qw(progress_frames progress_bytes heartbeat_after heartbeat_interval)) {
        fail("hello has invalid $key") unless $metadata{$key} =~ /^\d+$/ && $metadata{$key} > 0;
    }
    fail("hello has invalid semantic_timeout") unless
        $metadata{semantic_timeout} =~ /^\d+$/ &&
        $metadata{semantic_timeout} > 0 &&
        $metadata{semantic_timeout} <= 3600;
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
    my %message_seq = (
        $metadata->{driver} => 0,
        $metadata->{peer} => 0,
    );
    my $state = {
        %$metadata,
        session => $frames->[0]{session},
        expected => $metadata->{driver},
        turn => 1,
        terminal => 0,
        generation => \%generation,
        message_seq => \%message_seq,
        seq => 0,
    };
    my $next_seq = 1;
    my $recovery;
    for my $index (0 .. $#$frames) {
        my $frame = $frames->[$index];
        fail("mixed sessions") unless $frame->{session} eq $state->{session};
        if ($frame->{damage_before}) {
            fail("nested tail recovery") if $recovery;
            $recovery = {
                type => "header",
                id => $frame->{damage_before}{start},
                role => $state->{expected},
                generation => $state->{generation}{$state->{expected}} + 1,
                replace_seen => 0,
            };
        }
        fail("non-monotonic sequence") unless $frame->{seq} == $next_seq;
        $next_seq++;
        $state->{seq} = $frame->{seq};
        next if $index == 0;
        if ($frame->{corrupt}) {
            fail("nested tail recovery") if $recovery;
            fail("corrupt frame is not from the open turn holder") unless
                $frame->{sender} eq $state->{expected};
            fail("corrupt frame has invalid generation") unless
                $frame->{generation} == $state->{generation}{$frame->{sender}};
            $frame->{stale} = 1;
            $recovery = {
                type => "body",
                id => $frame->{seq},
                role => $frame->{sender},
                generation => $frame->{generation} + 1,
                replace_seen => 0,
            };
            next;
        }
        if ($recovery && !$recovery->{replace_seen}) {
            fail("tail damage must be followed by replacement") unless
                $frame->{kind} eq "control" &&
                $frame->{tag} eq "replace=$recovery->{role}.$recovery->{generation}";
            apply_frame($state, $frame);
            $recovery->{replace_seen} = 1;
            next;
        }
        if ($recovery) {
            fail("replacement must be followed by recovery control") unless
                $frame->{sender} eq $state->{driver} &&
                $frame->{kind} eq "control" &&
                $frame->{state} eq "none" &&
                $frame->{tag} eq "recover=$recovery->{type}.$recovery->{id}";
            apply_frame($state, $frame);
            $recovery = undef;
            next;
        }
        apply_frame($state, $frame);
    }
    fail("incomplete tail recovery") if $recovery;
    return $state;
}

sub other_participant {
    my ($state, $sender) = @_;
    return $sender eq $state->{driver} ? $state->{peer} : $state->{driver};
}

sub apply_frame {
    my ($session, $frame) = @_;
    fail("unknown participant $frame->{sender}") unless
        $frame->{sender} eq $session->{driver} || $frame->{sender} eq $session->{peer};
    my $want_generation = $session->{generation}{$frame->{sender}};
    if ($frame->{generation} < $want_generation) {
        $frame->{stale} = 1;
        return;
    }
    fail("future generation") if $frame->{generation} > $want_generation;
    if ($session->{terminal}) {
        if ($frame->{kind} eq "status" && $frame->{state} eq "none") {
            fail("status has invalid turn") unless
                $frame->{turn} == 0 || $frame->{turn} == $session->{turn};
            return;
        }
        fail("semantic frame after terminal");
    }
    if ($frame->{kind} eq "message") {
        fail("message requires continue or over") unless
            $frame->{state} eq "continue" || $frame->{state} eq "over";
        fail("turn sequence violation: expected $session->{expected}") unless
            $frame->{sender} eq $session->{expected};
        fail("turn sequence violation: expected turn $session->{turn}") unless
            $frame->{turn} == $session->{turn};
        $session->{message_seq}{$frame->{sender}} = $frame->{seq};
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
    if ($frame->{tag} =~ /^replace=([A-Za-z0-9._-]+)\.(\d+)$/) {
        my ($role, $generation) = ($1, 0 + $2);
        fail("replacement is driver-only") unless $frame->{sender} eq $session->{driver};
        fail("replacement must target the open turn holder") unless $role eq $session->{expected};
        fail("replacement targets unknown participant") unless exists $session->{generation}{$role};
        fail("replacement generation must increment by one") unless
            $generation == $session->{generation}{$role} + 1;
        $session->{generation}{$role} = $generation;
        $session->{message_seq}{$role} = 0;
    }
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

sub read_locked {
    my ($file) = @_;
    open(my $fh, "<", $file) or fail("open $file: $!");
    binmode($fh);
    flock($fh, LOCK_SH) or fail("lock $file: $!");
    local $/;
    my $data = <$fh>;
    close($fh) or fail("close $file: $!");
    return defined $data ? $data : "";
}

sub cmd_init {
    my (@argv) = @_;
    my ($file, $session, $driver, $peer, $release, $digest, $protocol, $release_root);
    my ($progress_frames, $progress_bytes, $heartbeat_after, $heartbeat_interval) = (8, 512, 30, 30);
    my $semantic_timeout = 300;
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
        "progress-frames=i" => \$progress_frames,
        "progress-bytes=i" => \$progress_bytes,
        "heartbeat-after=i" => \$heartbeat_after,
        "heartbeat-interval=i" => \$heartbeat_interval,
        "semantic-timeout=i" => \$semantic_timeout,
    ) or fail("bad init arguments");
    fail("missing init argument") unless
        defined $file && valid_name($session) && valid_name($driver) && valid_name($peer) &&
        defined $release && defined $digest && defined $protocol && defined $release_root;
    fail("driver and peer must differ") if $driver eq $peer;
    fail("protocol must be 2") unless $protocol == 2;
    fail("bad digest") unless $digest =~ /^[0-9a-f]{64}$/;
    fail("progress and heartbeat limits must be positive") unless
        $progress_frames > 0 && $progress_bytes > 0 &&
        $heartbeat_after > 0 && $heartbeat_interval > 0;
    fail("semantic timeout must be between 1 and 3600 seconds") unless
        $semantic_timeout > 0 && $semantic_timeout <= 3600;
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
        "progress_frames=$progress_frames",
        "progress_bytes=$progress_bytes",
        "heartbeat_after=$heartbeat_after",
        "heartbeat_interval=$heartbeat_interval",
        "semantic_timeout=$semantic_timeout",
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
    if ($kind eq "message" && $state eq "continue") {
        fail("progress frame exceeds $session->{progress_bytes} bytes; coalesce progress into the final yielding frame")
            if length($body) > $session->{progress_bytes};
        my ($previous_progress) = reverse grep {
            !$_->{stale} &&
            $_->{kind} eq "message" &&
            $_->{sender} eq $sender &&
            $_->{generation} == $generation &&
            $_->{turn} == $session->{turn} &&
            $_->{state} eq "continue"
        } @$frames;
        if ($previous_progress) {
            my $candidate_block = frame_block(
                ts => $previous_progress->{ts},
                sender => $previous_progress->{sender},
                kind => "message",
                state => "continue",
                tag => $previous_progress->{tag},
                body => $body,
            );
            fail("duplicate progress frame; report new evidence or yield")
                if $candidate_block eq $previous_progress->{block};
        }
        my $progress_count = grep {
            !$_->{stale} &&
            $_->{kind} eq "message" &&
            $_->{turn} == $session->{turn} &&
            $_->{state} eq "continue"
        } @$frames;
        fail("progress frame budget exhausted; coalesce progress into the final yielding frame")
            if $progress_count >= $session->{progress_frames};
    }
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
    if ($candidate->{stale}) {
        print STDERR "agent-comms protocol: stale generation frame recorded but fenced\n";
        exit 4;
    }
}

sub resume_body {
    my ($session, $frames, $replace, $new_generation, $handoff, $artifact_file) = @_;
    my $task = resume_task($session, $frames);
    my $task_body = $task->{block};
    my $artifact_ref = "-";
    if (defined $artifact_file) {
        my $artifact_path = abs_path($artifact_file);
        fail("resume artifact is missing: $artifact_file") unless defined $artifact_path;
        fail("resume artifact path contains a newline") if $artifact_path =~ /\n/;
        $artifact_ref = "$artifact_path@" . sha256_hex(read_body($artifact_path));
    }
    my $body = join("\n",
        "session=$session->{session}",
        "role=$replace",
        "generation=$new_generation",
        "open_turn=$session->{turn}",
        "release=$session->{release}",
        "digest=$session->{digest}",
        "protocol=$session->{protocol}",
        "release_root=$session->{release_root}",
        "task_ref=$task->{sha256}",
        "task_bytes=" . length($task_body),
        "artifact_ref=$artifact_ref",
        "next_action_bytes=" . length($handoff),
        "task:",
    );
    $body .= "\n$task_body\n---------- resume next-action ----------\nnext_action=$handoff";
    fail("resume packet exceeds 65536 bytes") if length($body) > 65536;
    return $body;
}

sub resume_task {
    my ($session, $frames) = @_;
    my ($task) = reverse grep {
        !$_->{stale} &&
        $_->{kind} eq "message" &&
        $_->{state} eq "over" &&
        $_->{turn} == $session->{turn} - 1
    } @$frames;
    return $task // $frames->[0];
}

sub validate_resume_actor {
    my ($session, $driver, $generation, $replace) = @_;
    fail("only the driver may replace a participant") unless $driver eq $session->{driver};
    fail("stale driver generation") unless $generation == $session->{generation}{$driver};
    fail("replacement must target the open turn holder") unless $replace eq $session->{expected};
}

sub replacement_frame {
    my ($session, $driver, $generation, $replace, $new_generation, $seq, $body) = @_;
    return encode_frame(
        session => $session->{session},
        seq => $seq,
        sender => $driver,
        generation => 0 + $generation,
        ts => timestamp(),
        kind => "control",
        turn => 0,
        state => "none",
        tag => "replace=$replace.$new_generation",
        body => $body,
    );
}

sub resume_session {
    my (%args) = @_;
    my $handoff = read_body($args{body_file});
    fail("resume handoff exceeds 4096 bytes") if length($handoff) > 4096;
    my ($fh, $data) = open_locked($args{file});
    my ($frames, $incomplete) = parse_frames($data, 1);
    fail("recover-tail requires an incomplete tail") if $args{require_incomplete} && !$incomplete;
    my $session = state_from_frames($frames);
    validate_resume_actor($session, $args{driver}, $args{generation}, $args{replace});
    my $new_generation = $session->{generation}{$args{replace}} + 1;
    my $body = resume_body(
        $session,
        $frames,
        $args{replace},
        $new_generation,
        $handoff,
        $args{artifact_file},
    );
    my $suffix = "";
    my $replacement_seq = $session->{seq} + 1;
    my ($damage_type, $damage_id);
    if ($incomplete && $incomplete->{type} eq "partial-body") {
        fail("damaged frame has wrong session") unless $incomplete->{session} eq $session->{session};
        fail("damaged frame has wrong sequence") unless $incomplete->{seq} == $replacement_seq;
        fail("damaged frame is not from replacement role") unless $incomplete->{sender} eq $args{replace};
        fail("damaged frame has wrong generation") unless
            $incomplete->{generation} == $session->{generation}{$args{replace}};
        $suffix .= "?" x $incomplete->{missing};
        $damage_type = "body";
        $damage_id = $incomplete->{seq};
        $replacement_seq++;
    } elsif ($incomplete) {
        my $partial = substr($data, $incomplete->{start});
        fail("damaged header is not a v2 frame") unless
            index("<!-- agent-comms v=2 ", $partial) == 0 ||
            index($partial, "<!-- agent-comms v=2 ") == 0;
        if ($partial =~ /session=(\S+)/) {
            fail("damaged header has wrong session") unless $1 eq $session->{session};
        }
        if ($partial =~ /seq=(\d+)/) {
            fail("damaged header has wrong sequence") unless 0 + $1 == $replacement_seq;
        }
        if ($partial =~ /sender=(\S+)/) {
            fail("damaged header is not from replacement role") unless $1 eq $args{replace};
        }
        $suffix .= "\n";
        $damage_type = "header";
        $damage_id = $incomplete->{start};
    }
    $suffix .= replacement_frame(
        $session,
        $args{driver},
        $args{generation},
        $args{replace},
        $new_generation,
        $replacement_seq,
        $body,
    );
    if ($incomplete) {
        my $recovery_body = join("\n",
            "damaged_offset=$incomplete->{start}",
            "fenced=$args{replace}.$session->{generation}{$args{replace}}",
            "replacement=$args{replace}.$new_generation",
        );
        $suffix .= encode_frame(
            session => $session->{session},
            seq => $replacement_seq + 1,
            sender => $args{driver},
            generation => 0 + $args{generation},
            ts => timestamp(),
            kind => "control",
            turn => 0,
            state => "none",
            tag => "recover=$damage_type.$damage_id",
            body => $recovery_body,
        );
    }
    my ($candidate_frames, $candidate_incomplete) = parse_frames($data . $suffix, 0);
    fail("recovery did not close the tail") if $candidate_incomplete;
    state_from_frames($candidate_frames);
    seek($fh, 0, SEEK_END) or fail("seek $args{file}: $!");
    print {$fh} $suffix or fail("write $args{file}: $!");
    close($fh) or fail("close $args{file}: $!");
    print "generation=$new_generation cursor=", length($data) + length($suffix), "\n";
}

sub cmd_resume {
    my ($require_incomplete, @argv) = @_;
    my ($file, $driver, $generation, $replace, $body_file, $artifact_file);
    GetOptionsFromArray(
        \@argv,
        "file=s" => \$file,
        "driver=s" => \$driver,
        "generation=i" => \$generation,
        "replace=s" => \$replace,
        "body-file=s" => \$body_file,
        "artifact-file=s" => \$artifact_file,
    ) or fail("bad resume arguments");
    fail("missing resume argument") unless
        defined $file && valid_name($driver) && defined $generation &&
        valid_name($replace) && defined $body_file;
    resume_session(
        file => $file,
        driver => $driver,
        generation => $generation,
        replace => $replace,
        body_file => $body_file,
        artifact_file => $artifact_file,
        require_incomplete => $require_incomplete,
    );
}

sub cmd_resume_packet {
    my (@argv) = @_;
    my ($file, $role, $generation);
    GetOptionsFromArray(
        \@argv,
        "file=s" => \$file,
        "role=s" => \$role,
        "generation=i" => \$generation,
    ) or fail("bad resume-packet arguments");
    fail("missing resume-packet argument") unless
        defined $file && valid_name($role) && defined $generation;
    my $data = read_locked($file);
    my ($frames, $incomplete) = parse_frames($data, 1);
    fail("incomplete channel tail") if $incomplete;
    my $session = state_from_frames($frames);
    my ($packet) = reverse grep {
        $_->{kind} eq "control" && $_->{tag} eq "replace=$role.$generation"
    } @$frames;
    fail("resume packet not found") unless $packet;
    my $body = $packet->{block};
    $body =~ s/^[^\n]*\n// or fail("resume packet has no body");
    $body =~ s/\n\z//;
    my ($packet_session, $packet_role, $packet_generation, $open_turn, $release,
        $digest, $protocol, $release_root, $task_ref, $task_bytes, $artifact_ref,
        $next_action_bytes, $payload) =
        $body =~ /\Asession=([^\n]+)\nrole=([^\n]+)\ngeneration=(\d+)\nopen_turn=(\d+)\nrelease=([^\n]+)\ndigest=([0-9a-f]{64})\nprotocol=(\d+)\nrelease_root=([^\n]+)\ntask_ref=([^\n]+)\ntask_bytes=(\d+)\nartifact_ref=([^\n]+)\nnext_action_bytes=(\d+)\ntask:\n(.*)\z/s;
    fail("malformed resume packet") unless defined $payload;
    my $task_body = substr($payload, 0, $task_bytes, "");
    my $separator = "\n---------- resume next-action ----------\nnext_action=";
    fail("malformed resume packet task length") unless length($task_body) == $task_bytes;
    fail("malformed resume packet separator") unless
        substr($payload, 0, length($separator), "") eq $separator;
    fail("malformed resume packet next action length") unless
        length($payload) == $next_action_bytes;
    my $next_action = $payload;
    fail("resume packet session mismatch") unless $packet_session eq $session->{session};
    fail("resume packet role mismatch") unless $packet_role eq $role;
    fail("resume packet generation mismatch") unless $packet_generation == $generation;
    fail("resume packet turn mismatch") unless $open_turn == $session->{turn};
    fail("resume packet release mismatch") unless $release eq $session->{release};
    fail("resume packet digest mismatch") unless $digest eq $session->{digest};
    fail("resume packet protocol mismatch") unless $protocol == $session->{protocol};
    fail("resume packet release root mismatch") unless $release_root eq $session->{release_root};
    my $task = resume_task($session, $frames);
    fail("resume packet task ref is invalid") unless
        $task_ref =~ /^[0-9a-f]{64}$/ &&
        $task->{sha256} eq $task_ref &&
        $task->{block} eq $task_body;
    if ($artifact_ref ne "-") {
        my ($artifact_path, $artifact_digest) =
            $artifact_ref =~ /\A(.+)\@([0-9a-f]{64})\z/s;
        fail("resume packet artifact ref is invalid") unless
            defined $artifact_path && $artifact_path !~ /\n/;
        my $canonical_artifact = abs_path($artifact_path);
        fail("resume packet artifact is missing") unless defined $canonical_artifact;
        fail("resume packet artifact path mismatch") unless $canonical_artifact eq $artifact_path;
        fail("resume packet artifact digest mismatch") unless
            sha256_hex(read_body($canonical_artifact)) eq $artifact_digest;
    }
    fail("resume packet next action is empty") unless length($next_action);
    print join("\n",
        "session=$packet_session",
        "role=$packet_role",
        "generation=$packet_generation",
        "open_turn=$open_turn",
        "release=$release",
        "digest=$digest",
        "protocol=$protocol",
        "release_root=$release_root",
        "task_ref=$task_ref",
        "artifact_ref=$artifact_ref",
        "",
        "## Original task",
        "",
        $task_body,
        "## Next action",
        "",
        $next_action,
        "",
    );
}

sub cmd_transcript {
    my (@argv) = @_;
    my $file;
    GetOptionsFromArray(\@argv, "file=s" => \$file) or fail("bad transcript arguments");
    fail("missing --file") unless defined $file;
    my $data = read_locked($file);
    my ($frames) = parse_frames($data, 1);
    print $_->{block} for @$frames;
}

sub cmd_inspect {
    my (@argv) = @_;
    my ($file, $allow_incomplete);
    GetOptionsFromArray(
        \@argv,
        "file=s" => \$file,
        "allow-incomplete" => \$allow_incomplete,
    ) or fail("bad inspect arguments");
    fail("missing --file") unless defined $file;
    my $data = read_locked($file);
    my ($frames, $incomplete) = parse_frames($data, 1);
    fail("incomplete channel tail") if $incomplete && !$allow_incomplete;
    my $session = state_from_frames($frames);
    print "session=$session->{session}\n";
    print "driver=$session->{driver}\n";
    print "peer=$session->{peer}\n";
    print "release=$session->{release}\n";
    print "digest=$session->{digest}\n";
    print "protocol=$session->{protocol}\n";
    print "release_root=$session->{release_root}\n";
    print "progress_frames=$session->{progress_frames}\n";
    print "progress_bytes=$session->{progress_bytes}\n";
    print "heartbeat_after=$session->{heartbeat_after}\n";
    print "heartbeat_interval=$session->{heartbeat_interval}\n";
    print "semantic_timeout=$session->{semantic_timeout}\n";
    print "terminal=" . ($session->{terminal} ? 1 : 0) . "\n";
    print "expected=$session->{expected}\n";
    print "turn=$session->{turn}\n";
    print "seq=$session->{seq}\n";
    print "generation.$session->{driver}=$session->{generation}{$session->{driver}}\n";
    print "generation.$session->{peer}=$session->{generation}{$session->{peer}}\n";
    print "message_seq.$session->{driver}=$session->{message_seq}{$session->{driver}}\n";
    print "message_seq.$session->{peer}=$session->{message_seq}{$session->{peer}}\n";
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
    $silence_seconds = 540;
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
    my $peer_exit;
    my %seen;
    my @semantic;
    while (1) {
        my $data = read_locked($file);
        my ($frames) = parse_frames($data, 1);
        my $session = @$frames ? state_from_frames($frames) : undef;
        if ($session) {
            fail("stale receiver generation") unless
                exists $session->{generation}{$me} &&
                $generation == $session->{generation}{$me};
            if (!defined $turn_started && !$session->{terminal} && $session->{expected} ne $me) {
                my ($floor_frame) = reverse grep {
                    $_->{kind} eq "message" &&
                    $_->{state} eq "over" &&
                    $_->{turn} == $session->{turn} - 1
                } @$frames;
                $floor_frame = $frames->[0] unless $floor_frame;
                my $replacement_tag =
                    "replace=$session->{expected}.$session->{generation}{$session->{expected}}";
                my ($replacement_frame) = reverse grep {
                    $_->{kind} eq "control" &&
                    $_->{tag} eq $replacement_tag &&
                    $_->{seq} > $floor_frame->{seq}
                } @$frames;
                $floor_frame = $replacement_frame if $replacement_frame;
                $turn_started = timestamp_epoch($floor_frame->{ts});
            }
        }
        my @after = grep { $_->{end} > $offset } @$frames;
        my $complete_end;
        for my $frame (@after) {
            next if $frame->{end} <= $offset;
            next if $seen{$frame->{end}}++;
            $last_frame = time();
            next if $frame->{stale};
            next if $frame->{sender} eq $me;
            if ($frame->{kind} eq "status" && $frame->{tag} =~ /^exit=(\d+)$/) {
                $peer_exit = { frame => $frame, status => $1 };
                next;
            }
            if ($frame->{kind} eq "control" && $frame->{state} eq "terminal") {
                push @semantic, $frame;
                $complete_end = $frame->{end};
                last;
            }
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
        if ($peer_exit && $session && !$session->{terminal}) {
            my $frame = $peer_exit->{frame};
            print "__PEER_EXIT__ session=$session->{session} turn=$frame->{turn} " .
                "sender=$frame->{sender} gen=$frame->{generation} " .
                "status=$peer_exit->{status}\n";
            exit 4;
        }
        if (!@semantic && $session && !$session->{terminal} && $session->{expected} eq $me) {
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

sub cmd_wait_control {
    my (@argv) = @_;
    my ($file, $cursor, $me, $tag, $timeout);
    $timeout = 30;
    GetOptionsFromArray(
        \@argv,
        "file=s" => \$file,
        "cursor=s" => \$cursor,
        "me=s" => \$me,
        "tag=s" => \$tag,
        "timeout=f" => \$timeout,
    ) or fail("bad wait-control arguments");
    fail("missing wait-control argument") unless
        defined $file && defined $cursor && valid_name($me) && valid_tag($tag);
    my $offset = cursor_offset($cursor);
    my $deadline = time() + $timeout;
    while (1) {
        my $data = read_locked($file);
        my ($frames, $incomplete) = parse_frames($data, 1);
        fail("incomplete channel tail") if $incomplete;
        state_from_frames($frames);
        for my $frame (@$frames) {
            next if $frame->{end} <= $offset;
            next if $frame->{stale};
            next if $frame->{sender} eq $me;
            next unless $frame->{kind} eq "control" && $frame->{tag} eq $tag;
            write_cursor($cursor, $frame->{end});
            print $frame->{block};
            return;
        }
        if (time() >= $deadline) {
            print "__CONTROL_TIMEOUT__ tag=$tag\n";
            exit 2;
        }
        sleep(0.05);
    }
}

my $command = shift(@ARGV) // "";
my %commands = (
    init => sub { cmd_init(@ARGV) },
    append => sub { cmd_append(@ARGV) },
    resume => sub { cmd_resume(0, @ARGV) },
    "recover-tail" => sub { cmd_resume(1, @ARGV) },
    "resume-packet" => sub { cmd_resume_packet(@ARGV) },
    recv => sub { cmd_recv(@ARGV) },
    "wait-control" => sub { cmd_wait_control(@ARGV) },
    transcript => sub { cmd_transcript(@ARGV) },
    inspect => sub { cmd_inspect(@ARGV) },
);
my $handler = $commands{$command};
fail("unknown command '$command'") unless $handler;
$handler->();
