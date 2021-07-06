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
use Parallel::ForkManager;
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
            [[qw(l list)], qq(fetch specified target list's post), ':s'],
            [[qw(f fav)], qq(fetch user's favorites instead of post)],
            [[qw(d devour)], qq(JUST DEVOUR!)]
        ]
    )->opts;
});

sub run {
    my $self = shift;

    # init
    $self->saved_files;

    if (scalar(keys %{$self->opts}) == scalar(grep { !defined $_ } values(%{$self->opts}))) {
        $self->_standard_fetch();
        exit;
    }

    if ($self->opts->{user}) {
        my $splitted_users = [split /,/, $self->opts->{user}];
        $self->_fetch_from_users($splitted_users);
        exit;
    }

    if ($self->opts->{list}) {
        my $splitted_lists = [split /,/, $self->opts->{list}];
        $self->_fetch_from_lists($splitted_lists);
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
    my $lists = $self->settings->{lists};
    my ($statuses, $media_urls, $binaries);

    $statuses = $self->_get_home_timeline();
    $media_urls = $self->_extract_file_name_and_url($statuses);
    $binaries = $self->_download($media_urls);

    for my $mediator (@$mediators) {
        $statuses = $self->_get_user_favorites($mediator);
        $media_urls = $self->_extract_file_name_and_url($statuses);
        $binaries = $self->_download($media_urls);
    }

    for my $list (@$lists) {
        my $users = $self->_get_list_users($list);
        while (my $users_slice = [splice @$users, 0, 8]) {
            $statuses = $self->_get_user_timelines($users_slice);
            $media_urls = $self->_extract_file_name_and_url($statuses);
            $binaries = $self->_download($media_urls);
            last unless @$users;
        }
    }
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
        say Dumper $rate_limit_status->{statuses}{'/statuses/user_timeline'};
    }
}

sub _fetch_from_lists {
    my ($self, $lists) = @_;

    for my $list_id (@$lists) {
        my $statuses = $self->_get_list_statuses($list_id);
        my $sorted_statuses = $self->_sort_and_uniq_statuses($statuses);

        for my $status (@$sorted_statuses) {
            my $media_array = $status->{extended_entities}{media};
            $self->_download($media_array, $status->{id}) if $media_array;
        }

        my $users = $self->_extract_user_screen_names($sorted_statuses);

        for my $user (@$users) {
            my $user_timeline = $self->_get_user_timeline($user);

            for my $status (@$user_timeline) {
                my $media_array = $status->{extended_entities}{media};
                $self->_download($media_array, $status->{id}) if $media_array;
            }

            my $rate_limit_status = $self->twitter->rate_limit_status()->{resources};
            say Dumper $rate_limit_status->{statuses}{'/statuses/user_timeline'};
        }

        my $rate_limit_status = $self->twitter->rate_limit_status()->{resources};
        say Dumper $rate_limit_status->{lists}{'/lists/statuses'};
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

            $max_id = $user_statuses->[-1]{id};
            last if scalar(@$user_statuses) < 200;
        }
    }
}

sub _get_home_timeline {
    my $self = shift;
    my $all_statuses = [];
    my $max_id;

    for my $iter (1..4) {
        my $statuses = $self->twitter->home_timeline({count => 200, defined($max_id) ? (max_id => $max_id) : ()});
        last if scalar(@$statuses) <= 1;
        push(@$all_statuses, @$statuses);
        $max_id = $statuses->[-1]{id};
        say "fetch tweets: ". scalar(@$statuses);
    }

    return $all_statuses;
}

sub _get_user_favorites {
    my ($self, $user) = @_;
    my $all_statuses = [];
    my $max_id;

    for my $iter (1..4) {
        my $favorites = $self->twitter->favorites({screen_name => $user, count => 200, defined($max_id) ? (max_id => $max_id) : ()});
        last if scalar(@$favorites) <= 1;
        push(@$all_statuses, @$favorites);
        $max_id = $favorites->[-1]{id};
        say "fetch tweets: ". scalar(@$favorites);
    }

    return $all_statuses;
}

sub _get_user_timeline {
    my ($self, $user) = @_;

    my $all_statuses;
    my $max_id;
    for my $iter (1..16) {
        my $statuses;
        $statuses = $self->twitter->user_timeline({screen_name => $user, count => 200, defined($max_id) ? (max_id => $max_id) : ()});
        last if scalar(@$statuses) <= 1;
        push(@$all_statuses, @$statuses);
        $max_id = $statuses->[-1]{id};
    }

    return $all_statuses;
}

