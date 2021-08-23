package Devourer::CLI::Twitter::Fetch;
use Moo;
use utf8;
use Getopt::Compact;
use Time::Piece;
use File::Basename qw(basename dirname);
use File::Copy 'move';
use File::Path 'mkpath';
use Twitter::API;
use YAML::Tiny;
use JSON 'encode_json';
use Furl;
use Parallel::ForkManager;
use Redis;
use Log::Dispatch;
use Clone 'clone';
use Time::HiRes 'sleep';

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
has current_list_members => (is => 'rw', default => sub { [] });
has stored_media_files => (is => 'ro', default => sub { Redis->new(server => 'redis:6379'); });
has stored_list_members => (is => 'ro', default => sub {
    my $redis = Redis->new(server => 'redis:6379');
    $redis->select(1);
    return $redis;
});
has read_members => (is => 'ro', default => sub {
    my $redis = Redis->new(server => 'redis:6379');
    $redis->select(2);
    return $redis;
});
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

    # Init Redis
    if ($self->opts->{init}) {
        $self->logger->info('Initializing Redis DB...');
        $self->stored_media_files->flushdb();
        $self->stored_media_files->set(basename($_), $_) for (split /\n/, `find @{[$self->settings->{outdir}]} -type f`);
        $self->stored_list_members->flushdb();
        $self->read_members->flushdb();
        $self->logger->info('Initialize done!');
        exit;
    }

    if (!$self->opts->{'no-list'}) {
        $self->logger->info('List members statuses fetching started!');

        push(@{ $self->current_list_members }, @{ $self->_get_list_members($_) }) for @{ $self->settings->{lists} };
        my $list_members_max_num = @{ $self->current_list_members };
        my $list_members_cur_num = 0;
        while (my $member_ids_slice = [splice @{ $self->current_list_members }, 0, $self->nproc]) {
            $list_members_cur_num += @$member_ids_slice;
            $self->logger->info("$list_members_cur_num/$list_members_max_num members fetching...");
            my $statuses = $self->_get_user_timelines($member_ids_slice);
            my $media_urls = $self->_extract_file_name_and_url($statuses, $self->settings->{min_followers});
            $self->_download($media_urls);
            last unless @{ $self->current_list_members };
        }

        $self->logger->info('List members statuses fetching done!');
    }

    if (!$self->opts->{'no-fav'}) {
        $self->logger->info('Mediators favorites fetching started!');

        my $mediators = clone($self->settings->{mediators});
        while (my $mediators_slice = [splice @$mediators, 0, $self->nproc]) {
            my $statuses = $self->_get_users_favorites($mediators_slice);
            my $media_urls = $self->_extract_file_name_and_url($statuses, 0);
            $self->_download($media_urls);
            last unless @$mediators;
        }

        $self->logger->info('Mediators favorites fetching done!');
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
            $max_id = $statuses->[-1]{id_str};
            $self->logger->info('Got '. $user. '\'s favorites. Next start with max_id='. $max_id);
        }
        $pm->finish(0, $all_statuses);
    }
    $pm->wait_all_children;

    $self->logger->info('Got all '. scalar(@$users). ' users '. scalar(@$users_favorites). ' favorites.');

    return $users_favorites;
}

sub _get_user_timelines {
    my ($self, $user_ids) = @_;

    $self->_logging_rate_limit_status();

    my $pm = Parallel::ForkManager->new($self->nproc);
    my $users_timeline;
    $pm->run_on_finish(sub {
        my $code = $_[1];
        my $all_statuses = $_[5];
        return unless defined($all_statuses);
        push(@$users_timeline, @$all_statuses) if scalar(@$all_statuses) > 1;
    });
    for my $user_id (@$user_ids) {
        $pm->start and next;
        my $all_statuses;
        my $max_id;
        my $is_stored_member = $self->stored_list_members->get($user_id) ? 1 : undef;
        for my $iter (1..16) {
            my $statuses = eval { $self->twitter->user_timeline({user_id => $user_id, count => 200, defined($max_id) ? (max_id => $max_id) : ()}) };
            last unless defined($statuses);
            last if scalar(@$statuses) <= 0;
            my $screen_name = $statuses->[0]{user}{screen_name};
            push(@$all_statuses, @$statuses);
            $max_id = $statuses->[-1]{id_str};
            if ($is_stored_member) {
                $self->logger->info("Got $screen_name ($user_id)'s statuses");
                last;
            } else {
                $self->logger->info("Got $screen_name ($user_id)'s statuses. Next start with max_id=$max_id");
            }
        }
        $self->stored_list_members->set($user_id, 1) unless $is_stored_member;
        $pm->finish(0, $all_statuses);
    }
    $pm->wait_all_children;

    $self->logger->info('Got all '. scalar(@$user_ids). ' users, '. scalar(@$users_timeline). ' statuses.');

    return $users_timeline;
}

