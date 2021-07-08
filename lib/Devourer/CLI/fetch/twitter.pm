package Devourer::CLI::fetch::twitter;
use Moo;
use utf8;
use Getopt::Compact;
use Time::Piece;
use File::Basename 'basename';
use File::Path 'mkpath';
use Twitter::API;
use YAML::Tiny;
use Furl;
use Parallel::ForkManager;
use Redis;
use Data::Dumper;
use Log::Dispatch;

has nproc => (is => 'ro', default => sub { chomp(my $nproc = `nproc --all`); $nproc });
has logger => (is => 'ro', default => sub {
    Log::Dispatch->new(
        outputs => [['Screen', min_level => 'info', newline => 1]]
    );
});
has settings => (is => 'ro', default => sub { YAML::Tiny->read('./settings.yml')->[0] });
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
has redis => (is => 'ro', default => sub { Redis->new(server => 'redis:6379'); });
has opts => (is => 'ro', default => sub {
    Getopt::Compact->new(
        name => 'devourer fetch twitter',
        struct => [
            [[qw(init)], qq(Initialize Redis DB)],
            [[qw(f no-fav)], qq(Do not fetch mediators favourites)],
            [[qw(l no-list)], qq(Do not fetch list users statuses)]
        ]
    )->opts;
});

sub run {
    my $self = shift;

    $self->_logging_rate_limit_status();

    # init
    if ($self->opts->{init}) {
        $self->logger->info('Initializing Redis DB...');
        $self->redis->flushdb();
        $self->redis->set(basename($_), 1) for (split /\n/, `find @{[$self->settings->{outdir}]} -type f`);
        $self->logger->info('Initialize Redis DB done!');
        exit;
    }

    if (!$self->opts->{'no-fav'}) {
        $self->logger->info('Mediators favorites fetching started!');

        my $mediators = $self->settings->{mediators};
        while (my $mediators_slice = [splice @$mediators, 0, $self->nproc]) {
            my $statuses = $self->_get_users_favorites($mediators_slice);
            my $media_urls = $self->_extract_file_name_and_url($statuses);
            $self->_download($media_urls);
            last unless @$mediators;
        }

        $self->logger->info('Mediators favorites fetching done!');
    }

    if (!$self->opts->{'no-list'}) {
        $self->logger->info('List users statuses fetching started!');

        my $lists = $self->settings->{lists};
        for my $list (@$lists) {
            my $users = $self->_get_list_users($list);
            while (my $users_slice = [splice @$users, 0, $self->nproc]) {
                my $statuses = $self->_get_user_timelines($users_slice);
                my $media_urls = $self->_extract_file_name_and_url($statuses);
                $self->_download($media_urls);
                last unless @$users;
            }
        }

        $self->logger->info('List users statuses fetching done!');
    }

    $self->logger->info('All done... I ate too much, I\'m full. :yum:');
}

sub _get_users_favorites {
    my ($self, $users) = @_;

    $self->_logging_rate_limit_status();

    my $pm = Parallel::ForkManager->new($self->nproc);
    my $users_favorites;
    $pm->run_on_finish(sub {
        my $code = $_[1];
        my $all_statuses = $_[5];
        push(@$users_favorites, @$all_statuses) if scalar(@$all_statuses) > 1;
    });
    for my $user (@$users) {
        $pm->start($user) and next;
        my $all_statuses;
        my $max_id;
        for my $iter (1..4) {
            my $statuses = $self->twitter->favorites({screen_name => $user, count => 200, defined($max_id) ? (max_id => $max_id) : ()});
            last if scalar(@$statuses) <= 1;
            push(@$all_statuses, @$statuses);
            $max_id = $statuses->[-1]{id};
            $self->logger->info('Got '. $user. '\'s favorites. Next start with max_id='. $max_id);
        }
        $pm->finish(0, $all_statuses);
    }
    $pm->wait_all_children;

    $self->logger->info('Got all '. scalar(@$users). ' users '. scalar(@$users_favorites). ' favorites.');

    return $users_favorites;
}