sub _get_user_timelines {
    my ($self, $users_slice) = @_;
    my $pm = Parallel::ForkManager->new(8);
    my $users_timeline;
    $pm->run_on_finish(sub {
        my $code = $_[1];
        my $all_statuses = $_[5];
        push(@$users_timeline, @$all_statuses);
    });
    for my $user (@$users_slice) {
        $pm->start and next;
        my $all_statuses;
        my $max_id;
        for my $iter (1..16) {
            my $statuses = $self->twitter->user_timeline({screen_name => $user, count => 200, defined($max_id) ? (max_id => $max_id) : ()});
            last if scalar(@$statuses) <= 1;
            push(@$all_statuses, @$statuses);
            $max_id = $statuses->[-1]{id};
        }
        $pm->finish(0, $all_statuses);
    }
    $pm->wait_all_children;

    return $users_timeline;
}

sub _get_list_users {
    my ($self, $list) = @_;

    my $members = $self->twitter->list_members({list_id => $list, count => 5000})->{users};
    my $members_screen_name = [map { $_->{screen_name} } @$members];

    return $members_screen_name;
}

sub _get_list_statuses {
    my ($self, $list_id) = @_;

    my $all_statuses;
    my $max_id;
    for my $iter (1..16) {
        my $statuses;
        $statuses = $self->twitter->list_statuses({list_id => $list_id, count => 200, defined($max_id) ? (max_id => $max_id) : ()});
        last if scalar(@$statuses) <= 1;
        push(@$all_statuses, @$statuses);
        $max_id = $statuses->[-1]{id};
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

sub _extract_user_screen_names {
    my ($self, $statuses) = @_;

    my %tmp;
    my $user_screen_names = [map {$_->{user}{screen_name}} @$statuses];
    my $unique_user_screen_names = [grep {!$tmp{$_}++} @$user_screen_names];

    return $unique_user_screen_names;
}

sub _extract_file_name_and_url {
    my ($self, $all_statuses) = @_;
    my $media_info = {};
    for my $status (@$all_statuses) {
        my $media_array = $status->{extended_entities}{media};
        next unless $media_array;
        my $status_id = $media_array->[0]{source_status_id} ? $media_array->[0]{source_status_id} : $status->{id};
        if ($media_array->[0]{video_info}) {
            my $video = $media_array->[0]{video_info}{variants};
            for (@$video) { $_->{bitrate} = 0 unless $_->{bitrate} }
            my $url = (sort { $b->{bitrate} <=> $a->{bitrate} } @$video)[0]{url};
            $url =~ s/\?.+//;
            my $filename = $status_id."-".basename($url);
            $media_info->{$filename} = $url;
        } else {
            for my $media (@$media_array) {
                my $url = $media->{media_url};
                my $filename = $status_id."-".basename($url);
                $media_info->{$filename} = $url. '?name=orig';
            }
        }
    }
    delete($media_info->{$_}) for @{ $self->saved_files };
    return $media_info;
}

sub _download {
    my $self = shift;
    my $media_urls = shift;
    my $pm = Parallel::ForkManager->new(8);
    my $filenames = [sort keys %$media_urls];

    while (my $filename_slice = [splice @$filenames, 0, 8]) {
        my $binaries = {};
        $pm->run_on_finish(sub {
            my $code = $_[1];
            $binaries->{$_[5]->[0]} = $_[5]->[1] if $code == 0;
        });
        for my $filename (@$filename_slice) {
            $pm->start and next;
            if (grep {$filename eq $_} @{$self->saved_files}) {
                say "[@{[ localtime->datetime ]}]Already saved     : $filename";
                $pm->finish(-1, [$filename, undef]);
            }
            my $res = $self->http->get($media_urls->{$filename});
            warn "[@{[ localtime->datetime ]}]Cannot fetch video: returned ". $res->code. ", url: ". $media_urls->{$filename} and $pm->finish(-1, [$filename, undef])
                if $res->code != 200;
            say "[@{[ localtime->datetime ]}]Media downloaded!     : ". $media_urls->{$filename};
            $pm->finish(0, [$filename, $res]);
        }
        $pm->wait_all_children;
        $self->_store($binaries);
        last unless @$filenames;
    }
}

sub _store {
    my ($self, $binaries) = @_;
    my $now = localtime;
    my ($year, $month, $day) = ($now->year, $now->strftime('%m'), $now->strftime('%d'));

    mkdir "./@{[$self->settings->{outdir}]}/searching/$year" unless -d "./@{[$self->settings->{outdir}]}/searching/$year";
    mkdir "./@{[$self->settings->{outdir}]}/searching/$year/$month" unless -d "./@{[$self->settings->{outdir}]}/searching/$year/$month";
    mkdir "./@{[$self->settings->{outdir}]}/searching/$year/$month/$day" unless -d "./@{[$self->settings->{outdir}]}/searching/$year/$month/$day";

    for my $filename (@{[sort keys %$binaries]}) {
        open my $fh, ">", "./@{[$self->settings->{outdir}]}/searching/$year/$month/$day/$filename"
            or die "[@{[ localtime->datetime ]}]Cannot create file: $!, filename: ".$filename;
        say $fh $binaries->{$filename}->content;
        close $fh;
        push(@{ $self->saved_files }, $filename);
        say "[@{[ localtime->datetime ]}]Image stored       : $filename";
    }
}

1;
