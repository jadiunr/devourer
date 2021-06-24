package Devourer::CLI::fetch::twitter;
use Moo;
use utf8;
use feature 'say';
use Getopt::Compact;
use Time::Piece;
use File::Basename 'basename';
use File::Path 'mkpath';
use Twitter::API;
use YAML::Tiny;
use Furl;
use Data::Dumper;

has settings => (is => 'ro', default => sub { YAML::Tiny->read('./settings.yml')->[0]; });
has http => (is => 'ro', default => sub { Furl->new(); });
has twitter => (is => 'ro', lazy => 1, default => sub {
    my $self = shift;
    Twitter::API->new_with_traits(
        traits              => ['Enchilada', 'RateLimiting'],
        consumer_key        => $self->settings->{twitter}{consumer_key},
        consumer_secret     => $self->settings->{twitter}{consumer_secret},
        access_token        => $self->settings->{twitter}{access_token},
        access_token_secret => $self->settings->{twitter}{access_token_secret}
    );
});
has saved_files => (is => 'ro', lazy => 1, default => sub {
    my $self = shift;
    [map {basename($_)} (split /\n/, `find @{[$self->settings->{outdir}]} -type f`)];
});
has favorited_statuses => (is => 'ro', lazy => 1, default => sub {
    my $self = shift;
    my $statuses = [map {(split '-', basename($_))[0]} (split /\n/, `find @{[$self->settings->{outdir}]}/favorited -type f -a -mtime -30 -print`)];
    $statuses = [grep {$_ =~ /^\d+$/} @$statuses];
    return [sort {$b <=> $a} @$statuses];
});
has opts => (is => 'ro', default => sub {
    Getopt::Compact->new(
        name => 'devourer fetch twitter',
        struct => [
            [[qw(u user)], qq(fetch specified target user's post), ':s'],
            [[qw(fav)], qq(fetch user's favorites instead of post)],
            [[qw(d devour)], qq(JUST DEVOUR!)]
        ]
    )->opts;
});

sub run {
    my $self = shift;

    if (scalar(keys %{$self->opts}) == scalar(grep { !defined $_ } values(%{$self->opts}))) {
        $self->_standard_fetch();
        exit;
    }

    if ($self->opts->{user}) {
        my $splitted_users = [split /,/, $self->opts->{user}];
        $self->_fetch_from_users($splitted_users);
        exit;
    }

    if ($self->opts->{devour}) {
        $self->_devour();
        exit;
    }
}

sub _standard_fetch {
    my $self = shift;

    my $mediators = $self->settings->{mediators};
    my $all_statuses;

    my $timeline = $self->_get_home_timeline();
    push(@$all_statuses, @$timeline);

    for my $mediator (@$mediators) {
        my $favorites = $self->_get_favorites($mediator);
        push(@$all_statuses, @$favorites);
    }

    my $sorted_statuses = $self->_sort_and_uniq_statuses($all_statuses);

    for my $status (@$sorted_statuses) {
        my $media_array = $status->{extended_entities}{media};
        $self->_download($media_array, $status->{id}) if $media_array;
    }

    my $rate_limit_status = $self->twitter->rate_limit_status()->{resources};
    say Dumper $rate_limit_status->{favorites};
    say Dumper $rate_limit_status->{statuses}{'/statuses/home_timeline'};
    say Dumper $rate_limit_status->{statuses}{'/statuses/user_timeline'};
}

sub _fetch_from_users {
    my ($self, $users) = @_;

    for my $user (@$users) {
        my $statuses = $self->opts->{fav} ? $self->_get_favorites($user) : $self->_get_user_timeline($user);
        my $sorted_statuses = $self->_sort_and_uniq_statuses($statuses);

        for my $status (@$sorted_statuses) {
            my $media_array = $status->{extended_entities}{media};
            $self->_download($media_array, $status->{id}) if $media_array;
        }

        my $rate_limit_status = $self->twitter->rate_limit_status()->{resources};
        say Dumper $rate_limit_status->{favorites};
        say Dumper $rate_limit_status->{statuses}{'/statuses/home_timeline'};
        say Dumper $rate_limit_status->{statuses}{'/statuses/user_timeline'};
    }
}

sub _devour {
    my $self = shift;

    for my $status (@{$self->favorited_statuses}) {
        my $user_id = eval { $self->twitter->show_status($status)->{user}{id} };
        warn "$@: $status" and next if $@;
        
        my $max_id;
        for my $iter (1..16) {
            my $user_statuses;
            $user_statuses = $self->twitter->user_timeline({user_id => $user_id, count => 200}) if !defined($max_id);
            $user_statuses = $self->twitter->user_timeline({user_id => $user_id, count => 200, max_id => $max_id}) if defined($max_id);
            
            for my $user_status (@$user_statuses) {
                my $media_array = $user_status->{extended_entities}{media};
                $self->_download($media_array, $user_status->{id}) if $media_array;
            }

            my $rate_limit_status = $self->twitter->rate_limit_status()->{resources};
            my $user_timeline_limit = $rate_limit_status->{statuses}{'/statuses/user_timeline'};
            my $show_statuses_limit = $rate_limit_status->{statuses}{'/statuses/show/:id'};

            say "user_timeline limit: ". $user_timeline_limit->{remaining}. "/". $user_timeline_limit->{limit};
            say "show_statuses_limit: ". $show_statuses_limit->{remaining}. "/". $show_statuses_limit->{limit};

            last if scalar(@$user_statuses) < 200;
        }
    }
}

sub _get_home_timeline {
    my $self = shift;

    my $all_statuses;
    my $max_id;
    for my $iter (1..4) {
        my $timeline;
        $timeline = $self->twitter->home_timeline({count => 200}) if !defined($max_id);
        $timeline = $self->twitter->home_timeline({count => 200, max_id => $max_id}) if defined($max_id);
        push(@$all_statuses, @$timeline);
        $max_id = $timeline->[-1]{id};
    }

    return $all_statuses;
}

sub _get_favorites {
    my ($self, $user) = @_;

    my $all_statuses;
    my $max_id;
    for my $iter (1..5) {
        my $favorites;
        $favorites = $self->twitter->favorites({screen_name => $user, count => 200}) if !defined($max_id);
        $favorites = $self->twitter->favorites({screen_name => $user, count => 200, max_id => $max_id}) if defined($max_id);
        push(@$all_statuses, @$favorites);
        $max_id = $favorites->[-1]{id};
    }

    return $all_statuses;
}

sub _get_user_timeline {
    my ($self, $user) = @_;

    my $all_statuses;
    my $max_id;
    for my $iter (1..16) {
        my $statuses;
        $statuses = $self->twitter->user_timeline({screen_name => $user, count => 200}) if !defined($max_id);
        $statuses = $self->twitter->user_timeline({screen_name => $user, count => 200, max_id => $max_id}) if defined($max_id);
        push(@$all_statuses, @$statuses);
        $max_id = $statuses->[-1]{id};
        last if scalar(@$statuses) < 200;
    }

    return $all_statuses;
}

sub _sort_and_uniq_statuses {
    my ($self, $statuses) = @_;

    my %tmp;
    my $unique_statuses = [grep {!$tmp{$_->{id}}++} @$statuses];
    my $sorted_statuses = [sort {
        Time::Piece->strptime($a->{created_at}, '%a %b %d %T %z %Y')
        <=>
        Time::Piece->strptime($b->{created_at}, '%a %b %d %T %z %Y')
    } @$unique_statuses];

    return $sorted_statuses;
}

sub _download {
    my $self = shift;
    my $media_array = shift;
    my $status_id = $media_array->[0]{source_status_id} ? $media_array->[0]{source_status_id} : shift;
    my $binary;

    if($media_array->[0]{video_info}) {
        my $video = $media_array->[0]{video_info}{variants};
        for (@$video) { $_->{bitrate} = 0 unless $_->{bitrate} }
        my $url = (sort { $b->{bitrate} <=> $a->{bitrate} } @$video)[0]{url};
        $url =~ s/\?.+//;

        my $filename = $status_id."-".basename($url);

        if (grep {$filename eq $_} @{$self->saved_files} or -f "@{[$self->settings->{outdir}]}/searching/$filename") {
            say "[@{[ localtime->datetime ]}]Already saved     : $filename";
            return;
        }

        $binary = $self->http->get($url);
        warn "[@{[ localtime->datetime ]}]Cannot fetch video: returned " . $binary->code . ", url: $url" and return
            if grep {$_ eq $binary->code} (404, 500);
        $self->_save($filename, $binary);
    } else {
        for my $image (@$media_array) {
            my $url = $image->{media_url};

            my $filename = $status_id."-".basename($url);
            if (grep {$filename eq $_} @{$self->saved_files} or -f "@{[$self->settings->{outdir}]}/searching/$filename") {
                say "[@{[ localtime->datetime ]}]Already saved     : $filename";
                return;
            }

            $binary = $self->http->get($url.'?name=orig');
            warn "[@{[ localtime->datetime ]}]Cannot fetch image: returned " . $binary->code . ", url: $url" and next
                if grep {$_ eq $binary->code} (404, 500);
            $self->_save($filename, $binary);
        }
    }
}

sub _save {
  my ($self, $filename, $binary) = @_;

  open my $fh, ">", "./@{[$self->settings->{outdir}]}/searching/$filename"
    or die "[@{[ localtime->datetime ]}]Cannot create file: $!, filename: ".$filename;
  say $fh $binary->content;
  close $fh;
  say "[@{[ localtime->datetime ]}]Image saved       : $filename";
}

1;