sub _get_list_members {
    my ($self, $list) = @_;

    $self->_logging_rate_limit_status();

    my $members = $self->twitter->list_members({list_id => $list, count => 5000})->{users};
    my $member_ids = [map { $_->{id_str} } @$members];

    $self->logger->info('Got '. scalar(@$member_ids). ' members screen name.');

    return $member_ids;
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
    my ($self, $all_statuses, $min_followers_count) = @_;
    my $rename_list = [];
    my $media_info = {};
    for my $status (@$all_statuses) {
        my $media_array = $status->{extended_entities}{media};
        next unless $media_array;
        $self->_notify_to_slack_if_not_read_yet($status, $min_followers_count) if $self->settings->{discord_webhook_url};
        my $status_id = $media_array->[0]{source_status_id_str} ? $media_array->[0]{source_status_id_str} : $status->{id_str};
        my $user_id = $status->{retweeted_status} ? $status->{retweeted_status}{user}{id_str} : $status->{user}{id_str};
        if ($media_array->[0]{video_info}) {
            my $video = $media_array->[0]{video_info}{variants};
            for (@$video) { $_->{bitrate} = 0 unless $_->{bitrate} }
            my $url = (sort { $b->{bitrate} <=> $a->{bitrate} } @$video)[0]{url};
            $url =~ s/\?.+//;
            my $old_filename = $status_id."-".basename($url);
            my $filename = $user_id."-".$status_id."-".basename($url);
            if (my $old_path = $self->stored_media_files->get($old_filename)) {
                my $new_path = dirname($old_path). "/$filename";
                move $old_path, $new_path;
                $self->stored_media_files->del($old_filename);
                $self->stored_media_files->set($filename, $new_path);
                $self->logger->info("FILE MOVED! '$old_filename' TO '$filename'");
                next;
            }
            next if $self->stored_media_files->get($filename);
            $media_info->{$filename} = $url;
        } else {
            for my $media (@$media_array) {
                my $url = $media->{media_url};
                my $old_filename = $status_id."-".basename($url);
                my $filename = $user_id."-".$status_id."-".basename($url);
                if (my $old_path = $self->stored_media_files->get($old_filename)) {
                    my $new_path = dirname($old_path). "/$filename";
                    move $old_path, $new_path;
                    $self->stored_media_files->del($old_filename);
                    $self->stored_media_files->set($filename, $new_path);
                    $self->logger->info("FILE MOVED! '$old_filename' TO '$filename'");
                    next;
                }
                next if $self->stored_media_files->get($filename);
                $media_info->{$filename} = $url. '?name=orig';
            }
        }
    }

    $self->logger->info('Extracted '. scalar(%$media_info). ' media files.');

    return $media_info;
}

sub _notify_to_slack_if_not_read_yet {
    my ($self, $status, $min_followers_count) = @_;
    my $orig_status = $status->{retweeted_status} ? $status->{retweeted_status} : $status;
    my $user_id = $orig_status->{user}{id_str};
    my $user_screen_name = $orig_status->{user}{screen_name};
    my $status_id = $orig_status->{id_str};

    return if grep {$user_id eq $_} @{ $self->current_list_members };
    return if $self->stored_list_members->get($user_id);
    return if $self->read_members->get($user_id);
    return if $orig_status->{user}{followers_count} < $min_followers_count;

    my $try = 0;
    ATTEMPT: {
        my $res = $self->http->post(
            $self->settings->{discord_webhook_url},
            [],
            [ content => "https://twitter.com/$user_screen_name/status/$status_id" ]
        );
        if ($res->code !~ /^2/) {
            if ($try++ < 512) {
                warn $res->content;
                sleep 0.5;
                redo ATTEMPT;
            } else {
                return;
            }
        }
    }

    $self->read_members->set($user_id, 1);
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
            if ($self->stored_media_files->get($filename)) {
                $self->logger->info($filename. ' is already stored.');
                $pm->finish(-1, [$filename, undef]);
            }
            my $res;
            for (1..16) {
                $res = $self->http->get($media_urls->{$filename});
                last if $res->code == 200;
                $self->logger->info("Download failed! Retrying...: $filename ($media_urls->{$filename})");
            }
            $self->logger->warn("Cannot download this media file $filename ($media_urls->{$filename}) with HTTP Status Code ". $res->code) and $pm->finish(-1, [$filename, undef]) if $res->code != 200;
            $self->logger->info("Media file downloaded: $filename ($media_urls->{$filename})");
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
    my $path = "@{[$self->settings->{outdir}]}/$year/$month/$day";

    mkpath $path and $self->logger->info("'$path' directory is not exist, so a new one has been created") unless -d $path;

    for my $filename (@{[sort keys %$binaries]}) {
        open my $fh, ">", "$path/$filename"
            or die "Cannot create file: $!, filename: ".$filename;
        print $fh $binaries->{$filename}->content;
        close $fh;
        $self->stored_media_files->set($filename, "$path/$filename");
        $self->logger->info('Media file stored in storage! Filename: '. $filename);
    }
}

1;