sub _get_user_timelines {
    my ($self, $users) = @_;

    $self->_logging_rate_limit_status();

    my $pm = Parallel::ForkManager->new($self->nproc);
    my $users_timeline;
    $pm->run_on_finish(sub {
        my $code = $_[1];
        my $all_statuses = $_[5];
        push(@$users_timeline, @$all_statuses) if scalar(@$all_statuses) > 1;
    });
    for my $user (@$users) {
        $pm->start and next;
        my $all_statuses;
        my $max_id;
        for my $iter (1..16) {
            my $statuses = $self->twitter->user_timeline({screen_name => $user, count => 200, defined($max_id) ? (max_id => $max_id) : ()});
            last if scalar(@$statuses) <= 1;
            push(@$all_statuses, @$statuses);
            $max_id = $statuses->[-1]{id};
            $self->logger->info('Got '. $user. '\'s statuses. Next start with max_id='. $max_id);
        }
        $pm->finish(0, $all_statuses);
    }
    $pm->wait_all_children;

    $self->logger->info('Got all '. scalar(@$users). ' users statuses.');

    return $users_timeline;
}

sub _get_list_users {
    my ($self, $list) = @_;

    $self->_logging_rate_limit_status();

    my $members = $self->twitter->list_members({list_id => $list, count => 5000})->{users};
    my $members_screen_name = [map { $_->{screen_name} } @$members];

    $self->logger->info('Got '. scalar(@$members_screen_name). ' users screen name.');

    return $members_screen_name;
}

sub _logging_rate_limit_status {
    my ($self) = @_;
    my $limit = $self->twitter->rate_limit_status({resources => ['statuses', 'favorites', 'lists']})->{resources};
    my $user_timeline_remaining = $limit->{statuses}{'/statuses/user_timeline'}{remaining};
    my $favorites_remaining = $limit->{favorites}{'/favorites/list'}{remaining};
    my $list_members_remaining = $limit->{lists}{'/lists/members'}{remaining};
    $self->logger->info("Rate Limitting info: user_timeline: $user_timeline_remaining, favorites: $favorites_remaining, list_members: $list_members_remaining");
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
            next if $self->redis->get($filename);
            $media_info->{$filename} = $url;
        } else {
            for my $media (@$media_array) {
                my $url = $media->{media_url};
                my $filename = $status_id."-".basename($url);
                next if $self->redis->get($filename);
                $media_info->{$filename} = $url. '?name=orig';
            }
        }
    }

    $self->logger->info('Extracted '. scalar(%$media_info). ' media files.');

    return $media_info;
}

sub _download {
    my $self = shift;
    my $media_urls = shift;
    my $pm = Parallel::ForkManager->new($self->nproc);
    my $filenames = [sort keys %$media_urls];

    while (my $filename_slice = [splice @$filenames, 0, $self->nproc * 10]) {
        my $binaries = {};
        $pm->run_on_finish(sub {
            my $code = $_[1];
            $binaries->{$_[5]->[0]} = $_[5]->[1] if $code == 0;
        });
        for my $filename (@$filename_slice) {
            $pm->start and next;
            if ($self->redis->get($filename)) {
                $self->logger->info($filename. ' is already stored.');
                $pm->finish(-1, [$filename, undef]);
            }
            my $res = $self->http->get($media_urls->{$filename});
            $self->logger->warn('Cannot download this video '. $media_urls->{$filename}. ' with HTTP Status Code '. $res->code) and $pm->finish(-1, [$filename, undef]) if $res->code != 200;
            $self->logger->info('Media file downloaded! URL: '. $media_urls->{$filename});
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

    mkdir "./@{[$self->settings->{outdir}]}/searching/$year" and $self->logger->info($year. ' directory is not exist, so a new one has been created') unless -d "./@{[$self->settings->{outdir}]}/searching/$year";
    mkdir "./@{[$self->settings->{outdir}]}/searching/$year/$month" and $self->logger->info($year. '/'. $month. ' directory is not exist, so a new one has been created') unless -d "./@{[$self->settings->{outdir}]}/searching/$year/$month";
    mkdir "./@{[$self->settings->{outdir}]}/searching/$year/$month/$day" and $self->logger->info($year. '/'. $month. '/'. $day. ' directory is not exist, so a new one has been created') unless -d "./@{[$self->settings->{outdir}]}/searching/$year/$month/$day";

    for my $filename (@{[sort keys %$binaries]}) {
        open my $fh, ">", "./@{[$self->settings->{outdir}]}/searching/$year/$month/$day/$filename"
            or die "Cannot create file: $!, filename: ".$filename;
        print $fh $binaries->{$filename}->content;
        close $fh;
        $self->redis->set($filename, 1);
        $self->logger->info('Media file stored in storage! Filename: '. $filename);
    }
}

1;
